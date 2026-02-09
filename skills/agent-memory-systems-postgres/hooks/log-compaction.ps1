Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonlLine {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Obj
  )

  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  ($Obj | ConvertTo-Json -Compress) + "`n" | Out-File -LiteralPath $Path -Append -Encoding ascii
}

function Get-FileTailBytes {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MaxBytes = 8192
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return [byte[]]@()
  }

  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $len = $fs.Length
    $readLen = [Math]::Min($MaxBytes, [int]$len)
    if ($readLen -le 0) { return [byte[]]@() }
    $fs.Seek(-1 * $readLen, [System.IO.SeekOrigin]::End) | Out-Null
    $buf = New-Object byte[] $readLen
    $n = $fs.Read($buf, 0, $readLen)
    if ($n -lt $readLen) { return $buf[0..($n-1)] }
    return $buf
  } finally {
    $fs.Dispose()
  }
}

function Resolve-PsqlPath {
  $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    return $cmd.Source
  }

  $candidates = @(
    'C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\17\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\16\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\15\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\14\\bin\\psql.exe'
  )

  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Try-GetPropString {
  param(
    [Parameter(Mandatory = $false)]$Obj,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $false)][AllowEmptyString()][AllowNull()][string]$Default = ''
  )

  if ($null -eq $Obj) { return $Default }
  $prop = $Obj.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $Default }
  if ($null -eq $prop.Value) { return $Default }
  return [string]$prop.Value
}

$raw = [Console]::In.ReadToEnd()
$payload = $null
try {
  if ($raw -and $raw.Trim().Length -gt 0) {
    $payload = $raw | ConvertFrom-Json
  }
} catch {
  $payload = $null
}

$sessionId = Try-GetPropString -Obj $payload -Name 'session_id' -Default ''
if (-not $sessionId) {
  $sessionId = Try-GetPropString -Obj $payload -Name 'sessionID' -Default 'unknown'
}

$trigger = Try-GetPropString -Obj $payload -Name 'trigger' -Default 'unknown'
$cwd = Try-GetPropString -Obj $payload -Name 'cwd' -Default ''

$transcriptPath = Try-GetPropString -Obj $payload -Name 'transcript_path' -Default ''
if (-not $transcriptPath) {
  $transcriptPath = Try-GetPropString -Obj $payload -Name 'transcriptPath' -Default ''
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$tailBytes = if ($transcriptPath) { Get-FileTailBytes -Path $transcriptPath -MaxBytes 8192 } else { [byte[]]@() }
if ($null -eq $tailBytes) {
  $tailBytes = [byte[]]@()
} else {
  $tailBytes = [byte[]]$tailBytes
}

$tailB64 = if ($tailBytes.Length -gt 0) { [Convert]::ToBase64String($tailBytes) } else { '' }

$logPath = Join-Path $env:USERPROFILE '.claude\compaction-events.jsonl'
Write-JsonlLine -Path $logPath -Obj @{
  event = 'PreCompact'
  time_utc = $timestamp
  session_id = $sessionId
  trigger = $trigger
  cwd = $cwd
  transcript_path = $transcriptPath
  transcript_tail_b64 = $tailB64
}

$psql = Resolve-PsqlPath
if (-not $psql) {
  exit 0
}

$sql = @'
WITH t AS (
  SELECT
    CASE
      WHEN length(:'tail_b64') > 0
      THEN convert_from(decode(:'tail_b64', 'base64'), 'UTF8')
      ELSE ''
    END AS tail
)
SELECT store_memory(
  'episodic',
  'compaction',
  ARRAY['compaction', :'trigger'],
  'Compaction ' || :'session_id' || ' ' || :'timestamp',
  'trigger=' || :'trigger' || E'\n'
    || 'cwd=' || :'cwd' || E'\n'
    || 'transcript_path=' || :'transcript_path' || E'\n\n'
    || (SELECT tail FROM t),
  jsonb_build_object(
    'session_id', :'session_id',
    'trigger', :'trigger',
    'timestamp_utc', :'timestamp',
    'cwd', :'cwd',
    'transcript_path', :'transcript_path',
    'source', 'claude-hook-precompact'
  ),
  'claude-hook',
  :'session_id',
  7.0
);
'@

try {
  & $psql -w -h 'localhost' -p '5432' -U 'postgres' -d 'agent_memory' -v 'ON_ERROR_STOP=1' `
    -v ("session_id=$sessionId") `
    -v ("trigger=$trigger") `
    -v ("timestamp=$timestamp") `
    -v ("cwd=$cwd") `
    -v ("transcript_path=$transcriptPath") `
    -v ("tail_b64=$tailB64") `
    -c $sql 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "psql failed with exit code $LASTEXITCODE"
  }
} catch {
  Write-JsonlLine -Path $logPath -Obj @{
    event = 'PreCompactError'
    time_utc = $timestamp
    session_id = $sessionId
    error = $_.Exception.Message
  }
}

exit 0
