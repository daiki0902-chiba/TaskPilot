// Dedicated acceptance host. It cannot start the normal application.
// Build substitutes immutable trust values; an empty policy is deliberately unusable.
using System;
using System.IO;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

namespace TaskPilot.Acceptance
{
    public static class Launcher
    {
        private const string TrustHash = "@@TRUST_SHA256@@";
        private const string PublisherList = "@@TRUST_THUMBPRINTS@@";
        public static bool IsDedicatedLauncher { get; private set; }
        public static string PackageRoot { get; private set; }
        public static string TrustConfigurationSha256 { get { return TrustHash; } }
        public static string[] TrustedPublisherThumbprints { get { return PublisherList.Length == 0 ? new string[0] : PublisherList.Split(';'); } }

        [STAThread]
        public static int Main(string[] arguments)
        {
            string mode = "GUI";
            if (arguments.Length == 1 && arguments[0] == "--preflight") mode = "PREFLIGHT";
            else if (arguments.Length == 1 && arguments[0] == "--collect-logs") mode = "DIAGNOSTICS";
            else if (arguments.Length != 0) return Stop("TP-ACCEPTANCE-ARGUMENTS", false);
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || !Environment.Is64BitProcess)
                return Stop("TP-ACCEPTANCE-PLATFORM", mode == "GUI");
            // Do not resolve KnownFolders, inspect TaskPilot state, load external
            // code, or create a runspace when no signing authority is configured.
            if (TrustedPublisherThumbprints.Length == 0 || TrustHash.Length != 64)
                return Stop("TP-ACCEPTANCE-PUBLISHER-NOT-CONFIGURED", mode == "GUI");
            PackageRoot = Path.GetDirectoryName(typeof(Launcher).Assembly.Location);
            IsDedicatedLauncher = true;
            try
            {
                using (PackageLease lease = PackageLease.Open(PackageRoot))
                {
                    // PackageLease rejects links before content access and holds
                    // all relevant file/directory handles throughout the session.
                    string[] bootstrap = { "TaskPilot.Acceptance.exe", "acceptance/TaskPilot.Acceptance.Security.ps1", "tools/Test-TaskPilotDesktopAcceptance.ps1" };
                    Environment.SetEnvironmentVariable("PSModuleAnalysisCachePath", "NUL", EnvironmentVariableTarget.Process);
                    // Never resolve a bootstrap cmdlet through inherited user
                    // modules. SystemDirectory is provided by the OS, not PATH,
                    // PSHOME or a caller-controlled environment variable.
                    Environment.SetEnvironmentVariable("PSModulePath", Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\Modules"), EnvironmentVariableTarget.Process);
                    using (Runspace runspace = RunspaceFactory.CreateRunspace())
                    {
                        runspace.ApartmentState = ApartmentState.STA;
                        runspace.ThreadOptions = PSThreadOptions.ReuseThread;
                        runspace.Open();
                        foreach (string relative in bootstrap) VerifyBootstrapSignature(runspace, lease, relative);
                        object readiness = InvokeFile(runspace, lease.FullPath("tools/Test-TaskPilotDesktopAcceptance.ps1"), PackageRoot);
                        PSObject report = PSObject.AsPSObject(readiness);
                        string status = report.Properties["Status"] == null ? "BLOCKED" : Convert.ToString(report.Properties["Status"].Value);
                        if (mode == "PREFLIGHT")
                        {
                            Console.WriteLine(status == "READY_FOR_DESKTOP_ACCEPTANCE" ? "{\"Status\":\"READY_FOR_DESKTOP_ACCEPTANCE\"}" : "{\"Status\":\"BLOCKED\",\"Code\":\"TP-ACCEPTANCE-PREFLIGHT\"}");
                            return status == "READY_FOR_DESKTOP_ACCEPTANCE" ? 0 : 2;
                        }
                        if (status != "READY_FOR_DESKTOP_ACCEPTANCE") return Stop("TP-ACCEPTANCE-PREFLIGHT", mode == "GUI");
                        string entry = mode == "DIAGNOSTICS" ? "tools/Collect-TaskPilotDesktopAcceptanceLogs.ps1" : "acceptance/TaskPilot.Acceptance.ps1";
                        VerifyBootstrapSignature(runspace, lease, entry);
                        InvokeFile(runspace, lease.FullPath(entry), mode == "DIAGNOSTICS" ? PackageRoot : null);
                    }
                }
                return 0;
            }
            catch
            {
                // Never emit raw exceptions: provider paths, task text and user
                // names can occur in messages. No fallback to the normal entry.
                return Stop("TP-ACCEPTANCE-AUTHORIZATION-OR-RUNTIME", mode == "GUI");
            }
            finally { IsDedicatedLauncher = false; }
        }

        private static void VerifyBootstrapSignature(Runspace runspace, PackageLease lease, string relative)
        {
            lease.AssertPinned(relative);
            if (lease.HasInternetZone(relative)) throw new InvalidOperationException("TP-ACCEPTANCE-DOWNLOAD-ORIGIN");
            using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = runspace;
                shell.AddCommand("Microsoft.PowerShell.Security\\Get-AuthenticodeSignature").AddParameter("LiteralPath", lease.FullPath(relative));
                Collection<PSObject> results = shell.Invoke();
                if (shell.HadErrors || results.Count != 1 || Convert.ToString(results[0].Properties["Status"].Value) != "Valid")
                    throw new InvalidOperationException("TP-ACCEPTANCE-SIGNATURE");
                System.Security.Cryptography.X509Certificates.X509Certificate2 signer = results[0].Properties["SignerCertificate"].Value as System.Security.Cryptography.X509Certificates.X509Certificate2;
                bool trusted = false;
                if (signer != null) foreach (string pin in TrustedPublisherThumbprints) if (String.Equals(pin, signer.Thumbprint, StringComparison.OrdinalIgnoreCase)) trusted = true;
                if (!trusted) throw new InvalidOperationException("TP-ACCEPTANCE-PUBLISHER");
            }
        }

        private static object InvokeFile(Runspace runspace, string path, string packageRoot)
        {
            using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = runspace;
                shell.AddCommand(path);
                if (packageRoot != null) shell.AddParameter("PackageRoot", packageRoot);
                Collection<PSObject> result = shell.Invoke();
                if (shell.HadErrors) throw new InvalidOperationException("TP-ACCEPTANCE-COMMAND");
                if (result.Count == 0) return null;
                return result[result.Count - 1];
            }
        }

        private static int Stop(string code, bool showWindow)
        {
            Console.WriteLine("{\"Status\":\"BLOCKED\",\"Code\":\"" + code + "\"}");
            if (showWindow) MessageBox.Show("受入専用ビルドの起動条件を満たしていません。\r\n" + code + "\r\n既存データは開いていません。", "TaskPilot [ACCEPTANCE ONLY]", MessageBoxButtons.OK, MessageBoxIcon.Stop);
            return 2;
        }
    }
}
