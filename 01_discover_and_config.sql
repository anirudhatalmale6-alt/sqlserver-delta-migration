/*===========================================================================
  01_discover_and_config.sql
  RUN ON: the OLD SQL Server (VM0810), once per database.
  DOES:   Reads nothing but system tables. Changes NOTHING. 100% safe.
  GIVES:  1) An inventory of every table: row count, primary key, identity
             column, the best "created" date column, and the order the tables
             must be processed in so foreign keys never break.
          2) A ready-made config block you paste into tables.csv.

  HOW TO RUN
    Open SQL Server Management Studio, pick the database in the dropdown
    (for example DatingTid), paste this whole file, press Execute (F5).
    Then click the "Results" grid, Ctrl+A, Ctrl+C and paste into Excel.

  Change @Cutoff below if the backup was taken on a different date.
===========================================================================*/

SET NOCOUNT ON;

DECLARE @Cutoff varchar(19) = '2026-07-30';   /* <-- date of the old backup */

/*--- work out a safe processing order from the foreign keys -----------------
  Level 0 = tables that depend on nobody (insert these first)
  Level 1 = tables that only depend on level 0 ... and so on.
  Level 99 = part of a circular foreign key chain, handle by hand.        */

IF OBJECT_ID('tempdb..#lvl') IS NOT NULL DROP TABLE #lvl;
CREATE TABLE #lvl (object_id int NOT NULL PRIMARY KEY, lvl int NULL);

INSERT INTO #lvl (object_id, lvl)
SELECT t.object_id, NULL
FROM sys.tables t
WHERE t.is_ms_shipped = 0 AND t.type = 'U';

UPDATE l SET lvl = 0
FROM #lvl l
WHERE NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys fk
        WHERE fk.parent_object_id = l.object_id
          AND fk.referenced_object_id <> fk.parent_object_id);

