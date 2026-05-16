param(
  [switch]$UiSmoke,
  [int]$SmokeSeconds = 1
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = Join-Path $Root "codex-home"
$ModelFile = Join-Path $Root "cloud-models.json"
$LegacyModelFile = Join-Path $Root "nous-models.json"
$SecretsFile = Join-Path $Root "cloud-secrets.json"
$ConfigFile = Join-Path $CodexHome "config.toml"
$DefaultModel = "nous/deepseek/deepseek-v4-flash"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function ConvertTo-Visibility {
  param([bool]$Visible)
  if ($Visible) { return [System.Windows.Visibility]::Visible }
  return [System.Windows.Visibility]::Collapsed
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
    return "present in Asclepius secrets"
  }
  return "missing"
}

function Get-NousKeyStatus {
  if (-not [string]::IsNullOrWhiteSpace($env:NOUS_API_KEY)) {
    return "direct API key present from NOUS_API_KEY"
  }
  $secrets = Get-Secrets
  if ($secrets.PSObject.Properties.Name -contains "nous_api_key" -and -not [string]::IsNullOrWhiteSpace($secrets.nous_api_key)) {
    return "direct API key present in Asclepius secrets"
  }
  return "Hermes OAuth via proxy; no API key required for free Nous models"
}

function Show-AsclepiusKeyDialog {
  param(
    [Parameter(Mandatory)][string]$ProviderName,
    [Parameter(Mandatory)][string]$CurrentStatus
  )

  [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Provider key" Width="520" Height="260" WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" WindowStyle="None" Background="#121212">
  <Border BorderBrush="#343434" BorderThickness="1" Background="#161616">
    <Grid Margin="22">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Name="PromptTitle" Foreground="#F4F4F4" FontFamily="Segoe UI" FontSize="17" FontWeight="SemiBold"/>
      <TextBlock Name="PromptStatus" Grid.Row="1" Margin="0,10,0,18" Foreground="#A9A9A9" FontFamily="Segoe UI" FontSize="12" TextWrapping="Wrap"/>
      <Border Grid.Row="2" Height="48" CornerRadius="14" Background="#2B2B2B" BorderBrush="#3B3B3B" BorderThickness="1" VerticalAlignment="Top">
        <PasswordBox Name="KeyBox" Margin="14,8" BorderThickness="0" Background="#2B2B2B" Foreground="#F4F4F4" FontFamily="Segoe UI" FontSize="15"/>
      </Border>
      <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button Name="CancelButton" Width="96" Height="36" Margin="0,0,10,0" Content="Cancel" Background="#2B2B2B" Foreground="#F4F4F4" BorderBrush="#424242"/>
        <Button Name="OkButton" Width="96" Height="36" Content="Save" Background="#F4F4F4" Foreground="#111111" BorderBrush="#F4F4F4"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

  $reader = New-Object System.Xml.XmlNodeReader $dialogXaml
  $dialog = [Windows.Markup.XamlReader]::Load($reader)
  $dialog.FindName("PromptTitle").Text = "$ProviderName API key"
  $dialog.FindName("PromptStatus").Text = "Current status: $CurrentStatus"
  $keyBox = $dialog.FindName("KeyBox")
  $dialog.FindName("CancelButton").Add_Click({ $dialog.DialogResult = $false })
  $dialog.FindName("OkButton").Add_Click({
    $dialog.Tag = $keyBox.Password
    $dialog.DialogResult = $true
  })
  if ($script:Window) { $dialog.Owner = $script:Window }
  $result = $dialog.ShowDialog()
  if ($result -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$dialog.Tag)) {
    return ([string]$dialog.Tag).Trim()
  }
  return $null
}

