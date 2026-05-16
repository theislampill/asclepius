$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = Join-Path $Root "codex-home"
$ModelFile = Join-Path $Root "cloud-models.json"
$LegacyModelFile = Join-Path $Root "nous-models.json"
$SecretsFile = Join-Path $Root "cloud-secrets.json"
$ConfigFile = Join-Path $CodexHome "config.toml"
$DefaultModel = "nous/deepseek/deepseek-v4-flash"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$script:Theme = @{
  Window = [System.Drawing.Color]::FromArgb(18, 18, 18)
  Panel = [System.Drawing.Color]::FromArgb(31, 31, 31)
  Control = [System.Drawing.Color]::FromArgb(44, 44, 44)
  ControlLight = [System.Drawing.Color]::FromArgb(57, 57, 57)
  Text = [System.Drawing.Color]::FromArgb(245, 245, 245)
  Muted = [System.Drawing.Color]::FromArgb(176, 176, 176)
  Accent = [System.Drawing.Color]::FromArgb(97, 154, 255)
}

function Set-AsclepiusTheme {
  param([Parameter(Mandatory)]$Control)
  $Control.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $Control.ForeColor = $script:Theme.Text
  if ($Control -is [System.Windows.Forms.Form]) {
    $Control.BackColor = $script:Theme.Window
  } elseif ($Control -is [System.Windows.Forms.Button]) {
    $Control.BackColor = $script:Theme.Control
    $Control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Control.FlatAppearance.BorderColor = $script:Theme.ControlLight
    $Control.FlatAppearance.MouseOverBackColor = $script:Theme.ControlLight
  } elseif ($Control -is [System.Windows.Forms.TextBox] -or $Control -is [System.Windows.Forms.ComboBox]) {
    $Control.BackColor = $script:Theme.Panel
    $Control.ForeColor = $script:Theme.Text
  } elseif ($Control -is [System.Windows.Forms.Label]) {
    $Control.BackColor = [System.Drawing.Color]::Transparent
  }

  foreach ($child in $Control.Controls) {
    Set-AsclepiusTheme -Control $child
  }
}

function Get-CurrentModel {
  if (Test-Path -LiteralPath $ConfigFile) {
    $match = Select-String -LiteralPath $ConfigFile -Pattern '^\s*model\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($match -and $match.Matches.Count -gt 0) {
      $value = $match.Matches[0].Groups[1].Value
      if ($value -notmatch '^[a-z]+[:/]') { return "nous/$value" }
      return $value
    }
  }
  return $DefaultModel
}

function Get-Secrets {
  if (-not (Test-Path -LiteralPath $SecretsFile)) { return [pscustomobject]@{} }
  try {
    return Get-Content -Raw -LiteralPath $SecretsFile | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{}
  }
}

function Save-Secrets {
  param($Secrets)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($SecretsFile, ($Secrets | ConvertTo-Json -Depth 8), $utf8NoBom)
}

function Get-OpenRouterKeyStatus {
  if (-not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
    return "present from OPENROUTER_API_KEY"
  }
  $secrets = Get-Secrets
  if ($secrets.PSObject.Properties.Name -contains "openrouter_api_key" -and -not [string]::IsNullOrWhiteSpace($secrets.openrouter_api_key)) {
    return "present in Cloud-Codex secrets"
  }
  return "missing"
}

function Get-NousKeyStatus {
  if (-not [string]::IsNullOrWhiteSpace($env:NOUS_API_KEY)) {
    return "direct API key present from NOUS_API_KEY"
  }
  $secrets = Get-Secrets
  if ($secrets.PSObject.Properties.Name -contains "nous_api_key" -and -not [string]::IsNullOrWhiteSpace($secrets.nous_api_key)) {
    return "direct API key present in Cloud-Codex secrets"
  }
  return "Hermes OAuth via proxy; no API key required for free Nous models"
}

