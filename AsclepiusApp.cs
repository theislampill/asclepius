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

    internal sealed class MainForm : Form
    {
        private readonly AsclepiusConfig _config;
        private readonly ProcessRunner _runner;
        private readonly ComboBox _models = new ComboBox();
        private readonly TextBox _log = new TextBox();
        private readonly Label _health = new Label();
        private readonly Label _details = new Label();

        public MainForm(AsclepiusConfig config)
        {
            _config = config;
            _runner = new ProcessRunner(config, AppendLog);
            BuildUi();
            LoadModels();
            Shown += (s, e) => CheckHealth();
        }

        private void BuildUi()
        {
            Text = "Asclepius";
            Size = new Size(920, 620);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(820, 540);

            var title = new Label
            {
                Text = "Asclepius",
                Font = new Font("Segoe UI", 18, FontStyle.Bold),
                Location = new Point(18, 14),
                Size = new Size(260, 36)
            };
            Controls.Add(title);

            _health.Text = "Health: checking...";
            _health.Location = new Point(300, 22);
            _health.Size = new Size(560, 24);
            Controls.Add(_health);

            _models.Location = new Point(18, 70);
            _models.Size = new Size(850, 28);
            _models.DropDownStyle = ComboBoxStyle.DropDownList;
            _models.SelectedIndexChanged += (s, e) => UpdateDetails();
            Controls.Add(_models);

            _details.Location = new Point(18, 108);
            _details.Size = new Size(850, 78);
            _details.Text = "Model details";
            Controls.Add(_details);

            AddButton("Launch Codex", 18, 200, (s, e) => LaunchCodex());
            AddButton("Start / Health", 150, 200, (s, e) => StartServicesThenHealth());
            AddButton("Refresh Models", 282, 200, (s, e) => RefreshModels());
            AddButton("Nous OAuth", 414, 200, (s, e) => OpenVisible(_config.OAuthScript));
            AddButton("Hermes Golden Update", 546, 200, (s, e) => ConfirmAndOpenUpdate());
            AddButton("Hermes Sessions", 18, 244, (s, e) => OpenVisible(_config.SessionsScript));
            AddButton("Legacy Picker", 166, 244, (s, e) => OpenVisible(_config.PickerScript));

            var boundary = new Label
            {
                Location = new Point(18, 292),
                Size = new Size(850, 42),
                Text = "Codex updates stay inside Codex. Hermes updates run through Hermes Golden Update. Hermes tools run in WSL under the mapped workspace."
            };
            Controls.Add(boundary);

            _log.Location = new Point(18, 346);
            _log.Size = new Size(850, 190);
            _log.Multiline = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.ReadOnly = true;
            Controls.Add(_log);
        }

        private Button AddButton(string text, int x, int y, EventHandler handler)
        {
            var button = new Button { Text = text, Location = new Point(x, y), Size = new Size(120, 34) };
            if (text.Length > 16) button.Size = new Size(170, 34);
            button.Click += handler;
            Controls.Add(button);
            return button;
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
                    Display = "Nous | deepseek/deepseek-v4-flash",
                    Provider = "nous",
                    ProviderDisplay = "Nous",
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

        private void LaunchCodex()
        {
            var model = SelectedModel();
            if (model == null) return;
            if (!ConfirmModel(model)) return;
            RunBackground("Launching Codex...", () =>
            {
                _runner.RunPowerShell(_config.LaunchCodexScript, new[] { "-Model", model.Slug, "-Workspace", _config.Workspace }, 60000);
                AppendLog("Launch requested for " + model.Slug);
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
                CheckHealth();
            });
        }

        private void RefreshModels()
        {
            RunBackground("Refreshing model catalog...", () =>
            {
                _runner.RunPowerShell(_config.StartServicesScript, new[] { "-NoCatalogRefresh" }, 60000);
                _runner.RunPowerShell(_config.RefreshCatalogScript, new string[0], 180000);
                BeginInvoke(new Action(LoadModels));
            });
        }

        private void CheckHealth()
        {
            try
            {
                using (var client = new WebClient())
                {
                    string json = client.DownloadString(_config.HealthUrl);
                    _health.Text = "Health: ok";
                    AppendLog("Health: " + SecretFilter.Redact(json));
                }
            }
            catch (Exception ex)
            {
                _health.Text = "Health: needs start";
                AppendLog("Health check failed: " + ex.Message);
            }
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
            string line = DateTime.Now.ToString("HH:mm:ss") + " " + SecretFilter.Redact(text ?? "");
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), text);
                return;
            }
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
    }
}
