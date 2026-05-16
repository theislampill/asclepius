param(
  [switch]$NoCatalogRefresh
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BridgePort = 8655
$ProxyPort = 8645
$Logs = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

function Test-JsonEndpoint {
  param([string]$Uri)
  try {
    $null = Invoke-RestMethod -Uri $Uri -TimeoutSec 3
    return $true
  } catch {
    return $false
  }
}

function Find-Python {
  $candidates = @(
    (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "No Python executable found for Codex Nous bridge."
}

if (-not (Test-JsonEndpoint "http://127.0.0.1:$ProxyPort/health")) {
  $proxyCommand = "exec /home/agent/.local/bin/hermes proxy start --provider nous --host 127.0.0.1 --port $ProxyPort >> /tmp/codex-nous-hermes-proxy.log 2>&1"
  Start-Process -FilePath "wsl.exe" -ArgumentList "-d Ubuntu -- bash -lc `"$proxyCommand`"" -WindowStyle Hidden | Out-Null
  $ready = $false
  foreach ($i in 1..30) {
    Start-Sleep -Milliseconds 500
    if (Test-JsonEndpoint "http://127.0.0.1:$ProxyPort/health") { $ready = $true; break }
  }
  if (-not $ready) {
    throw "Hermes Nous proxy did not become healthy on 127.0.0.1:$ProxyPort."
  }
}

if (-not (Test-JsonEndpoint "http://127.0.0.1:$BridgePort/health")) {
  $python = Find-Python
  $bridge = Join-Path $Root "codex_nous_bridge.py"
  $out = Join-Path $Logs "codex-nous-bridge.out.log"
  $err = Join-Path $Logs "codex-nous-bridge.err.log"
  Start-Process -FilePath $python -ArgumentList @($bridge) -WorkingDirectory $Root -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null
  $ready = $false
  foreach ($i in 1..30) {
    Start-Sleep -Milliseconds 500
    if (Test-JsonEndpoint "http://127.0.0.1:$BridgePort/health") { $ready = $true; break }
  }
  if (-not $ready) {
    throw "Codex Nous bridge did not become healthy on 127.0.0.1:$BridgePort."
  }
}

if (-not $NoCatalogRefresh) {
  & (Join-Path $Root "Refresh-NousCatalog.ps1") | Out-Null
}

Write-Output "Hermes Nous proxy: http://127.0.0.1:$ProxyPort/health"
Write-Output "Codex Nous bridge: http://127.0.0.1:$BridgePort/health"