function Set-ProviderKey {
  param(
    [Parameter(Mandatory)][string]$ProviderName,
    [Parameter(Mandatory)][string]$SecretName,
    [Parameter(Mandatory)][string]$CurrentStatus
  )
  $prompt = "Paste your $ProviderName API key. It will be saved only for this isolated Cloud-Codex profile.`r`nCurrent status: $CurrentStatus"
  $key = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, "$ProviderName API key", "")
  if ([string]::IsNullOrWhiteSpace($key)) { return $false }
  $secrets = Get-Secrets
  if ($secrets.PSObject.Properties.Name -contains $SecretName) {
    $secrets.$SecretName = $key.Trim()
  } else {
    $secrets | Add-Member -NotePropertyName $SecretName -NotePropertyValue $key.Trim()
  }
  Save-Secrets -Secrets $secrets
  return $true
}

function Clear-ProviderKey {
  param([Parameter(Mandatory)][string]$SecretName)
  $secrets = Get-Secrets
  if ($secrets.PSObject.Properties.Name -contains $SecretName) {
    $secrets.$SecretName = ""
    Save-Secrets -Secrets $secrets
  }
}

function Load-Models {
  param([switch]$ForceRefresh)
  & (Join-Path $Root "Start-CodexNousCloudServices.ps1") -NoCatalogRefresh | Out-Null
  if ($ForceRefresh -or -not (Test-Path -LiteralPath $ModelFile)) {
    & (Join-Path $Root "Refresh-NousCatalog.ps1") | Out-Null
  }
  $path = if (Test-Path -LiteralPath $ModelFile) { $ModelFile } else { $LegacyModelFile }
  $data = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
  return $data
}

function Test-CodexDesktopInstalled {
  try {
    $codex = Resolve-Path "C:\Program Files\WindowsApps\OpenAI.Codex_*\app\Codex.exe" -ErrorAction Stop |
      Sort-Object Path -Descending |
      Select-Object -First 1
    return $null -ne $codex
  } catch {
    return $false
  }
}

function Test-WslUbuntuInstalled {
  $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
  if (-not $wsl) { return $false }
  try {
    $distros = & $wsl.Source -l -q 2>$null
    return @($distros) -contains "Ubuntu"
  } catch {
    return $false
  }
}

function Test-HermesInstalled {
  $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
  if (-not $wsl) { return $false }
  try {
    $out = & $wsl.Source -d Ubuntu -- bash -lc 'test -x "$HOME/.local/bin/hermes" && echo ok' 2>$null
    return ($LASTEXITCODE -eq 0 -and @($out) -contains "ok")
  } catch {
    return $false
  }
}

function Test-PythonInstalled {
  return $null -ne (Get-Command python -ErrorAction SilentlyContinue)
}

function Start-DependencyInstall {
  param([Parameter(Mandatory)][string]$Target)
  $script = Join-Path $Root "Install-AsclepiusDependency.ps1"
  if (-not (Test-Path -LiteralPath $script)) {
    $status.Text = "Dependency installer not found: $script"
    return
  }
  Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $script,
    "-Target", $Target
  ) -WorkingDirectory $Root | Out-Null
  $status.Text = "$Target install window opened. Finish it, then click Refresh Checks."
}

function Get-DefaultModelFromCatalog {
  if ($script:Catalog -and $script:Catalog.default_model) {
    return [string]$script:Catalog.default_model
  }
  return $DefaultModel
}

function Invoke-BridgeSmoke {
  param([string]$Model)
  $body = @{
    model = $Model
    input = "Reply only with: ok"
    stream = $false
  } | ConvertTo-Json -Depth 8
  $resp = Invoke-RestMethod -Uri "http://127.0.0.1:8655/v1/responses" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120
  $text = ""
  foreach ($item in @($resp.output)) {
    if ($item.type -eq "message") {
      foreach ($content in @($item.content)) {
        if ($content.text) { $text += $content.text }
      }
    }
  }
  return $text.Trim()
}

function Launch-CloudCodex {
  param([string]$Model)
  $script = Join-Path $Root "Launch-CloudCodexApp.ps1"
  Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden",
    "-File", $script,
    "-Model", $Model
  ) -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
}

