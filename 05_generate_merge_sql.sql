/*===========================================================================
  05_generate_merge_sql.sql
  RUN ON: the NEW server (VM1535), on the database you are migrating.
  DOES:   Installs one helper procedure,  stg.usp_MergeDelta , and then shows
          you - WITHOUT RUNNING ANYTHING - exactly what it intends to do to
          every table.

  This is the safety gate. Nothing is written to your live tables until you
  deliberately ask for it with @Execute = 1.

  HOW TO USE
    Step 1  Run this whole file once. It creates the procedure and prints a
            preview for every staged table. Read the preview.
    Step 2  Try ONE table for real:
              EXEC stg.usp_MergeDelta @Schema='dbo', @Table='Members', @Execute=1;
    Step 3  Check the table looks right, then run them all in order:
              EXEC stg.usp_MergeDelta_All @Execute=1;

  Every run is inside a transaction. If anything fails, that table is rolled
  back completely - you never end up with half a table imported.
===========================================================================*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('stg.usp_MergeDelta') IS NOT NULL DROP PROCEDURE stg.usp_MergeDelta;
GO
/* These two must be ON when the procedure is created, because it uses the
   XML .nodes() method to split the KeyColumns list. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE PROCEDURE stg.usp_MergeDelta
    @Schema  sysname,
    @Table   sysname,
    @Execute bit = 0            /* 0 = only show the SQL, 1 = actually run it */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stg          sysname,
            @target       nvarchar(300),
            @identityCol  sysname,
            @keyCols      nvarchar(500),
            @keepIdentity bit,
            @sql          nvarchar(max),
            @colList      nvarchar(max),
            @selList      nvarchar(max),
            @pred         nvarchar(max),
            @msg          nvarchar(1000);

    SET @stg    = @Schema + '_' + @Table;
    SET @target = QUOTENAME(@Schema) + '.' + QUOTENAME(@Table);

    IF OBJECT_ID('stg.' + QUOTENAME(@stg)) IS NULL
    BEGIN
        RAISERROR('No staging table stg.%s - was this table exported and imported?', 16, 1, @stg);
        RETURN;
    END
    IF OBJECT_ID(@target) IS NULL
    BEGIN
        RAISERROR('Target table %s does not exist on this server.', 16, 1, @target);
        RETURN;
    END

    DECLARE @stagedRows bigint;

    SELECT @keyCols = KeyColumns, @keepIdentity = KeepIdentity, @stagedRows = StagedRows
    FROM stg.__MergeConfig
    WHERE SchemaName = @Schema AND TableName = @Table;

    IF @keyCols IS NULL OR LTRIM(RTRIM(@keyCols)) = ''
    BEGIN
        RAISERROR('No KeyColumns configured for %s. Fill it in: UPDATE stg.__MergeConfig SET KeyColumns=''OrderID'' WHERE TableName=''%s''', 16, 1, @target, @Table);
        RETURN;
    END

    SELECT @identityCol = c.name
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(@target) AND c.is_identity = 1;

    /*--- the columns we will insert: everything that was staged, minus the
          identity column when we are letting this server allocate new IDs --*/
    SELECT @colList = STUFF((
        SELECT ', ' + QUOTENAME(sc.name)
        FROM sys.columns sc
        WHERE sc.object_id = OBJECT_ID('stg.' + QUOTENAME(@stg))
          AND NOT (@keepIdentity = 0 AND @identityCol IS NOT NULL AND sc.name = @identityCol)
        ORDER BY sc.column_id
        FOR XML PATH('')), 1, 2, '');

    SELECT @selList = STUFF((
        SELECT ', s.' + QUOTENAME(sc.name)
        FROM sys.columns sc
        WHERE sc.object_id = OBJECT_ID('stg.' + QUOTENAME(@stg))
          AND NOT (@keepIdentity = 0 AND @identityCol IS NOT NULL AND sc.name = @identityCol)
        ORDER BY sc.column_id
        FOR XML PATH('')), 1, 2, '');

    /*--- "do we already have this row?" test, built from KeyColumns --------
      The comma list is split with the XML trick rather than STRING_SPLIT so
      this also works on SQL Server 2012 and 2014.
      NOTE: if one of your key columns can contain NULL, change the generated
      line  t.[Col] = s.[Col]  into
            (t.[Col] = s.[Col] OR (t.[Col] IS NULL AND s.[Col] IS NULL))
      because in SQL NULL never equals NULL.                               */
    ;WITH k AS (
        SELECT LTRIM(RTRIM(n.x.value('.', 'nvarchar(128)'))) AS colName
        FROM (SELECT CAST('<i>' + REPLACE(@keyCols, ',', '</i><i>') + '</i>' AS xml) AS d) src
        CROSS APPLY src.d.nodes('/i') AS n(x)
    )
    SELECT @pred = STUFF((
        SELECT ' AND t.' + QUOTENAME(colName) + ' = s.' + QUOTENAME(colName)
        FROM k
        WHERE colName <> ''
        FOR XML PATH('')), 1, 5, '');

    IF @pred IS NULL
    BEGIN
        RAISERROR('Could not build a key comparison from KeyColumns "%s".', 16, 1, @keyCols);
        RETURN;
    END

    /*--- assemble --------------------------------------------------------*/
    DECLARE @useIdentityInsert bit = CASE WHEN @keepIdentity = 1 AND @identityCol IS NOT NULL THEN 1 ELSE 0 END;

    SET @sql =
        N'INSERT INTO ' + @target + N' (' + @colList + N')' + CHAR(13) + CHAR(10) +
        N'SELECT ' + @selList + CHAR(13) + CHAR(10) +
        N'FROM stg.' + QUOTENAME(@stg) + N' AS s' + CHAR(13) + CHAR(10) +
        N'WHERE NOT EXISTS (SELECT 1 FROM ' + @target + N' AS t WHERE ' + @pred + N');';

    IF @useIdentityInsert = 1
        SET @sql = N'SET IDENTITY_INSERT ' + @target + N' ON;' + CHAR(13) + CHAR(10) +
                   @sql + CHAR(13) + CHAR(10) +
                   N'SET IDENTITY_INSERT ' + @target + N' OFF;';

    /*--- show it ---------------------------------------------------------*/
    DECLARE @header nvarchar(1000);
    SET @header = '/*==== ' + @target + '  (staged rows: ' +
                  CAST(ISNULL(@stagedRows, 0) AS varchar(20)) +
                  ', key: ' + @keyCols +
                  ', keep original IDs: ' +
                  CASE WHEN @keepIdentity = 1 THEN 'YES' ELSE 'NO - new IDs will be allocated' END + ') ====*/';
    PRINT '';
    PRINT @header;

    DECLARE @i int = 1, @len int = LEN(@sql);
    WHILE @i <= @len
    BEGIN
        PRINT SUBSTRING(@sql, @i, 4000);
        SET @i = @i + 4000;
    END

    IF @keepIdentity = 0 AND @identityCol IS NOT NULL
    BEGIN
        PRINT '/* WARNING: this table gets NEW ID values. Any child table that';
        PRINT '   points at ' + QUOTENAME(@identityCol) + ' must be remapped -';
        PRINT '   see 06_merge_templates.sql section B before you run it. */';
    END

    /*--- how many staged rows will be SKIPPED, and is that suspicious? ------
      A staged row is skipped when the key already exists in the target.
      Usually that is exactly what we want (you are re-running the import and
      the row is already there).

      But if the key is the identity ID, "already exists" can also mean the
      new server handed that same number to a DIFFERENT, unrelated row. In
      that case the row we skip is a real customer record that would be
      quietly thrown away. That is the one failure mode of this whole job
      that does not announce itself, so it is checked and shouted about. */
    DECLARE @skipped bigint, @skipSql nvarchar(max);
    SET @skipSql = N'SELECT @n = COUNT_BIG(*) FROM stg.' + QUOTENAME(@stg) + N' AS s ' +
                   N'WHERE EXISTS (SELECT 1 FROM ' + @target + N' AS t WHERE ' + @pred + N');';
    EXEC sp_executesql @skipSql, N'@n bigint OUTPUT', @n = @skipped OUTPUT;

    IF @skipped > 0
    BEGIN
        SET @msg = '/* ' + CAST(@skipped AS varchar(20)) + ' of ' + CAST(ISNULL(@stagedRows,0) AS varchar(20)) +
                   ' staged row(s) already match an existing row on the key and will NOT be inserted. */';
        PRINT @msg;

        IF @keepIdentity = 1 AND @identityCol IS NOT NULL
           AND REPLACE(LTRIM(RTRIM(@keyCols)), ' ', '') = @identityCol
        BEGIN
            PRINT '/* !!! STOP AND CHECK THIS ONE !!!';
            PRINT '   The key is the identity column ' + QUOTENAME(@identityCol) + ', and some of those';
            PRINT '   ID numbers already exist here. Either you already imported these';
            PRINT '   rows (fine, run again and nothing happens), or the new server gave';
            PRINT '   those same numbers to different records - in which case skipping';
            PRINT '   them would LOSE real data.';
            PRINT '   Check with the query in 06_merge_templates.sql section A before';
            PRINT '   running this table with @Execute=1. */';
        END
    END

    /*--- or run it -------------------------------------------------------*/
    IF @Execute = 1
    BEGIN
        DECLARE @before bigint, @after bigint, @countSql nvarchar(1000);
        SET @countSql = N'SELECT @c = COUNT_BIG(*) FROM ' + @target + N';';
        EXEC sp_executesql @countSql, N'@c bigint OUTPUT', @c = @before OUTPUT;

        BEGIN TRY
            BEGIN TRANSACTION;
            EXEC sp_executesql @sql;
            COMMIT TRANSACTION;

            EXEC sp_executesql @countSql, N'@c bigint OUTPUT', @c = @after OUTPUT;

            SET @msg = '   --> ' + @target + ': ' + CAST(@before AS varchar(20)) + ' rows before, ' +
                       CAST(@after AS varchar(20)) + ' rows after, ' +
                       CAST(@after - @before AS varchar(20)) + ' inserted.';
            PRINT @msg;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            SET @msg = '   !!! ' + @target + ' FAILED and was rolled back: ' + ERROR_MESSAGE();
            PRINT @msg;
            THROW;
        END CATCH
    END
