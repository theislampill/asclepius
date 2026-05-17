using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class AsclepiusLauncher
{
    private const string ProviderLauncherScript = "Launch-AsclepiusProviderLauncher.ps1";

    [STAThread]
    private static int Main(string[] args)
    {
        string exePath = Application.ExecutablePath;
        string root = Path.GetDirectoryName(exePath) ?? AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(root, ProviderLauncherScript);

        bool selfTest = args.Length == 1 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase);
        if (!File.Exists(scriptPath))
        {
            if (!selfTest)
            {
                MessageBox.Show(
                    "Asclepius could not find " + ProviderLauncherScript + " beside Asclepius.exe.",
                    "Asclepius",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            return 2;
        }

        if (selfTest)
        {
            return 0;
        }

        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(powershell))
        {
            powershell = "powershell.exe";
        }

        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " + Quote(scriptPath) + ExtraArguments(args),
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        Process.Start(startInfo);
        return 0;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string ExtraArguments(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return string.Empty;
        }

        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            builder.Append(' ');
            builder.Append(Quote(args[i]));
        }
        return builder.ToString();
    }
}
