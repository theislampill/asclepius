param(
  [string]$AppUserModelId = "NousResearch.Asclepius.Codex",
  [string]$WindowTitle = "Asclepius Identity Probe",
  [int]$KeepOpenSeconds = 2,
  [int]$TargetProcessId = 0,
  [switch]$AllowCodexTarget,
  [switch]$NoDarkTitlebar
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class AsclepiusWindowIdentity
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

        // COLORREF values are 0x00BBGGRR. These mirror Codex's dark chrome.
        ok = SetDwmInt(hwnd, 35, 0x00111111) || ok; // caption
        ok = SetDwmInt(hwnd, 34, 0x00282828) || ok; // border
        ok = SetDwmInt(hwnd, 36, 0x00F4F4F4) || ok; // caption text
        return ok;
    }
}
"@

Add-Type -TypeDefinition $source -Language CSharp

function New-ProbeTarget {
  $targetPath = Join-Path $env:TEMP ("asclepius-identity-target-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
  $targetSource = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex Identity Probe Target"
$form.Size = New-Object System.Drawing.Size(720, 220)
$form.StartPosition = "CenterScreen"
$form.ShowInTaskbar = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "Disposable window for Asclepius AppUserModelID testing. This is not Codex."
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

  return [pscustomobject]@{
    Process = $process
    ScriptPath = $targetPath
  }
}

function Get-MainWindowHandle {
  param([Parameter(Mandatory)][int]$ProcessId)
  $deadline = (Get-Date).AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 150
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    if ($p.MainWindowHandle -ne 0) {
      return $p.MainWindowHandle
    }
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for process $ProcessId to create a main window."
}

$probe = $null
$targetProcess = $null
$touchedCodex = $false

try {
  if ($TargetProcessId -ne 0) {
    $targetProcess = Get-Process -Id $TargetProcessId -ErrorAction Stop
    $isCodex = ($targetProcess.ProcessName -eq "Codex" -or $targetProcess.ProcessName -eq "codex")
    if ($isCodex -and -not $AllowCodexTarget) {
      throw "Refusing to modify a Codex window without -AllowCodexTarget. Run the disposable default probe first."
    }
    $touchedCodex = $isCodex
  } else {
    $probe = New-ProbeTarget
    $targetProcess = $probe.Process
  }

  $hwnd = Get-MainWindowHandle -ProcessId $targetProcess.Id
  $beforeTitle = [AsclepiusWindowIdentity]::GetTitle($hwnd)
  $beforeAppId = [AsclepiusWindowIdentity]::GetAppUserModelId($hwnd)

  [AsclepiusWindowIdentity]::SetAppUserModelId($hwnd, $AppUserModelId)
  [AsclepiusWindowIdentity]::SetTitle($hwnd, $WindowTitle)
  $darkTitlebarOk = $false
  if (-not $NoDarkTitlebar) {
    $darkTitlebarOk = [AsclepiusWindowIdentity]::SetDarkTitlebar($hwnd)
  }

  Start-Sleep -Milliseconds 250
  $afterTitle = [AsclepiusWindowIdentity]::GetTitle($hwnd)
  $afterAppId = [AsclepiusWindowIdentity]::GetAppUserModelId($hwnd)

  if ($KeepOpenSeconds -gt 0) {
    Start-Sleep -Seconds $KeepOpenSeconds
  }

  [pscustomobject]@{
    ok = ($afterAppId -eq $AppUserModelId -and $afterTitle -eq $WindowTitle)
    touched_codex = $touchedCodex
    pid = $targetProcess.Id
    hwnd = ("0x{0:X}" -f $hwnd.ToInt64())
    title_before = $beforeTitle
    title_after = $afterTitle
    app_user_model_id_before = $beforeAppId
    app_user_model_id_after = $afterAppId
    dark_titlebar = $darkTitlebarOk
    note = "Default mode uses a disposable probe window only. It does not touch the live Codex app."
  }
} finally {
  if ($probe) {
    try {
      $p = Get-Process -Id $probe.Process.Id -ErrorAction SilentlyContinue
      if ($p) {
        $null = $p.CloseMainWindow()
        Start-Sleep -Milliseconds 500
        if (-not $p.HasExited) {
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
      }
    } catch {}

    if ($probe.ScriptPath -and (Test-Path -LiteralPath $probe.ScriptPath)) {
      Remove-Item -LiteralPath $probe.ScriptPath -Force -ErrorAction SilentlyContinue
    }
  }
}
