/*===========================================================================
  07_ssms_only_generate_inserts.sql

  THE SIMPLE ROUTE - NO POWERSHELL, NO BCP, NOTHING TO INSTALL.
  Everything happens inside SQL Server Management Studio.

  This is the answer to "maybe I just export it and create it all manually".
  Yes - and this writes the INSERT statements for you.

  ---------------------------------------------------------------------------
  HOW TO USE

  1. Open this in SSMS ON THE OLD SERVER (VM0810).
     Pick the database in the dropdown at the top left.

  2. Change the four lines in the SETTINGS block below.

  3. Press Execute (F5).

  4. Click the MESSAGES tab (not Results). A complete, ready-to-run script
     appears there. Select it all, copy it.

  5. Open a new query window ON THE NEW SERVER (VM1535), same database,
     paste, read it, and press Execute.

  Do one table at a time, parents before children.

  ---------------------------------------------------------------------------
  WHAT THE GENERATED SCRIPT DOES FOR YOU

    * It skips computed columns and rowversion columns automatically.
      SQL Server fills those in itself and refuses the insert otherwise.

    * It handles NULLs, dates, decimals, GUIDs, binary data and Danish
      characters correctly. Apostrophes inside text are escaped, so a name
      like O'Brien will not break the script.

    * It switches IDENTITY_INSERT on and off around the insert when the
      table has an automatic ID column.

    * Every row is guarded with NOT EXISTS on the key you choose, so running
      the generated script twice does NOT create duplicates. If you are
      unsure whether something already went across, just run it again.

  ---------------------------------------------------------------------------
  IMPORTANT - THE ID NUMBER TRAP

  If the table has an automatic ID column, read this.

  Both servers have been handing out ID numbers since 30 July. The old server
  may have given number 11 to a real customer while the new server gave the
  same number 11 to a different record. If you use ID as the key below, the
  generated script will treat the new server's row as "already there" and
  quietly skip your real customer.

  So: where the table has a real business value - an order number, a
  subscription id, an e-mail address, a GUID - use THAT as @KeyColumns
  rather than the ID.

  Run 02_check_gap_and_collisions.sql on both servers first. It tells you
  exactly which tables are affected. For most tables there is no problem and
  the ID is a perfectly good key.

  ---------------------------------------------------------------------------
  SIZE

  This route is comfortable up to a few thousand rows per table. Beyond that
  the generated text gets unwieldy and the bcp route (scripts 03 to 06) is
  the better tool. @MaxRows below stops it running away with you.
===========================================================================*/

/* Needed because this script uses the XML .value() method. SSMS normally has
   these on already; setting them explicitly means it also works if you ever
   run it through sqlcmd or a scheduled job. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;

/*===========================================================================
  SETTINGS - change these four, then press F5
===========================================================================*/

DECLARE @Schema     sysname       = 'dbo';
DECLARE @Table      sysname       = 'VIPsubscriptions';

/* Which rows to take. Leave as '' to take the whole table. */
DECLARE @Where      nvarchar(max) = '[Created] >= ''2026-07-30''';

/* How to recognise a row we already have. Prefer a business value over ID. */
DECLARE @KeyColumns nvarchar(500) = 'OrderID';

/* 1 = keep the original ID numbers from the old server (the normal case).
   0 = leave the ID out and let the new server allocate fresh numbers.
       Use 0 when 02_check_gap_and_collisions.sql showed this table has rows
       created on BOTH servers since 30 July. See the note at the bottom
       about what to do with child tables afterwards. */
DECLARE @KeepIdentity bit         = 1;

/* Safety stop, so a huge table cannot run away with you. */
DECLARE @MaxRows    int           = 5000;

/*===========================================================================
  From here down, nothing needs changing.
===========================================================================*/

DECLARE @target      nvarchar(300) = QUOTENAME(@Schema) + '.' + QUOTENAME(@Table),
        @identityCol sysname,
        @colList     nvarchar(max),
        @selList     nvarchar(max),
        @valExpr     nvarchar(max),
        @pred        nvarchar(max),
        @orderBy     nvarchar(300),
        @sql         nvarchar(max),
        @rowCount    int,
        @msg         nvarchar(1000);

IF OBJECT_ID(@target) IS NULL
BEGIN
    RAISERROR('Table %s does not exist in this database. Check the dropdown at the top left.', 16, 1, @target);
    RETURN;
END

SELECT @identityCol = c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(@target) AND c.is_identity = 1;

