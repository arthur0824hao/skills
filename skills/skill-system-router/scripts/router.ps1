param(
  [Parameter(Position=0)][string]$Command = 'run',
  [Parameter(Position=1)][string]$TaskSpecId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail-Json {
  param([Parameter(Mandatory=$true)][string]$Message)
  $obj = @{
    status = 'error'
    summary = $Message
    errors = @(@{ code = 'ROUTER_ERROR'; message = $Message })
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

function Get-TaskSpecJson {
  param([Parameter(Mandatory=$true)][string]$Id)
  return (Psql-OneJson -Sql "SELECT row_to_json(t)::text FROM (SELECT id, goal, workspace, inputs, verification, pinned_pipeline, budgets, policy_profile_id FROM skill_system.task_specs WHERE id = $Id) t;")
}

function Get-PolicyProfileJson {
  param([Parameter(Mandatory=$true)][string]$Id)
  return (Psql-OneJson -Sql "SELECT row_to_json(t)::text FROM (SELECT id, name, allowed_effects, allowed_exec, allowed_write_roots, metadata FROM skill_system.policy_profiles WHERE id = $Id) t;")
}

function Extract-ManifestBlock {
  param([Parameter(Mandatory=$true)][string]$SkillId, [Parameter(Mandatory=$true)][string]$SkillsRoot)
  $md = Join-Path (Join-Path $SkillsRoot $SkillId) 'SKILL.md'
  if (-not (Test-Path -LiteralPath $md)) { Fail-Json "Skill SKILL.md not found: $md" }
  $lines = Get-Content -LiteralPath $md -ErrorAction Stop
  $in = $false
  $buf = New-Object System.Collections.Generic.List[string]
  foreach ($l in $lines) {
    if (-not $in) {
      if ($l -match '^```router-manifest\s*$') { $in = $true; continue }
      continue
    }
    if ($l -match '^```\s*$') { break }
    $buf.Add($l)
  }
  if ($buf.Count -eq 0) { Fail-Json "Missing router-manifest block for skill '$SkillId'" }
  return ($buf -join "`n")
}

function Apply-Placeholders {
  param([Parameter(Mandatory=$true)][string]$Text, [Parameter(Mandatory=$true)]$ArgsObj)
  $s = $Text
  if ($null -eq $ArgsObj) { return $s }

  if ($ArgsObj -is [hashtable]) {
    foreach ($k in $ArgsObj.Keys) {
      $v = [string]$ArgsObj[$k]
      $s = $s.Replace("{$k}", $v)
    }
    return $s
  }

  foreach ($p in $ArgsObj.PSObject.Properties) {
    $k = [string]$p.Name
    $v = [string]$p.Value
    $s = $s.Replace("{$k}", $v)
  }
  return $s
}

function Run-Pipeline {
  param(
    [Parameter(Mandatory=$true)]$TaskObj,
    [Parameter(Mandatory=$true)]$PolicyObj,
    [Parameter(Mandatory=$true)][string]$SkillsRoot
  )

  # Keep SQL quoting simple: store an empty policy snapshot in MVP.
  $runIdLine = Psql-OneJson -Sql "INSERT INTO skill_system.runs(task_spec_id, status, started_at, effective_policy) VALUES ($($TaskObj.id), 'running', NOW(), '{}'::jsonb) RETURNING id;"
  $runId = [int64]$runIdLine
  if (-not $runId) { Fail-Json 'Failed to create run row' }

  $allowedEffects = @()
  if ($null -ne $PolicyObj -and $PolicyObj.allowed_effects) { $allowedEffects = @($PolicyObj.allowed_effects) }

  $stepIndex = 0
  $okSteps = 0
  $start = Get-Date

  foreach ($step in @($TaskObj.pinned_pipeline)) {
    $stepIndex += 1
    $skill = [string]$step.skill
    $op = [string]$step.op
    $args = $step.args

    $manifestRaw = Extract-ManifestBlock -SkillId $skill -SkillsRoot $SkillsRoot
    $manifestObj = $manifestRaw | ConvertFrom-Json -ErrorAction Stop

    if ($allowedEffects.Count -gt 0) {
      foreach ($eff in @($manifestObj.effects)) {
        if (-not ($allowedEffects -contains [string]$eff)) {
          Psql-OneJson -Sql "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='policy_blocked:$eff' WHERE id=$runId;" | Out-Null
          Fail-Json "Policy blocked effect '$eff' for step $stepIndex ($skill $op)"
        }
      }
    }

    $ep = $null
    if ($manifestObj.entrypoints -and $manifestObj.entrypoints.$op) {
      $ep = $manifestObj.entrypoints.$op.windows
    }
    if (-not $ep) {
      Psql-OneJson -Sql "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='missing_entrypoint' WHERE id=$runId;" | Out-Null
      Fail-Json "Missing entrypoint for $skill op=$op os=windows"
    }

    $argv = @()
    foreach ($a in @($ep)) {
      $argv += (Apply-Placeholders -Text ([string]$a) -ArgsObj $args)
    }

    Psql-OneJson -Sql "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($runId, 'info', 'step_started', jsonb_build_object('index',$stepIndex));" | Out-Null

    $output = ''
    $exitCode = 0
    $skillDir = Join-Path $SkillsRoot $skill
    try {
      Push-Location -LiteralPath $skillDir
      if ($argv.Count -gt 1) {
        $output = & $argv[0] @($argv[1..($argv.Count-1)]) 2>&1 | Out-String
      } else {
        $output = & $argv[0] 2>&1 | Out-String
      }
      $exitCode = $LASTEXITCODE
    } catch {
      $exitCode = 1
      $output = $_.Exception.Message
    } finally {
      try { Pop-Location } catch { }
    }

    $lines = @((($output -split "`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' }))
    $lastLine = if ($lines.Count -gt 0) { $lines[$lines.Count-1] } else { '' }

    if ($exitCode -ne 0) {
      Psql-OneJson -Sql "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='step_failed' WHERE id=$runId;" | Out-Null
      Fail-Json "Step failed ($skill $op) exit_code=$exitCode"
    }
    if (-not $lastLine -or -not $lastLine.StartsWith('{')) {
      Psql-OneJson -Sql "UPDATE skill_system.runs SET status='failed', ended_at=NOW(), error='missing_last_line_json' WHERE id=$runId;" | Out-Null
      Fail-Json "Step output missing last-line JSON ($skill $op)"
    }

    $okSteps += 1
    Psql-OneJson -Sql "INSERT INTO skill_system.run_events(run_id, level, event_type, payload) VALUES ($runId, 'info', 'step_succeeded', jsonb_build_object('index',$stepIndex));" | Out-Null
  }

  $durMs = [int]((New-TimeSpan -Start $start -End (Get-Date)).TotalMilliseconds)
  Psql-OneJson -Sql "UPDATE skill_system.runs SET status='succeeded', ended_at=NOW(), metrics=jsonb_build_object('steps',$okSteps,'duration_ms',$durMs) WHERE id=$runId;" | Out-Null

  $obj = @{
    status = 'ok'
    summary = 'run_succeeded'
    artifacts = @()
    metrics = @{ run_id = $runId; steps = $okSteps; duration_ms = $durMs }
    errors = @()
  }
  ($obj | ConvertTo-Json -Depth 10 -Compress)
}

function Usage {
  @'
Usage:
  scripts\router.ps1 run <task_spec_id>
'@
}

$c = if ($null -eq $Command) { '' } else { $Command.Trim().ToLowerInvariant() }
if ($c -ne 'run') { Usage; exit 2 }
if (-not $TaskSpecId) { Usage; exit 2 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillsRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..\..')).Path

$taskJson = Get-TaskSpecJson -Id $TaskSpecId
if (-not $taskJson -or $taskJson -eq 'null') { Fail-Json "Task spec not found: $TaskSpecId" }
$taskObj = $taskJson | ConvertFrom-Json -ErrorAction Stop

$policyObj = $null
if ($taskObj.policy_profile_id) {
  $policyJson = Get-PolicyProfileJson -Id ([string]$taskObj.policy_profile_id)
  if ($policyJson -and $policyJson -ne 'null') {
    $policyObj = $policyJson | ConvertFrom-Json -ErrorAction Stop
  }
}

Run-Pipeline -TaskObj $taskObj -PolicyObj $policyObj -SkillsRoot $skillsRoot