function Set-ProviderKey {
  param(
    [Parameter(Mandatory)][string]$ProviderName,
    [Parameter(Mandatory)][string]$SecretName,
    [Parameter(Mandatory)][string]$CurrentStatus
  )
  $key = Show-AsclepiusKeyDialog -ProviderName $ProviderName -CurrentStatus $CurrentStatus
  if ([string]::IsNullOrWhiteSpace($key)) { return $false }
  $secrets = Get-Secrets
  if ($secrets.PSObject.Properties.Name -contains $SecretName) {
    $secrets.$SecretName = $key
  } else {
    $secrets | Add-Member -NotePropertyName $SecretName -NotePropertyValue $key
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
  return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Test-CodexDesktopInstalled {
  $running = Get-Process -Name Codex -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.EndsWith("\app\Codex.exe", [System.StringComparison]::OrdinalIgnoreCase) } |
    Select-Object -First 1
  if ($running) { return $true }

  try {
    $codex = Resolve-Path "C:\Program Files\WindowsApps\OpenAI.Codex_*\app\Codex.exe" -ErrorAction Stop |
      Sort-Object Path -Descending |
      Select-Object -First 1
    return $null -ne $codex
  } catch {
    try {
      $pkg = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction Stop | Select-Object -First 1
      return $null -ne $pkg
    } catch {
      return $false
    }
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
    Set-Status "Dependency installer not found: $script"
    return
  }
  Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $script,
    "-Target", $Target
  ) -WorkingDirectory $Root | Out-Null
  Set-Status "$Target install opened. Refresh checks when it completes."
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
    [System.Windows.MessageBox]::Show("OpenRouter needs an API key before this route can run.", "OpenRouter key missing", "OK", "Warning") | Out-Null
    return $false
  }
  if ($Model.billing -eq "paid") {
    $msg = "Portal: $($Model.provider_display)`nModel: $($Model.model_id)`nPrice: $($Model.price_text)"
    $answer = [System.Windows.MessageBox]::Show($msg, "Confirm paid cloud model", "YesNo", "Warning")
    return $answer -eq [System.Windows.MessageBoxResult]::Yes
  }
  if ($Model.billing -eq "unknown") {
    $msg = "Portal: $($Model.provider_display)`nModel: $($Model.model_id)"
    $answer = [System.Windows.MessageBox]::Show($msg, "Confirm unknown cloud price", "YesNo", "Warning")
    return $answer -eq [System.Windows.MessageBoxResult]::Yes
  }
  return $true
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Asclepius" Width="980" Height="640" MinWidth="820" MinHeight="560"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResizeWithGrip"
        Background="#111111" FontFamily="Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="NavText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F2F2F2"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="16,10,0,10"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9D9D9D"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="PillButton" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Foreground" Value="#F4F4F4"/>
      <Setter Property="Background" Value="#2F2F2F"/>
      <Setter Property="BorderBrush" Value="#444444"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="#383838"/>
                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#5A5A5A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="#252525"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource PillButton}">
      <Setter Property="Background" Value="#EFEFEF"/>
      <Setter Property="BorderBrush" Value="#EFEFEF"/>
      <Setter Property="Foreground" Value="#141414"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,0"/>
    </Style>
    <Style x:Key="TitleButton" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Foreground" Value="#D6D6D6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="TitleButtonBorder" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TitleButtonBorder" Property="Background" Value="#272727"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="TitleButtonBorder" Property="Background" Value="#333333"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkTextBox" TargetType="TextBox">
      <Setter Property="Background" Value="#2D2D2D"/>
      <Setter Property="Foreground" Value="#D8D8D8"/>
      <Setter Property="CaretBrush" Value="#F4F4F4"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderThickness="0">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkComboBoxItem" TargetType="{x:Type ComboBoxItem}">
      <Setter Property="Foreground" Value="#F4F4F4"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ComboBoxItem}">
            <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#363636"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#404040"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkComboBox" TargetType="{x:Type ComboBox}">
      <Setter Property="Foreground" Value="#F4F4F4"/>
      <Setter Property="Background" Value="#343434"/>
      <Setter Property="BorderBrush" Value="#494949"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource DarkComboBoxItem}"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
      <Setter Property="MaxDropDownHeight" Value="360"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ComboBox}">
            <Grid>
              <ToggleButton x:Name="ToggleButton"
                            Focusable="False"
                            ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="ToggleBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
                      <Grid>
                        <TextBlock Text="v" Foreground="#CFCFCF" FontSize="13" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,1"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <TextBlock x:Name="ContentSite"
                         IsHitTestVisible="False"
                         Text="{Binding SelectedItem.pickerDisplay, RelativeSource={RelativeSource TemplatedParent}}"
                         Foreground="#F4F4F4"
                         TextTrimming="CharacterEllipsis"
                         Margin="12,0,32,0"
                         VerticalAlignment="Center"
                         HorizontalAlignment="Stretch"/>
              <Popup x:Name="Popup"
                     Placement="Bottom"
                     IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True"
                     Focusable="False">
                <Grid MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <Border Background="#202020" BorderBrush="#4A4A4A" BorderThickness="1" CornerRadius="9">
                    <ScrollViewer Margin="0" SnapsToDevicePixels="True">
                      <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                    </ScrollViewer>
                  </Border>
                </Grid>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="#282828" BorderThickness="1" Background="#111111">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="34"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Border Name="TitleBar" Grid.Row="0" Background="#111111" BorderBrush="#262626" BorderThickness="0,0,0,1">
        <DockPanel LastChildFill="True">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button Name="MinimizeButton" Style="{StaticResource TitleButton}" Content="-"/>
            <Button Name="MaximizeButton" Style="{StaticResource TitleButton}" Content="[]"/>
            <Button Name="CloseButton" Style="{StaticResource TitleButton}" Content="X"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border Width="18" Height="18" CornerRadius="6" Background="#426DFF" Margin="14,0,14,0"/>
            <TextBlock Text="File" Foreground="#BDBDBD" FontSize="14" Margin="0,0,24,0"/>
            <TextBlock Text="Edit" Foreground="#BDBDBD" FontSize="14" Margin="0,0,24,0"/>
            <TextBlock Text="View" Foreground="#BDBDBD" FontSize="14" Margin="0,0,24,0"/>
            <TextBlock Text="Window" Foreground="#BDBDBD" FontSize="14" Margin="0,0,24,0"/>
            <TextBlock Text="Help" Foreground="#BDBDBD" FontSize="14" Margin="0,0,24,0"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Row="1" Background="#141414" Margin="38">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0" LastChildFill="True">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
            <Button Name="RefreshButton" Style="{StaticResource PillButton}" Content="Refresh" Margin="0,0,8,0"/>
            <Button Name="OAuthButton" Style="{StaticResource PillButton}" Content="Nous OAuth" Margin="0,0,8,0"/>
            <Button Name="HermesUpdateButton" Style="{StaticResource PillButton}" Content="Hermes" Margin="0,0,8,0"/>
            <Button Name="SessionsButton" Style="{StaticResource PillButton}" Content="Sessions"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="Asclepius" Foreground="#F4F4F4" FontWeight="SemiBold" FontSize="20"/>
            <TextBlock Text="Provider route" Foreground="#9D9D9D" FontSize="13" Margin="0,8,0,0"/>
          </StackPanel>
        </DockPanel>

        <StackPanel Name="InstallPanel" Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,28,0,0">
          <Button Name="InstallCodexButton" Style="{StaticResource PillButton}" Content="Install Codex" Margin="0,0,10,0"/>
          <Button Name="InstallWslButton" Style="{StaticResource PillButton}" Content="Install WSL Ubuntu" Margin="0,0,10,0"/>
          <Button Name="InstallHermesButton" Style="{StaticResource PillButton}" Content="Install Hermes" Margin="0,0,10,0"/>
          <Button Name="InstallPythonButton" Style="{StaticResource PillButton}" Content="Install Python" Margin="0,0,10,0"/>
          <Button Name="RefreshChecksButton" Style="{StaticResource PillButton}" Content="Refresh checks"/>
        </StackPanel>

        <Grid Grid.Row="2" VerticalAlignment="Center" MaxWidth="760" HorizontalAlignment="Center">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Name="StatusBlock" Grid.Row="0" Foreground="#A6A6A6" FontSize="13" Margin="0,0,0,14" Text="Starting Asclepius..."/>

          <Border Grid.Row="1" Background="#2B2B2B" BorderBrush="#414141" BorderThickness="1" CornerRadius="16" Padding="16">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="24"/>
                <RowDefinition Height="42"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="42"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="46"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Text="Search" Foreground="#A6A6A6" FontSize="12" VerticalAlignment="Top"/>
              <Border Grid.Row="1" Background="#202020" BorderBrush="#3E3E3E" BorderThickness="1" CornerRadius="9">
                <TextBox Name="FilterBox" Margin="12,0" Style="{StaticResource DarkTextBox}" Text=""/>
              </Border>
              <ComboBox Name="RouteCombo" Grid.Row="3" Height="38" Style="{StaticResource DarkComboBox}">
                <ComboBox.ItemTemplate>
                  <DataTemplate>
                    <TextBlock Text="{Binding pickerDisplay}" Foreground="#F4F4F4" TextTrimming="CharacterEllipsis"/>
                  </DataTemplate>
                </ComboBox.ItemTemplate>
              </ComboBox>
              <StackPanel Grid.Row="4" Margin="0,10,0,12">
                <TextBlock Name="RouteSummary" Text="Loading cloud routes..." Foreground="#B0B0B0" FontSize="13" TextTrimming="CharacterEllipsis"/>
                <TextBlock Name="AuthBlock" Foreground="#929292" FontSize="12" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <Grid Grid.Row="5">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button Grid.Column="0" Style="{StaticResource PillButton}" Content="Default permissions" Margin="0,0,10,0"/>
                <Button Grid.Column="1" Style="{StaticResource PillButton}" Content="Work locally" Margin="0,0,10,0"/>
                <Button Grid.Column="3" Style="{StaticResource PillButton}" Content="Custom Medium" Margin="0,0,10,0"/>
                <Button Name="LaunchButton" Grid.Column="4" Style="{StaticResource PrimaryButton}" Content="Launch Codex"/>
              </Grid>
            </Grid>
          </Border>

          <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,18,0,0">
            <Button Name="SetNousKeyButton" Style="{StaticResource PillButton}" Content="Nous key" Margin="0,0,8,0"/>
            <Button Name="ClearNousKeyButton" Style="{StaticResource PillButton}" Content="Clear Nous" Margin="0,0,8,0"/>
            <Button Name="SetOpenRouterKeyButton" Style="{StaticResource PillButton}" Content="OpenRouter key" Margin="0,0,8,0"/>
            <Button Name="ClearOpenRouterKeyButton" Style="{StaticResource PillButton}" Content="Clear OpenRouter" Margin="0,0,8,0"/>
            <Button Name="SmokeButton" Style="{StaticResource PillButton}" Content="Smoke"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
  "TitleBar","MinimizeButton","MaximizeButton","CloseButton","RefreshButton","OAuthButton",
  "HermesUpdateButton","SessionsButton","RouteSummary","StatusBlock","FilterBox","RouteCombo",
  "LaunchButton","AuthBlock","InstallPanel","InstallCodexButton","InstallWslButton",
  "InstallHermesButton","InstallPythonButton","RefreshChecksButton","SetNousKeyButton",
  "ClearNousKeyButton","SetOpenRouterKeyButton","ClearOpenRouterKeyButton","SmokeButton"
)
foreach ($name in $names) {
  Set-Variable -Name $name -Value $script:Window.FindName($name) -Scope Script
}

