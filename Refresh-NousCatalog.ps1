$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CatalogPath = Join-Path $Root "codex-model-catalog.json"
$PickerPath = Join-Path $Root "cloud-models.json"
$LegacyPickerPath = Join-Path $Root "nous-models.json"
$SecretsPath = Join-Path $Root "cloud-secrets.json"
$Preferred = "nous/deepseek/deepseek-v4-flash"
$Culture = [System.Globalization.CultureInfo]::InvariantCulture
$script:SourceStatus = [ordered]@{}

function Set-SourceStatus {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][bool]$Ok,
    [int]$Count = 0,
    [string]$Message = ""
  )
  $script:SourceStatus[$Name] = [pscustomobject]@{
    ok = $Ok
    count = $Count
    message = $Message
    checked_at = (Get-Date).ToUniversalTime().ToString("o")
  }
}

function ConvertTo-DecimalOrNull {
  param($Value)
  if ($null -eq $Value) { return $null }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $decimal = [decimal]0
  if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Float, $Culture, [ref]$decimal)) {
    return $decimal
  }
  return $null
}

function Get-BillingState {
  param($PromptPerM, $CompletionPerM)
  if ($null -eq $PromptPerM -and $null -eq $CompletionPerM) { return "unknown" }
  $prompt = if ($null -eq $PromptPerM) { [decimal]0 } else { [decimal]$PromptPerM }
  $completion = if ($null -eq $CompletionPerM) { [decimal]0 } else { [decimal]$CompletionPerM }
  if ($prompt -eq 0 -and $completion -eq 0) { return "free" }
  return "paid"
}

function Format-PricePerM {
  param($PromptPerM, $CompletionPerM)
  if ($null -eq $PromptPerM -and $null -eq $CompletionPerM) { return "unknown price" }
  $prompt = if ($null -eq $PromptPerM) { "?" } else { '$' + ([decimal]$PromptPerM).ToString("0.####", $Culture) + "/M in" }
  $completion = if ($null -eq $CompletionPerM) { "?" } else { '$' + ([decimal]$CompletionPerM).ToString("0.####", $Culture) + "/M out" }
  return "$prompt, $completion"
}

function Get-TokenPricePerMillion {
  param([string]$TokenPrice)
  if ([string]::IsNullOrWhiteSpace($TokenPrice)) {
    return [pscustomobject]@{ prompt = $null; completion = $null }
  }
  if ($TokenPrice -match 'in\s*\$([0-9.]+)\s*/\s*out\s*\$([0-9.]+)') {
    return [pscustomobject]@{
      prompt = ConvertTo-DecimalOrNull $Matches[1]
      completion = ConvertTo-DecimalOrNull $Matches[2]
    }
  }
  if ($TokenPrice -match '\$([0-9.]+)\s*/\s*1M') {
    $price = ConvertTo-DecimalOrNull $Matches[1]
    return [pscustomobject]@{ prompt = $price; completion = $price }
  }
  return [pscustomobject]@{ prompt = $null; completion = $null }
}

function ConvertTo-RouteModelId {
  param([string]$ModelId)
  return $ModelId.Replace(":", "__colon__")
}

function Get-Secrets {
  if (-not (Test-Path -LiteralPath $SecretsPath)) { return [pscustomobject]@{} }
  try {
    return Get-Content -Raw -LiteralPath $SecretsPath | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{}
  }
}

