param(
  [Parameter(Position=0)][string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillsRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..\..')).Path

if (-not $OutFile) { $OutFile = Join-Path $skillsRoot 'skills-index.json' }

function Extract-ManifestBlock {
  param([Parameter(Mandatory=$true)][string]$MdPath)
  $lines = Get-Content -LiteralPath $MdPath -ErrorAction Stop
  foreach ($tag in @('skill-manifest', 'router-manifest')) {
    $in = $false
    $buf = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
      if (-not $in) {
        if ($l -match "^\`\`\`$tag\s*$") { $in = $true; continue }
        continue
      }
      if ($l -match '^\`\`\`\s*$') { break }
      $buf.Add($l)
    }
    if ($buf.Count -gt 0) { return ($buf -join "`n") }
  }
  return $null
}

$manifests = @()

foreach ($dir in (Get-ChildItem -Path $skillsRoot -Directory)) {
  $md = Join-Path $dir.FullName 'SKILL.md'
  if (-not (Test-Path -LiteralPath $md)) { continue }

  $block = Extract-ManifestBlock -MdPath $md
  if (-not $block) { continue }

  try {
    $obj = $block | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning "Invalid manifest JSON in $($dir.Name), skipping"
    continue
  }

  $obj | Add-Member -NotePropertyName '_dir' -NotePropertyValue $dir.Name -Force
  $manifests += $obj
}

$index = [ordered]@{
  schema_version   = '2.0'
  generated_at     = (Get-Date -Format 'o')
  skills           = [ordered]@{}
  capability_index = [ordered]@{}
}

foreach ($m in $manifests) {
  $sid = if ($m.id) { $m.id } else { $m._dir }
  $caps = @($m.capabilities | Where-Object { $_ })
  $effects = @($m.effects | Where-Object { $_ })

  $ops = [ordered]@{}
  $rawOps = if ($m.operations) { $m.operations } else { $null }
  if ($rawOps) {
    foreach ($prop in $rawOps.PSObject.Properties) {
      $opObj = $prop.Value
      if ($opObj.description) {
        $inputParams = @()
        if ($opObj.input) {
          $inputParams = @($opObj.input.PSObject.Properties | ForEach-Object { $_.Name })
        }
        $ops[$prop.Name] = [ordered]@{
          description  = [string]$opObj.description
          input_params = $inputParams
        }
      }
    }
  }

  $index.skills[$sid] = [ordered]@{
    dir          = [string]$m._dir
    version      = if ($m.version) { [string]$m.version } else { '0.0.0' }
    capabilities = $caps
    effects      = $effects
    operations   = $ops
  }

  foreach ($cap in $caps) {
    if (-not $index.capability_index.Contains($cap)) {
      $index.capability_index[$cap] = @()
    }
    if ($index.capability_index[$cap] -notcontains $sid) {
      $index.capability_index[$cap] += $sid
    }
  }
}

$json = $index | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8NoBOM
Write-Host "Index written: $OutFile ($($manifests.Count) skills)"
