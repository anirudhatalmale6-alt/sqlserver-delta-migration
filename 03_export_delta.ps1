<#
================================================================================
 03_export_delta.ps1
 RUN ON: the OLD server (VM0810), or any Windows machine that can reach it.
 DOES:   Reads the tables listed in tables.csv and writes one .dat file per
         table into the output folder. READ ONLY - it never writes to the
         old database.

 The .dat files are in SQL Server "native" format. That matters: it means
 Danish characters (ae, oe, aa) and decimal amounts survive exactly as they
 are. A CSV export would risk mangling them.

 EXAMPLE
   .\03_export_delta.ps1 -Server "VM0810" -Database "DatingTid" `
                         -User "your_sql_login" -Password "xxxx" `
                         -ConfigFile ".\tables.csv" -OutDir "D:\delta\DatingTid"

 For a trusted Windows login leave out -User and -Password.
 If you get an SSL or certificate error, add  -TrustServerCert
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Server,
    [Parameter(Mandatory=$true)][string]$Database,
    [string]$User,
    [string]$Password,
    [string]$ConfigFile = ".\tables.csv",
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$BcpPath = "bcp",
    [switch]$TrustServerCert
)

$ErrorActionPreference = "Stop"

# ---------- connection helpers -------------------------------------------------
if ($User) {
    $connStr  = "Server=$Server;Database=$Database;User ID=$User;Password=$Password;TrustServerCertificate=True;"
    $bcpAuth  = @("-U", $User, "-P", $Password)
} else {
    $connStr  = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
    $bcpAuth  = @("-T")
}
if ($TrustServerCert) { $bcpAuth += "-u" }

function Invoke-Scalar-List {
    param([string]$Sql, [hashtable]$Parameters)
    $out = New-Object System.Collections.Generic.List[string]
    $cn = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = $Sql
        if ($Parameters) { foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) } }
        $rd = $cmd.ExecuteReader()
        while ($rd.Read()) { $out.Add($rd.GetString(0)) }
        $rd.Close()
    } finally { $cn.Close() }
    return $out
}

# ---------- start --------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$logFile = Join-Path $OutDir "export_log.txt"
"=== Export started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') from $Server / $Database ===" | Out-File $logFile -Encoding UTF8

function Log { param([string]$m) Write-Host $m; $m | Out-File $logFile -Append -Encoding UTF8 }

$rows = Import-Csv -Path $ConfigFile -Delimiter ';'
$realRows = @($rows | Where-Object { -not ([string]$_.Schema).Trim().StartsWith("#") -and ([string]$_.Table).Trim() -ne "" })
Log "Tables to export: $($realRows.Count)"

$manifest = New-Object System.Collections.Generic.List[object]
$failed   = 0

foreach ($r in $rows) {
    # Cast through [string] first: a commented-out or short line leaves some of
    # these fields empty, and calling .Trim() on nothing throws.
    $schema = ([string]$r.Schema).Trim()
    $table  = ([string]$r.Table).Trim()
    $where  = ([string]$r.WhereClause).Trim()

    if ($schema.StartsWith("#")) { continue }   # allow commented-out lines
    if ([string]::IsNullOrWhiteSpace($schema) -or [string]::IsNullOrWhiteSpace($table)) { continue }

    $full = "[$schema].[$table]"
    Log ""
    Log "--- $full"

    # Columns we are allowed to insert later: skip computed columns and
    # rowversion/timestamp columns, because SQL Server generates those itself.
    $colSql = @"
SELECT c.name
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(@t)
  AND c.is_computed = 0
  AND ty.name <> 'timestamp'
ORDER BY c.column_id
"@
    $cols = Invoke-Scalar-List -Sql $colSql -Parameters @{ "@t" = "$schema.$table" }
    if ($cols.Count -eq 0) { Log "  !! table not found or has no copyable columns - SKIPPED"; $failed++; continue }

    $colList = ($cols | ForEach-Object { "[$_]" }) -join ", "

    # NOTE: the query must not contain double-quote characters, otherwise the
    # command line handed to bcp.exe gets broken up in the wrong place.
    $query = "SELECT $colList FROM $full"
    if ($where -ne "") { $query += " WHERE $where" }

    $datFile  = Join-Path $OutDir "$schema.$table.dat"
    $colsFile = Join-Path $OutDir "$schema.$table.cols"
    $colList | Out-File $colsFile -Encoding UTF8 -NoNewline

    $args = @($query, "queryout", $datFile, "-N", "-q", "-S", $Server, "-d", $Database) + $bcpAuth
    Log "  query : $query"

    & $BcpPath @args 2>&1 | ForEach-Object { Log "  bcp   : $_" }

    if ($LASTEXITCODE -ne 0) {
        Log "  !! bcp FAILED with exit code $LASTEXITCODE"
        $failed++
        continue
    }

    $size = (Get-Item $datFile).Length
    Log "  ok    : $datFile ($size bytes)"
    $manifest.Add([pscustomobject]@{
        Schema       = $schema
        Table        = $table
        WhereClause  = $where
        KeyColumns   = $r.KeyColumns
        KeepIdentity = $r.KeepIdentity
        File         = "$schema.$table.dat"
        Bytes        = $size
    })
}

$manifest | Export-Csv -Path (Join-Path $OutDir "manifest.csv") -Delimiter ';' -NoTypeInformation -Encoding UTF8

Log ""
Log "=== Finished. Exported $($manifest.Count) table(s), $failed failure(s). ==="
Log "Now copy the whole folder $OutDir to the new server and run 04_import_to_staging.ps1"

if ($failed -gt 0) { exit 1 }