function Get-ProviderStatus {
  $secrets = Get-Secrets
  $nousKey = $env:NOUS_API_KEY
  $nousKeySource = "missing"
  if (-not [string]::IsNullOrWhiteSpace($nousKey)) {
    $nousKeySource = "NOUS_API_KEY"
  } elseif ($secrets.PSObject.Properties.Name -contains "nous_api_key" -and -not [string]::IsNullOrWhiteSpace($secrets.nous_api_key)) {
    $nousKeySource = "cloud-secrets.json"
  }

  $openRouterKey = $env:OPENROUTER_API_KEY
  $openRouterSource = "missing"
  if (-not [string]::IsNullOrWhiteSpace($openRouterKey)) {
    $openRouterSource = "OPENROUTER_API_KEY"
  } elseif ($secrets.PSObject.Properties.Name -contains "openrouter_api_key" -and -not [string]::IsNullOrWhiteSpace($secrets.openrouter_api_key)) {
    $openRouterSource = "cloud-secrets.json"
  }

  $nousReady = $false
  $nousAuthenticated = $false
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:8645/health" -TimeoutSec 5
    $nousReady = $true
    if ($health.PSObject.Properties.Name -contains "authenticated") {
      $nousAuthenticated = [bool]$health.authenticated
    } else {
      $nousAuthenticated = $true
    }
  } catch {
    $nousReady = $false
  }

  return [pscustomobject]@{
    nous = [pscustomobject]@{
      display_name = "Nous Portal via Hermes OAuth"
      route_prefix = "nous"
      credential = "Hermes OAuth by default; optional direct Nous API key"
      ready = $nousReady
      authenticated = ($nousAuthenticated -or $nousKeySource -ne "missing")
      hermes_authenticated = $nousAuthenticated
      api_key_present = ($nousKeySource -ne "missing")
      key_source = $nousKeySource
      active_auth = if ($nousKeySource -ne "missing") { "direct_api_key" } elseif ($nousAuthenticated) { "hermes_oauth_proxy" } else { "missing" }
    }
    openrouter = [pscustomobject]@{
      display_name = "OpenRouter"
      route_prefix = "openrouter"
      credential = "OpenRouter API key"
      ready = $true
      authenticated = ($openRouterSource -ne "missing")
      api_key_present = ($openRouterSource -ne "missing")
      key_source = $openRouterSource
    }
  }
}

$script:Entries = New-Object System.Collections.Generic.List[object]
$script:Seen = @{}

function Add-CloudModel {
  param(
    [Parameter(Mandatory)][string]$Provider,
    [Parameter(Mandatory)][string]$ProviderDisplay,
    [Parameter(Mandatory)][string]$ModelId,
    [string]$DisplayName,
    [string]$SourceCatalog,
    [string]$UpstreamSource,
    $PromptPerM,
    $CompletionPerM,
    $ContextLength,
    [string[]]$InputModalities,
    [string[]]$OutputModalities,
    [string]$Href
  )

  if ([string]::IsNullOrWhiteSpace($ModelId)) { return }
  $modelIdClean = $ModelId.Trim()
  $slug = "$Provider/" + (ConvertTo-RouteModelId -ModelId $modelIdClean)
  if ($script:Seen.ContainsKey($slug)) { return }

  $billing = Get-BillingState -PromptPerM $PromptPerM -CompletionPerM $CompletionPerM
  $billingLabel = switch ($billing) {
    "free" { "FREE" }
    "paid" { "PAID" }
    default { "PRICE UNKNOWN" }
  }
  if ($Provider -eq "openrouter" -and $modelIdClean.EndsWith(":free", [System.StringComparison]::OrdinalIgnoreCase)) {
    $billingLabel = "FREE VARIANT"
  }
  $priceText = Format-PricePerM -PromptPerM $PromptPerM -CompletionPerM $CompletionPerM
  $priority = if ($slug -eq $Preferred) {
    0
  } elseif ($Provider -eq "nous" -and $billing -eq "free") {
    5
  } elseif ($Provider -eq "nous" -and $billing -eq "paid") {
    20
  } elseif ($Provider -eq "openrouter" -and $billing -eq "free") {
    40
  } elseif ($Provider -eq "openrouter" -and $billing -eq "paid") {
    70
  } else {
    90
  }

  $entry = [pscustomobject]@{
    slug = $slug
    provider = $Provider
    provider_display = $ProviderDisplay
    model_id = $modelIdClean
    is_provider_free_variant = [bool]($Provider -eq "openrouter" -and $modelIdClean.EndsWith(":free", [System.StringComparison]::OrdinalIgnoreCase))
    display_name = if ([string]::IsNullOrWhiteSpace($DisplayName)) { $modelIdClean } else { $DisplayName }
    display = "$billingLabel | $ProviderDisplay | $modelIdClean | $priceText"
    billing = $billing
    billing_label = $billingLabel
    price_text = $priceText
    prompt_price_per_million = $PromptPerM
    completion_price_per_million = $CompletionPerM
    context_length = $ContextLength
    input_modalities = @($InputModalities | Where-Object { $_ })
    output_modalities = @($OutputModalities | Where-Object { $_ })
    source_catalog = $SourceCatalog
    upstream_source = $UpstreamSource
    href = $Href
    priority = $priority
  }
  $script:Entries.Add($entry) | Out-Null
  $script:Seen[$slug] = $true
}

