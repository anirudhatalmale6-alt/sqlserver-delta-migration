/*===========================================================================
  06_merge_templates.sql
  RUN ON: the NEW server (VM1535).

  This file is for the awkward tables - the ones where both servers handed
  out the same ID numbers to different records. Script 05 tells you which
  ones those are.

  SECTION A  look at a clash with your own eyes before deciding anything
  SECTION B  import a table with NEW ids and repair the children automatically
  SECTION C  a plain hand-editable template, if you would rather do it yourself

  Run the whole file once to install the two helper procedures. Nothing is
  changed in your data just by installing them.
===========================================================================*/

SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*===========================================================================
  SECTION A - SHOW ME THE CLASH

    EXEC stg.usp_ShowKeyClashes @Schema='dbo', @Table='Members';

  Puts the row from the old server directly above the row that already sits
  on the new server with that same ID. Look at them.

    * If they are obviously the SAME record (same name, same e-mail, same
      date) then the row was already migrated. Nothing to do - leave
      KeepIdentity = 1 and the import will simply skip it.

    * If they are DIFFERENT people or different payments, you have a real
      collision. Use SECTION B for that table.
===========================================================================*/
IF OBJECT_ID('stg.usp_ShowKeyClashes') IS NOT NULL DROP PROCEDURE stg.usp_ShowKeyClashes;
GO
CREATE PROCEDURE stg.usp_ShowKeyClashes
    @Schema sysname,
    @Table  sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @stg sysname = @Schema + '_' + @Table,
            @target nvarchar(300) = QUOTENAME(@Schema) + '.' + QUOTENAME(@Table),
            @keyCols nvarchar(500), @pred nvarchar(max), @colList nvarchar(max),
            @sql nvarchar(max), @firstKey sysname;

    SELECT @keyCols = KeyColumns FROM stg.__MergeConfig
    WHERE SchemaName = @Schema AND TableName = @Table;

    IF @keyCols IS NULL
    BEGIN
        RAISERROR('No config row for that table - run 04_import_to_staging.ps1 first.', 16, 1);
        RETURN;
    END

    ;WITH k AS (
        SELECT LTRIM(RTRIM(n.x.value('.', 'nvarchar(128)'))) AS colName
        FROM (SELECT CAST('<i>' + REPLACE(@keyCols, ',', '</i><i>') + '</i>' AS xml) AS d) src
        CROSS APPLY src.d.nodes('/i') AS n(x)
    )
    SELECT @pred = STUFF((SELECT ' AND t.' + QUOTENAME(colName) + ' = s.' + QUOTENAME(colName)
                          FROM k WHERE colName <> '' FOR XML PATH('')), 1, 5, ''),
           @firstKey = (SELECT TOP 1 colName FROM k WHERE colName <> '');

    /* use the staged column list for both sides so the two halves line up */
    SELECT @colList = STUFF((SELECT ', ' + QUOTENAME(sc.name)
                             FROM sys.columns sc
                             WHERE sc.object_id = OBJECT_ID('stg.' + QUOTENAME(@stg))
                             ORDER BY sc.column_id
                             FOR XML PATH('')), 1, 2, '');

    SET @sql =
        N'SELECT CAST(''1 OLD SERVER (waiting to be imported)'' AS varchar(40)) AS Source, ' + @colList +
        N' FROM stg.' + QUOTENAME(@stg) + N' AS s ' +
        N'WHERE EXISTS (SELECT 1 FROM ' + @target + N' AS t WHERE ' + @pred + N') ' +
        N'UNION ALL ' +
        N'SELECT CAST(''2 NEW SERVER (already here)'' AS varchar(40)), ' + @colList +
        N' FROM ' + @target + N' AS t ' +
        N'WHERE EXISTS (SELECT 1 FROM stg.' + QUOTENAME(@stg) + N' AS s WHERE ' + @pred + N') ' +
        N'ORDER BY ' + QUOTENAME(@firstKey) + N', Source;';

    EXEC sp_executesql @sql;
END
GO