DECLARE @pass int = 0;
WHILE @pass < 50 AND EXISTS (SELECT 1 FROM #lvl WHERE lvl IS NULL)
BEGIN
    SET @pass += 1;
    UPDATE l SET lvl = @pass
    FROM #lvl l
    WHERE l.lvl IS NULL
      AND NOT EXISTS (
            SELECT 1
            FROM sys.foreign_keys fk
            JOIN #lvl p ON p.object_id = fk.referenced_object_id
            WHERE fk.parent_object_id = l.object_id
              AND fk.referenced_object_id <> fk.parent_object_id
              AND p.lvl IS NULL);
END
UPDATE #lvl SET lvl = 99 WHERE lvl IS NULL;   /* circular FK */

/*--- gather the facts about every table ----------------------------------*/

IF OBJECT_ID('tempdb..#inv') IS NOT NULL DROP TABLE #inv;

SELECT
    RunOrder        = l.lvl,
    SchemaName      = s.name,
    TableName       = t.name,
    [Rows]          = ISNULL((SELECT SUM(ps.row_count)
                              FROM sys.dm_db_partition_stats ps
                              WHERE ps.object_id = t.object_id
                                AND ps.index_id IN (0,1)), 0),
    IdentityColumn  = ISNULL((SELECT c.name FROM sys.columns c
                              WHERE c.object_id = t.object_id AND c.is_identity = 1), ''),
    PrimaryKey      = ISNULL(STUFF((
                          SELECT ', ' + c.name
                          FROM sys.indexes i
                          JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                          JOIN sys.columns c       ON c.object_id  = ic.object_id AND c.column_id = ic.column_id
                          WHERE i.object_id = t.object_id AND i.is_primary_key = 1
                          ORDER BY ic.key_ordinal
                          FOR XML PATH('')), 1, 2, ''), ''),
    DateColumn      = ISNULL(dc.BestDateColumn, ''),
    AllDateColumns  = ISNULL(STUFF((
                          SELECT ', ' + c.name
                          FROM sys.columns c
                          JOIN sys.types ty ON ty.user_type_id = c.user_type_id
                          WHERE c.object_id = t.object_id
                            AND ty.name IN ('datetime','datetime2','smalldatetime','date','datetimeoffset')
                          ORDER BY c.column_id
                          FOR XML PATH('')), 1, 2, ''), ''),
    ParentTables    = ISNULL(STUFF((
                          SELECT DISTINCT ', ' + OBJECT_NAME(fk.referenced_object_id)
                          FROM sys.foreign_keys fk
                          WHERE fk.parent_object_id = t.object_id
                            AND fk.referenced_object_id <> fk.parent_object_id
                          FOR XML PATH('')), 1, 2, ''), '')
INTO #inv
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN #lvl l        ON l.object_id = t.object_id
OUTER APPLY (
    SELECT TOP 1 c.name AS BestDateColumn
    FROM sys.columns c
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = t.object_id
      AND ty.name IN ('datetime','datetime2','smalldatetime','date','datetimeoffset')
    ORDER BY CASE
               WHEN c.name LIKE '%creat%'  THEN 0    /* Created, CreateDate  */
               WHEN c.name LIKE '%oprett%' THEN 0    /* Danish: Oprettet     */
               WHEN c.name LIKE '%insert%' THEN 1
               WHEN c.name LIKE '%dato%'   THEN 2    /* Danish: Dato         */
               WHEN c.name LIKE '%date%'   THEN 3
               WHEN c.name LIKE '%time%'   THEN 4
               WHEN c.name LIKE '%stamp%'  THEN 4
               ELSE 9
             END, c.column_id
) dc
WHERE t.is_ms_shipped = 0;

/*=== RESULT 1 : the inventory ============================================*/
SELECT
    RunOrder, SchemaName, TableName, [Rows],
    IdentityColumn, PrimaryKey, DateColumn, AllDateColumns, ParentTables,
    Note = CASE
             WHEN RunOrder = 99      THEN 'CIRCULAR FOREIGN KEY - handle by hand'
             WHEN [Rows]   = 0       THEN 'empty - nothing to move'
             WHEN DateColumn = ''    THEN 'NO DATE COLUMN - see README section 4'
             ELSE ''
           END
FROM #inv
ORDER BY RunOrder, SchemaName, TableName;

/*=== RESULT 2 : paste this into tables.csv ===============================
  Columns are separated by a SEMICOLON, because the WHERE clause and the
  key list contain commas.

  Schema ; Table ; WhereClause ; KeyColumns ; KeepIdentity
    WhereClause   which rows to take from the OLD server. Empty = every row.
    KeyColumns    how to recognise a row we already have, so it is not
                  inserted twice. Prefer a real business key (an order number,
                  a subscription id, an e-mail) over the identity ID.
    KeepIdentity  1 = keep the original ID values (normal)
                  0 = let the new server hand out fresh IDs (only needed when
                      the ID would clash - script 02 tells you which tables)
=========================================================================*/
SELECT
    CsvLine =
        SchemaName + ';' + TableName + ';' +
        CASE WHEN [Rows] = 0     THEN ''
             WHEN DateColumn = '' THEN ''
             ELSE '[' + DateColumn + '] >= ''' + @Cutoff + ''''
        END + ';' +
        CASE WHEN PrimaryKey <> '' THEN PrimaryKey ELSE IdentityColumn END + ';' +
        CASE WHEN IdentityColumn = '' THEN '0' ELSE '1' END,
    Warning = CASE
                WHEN [Rows] = 0        THEN '<-- empty table, you can delete this line'
                WHEN DateColumn = ''   THEN '<-- NO DATE COLUMN: fill in a WHERE clause yourself'
                WHEN RunOrder  = 99    THEN '<-- circular FK, check the order by hand'
                ELSE ''
              END
FROM #inv
ORDER BY RunOrder, SchemaName, TableName;

DROP TABLE #inv;
DROP TABLE #lvl;