$script:Catalog = $null
$script:AllModels = @()

function Set-Status {
  param([string]$Text)
  $script:StatusBlock.Text = $Text
}

function Get-DefaultModelFromCatalog {
  if ($script:Catalog -and $script:Catalog.default_model) {
    return [string]$script:Catalog.default_model
  }
  return $DefaultModel
}

function Get-SelectedModel {
  return $script:RouteCombo.SelectedItem
}

function Get-ProviderShortName {
  param($Model)
  if (-not $Model) { return "Cloud" }
  switch ([string]$Model.provider) {
    "nous" { return "Nous Portal" }
    "openrouter" { return "OpenRouter" }
    default {
      if ($Model.provider_display) { return [string]$Model.provider_display }
      return [string]$Model.provider
    }
  }
}

function Set-PickerDisplay {
  param($Model)
  if (-not $Model) { return }
  $label = "{0} | {1} | {2}" -f $Model.billing_label, (Get-ProviderShortName -Model $Model), $Model.model_id
  if ($Model.PSObject.Properties.Name -contains "picker_display") {
    $Model.picker_display = $label
  } else {
    $Model | Add-Member -NotePropertyName "picker_display" -NotePropertyValue $label
  }
  if ($Model.PSObject.Properties.Name -contains "pickerDisplay") {
    $Model.pickerDisplay = $label
  } else {
    $Model | Add-Member -NotePropertyName "pickerDisplay" -NotePropertyValue $label
  }
}