/*===========================================================================
  SECTION B - IMPORT WITH NEW IDs AND REPAIR THE CHILDREN

    EXEC stg.usp_MergeDelta_Remap @Schema='dbo', @Table='Members',
                                  @BusinessKey='MemberGuid', @Execute=0;

  What it does, in plain words:

    1. Inserts the old server's rows into the real table WITHOUT forcing the
       old ID. The new server allocates fresh, free ID numbers.
    2. While inserting, it writes down which old ID became which new ID.
    3. It then looks up every table that points at this one through a foreign
       key, and rewrites those references in the STAGING copies so they point
       at the new numbers.

  So after running this for the parent table, you merge the child tables the
  normal way with script 05 and their links are already correct.

  @BusinessKey is how we recognise a row we have already imported, now that
  the ID is no longer reliable. It must be something that means the same
  thing on both servers - a member GUID, an e-mail address, a QuickPay
  subscription id, an order number. If you get this wrong you will import
  duplicates, so it is worth a moment's thought.

  Always run once with @Execute=0 first. It reports what it would do.
===========================================================================*/
IF OBJECT_ID('stg.usp_MergeDelta_Remap') IS NOT NULL DROP PROCEDURE stg.usp_MergeDelta_Remap;
GO

IF OBJECT_ID('stg.__IdMap') IS NULL
CREATE TABLE stg.__IdMap (
    SchemaName sysname  NOT NULL,
    TableName  sysname  NOT NULL,
    OldId      bigint   NOT NULL,
    NewId      bigint   NOT NULL,
    MappedAt   datetime NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK___IdMap PRIMARY KEY (SchemaName, TableName, OldId)
);
GO