END
GO

/*===========================================================================
  Driver: walk every staged table in foreign-key order.
===========================================================================*/
IF OBJECT_ID('stg.usp_MergeDelta_All') IS NOT NULL DROP PROCEDURE stg.usp_MergeDelta_All;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE PROCEDURE stg.usp_MergeDelta_All
    @Execute bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    /* work out parent-before-child order, same logic as script 01 */
    DECLARE @lvl TABLE (object_id int PRIMARY KEY, lvl int NULL);
    INSERT INTO @lvl (object_id, lvl)
    SELECT t.object_id, NULL FROM sys.tables t WHERE t.is_ms_shipped = 0 AND t.type = 'U';

    UPDATE l SET lvl = 0
    FROM @lvl l
    WHERE NOT EXISTS (SELECT 1 FROM sys.foreign_keys fk
                      WHERE fk.parent_object_id = l.object_id
                        AND fk.referenced_object_id <> fk.parent_object_id);

    DECLARE @pass int = 0;
    WHILE @pass < 50 AND EXISTS (SELECT 1 FROM @lvl WHERE lvl IS NULL)
    BEGIN
        SET @pass = @pass + 1;
        UPDATE l SET lvl = @pass
        FROM @lvl l
        WHERE l.lvl IS NULL
          AND NOT EXISTS (SELECT 1
                          FROM sys.foreign_keys fk
                          JOIN @lvl p ON p.object_id = fk.referenced_object_id
                          WHERE fk.parent_object_id = l.object_id
                            AND fk.referenced_object_id <> fk.parent_object_id
                            AND p.lvl IS NULL);
    END
    UPDATE @lvl SET lvl = 99 WHERE lvl IS NULL;

    DECLARE @s sysname, @t sysname;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT mc.SchemaName, mc.TableName
        FROM stg.__MergeConfig mc
        JOIN sys.tables tt   ON tt.name = mc.TableName
        JOIN sys.schemas ss  ON ss.schema_id = tt.schema_id AND ss.name = mc.SchemaName
        JOIN @lvl l          ON l.object_id = tt.object_id
        ORDER BY l.lvl, mc.SchemaName, mc.TableName;

    OPEN c;
    FETCH NEXT FROM c INTO @s, @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC stg.usp_MergeDelta @Schema = @s, @Table = @t, @Execute = @Execute;
        FETCH NEXT FROM c INTO @s, @t;
    END
    CLOSE c;
    DEALLOCATE c;
END
GO

/*--- preview everything, run nothing ---------------------------------------*/
PRINT '=========================================================';
PRINT ' PREVIEW ONLY - nothing below has been executed.';
PRINT ' Read it, then run:  EXEC stg.usp_MergeDelta_All @Execute=1;';
PRINT '=========================================================';
GO
EXEC stg.usp_MergeDelta_All @Execute = 0;
GO
