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

function Test-InstalledLauncher {
  if ($SkipInstalled) {
    Add-Check "installed_launcher" "skipped"
    return
  }

  $script = Join-Path $InstalledRoot "Launch-CloudCodexApp.ps1"
  Assert-True (Test-Path -LiteralPath $script) "Installed real-Codex launcher not found: $script"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $InstalledRoot "Asclepius.exe"))) "Unsafe Asclepius host exe is still installed."
  $dryRun = & $script -DryRun
  if ($LASTEXITCODE -ne 0) {
    throw "Real-Codex launcher dry-run failed."
  }
  Assert-True ($dryRun.CodexDesktopExe -like "*Codex.exe") "Dry-run did not resolve the real Codex Desktop executable."
  Assert-True ($dryRun.CodexHome -like "*\.codex-nous-cloud\codex-home") "Dry-run did not use the isolated Asclepius Codex home."
  Add-Check "installed_launcher" $dryRun.CodexDesktopExe
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
  Assert-True ($target -match 'wscript\.exe$') "Shortcut target is $target, not the safe VBS launcher host."
  Assert-True ($shortcut.Arguments -like "*Launch-CloudCodexApp.vbs*") "Shortcut does not launch the real-Codex app VBS."
  Add-Check "desktop_shortcut" ("{0} {1}" -f $target, $shortcut.Arguments)
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

  foreach ($required in @("Launch-CloudCodexApp.ps1", "Launch-CloudCodexApp.vbs", "Test-Asclepius.ps1")) {
    Assert-True ($entries -contains $required) "Package missing $required"
  }

  foreach ($removed in @("AsclepiusHost.cs", "Build-AsclepiusHost.ps1", "AsclepiusApp.cs", "Build-AsclepiusApp.ps1")) {
    Assert-True (-not ($entries -contains $removed)) "Package should not include unsafe/fake app file $removed"
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
Test-InstalledLauncher
Test-Shortcut
Test-DefaultCodexUntouched
Test-Package

$Results | ForEach-Object { Write-Output $_ }
