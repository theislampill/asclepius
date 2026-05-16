using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
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
        public static readonly Color Background = Color.FromArgb(18, 19, 22);
        public static readonly Color Surface = Color.FromArgb(28, 30, 34);
        public static readonly Color SurfaceAlt = Color.FromArgb(38, 41, 46);
        public static readonly Color Text = Color.FromArgb(244, 246, 248);
        public static readonly Color Muted = Color.FromArgb(172, 179, 190);
        public static readonly Color Accent = Color.FromArgb(128, 179, 255);
        public static readonly Color AccentDark = Color.FromArgb(50, 84, 132);
        public static readonly Color Success = Color.FromArgb(110, 217, 145);
        public static readonly Color Warning = Color.FromArgb(245, 196, 97);
        public static readonly Color Danger = Color.FromArgb(255, 113, 113);
    }

    internal sealed class MainForm : Form
    {
        private readonly AsclepiusConfig _config;
        private readonly ProcessRunner _runner;
        private readonly ComboBox _models = new ComboBox();
        private readonly TextBox _log = new TextBox();
        private readonly Label _status = new Label();
        private readonly Label _details = new Label();
        private readonly FlowLayoutPanel _checksPanel = new FlowLayoutPanel();
        private readonly Button _launchButton = new Button();
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
            Size = new Size(980, 680);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(900, 600);
            BackColor = Theme.Background;
            ForeColor = Theme.Text;
            Font = new Font("Segoe UI", 9.5f);
            KeyPreview = true;
            AccessibleName = "Asclepius";
            AccessibleDescription = "A local supervisor app for Codex Desktop and Hermes cloud model routing.";

            var title = new Label
            {
                Text = "Asclepius",
                Font = new Font("Segoe UI", 22, FontStyle.Bold),
                Location = new Point(24, 18),
                Size = new Size(220, 42),
                ForeColor = Theme.Text,
                BackColor = Theme.Background
            };
            Controls.Add(title);

            var subtitle = new Label
            {
                Text = "Hermes-backed cloud model selection for an isolated Codex profile.",
                Location = new Point(26, 62),
                Size = new Size(620, 24),
                ForeColor = Theme.Muted,
                BackColor = Theme.Background
            };
            Controls.Add(subtitle);

            _status.Text = "First run checks pending";
            _status.Location = new Point(690, 30);
            _status.Size = new Size(240, 34);
            _status.TextAlign = ContentAlignment.MiddleCenter;
            _status.BackColor = Theme.SurfaceAlt;
            _status.ForeColor = Theme.Warning;
            _status.AccessibleName = "Readiness status";
            Controls.Add(_status);

            var setupPanel = CreatePanel(24, 112, 330, 492, "First run");
            Controls.Add(setupPanel);

            var setupTitle = CreateLabel("First run", 18, 16, 280, 28, 14, FontStyle.Bold, Theme.Text);
            setupPanel.Controls.Add(setupTitle);
            var setupCopy = CreateLabel("Asclepius checks each dependency before it launches the isolated Codex profile.", 18, 48, 286, 44, 9.5f, FontStyle.Regular, Theme.Muted);
            setupPanel.Controls.Add(setupCopy);

            _checksPanel.Location = new Point(18, 98);
            _checksPanel.Size = new Size(294, 374);
            _checksPanel.BackColor = Theme.Surface;
            _checksPanel.FlowDirection = FlowDirection.TopDown;
            _checksPanel.WrapContents = false;
            _checksPanel.AutoScroll = true;
            _checksPanel.AccessibleName = "Dependency checks";
            setupPanel.Controls.Add(_checksPanel);

            var launchPanel = CreatePanel(374, 112, 562, 278, "Launch");
            Controls.Add(launchPanel);

            launchPanel.Controls.Add(CreateLabel("Launch", 18, 16, 180, 28, 14, FontStyle.Bold, Theme.Text));
            launchPanel.Controls.Add(CreateLabel("Choose a provider-qualified route. Paid or unknown routes ask before launch.", 18, 48, 510, 24, 9.5f, FontStyle.Regular, Theme.Muted));

            _models.Location = new Point(18, 86);
            _models.Size = new Size(520, 30);
            _models.DropDownStyle = ComboBoxStyle.DropDownList;
            _models.BackColor = Theme.SurfaceAlt;
            _models.ForeColor = Theme.Text;
            _models.FlatStyle = FlatStyle.Flat;
            _models.AccessibleName = "Cloud model route";
            _models.AccessibleDescription = "Select a provider-qualified cloud model route.";
            _models.SelectedIndexChanged += (s, e) => UpdateDetails();
            launchPanel.Controls.Add(_models);

            _details.Location = new Point(18, 128);
            _details.Size = new Size(520, 66);
            _details.ForeColor = Theme.Muted;
            _details.BackColor = Theme.Surface;
            _details.AccessibleName = "Selected model details";
            launchPanel.Controls.Add(_details);

            StyleButton(_launchButton, "Launch Codex", true);
            _launchButton.Location = new Point(18, 214);
            _launchButton.Size = new Size(134, 38);
            _launchButton.Click += (s, e) => LaunchCodex();
            _launchButton.AccessibleDescription = "Launch Codex Desktop with the selected Asclepius model route.";
            launchPanel.Controls.Add(_launchButton);

            var startButton = CreateButton("Start services", 166, 214, 120, (s, e) => StartServicesThenHealth(), false);
            launchPanel.Controls.Add(startButton);
            var refreshButton = CreateButton("Refresh models", 300, 214, 124, (s, e) => RefreshModels(), false);
            launchPanel.Controls.Add(refreshButton);
            var oauthButton = CreateButton("Nous OAuth", 438, 214, 100, (s, e) => OpenVisible(_config.OAuthScript), false);
            launchPanel.Controls.Add(oauthButton);

            var toolsPanel = CreatePanel(374, 410, 562, 194, "Tools");
            Controls.Add(toolsPanel);
            toolsPanel.Controls.Add(CreateLabel("Tools", 18, 16, 180, 28, 14, FontStyle.Bold, Theme.Text));
            toolsPanel.Controls.Add(CreateLabel("Codex updates stay in Codex. Hermes updates and memory controls stay here.", 18, 48, 510, 24, 9.5f, FontStyle.Regular, Theme.Muted));
            toolsPanel.Controls.Add(CreateButton("Hermes Golden Update", 18, 88, 176, (s, e) => ConfirmAndOpenUpdate(), false));
            toolsPanel.Controls.Add(CreateButton("Hermes Sessions", 210, 88, 138, (s, e) => OpenVisible(_config.SessionsScript), false));
            toolsPanel.Controls.Add(CreateButton("Legacy Picker", 364, 88, 112, (s, e) => OpenVisible(_config.PickerScript), false));

            _log.Location = new Point(18, 126);
            _log.Size = new Size(520, 48);
            _log.Multiline = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.ReadOnly = true;
            _log.BackColor = Color.FromArgb(12, 13, 15);
            _log.ForeColor = Theme.Muted;
            _log.BorderStyle = BorderStyle.FixedSingle;
            _log.AccessibleName = "Asclepius event log";
            toolsPanel.Controls.Add(_log);
        }

        private Panel CreatePanel(int x, int y, int width, int height, string name)
        {
            var panel = new Panel
            {
                Location = new Point(x, y),
                Size = new Size(width, height),
                BackColor = Theme.Surface,
                BorderStyle = BorderStyle.FixedSingle,
                AccessibleName = name
            };
            return panel;
        }

        private Label CreateLabel(string text, int x, int y, int width, int height, float size, FontStyle style, Color color)
        {
            return new Label
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, height),
                Font = new Font("Segoe UI", size, style),
                ForeColor = color,
                BackColor = Theme.Surface
            };
        }

        private Button CreateButton(string text, int x, int y, int width, EventHandler handler, bool primary)
        {
            var button = new Button { Text = text, Location = new Point(x, y), Size = new Size(width, 38) };
            StyleButton(button, text, primary);
            button.Click += handler;
            return button;
        }

        private void StyleButton(Button button, string text, bool primary)
        {
            button.Text = text;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 1;
            button.FlatAppearance.BorderColor = primary ? Theme.Accent : Theme.SurfaceAlt;
            button.BackColor = primary ? Theme.AccentDark : Theme.SurfaceAlt;
            button.ForeColor = Theme.Text;
            button.Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
            button.AccessibleName = text;
            button.TabStop = true;
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
            _details.Text = "Portal: " + model.ProviderDisplay +
                            "\r\nModel: " + model.ModelId +
                            "\r\nRoute: " + model.Slug +
                            "\r\nBilling: " + model.Billing + " " + model.PriceText;
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
            foreach (var item in checks)
            {
                var check = item;
                _checksPanel.Controls.Add(CreateCheckCard(check));
            }

            int missingRequired = checks.Count(c => c.Required && !c.Ok);
            int missingOptional = checks.Count(c => !c.Required && !c.Ok);
            bool canLaunch = ReadinessChecks.CanLaunch(checks);
            _launchButton.Enabled = canLaunch;
            _launchButton.BackColor = canLaunch ? Theme.AccentDark : Color.FromArgb(48, 50, 55);
            _status.Text = canLaunch ? "Ready" : missingRequired + " required setup";
            _status.ForeColor = canLaunch ? Theme.Success : Theme.Warning;
            AppendLog(canLaunch ? "Ready to launch." : "Setup needed: " + missingRequired + " required, " + missingOptional + " optional.");
        }

        private Panel CreateCheckCard(DependencyCheck check)
        {
            var card = new Panel
            {
                Size = new Size(270, String.IsNullOrWhiteSpace(check.Action) ? 78 : 112),
                Margin = new Padding(0, 0, 0, 10),
                BackColor = Theme.SurfaceAlt,
                BorderStyle = BorderStyle.FixedSingle,
                AccessibleName = check.Title + " status"
            };

            var status = CreateLabel(check.Ok ? "OK" : (check.Required ? "Required" : "Optional"), 12, 10, 70, 22, 8.5f, FontStyle.Bold, check.Ok ? Theme.Success : Theme.Warning);
            status.BackColor = Theme.SurfaceAlt;
            card.Controls.Add(status);

            var title = CreateLabel(check.Title, 88, 9, 168, 24, 10.5f, FontStyle.Bold, Theme.Text);
            title.BackColor = Theme.SurfaceAlt;
            card.Controls.Add(title);

            var message = CreateLabel(check.Message ?? "", 12, 38, 244, 36, 8.5f, FontStyle.Regular, Theme.Muted);
            message.BackColor = Theme.SurfaceAlt;
            card.Controls.Add(message);

            if (!String.IsNullOrWhiteSpace(check.Action))
            {
                var buttonText = ActionLabel(check.Action);
                var button = new Button { Location = new Point(12, 78), Size = new Size(160, 28) };
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