function Update-DependencyStatus {
  $codexOk = Test-CodexDesktopInstalled
  $wslOk = Test-WslUbuntuInstalled
  $hermesOk = if ($wslOk) { Test-HermesInstalled } else { $false }
  $pythonOk = Test-PythonInstalled

  $script:InstallCodexButton.Visibility = ConvertTo-Visibility (-not $codexOk)
  $script:InstallWslButton.Visibility = ConvertTo-Visibility (-not $wslOk)
  $script:InstallHermesButton.Visibility = ConvertTo-Visibility ($wslOk -and (-not $hermesOk))
  $script:InstallPythonButton.Visibility = ConvertTo-Visibility (-not $pythonOk)
  $script:RefreshChecksButton.Visibility = ConvertTo-Visibility (-not ($codexOk -and $wslOk -and $hermesOk -and $pythonOk))

  if ($codexOk -and $wslOk -and $hermesOk -and $pythonOk) {
    $script:InstallPanel.Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $script:InstallPanel.Visibility = [System.Windows.Visibility]::Visible
  }
}

function Update-AuthSummary {
  $nousText = "Nous OAuth: checking"
  $openRouterText = "OpenRouter key: checking"
  if ($script:Catalog -and $script:Catalog.providers) {
    $nous = $script:Catalog.providers.nous
    $openrouter = $script:Catalog.providers.openrouter
    if ($nous) {
      if ($nous.active_auth -eq "direct_api_key") {
        $nousText = "Nous: direct API key"
      } elseif ($nous.active_auth -eq "hermes_oauth_proxy" -or $nous.hermes_authenticated -eq $true) {
        $nousText = "Nous OAuth: signed in"
      } else {
        $nousText = "Nous OAuth: login needed"
      }
    }
    if ($openrouter) {
      if ($openrouter.api_key_present -eq $true) { $openRouterText = "OpenRouter key: present" } else { $openRouterText = "OpenRouter key: missing" }
    }
  }
  $script:AuthBlock.Text = "$nousText    |    $openRouterText"
}

