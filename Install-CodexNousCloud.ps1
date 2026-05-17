$ErrorActionPreference = "Stop"
$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Join-Path $env:USERPROFILE ".codex-nous-cloud"
$CodexHome = Join-Path $Root "codex-home"
$ElectronUserData = Join-Path $Root "electron-user-data"
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "asclepius.lnk"

$required = @(
  "Asclepius.exe",
  "AsclepiusLauncher.cs",
  "Build-AsclepiusLauncher.ps1",
  "Test-Asclepius.ps1",
  "Install-AsclepiusDependency.ps1",
  "codex_nous_bridge.py",
  "asclepius_hermes_event_runner.py",
  "sync_asclepius_token_usage.py",
  "Start-CodexNousCloudServices.ps1",
  "Refresh-NousCatalog.ps1",
  "Launch-AsclepiusProviderLauncher.ps1",
  "Launch-AsclepiusProviderLauncher.vbs",
  "Launch-CloudCodexApp.ps1",
  "Launch-CloudCodexApp.vbs",
  "Launch-CloudCodexModelPicker.ps1",
  "Launch-CloudCodexModelPicker.vbs",
  "Test-AsclepiusWindowIdentity.ps1",
  "Start-AsclepiusWindowIdentityWatcher.ps1",
  "Start-AsclepiusHermesTitlebarOverlay.ps1",
  "Start-AsclepiusCodexIdentitySmoke.ps1",
  "Manage-AsclepiusHermesSessions.ps1",
  "Get-AsclepiusHermesStatus.ps1",
  "Update-HermesGolden.ps1",
  "Install-CloudCodexAutoRefresh.ps1",
  "Start-CloudCodexCatalogAutoRefresh.ps1",
  "Start-HermesNousOAuthLogin.ps1",
  "cloud-codex-instructions.md"
)

$sourceExe = Join-Path $Source "Asclepius.exe"
if (-not (Test-Path -LiteralPath $sourceExe)) {
  $buildScript = Join-Path $Source "Build-AsclepiusLauncher.ps1"
  if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Asclepius.exe is missing and the launcher build script is not available."
  }
  & $buildScript -OutputPath $sourceExe | Out-Null
}

foreach ($name in $required) {
  $path = Join-Path $Source $name
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required file missing from package: $name"
  }
}

New-Item -ItemType Directory -Force -Path $Root, $CodexHome, $ElectronUserData | Out-Null
foreach ($name in $required) {
  Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $Root -Force
}

Remove-Item -LiteralPath (Join-Path $Root "AsclepiusHost.cs") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root "Build-AsclepiusHost.ps1") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root "AsclepiusApp.cs") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root "Build-AsclepiusApp.ps1") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root "asclepius-smoke.json") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root "asclepius-window-smoke.json") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root "asclepius-host-smoke.json") -Force -ErrorAction SilentlyContinue

$catalog = Join-Path $Root "codex-model-catalog.json"
$escapedCatalog = $catalog.Replace("\", "\\")
$instructions = Join-Path $Root "cloud-codex-instructions.md"
$escapedInstructions = $instructions.Replace("\", "\\")

$config = @"
model = "nous/deepseek/deepseek-v4-flash"
model_provider = "nous-cloud"
model_reasoning_effort = "medium"
approval_policy = "never"
sandbox_mode = "workspace-write"
model_catalog_json = "$escapedCatalog"
model_instructions_file = "$escapedInstructions"
personality = "pragmatic"

[windows]
sandbox = "elevated"

[model_providers.nous-cloud]
name = "@nous:deepseek/deepseek-v4-flash via Hermes"
base_url = "http://127.0.0.1:8655/v1"
experimental_bearer_token = "local-codex-nous-cloud"
wire_api = "responses"
request_max_retries = 1
stream_max_retries = 1
stream_idle_timeout_ms = 300000

[projects.'C:\workspace\ai']
trust_level = "trusted"

[projects.'c:\users\theis\.codex-nous-cloud']
trust_level = "trusted"
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $CodexHome "config.toml"), $config, $utf8NoBom)

& (Join-Path $Root "Start-CodexNousCloudServices.ps1") | Out-Null

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($DesktopShortcut)
$shortcut.TargetPath = "$Root\Asclepius.exe"
$shortcut.Arguments = ""
$shortcut.WorkingDirectory = $Root
$shortcut.Description = "Choose an Asclepius provider route, then launch real Codex Desktop with Hermes underneath"
$shortcut.IconLocation = "$Root\Asclepius.exe,0"
$shortcut.Save()

try {
  & (Join-Path $Root "Install-CloudCodexAutoRefresh.ps1") | Out-Null
  $refreshMode = "installed"
} catch {
  $refreshMode = "not installed: $($_.Exception.Message)"
}

Write-Output "Installed to $Root"
Write-Output "Isolated CODEX_HOME: $CodexHome"
Write-Output "Desktop shortcut: $DesktopShortcut"
Write-Output "Shortcut opens Asclepius.exe, which starts the provider launcher without a terminal window."
Write-Output "Catalog auto-refresh: $refreshMode"
Write-Output "No Codex binaries, credentials, logs, or Electron state were copied from this package."
