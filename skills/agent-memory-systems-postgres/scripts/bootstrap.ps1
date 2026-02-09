param(
  [switch]$InstallAll,
  [string]$PgVersion = '18'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Prompt-YesNo {
  param(
    [Parameter(Mandatory = $true)][string]$Question,
    [bool]$DefaultYes = $true
  )

  $suffix = if ($DefaultYes) { ' [Y/n]' } else { ' [y/N]' }
  $ans = Read-Host ($Question + $suffix)
  if (-not $ans) { return $DefaultYes }
  $a = $ans.Trim().ToLowerInvariant()
  return ($a -eq 'y' -or $a -eq 'yes')
}

function Assert-InteractiveOrInstallAll {
  param([switch]$InstallAll)
  if ($InstallAll) { return }
  if ([Console]::IsInputRedirected) {
    throw 'Non-interactive stdin detected. Re-run interactively, or pass -InstallAll.'
  }
}

function Try-Command {
  param([Parameter(Mandatory = $true)][string]$Exe)
  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
  if ($cmd) { return $true }
  return $false
}

function Write-SetupRecord {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Record
  )
  $path = Join-Path $env:USERPROFILE '.config\opencode\agent-memory-systems-postgres\setup.json'
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  ($Record | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $path -Encoding ascii
  Write-Host "Wrote setup record to $path"
}

$record = @{
  time_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  os = 'windows'
  selected = @{}
  notes = @()
}

Assert-InteractiveOrInstallAll -InstallAll:$InstallAll

$wantPgpass = $InstallAll -or (Prompt-YesNo -Question 'Set up pgpass.conf for non-interactive psql?' -DefaultYes $true)
$record.selected.pgpass = $wantPgpass
if ($wantPgpass) {
  try {
    & (Join-Path $PSScriptRoot 'setup-pgpass.ps1')
    $record.notes += 'pgpass.conf configured'
  } catch {
    $record.notes += "pgpass setup failed: $($_.Exception.Message)"
  }
}

$wantOllama = $InstallAll -or (Prompt-YesNo -Question 'Install Ollama for local embeddings?' -DefaultYes $false)
$record.selected.ollama = $wantOllama
if ($wantOllama) {
  if (Try-Command -Exe 'ollama.exe') {
    $record.notes += 'ollama already installed'
  } else {
    $canWinget = Try-Command -Exe 'winget.exe'
    if ($canWinget -and (Prompt-YesNo -Question 'Use winget to install Ollama (recommended)?' -DefaultYes $false)) {
      $record.notes += 'Installing Ollama via winget'
      try {
        & winget install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements
      } catch {
        $record.notes += "winget install failed: $($_.Exception.Message)"
      }
    } else {
      $record.notes += 'Install Ollama manually: https://ollama.com/download'
    }
  }

  if (Try-Command -Exe 'ollama.exe') {
    $model = Read-Host 'Ollama embedding model to pull (default: nomic-embed-text)'
    if (-not $model) { $model = 'nomic-embed-text' }
    $record.selected.ollama_model = $model
    if ($InstallAll -or (Prompt-YesNo -Question "Pull model '$model' now?" -DefaultYes $false)) {
      try {
        & ollama pull $model
      } catch {
        $record.notes += "ollama pull failed: $($_.Exception.Message)"
      }
    }
  }
}

$wantPgvector = $InstallAll -or (Prompt-YesNo -Question 'Enable pgvector extension (vector) in Postgres?' -DefaultYes $false)
$record.selected.pgvector = $wantPgvector
if ($wantPgvector) {
  try {
    & (Join-Path $PSScriptRoot 'setup-pgvector.ps1') -PgVersion $PgVersion -InstallPrereqs -Install -Enable -ApplyInitSql
    $record.notes += 'pgvector installed+enabled'
  } catch {
    $record.notes += "pgvector setup failed: $($_.Exception.Message)"
  }
}

Write-SetupRecord -Record $record
Write-Host 'Bootstrap complete.'
exit 0
