param(
  [string]$Model = "nous/deepseek/deepseek-v4-flash",
  [string]$Workspace = "C:\workspace\ai",
  [string]$AppUserModelId = "NousResearch.Asclepius.Codex",
  [string]$WindowTitle = "Asclepius",
  [int]$TimeoutSeconds = 60,
  [switch]$CloseWhenDone
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProbeScript = Join-Path $Root "Test-AsclepiusWindowIdentity.ps1"
$WatcherScript = Join-Path $Root "Start-AsclepiusWindowIdentityWatcher.ps1"

function Get-CodexProcessSnapshot {
  $rows = @()
  foreach ($name in @("Codex", "codex")) {
    $rows += Get-Process -Name $name -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path.EndsWith("\Codex.exe", [System.StringComparison]::OrdinalIgnoreCase) } |
      ForEach-Object {
        [pscustomobject]@{
          Id = $_.Id
          MainWindowHandle = [int64]$_.MainWindowHandle
          MainWindowTitle = $_.MainWindowTitle
          Path = $_.Path
        }
      }
  }

  $rows | Sort-Object Id -Unique
}

function Find-CodexDesktopExe {
  $candidates = @()

  $candidates += Get-Process -Name Codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.EndsWith("\app\Codex.exe", [System.StringComparison]::OrdinalIgnoreCase) } |
    Select-Object -ExpandProperty Path

  try {
    $candidates += Resolve-Path "C:\Program Files\WindowsApps\OpenAI.Codex_*\app\Codex.exe" -ErrorAction Stop |
      Sort-Object Path -Descending |
      Select-Object -ExpandProperty Path
  } catch {}

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "Could not find the installed Codex Desktop executable."
}

