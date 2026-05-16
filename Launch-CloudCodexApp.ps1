param(
  [string]$Model,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = Join-Path $Root "codex-home"
$ElectronUserData = Join-Path $Root "electron-user-data"
$Workspace = "C:\workspace\ai"
$CloudModelsPath = Join-Path $Root "cloud-models.json"

function Set-CloudCodexModel {
  param([string]$SelectedModel)
  if ([string]::IsNullOrWhiteSpace($SelectedModel)) {
    return
  }
  $configPath = Join-Path $CodexHome "config.toml"
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Cloud-Codex config not found: $configPath"
  }
  $escaped = $SelectedModel.Replace("\", "\\").Replace('"', '\"')
  $content = Get-Content -Raw -LiteralPath $configPath
  if ($content -match '(?m)^model\s*=') {
    $content = [regex]::Replace($content, '(?m)^model\s*=.*$', "model = `"$escaped`"", 1)
  } else {
    $content = "model = `"$escaped`"`r`n" + $content
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
& (Join-Path $Root "Start-CodexNousCloudServices.ps1") | Out-Null
$ResolvedModel = Resolve-CloudCodexModel -RequestedModel $Model
Set-CloudCodexModel -SelectedModel $ResolvedModel

$CodexDesktopExe = Find-CodexDesktopExe
$CodexCli = (Get-Command codex.exe -ErrorAction SilentlyContinue).Source

$env:CODEX_HOME = $CodexHome
$env:CODEX_ELECTRON_USER_DATA_PATH = $ElectronUserData
if ($CodexCli) {
  $env:CODEX_CLI_PATH = $CodexCli
}

if ($DryRun) {
  [PSCustomObject]@{
    CodexDesktopExe = $CodexDesktopExe
    CodexHome = $CodexHome
    ElectronUserData = $ElectronUserData
    Workspace = $Workspace
    CodexCliPath = $CodexCli
    SelectedModel = $ResolvedModel
  }
  exit 0
}

Start-Process -FilePath $CodexDesktopExe -ArgumentList @("--open-project", $Workspace) -WorkingDirectory $Workspace | Out-Null