function Add-NousRecommendedModels {
  try {
    $recommended = Invoke-RestMethod -Uri "https://portal.nousresearch.com/api/nous/recommended-models" -TimeoutSec 30
  } catch {
    Set-SourceStatus -Name "nous_recommended" -Ok $false -Message $_.Exception.Message
    return
  }

  $count = 0
  foreach ($m in @($recommended.freeRecommendedModels)) {
    $price = Get-TokenPricePerMillion -TokenPrice $m.tokenPrice
    Add-CloudModel `
      -Provider "nous" `
      -ProviderDisplay "Nous Portal via Hermes OAuth" `
      -ModelId $m.modelName `
      -DisplayName $m.displayName `
      -SourceCatalog "nous_recommended_free" `
      -UpstreamSource $m.source `
      -PromptPerM $price.prompt `
      -CompletionPerM $price.completion `
      -ContextLength $m.contextLength `
      -InputModalities @($m.inputModalities) `
      -OutputModalities @($m.outputModalities) `
      -Href $m.href
    $count++
  }

  foreach ($m in @($recommended.paidRecommendedModels)) {
    $price = Get-TokenPricePerMillion -TokenPrice $m.tokenPrice
    Add-CloudModel `
      -Provider "nous" `
      -ProviderDisplay "Nous Portal via Hermes OAuth" `
      -ModelId $m.modelName `
      -DisplayName $m.displayName `
      -SourceCatalog "nous_recommended_paid" `
      -UpstreamSource $m.source `
      -PromptPerM $price.prompt `
      -CompletionPerM $price.completion `
      -ContextLength $m.contextLength `
      -InputModalities @($m.inputModalities) `
      -OutputModalities @($m.outputModalities) `
      -Href $m.href
    $count++
  }
  Set-SourceStatus -Name "nous_recommended" -Ok $true -Count $count
}

function Add-NousLiveModels {
  $sourceName = "nous_live_models"
  $secrets = Get-Secrets
  $nousKey = if (-not [string]::IsNullOrWhiteSpace($env:NOUS_API_KEY)) {
    $env:NOUS_API_KEY
  } elseif ($secrets.PSObject.Properties.Name -contains "nous_api_key" -and -not [string]::IsNullOrWhiteSpace($secrets.nous_api_key)) {
    [string]$secrets.nous_api_key
  } else {
    ""
  }
  try {
    if (-not [string]::IsNullOrWhiteSpace($nousKey)) {
      $models = Invoke-RestMethod -Uri "https://inference-api.nousresearch.com/v1/models" -Headers @{ Authorization = "Bearer $nousKey" } -TimeoutSec 20
      $sourceName = "nous_live_models_direct_api_key"
    } else {
      $models = Invoke-RestMethod -Uri "http://127.0.0.1:8645/v1/models" -TimeoutSec 20
    }
  } catch {
    try {
      $models = Invoke-RestMethod -Uri "https://inference-api.nousresearch.com/v1/models" -TimeoutSec 20
      $sourceName = "nous_live_models_direct"
    } catch {
      Set-SourceStatus -Name "nous_live_models" -Ok $false -Message $_.Exception.Message
      return
    }
  }

  $count = 0
  foreach ($m in @($models.data)) {
    $id = if ($m.id) { $m.id } else { $m.modelName }
    Add-CloudModel `
      -Provider "nous" `
      -ProviderDisplay "Nous Portal via Hermes OAuth" `
      -ModelId $id `
      -DisplayName $(if ($m.name) { $m.name } else { $id }) `
      -SourceCatalog "nous_live_models" `
      -UpstreamSource "nous" `
      -PromptPerM $null `
      -CompletionPerM $null `
      -ContextLength $(if ($m.context_length) { $m.context_length } elseif ($m.contextLength) { $m.contextLength } else { $null }) `
      -InputModalities @($m.input_modalities) `
      -OutputModalities @($m.output_modalities) `
      -Href $null
    $count++
  }
  Set-SourceStatus -Name $sourceName -Ok $true -Count $count
}

