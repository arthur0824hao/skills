Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Dir {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

$hostName = Read-Host 'PGHOST (default: localhost)'
if (-not $hostName) { $hostName = 'localhost' }

$port = Read-Host 'PGPORT (default: 5432)'
if (-not $port) { $port = '5432' }

$database = Read-Host 'PGDATABASE (default: agent_memory)'
if (-not $database) { $database = 'agent_memory' }

$user = Read-Host 'PGUSER (default: postgres)'
if (-not $user) { $user = 'postgres' }

$secure = Read-Host 'Password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if (-not $password) {
  throw 'Password cannot be empty'
}

$pgDir = Join-Path $env:APPDATA 'postgresql'
Ensure-Dir -Path $pgDir
$pgpassPath = Join-Path $pgDir 'pgpass.conf'

$escaped = $password.Replace('\\', '\\\\').Replace(':', '\\:')
$line = "$hostName`:$port`:$database`:$user`:$escaped"

$line | Out-File -LiteralPath $pgpassPath -Encoding ascii
Write-Host "Wrote $pgpassPath"
