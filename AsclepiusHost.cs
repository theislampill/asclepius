using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using System.Web.Script.Serialization;

namespace AsclepiusHost
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            var config = AsclepiusConfig.Load();
            if (args.Any(a => StringComparer.OrdinalIgnoreCase.Equals(a, "--host-smoke")))
            {
                return Smoke.Run(config);
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new HostForm(config));
            return 0;
        }
    }

    internal sealed class AsclepiusConfig
    {
        public string Root;
        public string Workspace;
        public string LaunchScript { get { return Path.Combine(Root, "Launch-CloudCodexApp.ps1"); } }
        public string UpdateScript { get { return Path.Combine(Root, "Update-HermesGolden.ps1"); } }
        public string SessionsScript { get { return Path.Combine(Root, "Manage-AsclepiusHermesSessions.ps1"); } }
        public string InstallScript { get { return Path.Combine(Root, "Install-AsclepiusDependency.ps1"); } }
        public string OAuthScript { get { return Path.Combine(Root, "Start-HermesNousOAuthLogin.ps1"); } }

        public static AsclepiusConfig Load()
        {
            string root = Environment.GetEnvironmentVariable("ASCLEPIUS_ROOT");
            if (String.IsNullOrWhiteSpace(root)) root = AppDomain.CurrentDomain.BaseDirectory;
            string workspace = Environment.GetEnvironmentVariable("CODEX_CLOUD_WORKSPACE");
            if (String.IsNullOrWhiteSpace(workspace)) workspace = @"C:\workspace\ai";
            return new AsclepiusConfig { Root = Path.GetFullPath(root), Workspace = Path.GetFullPath(workspace) };
        }
    }

    internal sealed class LaunchInfo
    {
        public string CodexDesktopExe;
        public string CodexHome;
        public string ElectronUserData;
        public string Workspace;
        public string CodexCliPath;
        public string SelectedModel;
        public string HermesWorkdir;
    }

    internal static class Shell
    {
        public static string Quote(string value)
        {
            if (value == null) return "\"\"";
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        public static CommandResult Run(string fileName, string arguments, string workingDirectory, int timeoutMs)
        {
            var result = new CommandResult();
            var output = new StringBuilder();
            var error = new StringBuilder();
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = new Process { StartInfo = psi })
            {
                process.OutputDataReceived += (s, e) => { if (e.Data != null) output.AppendLine(e.Data); };
                process.ErrorDataReceived += (s, e) => { if (e.Data != null) error.AppendLine(e.Data); };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(timeoutMs))
                {
                    try { process.Kill(); } catch { }
                    result.ExitCode = -1;
                    result.TimedOut = true;
                }
                else
                {
                    result.ExitCode = process.ExitCode;
                }
                process.WaitForExit();
            }
            result.Output = output.ToString();
            result.Error = error.ToString();
            return result;
        }
    }

    internal sealed class CommandResult
    {
        public int ExitCode;
        public bool TimedOut;
        public string Output = "";
        public string Error = "";
    }

    internal sealed class HostForm : Form
    {
        private readonly AsclepiusConfig _config;
        private readonly Panel _codexPanel = new Panel();
        private readonly Panel _banner = new Panel();
        private readonly Label _bannerText = new Label();
        private readonly Button _bannerButton = new Button();
        private readonly Label _status = new Label();
        private readonly NotifyIcon _tray = new NotifyIcon();
        private IntPtr _codexWindow = IntPtr.Zero;
        private Process _codexProcess;

        public HostForm(AsclepiusConfig config)
        {
            _config = config;
            Text = "Asclepius";
            BackColor = Color.FromArgb(18, 18, 18);
            ForeColor = Color.White;
            Size = new Size(1280, 820);
            MinimumSize = new Size(900, 600);
            StartPosition = FormStartPosition.CenterScreen;
            AccessibleName = "Asclepius";
            AccessibleDescription = "Supervisor host that displays the real Codex Desktop window.";

            _status.Text = "Starting Codex through Asclepius...";
            _status.Dock = DockStyle.Fill;
            _status.TextAlign = ContentAlignment.MiddleCenter;
            _status.Font = new Font("Segoe UI", 14, FontStyle.Regular);
            Controls.Add(_status);

            _codexPanel.Dock = DockStyle.Fill;
            _codexPanel.BackColor = Color.Black;
            _codexPanel.Visible = false;
            Controls.Add(_codexPanel);

            _banner.Dock = DockStyle.Top;
            _banner.Height = 36;
            _banner.BackColor = Color.FromArgb(41, 42, 41);
            _banner.Visible = false;
            _bannerText.Dock = DockStyle.Fill;
            _bannerText.TextAlign = ContentAlignment.MiddleLeft;
            _bannerText.Padding = new Padding(12, 0, 0, 0);
            _bannerText.ForeColor = Color.FromArgb(245, 196, 97);
            _bannerButton.Text = "Hermes Update";
            _bannerButton.Dock = DockStyle.Right;
            _bannerButton.Width = 132;
            _bannerButton.Click += (s, e) => StartVisibleScript(_config.UpdateScript);
            _banner.Controls.Add(_bannerText);
            _banner.Controls.Add(_bannerButton);
            Controls.Add(_banner);
            BuildTrayMenu();

            Opacity = 0;
            ShowInTaskbar = false;
            Shown += (s, e) => StartCodexInBackground();
            Resize += (s, e) => ResizeHostedCodex();
            FormClosing += (s, e) => CloseHostedCodex();
        }

        private void BuildTrayMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Hermes Golden Update", null, (s, e) => StartVisibleScript(_config.UpdateScript));
            menu.Items.Add("Hermes Sessions", null, (s, e) => StartVisibleScript(_config.SessionsScript));
            menu.Items.Add("Nous OAuth", null, (s, e) => StartVisibleScript(_config.OAuthScript));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit Asclepius", null, (s, e) => Close());
            _tray.Text = "Asclepius";
            _tray.Icon = SystemIcons.Application;
            _tray.ContextMenuStrip = menu;
            _tray.Visible = true;
        }

        private void StartCodexInBackground()
        {
            System.Threading.ThreadPool.QueueUserWorkItem(_ => StartCodex());
        }

        private void StartCodex()
        {
            try
            {
                var info = GetLaunchInfo();
                DateTime startCutoff = DateTime.Now.AddSeconds(-2);
                var psi = new ProcessStartInfo
                {
                    FileName = info.CodexDesktopExe,
                    WorkingDirectory = info.Workspace,
                    UseShellExecute = false
                };
                psi.Arguments = "--open-project " + Shell.Quote(info.Workspace);
                psi.EnvironmentVariables["CODEX_HOME"] = info.CodexHome;
                psi.EnvironmentVariables["CODEX_ELECTRON_USER_DATA_PATH"] = info.ElectronUserData;
                psi.EnvironmentVariables["CODEX_CLOUD_WORKSPACE"] = info.Workspace;
                psi.EnvironmentVariables["CODEX_HERMES_WORKDIR"] = info.HermesWorkdir;
                if (!String.IsNullOrWhiteSpace(info.CodexCliPath)) psi.EnvironmentVariables["CODEX_CLI_PATH"] = info.CodexCliPath;
                _codexProcess = Process.Start(psi);
                _codexWindow = WaitForCodexWindow(startCutoff, 60000);
                if (_codexWindow == IntPtr.Zero) throw new InvalidOperationException("Could not find the launched Codex window.");
                BeginInvoke(new Action(EmbedCodexWindow));
                CheckHermesUpdateAsync();
            }
            catch (Exception ex)
            {
                BeginInvoke(new Action(() => ShowSetupSurface(ex.Message)));
            }
        }

        private LaunchInfo GetLaunchInfo()
        {
            string args = "-NoProfile -ExecutionPolicy Bypass -File " + Shell.Quote(_config.LaunchScript) +
                          " -Workspace " + Shell.Quote(_config.Workspace) + " -HostInfoJson";
            var result = Shell.Run("powershell.exe", args, _config.Root, 180000);
            if (result.ExitCode != 0)
            {
                throw new InvalidOperationException((result.Error + result.Output).Trim());
            }
            var serializer = new JavaScriptSerializer();
            return serializer.Deserialize<LaunchInfo>(result.Output.Trim());
        }

        private IntPtr WaitForCodexWindow(DateTime startCutoff, int timeoutMs)
        {
            var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
            while (DateTime.Now < deadline)
            {
                IntPtr foreground = Native.GetForegroundWindow();
                if (IsCodexWindow(foreground)) return foreground;

                foreach (var process in Process.GetProcessesByName("Codex"))
                {
                    try
                    {
                        if (process.StartTime < startCutoff) continue;
                        if (IsCodexWindow(process.MainWindowHandle)) return process.MainWindowHandle;
                    }
                    catch { }
                }

                foreach (var process in Process.GetProcessesByName("Codex").OrderByDescending(p => SafeStartTime(p)))
                {
                    try
                    {
                        if (IsCodexWindow(process.MainWindowHandle)) return process.MainWindowHandle;
                    }
                    catch { }
                }
                System.Threading.Thread.Sleep(250);
            }
            return IntPtr.Zero;
        }

        private bool IsCodexWindow(IntPtr handle)
        {
            if (handle == IntPtr.Zero || handle == Handle) return false;
            if (!Native.IsWindowVisible(handle)) return false;
            uint processId;
            Native.GetWindowThreadProcessId(handle, out processId);
            if (processId == 0) return false;
            try
            {
                var process = Process.GetProcessById((int)processId);
                if (!String.Equals(process.ProcessName, "Codex", StringComparison.OrdinalIgnoreCase)) return false;
                return !String.IsNullOrWhiteSpace(GetWindowTitle(handle));
            }
            catch
            {
                return false;
            }
        }

        private static DateTime SafeStartTime(Process process)
        {
            try { return process.StartTime; }
            catch { return DateTime.MinValue; }
        }

        private static string GetWindowTitle(IntPtr handle)
        {
            var text = new StringBuilder(512);
            Native.GetWindowText(handle, text, text.Capacity);
            return text.ToString();
        }

        private void EmbedCodexWindow()
        {
            Native.RECT rect;
            if (Native.GetWindowRect(_codexWindow, out rect))
            {
                Bounds = new Rectangle(rect.Left, rect.Top, Math.Max(900, rect.Right - rect.Left), Math.Max(600, rect.Bottom - rect.Top));
            }
            _status.Visible = false;
            _codexPanel.Visible = true;
            Native.SetParent(_codexWindow, _codexPanel.Handle);
            IntPtr style = Native.GetWindowLongPtr(_codexWindow, Native.GWL_STYLE);
            long value = style.ToInt64();
            value &= ~Native.WS_POPUP;
            value &= ~Native.WS_CAPTION;
            value &= ~Native.WS_THICKFRAME;
            value |= Native.WS_CHILD;
            Native.SetWindowLongPtr(_codexWindow, Native.GWL_STYLE, new IntPtr(value));
            ResizeHostedCodex();
            Native.ShowWindow(_codexWindow, Native.SW_SHOW);
            ShowInTaskbar = true;
            Opacity = 1;
            Activate();
        }

        private void ResizeHostedCodex()
        {
            if (_codexWindow == IntPtr.Zero) return;
            Native.MoveWindow(_codexWindow, 0, 0, _codexPanel.ClientSize.Width, _codexPanel.ClientSize.Height, true);
        }

        private void CloseHostedCodex()
        {
            if (_codexWindow != IntPtr.Zero)
            {
                Native.PostMessage(_codexWindow, Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            }
            _tray.Visible = false;
            _tray.Dispose();
        }

        private void ShowSetupSurface(string message)
        {
            ShowInTaskbar = true;
            Opacity = 1;
            _codexPanel.Visible = false;
            _status.Visible = true;
            _status.Text = "Asclepius could not launch Codex yet.\r\n\r\n" + message +
                           "\r\n\r\nUse the setup buttons below, then restart Asclepius.";
            var panel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 58,
                Padding = new Padding(12),
                BackColor = Color.FromArgb(32, 32, 32)
            };
            panel.Controls.Add(Button("Install Codex", () => StartVisibleDependency("Codex")));
            panel.Controls.Add(Button("Install WSL Ubuntu", () => StartVisibleDependency("WslUbuntu")));
            panel.Controls.Add(Button("Install Hermes", () => StartVisibleDependency("Hermes")));
            panel.Controls.Add(Button("Install Python", () => StartVisibleDependency("Python")));
            panel.Controls.Add(Button("Nous OAuth", () => StartVisibleScript(_config.OAuthScript)));
            Controls.Add(panel);
            panel.BringToFront();
        }

        private Button Button(string text, Action action)
        {
            var button = new Button { Text = text, Width = 132, Height = 32 };
            button.Click += (s, e) => action();
            return button;
        }

        private void StartVisibleDependency(string target)
        {
            StartVisibleScript(_config.InstallScript, "-Target " + target);
        }

        private void StartVisibleScript(string script, string extraArgs = "")
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Shell.Quote(script) + " " + extraArgs,
                WorkingDirectory = _config.Root,
                UseShellExecute = true
            };
            Process.Start(psi);
        }

        private void CheckHermesUpdateAsync()
        {
            System.Threading.ThreadPool.QueueUserWorkItem(_ =>
            {
                var result = Shell.Run("wsl.exe", "-d Ubuntu -- bash -lc " + Shell.Quote("/home/agent/.local/bin/hermes update --check 2>&1 | head -80"), _config.Root, 60000);
                string text = result.Output + result.Error;
                if (text.IndexOf("Update available", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    text.IndexOf("commits behind", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    BeginInvoke(new Action(() =>
                    {
                        _bannerText.Text = "Hermes update available. Codex updates remain inside Codex.";
                        _banner.Visible = true;
                        _banner.BringToFront();
                        try { _tray.ShowBalloonTip(5000, "Asclepius", "Hermes update available.", ToolTipIcon.Info); } catch { }
                    }));
                }
            });
        }
    }

    internal static class Smoke
    {
        public static int Run(AsclepiusConfig config)
        {
            var result = new Dictionary<string, object>();
            result["process_name"] = "Asclepius";
            result["supervisor_mode"] = "host_real_codex";
            result["shows_fake_codex_ui"] = false;
            result["root"] = config.Root;
            result["launch_script_present"] = File.Exists(config.LaunchScript);
            result["install_script_present"] = File.Exists(config.InstallScript);
            result["sessions_script_present"] = File.Exists(config.SessionsScript);
            result["tray_supervisor_menu"] = true;
            var launch = Shell.Run("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File " + Shell.Quote(config.LaunchScript) + " -HostInfoJson", config.Root, 180000);
            result["launch_info_ok"] = launch.ExitCode == 0;
            if (launch.ExitCode == 0)
            {
                var serializer = new JavaScriptSerializer();
                var info = serializer.Deserialize<LaunchInfo>(launch.Output.Trim());
                result["codex_desktop_exe"] = info.CodexDesktopExe;
                result["codex_home"] = info.CodexHome;
                result["selected_model"] = info.SelectedModel;
            }
            else
            {
                result["launch_info_error"] = launch.Error + launch.Output;
            }
            File.WriteAllText(Path.Combine(config.Root, "asclepius-host-smoke.json"), new JavaScriptSerializer().Serialize(result), Encoding.UTF8);
            return launch.ExitCode == 0 ? 0 : 1;
        }
    }

    internal static class Native
    {
        public const int GWL_STYLE = -16;
        public const long WS_CHILD = 0x40000000L;
        public const long WS_POPUP = 0x80000000L;
        public const long WS_CAPTION = 0x00C00000L;
        public const long WS_THICKFRAME = 0x00040000L;
        public const int SW_SHOW = 5;
        public const int WM_CLOSE = 0x0010;

        [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
        [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int nWidth, int nHeight, bool repaint);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] public static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] public static extern IntPtr GetWindowLong32(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] public static extern IntPtr SetWindowLong32(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        public static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex)
        {
            return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, nIndex) : GetWindowLong32(hWnd, nIndex);
        }

        public static IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong)
        {
            return IntPtr.Size == 8 ? SetWindowLongPtr64(hWnd, nIndex, dwNewLong) : SetWindowLong32(hWnd, nIndex, dwNewLong);
        }

        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }
    }
}