function ConvertTo-WslPath {
  param([Parameter(Mandatory)][string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  if ($full -match '^([A-Za-z]):\\(.*)$') {
    $drive = $matches[1].ToLowerInvariant()
    $rest = $matches[2].Replace('\', '/')
    return "/mnt/$drive/$rest"
  }
  return $full.Replace('\', '/')
}

function Write-IsolatedConfig {
  param(
    [Parameter(Mandatory)][string]$CodexHome,
    [Parameter(Mandatory)][string]$SelectedModel,
    [Parameter(Mandatory)][string]$TempRoot
  )

  New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
  $catalog = Join-Path $TempRoot "codex-model-catalog.json"
  $instructions = Join-Path $TempRoot "cloud-codex-instructions.md"
  $escapedCatalog = $catalog.Replace("\", "\\")
  $escapedInstructions = $instructions.Replace("\", "\\")
  $wslWorkspace = ConvertTo-WslPath -Path $Workspace

  $instructionText = @"
In this isolated Asclepius identity smoke profile, runtime model identity is:
- provider: nous
- model route: $SelectedModel
- upstream model: deepseek/deepseek-v4-flash

Codex Desktop is the visible app shell, but Hermes Agent executes the brain/tool loop.
Hermes runs under WSL/Linux. Convert Windows paths under $Workspace to WSL paths under $wslWorkspace.
"@

  $config = @"
model = "$SelectedModel"
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
name = "Asclepius Nous"
base_url = "http://127.0.0.1:8655/v1"
experimental_bearer_token = "local-codex-nous-cloud"
wire_api = "responses"
request_max_retries = 1
stream_max_retries = 1
stream_idle_timeout_ms = 300000

[projects.'C:\workspace\ai']
trust_level = "trusted"
"@

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $CodexHome "config.toml"), $config, $utf8NoBom)
  [System.IO.File]::WriteAllText($instructions, $instructionText, $utf8NoBom)
}

function Wait-ForFreshCodexWindow {
  param(
    [Parameter(Mandatory)]$Before,
    [Parameter(Mandatory)][datetime]$Deadline
  )

  $beforePids = @{}
  $beforeHandles = @{}
  foreach ($row in @($Before)) {
    $beforePids[[int]$row.Id] = $true
    if ([int64]$row.MainWindowHandle -ne 0) {
      $beforeHandles[[int64]$row.MainWindowHandle] = $true
    }
  }

  do {
    Start-Sleep -Milliseconds 500
    $after = @(Get-CodexProcessSnapshot)
    $newWindows = @($after | Where-Object {
      $_.MainWindowHandle -ne 0 -and
      -not $beforePids.ContainsKey([int]$_.Id) -and
      -not $beforeHandles.ContainsKey([int64]$_.MainWindowHandle)
    })

    if ($newWindows.Count -gt 0) {
      return $newWindows | Sort-Object Id | Select-Object -First 1
    }
  } while ((Get-Date) -lt $Deadline)

  return $null
}

if (-not (Test-Path -LiteralPath $ProbeScript)) {
  throw "Window identity probe script not found: $ProbeScript"
}
if (-not (Test-Path -LiteralPath $WatcherScript)) {
  throw "Window identity watcher script not found: $WatcherScript"
}

$before = @(Get-CodexProcessSnapshot)
$codexExe = Find-CodexDesktopExe
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tempRoot = Join-Path (Join-Path $env:USERPROFILE ".codex-nous-cloud\identity-smoke") $stamp
$codexHome = Join-Path $tempRoot "codex-home"
$electronUserData = Join-Path $tempRoot "electron-user-data"

New-Item -ItemType Directory -Force -Path $tempRoot, $codexHome, $electronUserData | Out-Null
Write-IsolatedConfig -CodexHome $codexHome -SelectedModel $Model -TempRoot $tempRoot

& (Join-Path $Root "Start-CodexNousCloudServices.ps1") | Out-Null

$env:CODEX_HOME = $codexHome
$env:CODEX_ELECTRON_USER_DATA_PATH = $electronUserData
$env:CODEX_CLOUD_WORKSPACE = $Workspace
$env:CODEX_HERMES_WORKDIR = ConvertTo-WslPath -Path $Workspace

$started = Start-Process -FilePath $codexExe -ArgumentList @("--open-project", $Workspace) -WorkingDirectory $Workspace -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$target = Wait-ForFreshCodexWindow -Before $before -Deadline $deadline

if (-not $target) {
  $after = @(Get-CodexProcessSnapshot)
  $newPids = @($after.Id | Where-Object { $before.Id -notcontains $_ })
  [pscustomobject]@{
    ok = $false
    reason = "No fresh Codex top-level window appeared. Refusing to modify an existing Codex window."
    started_process_id = $started.Id
    new_codex_process_ids = $newPids
    existing_codex_window_count = @($before | Where-Object { $_.MainWindowHandle -ne 0 }).Count
    temp_root = $tempRoot
  }
  exit 2
}

$watcherOnce = & $WatcherScript `
  -TargetProcessId $target.Id `
  -AppUserModelId $AppUserModelId `
  -WindowTitle $WindowTitle `
  -Once

$watcherRow = @($watcherOnce | Where-Object { $_ -is [pscustomobject] } | Select-Object -First 1)[0]
if (-not $watcherRow) {
  throw "Window identity watcher did not return a structured result."
}

$watcher = Start-Process -FilePath "powershell.exe" -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-WindowStyle", "Hidden",
  "-File", $WatcherScript,
  "-TargetProcessId", ([string]$target.Id),
  "-AppUserModelId", $AppUserModelId,
  "-WindowTitle", $WindowTitle,
  "-IntervalMilliseconds", "750",
  "-MaxSeconds", "30"
) -WorkingDirectory $Root -WindowStyle Hidden -PassThru

Start-Sleep -Seconds 3
$verifyOnce = & $WatcherScript `
  -TargetProcessId $target.Id `
  -AppUserModelId $AppUserModelId `
  -WindowTitle $WindowTitle `
  -Once

$verifyRow = @($verifyOnce | Where-Object { $_ -is [pscustomobject] } | Select-Object -First 1)[0]
if (-not $verifyRow) {
  throw "Window identity watcher did not return a structured verify result."
}
$afterTarget = Get-Process -Id $target.Id -ErrorAction Stop
$result = [pscustomobject]@{
  ok = ($verifyRow.ok -eq $true -and $verifyRow.visible_branded_count -gt 0)
  touched_existing_codex = $false
  started_process_id = $started.Id
  target_process_id = $target.Id
  target_hwnd = $verifyRow.hwnd
  target_window_count = $verifyRow.window_count
  visible_branded_count = $verifyRow.visible_branded_count
  target_title_before = $verifyRow.title_before
  target_title_after = $verifyRow.title_after
  process_main_window_title_after = $afterTarget.MainWindowTitle
  app_user_model_id_before = $verifyRow.app_user_model_id_before
  app_user_model_id_after = $verifyRow.app_user_model_id_after
  dark_titlebar = $verifyRow.dark_titlebar
  watcher_process_id = $watcher.Id
  watcher_once_ok = $watcherRow.ok
  temp_root = $tempRoot
  note = "Only a Codex PID/HWND absent from the pre-launch snapshot was modified. Existing Codex windows were not targeted."
}

if ($CloseWhenDone) {
  $p = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
  if ($p) {
    $null = $p.CloseMainWindow()
    Start-Sleep -Milliseconds 800
    if (-not $p.HasExited) {
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
  }
}

$result
