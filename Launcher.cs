using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Community Startup Manager")]
[assembly: AssemblyDescription("A reversible Windows startup manager")]
[assembly: AssemblyVersion("0.3.0.0")]
[assembly: AssemblyFileVersion("0.3.0.0")]

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool diagnostic = false;
        string scriptArgument = "";
        string logPath = null;

        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--self-test")
            {
                scriptArgument = " -SelfTest";
                diagnostic = true;
            }
            else if (args[i] == "--ui-smoke-test")
            {
                scriptArgument = " -UiSmokeTest";
                diagnostic = true;
            }
            else if (args[i] == "--demo-screenshot" && i + 1 < args.Length)
            {
                scriptArgument = " -UiScreenshotPath " + Quote(args[++i]);
                diagnostic = true;
            }
            else if (args[i] == "--log" && i + 1 < args.Length)
            {
                logPath = args[++i];
            }
            else
            {
                MessageBox.Show("Unknown option: " + args[i], "Community Startup Manager");
                return 2;
            }
        }

        string tempRoot = Path.GetFullPath(Path.GetTempPath());
        string tempDir = Path.Combine(tempRoot, "CommunityStartupManager-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(tempDir);
            string scriptPath = Path.Combine(tempDir, "StartupManager.ps1");
            Extract("CommunityStartupManager.StartupManager.ps1", scriptPath);
            Extract("CommunityStartupManager.App.xaml", Path.Combine(tempDir, "App.xaml"));

            string windir = Environment.GetEnvironmentVariable("WINDIR");
            if (String.IsNullOrEmpty(windir)) { throw new InvalidOperationException("Windows directory not found."); }
            string powershell = Path.Combine(windir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershell)) { throw new FileNotFoundException("Windows PowerShell 5.1 is required.", powershell); }

            var start = new ProcessStartInfo();
            start.FileName = powershell;
            start.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -File " + Quote(scriptPath) + scriptArgument;
            start.WorkingDirectory = tempDir;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;

            var output = new StringBuilder();
            var error = new StringBuilder();
            using (var process = new Process())
            {
                process.StartInfo = start;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) { output.AppendLine(e.Data); } };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) { error.AppendLine(e.Data); } };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();

                string report = output.ToString() + error.ToString();
                if (!String.IsNullOrEmpty(logPath)) { File.WriteAllText(logPath, report, Encoding.UTF8); }
                if (process.ExitCode != 0 && !diagnostic)
                {
                    MessageBox.Show(report.Length > 0 ? report : "The app exited with code " + process.ExitCode + ".",
                        "Community Startup Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            if (!String.IsNullOrEmpty(logPath)) { File.WriteAllText(logPath, ex.ToString(), Encoding.UTF8); }
            if (!diagnostic) { MessageBox.Show(ex.Message, "Community Startup Manager", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            return 1;
        }
        finally
        {
            string full = Path.GetFullPath(tempDir);
            string prefix = tempRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
                Path.GetFileName(full).StartsWith("CommunityStartupManager-", StringComparison.Ordinal))
            {
                try { Directory.Delete(full, true); } catch { /* Windows may still be releasing files. */ }
            }
        }
    }

    private static void Extract(string resourceName, string destination)
    {
        using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (input == null) { throw new InvalidOperationException("Embedded app resource is missing: " + resourceName); }
            using (var output = File.Create(destination)) { input.CopyTo(output); }
        }
    }

    private static string Quote(string value)
    {
        if (value.IndexOf('"') >= 0) { throw new ArgumentException("A path contains a quotation mark."); }
        return "\"" + value + "\"";
    }
}
