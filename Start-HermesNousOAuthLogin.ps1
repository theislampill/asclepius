$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "Hermes Nous OAuth Login"
Write-Host "------------------------"
Write-Host "This opens Hermes' Nous OAuth login flow in WSL."
Write-Host "Use this for free Nous Portal models. No Nous API key is required."
Write-Host ""

wsl.exe -d Ubuntu -- bash -lc "/home/agent/.local/bin/hermes login --provider nous"
$loginExit = $LASTEXITCODE

Write-Host ""
Write-Host "Current Hermes Nous auth status:"
wsl.exe -d Ubuntu -- bash -lc "/home/agent/.local/bin/hermes auth status nous"

if ($loginExit -ne 0) {
  Write-Host ""
  Write-Host "Hermes login exited with code $loginExit."
}

Write-Host ""
Write-Host "Return to Cloud-Codex and click Refresh after login completes."
Write-Host "Press Enter to close this window."
[void][Console]::ReadLine()
