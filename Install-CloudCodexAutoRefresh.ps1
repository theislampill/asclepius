$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "Cloud-Codex Catalog Auto Refresh"
$RefreshScript = Join-Path $Root "Refresh-NousCatalog.ps1"
$RunnerScript = Join-Path $Root "Start-CloudCodexCatalogAutoRefresh.ps1"
$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunValueName = "Cloud-Codex Catalog Auto Refresh"

if (-not (Test-Path -LiteralPath $RefreshScript)) {
  throw "Refresh script not found: $RefreshScript"
}
if (-not (Test-Path -LiteralPath $RunnerScript)) {
  throw "Auto-refresh runner not found: $RunnerScript"
}

$argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RefreshScript`""
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument -WorkingDirectory $Root

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$hourlyTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
  -RepetitionInterval (New-TimeSpan -Hours 1) `
  -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable

try {
  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($logonTrigger, $hourlyTrigger) `
    -Settings $settings `
    -Description "Refreshes Cloud-Codex cloud model/provider/price catalog from live provider endpoints." `
    -Force | Out-Null

  Write-Output "Installed scheduled task: $TaskName"
} catch {
  $runnerArgument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RunnerScript`""
  New-Item -Path $RunKeyPath -Force | Out-Null
  Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value "powershell.exe $runnerArgument"
  Start-Process -FilePath "powershell.exe" -ArgumentList $runnerArgument -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
  Write-Output "Scheduled task install failed: $($_.Exception.Message)"
  Write-Output "Installed HKCU startup auto-refresh fallback: $RunValueName"
}
