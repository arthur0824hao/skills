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
  scripts\mem.ps1 types
  scripts\mem.ps1 health
  scripts\mem.ps1 search <query> [limit]
  scripts\mem.ps1 store <memory_type> <category> <title> [tags_csv] [importance]

Notes:
  - For store: content is read from STDIN.
    Example: "content" | scripts\mem.ps1 store semantic project "Title" "tag1,tag2" 8
'@
}

$cmd = if ($null -eq $Command) { '' } else { [string]$Command }
$cmd = $cmd.Trim().ToLowerInvariant()

switch ($cmd) {
  'types' {
    Psql-Query -Sql "SELECT unnest(enum_range(NULL::memory_type));"
    exit 0
  }

  'health' {
    Psql-Query -Sql "SELECT * FROM memory_health_check();"
    exit 0
  }

  'search' {
    if (-not $Arg1) { Usage; exit 2 }
    $limit = 10
    if ($Arg2) { $limit = [int]$Arg2 }
    $q = $Arg1.Replace("'", "''")
    Psql-Query -Sql "SELECT id, memory_type, category, title, relevance_score, match_type FROM search_memories('$q', NULL, NULL, NULL, NULL, 0.0, $limit) ORDER BY relevance_score DESC;"
    exit 0
  }

  'store' {
    if (-not $Arg1 -or -not $Arg2 -or -not $Arg3) { Usage; exit 2 }
    $mtype = $Arg1.Replace("'", "''")
    $category = $Arg2.Replace("'", "''")
    $title = $Arg3.Replace("'", "''")
    $tags = if ($Arg4) { $Arg4.Replace("'", "''") } else { '' }
    $importance = if ($Arg5) { [double]$Arg5 } else { 5.0 }

    $content = ''
    try {
      if (-not [Console]::IsInputRedirected) {
        Write-Host 'No content on stdin; abort.'
        exit 2
      }
      $content = [Console]::In.ReadToEnd()
    } catch {
      Write-Host 'Failed to read stdin.'
      exit 2
    }
    if (-not $content -or $content.Trim().Length -eq 0) {
      Write-Host 'Empty content; abort.'
      exit 2
    }

    $contentSql = $content.Replace("'", "''")
    $tagsExpr = if ($tags.Length -eq 0) { "ARRAY[]::text[]" } else { "string_to_array('$tags', ',')" }

    $sql = "SELECT store_memory('$mtype'::memory_type, '$category', $tagsExpr, '$title', '$contentSql', '{}'::jsonb, 'user', NULL, $importance);"
    Psql-Query -Sql $sql
    exit 0
  }

  default {
    Usage
    exit 2
  }
}
