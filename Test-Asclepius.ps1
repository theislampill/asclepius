param(
  [string]$InstalledRoot = (Join-Path $env:USERPROFILE ".codex-nous-cloud"),
  [switch]$SkipInstalled,
  [switch]$SkipPackage
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Results = New-Object System.Collections.Generic.List[string]

function Add-Check {
  param([string]$Name, [string]$Value = "ok")
  $Results.Add(("{0}: {1}" -f $Name, $Value)) | Out-Null
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Test-PowerShellSyntax {
  $scripts = Get-ChildItem -LiteralPath $Root -Filter "*.ps1" -File
  foreach ($script in $scripts) {
    [scriptblock]::Create([System.IO.File]::ReadAllText($script.FullName)) | Out-Null
  }
  Add-Check "powershell_syntax" ("{0} scripts" -f $scripts.Count)
}

function Test-PythonBridge {
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) {
    Add-Check "python_bridge" "skipped: python not found"
    return
  }

  & $python.Source -m py_compile (Join-Path $Root "codex_nous_bridge.py")
  if ($LASTEXITCODE -ne 0) {
    throw "Python bridge compile failed."
  }
  Add-Check "python_bridge"
}

function Test-SourceBuild {
  & (Join-Path $Root "Build-AsclepiusApp.ps1") | Out-Null
  Assert-True (Test-Path -LiteralPath (Join-Path $Root "Asclepius.exe")) "Source Asclepius.exe was not built."
  Add-Check "source_build"
}

function Test-InstalledApp {
  if ($SkipInstalled) {
    Add-Check "installed_app" "skipped"
    return
  }

  $exe = Join-Path $InstalledRoot "Asclepius.exe"
  Assert-True (Test-Path -LiteralPath $exe) "Installed Asclepius.exe not found: $exe"

  & $exe --smoke
  if ($LASTEXITCODE -ne 0) {
    throw "Installed Asclepius --smoke failed."
  }
  $smokePath = Join-Path $InstalledRoot "asclepius-smoke.json"
  $smoke = Get-Content -LiteralPath $smokePath -Raw | ConvertFrom-Json
  Assert-True ([bool]$smoke.scripts_present) "Installed smoke did not find required scripts."
  Assert-True ([bool]$smoke.config_present) "Installed smoke did not find isolated Codex config."

  & $exe --window-smoke
  if ($LASTEXITCODE -ne 0) {
    throw "Installed Asclepius --window-smoke failed."
  }
  $windowSmokePath = Join-Path $InstalledRoot "asclepius-window-smoke.json"
  $windowSmoke = Get-Content -LiteralPath $windowSmokePath -Raw | ConvertFrom-Json
  Assert-True ($windowSmoke.process -eq "Asclepius") "Window smoke process was $($windowSmoke.process), not Asclepius."
  Assert-True ($windowSmoke.window_title -eq "Asclepius") "Window smoke title was $($windowSmoke.window_title), not Asclepius."
  Assert-True ([double]($windowSmoke.contrast_text_background) -ge 4.5) "Text/background contrast is below WCAG AA."
  Assert-True ([double]($windowSmoke.contrast_muted_surface) -ge 4.5) "Muted/surface contrast is below WCAG AA."
  Assert-True ([int]($windowSmoke.keyboard_controls) -ge 5) "Expected keyboard-operable controls in the app."
  Assert-True ([int]($windowSmoke.accessible_named_controls) -ge 8) "Expected accessible names on major controls."
  Add-Check "installed_app" ("workspace {0}" -f $smoke.workspace)
}

function Test-Shortcut {
  if ($SkipInstalled) {
    Add-Check "desktop_shortcut" "skipped"
    return
  }

  $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "asclepius.lnk"
  Assert-True (Test-Path -LiteralPath $shortcutPath) "Desktop shortcut not found: $shortcutPath"
  $wsh = New-Object -ComObject WScript.Shell
  $shortcut = $wsh.CreateShortcut($shortcutPath)
  $target = $shortcut.TargetPath
  Assert-True (Test-Path -LiteralPath $target) "Shortcut target does not exist: $target"
  Assert-True ($target -ieq (Join-Path $InstalledRoot "Asclepius.exe")) "Shortcut target is $target, not installed Asclepius.exe."
  Add-Check "desktop_shortcut" $target
}

function Test-DefaultCodexUntouched {
  $defaultConfig = Join-Path $env:USERPROFILE ".codex\config.toml"
  if (-not (Test-Path -LiteralPath $defaultConfig)) {
    Add-Check "default_codex_profile" "not present"
    return
  }

  $modelLine = Select-String -LiteralPath $defaultConfig -Pattern '^model\s*=' -CaseSensitive | Select-Object -First 1
  Add-Check "default_codex_profile" ($modelLine.Line.Trim())
}

function Test-Package {
  if ($SkipPackage) {
    Add-Check "package" "skipped"
    return
  }

  & (Join-Path $Root "Package-CloudCodex.ps1") | Out-Null
  $zip = Get-ChildItem -LiteralPath (Join-Path $Root "dist") -Filter "*.zip" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  Assert-True ($null -ne $zip) "Package zip was not created."

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
  try {
    $entries = @($archive.Entries.FullName)
  } finally {
    $archive.Dispose()
  }

  foreach ($required in @("AsclepiusApp.cs", "Build-AsclepiusApp.ps1", "Test-Asclepius.ps1")) {
    Assert-True ($entries -contains $required) "Package missing $required"
  }

  $forbidden = $entries | Where-Object {
    $_ -match '\.exe$' -or
    $_ -match '(^|/)asclepius-.*smoke\.json$' -or
    $_ -match '(^|/)bridge-state\.json' -or
    $_ -match '(^|/)cloud-secrets\.json' -or
    $_ -match '^(codex-home|electron-user-data|logs)/'
  }
  Assert-True (-not $forbidden) ("Package contains generated/private entries: {0}" -f ($forbidden -join ", "))

  $hash = Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256
  Add-Check "package" ("{0} sha256={1}" -f $zip.FullName, $hash.Hash)
}

Test-PowerShellSyntax
Test-PythonBridge
Test-SourceBuild
Test-InstalledApp
Test-Shortcut
Test-DefaultCodexUntouched
Test-Package

$Results | ForEach-Object { Write-Output $_ }