CREATE PROCEDURE stg.usp_MergeDelta_Remap
    @Schema      sysname,
    @Table       sysname,
    @BusinessKey nvarchar(500),      /* comma separated, NOT the identity id */
    @Execute     bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stg         sysname       = @Schema + '_' + @Table,
            @target      nvarchar(300) = QUOTENAME(@Schema) + '.' + QUOTENAME(@Table),
            @identityCol sysname,
            @colList     nvarchar(max),
            @selList     nvarchar(max),
            @pred        nvarchar(max),
            @sql         nvarchar(max),
            @msg         nvarchar(1000),
            @n           bigint;

    IF OBJECT_ID('stg.' + QUOTENAME(@stg)) IS NULL
    BEGIN RAISERROR('No staging table stg.%s', 16, 1, @stg); RETURN; END

    SELECT @identityCol = c.name FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(@target) AND c.is_identity = 1;

    IF @identityCol IS NULL
    BEGIN
        RAISERROR('%s has no identity column, so it does not need remapping. Use script 05.', 16, 1, @target);
        RETURN;
    END

    /* everything except the identity column - the server allocates that */
    SELECT @colList = STUFF((SELECT ', ' + QUOTENAME(sc.name)
                             FROM sys.columns sc
                             WHERE sc.object_id = OBJECT_ID('stg.' + QUOTENAME(@stg))
                               AND sc.name <> @identityCol
                             ORDER BY sc.column_id FOR XML PATH('')), 1, 2, '');
    SELECT @selList = STUFF((SELECT ', s.' + QUOTENAME(sc.name)
                             FROM sys.columns sc
                             WHERE sc.object_id = OBJECT_ID('stg.' + QUOTENAME(@stg))
                               AND sc.name <> @identityCol
                             ORDER BY sc.column_id FOR XML PATH('')), 1, 2, '');

    ;WITH k AS (
        SELECT LTRIM(RTRIM(n.x.value('.', 'nvarchar(128)'))) AS colName
        FROM (SELECT CAST('<i>' + REPLACE(@BusinessKey, ',', '</i><i>') + '</i>' AS xml) AS d) src
        CROSS APPLY src.d.nodes('/i') AS n(x)
    )
    SELECT @pred = STUFF((SELECT ' AND t.' + QUOTENAME(colName) + ' = s.' + QUOTENAME(colName)
                          FROM k WHERE colName <> '' FOR XML PATH('')), 1, 5, '');

    IF @pred IS NULL
    BEGIN RAISERROR('Could not read a business key from "%s".', 16, 1, @BusinessKey); RETURN; END

    IF @BusinessKey = @identityCol
    BEGIN
        RAISERROR('The business key must NOT be the identity column - that is the value we are throwing away.', 16, 1);
        RETURN;
    END

    /*--- how many rows are actually new? ---------------------------------*/
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM stg.' + QUOTENAME(@stg) + N' AS s ' +
               N'WHERE NOT EXISTS (SELECT 1 FROM ' + @target + N' AS t WHERE ' + @pred + N');';
    EXEC sp_executesql @sql, N'@n bigint OUTPUT', @n = @n OUTPUT;

    SET @msg = '=== ' + @target + ': ' + CAST(@n AS varchar(20)) +
               ' row(s) would be inserted with NEW ids, matched on business key ' + @BusinessKey;
    PRINT @msg;

    /*--- the insert, capturing old id -> new id --------------------------
      MERGE is used instead of a plain INSERT for one reason only: its OUTPUT
      clause is allowed to read columns from the SOURCE as well as from the
      inserted row, which is the only way to pair the two ids together.
      "ON 1 = 0" simply means "never match", so every source row is inserted. */
    SET @sql =
        N'MERGE INTO ' + @target + N' AS t ' +
        N'USING (SELECT * FROM stg.' + QUOTENAME(@stg) + N' AS s ' +
        N'       WHERE NOT EXISTS (SELECT 1 FROM ' + @target + N' AS t WHERE ' + @pred + N')) AS s ' +
        N'ON 1 = 0 ' +
        N'WHEN NOT MATCHED BY TARGET THEN INSERT (' + @colList + N') VALUES (' + @selList + N') ' +
        N'OUTPUT @sch, @tab, s.' + QUOTENAME(@identityCol) + N', inserted.' + QUOTENAME(@identityCol) +
        N' INTO stg.__IdMap (SchemaName, TableName, OldId, NewId);';

    PRINT '';
    PRINT '-- statement that will run:';
    DECLARE @i int = 1, @len int = LEN(@sql);
    WHILE @i <= @len BEGIN PRINT SUBSTRING(@sql, @i, 4000); SET @i = @i + 4000; END

    /*--- which child tables will need repairing? -------------------------*/
    PRINT '';
    PRINT '-- child tables that reference ' + @target + '.' + QUOTENAME(@identityCol) + ':';

    DECLARE @cs sysname, @ct sysname, @cc sysname, @childStg sysname;

    DECLARE ch CURSOR LOCAL FAST_FORWARD FOR
        SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id),
               OBJECT_NAME(fk.parent_object_id),
               pc.name
        FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id     AND pc.column_id = fkc.parent_column_id
        JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
        WHERE fk.referenced_object_id = OBJECT_ID(@target)
          AND rc.name = @identityCol
          AND fk.parent_object_id <> fk.referenced_object_id;

    OPEN ch;
    FETCH NEXT FROM ch INTO @cs, @ct, @cc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @childStg = @cs + '_' + @ct;
        IF OBJECT_ID('stg.' + QUOTENAME(@childStg)) IS NULL
            PRINT '   ' + QUOTENAME(@cs) + '.' + QUOTENAME(@ct) + '.' + QUOTENAME(@cc) + '  (not staged - nothing to repair)';
        ELSE
            PRINT '   ' + QUOTENAME(@cs) + '.' + QUOTENAME(@ct) + '.' + QUOTENAME(@cc) + '  -> stg.' + QUOTENAME(@childStg) + ' will be rewritten';
        FETCH NEXT FROM ch INTO @cs, @ct, @cc;
    END
    CLOSE ch; DEALLOCATE ch;

    IF @Execute = 0
    BEGIN
        PRINT '';
        PRINT '-- PREVIEW ONLY. Nothing was changed. Re-run with @Execute=1 when you are happy.';
        RETURN;
    END

    /*--- do it, in this order and no other -------------------------------
      1. insert the parents, recording old id -> new id
      2. only THEN rewrite the children, because step 1 is what fills in the
         map that step 2 reads. Doing it the other way round would quietly
         leave every child pointing at the old numbers.                    */
    DECLARE @mapBefore bigint, @mapAfter bigint;
    SELECT @mapBefore = COUNT_BIG(*) FROM stg.__IdMap WHERE SchemaName = @Schema AND TableName = @Table;

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @sql =
            N'MERGE INTO ' + @target + N' AS t ' +
            N'USING (SELECT * FROM stg.' + QUOTENAME(@stg) + N' AS s ' +
            N'       WHERE NOT EXISTS (SELECT 1 FROM ' + @target + N' AS t WHERE ' + @pred + N')) AS s ' +
            N'ON 1 = 0 ' +
            N'WHEN NOT MATCHED BY TARGET THEN INSERT (' + @colList + N') VALUES (' + @selList + N') ' +
            N'OUTPUT @sch, @tab, s.' + QUOTENAME(@identityCol) + N', inserted.' + QUOTENAME(@identityCol) +
            N' INTO stg.__IdMap (SchemaName, TableName, OldId, NewId);';

        EXEC sp_executesql @sql, N'@sch sysname, @tab sysname', @sch = @Schema, @tab = @Table;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @msg = '   !!! ' + @target + ' FAILED and was rolled back: ' + ERROR_MESSAGE();
        PRINT @msg;
        THROW;
    END CATCH

    SELECT @mapAfter = COUNT_BIG(*) FROM stg.__IdMap WHERE SchemaName = @Schema AND TableName = @Table;
    SET @msg = '   --> inserted ' + CAST(@mapAfter - @mapBefore AS varchar(20)) + ' row(s) into ' + @target + ' with new ids.';
    PRINT @msg;

    /*--- now, and only now, repair the children --------------------------*/
    DECLARE ch2 CURSOR LOCAL FAST_FORWARD FOR
        SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id),
               OBJECT_NAME(fk.parent_object_id),
               pc.name
        FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id     AND pc.column_id = fkc.parent_column_id
        JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
        WHERE fk.referenced_object_id = OBJECT_ID(@target)
          AND rc.name = @identityCol
          AND fk.parent_object_id <> fk.referenced_object_id;

    OPEN ch2;
    FETCH NEXT FROM ch2 INTO @cs, @ct, @cc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @childStg = @cs + '_' + @ct;
        IF OBJECT_ID('stg.' + QUOTENAME(@childStg)) IS NOT NULL
        BEGIN
            SET @sql = N'UPDATE c SET c.' + QUOTENAME(@cc) + N' = m.NewId ' +
                       N'FROM stg.' + QUOTENAME(@childStg) + N' AS c ' +
                       N'JOIN stg.__IdMap AS m ON m.SchemaName = @sch AND m.TableName = @tab ' +
                       N'                     AND m.OldId = c.' + QUOTENAME(@cc) + N';' +
                       N'SELECT @r = @@ROWCOUNT;';
            DECLARE @r bigint;
            EXEC sp_executesql @sql, N'@sch sysname, @tab sysname, @r bigint OUTPUT',
                 @sch = @Schema, @tab = @Table, @r = @r OUTPUT;
            SET @msg = '   --> stg.' + QUOTENAME(@childStg) + '.' + QUOTENAME(@cc) +
                       ': ' + CAST(ISNULL(@r,0) AS varchar(20)) + ' reference(s) repointed.';
            PRINT @msg;
        END
        FETCH NEXT FROM ch2 INTO @cs, @ct, @cc;
    END
    CLOSE ch2; DEALLOCATE ch2;

    PRINT '   --> old id / new id pairs are kept in stg.__IdMap for your records.';
    PRINT '   --> now merge the child tables with script 05 in the normal way.';
