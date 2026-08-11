/*===========================================================================
  02_check_gap_and_collisions.sql
  RUN ON: BOTH servers - first the OLD one (VM0810), then the NEW one (VM1535),
          on the same database, and keep both results side by side.
  DOES:   Reads only. Changes NOTHING. 100% safe.

  WHY THIS SCRIPT MATTERS - please read this bit.

  Both servers have been writing rows since 30 July. The old server kept
  taking real customer payments, and the new server has been given its own
  test and live rows. Both of them hand out ID numbers from their own
  counter, starting from the same place.

  So the old server may have created Member ID 11, 12, 13 - and the new
  server may ALSO have created a completely different Member ID 11, 12, 13.
  Same numbers, different people.

  If we copy the old rows across and force the original IDs, one of two bad
  things happens: either the insert fails with a primary key error (annoying
  but safe), or - on a table without a primary key - you silently end up with
  two different customers sharing one ID and the subscriptions attached to
  the wrong person. That second one is the dangerous case.

  This script tells you exactly which tables have that problem, so we only
  do the complicated fix where it is genuinely needed.

  HOW TO READ THE RESULT
    Run it on the OLD server  -> "RowsAfterCutoff" is the data we must move.
    Run it on the NEW server  -> "RowsAfterCutoff" should normally be 0.
        Every table where the NEW server shows a number bigger than 0 is a
        table where both servers wrote rows. Those tables need KeepIdentity=0
        and the remap recipe in 06_merge_templates.sql, section B.
===========================================================================*/

SET NOCOUNT ON;

DECLARE @Cutoff datetime = '2026-07-30';   /* <-- date of the old backup */

IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (
    SchemaName      sysname,
    TableName       sysname,
    TotalRows       bigint  NULL,
    RowsAfterCutoff bigint  NULL,
    MinIdentity     bigint  NULL,
    MaxIdentity     bigint  NULL,
    DateColumn      sysname NULL,
    IdentityColumn  sysname NULL
);

DECLARE @sch sysname, @tab sysname, @datecol sysname, @idcol sysname, @sql nvarchar(max);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.name, t.name,
           (SELECT TOP 1 c.name
              FROM sys.columns c
              JOIN sys.types ty ON ty.user_type_id = c.user_type_id
             WHERE c.object_id = t.object_id
               AND ty.name IN ('datetime','datetime2','smalldatetime','date','datetimeoffset')
             ORDER BY CASE WHEN c.name LIKE '%creat%'  THEN 0
                           WHEN c.name LIKE '%oprett%' THEN 0
                           WHEN c.name LIKE '%insert%' THEN 1
                           WHEN c.name LIKE '%dato%'   THEN 2
                           WHEN c.name LIKE '%date%'   THEN 3
                           WHEN c.name LIKE '%time%'   THEN 4
                           WHEN c.name LIKE '%stamp%'  THEN 4
                           ELSE 9 END, c.column_id),
           (SELECT c.name FROM sys.columns c
             WHERE c.object_id = t.object_id AND c.is_identity = 1)
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0 AND t.type = 'U'
    ORDER BY s.name, t.name;

OPEN cur;
FETCH NEXT FROM cur INTO @sch, @tab, @datecol, @idcol;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql =
        N'INSERT INTO #r (SchemaName, TableName, TotalRows, RowsAfterCutoff, MinIdentity, MaxIdentity, DateColumn, IdentityColumn) ' +
        N'SELECT @sch, @tab, COUNT_BIG(*), ' +
        CASE WHEN @datecol IS NULL THEN N'NULL, '
             ELSE N'SUM(CASE WHEN ' + QUOTENAME(@datecol) + N' >= @Cutoff THEN 1 ELSE 0 END), ' END +
        CASE WHEN @idcol IS NULL THEN N'NULL, NULL, '
             ELSE N'MIN(CAST(' + QUOTENAME(@idcol) + N' AS bigint)), MAX(CAST(' + QUOTENAME(@idcol) + N' AS bigint)), ' END +
        N'@datecol, @idcol FROM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tab) + N' WITH (NOLOCK);';

    BEGIN TRY
        EXEC sp_executesql @sql,
             N'@sch sysname, @tab sysname, @datecol sysname, @idcol sysname, @Cutoff datetime',
             @sch = @sch, @tab = @tab, @datecol = @datecol, @idcol = @idcol, @Cutoff = @Cutoff;
    END TRY
    BEGIN CATCH
        INSERT INTO #r (SchemaName, TableName, DateColumn, IdentityColumn)
        VALUES (@sch, @tab, @datecol, @idcol);
    END CATCH

    FETCH NEXT FROM cur INTO @sch, @tab, @datecol, @idcol;
END
CLOSE cur;
DEALLOCATE cur;

SELECT
    SchemaName,
    TableName,
    TotalRows,
    RowsAfterCutoff,
    MinIdentity,
    MaxIdentity,
    DateColumn     = ISNULL(DateColumn, '(none)'),
    IdentityColumn = ISNULL(IdentityColumn, '(none)'),
    Verdict = CASE
        WHEN TotalRows = 0
            THEN 'empty'
        WHEN DateColumn IS NULL
            THEN 'no date column - compare TotalRows between the two servers by hand'
        WHEN RowsAfterCutoff = 0
            THEN 'no rows after cutoff'
        WHEN IdentityColumn IS NULL
            THEN 'rows after cutoff, no identity - safe to copy'
        ELSE 'rows after cutoff WITH identity - on the NEW server this means KeepIdentity=0 + remap'
      END
FROM #r
ORDER BY CASE WHEN RowsAfterCutoff > 0 THEN 0 ELSE 1 END, SchemaName, TableName;

DROP TABLE #r;
