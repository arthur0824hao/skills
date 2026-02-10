param(
  [Parameter(Position=0)][string]$Command = 'ready',
  [Parameter(Position=1)][string]$Arg1,
  [Parameter(Position=2)][string]$Arg2,
  [Parameter(Position=3)][string]$Arg3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)
  return ($Value -replace "'", "''")
}

function Psql-Query {
  param([Parameter(Mandatory = $true)][string]$Sql)
  $psql = Resolve-PsqlPath
  if (-not $psql) { throw 'psql.exe not found (install PostgreSQL or add psql to PATH)' }

  $pgHost = if ($env:PGHOST) { $env:PGHOST } else { 'localhost' }
  $pgPort = if ($env:PGPORT) { $env:PGPORT } else { '5432' }
  $pgDb = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'agent_memory' }
  $pgUser = if ($env:PGUSER) { $env:PGUSER } else { 'postgres' }

  & $psql -w -h $pgHost -p $pgPort -U $pgUser -d $pgDb -v 'ON_ERROR_STOP=1' -t -A -c $Sql
}

function Usage {
  @'
Usage:
  scripts\tasks.ps1 ready [limit]
  scripts\tasks.ps1 create <title> [priority]
  scripts\tasks.ps1 block <blocker_id> <blocked_id>
  scripts\tasks.ps1 parent <parent_id> <child_id>
  scripts\tasks.ps1 claim <task_id> <assignee>
  scripts\tasks.ps1 link-mem <task_id> <memory_id> [link_type]
  scripts\tasks.ps1 rebuild
'@
}

$cmd = if ($null -eq $Command) { '' } else { [string]$Command }
$cmd = $cmd.Trim().ToLowerInvariant()
switch ($cmd) {
  'ready' {
    $limit = 50
    if ($Arg1) { $limit = [int]$Arg1 }
    $sql = @"
SELECT id || E'\t' || priority || E'\t' || status || E'\t' || coalesce(assignee,'') || E'\t' || title
FROM agent_tasks t
WHERE t.deleted_at IS NULL
  AND t.status IN ('open','in_progress')
  AND NOT EXISTS (SELECT 1 FROM blocked_tasks_cache b WHERE b.task_id = t.id)
ORDER BY priority ASC, updated_at ASC
LIMIT $limit;
"@
    Psql-Query -Sql $sql
    exit 0
  }

  'create' {
    if (-not $Arg1) { Usage; exit 2 }
    $title = Escape-SqlLiteral -Value $Arg1
    $prio = 2
    if ($Arg2) { $prio = [int]$Arg2 }
    $sql = "INSERT INTO agent_tasks(title, created_by, priority) VALUES ('$title', 'user', $prio) RETURNING id;"
    Psql-Query -Sql $sql
    exit 0
  }

  'block' {
    if (-not $Arg1 -or -not $Arg2) { Usage; exit 2 }
    $sql = "INSERT INTO task_links(from_task_id,to_task_id,link_type) VALUES ($Arg1,$Arg2,'blocks') ON CONFLICT DO NOTHING;"
    Psql-Query -Sql $sql
    exit 0
  }

  'parent' {
    if (-not $Arg1 -or -not $Arg2) { Usage; exit 2 }
    $sql = "INSERT INTO task_links(from_task_id,to_task_id,link_type) VALUES ($Arg1,$Arg2,'parent_child') ON CONFLICT DO NOTHING;"
    Psql-Query -Sql $sql
    exit 0
  }

  'claim' {
    if (-not $Arg1 -or -not $Arg2) { Usage; exit 2 }
    $assignee = Escape-SqlLiteral -Value $Arg2
    $sql = "SELECT claim_task($Arg1, '$assignee');"
    Psql-Query -Sql $sql
    exit 0
  }

  'link-mem' {
    if (-not $Arg1 -or -not $Arg2) { Usage; exit 2 }
    $lt = if ($Arg3) { Escape-SqlLiteral -Value $Arg3 } else { 'supports' }
    $sql = "INSERT INTO task_memory_links(task_id,memory_id,link_type) VALUES ($Arg1,$Arg2,'$lt') ON CONFLICT DO NOTHING;"
    Psql-Query -Sql $sql
    exit 0
  }

  'rebuild' {
    Psql-Query -Sql 'SELECT rebuild_blocked_tasks_cache();'
    exit 0
  }

  default {
    Usage
    exit 2
  }
}
