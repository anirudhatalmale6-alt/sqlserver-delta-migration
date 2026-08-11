<#
================================================================================
 04_import_to_staging.ps1
 RUN ON: the NEW server (VM1535), or any Windows machine that can reach it.
 DOES:   Loads every .dat file into a STAGING copy of the table, in a separate
         schema called  stg.  It does NOT touch your real tables yet.

         stg.Members  is a scratch copy of  dbo.Members , and nothing reads it
         except the merge script. If anything looks wrong you just drop the
         stg schema and start again - your live data is never at risk in this
         step.

 EXAMPLE
   .\04_import_to_staging.ps1 -Server "VM1535" -Database "DatingTid" `
                              -User "your_sql_login" -Password "xxxx" `
                              -InDir "D:\delta\DatingTid"

 If you get an SSL or certificate error, add  -TrustServerCert
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Server,
    [Parameter(Mandatory=$true)][string]$Database,
    [string]$User,
    [string]$Password,
    [Parameter(Mandatory=$true)][string]$InDir,
    [string]$BcpPath = "bcp",
    [switch]$TrustServerCert
)

$ErrorActionPreference = "Stop"

if ($User) {
    $connStr = "Server=$Server;Database=$Database;User ID=$User;Password=$Password;TrustServerCertificate=True;"
    $bcpAuth = @("-U", $User, "-P", $Password)
} else {
    $connStr = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
    $bcpAuth = @("-T")
}
if ($TrustServerCert) { $bcpAuth += "-u" }

function Invoke-NonQuery {
    param([string]$Sql, [hashtable]$Parameters)
    $cn = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 0
        if ($Parameters) { foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) } }
        [void]$cmd.ExecuteNonQuery()
    } finally { $cn.Close() }
}

function Invoke-Scalar {
    param([string]$Sql, [hashtable]$Parameters)
    $cn = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 0
        if ($Parameters) { foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) } }
        return $cmd.ExecuteScalar()
    } finally { $cn.Close() }
}

$logFile = Join-Path $InDir "import_log.txt"
"=== Import to staging started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') into $Server / $Database ===" | Out-File $logFile -Encoding UTF8
function Log { param([string]$m) Write-Host $m; $m | Out-File $logFile -Append -Encoding UTF8 }

# ---------- staging schema + config table -------------------------------------
Invoke-NonQuery "IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');"
Invoke-NonQuery @"
IF OBJECT_ID('stg.__MergeConfig') IS NULL
CREATE TABLE stg.__MergeConfig (
    SchemaName   sysname       NOT NULL,
    TableName    sysname       NOT NULL,
    KeyColumns   nvarchar(500) NULL,
    KeepIdentity bit           NOT NULL DEFAULT 1,
    StagedRows   bigint        NULL,
    LoadedAt     datetime      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK___MergeConfig PRIMARY KEY (SchemaName, TableName)
);
"@

$manifestPath = Join-Path $InDir "manifest.csv"
if (-not (Test-Path $manifestPath)) { throw "manifest.csv not found in $InDir - run 03_export_delta.ps1 first." }
$rows = Import-Csv -Path $manifestPath -Delimiter ';'
Log "Tables in manifest: $($rows.Count)"

$failed = 0

foreach ($r in $rows) {
    $schema = ([string]$r.Schema).Trim()
    $table  = ([string]$r.Table).Trim()
    if ($schema -eq "" -or $table -eq "") { continue }
    $datFile  = Join-Path $InDir $r.File
    $colsFile = Join-Path $InDir "$schema.$table.cols"

    Log ""
    Log "--- [$schema].[$table]"

    if (-not (Test-Path $datFile))  { Log "  !! missing $datFile - SKIPPED";  $failed++; continue }
    if (-not (Test-Path $colsFile)) { Log "  !! missing $colsFile - SKIPPED"; $failed++; continue }

    $colList = (Get-Content $colsFile -Raw).Trim()

    # Build an empty staging table with EXACTLY the exported columns, in the
    # exported order. If a column is missing on this server the next line
    # fails loudly - which is what we want, it means the schemas differ.
    $stgName = "$schema" + "_" + "$table"
    $drop = "IF OBJECT_ID('stg.[$stgName]') IS NOT NULL DROP TABLE stg.[$stgName];"
    $make = "SELECT TOP 0 $colList INTO stg.[$stgName] FROM [$schema].[$table];"
    try {
        Invoke-NonQuery $drop
        Invoke-NonQuery $make
    } catch {
        Log "  !! could not create staging table: $($_.Exception.Message)"
        $failed++
        continue
    }

    # -E keeps the original identity values from the file instead of letting
    # this server invent new ones. We need the originals in staging so the
    # merge step can decide what to do with them.
    $args = @("$Database.stg.$stgName", "in", $datFile, "-N", "-E", "-q", "-S", $Server) + $bcpAuth
    & $BcpPath @args 2>&1 | ForEach-Object { Log "  bcp   : $_" }

    if ($LASTEXITCODE -ne 0) {
        Log "  !! bcp FAILED with exit code $LASTEXITCODE"
        $failed++
        continue
    }

    $cnt = Invoke-Scalar "SELECT COUNT_BIG(*) FROM stg.[$stgName];"
    Log "  ok    : $cnt row(s) staged into stg.[$stgName]"

    $keep = 1
    if ($r.KeepIdentity -eq "0") { $keep = 0 }

    Invoke-NonQuery @"
MERGE stg.__MergeConfig AS t
USING (SELECT @s AS SchemaName, @t AS TableName) AS s
   ON t.SchemaName = s.SchemaName AND t.TableName = s.TableName
WHEN MATCHED THEN UPDATE SET KeyColumns = @k, KeepIdentity = @i, StagedRows = @c, LoadedAt = GETDATE()
WHEN NOT MATCHED THEN INSERT (SchemaName, TableName, KeyColumns, KeepIdentity, StagedRows)
                      VALUES (@s, @t, @k, @i, @c);
"@ @{ "@s" = $schema; "@t" = $table; "@k" = [string]$r.KeyColumns; "@i" = $keep; "@c" = $cnt }
}

Log ""
Log "=== Finished. $failed failure(s). ==="
Log "Nothing has been written to your real tables yet."
Log "Next: run 05_generate_merge_sql.sql and read what it produces."

if ($failed -gt 0) { exit 1 }