function Add-OpenRouterModels {
  try {
    $models = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/models" -TimeoutSec 45
  } catch {
    Set-SourceStatus -Name "openrouter_models" -Ok $false -Message $_.Exception.Message
    return
  }

  $count = 0
  foreach ($m in @($models.data)) {
    $promptToken = ConvertTo-DecimalOrNull $m.pricing.prompt
    $completionToken = ConvertTo-DecimalOrNull $m.pricing.completion
    $promptPerM = if ($null -eq $promptToken) { $null } else { [decimal]$promptToken * 1000000 }
    $completionPerM = if ($null -eq $completionToken) { $null } else { [decimal]$completionToken * 1000000 }
    Add-CloudModel `
      -Provider "openrouter" `
      -ProviderDisplay "OpenRouter" `
      -ModelId $m.id `
      -DisplayName $m.name `
      -SourceCatalog "openrouter_models" `
      -UpstreamSource "openrouter" `
      -PromptPerM $promptPerM `
      -CompletionPerM $completionPerM `
      -ContextLength $m.context_length `
      -InputModalities @($m.architecture.input_modalities) `
      -OutputModalities @($m.architecture.output_modalities) `
      -Href $("https://openrouter.ai/" + $m.canonical_slug)
    $count++
  }
  Set-SourceStatus -Name "openrouter_models" -Ok $true -Count $count
}

function Get-CodexModelTemplate {
  $defaultCatalog = Join-Path $env:USERPROFILE ".codex\models_cache.json"
  if (-not (Test-Path -LiteralPath $defaultCatalog)) { return $null }
  try {
    $defaultModels = (Get-Content -Raw -LiteralPath $defaultCatalog | ConvertFrom-Json).models
    $template = @($defaultModels | Where-Object { $_.slug -eq "gpt-5.5" } | Select-Object -First 1)[0]
    if (-not $template) { $template = @($defaultModels | Select-Object -First 1)[0] }
    return $template
  } catch {
    return $null
  }
}

function Select-DefaultModel {
  param([object[]]$Models)
  if (-not $Models -or $Models.Count -eq 0) { return $Preferred }

  $preferredLive = @($Models | Where-Object { $_.slug -eq $Preferred } | Select-Object -First 1)
  if ($preferredLive.Count -gt 0) { return [string]$preferredLive[0].slug }

  $freeNous = @($Models | Where-Object { $_.provider -eq "nous" -and $_.billing -eq "free" } | Sort-Object priority, model_id | Select-Object -First 1)
  if ($freeNous.Count -gt 0) { return [string]$freeNous[0].slug }

  $freeAny = @($Models | Where-Object { $_.billing -eq "free" } | Sort-Object priority, provider_display, model_id | Select-Object -First 1)
  if ($freeAny.Count -gt 0) { return [string]$freeAny[0].slug }

  $nousAny = @($Models | Where-Object { $_.provider -eq "nous" } | Sort-Object priority, model_id | Select-Object -First 1)
  if ($nousAny.Count -gt 0) { return [string]$nousAny[0].slug }

  return [string]$Models[0].slug
}

Add-NousRecommendedModels
Add-NousLiveModels
Add-OpenRouterModels

