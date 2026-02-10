param(
  [Parameter(Position=0)][string]$Command = 'types',
  [Parameter(Position=1)][string]$Arg1,
  [Parameter(Position=2)][string]$Arg2,
  [Parameter(Position=3)][string]$Arg3,
  [Parameter(Position=4)][string]$Arg4,
  [Parameter(Position=5)][string]$Arg5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail-Json {
  param([Parameter(Mandatory=$true)][string]$Message)
  $obj = @{
    status = 'error'
    summary = $Message
    errors = @(@{ code = 'MEM_ROUTER_ADAPTER'; message = $Message })
    artifacts = @()
    metrics = @{}
  }
  ($obj | ConvertTo-Json -Depth 10 -Compress)
  exit 1
}

function Resolve-PsqlPath {
  $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $candidates = @(
    'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    'C:\Program Files\PostgreSQL\17\bin\psql.exe',
    'C:\Program Files\PostgreSQL\16\bin\psql.exe',
    'C:\Program Files\PostgreSQL\15\bin\psql.exe',
    'C:\Program Files\PostgreSQL\14\bin\psql.exe'
  )
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}

function Psql-OneJson {
  param([Parameter(Mandatory=$true)][string]$Sql)
  $psql = Resolve-PsqlPath
  if (-not $psql) { Fail-Json 'psql.exe not found (install PostgreSQL or add psql to PATH)' }
  $pgHost = if ($env:PGHOST) { $env:PGHOST } else { 'localhost' }
  $pgPort = if ($env:PGPORT) { $env:PGPORT } else { '5432' }
  $pgDb = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'agent_memory' }
  $pgUser = if ($env:PGUSER) { $env:PGUSER } else { 'postgres' }
  $out = & $psql -w -h $pgHost -p $pgPort -U $pgUser -d $pgDb -v 'ON_ERROR_STOP=1' -t -A -c $Sql
  return ($out | ForEach-Object { $_.ToString().TrimEnd("`r") } | Where-Object { $_ -ne '' } | Select-Object -First 1)
}

function Usage {
  @'
Usage:
  scripts\router_mem.ps1 types
  scripts\router_mem.ps1 health
  scripts\router_mem.ps1 search <query> [limit]
  scripts\router_mem.ps1 store <memory_type> <category> <title> [tags_csv] [importance]

Notes:
  - For store: content is read from STDIN.
  - Emits a single JSON object on stdout (for Router last-line JSON contract).
'@
}

$cmd = if ($null -eq $Command) { '' } else { $Command.Trim().ToLowerInvariant() }

switch ($cmd) {
  'types' {
    $json = Psql-OneJson -Sql "SELECT jsonb_build_object('status','ok','summary','types','results',COALESCE((SELECT jsonb_agg(x) FROM (SELECT unnest(enum_range(NULL::memory_type)) AS x) t),'[]'::jsonb))::text;"
    if (-not $json) { Fail-Json 'types query failed' }
    $json
    exit 0
  }
  'health' {
    $json = Psql-OneJson -Sql "SELECT jsonb_build_object('status','ok','summary','health','results',COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM memory_health_check() t),'[]'::jsonb))::text;"
    if (-not $json) { Fail-Json 'health query failed' }
    $json
    exit 0
  }
  'search' {
    if (-not $Arg1) { Usage; exit 2 }
    $limit = 10
    if ($Arg2) { $limit = [int]$Arg2 }
    $q = $Arg1.Replace("'", "''")
    $json = Psql-OneJson -Sql "SELECT jsonb_build_object('status','ok','summary','search','results',COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM (SELECT id, memory_type, category, title, relevance_score, match_type FROM search_memories('$q', NULL, NULL, NULL, NULL, 0.0, $limit) ORDER BY relevance_score DESC) r),'[]'::jsonb))::text;"
    if (-not $json) { Fail-Json 'search failed' }
    $json
    exit 0
  }
  'store' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Arg3) { Usage; exit 2 }
    $mtype = $Arg1
    $category = $Arg2
    $title = $Arg3
    $tags = if ($Arg4) { $Arg4 } else { '' }
    $importance = if ($Arg5) { [double]$Arg5 } else { 5.0 }

    if (-not [Console]::IsInputRedirected) { Fail-Json 'No content on stdin' }
    $content = [Console]::In.ReadToEnd()
    if (-not $content -or $content.Trim().Length -eq 0) { Fail-Json 'Empty content on stdin' }

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $mem = Join-Path $scriptDir 'mem.ps1'
    $stored = $content | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mem store $mtype $category $title $tags $importance
    $storedId = ($stored | Select-Object -Last 1).ToString().Trim()
    if (-not $storedId) { Fail-Json 'store failed' }
    $obj = @{
      status = 'ok'
      summary = 'store'
      results = @(@{ stored_id = [int64]$storedId })
      artifacts = @()
      metrics = @{}
      errors = @()
    }
    ($obj | ConvertTo-Json -Depth 10 -Compress)
    exit 0
  }
  default {
    Usage
    exit 2
  }
}
