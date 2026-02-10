param(
  [string]$PgVersion = '18',
  [string]$VersionTag = 'v0.8.1',
  [switch]$InstallPrereqs,
  [switch]$Install,
  [switch]$Enable,
  [switch]$ApplyInitSql
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell (Administrator).'
  }
}

function Resolve-PsqlPath {
  $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $candidate = "C:\\Program Files\\PostgreSQL\\$PgVersion\\bin\\psql.exe"
  if (Test-Path -LiteralPath $candidate) { return $candidate }
  return $null
}

function Resolve-PgConfigPath {
  $cmd = Get-Command pg_config.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $candidate = "C:\\Program Files\\PostgreSQL\\$PgVersion\\bin\\pg_config.exe"
  if (Test-Path -LiteralPath $candidate) { return $candidate }
  return $null
}

function Resolve-GitPath {
  $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $candidates = @(
    "$env:ProgramFiles\Git\cmd\git.exe",
    "$env:ProgramFiles\Git\bin\git.exe",
    "$env:ProgramFiles(x86)\Git\cmd\git.exe",
    "$env:ProgramFiles(x86)\Git\bin\git.exe"
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

function Resolve-VsWhere {
  $candidates = @(
    "$env:ProgramFiles(x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe",
    "$env:ProgramFiles\\Microsoft Visual Studio\\Installer\\vswhere.exe"
  )
  foreach ($p in $candidates) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

function Resolve-VsDevCmd {
  # Prefer vswhere if present, but fall back to common install paths.
  $vswhere = Resolve-VsWhere
  if ($vswhere) {
    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($installPath) {
      $devcmd = Join-Path $installPath 'Common7\Tools\VsDevCmd.bat'
      if (Test-Path -LiteralPath $devcmd) { return $devcmd }
    }
  }

  $fallbacks = @(
    "$env:ProgramFiles(x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
    "$env:ProgramFiles(x86)\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
  )

  foreach ($p in $fallbacks) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }

  return $null
}

function Try-EnableExtension {
  param(
    [Parameter(Mandatory = $true)][string]$Psql
  )

  # PowerShell may treat native stderr as terminating when $ErrorActionPreference='Stop'.
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Psql -w -h localhost -p 5432 -U postgres -d agent_memory -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;" 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $oldEap
  }
}

function Apply-InitSql {
  param(
    [Parameter(Mandatory = $true)][string]$Psql
  )

  $initSql = Join-Path $PSScriptRoot '..\init.sql'
  $initSql = (Resolve-Path -LiteralPath $initSql).Path
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Psql -w -h localhost -p 5432 -U postgres -d agent_memory -v ON_ERROR_STOP=1 -f $initSql 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $oldEap
  }
}

Write-Host "setup-pgvector.ps1 PgVersion=$PgVersion"
Write-Output "setup-pgvector.ps1 PgVersion=$PgVersion"

# Admin is required only for build/install steps that write into PostgreSQL's install directory.
if ($Install -or $InstallPrereqs) {
  Assert-Admin
}

$psql = Resolve-PsqlPath
if (-not $psql) {
  throw 'psql.exe not found. Install PostgreSQL or add it to PATH.'
}

$pgConfig = Resolve-PgConfigPath
if (-not $pgConfig) {
  throw 'pg_config.exe not found. Ensure PostgreSQL dev files are installed.'
}

# First attempt: extension already present
if ($Enable -or (-not $Install -and -not $InstallPrereqs)) {
  if (Try-EnableExtension -Psql $psql) {
    Write-Host 'pgvector extension enabled (already installed).'
    Write-Output 'pgvector extension enabled (already installed).'
    if ($ApplyInitSql) {
      if (Apply-InitSql -Psql $psql) {
        Write-Host 'init.sql applied.'
        Write-Output 'init.sql applied.'
      }
    }
    exit 0
  }
}

if (-not $Install) {
  Write-Host 'pgvector is not installed. Re-run with -Install (and optionally -InstallPrereqs) to build+install.'
  Write-Output 'pgvector is not installed. Re-run with -Install (and optionally -InstallPrereqs) to build+install.'
  exit 0
}

if ($InstallPrereqs) {
  if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget not found; install App Installer from Microsoft Store.'
  }

  if (-not (Resolve-GitPath)) {
    Write-Host 'Installing Git via winget...'
    Write-Output 'Installing Git via winget...'
    & winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
  }

  if (-not (Resolve-VsDevCmd)) {
    Write-Host 'Installing Visual Studio Build Tools (C++ toolchain) via winget...'
    Write-Output 'Installing Visual Studio Build Tools (C++ toolchain) via winget...'
    & winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements
    Write-Host 'NOTE: You may need to re-run this script after installation completes.'
    Write-Output 'NOTE: You may need to re-run this script after installation completes.'
  }
}

$vsDevCmd = Resolve-VsDevCmd
if (-not $vsDevCmd) {
  throw 'VsDevCmd.bat not found. Install Visual Studio Build Tools (C++), then re-run.'
}

$git = Resolve-GitPath
if (-not $git) {
  throw 'git.exe not found. Install Git, then re-run.'
}

# Build+install pgvector using the official Windows instructions (nmake /F Makefile.win)
$temp = Join-Path $env:TEMP ('pgvector-build-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

Write-Host 'Cloning pgvector...'
Write-Output 'Cloning pgvector...'
& $git clone --branch $VersionTag --depth 1 https://github.com/pgvector/pgvector.git $temp

$pgRoot = (Split-Path -Parent (Split-Path -Parent $psql))

Write-Host 'Building pgvector with nmake...'
Write-Output 'Building pgvector with nmake...'
$cmd = "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && set `"PGROOT=$pgRoot`" && cd /d `"$temp`" && nmake /F Makefile.win && nmake /F Makefile.win install"
& cmd.exe /c $cmd

if ($LASTEXITCODE -ne 0) {
  throw "nmake build/install failed (exit=$LASTEXITCODE). Ensure you ran as Administrator and PGROOT is correct."
}

# Enable extension
if (-not (Try-EnableExtension -Psql $psql)) {
  throw 'pgvector installed but CREATE EXTENSION vector failed. Check server logs and extension files.'
}

Write-Host 'pgvector extension enabled.'
Write-Output 'pgvector extension enabled.'

if ($ApplyInitSql) {
  if (Apply-InitSql -Psql $psql) {
    Write-Host 'init.sql applied.'
    Write-Output 'init.sql applied.'
  } else {
    Write-Host 'init.sql apply failed (non-fatal).'
    Write-Output 'init.sql apply failed (non-fatal).'
  }
}

exit 0
