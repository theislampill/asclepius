param(
  [Parameter(Mandatory)][int]$TargetProcessId,
  [int]$PollMilliseconds = 1000,
  [int]$StatusRefreshSeconds = 60,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatusScript = Join-Path $Root "Get-AsclepiusHermesStatus.ps1"
$UpdateScript = Join-Path $Root "Update-HermesGolden.ps1"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$nativeSource = @"
using System;
using System.Runtime.InteropServices;

public static class AsclepiusHermesTitlebarOverlayNative
{
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll", EntryPoint="GetWindowLong")]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint="SetWindowLong")]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint="SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;
    private const long WS_EX_APPWINDOW = 0x00040000L;

    public static IntPtr FindTopLevelWindowForProcess(int targetProcessId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) { return true; }
            uint windowProcessId;
            GetWindowThreadProcessId(hWnd, out windowProcessId);
            if ((int)windowProcessId == targetProcessId) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void MakeToolWindow(IntPtr hWnd)
    {
        if (IntPtr.Size == 8) {
            long style = GetWindowLongPtr64(hWnd, GWL_EXSTYLE).ToInt64();
            style = (style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
            SetWindowLongPtr64(hWnd, GWL_EXSTYLE, new IntPtr(style));
        } else {
            int style = GetWindowLong32(hWnd, GWL_EXSTYLE);
            style = (int)((style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
            SetWindowLong32(hWnd, GWL_EXSTYLE, style);
        }
    }
}
"@
Add-Type -TypeDefinition $nativeSource -Language CSharp

function Get-HermesStatus {
  if (-not (Test-Path -LiteralPath $StatusScript)) { return $null }
  try {
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StatusScript -Json |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
      Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace([string]$json)) { return $null }
    return ($json | ConvertFrom-Json)
  } catch {
    return $null
  }
}

if ($SelfTest) {
  [pscustomobject]@{
    TargetProcessId = $TargetProcessId
    StatusScript = (Test-Path -LiteralPath $StatusScript)
    UpdateScript = (Test-Path -LiteralPath $UpdateScript)
  }
  return
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Asclepius Hermes Update" Width="330" Height="32"
        Left="-20000" Top="-20000"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        ShowActivated="False" Topmost="True" AllowsTransparency="True"
        Background="Transparent" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Border Name="ChipBorder" CornerRadius="12" Background="#3B2A18" BorderBrush="#73501D" BorderThickness="1">
    <Button Name="UpdateButton" BorderThickness="0" Background="Transparent" Foreground="#FFD18A"
            FontSize="12" FontWeight="SemiBold" Cursor="Hand" Padding="12,0">
      <Button.Template>
        <ControlTemplate TargetType="Button">
          <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="12">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="ButtonBorder" Property="Background" Value="#4A341C"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
              <Setter TargetName="ButtonBorder" Property="Background" Value="#2E2115"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Button.Template>
    </Button>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)
$script:UpdateButton = $script:Window.FindName("UpdateButton")
$script:Status = $null
$script:LastStatusRefresh = [DateTime]::MinValue
$script:TargetHwnd = [IntPtr]::Zero

$script:Window.Add_SourceInitialized({
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:Window)
    [AsclepiusHermesTitlebarOverlayNative]::MakeToolWindow($helper.Handle)
  } catch {}
})

function Refresh-Status {
  $script:Status = Get-HermesStatus
  $script:LastStatusRefresh = Get-Date
}

function Apply-Status {
  if (-not $script:Status -or $script:Status.state -ne "outdated") {
    $script:Window.Hide()
    return $false
  }
  $script:UpdateButton.Content = "Hermes out of date: $($script:Status.behind) commits | Update"
  $script:UpdateButton.ToolTip = $script:Status.tooltip
  if (-not $script:Window.IsVisible) { $script:Window.Show() }
  return $true
}

function Update-Position {
  try {
    $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
    $handle = [AsclepiusHermesTitlebarOverlayNative]::FindTopLevelWindowForProcess($TargetProcessId)
    if ($handle -eq [IntPtr]::Zero) {
      $handle = $process.MainWindowHandle
    }
    if ($handle -eq [IntPtr]::Zero -or [AsclepiusHermesTitlebarOverlayNative]::IsIconic($handle)) {
      $script:Window.Hide()
      return
    }

    $foreground = [AsclepiusHermesTitlebarOverlayNative]::GetForegroundWindow()
    $overlayHandle = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
    if ($foreground -ne $handle -and $foreground -ne $overlayHandle) {
      $script:Window.Hide()
      return
    }

    $rect = New-Object AsclepiusHermesTitlebarOverlayNative+RECT
    if (-not [AsclepiusHermesTitlebarOverlayNative]::GetWindowRect($handle, [ref]$rect)) {
      $script:Window.Hide()
      return
    }

    if (-not (Apply-Status)) { return }
    $leftCandidate = $rect.Right - [int]$script:Window.Width - 168
    $script:Window.Left = [Math]::Max($rect.Left + 320, $leftCandidate)
    $script:Window.Top = $rect.Top + 5
  } catch {
    $script:Window.Close()
  }
}

$script:UpdateButton.Add_Click({
  if (-not (Test-Path -LiteralPath $UpdateScript)) {
    $script:UpdateButton.Content = "Hermes update script missing"
    return
  }
  Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$UpdateScript) -WorkingDirectory $Root | Out-Null
  $script:UpdateButton.Content = "Hermes update opened..."
  Refresh-Status
})

Refresh-Status

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($PollMilliseconds)
$timer.Add_Tick({
  if (((Get-Date) - $script:LastStatusRefresh).TotalSeconds -ge $StatusRefreshSeconds) {
    Refresh-Status
  }
  Update-Position
})
$timer.Start()

$script:Window.Add_Loaded({ Update-Position })
$script:Window.Add_Closed({
  try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch {}
})
$script:Window.Show()
[System.Windows.Threading.Dispatcher]::Run()