function Update-Details {
  $m = Get-SelectedModel
  if (-not $m) {
    $script:RouteSummary.Text = "No matching cloud routes."
    $script:LaunchButton.IsEnabled = $false
    $script:SmokeButton.IsEnabled = $false
    return
  }

  $auth = if ($m.provider -eq "openrouter") { "OpenRouter: $(Get-OpenRouterKeyStatus)" } else { "Nous: $(Get-NousKeyStatus)" }
  $script:RouteSummary.Text = "$($m.billing_label) | $(Get-ProviderShortName -Model $m) | $($m.model_id) | $($m.price_text)"
  $script:AuthBlock.Text = $auth
  $script:LaunchButton.IsEnabled = $true
  $script:SmokeButton.IsEnabled = $true
}

function Apply-Filter {
  $catalogDefault = Get-DefaultModelFromCatalog
  $selected = if ($script:RouteCombo.SelectedItem) { [string]$script:RouteCombo.SelectedItem.slug } else { Get-CurrentModel }
  $terms = @($script:FilterBox.Text.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
  $filtered = @($script:AllModels | Where-Object {
    $haystack = "$($_.slug) $($_.display) $($_.provider_display) $($_.model_id) $($_.billing) $($_.price_text)".ToLowerInvariant()
    foreach ($term in $terms) {
      if (-not $haystack.Contains($term)) { return $false }
    }
    return $true
  })

  $script:RouteCombo.ItemsSource = $filtered
  if ($filtered.Count -gt 0) {
    $choice = $filtered | Where-Object { [string]$_.slug -eq $selected } | Select-Object -First 1
    if (-not $choice) { $choice = $filtered | Where-Object { [string]$_.slug -eq $catalogDefault } | Select-Object -First 1 }
    if (-not $choice) { $choice = $filtered[0] }
    $script:RouteCombo.SelectedItem = $choice
  }
  Update-Details
}

function Populate-Models {
  param([switch]$ForceRefresh)
  try {
    $script:LaunchButton.IsEnabled = $false
    $script:SmokeButton.IsEnabled = $false
    Set-Status "Refreshing cloud model catalog..."
    $script:Catalog = Load-Models -ForceRefresh:$ForceRefresh
    $script:AllModels = @($script:Catalog.models)
    foreach ($model in $script:AllModels) { Set-PickerDisplay -Model $model }
    Update-AuthSummary
    Apply-Filter
    $fetched = if ($script:Catalog.fetched_at) { [DateTime]::Parse([string]$script:Catalog.fetched_at).ToLocalTime().ToString("g") } else { "now" }
    Set-Status "$($script:AllModels.Count) provider-qualified routes. Fetched $fetched."
  } catch {
    Set-Status "Model refresh failed: $($_.Exception.Message)"
  }
}

$script:TitleBar.Add_MouseLeftButtonDown({
  if ($_.ClickCount -eq 2) {
    if ($script:Window.WindowState -eq [System.Windows.WindowState]::Maximized) { $script:Window.WindowState = [System.Windows.WindowState]::Normal } else { $script:Window.WindowState = [System.Windows.WindowState]::Maximized }
  } else {
    try { $script:Window.DragMove() } catch {}
  }
})
$script:MinimizeButton.Add_Click({ $script:Window.WindowState = [System.Windows.WindowState]::Minimized })
$script:MaximizeButton.Add_Click({
  if ($script:Window.WindowState -eq [System.Windows.WindowState]::Maximized) { $script:Window.WindowState = [System.Windows.WindowState]::Normal } else { $script:Window.WindowState = [System.Windows.WindowState]::Maximized }
})
$script:CloseButton.Add_Click({ $script:Window.Close() })

$script:RouteCombo.Add_SelectionChanged({ Update-Details })
$script:FilterBox.Add_TextChanged({ Apply-Filter })
$script:RefreshButton.Add_Click({ Populate-Models -ForceRefresh })
$script:OAuthButton.Add_Click({
  $script = Join-Path $Root "Start-HermesNousOAuthLogin.ps1"
  if (Test-Path -LiteralPath $script) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$script) -WorkingDirectory $Root | Out-Null
    Set-Status "Nous OAuth opened. Finish login, then refresh."
  } else {
    Set-Status "Hermes OAuth script missing."
  }
})
$script:HermesUpdateButton.Add_Click({
  $script = Join-Path $Root "Update-HermesGolden.ps1"
  if (Test-Path -LiteralPath $script) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$script) -WorkingDirectory $Root | Out-Null
    Set-Status "Hermes update opened."
  } else {
    Set-Status "Hermes update script missing."
  }
})
$script:SessionsButton.Add_Click({
  $script = Join-Path $Root "Manage-AsclepiusHermesSessions.ps1"
  if (Test-Path -LiteralPath $script) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$script) -WorkingDirectory $Root | Out-Null
    Set-Status "Hermes sessions opened."
  } else {
    Set-Status "Hermes session script missing."
  }
})
$script:SetNousKeyButton.Add_Click({
  if (Set-ProviderKey -ProviderName "Nous" -SecretName "nous_api_key" -CurrentStatus (Get-NousKeyStatus)) {
    Populate-Models -ForceRefresh
    Set-Status "Nous key saved."
  }
})
$script:ClearNousKeyButton.Add_Click({
  Clear-ProviderKey -SecretName "nous_api_key"
  Populate-Models -ForceRefresh
  Set-Status "Nous key cleared. Free Nous routes use Hermes OAuth."
})
$script:SetOpenRouterKeyButton.Add_Click({
  if (Set-ProviderKey -ProviderName "OpenRouter" -SecretName "openrouter_api_key" -CurrentStatus (Get-OpenRouterKeyStatus)) {
    Populate-Models -ForceRefresh
    Set-Status "OpenRouter key saved."
  }
})
$script:ClearOpenRouterKeyButton.Add_Click({
  Clear-ProviderKey -SecretName "openrouter_api_key"
  Populate-Models -ForceRefresh
  Set-Status "OpenRouter key cleared."
})
$script:InstallCodexButton.Add_Click({ Start-DependencyInstall -Target "Codex" })
$script:InstallWslButton.Add_Click({ Start-DependencyInstall -Target "WslUbuntu" })
$script:InstallHermesButton.Add_Click({ Start-DependencyInstall -Target "Hermes" })
$script:InstallPythonButton.Add_Click({ Start-DependencyInstall -Target "Python" })
$script:RefreshChecksButton.Add_Click({ Update-DependencyStatus })
$script:LaunchButton.Add_Click({
  $m = Get-SelectedModel
  if ($m -and (Test-ModelCanRun -Model $m)) {
    Launch-CloudCodex -Model ([string]$m.slug)
    $script:Window.Close()
  }
})
$script:SmokeButton.Add_Click({
  $m = Get-SelectedModel
  if (-not $m -or -not (Test-ModelCanRun -Model $m)) { return }
  try {
    Set-Status "Smoking $($m.provider_display) / $($m.model_id)..."
    $answer = Invoke-BridgeSmoke -Model ([string]$m.slug)
    Set-Status "Smoke response: $answer"
  } catch {
    Set-Status "Smoke failed: $($_.Exception.Message)"
  }
})

$script:Window.Add_Loaded({
  Update-DependencyStatus
  if ($UiSmoke) {
    $script:RouteSummary.Text = "UI smoke"
    Set-Status "UI smoke ready."
    $script:SmokeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SmokeTimer.Interval = [TimeSpan]::FromSeconds($SmokeSeconds)
    $script:SmokeTimer.Add_Tick({
      $script:SmokeTimer.Stop()
      $script:Window.Close()
    })
    $script:SmokeTimer.Start()
  } else {
    Populate-Models -ForceRefresh
  }
})

[void]$script:Window.ShowDialog()
