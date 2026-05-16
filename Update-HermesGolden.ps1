$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Hermes Golden Update"

function Invoke-HermesBash {
  param([Parameter(Mandatory)][string]$Script)
  & wsl.exe -d Ubuntu -- bash -lc $Script
}

Write-Host "Hermes Golden Update" -ForegroundColor Cyan
Write-Host ""
Write-Host "This updates Hermes only. Codex Desktop's blue Update button remains the Codex updater."
Write-Host "A Hermes backup is requested before update."
Write-Host ""

try {
  Write-Host "Current Hermes version/state:" -ForegroundColor Yellow
  Invoke-HermesBash "/home/agent/.local/bin/hermes version 2>&1 || true"
  Invoke-HermesBash "cd /home/agent/.hermes/hermes-agent && git status --short --branch && git log --oneline -1"
  Write-Host ""

  Write-Host "Checking for update..." -ForegroundColor Yellow
  Invoke-HermesBash "/home/agent/.local/bin/hermes update --check 2>&1 || true"
  Write-Host ""

  $answer = Read-Host "Run 'hermes update --backup --yes' now? Type YES to continue"
  if ($answer -ne "YES") {
    Write-Host "Cancelled."
    Read-Host "Press Enter to close"
    exit 0
  }

  Write-Host ""
  Write-Host "Updating Hermes..." -ForegroundColor Yellow
  Invoke-HermesBash "/home/agent/.local/bin/hermes update --backup --yes 2>&1"

  Write-Host ""
  Write-Host "Restarting Asclepius services so the bridge sees the updated Hermes..." -ForegroundColor Yellow
  try {
    Get-CimInstance Win32_Process |
      Where-Object { $_.CommandLine -like '*codex_nous_bridge.py*' -and $_.Name -match 'python' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  } catch {}
  try {
    Invoke-HermesBash "pkill -f 'hermes proxy start --provider nous --host 127.0.0.1 --port 8645' 2>/dev/null || true"
  } catch {}
  & (Join-Path $PSScriptRoot "Start-CodexNousCloudServices.ps1") | Write-Host

  Write-Host ""
  Write-Host "Hermes Golden update complete." -ForegroundColor Green
} catch {
  Write-Host ""
  Write-Host "Hermes Golden update failed:" -ForegroundColor Red
  Write-Host $_.Exception.Message
}

Read-Host "Press Enter to close"
