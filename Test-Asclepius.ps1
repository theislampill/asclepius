param(
  [string]$InstalledRoot = (Join-Path $env:USERPROFILE ".codex-nous-cloud"),
  [switch]$SkipInstalled,
  [switch]$SkipPackage
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Results = New-Object System.Collections.Generic.List[string]
$script:LastPackagePath = $null

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

  & $python.Source -m py_compile `
    (Join-Path $Root "codex_nous_bridge.py") `
    (Join-Path $Root "sync_asclepius_token_usage.py") `
    (Join-Path $Root "asclepius_hermes_event_runner.py")
  if ($LASTEXITCODE -ne 0) {
    throw "Python bridge compile failed."
  }
  Add-Check "python_bridge" "bridge, event runner, and token sync"
}

function Test-WindowIdentityProbe {
  $probe = Join-Path $Root "Test-AsclepiusWindowIdentity.ps1"
  Assert-True (Test-Path -LiteralPath $probe) "Window identity probe script not found: $probe"
  $result = & $probe -KeepOpenSeconds 0
  $row = @($result | Where-Object { $_ -is [pscustomobject] } | Select-Object -First 1)[0]
  Assert-True ($null -ne $row) "Window identity probe did not return a structured result."
  Assert-True ($row.ok -eq $true) "Window identity probe did not set/read back the expected AppUserModelID and title."
  Assert-True ($row.touched_codex -eq $false) "Window identity probe unexpectedly touched a Codex process."
  Add-Check "window_identity_probe" ("{0} {1}" -f $row.hwnd, $row.app_user_model_id_after)
}

function Test-WindowIdentityWatcher {
  $watcher = Join-Path $Root "Start-AsclepiusWindowIdentityWatcher.ps1"
  Assert-True (Test-Path -LiteralPath $watcher) "Window identity watcher script not found: $watcher"
  $result = & $watcher -SelfTest
  $row = @($result | Where-Object { $_ -is [pscustomobject] } | Select-Object -First 1)[0]
  Assert-True ($null -ne $row) "Window identity watcher did not return a structured self-test result."
  Assert-True ($row.ok -eq $true) "Window identity watcher did not repair the disposable window title/AppUserModelID."
  Assert-True ($row.touched_codex -eq $false) "Window identity watcher self-test unexpectedly touched Codex."
  Add-Check "window_identity_watcher" ("{0} {1}" -f $row.repaired_title_after, $row.app_user_model_id_after)
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
  Add-Check "installed_desktop_auth" $dryRun.DesktopAuthMode
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
  Assert-True ($shortcut.Arguments -like "*Launch-AsclepiusProviderLauncher.vbs*") "Shortcut does not launch the Asclepius provider launcher VBS."
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

function Test-InstalledContextStatus {
  if ($SkipInstalled) {
    Add-Check "context_status" "skipped"
    return
  }

  $statusPath = Join-Path $InstalledRoot "asclepius-context-status.json"
  if (-not (Test-Path -LiteralPath $statusPath)) {
    Add-Check "context_status" "not generated yet"
    return
  }

  $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
  $notes = @($status.notes)
  Assert-True ($notes -contains "Codex usable context window is the true window Codex enforces for the current profile and auto-compaction.") "Context status does not document Codex-usable window semantics."
  Assert-True ($notes -contains "Hermes tool activity is parsed from Hermes Agent logs; it is not yet native Codex tool-call UI.") "Context status does not document Hermes tool activity semantics."

  if ($null -ne $status.latest_thread) {
    Assert-True ([int64]$status.latest_thread.context_window -gt 0) "Latest thread has no Codex-usable context window."
    Assert-True ([int64]$status.latest_thread.context_tokens_used -ge 0) "Latest thread has invalid context tokens used."
    if ($null -ne $status.latest_thread.tool_activity) {
      Assert-True ([int64]$status.latest_thread.tool_activity.total_tool_events -ge 0) "Tool activity count is invalid."
    }
    Add-Check "context_status" ("{0:n0}/{1:n0} tokens" -f [int64]$status.latest_thread.context_tokens_used, [int64]$status.latest_thread.context_window)
  } else {
    Add-Check "context_status" "no latest thread yet"
  }
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

  foreach ($required in @("Launch-AsclepiusProviderLauncher.ps1", "Launch-AsclepiusProviderLauncher.vbs", "Launch-CloudCodexApp.ps1", "Launch-CloudCodexApp.vbs", "Launch-CloudCodexModelPicker.ps1", "Launch-CloudCodexModelPicker.vbs", "Test-Asclepius.ps1", "Test-AsclepiusWindowIdentity.ps1", "Start-AsclepiusWindowIdentityWatcher.ps1", "Start-AsclepiusHermesTitlebarOverlay.ps1", "Start-AsclepiusCodexIdentitySmoke.ps1", "Get-AsclepiusHermesStatus.ps1", "asclepius_hermes_event_runner.py", "sync_asclepius_token_usage.py")) {
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
  $script:LastPackagePath = $zip.FullName
  Add-Check "package" ("{0} sha256={1}" -f $zip.FullName, $hash.Hash)
}

function Test-SecretEgress {
  if ($SkipPackage) {
    Add-Check "secret_egress" "skipped"
    return
  }

  Assert-True (Test-Path -LiteralPath $script:LastPackagePath) "No package path available for secret egress scan."
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($script:LastPackagePath)
  $findings = New-Object System.Collections.Generic.List[string]
  try {
    $forbiddenEntries = @($archive.Entries.FullName | Where-Object {
      $_ -match '(^|/)(auth\.json|cloud-secrets\.json|\.env(\..*)?|.*\.token|.*\.key)$' -or
      $_ -match '^(codex-home|electron-user-data|logs)/' -or
      $_ -match '(^|/)(state|logs)_\d*\.sqlite' -or
      $_ -match '(^|/)bridge-state\.json'
    })
    foreach ($entry in $forbiddenEntries) {
      $findings.Add("forbidden entry: $entry") | Out-Null
    }

    $patterns = [ordered]@{
      openai_key = 'sk-(proj-)?[A-Za-z0-9_-]{20,}'
      github_token = 'github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}'
      jwt = 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
      private_key = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
      aws_key = 'AKIA[0-9A-Z]{16}'
      slack_token = 'xox[baprs]-[A-Za-z0-9-]{20,}'
      token_value = '(?i)(access_token|refresh_token|id_token|session_token|cookie)\s*[:=]\s*["''][^"'']{12,}["'']'
    }

    foreach ($entry in @($archive.Entries)) {
      if ($entry.Length -gt 2097152) { continue }
      if ($entry.FullName -notmatch '\.(ps1|vbs|py|md|toml|json|txt)$') { continue }
      $reader = New-Object System.IO.StreamReader($entry.Open())
      try {
        $text = $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
      foreach ($name in $patterns.Keys) {
        if ($text -match $patterns[$name]) {
          $findings.Add("$name pattern in $($entry.FullName)") | Out-Null
        }
      }
    }
  } finally {
    $archive.Dispose()
  }

  Assert-True ($findings.Count -eq 0) ("Secret egress scan found: {0}" -f ($findings -join "; "))
  Add-Check "secret_egress" "package entries and text payloads clean"
}

Test-PowerShellSyntax
Test-PythonBridge
Test-WindowIdentityProbe
Test-WindowIdentityWatcher
Test-InstalledLauncher
Test-Shortcut
Test-DefaultCodexUntouched
Test-InstalledContextStatus
Test-Package
Test-SecretEgress

$Results | ForEach-Object { Write-Output $_ }
