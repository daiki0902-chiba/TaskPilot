// Separate development-only entry. This build never activates another flavor.
// A trusted local parent/provisioning protocol is intentionally not simulated.
using System;
using System.Runtime.InteropServices;

namespace TaskPilot.LocalValidation
{
    public static class Host
    {
        public static bool IsLocalValidationHost { get { return false; } }
        public static bool HasProtectedParent { get { return false; } }
        public static string PackageRoot { get { return null; } }
        public static bool ProtectedParentProtocolImplemented { get { return false; } }

        public static LocalSession OpenCurrentSession()
        {
            // A receipt's signature cannot establish a live parent file lease
            // or prove the VM has no host data mappings. No approval flag,
            // environment variable, certificate-store change, or caller object
            // substitutes for these missing mechanisms.
            throw new InvalidOperationException("TP-LOCAL-PROTECTED-PARENT-PROTOCOL-REQUIRED");
        }

        [STAThread]
        public static int Main(string[] arguments)
        {
            bool headless = arguments.Length == 1 &&
                (arguments[0] == "--preflight" || arguments[0] == "--collect-logs");
            string code = arguments.Length == 0 || headless
                ? "TP-LOCAL-PROTECTED-PARENT-PROTOCOL-REQUIRED"
                : "TP-LOCAL-ARGUMENTS-REJECTED";
            // Deliberately before KnownFolder resolution, external scripts,
            // package reads, logs, or creation of any persistent state.
            Console.WriteLine("{\"Status\":\"NOT_READY\",\"Code\":\"" + code + "\",\"CanLaunch\":false}");
            if (arguments.Length == 0 && Environment.OSVersion.Platform == PlatformID.Win32NT)
                MessageBoxW(IntPtr.Zero, "Local developer validation is NOT_READY. No TaskPilot user data was opened.\r\n" + code,
                    "TaskPilot [LOCAL VALIDATION ONLY]", 0x10);
            return 2;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr parent, string text, string title, uint type);
    }

    public sealed class LocalSession : IDisposable
    {
        private LocalSession() { }
        public string Purpose { get { return "LocalDeveloperValidationSyntheticOnly"; } }
        public string Version { get { return "0.4.0.2"; } }
        public string EnvironmentId { get { return null; } }
        public object PackageLease { get { return null; } }
        public void Dispose() { }
    }
}
