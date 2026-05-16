param(
  [string]$Model,
  [string]$Workspace = "C:\workspace\ai",
  [switch]$DryRun,
  [switch]$HostInfoJson,
  [switch]$NoWindowIdentity
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = Join-Path $Root "codex-home"
$ElectronUserData = Join-Path $Root "electron-user-data"
$CloudModelsPath = Join-Path $Root "cloud-models.json"
$InstructionsPath = Join-Path $Root "cloud-codex-instructions.md"
$WindowIdentityProbe = Join-Path $Root "Test-AsclepiusWindowIdentity.ps1"
$WindowIdentityWatcher = Join-Path $Root "Start-AsclepiusWindowIdentityWatcher.ps1"
$AppUserModelId = "NousResearch.Asclepius.Codex"
$WindowTitle = "Asclepius"

function Get-CodexProcessSnapshot {
  $asclepiusUserData = [System.IO.Path]::GetFullPath($ElectronUserData).TrimEnd('\')
  $userDataByPid = @{}
  $parentByPid = @{}
  $knownCodexPids = @{}
  $asclepiusFamilyPids = @{}
  try {
    $cimRows = @(Get-CimInstance Win32_Process -Filter "name = 'Codex.exe'" -ErrorAction Stop)
    foreach ($row in $cimRows) {
      $pid = [int]$row.ProcessId
      $parentByPid[$pid] = [int]$row.ParentProcessId
      $knownCodexPids[$pid] = $true

      $commandLine = [string]$row.CommandLine
      $userData = $null
      if ($commandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') {
        $userData = if ($matches[1]) { $matches[1] } else { $matches[2] }
      } elseif ($commandLine -match '--user-data-dir\s+(?:"([^"]+)"|(\S+))') {
        $userData = if ($matches[1]) { $matches[1] } else { $matches[2] }
      }
      if (-not [string]::IsNullOrWhiteSpace($userData)) {
        try {
          $userDataByPid[$pid] = [System.IO.Path]::GetFullPath($userData).TrimEnd('\')
        } catch {
          $userDataByPid[$pid] = $userData.TrimEnd('\')
        }
      }
    }

    foreach ($pid in @($userDataByPid.Keys)) {
      $userData = $userDataByPid[$pid]
      if (-not $userData.Equals($asclepiusUserData, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
      }

      $current = [int]$pid
      for ($i = 0; $i -lt 12; $i++) {
        $asclepiusFamilyPids[$current] = $true
        if (-not $parentByPid.ContainsKey($current)) { break }
        $parent = [int]$parentByPid[$current]
        if (-not $knownCodexPids.ContainsKey($parent)) { break }
        $current = $parent
      }
    }
  } catch {}

  $rows = @()
  foreach ($name in @("Codex", "codex")) {
    $rows += Get-Process -Name $name -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path.EndsWith("\Codex.exe", [System.StringComparison]::OrdinalIgnoreCase) } |
      ForEach-Object {
        $userData = $userDataByPid[[int]$_.Id]
        [pscustomobject]@{
          Id = $_.Id
          MainWindowHandle = [int64]$_.MainWindowHandle
          MainWindowTitle = $_.MainWindowTitle
          Path = $_.Path
          UserDataDir = $userData
          IsAsclepiusProfile = $asclepiusFamilyPids.ContainsKey([int]$_.Id)
        }
      }
  }
  $rows | Sort-Object Id -Unique
}

function Wait-ForAsclepiusCodexWindow {
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
    $asclepiusTargets = @($after | Where-Object {
      $_.IsAsclepiusProfile -and
      $_.MainWindowHandle -ne 0
    })
    $freshAsclepius = @($asclepiusTargets | Where-Object {
      $_.MainWindowHandle -ne 0 -and
      -not $beforePids.ContainsKey([int]$_.Id) -and
      -not $beforeHandles.ContainsKey([int64]$_.MainWindowHandle)
    })
    if ($freshAsclepius.Count -gt 0) {
      return $freshAsclepius | Sort-Object Id | Select-Object -First 1
    }
    if ($asclepiusTargets.Count -gt 0) {
      return $asclepiusTargets | Sort-Object Id | Select-Object -First 1
    }

    $freshFallback = @($after | Where-Object {
      $_.MainWindowHandle -ne 0 -and
      -not $beforePids.ContainsKey([int]$_.Id) -and
      -not $beforeHandles.ContainsKey([int64]$_.MainWindowHandle)
    })
    if ($freshFallback.Count -gt 0) {
      return $freshFallback | Sort-Object Id | Select-Object -First 1
    }
  } while ((Get-Date) -lt $Deadline)

  return $null
}

function Ensure-CodexAuthLink {
  $defaultAuth = Join-Path $env:USERPROFILE ".codex\auth.json"
  $isolatedAuth = Join-Path $CodexHome "auth.json"
  if (-not (Test-Path -LiteralPath $defaultAuth)) { return "default auth missing" }

  if (Test-Path -LiteralPath $isolatedAuth) {
    try {
      $defaultItem = Get-Item -LiteralPath $defaultAuth -Force
      $isolatedItem = Get-Item -LiteralPath $isolatedAuth -Force
      if (-not $isolatedItem.PSIsContainer -and $defaultItem.Length -eq $isolatedItem.Length) {
        $defaultHash = (Get-FileHash -LiteralPath $defaultAuth -Algorithm SHA256).Hash
        $isolatedHash = (Get-FileHash -LiteralPath $isolatedAuth -Algorithm SHA256).Hash
        if ($defaultHash -eq $isolatedHash) {
          return "isolated auth current"
        }
      }
    } catch {}

    $isolatedFull = [System.IO.Path]::GetFullPath($isolatedAuth)
    $codexHomeFull = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\') + '\'
    if (-not $isolatedFull.StartsWith($codexHomeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to replace auth outside the isolated Asclepius Codex home."
    }
    Remove-Item -LiteralPath $isolatedAuth -Force -ErrorAction SilentlyContinue
  }

  try {
    New-Item -ItemType HardLink -Path $isolatedAuth -Target $defaultAuth -Force | Out-Null
    return "linked to default Codex auth"
  } catch {
    Copy-Item -LiteralPath $defaultAuth -Destination $isolatedAuth -Force
    return "copied default Codex auth"
  }
}

function Get-DefaultCodexElectronUserDataRoot {
  $candidates = New-Object System.Collections.Generic.List[string]

  try {
    Resolve-Path (Join-Path $env:LOCALAPPDATA "Packages\OpenAI.Codex_*\LocalCache\Roaming\Codex") -ErrorAction Stop |
      Sort-Object Path -Descending |
      ForEach-Object { $candidates.Add($_.Path) }
  } catch {}

  foreach ($path in @(
    (Join-Path $env:APPDATA "Codex"),
    (Join-Path $env:APPDATA "OpenAI\Codex"),
    (Join-Path $env:LOCALAPPDATA "OpenAI\Codex")
  )) {
    $candidates.Add($path)
  }

  $isolatedFull = [System.IO.Path]::GetFullPath($ElectronUserData).TrimEnd('\')
  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $candidateFull = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
    if ($candidateFull.Equals($isolatedFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not (Test-Path -LiteralPath $candidateFull)) { continue }
    if (
      (Test-Path -LiteralPath (Join-Path $candidateFull "Local State")) -or
      (Test-Path -LiteralPath (Join-Path $candidateFull "Network\Cookies")) -or
      (Test-Path -LiteralPath (Join-Path $candidateFull "Local Storage"))
    ) {
      return $candidateFull
    }
  }

  return $null
}

function Copy-DesktopAuthItem {
  param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$DestinationRoot,
    [Parameter(Mandatory)][string]$RelativePath
  )

  $source = Join-Path $SourceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $source)) { return "missing" }

  $dest = Join-Path $DestinationRoot $RelativePath
  $destFull = [System.IO.Path]::GetFullPath($dest)
  $destRootFull = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\') + '\'
  if (-not $destFull.StartsWith($destRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to copy desktop auth state outside the isolated Asclepius Electron profile."
  }

  $sourceItem = Get-Item -LiteralPath $source -Force
  $destParent = Split-Path -Parent $dest
  if ($destParent) {
    New-Item -ItemType Directory -Force -Path $destParent | Out-Null
  }

  if ($sourceItem.PSIsContainer) {
    if (Test-Path -LiteralPath $dest) {
      $destItem = Get-Item -LiteralPath $dest -Force
      if (-not $destItem.PSIsContainer) {
        Remove-Item -LiteralPath $dest -Force
      }
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Get-ChildItem -LiteralPath $source -Force -ErrorAction Stop |
      ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force -ErrorAction Stop
      }
    return "copied"
  }

  if (Test-Path -LiteralPath $dest) {
    $destItem = Get-Item -LiteralPath $dest -Force
    if ($destItem.PSIsContainer) {
      Remove-Item -LiteralPath $dest -Recurse -Force
    }
  }
  Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
  return "copied"
}

function Sync-CodexDesktopAuthState {
  $sourceRoot = Get-DefaultCodexElectronUserDataRoot
  if (-not $sourceRoot) { return "default desktop auth missing" }

  $sourceFull = [System.IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
  $destFull = [System.IO.Path]::GetFullPath($ElectronUserData).TrimEnd('\')
  if ($sourceFull.Equals($destFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return "shared desktop auth profile"
  }

  New-Item -ItemType Directory -Force -Path $ElectronUserData | Out-Null
  $relativeItems = @(
    "Local State",
    "Preferences",
    "Network",
    "Local Storage",
    "Session Storage",
    "IndexedDB",
    "Partitions",
    "SharedStorage",
    "SharedStorage-wal",
    "DIPS"
  )

  $copied = 0
  $failed = 0
  foreach ($relative in $relativeItems) {
    try {
      $result = Copy-DesktopAuthItem -SourceRoot $sourceFull -DestinationRoot $destFull -RelativePath $relative
      if ($result -eq "copied") { $copied++ }
    } catch {
      $failed++
    }
  }

  if ($failed -gt 0) {
    return "desktop auth partially synced ($copied copied, $failed failed)"
  }
  return "desktop auth synced ($copied items)"
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

function Write-CloudCodexInstructions {
  param([string]$SelectedModel)
  $route = if ([string]::IsNullOrWhiteSpace($SelectedModel)) { "nous/deepseek/deepseek-v4-flash" } else { $SelectedModel }
  $provider = if ($route -match '^([^/:]+)[:/]') { $matches[1] } else { "nous" }
  $upstream = if ($route -match '^[^/:]+[:/](.+)$') { $matches[1] } else { $route }
  $wslWorkspace = ConvertTo-WslPath -Path $Workspace
  $text = @"
In this isolated Asclepius / Cloud-Codex profile, runtime model identity is:
- provider: $provider
- model route: $route
- upstream model: $upstream

When the user asks what model you are, answer with this runtime provider/model.
Do not describe the runtime model as GPT-5 unless the user is asking about the
Codex product lineage rather than the active model backend.

Important runtime boundary:
- Codex Desktop is the visible app shell, but Hermes Agent executes the brain/tool loop.
- Hermes runs under WSL/Linux. Convert Windows paths under $Workspace to WSL paths under $wslWorkspace.
- The Codex sandbox dropdown is UI/profile intent, not a hard sandbox for Hermes tools.
"@
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($InstructionsPath, $text, $utf8NoBom)
}

function Set-CloudCodexModel {
  param([string]$SelectedModel)
  if ([string]::IsNullOrWhiteSpace($SelectedModel)) {
    return
  }
  $provider = if ($SelectedModel -match '^([^/:]+)[:/]') { $matches[1] } else { "nous" }
  $upstream = if ($SelectedModel -match '^[^/:]+[:/](.+)$') { $matches[1] } else { $SelectedModel }
  $providerName = "@$provider`:$upstream via Hermes"
  $configPath = Join-Path $CodexHome "config.toml"
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Cloud-Codex config not found: $configPath"
  }
  $escaped = $SelectedModel.Replace("\", "\\").Replace('"', '\"')
  $escapedProviderName = $providerName.Replace("\", "\\").Replace('"', '\"')
  $content = Get-Content -Raw -LiteralPath $configPath
  if ($content -match '(?m)^model\s*=') {
    $content = [regex]::Replace($content, '(?m)^model\s*=.*$', "model = `"$escaped`"", 1)
  } else {
    $content = "model = `"$escaped`"`r`n" + $content
  }
  if ($content -match '(?m)^name\s*=\s*".*"$') {
    $content = [regex]::Replace($content, '(?m)^name\s*=.*$', "name = `"$escapedProviderName`"", 1)
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($configPath, $content, $utf8NoBom)
}

function Resolve-CloudCodexModel {
  param([string]$RequestedModel)
  if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
    return $RequestedModel
  }
  if (Test-Path -LiteralPath $CloudModelsPath) {
    try {
      $catalog = Get-Content -Raw -LiteralPath $CloudModelsPath | ConvertFrom-Json
      if ($catalog.default_model) { return [string]$catalog.default_model }
    } catch {}
  }
  return $null
}

function Find-CodexDesktopExe {
  $candidates = New-Object System.Collections.Generic.List[string]

  Get-Process -Name Codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.EndsWith("\app\Codex.exe", [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $candidates.Add($_.Path) }

  try {
    Resolve-Path "C:\Program Files\WindowsApps\OpenAI.Codex_*\app\Codex.exe" -ErrorAction Stop |
      ForEach-Object { $candidates.Add($_.Path) }
  } catch {}

  try {
    where.exe codex 2>$null |
      Where-Object { $_ -match "\\app\\resources\\codex(\\.exe)?$" } |
      ForEach-Object {
        $appDir = Split-Path -Parent (Split-Path -Parent $_)
        $candidates.Add((Join-Path $appDir "Codex.exe"))
      }
  } catch {}

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "Could not find the installed Codex desktop executable."
}

New-Item -ItemType Directory -Force -Path $CodexHome, $ElectronUserData | Out-Null
$AuthMode = Ensure-CodexAuthLink
$DesktopAuthMode = Sync-CodexDesktopAuthState
$ResolvedModel = Resolve-CloudCodexModel -RequestedModel $Model
Set-CloudCodexModel -SelectedModel $ResolvedModel
Write-CloudCodexInstructions -SelectedModel $ResolvedModel

$env:CODEX_CLOUD_WORKSPACE = $Workspace
$env:CODEX_HERMES_WORKDIR = ConvertTo-WslPath -Path $Workspace
& (Join-Path $Root "Start-CodexNousCloudServices.ps1") | Out-Null

$CodexDesktopExe = Find-CodexDesktopExe
$CodexCli = (Get-Command codex.exe -ErrorAction SilentlyContinue).Source

$env:CODEX_HOME = $CodexHome
$env:CODEX_ELECTRON_USER_DATA_PATH = $ElectronUserData
$env:CODEX_CLOUD_WORKSPACE = $Workspace
$env:CODEX_HERMES_WORKDIR = ConvertTo-WslPath -Path $Workspace
if ($CodexCli) {
  $env:CODEX_CLI_PATH = $CodexCli
}

$launchInfo = [PSCustomObject]@{
  CodexDesktopExe = $CodexDesktopExe
  CodexHome = $CodexHome
  ElectronUserData = $ElectronUserData
  Workspace = $Workspace
  CodexCliPath = $CodexCli
  SelectedModel = $ResolvedModel
  HermesWorkdir = ConvertTo-WslPath -Path $Workspace
  AuthMode = $AuthMode
  DesktopAuthMode = $DesktopAuthMode
  AppUserModelId = $AppUserModelId
  WindowTitle = $WindowTitle
  WindowIdentityWatcher = $WindowIdentityWatcher
}

if ($HostInfoJson) {
  $launchInfo | ConvertTo-Json -Compress
  exit 0
}

if ($DryRun) {
  $launchInfo
  exit 0
}

$before = @(Get-CodexProcessSnapshot)
$started = Start-Process -FilePath $CodexDesktopExe -ArgumentList @("--open-project", $Workspace) -WorkingDirectory $Workspace -PassThru

if (-not $NoWindowIdentity) {
  $target = Wait-ForAsclepiusCodexWindow -Before $before -Deadline (Get-Date).AddSeconds(60)
  if ($target) {
    if (Test-Path -LiteralPath $WindowIdentityWatcher) {
      & $WindowIdentityWatcher `
        -TargetProcessId $target.Id `
        -AppUserModelId $AppUserModelId `
        -WindowTitle $WindowTitle `
        -Once | Out-Null
      Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", $WindowIdentityWatcher,
        "-TargetProcessId", ([string]$target.Id),
        "-AppUserModelId", $AppUserModelId,
        "-WindowTitle", $WindowTitle,
        "-IntervalMilliseconds", "750"
      ) -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
    } elseif (Test-Path -LiteralPath $WindowIdentityProbe) {
      & $WindowIdentityProbe `
        -TargetProcessId $target.Id `
        -AllowCodexTarget `
        -AppUserModelId $AppUserModelId `
        -WindowTitle $WindowTitle `
        -KeepOpenSeconds 0 | Out-Null
    }
  }
}
