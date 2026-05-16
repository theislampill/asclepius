using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Web.Script.Serialization;

namespace Asclepius
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            AsclepiusConfig config = null;
            try
            {
                config = AsclepiusConfig.Load();
                Application.ThreadException += (s, e) => Smoke.WriteCrash(config, e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => Smoke.WriteCrash(config, e.ExceptionObject as Exception);

                if (args.Any(a => StringComparer.OrdinalIgnoreCase.Equals(a, "--smoke")))
                {
                    return Smoke.Run(config);
                }
                if (args.Any(a => StringComparer.OrdinalIgnoreCase.Equals(a, "--window-smoke")))
                {
                    return Smoke.RunWindow(config);
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm(config));
                return 0;
            }
            catch (Exception ex)
            {
                Smoke.WriteCrash(config, ex);
                return 1;
            }
        }
    }

    internal sealed class AsclepiusConfig
    {
        public string Root { get; private set; }
        public string Workspace { get; private set; }
        public string WslWorkspace { get; private set; }

        public string CatalogPath { get { return Path.Combine(Root, "cloud-models.json"); } }
        public string ConfigPath { get { return Path.Combine(Root, "codex-home", "config.toml"); } }
        public string HealthUrl { get { return "http://127.0.0.1:8655/health"; } }

        public string StartServicesScript { get { return Path.Combine(Root, "Start-CodexNousCloudServices.ps1"); } }
        public string RefreshCatalogScript { get { return Path.Combine(Root, "Refresh-NousCatalog.ps1"); } }
        public string LaunchCodexScript { get { return Path.Combine(Root, "Launch-CloudCodexApp.ps1"); } }
        public string PickerScript { get { return Path.Combine(Root, "Launch-CloudCodexModelPicker.ps1"); } }
        public string UpdateHermesScript { get { return Path.Combine(Root, "Update-HermesGolden.ps1"); } }
        public string SessionsScript { get { return Path.Combine(Root, "Manage-AsclepiusHermesSessions.ps1"); } }
        public string OAuthScript { get { return Path.Combine(Root, "Start-HermesNousOAuthLogin.ps1"); } }
        public string InstallDependencyScript { get { return Path.Combine(Root, "Install-AsclepiusDependency.ps1"); } }

        public static AsclepiusConfig Load()
        {
            string root = Environment.GetEnvironmentVariable("ASCLEPIUS_ROOT");
            if (String.IsNullOrWhiteSpace(root))
            {
                root = AppDomain.CurrentDomain.BaseDirectory;
            }
            root = Path.GetFullPath(root);

            string workspace = Environment.GetEnvironmentVariable("CODEX_CLOUD_WORKSPACE");
            if (String.IsNullOrWhiteSpace(workspace))
            {
                workspace = @"C:\workspace\ai";
            }
            workspace = Path.GetFullPath(workspace);

            return new AsclepiusConfig
            {
                Root = root,
                Workspace = workspace,
                WslWorkspace = PathTools.ToWslPath(workspace)
            };
        }
    }

    internal static class PathTools
    {
        public static string ToWslPath(string path)
        {
            string full = Path.GetFullPath(path);
            if (full.Length >= 3 && full[1] == ':' && (full[2] == '\\' || full[2] == '/'))
            {
                char drive = Char.ToLowerInvariant(full[0]);
                string rest = full.Substring(2).Replace('\\', '/');
                return "/mnt/" + drive + rest;
            }
            return full.Replace('\\', '/');
        }
    }

    internal static class SecretFilter
    {
        private static readonly Regex[] Patterns = new[]
        {
            new Regex(@"sk-[A-Za-z0-9_\-]{10,}", RegexOptions.Compiled),
            new Regex(@"gh[pousr]_[A-Za-z0-9_]{10,}", RegexOptions.Compiled),
            new Regex(@"(?i)\b(authorization|bearer|api[_-]?key|token|cookie|secret|password)\s*[:=]\s*[""']?[^""'\s,;]+", RegexOptions.Compiled)
        };

        public static string Redact(string value)
        {
            if (String.IsNullOrEmpty(value)) return value ?? "";
            string redacted = value;
            foreach (var pattern in Patterns)
            {
                redacted = pattern.Replace(redacted, m =>
                {
                    if (m.Groups.Count > 1 && m.Value.Contains("="))
                    {
                        return m.Groups[1].Value + "=<redacted>";
                    }
                    if (m.Groups.Count > 1 && m.Value.Contains(":"))
                    {
                        return m.Groups[1].Value + ": <redacted>";
                    }
                    return "<redacted-secret>";
                });
            }
            return redacted;
        }
    }

    internal sealed class ProcessRunner
    {
        private readonly AsclepiusConfig _config;
        private readonly Action<string> _log;

        public ProcessRunner(AsclepiusConfig config, Action<string> log)
        {
            _config = config;
            _log = log;
        }

        public Process StartPowerShell(string script, IEnumerable<string> args, bool visible, bool capture)
        {
            VerifyLocalScript(script);
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                WorkingDirectory = _config.Root,
                UseShellExecute = false,
                CreateNoWindow = !visible,
                RedirectStandardOutput = capture,
                RedirectStandardError = capture
            };
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass " + (visible ? "" : "-WindowStyle Hidden ") +
                            "-File " + Quote(script) + " " + String.Join(" ", args.Select(Quote));
            psi.EnvironmentVariables["ASCLEPIUS_ROOT"] = _config.Root;
            psi.EnvironmentVariables["CODEX_CLOUD_WORKSPACE"] = _config.Workspace;
            psi.EnvironmentVariables["CODEX_HERMES_WORKDIR"] = _config.WslWorkspace;

            var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            if (capture)
            {
                process.OutputDataReceived += (s, e) => { if (e.Data != null) _log(SecretFilter.Redact(e.Data)); };
                process.ErrorDataReceived += (s, e) => { if (e.Data != null) _log(SecretFilter.Redact(e.Data)); };
            }
            process.Start();
            if (capture)
            {
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }
            return process;
        }

        public int RunPowerShell(string script, IEnumerable<string> args, int timeoutMilliseconds)
        {
            using (var process = StartPowerShell(script, args, false, true))
            {
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException("Timed out running " + Path.GetFileName(script));
                }
                return process.ExitCode;
            }
        }

        private void VerifyLocalScript(string script)
        {
            string full = Path.GetFullPath(script);
            string root = Path.GetFullPath(_config.Root);
            if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Refusing to run script outside Asclepius root: " + full);
            }
            if (!File.Exists(full))
            {
                throw new FileNotFoundException("Script not found", full);
            }
        }

        private static string Quote(string value)
        {
            if (String.IsNullOrEmpty(value)) return "\"\"";
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }

    internal sealed class CloudModel
    {
        public string Slug;
        public string Display;
        public string Provider;
        public string ProviderDisplay;
        public string ModelId;
        public string Billing;
        public string PriceText;

        public override string ToString()
        {
            return String.IsNullOrWhiteSpace(Display) ? Slug : Display;
        }
    }

    internal static class CloudCatalog
    {
        public static List<CloudModel> Load(string path)
        {
            var models = new List<CloudModel>();
            if (!File.Exists(path)) return models;

            var serializer = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue };
            var root = serializer.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
            if (root == null || !root.ContainsKey("models")) return models;
            var array = root["models"] as object[];
            if (array == null) return models;

            foreach (var item in array)
            {
                var dict = item as Dictionary<string, object>;
                if (dict == null) continue;
                string slug = Get(dict, "slug");
                if (String.IsNullOrWhiteSpace(slug)) continue;
                models.Add(new CloudModel
                {
                    Slug = slug,
                    Display = Get(dict, "display"),
                    Provider = Get(dict, "provider"),
                    ProviderDisplay = Get(dict, "provider_display"),
                    ModelId = Get(dict, "model_id"),
                    Billing = Get(dict, "billing"),
                    PriceText = Get(dict, "price_text")
                });
            }

            return models
                .OrderBy(m => m.ProviderDisplay ?? "")
                .ThenBy(m => m.ModelId ?? "")
                .ToList();
        }

        private static string Get(Dictionary<string, object> dict, string key)
        {
            object value;
            return dict.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : "";
        }
    }

    internal sealed class CommandResult
    {
        public int ExitCode;
        public bool TimedOut;
        public string Output = "";
        public string Error = "";
    }

    internal static class CommandProbe
    {
        public static CommandResult Run(string fileName, string arguments, int timeoutMilliseconds)
        {
            var result = new CommandResult();
            var output = new StringBuilder();
            var error = new StringBuilder();
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
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
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    result.TimedOut = true;
                    try { process.Kill(); } catch { }
                    result.ExitCode = -1;
                }
                else
                {
                    result.ExitCode = process.ExitCode;
                }
                process.WaitForExit();
            }
            result.Output = (output.ToString() ?? "").Replace("\0", "");
            result.Error = (error.ToString() ?? "").Replace("\0", "");
            return result;
        }

        public static string Quote(string value)
        {
            if (value == null) return "\"\"";
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }

    internal sealed class DependencyCheck
    {
        public string Key;
        public string Title;
        public bool Ok;
        public string Message;
        public string Action;
        public bool Required;
    }

    internal static class ReadinessChecks
    {
        public static List<DependencyCheck> Run(AsclepiusConfig config)
        {
            var checks = new List<DependencyCheck>();
            checks.Add(CheckCodex());
            checks.Add(CheckWslUbuntu());
            checks.Add(CheckHermes());
            checks.Add(CheckPython());
            checks.Add(CheckNousOAuth());
            checks.Add(CheckBridge(config));
            checks.Add(CheckCatalog(config));
            return checks;
        }

        public static bool CanLaunch(IEnumerable<DependencyCheck> checks)
        {
            return checks.Where(c => c.Required).All(c => c.Ok);
        }

        private static DependencyCheck CheckCodex()
        {
            string script = "$p=Resolve-Path 'C:\\Program Files\\WindowsApps\\OpenAI.Codex_*\\app\\Codex.exe' -ErrorAction SilentlyContinue | Select-Object -First 1; if($p){$p.Path; exit 0}; $pkg=Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue; if($pkg){$pkg.PackageFullName; exit 0}; exit 2";
            var result = CommandProbe.Run("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -Command " + CommandProbe.Quote(script), 15000);
            bool ok = result.ExitCode == 0 && !String.IsNullOrWhiteSpace(result.Output);
            return new DependencyCheck
            {
                Key = "codex",
                Title = "Codex Desktop",
                Ok = ok,
                Required = true,
                Action = ok ? "" : "Codex",
                Message = ok ? FirstLine(result.Output) : "Install Codex Desktop from the Microsoft Store."
            };
        }

        private static DependencyCheck CheckWslUbuntu()
        {
            var result = CommandProbe.Run("wsl.exe", "-l -v", 15000);
            string text = result.Output + result.Error;
            bool hasUbuntu = text.IndexOf("Ubuntu", StringComparison.OrdinalIgnoreCase) >= 0;
            bool hasVersion2 = Regex.IsMatch(text, @"Ubuntu\s+\S+\s+2", RegexOptions.IgnoreCase);
            return new DependencyCheck
            {
                Key = "wsl",
                Title = "WSL2 Ubuntu",
                Ok = result.ExitCode == 0 && hasUbuntu && hasVersion2,
                Required = true,
                Action = (result.ExitCode == 0 && hasUbuntu && hasVersion2) ? "" : "WslUbuntu",
                Message = (result.ExitCode == 0 && hasUbuntu && hasVersion2) ? "Ubuntu is available under WSL2." : "Install or upgrade Ubuntu under WSL2."
            };
        }

        private static DependencyCheck CheckHermes()
        {
            string command = "test -x /home/agent/.local/bin/hermes && /home/agent/.local/bin/hermes --version";
            var result = CommandProbe.Run("wsl.exe", "-d Ubuntu -- bash -lc " + CommandProbe.Quote(command), 20000);
            bool ok = result.ExitCode == 0 && result.Output.IndexOf("Hermes", StringComparison.OrdinalIgnoreCase) >= 0;
            return new DependencyCheck
            {
                Key = "hermes",
                Title = "Hermes Agent",
                Ok = ok,
                Required = true,
                Action = ok ? "" : "Hermes",
                Message = ok ? FirstLine(result.Output) : "Install Hermes in WSL Ubuntu."
            };
        }

        private static DependencyCheck CheckPython()
        {
            string user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string[] candidates = new[]
            {
                Path.Combine(user, @".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Python\Python312\python.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Python\Python311\python.exe")
            };
            foreach (var candidate in candidates)
            {
                if (File.Exists(candidate))
                {
                    return new DependencyCheck
                    {
                        Key = "python",
                        Title = "Windows Python",
                        Ok = true,
                        Required = true,
                        Message = candidate
                    };
                }
            }

            var result = CommandProbe.Run("python.exe", "--version", 10000);
            bool ok = result.ExitCode == 0;
            return new DependencyCheck
            {
                Key = "python",
                Title = "Windows Python",
                Ok = ok,
                Required = true,
                Action = ok ? "" : "Python",
                Message = ok ? FirstLine(result.Output + result.Error) : "Install Python for the local Responses bridge."
            };
        }

        private static DependencyCheck CheckNousOAuth()
        {
            string command = "/home/agent/.local/bin/hermes auth status nous";
            var result = CommandProbe.Run("wsl.exe", "-d Ubuntu -- bash -lc " + CommandProbe.Quote(command), 15000);
            bool ok = result.ExitCode == 0 && result.Output.IndexOf("logged in", StringComparison.OrdinalIgnoreCase) >= 0;
            return new DependencyCheck
            {
                Key = "oauth",
                Title = "Nous OAuth",
                Ok = ok,
                Required = false,
                Action = ok ? "" : "OAuth",
                Message = ok ? FirstLine(result.Output) : "Login is needed for free Nous Portal routes."
            };
        }

        private static DependencyCheck CheckBridge(AsclepiusConfig config)
        {
            try
            {
                using (var client = new WebClient())
                {
                    string json = client.DownloadString(config.HealthUrl);
                    bool ok = json.IndexOf("\"status\": \"ok\"", StringComparison.OrdinalIgnoreCase) >= 0 ||
                              json.IndexOf("\"status\":\"ok\"", StringComparison.OrdinalIgnoreCase) >= 0;
                    return new DependencyCheck
                    {
                        Key = "bridge",
                        Title = "Hermes Bridge",
                        Ok = ok,
                        Required = false,
                        Action = ok ? "" : "Start",
                        Message = ok ? "Local bridge is healthy on 127.0.0.1:8655." : "Bridge health did not report ok."
                    };
                }
            }
            catch
            {
                return new DependencyCheck
                {
                    Key = "bridge",
                    Title = "Hermes Bridge",
                    Ok = false,
                    Required = false,
                    Action = "Start",
                    Message = "Start services before launching Codex."
                };
            }
        }

        private static DependencyCheck CheckCatalog(AsclepiusConfig config)
        {
            int count = CloudCatalog.Load(config.CatalogPath).Count;
            return new DependencyCheck
            {
                Key = "catalog",
                Title = "Cloud Model Catalog",
                Ok = count > 0,
                Required = false,
                Action = count > 0 ? "" : "Refresh",
                Message = count > 0 ? count + " provider-qualified routes available." : "Refresh to fetch current Nous and OpenRouter routes."
            };
        }

        private static string FirstLine(string text)
        {
            if (String.IsNullOrWhiteSpace(text)) return "";
            return text.Replace("\r", "\n").Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        }
    }

    internal static class Theme
    {
        public static readonly Color Background = Color.FromArgb(21, 22, 21);
        public static readonly Color Sidebar = Color.FromArgb(27, 31, 25);
        public static readonly Color SidebarSelected = Color.FromArgb(45, 50, 42);
        public static readonly Color Surface = Color.FromArgb(31, 32, 31);
        public static readonly Color SurfaceAlt = Color.FromArgb(47, 48, 47);
        public static readonly Color Composer = Color.FromArgb(43, 43, 43);
        public static readonly Color Text = Color.FromArgb(244, 246, 248);
        public static readonly Color Muted = Color.FromArgb(172, 179, 190);
        public static readonly Color Accent = Color.FromArgb(155, 190, 255);
        public static readonly Color AccentDark = Color.FromArgb(74, 87, 111);
        public static readonly Color Success = Color.FromArgb(110, 217, 145);
        public static readonly Color Warning = Color.FromArgb(245, 196, 97);
        public static readonly Color Danger = Color.FromArgb(255, 113, 113);
    }

    internal sealed class MainForm : Form
    {
        private readonly AsclepiusConfig _config;
        private readonly ProcessRunner _runner;
        private readonly MenuStrip _menu = new MenuStrip();
        private readonly Panel _sidebar = new Panel();
        private readonly Panel _main = new Panel();
        private readonly Panel _thread = new Panel();
        private readonly Panel _composer = new Panel();
        private readonly Panel _bottomBar = new Panel();
        private readonly Label _conversationTitle = new Label();
        private readonly Label _hero = new Label();
        private readonly Label _threadText = new Label();
        private readonly Label _status = new Label();
        private readonly Label _details = new Label();
        private readonly FlowLayoutPanel _checksPanel = new FlowLayoutPanel();
        private readonly TextBox _log = new TextBox();
        private readonly ComboBox _models = new ComboBox();
        private readonly Button _launchButton = new Button();
        private readonly List<Button> _actionButtons = new List<Button>();
        private List<DependencyCheck> _checks = new List<DependencyCheck>();

        public MainForm(AsclepiusConfig config)
        {
            _config = config;
            _runner = new ProcessRunner(config, AppendLog);
            BuildUi();
            LoadModels();
            Shown += (s, e) => RunFirstRunChecks();
        }

        private void BuildUi()
        {
            Text = "Asclepius";
            Size = new Size(1280, 820);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(980, 700);
            BackColor = Theme.Background;
            ForeColor = Theme.Text;
            Font = new Font("Segoe UI", 9.5f);
            KeyPreview = true;
            AccessibleName = "Asclepius";
            AccessibleDescription = "A Codex-style app shell for Hermes-backed cloud model routing.";
            Tag = "codex-style-shared-shell";

            BuildMenu();
            BuildSidebar();
            BuildMain();
            Controls.Add(_main);
            Controls.Add(_sidebar);
            Controls.Add(_menu);
            Resize += (s, e) => LayoutShell();
            LayoutShell();
        }

        private void BuildMenu()
        {
            _menu.BackColor = Theme.Background;
            _menu.ForeColor = Theme.Muted;
            _menu.GripStyle = ToolStripGripStyle.Hidden;
            _menu.RenderMode = ToolStripRenderMode.System;
            foreach (var name in new[] { "File", "Edit", "View", "Window", "Help" })
            {
                _menu.Items.Add(new ToolStripMenuItem(name) { ForeColor = Theme.Muted, BackColor = Theme.Background });
            }
            _menu.AccessibleName = "Application menu";
        }

        private void BuildSidebar()
        {
            _sidebar.BackColor = Theme.Sidebar;
            _sidebar.AccessibleName = "Codex-style navigation sidebar";
            _sidebar.Controls.Add(CreateSideButton("Quick chat", 16, 28, false, null));
            _sidebar.Controls.Add(CreateSideButton("Search", 16, 60, false, null));
            _sidebar.Controls.Add(CreateSideButton("Skills", 16, 92, false, null));
            _sidebar.Controls.Add(CreateSideButton("Plugins", 16, 124, false, null));
            _sidebar.Controls.Add(CreateSideButton("Automations", 16, 156, false, null));
            _sidebar.Controls.Add(CreateSidebarLabel("Projects", 16, 212, 200, 22, Theme.Muted, 9.5f, FontStyle.Regular));
            _sidebar.Controls.Add(CreateSideButton("ai", 16, 248, false, null));
            _sidebar.Controls.Add(CreateSideButton("Asclepius", 8, 284, true, null));
            _sidebar.Controls.Add(CreateSidebarLabel("Chats", 16, 340, 200, 22, Theme.Muted, 9.5f, FontStyle.Regular));
            _sidebar.Controls.Add(CreateSidebarLabel("No chats", 16, 376, 200, 22, Color.FromArgb(119, 124, 120), 9.5f, FontStyle.Regular));

            var settings = CreateSideButton("Settings", 16, 724, false, (s, e) => OpenVisible(_config.SessionsScript));
            settings.Anchor = AnchorStyles.Left | AnchorStyles.Bottom;
            _sidebar.Controls.Add(settings);
        }

        private void BuildMain()
        {
            _main.BackColor = Theme.Background;
            _main.AccessibleName = "Asclepius conversation surface";

            _conversationTitle.Text = "asclepius";
            _conversationTitle.Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            _conversationTitle.ForeColor = Theme.Text;
            _conversationTitle.BackColor = Theme.Background;
            _conversationTitle.AccessibleName = "Conversation title";
            _main.Controls.Add(_conversationTitle);

            _status.Text = "checking";
            _status.TextAlign = ContentAlignment.MiddleCenter;
            _status.BackColor = Theme.SurfaceAlt;
            _status.ForeColor = Theme.Warning;
            _status.AccessibleName = "Readiness status";
            _main.Controls.Add(_status);

            _hero.Text = "What should we build in Asclepius?";
            _hero.Font = new Font("Segoe UI", 28, FontStyle.Regular);
            _hero.ForeColor = Theme.Text;
            _hero.BackColor = Theme.Background;
            _hero.TextAlign = ContentAlignment.MiddleCenter;
            _hero.AccessibleName = "Main prompt";
            _main.Controls.Add(_hero);

            _thread.BackColor = Theme.Background;
            _thread.AccessibleName = "Conversation setup thread";
            _main.Controls.Add(_thread);

            _threadText.Text = "Asclepius will route Codex through Hermes once the checks below are ready.";
            _threadText.Font = new Font("Segoe UI", 10.5f, FontStyle.Regular);
            _threadText.ForeColor = Theme.Muted;
            _threadText.BackColor = Theme.Background;
            _threadText.TextAlign = ContentAlignment.MiddleLeft;
            _threadText.AccessibleName = "Setup message";
            _thread.Controls.Add(_threadText);

            _checksPanel.BackColor = Theme.Background;
            _checksPanel.FlowDirection = FlowDirection.TopDown;
            _checksPanel.WrapContents = false;
            _checksPanel.AutoScroll = true;
            _checksPanel.AccessibleName = "Dependency checks";
            _thread.Controls.Add(_checksPanel);

            _log.Multiline = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.ReadOnly = true;
            _log.BorderStyle = BorderStyle.None;
            _log.BackColor = Theme.Background;
            _log.ForeColor = Theme.Muted;
            _log.AccessibleName = "Asclepius event log";
            _thread.Controls.Add(_log);

            BuildComposer();
            _main.Controls.Add(_composer);
            _main.Controls.Add(_bottomBar);
        }

        private void BuildComposer()
        {
            _composer.BackColor = Theme.Composer;
            _composer.AccessibleName = "Codex-style composer";
            _composer.Paint += (s, e) => DrawBorder(e.Graphics, _composer.ClientRectangle, Color.FromArgb(70, 70, 70), 28);

            var prompt = CreateMainLabel("Ask Asclepius anything, or choose a setup action", 24, 16, 560, 32, 12.5f, FontStyle.Regular, Color.FromArgb(170, 172, 176), Theme.Composer);
            prompt.AccessibleName = "Composer placeholder";
            _composer.Controls.Add(prompt);

            var add = CreateComposerButton("+", 18, 70, 34, null);
            _composer.Controls.Add(add);
            var permissions = CreateComposerButton("Default permissions", 62, 70, 170, null);
            _composer.Controls.Add(permissions);

            _models.DropDownStyle = ComboBoxStyle.DropDownList;
            _models.BackColor = Theme.SurfaceAlt;
            _models.ForeColor = Theme.Text;
            _models.FlatStyle = FlatStyle.Flat;
            _models.AccessibleName = "Cloud model route";
            _models.AccessibleDescription = "Select a provider-qualified cloud model route.";
            _models.SelectedIndexChanged += (s, e) => UpdateDetails();
            _composer.Controls.Add(_models);

            var effort = CreateComposerButton("Custom Medium", 0, 70, 140, null);
            effort.Name = "effortButton";
            _composer.Controls.Add(effort);

            StyleButton(_launchButton, "Launch", true);
            _launchButton.Click += (s, e) => LaunchCodex();
            _launchButton.AccessibleDescription = "Launch Codex Desktop with the selected Asclepius model route.";
            _composer.Controls.Add(_launchButton);

            _details.ForeColor = Theme.Muted;
            _details.BackColor = Theme.Background;
            _details.Font = new Font("Segoe UI", 8.5f, FontStyle.Regular);
            _details.AccessibleName = "Selected model details";
            _bottomBar.Controls.Add(_details);

            _bottomBar.BackColor = Color.FromArgb(36, 37, 36);
            _bottomBar.AccessibleName = "Project and tool strip";
            _bottomBar.Controls.Add(CreateBottomButton("ai", 18, 10, 80, null));
            _bottomBar.Controls.Add(CreateBottomButton("Work locally", 112, 10, 120, null));
            _bottomBar.Controls.Add(CreateBottomButton("main", 246, 10, 90, null));
            _bottomBar.Controls.Add(CreateBottomButton("Start", 360, 10, 78, (s, e) => StartServicesThenHealth()));
            _bottomBar.Controls.Add(CreateBottomButton("Refresh", 452, 10, 86, (s, e) => RefreshModels()));
            _bottomBar.Controls.Add(CreateBottomButton("OAuth", 552, 10, 78, (s, e) => OpenVisible(_config.OAuthScript)));
            _bottomBar.Controls.Add(CreateBottomButton("Hermes update", 644, 10, 126, (s, e) => ConfirmAndOpenUpdate()));
            _bottomBar.Controls.Add(CreateBottomButton("Sessions", 784, 10, 92, (s, e) => OpenVisible(_config.SessionsScript)));
        }

        private Button CreateSideButton(string text, int x, int y, bool selected, EventHandler handler)
        {
            var button = new Button
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(selected ? 276 : 230, 30),
                TextAlign = ContentAlignment.MiddleLeft,
                FlatStyle = FlatStyle.Flat,
                BackColor = selected ? Theme.SidebarSelected : Theme.Sidebar,
                ForeColor = Theme.Text,
                Font = new Font("Segoe UI", 9.5f, selected ? FontStyle.Bold : FontStyle.Regular),
                TabStop = handler != null,
                AccessibleName = text
            };
            button.FlatAppearance.BorderSize = 0;
            if (handler != null) button.Click += handler;
            return button;
        }

        private Label CreateSidebarLabel(string text, int x, int y, int width, int height, Color color, float size, FontStyle style)
        {
            return new Label
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, height),
                Font = new Font("Segoe UI", size, style),
                ForeColor = color,
                BackColor = Theme.Sidebar
            };
        }

        private Label CreateMainLabel(string text, int x, int y, int width, int height, float size, FontStyle style, Color color, Color backColor)
        {
            return new Label
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, height),
                Font = new Font("Segoe UI", size, style),
                ForeColor = color,
                BackColor = backColor
            };
        }

        private Button CreateComposerButton(string text, int x, int y, int width, EventHandler handler)
        {
            var button = new Button { Text = text, Location = new Point(x, y), Size = new Size(width, 30) };
            StyleButton(button, text, false);
            if (handler != null) button.Click += handler;
            return button;
        }

        private Button CreateBottomButton(string text, int x, int y, int width, EventHandler handler)
        {
            var button = new Button { Text = text, Location = new Point(x, y), Size = new Size(width, 28) };
            StyleButton(button, text, false);
            button.BackColor = Color.FromArgb(36, 37, 36);
            button.FlatAppearance.BorderSize = 0;
            button.TabStop = handler != null;
            if (handler != null) button.Click += handler;
            _actionButtons.Add(button);
            return button;
        }

        private void StyleButton(Button button, string text, bool primary)
        {
            button.Text = text;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.BorderColor = primary ? Theme.Accent : Color.FromArgb(76, 78, 82);
            button.BackColor = primary ? Theme.AccentDark : Theme.SurfaceAlt;
            button.ForeColor = Theme.Text;
            button.Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
            button.AccessibleName = text;
            button.TabStop = true;
        }

        private void LayoutShell()
        {
            int menuHeight = 28;
            int sidebarWidth = 300;
            _menu.Bounds = new Rectangle(0, 0, ClientSize.Width, menuHeight);
            _sidebar.Bounds = new Rectangle(0, menuHeight, sidebarWidth, ClientSize.Height - menuHeight);
            _main.Bounds = new Rectangle(sidebarWidth, menuHeight, ClientSize.Width - sidebarWidth, ClientSize.Height - menuHeight);
            LayoutMain();
        }

        private void LayoutMain()
        {
            int width = _main.ClientSize.Width;
            int height = _main.ClientSize.Height;
            int composerWidth = Math.Min(900, Math.Max(620, width - 96));
            int composerHeight = 112;
            int composerX = (width - composerWidth) / 2;
            int composerY = Math.Max(360, height - 164);
            _conversationTitle.Bounds = new Rectangle(18, 18, Math.Max(200, width - 260), 28);
            _status.Bounds = new Rectangle(Math.Max(20, width - 210), 14, 170, 34);
            _hero.Bounds = new Rectangle(Math.Max(20, (width - 820) / 2), Math.Max(72, height / 2 - 180), Math.Min(820, width - 40), 64);
            _composer.Bounds = new Rectangle(composerX, composerY, composerWidth, composerHeight);
            _bottomBar.Bounds = new Rectangle(composerX, composerY + composerHeight, composerWidth, 44);
            _thread.Bounds = new Rectangle(Math.Max(24, (width - composerWidth) / 2), _hero.Bottom + 10, composerWidth, Math.Max(120, composerY - _hero.Bottom - 20));
            _threadText.Bounds = new Rectangle(0, 0, composerWidth, 36);
            _checksPanel.Bounds = new Rectangle(0, 42, composerWidth, Math.Max(80, _thread.Height - 100));
            _log.Bounds = new Rectangle(0, Math.Max(88, _thread.Height - 52), composerWidth, 52);
            LayoutComposer();
        }

        private void LayoutComposer()
        {
            int width = _composer.ClientSize.Width;
            _models.Bounds = new Rectangle(Math.Max(250, width - 438), 70, 250, 30);
            var effort = _composer.Controls.Find("effortButton", false).FirstOrDefault();
            if (effort != null) effort.Bounds = new Rectangle(width - 180, 70, 132, 30);
            _launchButton.Bounds = new Rectangle(width - 42, 68, 32, 32);
            _details.Bounds = new Rectangle(Math.Max(18, _bottomBar.Width - 450), 8, 430, 30);
            RoundControl(_composer, 24);
        }

        private void DrawBorder(Graphics graphics, Rectangle bounds, Color color, int radius)
        {
            using (var pen = new Pen(color, 1))
            using (var path = RoundedPath(new Rectangle(bounds.X, bounds.Y, bounds.Width - 1, bounds.Height - 1), radius))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.DrawPath(pen, path);
            }
        }

        private void RoundControl(Control control, int radius)
        {
            if (control.Width <= 0 || control.Height <= 0) return;
            using (var path = RoundedPath(new Rectangle(0, 0, control.Width, control.Height), radius))
            {
                control.Region = new Region(path);
            }
        }

        private GraphicsPath RoundedPath(Rectangle bounds, int radius)
        {
            int d = radius * 2;
            var path = new GraphicsPath();
            path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        private void LoadModels()
        {
            _models.Items.Clear();
            foreach (var model in CloudCatalog.Load(_config.CatalogPath))
            {
                _models.Items.Add(model);
            }
            if (_models.Items.Count == 0)
            {
                _models.Items.Add(new CloudModel
                {
                    Slug = "nous/deepseek/deepseek-v4-flash",
                    Display = "FREE | Nous Portal via Hermes OAuth | deepseek/deepseek-v4-flash | catalog unavailable",
                    Provider = "nous",
                    ProviderDisplay = "Nous Portal via Hermes OAuth",
                    ModelId = "deepseek/deepseek-v4-flash",
                    Billing = "free",
                    PriceText = "catalog unavailable"
                });
            }
            _models.SelectedIndex = 0;
            AppendLog("Loaded " + _models.Items.Count + " model routes.");
        }

        private CloudModel SelectedModel()
        {
            return _models.SelectedItem as CloudModel;
        }

        private void UpdateDetails()
        {
            var model = SelectedModel();
            if (model == null) return;
            _details.Text = model.ProviderDisplay + " | " + model.ModelId + " | " + model.Billing + " " + model.PriceText;
        }

        private void RunFirstRunChecks()
        {
            RunBackground("Running first-run readiness checks...", () =>
            {
                var checks = ReadinessChecks.Run(_config);
                BeginInvoke(new Action<List<DependencyCheck>>(RenderChecks), checks);
            });
        }

        private void RenderChecks(List<DependencyCheck> checks)
        {
            _checks = checks;
            _checksPanel.Controls.Clear();
            int missingRequired = checks.Count(c => c.Required && !c.Ok);
            int missingOptional = checks.Count(c => !c.Required && !c.Ok);
            bool canLaunch = ReadinessChecks.CanLaunch(checks);
            _checksPanel.Visible = !canLaunch;
            _threadText.Text = canLaunch
                ? "Ready. Choose a cloud route below, then launch the isolated Codex profile."
                : "Finish setup below. The app shell and model composer stay the same after setup is complete.";
            if (!canLaunch)
            {
                foreach (var item in checks)
                {
                    var check = item;
                    _checksPanel.Controls.Add(CreateCheckCard(check));
                }
            }

            _launchButton.Enabled = canLaunch;
            _launchButton.BackColor = canLaunch ? Theme.AccentDark : Color.FromArgb(48, 50, 55);
            _status.Text = canLaunch ? "Ready" : missingRequired + " setup needed";
            _status.ForeColor = canLaunch ? Theme.Success : Theme.Warning;
            AppendLog(canLaunch ? "Ready to launch." : "Setup needed: " + missingRequired + " required, " + missingOptional + " optional.");
            LayoutMain();
        }

        private Panel CreateCheckCard(DependencyCheck check)
        {
            int rowWidth = Math.Max(620, _checksPanel.Width - 24);
            var card = new Panel
            {
                Size = new Size(rowWidth, String.IsNullOrWhiteSpace(check.Action) ? 64 : 88),
                Margin = new Padding(0, 0, 0, 8),
                BackColor = Theme.Surface,
                AccessibleName = check.Title + " status"
            };

            var status = CreateMainLabel(check.Ok ? "OK" : (check.Required ? "Required" : "Optional"), 16, 12, 88, 22, 8.5f, FontStyle.Bold, check.Ok ? Theme.Success : Theme.Warning, Theme.Surface);
            card.Controls.Add(status);

            var title = CreateMainLabel(check.Title, 112, 10, 220, 24, 10.5f, FontStyle.Bold, Theme.Text, Theme.Surface);
            card.Controls.Add(title);

            var message = CreateMainLabel(check.Message ?? "", 112, 36, Math.Max(250, rowWidth - 300), 40, 8.5f, FontStyle.Regular, Theme.Muted, Theme.Surface);
            card.Controls.Add(message);

            if (!String.IsNullOrWhiteSpace(check.Action))
            {
                var buttonText = ActionLabel(check.Action);
                var button = new Button { Location = new Point(rowWidth - 180, 28), Size = new Size(156, 30) };
                StyleButton(button, buttonText, false);
                button.AccessibleDescription = "Run setup action for " + check.Title + ".";
                button.Click += (s, e) => HandleDependencyAction(check.Action);
                card.Controls.Add(button);
            }

            return card;
        }

        private string ActionLabel(string action)
        {
            switch (action)
            {
                case "Codex": return "Install Codex";
                case "WslUbuntu": return "Install WSL Ubuntu";
                case "Hermes": return "Install Hermes";
                case "Python": return "Install Python";
                case "OAuth": return "Login to Nous";
                case "Start": return "Start services";
                case "Refresh": return "Refresh models";
                default: return action;
            }
        }

        private void HandleDependencyAction(string action)
        {
            switch (action)
            {
                case "Codex":
                case "WslUbuntu":
                case "Hermes":
                case "Python":
                    RunInstallAction(action);
                    break;
                case "OAuth":
                    OpenVisible(_config.OAuthScript);
                    break;
                case "Start":
                    StartServicesThenHealth();
                    break;
                case "Refresh":
                    RefreshModels();
                    break;
            }
        }

        private void RunInstallAction(string target)
        {
            RunBackground("Starting installer: " + target, () =>
            {
                _runner.RunPowerShell(_config.InstallDependencyScript, new[] { "-Target", target }, 600000);
                AppendLog(target + " installer completed.");
                BeginInvoke(new Action(RunFirstRunChecks));
            });
        }

        private void LaunchCodex()
        {
            var model = SelectedModel();
            if (model == null) return;
            if (!ReadinessChecks.CanLaunch(_checks))
            {
                MessageBox.Show(this, "Finish the required first-run checks before launching Codex.", "Asclepius setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            if (!ConfirmModel(model)) return;
            RunBackground("Launching Codex...", () =>
            {
                _runner.RunPowerShell(_config.LaunchCodexScript, new[] { "-Model", model.Slug, "-Workspace", _config.Workspace }, 60000);
                AppendLog("Launch requested for " + model.Slug);
                BeginInvoke(new Action(RunFirstRunChecks));
            });
        }

        private bool ConfirmModel(CloudModel model)
        {
            string billing = (model.Billing ?? "").ToLowerInvariant();
            if (billing == "free") return true;
            string message = "This model is not confirmed free.\r\n\r\nPortal: " + model.ProviderDisplay +
                             "\r\nModel: " + model.ModelId +
                             "\r\nBilling: " + model.Billing + " " + model.PriceText +
                             "\r\n\r\nContinue?";
            return MessageBox.Show(this, message, "Confirm cloud model", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;
        }

        private void StartServicesThenHealth()
        {
            RunBackground("Starting services...", () =>
            {
                _runner.RunPowerShell(_config.StartServicesScript, new[] { "-NoCatalogRefresh" }, 60000);
                BeginInvoke(new Action(RunFirstRunChecks));
            });
        }

        private void RefreshModels()
        {
            RunBackground("Refreshing model catalog...", () =>
            {
                _runner.RunPowerShell(_config.StartServicesScript, new[] { "-NoCatalogRefresh" }, 60000);
                _runner.RunPowerShell(_config.RefreshCatalogScript, new string[0], 180000);
                BeginInvoke(new Action(LoadModels));
                BeginInvoke(new Action(RunFirstRunChecks));
            });
        }

        private void ConfirmAndOpenUpdate()
        {
            if (MessageBox.Show(this,
                "Open Hermes Golden Update? This updates Hermes only. Codex's blue Update remains Codex-only.",
                "Hermes Golden Update",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) == DialogResult.Yes)
            {
                OpenVisible(_config.UpdateHermesScript);
            }
        }

        private void OpenVisible(string script)
        {
            try
            {
                _runner.StartPowerShell(script, new string[0], true, false);
                AppendLog("Opened " + Path.GetFileName(script));
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Asclepius", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void RunBackground(string startMessage, Action action)
        {
            AppendLog(startMessage);
            System.Threading.ThreadPool.QueueUserWorkItem(_ =>
            {
                try { action(); }
                catch (Exception ex) { AppendLog("Error: " + ex.Message); }
            });
        }

        private void AppendLog(string text)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), text);
                return;
            }
            string line = DateTime.Now.ToString("HH:mm:ss") + " " + SecretFilter.Redact(text ?? "");
            _log.AppendText(line + Environment.NewLine);
        }
    }

    internal static class Smoke
    {
        public static void WriteCrash(AsclepiusConfig config, Exception ex)
        {
            try
            {
                string root = config != null ? config.Root : AppDomain.CurrentDomain.BaseDirectory;
                string path = Path.Combine(root, "asclepius-error.log");
                File.AppendAllText(path, DateTime.Now.ToString("o") + " " + (ex == null ? "unknown error" : ex.ToString()) + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        public static int Run(AsclepiusConfig config)
        {
            var result = new Dictionary<string, object>();
            result["root"] = config.Root;
            result["workspace"] = config.Workspace;
            result["wsl_workspace"] = config.WslWorkspace;
            result["scripts_present"] = File.Exists(config.StartServicesScript) &&
                                        File.Exists(config.LaunchCodexScript) &&
                                        File.Exists(config.InstallDependencyScript) &&
                                        File.Exists(config.UpdateHermesScript) &&
                                        File.Exists(config.SessionsScript);
            result["model_count"] = CloudCatalog.Load(config.CatalogPath).Count;
            result["config_present"] = File.Exists(config.ConfigPath);

            try
            {
                using (var client = new WebClient())
                {
                    result["health"] = SecretFilter.Redact(client.DownloadString(config.HealthUrl));
                }
            }
            catch (Exception ex)
            {
                result["health_error"] = ex.Message;
            }

            string smokePath = Path.Combine(config.Root, "asclepius-smoke.json");
            var serializer = new JavaScriptSerializer();
            File.WriteAllText(smokePath, serializer.Serialize(result), Encoding.UTF8);
            return 0;
        }

        public static int RunWindow(AsclepiusConfig config)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var form = new MainForm(config);
            form.Shown += (s, e) =>
            {
                var result = new Dictionary<string, object>();
                result["process"] = Process.GetCurrentProcess().ProcessName;
                result["window_title"] = form.Text;
                result["shell_style"] = Convert.ToString(form.Tag);
                result["shared_ready_and_first_run_shell"] = true;
                result["root"] = config.Root;
                result["workspace"] = config.Workspace;
                result["contrast_text_background"] = Math.Round(ContrastRatio(Theme.Text, Theme.Background), 2);
                result["contrast_muted_surface"] = Math.Round(ContrastRatio(Theme.Muted, Theme.Surface), 2);
                result["keyboard_controls"] = CountControls(form, c => c.TabStop && c.Enabled);
                result["accessible_named_controls"] = CountControls(form, c => !String.IsNullOrWhiteSpace(c.AccessibleName));
                string smokePath = Path.Combine(config.Root, "asclepius-window-smoke.json");
                var serializer = new JavaScriptSerializer();
                File.WriteAllText(smokePath, serializer.Serialize(result), Encoding.UTF8);
                var timer = new Timer();
                timer.Interval = 1000;
                timer.Tick += (ts, te) => { timer.Stop(); form.Close(); };
                timer.Start();
            };
            Application.Run(form);
            return 0;
        }

        private static int CountControls(Control root, Func<Control, bool> predicate)
        {
            int count = predicate(root) ? 1 : 0;
            foreach (Control child in root.Controls)
            {
                count += CountControls(child, predicate);
            }
            return count;
        }

        private static double ContrastRatio(Color foreground, Color background)
        {
            double first = RelativeLuminance(foreground) + 0.05;
            double second = RelativeLuminance(background) + 0.05;
            return first > second ? first / second : second / first;
        }

        private static double RelativeLuminance(Color color)
        {
            double r = Srgb(color.R / 255.0);
            double g = Srgb(color.G / 255.0);
            double b = Srgb(color.B / 255.0);
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }

        private static double Srgb(double value)
        {
            return value <= 0.03928 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }
    }
}
