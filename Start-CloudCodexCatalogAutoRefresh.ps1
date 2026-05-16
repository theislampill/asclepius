$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$RefreshScript = Join-Path $Root "Refresh-NousCatalog.ps1"
$Logs = Join-Path $Root "logs"
$LogFile = Join-Path $Logs "cloud-codex-catalog-auto-refresh.log"
$MutexName = "Local\CloudCodexCatalogAutoRefresh"

New-Item -ItemType Directory -Force -Path $Logs | Out-Null

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) {
  exit 0
}

function Write-RefreshLog {
  param([string]$Message)
  $line = "{0} {1}" -f (Get-Date).ToUniversalTime().ToString("o"), $Message
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-CatalogRefresh {
  if (-not (Test-Path -LiteralPath $RefreshScript)) {
    Write-RefreshLog "Refresh script missing: $RefreshScript"
    return
  }

  try {
    Write-RefreshLog "refresh-start"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RefreshScript 2>&1
    foreach ($line in @($output)) {
      if ($line) { Write-RefreshLog ([string]$line) }
    }
    Write-RefreshLog "refresh-ok"
  } catch {
    Write-RefreshLog ("refresh-failed " + $_.Exception.Message)
  }
}

try {
  Invoke-CatalogRefresh
  while ($true) {
    Start-Sleep -Seconds 3600
    Invoke-CatalogRefresh
  }
} finally {
  $mutex.ReleaseMutex() | Out-Null
  $mutex.Dispose()
}