function Test-ModelCanRun {
  param($Model)
  if (-not $Model) { return $false }
  if ($Model.provider -eq "openrouter" -and (Get-OpenRouterKeyStatus) -eq "missing") {
    [System.Windows.Forms.MessageBox]::Show(
      "This is an OpenRouter model, but Cloud-Codex does not have an OpenRouter API key yet.",
      "OpenRouter key missing",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return $false
  }

  if ($Model.billing -eq "paid") {
    $message = "This selection is marked PAID.`r`n`r`nPortal: $($Model.provider_display)`r`nModel: $($Model.model_id)`r`nPrice: $($Model.price_text)`r`n`r`nContinue?"
    $answer = [System.Windows.Forms.MessageBox]::Show(
      $message,
      "Confirm paid cloud model",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
  }

  if ($Model.billing -eq "unknown") {
    $message = "Cloud-Codex could not confirm the price for this model.`r`n`r`nPortal: $($Model.provider_display)`r`nModel: $($Model.model_id)`r`n`r`nContinue?"
    $answer = [System.Windows.Forms.MessageBox]::Show(
      $message,
      "Confirm unknown cloud price",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
  }

  return $true
}

$script:Catalog = $null
$script:AllModels = @()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Asclepius"
$form.Size = New-Object System.Drawing.Size(960, 640)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Asclepius model and portal"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 18)
$title.Size = New-Object System.Drawing.Size(900, 26)
$form.Controls.Add($title)

$filter = New-Object System.Windows.Forms.TextBox
$filter.Location = New-Object System.Drawing.Point(18, 50)
$filter.Size = New-Object System.Drawing.Size(910, 26)
if ($filter.PSObject.Properties.Name -contains "PlaceholderText") {
  $filter.PlaceholderText = "Filter by portal, model, free, paid, deepseek, stepfun..."
}
$form.Controls.Add($filter)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.Location = New-Object System.Drawing.Point(18, 84)
$combo.Size = New-Object System.Drawing.Size(910, 28)
$combo.DropDownStyle = "DropDownList"
$combo.DisplayMember = "display"
$form.Controls.Add($combo)

$details = New-Object System.Windows.Forms.Label
$details.Text = "Loading cloud catalog..."
$details.Location = New-Object System.Drawing.Point(18, 122)
$details.Size = New-Object System.Drawing.Size(910, 90)
$form.Controls.Add($details)

$authSummary = New-Object System.Windows.Forms.Label
$authSummary.Text = "Checking provider auth..."
$authSummary.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$authSummary.Location = New-Object System.Drawing.Point(18, 220)
$authSummary.Size = New-Object System.Drawing.Size(910, 28)
$form.Controls.Add($authSummary)

$status = New-Object System.Windows.Forms.Label
$status.Text = ""
$status.Location = New-Object System.Drawing.Point(18, 250)
$status.Size = New-Object System.Drawing.Size(910, 34)
$form.Controls.Add($status)

$launch = New-Object System.Windows.Forms.Button
$launch.Text = "Launch"
$launch.Location = New-Object System.Drawing.Point(18, 304)
$launch.Size = New-Object System.Drawing.Size(110, 34)
$launch.Enabled = $false
$form.Controls.Add($launch)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = "Refresh"
$refresh.Location = New-Object System.Drawing.Point(142, 304)
$refresh.Size = New-Object System.Drawing.Size(110, 34)
$form.Controls.Add($refresh)

$smoke = New-Object System.Windows.Forms.Button
$smoke.Text = "Smoke"
$smoke.Location = New-Object System.Drawing.Point(266, 304)
$smoke.Size = New-Object System.Drawing.Size(110, 34)
$smoke.Enabled = $false
$form.Controls.Add($smoke)

$setNousKey = New-Object System.Windows.Forms.Button
$setNousKey.Text = "Set Nous API Key"
$setNousKey.Location = New-Object System.Drawing.Point(390, 304)
$setNousKey.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($setNousKey)

$clearNousKey = New-Object System.Windows.Forms.Button
$clearNousKey.Text = "Clear Nous Key"
$clearNousKey.Location = New-Object System.Drawing.Point(524, 304)
$clearNousKey.Size = New-Object System.Drawing.Size(110, 34)
$form.Controls.Add($clearNousKey)

$nousOAuth = New-Object System.Windows.Forms.Button
$nousOAuth.Text = "Nous OAuth Login"
$nousOAuth.Location = New-Object System.Drawing.Point(648, 304)
$nousOAuth.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($nousOAuth)

$setOpenRouterKey = New-Object System.Windows.Forms.Button
$setOpenRouterKey.Text = "Set OpenRouter Key"
$setOpenRouterKey.Location = New-Object System.Drawing.Point(18, 348)
$setOpenRouterKey.Size = New-Object System.Drawing.Size(160, 34)
$form.Controls.Add($setOpenRouterKey)

$clearOpenRouterKey = New-Object System.Windows.Forms.Button
$clearOpenRouterKey.Text = "Clear OpenRouter"
$clearOpenRouterKey.Location = New-Object System.Drawing.Point(192, 348)
$clearOpenRouterKey.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($clearOpenRouterKey)

$hermesUpdate = New-Object System.Windows.Forms.Button
$hermesUpdate.Text = "Hermes Golden Update"
$hermesUpdate.Location = New-Object System.Drawing.Point(346, 348)
$hermesUpdate.Size = New-Object System.Drawing.Size(170, 34)
$form.Controls.Add($hermesUpdate)

$hermesSessions = New-Object System.Windows.Forms.Button
$hermesSessions.Text = "Hermes Sessions"
$hermesSessions.Location = New-Object System.Drawing.Point(530, 348)
$hermesSessions.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($hermesSessions)

$dependencySummary = New-Object System.Windows.Forms.Label
$dependencySummary.Text = "Checking first-run requirements..."
$dependencySummary.Location = New-Object System.Drawing.Point(18, 402)
$dependencySummary.Size = New-Object System.Drawing.Size(910, 44)
$form.Controls.Add($dependencySummary)

$installCodex = New-Object System.Windows.Forms.Button
$installCodex.Text = "Install Codex"
$installCodex.Location = New-Object System.Drawing.Point(18, 456)
$installCodex.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($installCodex)

$installWsl = New-Object System.Windows.Forms.Button
$installWsl.Text = "Install WSL Ubuntu"
$installWsl.Location = New-Object System.Drawing.Point(152, 456)
$installWsl.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($installWsl)

$installHermes = New-Object System.Windows.Forms.Button
$installHermes.Text = "Install Hermes"
$installHermes.Location = New-Object System.Drawing.Point(306, 456)
$installHermes.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($installHermes)

$installPython = New-Object System.Windows.Forms.Button
$installPython.Text = "Install Python"
$installPython.Location = New-Object System.Drawing.Point(440, 456)
$installPython.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($installPython)

$refreshChecks = New-Object System.Windows.Forms.Button
$refreshChecks.Text = "Refresh Checks"
$refreshChecks.Location = New-Object System.Drawing.Point(574, 456)
$refreshChecks.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($refreshChecks)

function Get-SelectedModel {
  if (-not $combo.SelectedItem) { return $null }
  return $combo.SelectedItem
}

function Update-DependencyStatus {
  $codexOk = Test-CodexDesktopInstalled
  $wslOk = Test-WslUbuntuInstalled
  $hermesOk = if ($wslOk) { Test-HermesInstalled } else { $false }
  $pythonOk = Test-PythonInstalled

  $installCodex.Visible = -not $codexOk
  $installWsl.Visible = -not $wslOk
  $installHermes.Visible = $wslOk -and (-not $hermesOk)
  $installPython.Visible = -not $pythonOk

  $parts = @(
    "Codex: $(if ($codexOk) { 'installed' } else { 'missing' })",
    "WSL Ubuntu: $(if ($wslOk) { 'installed' } else { 'missing' })",
    "Hermes: $(if ($hermesOk) { 'installed' } else { 'missing' })",
    "Python: $(if ($pythonOk) { 'installed' } else { 'missing' })"
  )
  $dependencySummary.Text = "First-run checks: " + ($parts -join "    |    ")
  if ($codexOk -and $wslOk -and $hermesOk -and $pythonOk) {
    $dependencySummary.Text += "`r`nReady: Asclepius can launch real Codex with the isolated Hermes profile."
  } else {
    $dependencySummary.Text += "`r`nInstall only the missing pieces, then refresh checks."
  }
}

function Update-AuthSummary {
  if (-not $script:Catalog -or -not $script:Catalog.providers) {
    $authSummary.Text = "Provider auth: checking..."
    return
  }

  $nous = $script:Catalog.providers.nous
  $openrouter = $script:Catalog.providers.openrouter

  $nousText = "Nous OAuth: status unknown"
  if ($nous) {
    if ($nous.active_auth -eq "direct_api_key") {
      $nousText = "Nous: direct API key set; OAuth not required"
    } elseif ($nous.active_auth -eq "hermes_oauth_proxy") {
      $nousText = "Nous OAuth: signed in; free Nous models ready"
    } elseif ($nous.hermes_authenticated -eq $true) {
      $nousText = "Nous OAuth: signed in; free Nous models ready"
    } else {
      $nousText = "Nous OAuth: login needed for free Nous models"
    }
  }

  $openRouterText = "OpenRouter key: status unknown"
  if ($openrouter) {
    if ($openrouter.api_key_present -eq $true) {
      $openRouterText = "OpenRouter key: present"
    } else {
      $openRouterText = "OpenRouter key: missing"
    }
  }

  $authSummary.Text = "$nousText    |    $openRouterText"
}

function Update-Details {
  $m = Get-SelectedModel
  if (-not $m) {
    $details.Text = "No matching cloud models."
    $launch.Enabled = $false
    $smoke.Enabled = $false
    return
  }

  $auth = if ($m.provider -eq "openrouter") {
    "OpenRouter API key: $(Get-OpenRouterKeyStatus)"
  } else {
    "Nous auth: $(Get-NousKeyStatus)"
  }
  $variant = if ($m.is_provider_free_variant) { "OpenRouter explicit :free route" } else { "canonical/provider route" }
  $details.Text = "Portal: $($m.provider_display)`r`nModel: $($m.model_id)`r`nBilling: $($m.billing_label) ($($m.price_text))`r`nRoute type: $variant`r`nAuth: $auth"
  $launch.Enabled = $true
  $smoke.Enabled = $true
}

function Apply-Filter {
  $catalogDefault = Get-DefaultModelFromCatalog
  $selected = if ($combo.SelectedItem) { [string]$combo.SelectedItem.slug } else { Get-CurrentModel }
  $terms = @($filter.Text.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
  $filtered = @($script:AllModels | Where-Object {
    $haystack = "$($_.slug) $($_.display) $($_.provider_display) $($_.model_id) $($_.billing) $($_.price_text)".ToLowerInvariant()
    foreach ($term in $terms) {
      if (-not $haystack.Contains($term)) { return $false }
    }
    return $true
  })

  $combo.BeginUpdate()
  $combo.Items.Clear()
  foreach ($m in $filtered) { [void]$combo.Items.Add($m) }
  $combo.EndUpdate()

  if ($combo.Items.Count -gt 0) {
    $selectedIndex = 0
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
      if ([string]$combo.Items[$i].slug -eq $selected) { $selectedIndex = $i; break }
      if ([string]$combo.Items[$i].slug -eq $catalogDefault) { $selectedIndex = $i }
    }
    $combo.SelectedIndex = $selectedIndex
  }
  Update-Details
}

function Populate-Models {
  param([switch]$ForceRefresh)
  try {
    $launch.Enabled = $false
    $smoke.Enabled = $false
    $status.Text = "Refreshing cloud model catalog..."
    $form.Refresh()
    $script:Catalog = Load-Models -ForceRefresh:$ForceRefresh
    $script:AllModels = @($script:Catalog.models)
    Update-AuthSummary
    Apply-Filter
    $fetched = if ($script:Catalog.fetched_at) { [DateTime]::Parse([string]$script:Catalog.fetched_at).ToLocalTime().ToString("g") } else { "now" }
    $status.Text = "Catalog updated: $($script:AllModels.Count) portal-qualified model routes. Fetched: $fetched."
  } catch {
    $status.Text = "Model refresh failed: $($_.Exception.Message)"
  }
}

$combo.Add_SelectedIndexChanged({ Update-Details })
$filter.Add_TextChanged({ Apply-Filter })
$refresh.Add_Click({ Populate-Models -ForceRefresh })
$setNousKey.Add_Click({
  if (Set-ProviderKey -ProviderName "Nous" -SecretName "nous_api_key" -CurrentStatus (Get-NousKeyStatus)) {
    Populate-Models -ForceRefresh
    Update-AuthSummary
    $status.Text = "Optional Nous API key saved. Nous routes can use direct API auth instead of Hermes OAuth."
  }
})
$clearNousKey.Add_Click({
  Clear-ProviderKey -SecretName "nous_api_key"
  Populate-Models -ForceRefresh
  Update-AuthSummary
  $status.Text = "Optional Nous API key cleared. Free Nous routes use Hermes OAuth via proxy."
})
$nousOAuth.Add_Click({
  $script = Join-Path $Root "Start-HermesNousOAuthLogin.ps1"
  if (Test-Path -LiteralPath $script) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $script
    ) -WorkingDirectory $Root | Out-Null
    $authSummary.Text = "Nous OAuth: login window opened; finish it, then click Refresh"
    $status.Text = "Hermes Nous OAuth login window opened. Finish it, then click Refresh."
  } else {
    $status.Text = "Hermes OAuth login script not found: $script"
  }
})
$setOpenRouterKey.Add_Click({
  if (Set-ProviderKey -ProviderName "OpenRouter" -SecretName "openrouter_api_key" -CurrentStatus (Get-OpenRouterKeyStatus)) {
    Populate-Models -ForceRefresh
    Update-AuthSummary
    $status.Text = "OpenRouter key saved for this isolated Cloud-Codex profile."
  }
})
$clearOpenRouterKey.Add_Click({
  Clear-ProviderKey -SecretName "openrouter_api_key"
  Populate-Models -ForceRefresh
  Update-AuthSummary
  $status.Text = "OpenRouter key cleared from Cloud-Codex secrets."
})
$hermesUpdate.Add_Click({
  $script = Join-Path $Root "Update-HermesGolden.ps1"
  if (Test-Path -LiteralPath $script) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $script
    ) -WorkingDirectory $Root | Out-Null
    $status.Text = "Hermes Golden update window opened. Codex's blue Update remains Codex-only."
  } else {
    $status.Text = "Hermes Golden update script not found: $script"
  }
})
$hermesSessions.Add_Click({
  $script = Join-Path $Root "Manage-AsclepiusHermesSessions.ps1"
  if (Test-Path -LiteralPath $script) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $script
    ) -WorkingDirectory $Root | Out-Null
    $status.Text = "Hermes session manager opened."
  } else {
    $status.Text = "Hermes session manager script not found: $script"
  }
})
$installCodex.Add_Click({ Start-DependencyInstall -Target "Codex" })
$installWsl.Add_Click({ Start-DependencyInstall -Target "WslUbuntu" })
$installHermes.Add_Click({ Start-DependencyInstall -Target "Hermes" })
$installPython.Add_Click({ Start-DependencyInstall -Target "Python" })
$refreshChecks.Add_Click({ Update-DependencyStatus })
$launch.Add_Click({
  $m = Get-SelectedModel
  if ($m -and (Test-ModelCanRun -Model $m)) {
    Launch-CloudCodex -Model ([string]$m.slug)
    $form.Close()
  }
})
$smoke.Add_Click({
  $m = Get-SelectedModel
  if (-not $m -or -not (Test-ModelCanRun -Model $m)) { return }
  try {
    $status.Text = "Running smoke on $($m.provider_display) / $($m.model_id)..."
    $form.Refresh()
    $answer = Invoke-BridgeSmoke -Model ([string]$m.slug)
    $status.Text = "Smoke response: $answer"
  } catch {
    $status.Text = "Smoke failed: $($_.Exception.Message)"
  }
})

Set-AsclepiusTheme -Control $form
$title.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$authSummary.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Add_Shown({
  Update-DependencyStatus
  Populate-Models -ForceRefresh
})
[void]$form.ShowDialog()