$providerStatus = Get-ProviderStatus
$models = @($script:Entries | Sort-Object priority, provider_display, model_id)
if ($models.Count -eq 0) {
  throw "No cloud models were fetched from live providers; keeping existing catalog files unchanged."
}
$defaultModel = Select-DefaultModel -Models $models
$template = $null

$codexModels = foreach ($m in $models) {
  $description = "Portal: $($m.provider_display); model: $($m.model_id); billing: $($m.billing_label); price: $($m.price_text)."
  if ($m.provider -eq "openrouter") {
    $description += " Requires an OpenRouter API key in the Cloud-Codex picker or OPENROUTER_API_KEY."
    if ($m.is_provider_free_variant) {
      $description += " This is OpenRouter's explicit :free variant, not the canonical paid OpenRouter route."
    }
  } elseif ($m.provider -eq "nous") {
    $description += " Uses Hermes OAuth by default; no API key is required for free Nous routes."
    if ($providerStatus.nous.api_key_present) {
      $description += " A direct Nous API key is configured, so the bridge can use direct API auth."
    }
  }

  if ($template) {
    $entry = $template | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $entry.slug = $m.slug
    $entry.display_name = $m.display
    $entry.description = $description
    $entry.priority = $m.priority
    $entry.context_window = if ($m.context_length) { [int64]$m.context_length } else { 200000 }
    $entry.max_context_window = $entry.context_window
    $entry.availability_nux = $null
    $entry.upgrade = $null
    $entry.additional_speed_tiers = @()
    $entry.service_tiers = @()
    if ($entry.PSObject.Properties.Name -contains "base_instructions") {
      $entry.base_instructions = ""
    }
    if ($entry.PSObject.Properties.Name -contains "instructions_variables") {
      $entry.instructions_variables = $null
    }
    $entry
  } else {
    [pscustomobject]@{
      slug = $m.slug
      display_name = $m.display
      description = $description
      default_reasoning_level = "medium"
      supported_reasoning_levels = @(
        [pscustomobject]@{ effort = "low"; description = "Lower model-side reasoning budget where supported" },
        [pscustomobject]@{ effort = "medium"; description = "Default model-side reasoning budget where supported" },
        [pscustomobject]@{ effort = "high"; description = "Higher model-side reasoning budget where supported" }
      )
      shell_type = "shell_command"
      visibility = "list"
      supported_in_api = $true
      priority = $m.priority
      context_window = if ($m.context_length) { [int64]$m.context_length } else { 200000 }
      max_context_window = if ($m.context_length) { [int64]$m.context_length } else { 200000 }
      base_instructions = ""
      supports_reasoning_summaries = $false
      default_reasoning_summary = "none"
      support_verbosity = $false
      default_verbosity = "low"
      apply_patch_tool_type = "freeform"
      web_search_tool_type = "text_and_image"
      truncation_policy = [pscustomobject]@{ mode = "tokens"; limit = 10000 }
      supports_parallel_tool_calls = $true
      supports_image_detail_original = $false
      experimental_supported_tools = @()
      input_modalities = @("text")
      supports_search_tool = $false
    }
  }
}

$catalog = [pscustomobject]@{
  models = @($codexModels)
}
$picker = [pscustomobject]@{
  fetched_at = (Get-Date).ToUniversalTime().ToString("o")
  default_model = $defaultModel
  preferred_model = $Preferred
  source_status = $script:SourceStatus
  providers = $providerStatus
  models = @($models)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($CatalogPath, ($catalog | ConvertTo-Json -Depth 20), $utf8NoBom)
[System.IO.File]::WriteAllText($PickerPath, ($picker | ConvertTo-Json -Depth 20), $utf8NoBom)
[System.IO.File]::WriteAllText($LegacyPickerPath, ($picker | ConvertTo-Json -Depth 20), $utf8NoBom)

Write-Output "Wrote $CatalogPath"
Write-Output "Wrote $PickerPath"
Write-Output "Wrote $LegacyPickerPath"
