param(
  [int]$Limit = 25,
  [int]$MaxChars = 8000,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Escape-SqlLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)
  return ($Value -replace "'", "''")
}

function New-TempFilePath {
  param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$Suffix
  )
  $name = $Prefix + '-' + ([Guid]::NewGuid().ToString('n')) + $Suffix
  return (Join-Path $env:TEMP $name)
}

function Resolve-PsqlPath {
  $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  $candidates = @(
    'C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\17\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\16\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\15\\bin\\psql.exe',
    'C:\\Program Files\\PostgreSQL\\14\\bin\\psql.exe'
  )
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}

function Psql-Query {
  param(
    [Parameter(Mandatory = $true)][string]$Sql
  )

  $psql = Resolve-PsqlPath
  if (-not $psql) {
    throw 'psql.exe not found (install PostgreSQL or add psql to PATH)'
  }

  $pgHost = if ($env:PGHOST) { $env:PGHOST } else { 'localhost' }
  $pgPort = if ($env:PGPORT) { $env:PGPORT } else { '5432' }
  $pgDb = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'agent_memory' }
  $pgUser = if ($env:PGUSER) { $env:PGUSER } else { 'postgres' }

  & $psql -w -h $pgHost -p $pgPort -U $pgUser -d $pgDb -v 'ON_ERROR_STOP=1' -t -A -c $Sql
}

function Require-Env {
  param([Parameter(Mandatory = $true)][string]$Name)
  $item = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
  $v = if ($null -ne $item) { $item.Value } else { $null }
  if (-not $v) {
    Write-Host "Missing env var: $Name"
    return $null
  }
  return $v
}

$setupPath = Join-Path $env:USERPROFILE '.config\opencode\agent-memory-systems-postgres\setup.json'
$setup = $null
try {
  if (Test-Path -LiteralPath $setupPath) {
    $setup = (Get-Content -LiteralPath $setupPath -Raw) | ConvertFrom-Json
  }
} catch {
  $setup = $null
}

$provider = if ($env:EMBEDDING_PROVIDER) {
  $env:EMBEDDING_PROVIDER
} elseif ($setup -and $setup.selected -and $setup.selected.ollama -eq $true) {
  'ollama'
} else {
  'openai'
}
$apiKey = $null
if ($provider -eq 'ollama') {
  # Ollama OpenAI-compat requires an api_key value, but it is ignored.
  $apiKey = if ($env:EMBEDDING_API_KEY) { $env:EMBEDDING_API_KEY } else { 'ollama' }
} else {
  $apiKey = Require-Env -Name 'EMBEDDING_API_KEY'
  if (-not $apiKey) {
    Write-Host 'No embeddings ingested (set EMBEDDING_API_KEY to enable).'
    exit 0
  }
}
$apiUrl = if ($env:EMBEDDING_API_URL) { $env:EMBEDDING_API_URL } else {
  if ($provider -eq 'ollama') { 'http://localhost:11434/v1/embeddings' } else { 'https://api.openai.com/v1/embeddings' }
}
$model = if ($env:EMBEDDING_MODEL) {
  $env:EMBEDDING_MODEL
} elseif ($provider -eq 'ollama' -and $setup -and $setup.selected -and $setup.selected.ollama_model) {
  [string]$setup.selected.ollama_model
} else {
  if ($provider -eq 'ollama') { 'nomic-embed-text' } else { 'text-embedding-3-small' }
}
$dimensions = if ($env:EMBEDDING_DIMENSIONS) { [int]$env:EMBEDDING_DIMENSIONS } else { $null }

# Ensure embedding column exists (pgvector installed + init.sql applied)
$hasEmbedding = (Psql-Query -Sql "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='agent_memories' AND column_name='embedding');").Trim()
if ($hasEmbedding -ne 't') {
  Write-Host 'agent_memories.embedding is missing. Install pgvector and re-run init.sql.'
  exit 0
}

# Fetch candidate rows
$rowsTsv = Psql-Query -Sql "SELECT id || E'\t' || replace(title, E'\t', ' ') || E'\t' || replace(left(content, 20000), E'\t', ' ') FROM agent_memories WHERE deleted_at IS NULL AND embedding IS NULL ORDER BY importance_score DESC, accessed_at DESC LIMIT $Limit;"

if (-not $rowsTsv) {
  Write-Host 'No rows need embeddings.'
  exit 0
}

$lines = $rowsTsv -split "`r?`n" | Where-Object { $_ -and $_.Trim().Length -gt 0 }

foreach ($line in $lines) {
  $parts = $line -split "`t", 3
  if ($parts.Count -lt 3) { continue }

  $id = [int64]$parts[0]
  $title = [string]$parts[1]
  $content = [string]$parts[2]

  $input = ($title + "\n\n" + $content)
  if ($input.Length -gt $MaxChars) {
    $input = $input.Substring(0, $MaxChars)
  }

  if ($DryRun) {
    Write-Host "[dry-run] would embed id=$id"
    continue
  }

  $payload = @{ input = $input; model = $model }
  if ($null -ne $dimensions) { $payload.dimensions = $dimensions }
  $body = $payload | ConvertTo-Json -Compress
  $headers = @{ Authorization = "Bearer $apiKey"; 'Content-Type' = 'application/json' }

  $resp = $null
  try {
    $resp = Invoke-RestMethod -Method Post -Uri $apiUrl -Headers $headers -Body $body
  } catch {
    Write-Host "embed failed id=${id}: $($_.Exception.Message)"
    continue
  }

  $embedding = $resp.data[0].embedding
  if (-not $embedding) {
    Write-Host "embed missing vector id=$id"
    continue
  }

  $dim = @($embedding).Count

  # Build pgvector literal: [0.1,0.2,...]
  $vec = '[' + (($embedding | ForEach-Object { ([double]$_).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }) -join ',') + ']'

  $modelSql = Escape-SqlLiteral -Value $model
  $providerSql = Escape-SqlLiteral -Value $provider
  $apiUrlSql = Escape-SqlLiteral -Value $apiUrl

  $sql = @"
UPDATE agent_memories
SET embedding = '$vec'::vector,
    metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
      'embedding_model', '$modelSql',
      'embedding_dim', $dim,
      'embedding_api_url', '$apiUrlSql',
      'embedding_provider', '$providerSql',
      'embedded_at', now()
    ),
    updated_at = NOW()
WHERE id = $id;
"@

  try {
    $psql = Resolve-PsqlPath
    $pgHost = if ($env:PGHOST) { $env:PGHOST } else { 'localhost' }
    $pgPort = if ($env:PGPORT) { $env:PGPORT } else { '5432' }
    $pgDb = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'agent_memory' }
    $pgUser = if ($env:PGUSER) { $env:PGUSER } else { 'postgres' }

    $tmp = New-TempFilePath -Prefix 'agent-memory-embed' -Suffix '.sql'
    try {
      $sql | Out-File -LiteralPath $tmp -Encoding ascii
      & $psql -w -h $pgHost -p $pgPort -U $pgUser -d $pgDb -v 'ON_ERROR_STOP=1' -f $tmp 1>$null 2>$null
    } finally {
      Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $tmp
    }

    if ($LASTEXITCODE -ne 0) {
      throw "psql failed with exit code $LASTEXITCODE"
    }
  } catch {
    Write-Host "db update failed id=${id}: $($_.Exception.Message)"
    continue
  }

  Write-Host "embedded id=$id dim=$dim"
}

exit 0
