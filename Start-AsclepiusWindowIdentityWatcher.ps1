param(
  [int]$TargetProcessId = 0,
  [string]$AppUserModelId = "NousResearch.Asclepius.Codex",
  [string]$WindowTitle = "Asclepius",
  [int]$IntervalMilliseconds = 750,
  [int]$MaxSeconds = 0,
  [switch]$Once,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AsclepiusWindowKeeper
{
    private const ushort VT_LPWSTR = 31;

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;

        public PROPERTYKEY(Guid fmtid, uint pid)
        {
            this.fmtid = fmtid;
            this.pid = pid;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT
    {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr pointerValue;
        public IntPtr pointerValue2;
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out IPropertyStore propertyStore);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetWindowText(IntPtr hWnd, string lpString);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int dwAttribute, ref int pvAttribute, int cbAttribute);

    private static readonly PROPERTYKEY AppIdKey =
        new PROPERTYKEY(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

    private static IPropertyStore GetStore(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd))
        {
            throw new ArgumentException("The HWND is not a valid window.");
        }

        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
        if (hr != 0)
        {
            Marshal.ThrowExceptionForHR(hr);
        }
        return store;
    }

    public static void SetAppUserModelId(IntPtr hwnd, string appUserModelId)
    {
        IPropertyStore store = GetStore(hwnd);
        PROPVARIANT pv = new PROPVARIANT();
        pv.vt = VT_LPWSTR;
        pv.pointerValue = Marshal.StringToCoTaskMemUni(appUserModelId);
        try
        {
            PROPERTYKEY key = AppIdKey;
            store.SetValue(ref key, ref pv);
            store.Commit();
        }
        finally
        {
            PropVariantClear(ref pv);
            Marshal.ReleaseComObject(store);
        }
    }

    public static string GetAppUserModelId(IntPtr hwnd)
    {
        IPropertyStore store = GetStore(hwnd);
        PROPVARIANT pv = new PROPVARIANT();
        try
        {
            PROPERTYKEY key = AppIdKey;
            store.GetValue(ref key, out pv);
            if (pv.vt == VT_LPWSTR && pv.pointerValue != IntPtr.Zero)
            {
                return Marshal.PtrToStringUni(pv.pointerValue);
            }
            return "";
        }
        finally
        {
            PropVariantClear(ref pv);
            Marshal.ReleaseComObject(store);
        }
    }

    public static void SetTitle(IntPtr hwnd, string title)
    {
        if (!SetWindowText(hwnd, title))
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static string GetTitle(IntPtr hwnd)
    {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    private static bool SetDwmInt(IntPtr hwnd, int attribute, int value)
    {
        int v = value;
        return DwmSetWindowAttribute(hwnd, attribute, ref v, sizeof(int)) == 0;
    }

    public static bool SetDarkTitlebar(IntPtr hwnd)
    {
        bool ok = SetDwmInt(hwnd, 20, 1);
        if (!ok)
        {
            ok = SetDwmInt(hwnd, 19, 1);
        }
        ok = SetDwmInt(hwnd, 35, 0x00111111) || ok;
        ok = SetDwmInt(hwnd, 34, 0x00282828) || ok;
        ok = SetDwmInt(hwnd, 36, 0x00F4F4F4) || ok;
        return ok;
    }
}
"@

Add-Type -TypeDefinition $source -Language CSharp

function New-SelfTestTarget {
  $targetPath = Join-Path $env:TEMP ("asclepius-window-watcher-target-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
  $targetSource = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex"
$form.Size = New-Object System.Drawing.Size(720, 220)
$form.StartPosition = "CenterScreen"
$form.ShowInTaskbar = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "Disposable Asclepius window identity watcher target."
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(24, 72)
$form.Controls.Add($label)

[System.Windows.Forms.Application]::Run($form)
'@
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($targetPath, $targetSource, $utf8NoBom)
  $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-STA",
    "-WindowStyle", "Hidden",
    "-File", $targetPath
  ) -PassThru

  [pscustomobject]@{
    Process = $process
    ScriptPath = $targetPath
  }
}

function Set-AsclepiusWindowIdentity {
  param([Parameter(Mandatory)][int]$ProcessId)

  $process = Get-Process -Id $ProcessId -ErrorAction Stop
  $hwndValue = [int64]$process.MainWindowHandle
  if ($hwndValue -eq 0) {
    return [pscustomobject]@{
      ok = $false
      pid = $ProcessId
      hwnd = "0x0"
      reason = "main window handle not ready"
    }
  }

  $hwnd = [IntPtr]$hwndValue
  $beforeTitle = [AsclepiusWindowKeeper]::GetTitle($hwnd)
  $beforeAppId = [AsclepiusWindowKeeper]::GetAppUserModelId($hwnd)
  [AsclepiusWindowKeeper]::SetAppUserModelId($hwnd, $AppUserModelId)
  [AsclepiusWindowKeeper]::SetTitle($hwnd, $WindowTitle)
  $darkOk = [AsclepiusWindowKeeper]::SetDarkTitlebar($hwnd)
  Start-Sleep -Milliseconds 50
  $afterTitle = [AsclepiusWindowKeeper]::GetTitle($hwnd)
  $afterAppId = [AsclepiusWindowKeeper]::GetAppUserModelId($hwnd)

  [pscustomobject]@{
    ok = ($afterTitle -eq $WindowTitle -and $afterAppId -eq $AppUserModelId)
    pid = $ProcessId
    hwnd = ("0x{0:X}" -f $hwndValue)
    title_before = $beforeTitle
    title_after = $afterTitle
    app_user_model_id_before = $beforeAppId
    app_user_model_id_after = $afterAppId
    dark_titlebar = $darkOk
  }
}

if ($IntervalMilliseconds -lt 200) {
  $IntervalMilliseconds = 200
}

if ($SelfTest) {
  $target = $null
  try {
    $target = New-SelfTestTarget
    $TargetProcessId = $target.Process.Id
    $deadline = (Get-Date).AddSeconds(10)
    do {
      Start-Sleep -Milliseconds 100
      $process = Get-Process -Id $TargetProcessId -ErrorAction Stop
    } while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)

    $first = Set-AsclepiusWindowIdentity -ProcessId $TargetProcessId
    [AsclepiusWindowKeeper]::SetTitle(([IntPtr]([int64](Get-Process -Id $TargetProcessId).MainWindowHandle)), "Codex")
    Start-Sleep -Milliseconds 150
    $second = Set-AsclepiusWindowIdentity -ProcessId $TargetProcessId
    [pscustomobject]@{
      ok = ($first.ok -eq $true -and $second.ok -eq $true -and $second.title_after -eq $WindowTitle)
      pid = $TargetProcessId
      first_title_after = $first.title_after
      repaired_title_after = $second.title_after
      app_user_model_id_after = $second.app_user_model_id_after
      dark_titlebar = $second.dark_titlebar
      touched_codex = $false
    }
  } finally {
    if ($target) {
      $p = Get-Process -Id $target.Process.Id -ErrorAction SilentlyContinue
      if ($p) {
        $null = $p.CloseMainWindow()
        Start-Sleep -Milliseconds 300
        if (-not $p.HasExited) {
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
      }
      if ($target.ScriptPath -and (Test-Path -LiteralPath $target.ScriptPath)) {
        Remove-Item -LiteralPath $target.ScriptPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
  exit 0
}

if ($TargetProcessId -eq 0) {
  throw "TargetProcessId is required unless -SelfTest is used."
}

if ($Once) {
  Set-AsclepiusWindowIdentity -ProcessId $TargetProcessId
  exit 0
}

$deadline = if ($MaxSeconds -gt 0) { (Get-Date).AddSeconds($MaxSeconds) } else { $null }
while ($true) {
  if ($deadline -and (Get-Date) -gt $deadline) {
    exit 0
  }
  $process = Get-Process -Id $TargetProcessId -ErrorAction SilentlyContinue
  if (-not $process) {
    exit 0
  }
  try {
    Set-AsclepiusWindowIdentity -ProcessId $TargetProcessId | Out-Null
  } catch {
    # The target can legitimately be mid-repaint or closing; retry while the PID exists.
  }
  Start-Sleep -Milliseconds $IntervalMilliseconds
}
