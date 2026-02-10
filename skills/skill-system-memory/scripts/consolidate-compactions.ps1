Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$opencodeDir = Join-Path $env:USERPROFILE '.config\opencode\skill-system-memory'
$opencodeEvents = Join-Path $opencodeDir 'compaction-events.jsonl'
$claudeEvents = Join-Path $env:USERPROFILE '.claude\compaction-events.jsonl'

$eventsPath = $opencodeEvents
if (-not (Test-Path -LiteralPath $eventsPath)) {
  $eventsPath = $claudeEvents
}
if (-not (Test-Path -LiteralPath $eventsPath)) { exit 0 }

$lines = Get-Content -LiteralPath $eventsPath -ErrorAction Stop
$events = @()
foreach ($line in $lines) {
  $t = $line.Trim()
  if (-not $t) { continue }
  try {
    $obj = $t | ConvertFrom-Json
    if (-not $obj) { continue }
    if (-not $obj.time_utc) { continue }
    if ($obj.event -in @('session.compacting', 'PreCompact')) { $events += $obj }
  } catch { }
}

if ($events.Count -eq 0) { exit 0 }

$groups = $events | Group-Object {
  try { ([DateTime]::Parse($_.time_utc)).ToUniversalTime().ToString('yyyy-MM-dd') } catch { 'unknown' }
}

$outDir = Join-Path $opencodeDir 'compaction-daily'
if ($eventsPath -eq $claudeEvents) {
  $outDir = Join-Path $env:USERPROFILE '.claude\compaction-daily'
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$psql = Resolve-PsqlPath

foreach ($g in $groups) {
  $day = [string]$g.Name
  $items = @($g.Group)
  $count = $items.Count
  $sessions = @($items | ForEach-Object { $_.session_id } | Where-Object { $_ } | Select-Object -Unique)
  $triggers = @($items | ForEach-Object { $_.trigger } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending)
  $triggerSummary = if ($triggers.Count -gt 0) { ($triggers | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ' } else { 'unknown' }
  $sessionSummary = if ($sessions.Count -gt 0) { $sessions -join ', ' } else { 'unknown' }
  $summaryText = "date_utc=$day`ncount=$count`ntriggers=$triggerSummary`nsessions=$sessionSummary`n"
  $contentB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($summaryText))

  (Join-Path $outDir ("$day.txt")) | Out-Null
  $summaryText | Out-File -LiteralPath (Join-Path $outDir ("$day.txt")) -Encoding ascii

  if (-not $psql) { continue }

  $sql = @'
WITH payload AS (
  SELECT convert_from(decode(:'content_b64', 'base64'), 'UTF8') AS content
)
SELECT store_memory(
  'semantic',
  'compaction-daily',
  ARRAY['compaction','daily'],
  'Compaction Daily Summary ' || :'day',
  (SELECT content FROM payload),
  jsonb_build_object('date_utc', :'day', 'count', :'count', 'triggers', :'triggers', 'source', 'consolidate-compactions.ps1'),
  'opencode-maintenance',
  NULL,
  6.5
);
'@

  try {
    & $psql -w -h 'localhost' -p '5432' -U 'postgres' -d 'agent_memory' -v 'ON_ERROR_STOP=1' `
      -v ("day=$day") `
      -v ("count=$count") `
      -v ("triggers=$triggerSummary") `
      -v ("content_b64=$contentB64") `
      -c $sql 1>$null 2>$null
  } catch { }
}

exit 0
