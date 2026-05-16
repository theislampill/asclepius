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
$form.Text = "Cloud-Codex"
$form.Size = New-Object System.Drawing.Size(820, 480)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Text = "Cloud-Codex model"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 18)
$title.Size = New-Object System.Drawing.Size(760, 26)
$form.Controls.Add($title)

$filter = New-Object System.Windows.Forms.TextBox
$filter.Location = New-Object System.Drawing.Point(18, 50)
$filter.Size = New-Object System.Drawing.Size(770, 26)
if ($filter.PSObject.Properties.Name -contains "PlaceholderText") {
  $filter.PlaceholderText = "Filter by portal, model, free, paid, deepseek, stepfun..."
}
$form.Controls.Add($filter)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.Location = New-Object System.Drawing.Point(18, 84)
$combo.Size = New-Object System.Drawing.Size(770, 28)
$combo.DropDownStyle = "DropDownList"
$combo.DisplayMember = "display"
$form.Controls.Add($combo)

$details = New-Object System.Windows.Forms.Label
$details.Text = "Loading cloud catalog..."
$details.Location = New-Object System.Drawing.Point(18, 122)
$details.Size = New-Object System.Drawing.Size(770, 90)
$form.Controls.Add($details)

$authSummary = New-Object System.Windows.Forms.Label
$authSummary.Text = "Checking provider auth..."
$authSummary.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$authSummary.Location = New-Object System.Drawing.Point(18, 220)
$authSummary.Size = New-Object System.Drawing.Size(770, 28)
$form.Controls.Add($authSummary)

$status = New-Object System.Windows.Forms.Label
$status.Text = ""
$status.Location = New-Object System.Drawing.Point(18, 250)
$status.Size = New-Object System.Drawing.Size(770, 34)
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

function Get-SelectedModel {
  if (-not $combo.SelectedItem) { return $null }
  return $combo.SelectedItem
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

$form.Add_Shown({ Populate-Models -ForceRefresh })
[void]$form.ShowDialog()