END
GO

PRINT 'Installed: stg.usp_ShowKeyClashes and stg.usp_MergeDelta_Remap';
GO

/*===========================================================================
  SECTION C - PLAIN TEMPLATE, EDIT BY HAND

  If a table needs something special, copy this block and adjust it. This is
  exactly what script 05 generates, written out longhand so you can see the
  moving parts.

  ---------------------------------------------------------------------------
  -- keep the original ID numbers (the normal case)
  SET IDENTITY_INSERT dbo.MyTable ON;

  INSERT INTO dbo.MyTable (ID, ColumnA, ColumnB, Created)
  SELECT s.ID, s.ColumnA, s.ColumnB, s.Created
  FROM   stg.dbo_MyTable AS s
  WHERE  NOT EXISTS (SELECT 1 FROM dbo.MyTable AS t WHERE t.ID = s.ID);

  SET IDENTITY_INSERT dbo.MyTable OFF;
  ---------------------------------------------------------------------------
  -- recognise existing rows by a business key instead of the ID
  INSERT INTO dbo.MyTable (ColumnA, ColumnB, Created)
  SELECT s.ColumnA, s.ColumnB, s.Created
  FROM   stg.dbo_MyTable AS s
  WHERE  NOT EXISTS (SELECT 1 FROM dbo.MyTable AS t
                     WHERE t.OrderID = s.OrderID);
  ---------------------------------------------------------------------------

  Two things to remember when you edit:

    1. Leave out computed columns and any rowversion/timestamp column. SQL
       Server fills those in itself and will refuse the insert otherwise.
       The export never puts them in the file, so if you copy the column list
       from stg.dbo_MyTable you are automatically safe.

    2. If a key column can be NULL, write
         (t.Col = s.Col OR (t.Col IS NULL AND s.Col IS NULL))
       because in SQL, NULL is never equal to NULL - not even to another NULL.
===========================================================================*/