/*--- the columns we can actually insert ------------------------------------*/
SELECT @colList = STUFF((
    SELECT ', ' + QUOTENAME(c.name)
    FROM sys.columns c
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(@target)
      AND c.is_computed = 0
      AND ty.name <> 'timestamp'
      AND NOT (@KeepIdentity = 0 AND c.is_identity = 1)
    ORDER BY c.column_id
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

SELECT @selList = STUFF((
    SELECT ', s.' + QUOTENAME(c.name)
    FROM sys.columns c
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(@target)
      AND c.is_computed = 0
      AND ty.name <> 'timestamp'
      AND NOT (@KeepIdentity = 0 AND c.is_identity = 1)
    ORDER BY c.column_id
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

/*--- build the expression that turns each row into a literal ---------------
  Each column becomes a piece of text: a quoted string, a number, a date in
  the unambiguous yyyy-mm-ddThh:mi:ss form, 0x hex for binary, or NULL.    */
SELECT @valExpr = STUFF((
    SELECT ' + '', '' + ' +
           'CASE WHEN ' + QUOTENAME(c.name) + ' IS NULL THEN ''NULL'' ELSE ' +
           CASE
             WHEN ty.name IN ('char','varchar','text','nchar','nvarchar','ntext','sysname','xml')
               THEN '''N'''''' + REPLACE(CAST(' + QUOTENAME(c.name) + ' AS nvarchar(max)), '''''''', '''''''''''') + '''''''''
             WHEN ty.name IN ('binary','varbinary','image')
               THEN 'CONVERT(varchar(max), ' + QUOTENAME(c.name) + ', 1)'
             WHEN ty.name IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
               THEN ''''''''' + CONVERT(varchar(33), ' + QUOTENAME(c.name) + ', 126) + '''''''''
             WHEN ty.name = 'time'
               THEN ''''''''' + CONVERT(varchar(16), ' + QUOTENAME(c.name) + ', 114) + '''''''''
             WHEN ty.name = 'uniqueidentifier'
               THEN ''''''''' + CONVERT(varchar(36), ' + QUOTENAME(c.name) + ') + '''''''''
             WHEN ty.name = 'bit'
               THEN 'CONVERT(varchar(1), CONVERT(tinyint, ' + QUOTENAME(c.name) + '))'
             WHEN ty.name IN ('float','real')
               THEN 'CONVERT(varchar(50), ' + QUOTENAME(c.name) + ', 3)'
             WHEN ty.name IN ('money','smallmoney')
               THEN 'CONVERT(varchar(50), ' + QUOTENAME(c.name) + ', 2)'
             WHEN ty.name IN ('tinyint','smallint','int','bigint','decimal','numeric')
               THEN 'CONVERT(varchar(50), ' + QUOTENAME(c.name) + ')'
             ELSE '''N'''''' + REPLACE(CAST(' + QUOTENAME(c.name) + ' AS nvarchar(max)), '''''''', '''''''''''') + '''''''''
           END + ' END'
    FROM sys.columns c
    JOIN sys.types ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(@target)
      AND c.is_computed = 0
      AND ty.name <> 'timestamp'
      AND NOT (@KeepIdentity = 0 AND c.is_identity = 1)
    ORDER BY c.column_id
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 10, '');   /* 10 = length of the " + ', ' + " separator */

/*--- the duplicate guard ---------------------------------------------------*/
;WITH k AS (
    SELECT LTRIM(RTRIM(n.x.value('.', 'nvarchar(128)'))) AS colName
    FROM (SELECT CAST('<i>' + REPLACE(@KeyColumns, ',', '</i><i>') + '</i>' AS xml) AS d) src
    CROSS APPLY src.d.nodes('/i') AS n(x)
)
SELECT @pred = STUFF((
    SELECT ' AND t.' + QUOTENAME(colName) + ' = s.' + QUOTENAME(colName)
    FROM k WHERE colName <> ''
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 5, '');

IF @pred IS NULL
BEGIN
    RAISERROR('Could not read a key from @KeyColumns. Put a column name in it.', 16, 1);
    RETURN;
END

/*--- a stable order, so batches do not overlap or miss rows ----------------*/
SET @orderBy = COALESCE(QUOTENAME(@identityCol),
                        QUOTENAME((SELECT TOP 1 c.name
                                   FROM sys.indexes i
                                   JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                   WHERE i.object_id = OBJECT_ID(@target) AND i.is_primary_key = 1
                                   ORDER BY ic.key_ordinal)),
                        QUOTENAME((SELECT TOP 1 c.name FROM sys.columns c
                                   WHERE c.object_id = OBJECT_ID(@target) ORDER BY c.column_id)));

/*--- how many rows are we talking about? -----------------------------------*/
SET @sql = N'SELECT @n = COUNT(*) FROM ' + @target +
           CASE WHEN LTRIM(RTRIM(@Where)) = '' THEN N'' ELSE N' WHERE ' + @Where END + N';';
EXEC sp_executesql @sql, N'@n int OUTPUT', @n = @rowCount OUTPUT;

PRINT '/*';
SET @msg = '  ' + @target + ' - ' + CAST(@rowCount AS varchar(20)) + ' row(s) match.';
PRINT @msg;
SET @msg = '  Key used to avoid duplicates: ' + @KeyColumns;
PRINT @msg;
IF @identityCol IS NOT NULL
BEGIN
    SET @msg = '  Automatic ID column: ' + @identityCol +
               CASE WHEN @KeepIdentity = 1 THEN ' (original ID numbers kept)'
                    ELSE ' (LEFT OUT - the new server will allocate fresh ID numbers)' END;
    PRINT @msg;
    IF @KeepIdentity = 1 AND REPLACE(LTRIM(RTRIM(@KeyColumns)), ' ', '') = @identityCol
    BEGIN
        PRINT '';
        PRINT '  !! You are using the automatic ID as the key. That is fine ONLY if';
        PRINT '     the new server has not created its own rows in this table since';
        PRINT '     30 July. Check with 02_check_gap_and_collisions.sql first -';
        PRINT '     otherwise a real record can be silently skipped.';
    END
END
PRINT '*/';
PRINT '';

IF @rowCount = 0
BEGIN
    PRINT '-- Nothing to do: no rows match that WHERE clause.';
    RETURN;
END

IF @rowCount > @MaxRows
BEGIN
    SET @msg = 'That is ' + CAST(@rowCount AS varchar(20)) + ' rows, more than the @MaxRows limit of ' +
               CAST(@MaxRows AS varchar(20)) + '. Either raise @MaxRows, narrow the WHERE clause, or use the bcp route.';
    RAISERROR(@msg, 16, 1);
    RETURN;
END

/*--- emit the script, 200 rows per INSERT ----------------------------------*/
PRINT '-- ==========================================================';
SET @msg = '-- ' + @target + ' - generated on the OLD server, run this on the NEW server';
PRINT @msg;
PRINT '-- ==========================================================';
PRINT 'BEGIN TRANSACTION;';
PRINT '';

DECLARE @offset int = 0, @batch int = 200, @out nvarchar(max);

WHILE @offset < @rowCount
BEGIN
    SET @sql = N'SELECT @o = STUFF((SELECT '' ,'' + CHAR(13) + CHAR(10) + ''('' + ' + @valExpr + N' + '')'' ' +
               N'FROM (SELECT * FROM ' + @target +
               CASE WHEN LTRIM(RTRIM(@Where)) = '' THEN N'' ELSE N' WHERE ' + @Where END +
               N' ORDER BY ' + @orderBy + N' OFFSET ' + CAST(@offset AS nvarchar(20)) +
               N' ROWS FETCH NEXT ' + CAST(@batch AS nvarchar(20)) + N' ROWS ONLY) AS q ' +
               N'FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 4, '''');';

    EXEC sp_executesql @sql, N'@o nvarchar(max) OUTPUT', @o = @out OUTPUT;

    IF @out IS NOT NULL
    BEGIN
        IF @identityCol IS NOT NULL AND @KeepIdentity = 1
        BEGIN
            SET @msg = 'SET IDENTITY_INSERT ' + @target + ' ON;';
            PRINT @msg;
        END

        SET @msg = 'INSERT INTO ' + @target + ' (' + @colList + ')';
        PRINT @msg;
        SET @msg = 'SELECT ' + @selList;
        PRINT @msg;
        PRINT 'FROM (VALUES';

        /* PRINT only shows 4000 characters at a time, so feed it in slices */
        DECLARE @i int = 1, @len int = LEN(@out);
        WHILE @i <= @len
        BEGIN
            PRINT SUBSTRING(@out, @i, 4000);
            SET @i = @i + 4000;
        END

        SET @msg = ') AS s (' + @colList + ')';
        PRINT @msg;
        SET @msg = 'WHERE NOT EXISTS (SELECT 1 FROM ' + @target + ' AS t WHERE ' + @pred + ');';
        PRINT @msg;

        IF @identityCol IS NOT NULL AND @KeepIdentity = 1
        BEGIN
            SET @msg = 'SET IDENTITY_INSERT ' + @target + ' OFF;';
            PRINT @msg;
        END
        PRINT '';
    END

    SET @offset = @offset + @batch;
END

PRINT '-- Check the number below looks right, then COMMIT.';
SET @msg = 'SELECT COUNT(*) AS RowsNowInTable FROM ' + @target + ';';
PRINT @msg;
PRINT '';
PRINT 'COMMIT TRANSACTION;    -- or ROLLBACK TRANSACTION; if it looks wrong';
