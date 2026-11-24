// Synthetic CI-only LPAC feasibility experiment. C# 5 / .NET Framework.
// No TaskPilot application, actual user store, or real personal file is opened.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;

internal static class LpacProbe
{
    private const uint ExtendedStartupInfoPresent = 0x00080000, CreateSuspended = 0x4, CreateNoWindow = 0x08000000, CreateUnicodeEnvironment = 0x400;
    private const int SecurityCapabilitiesAttribute = 0x20009, AllApplicationPackagesPolicyAttribute = 0x2000f;
    private const uint AllApplicationPackagesOptOut = 0x1, TokenQuery = 0xa;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static readonly List<FileStream> PinnedPayload = new List<FileStream>();

    [StructLayout(LayoutKind.Sequential)] private struct StartupInfo
    {
        public int cb; public IntPtr lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr AttributeList; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct GenericMapping { public uint Read, Write, Execute, All; }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityCapabilities { public IntPtr AppContainerSid, Capabilities; public uint CapabilityCount, Reserved; }
    [StructLayout(LayoutKind.Sequential)] private struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation; public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("userenv.dll", CharSet=CharSet.Unicode)] private static extern int CreateAppContainerProfile(string name, string displayName, string description, IntPtr capabilities, uint capabilityCount, out IntPtr sid);
    [DllImport("userenv.dll", CharSet=CharSet.Unicode)] private static extern int DeleteAppContainerProfile(string name);
    [DllImport("userenv.dll", CharSet=CharSet.Unicode)] private static extern int GetAppContainerFolderPath(string sid, out IntPtr folder);
    [DllImport("advapi32.dll")] private static extern IntPtr FreeSid(IntPtr sid);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetSecurityDescriptorSacl(IntPtr descriptor, out bool present, out IntPtr sacl, out bool defaulted);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] private static extern uint SetNamedSecurityInfo(string path, int type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string currentDirectory, ref StartupInfoEx startupInfo, out ProcessInformation processInformation);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr buffer, int length, out int returned);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr duplicate);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AccessCheck(IntPtr descriptor, IntPtr token, uint desiredAccess, ref GenericMapping mapping, IntPtr privileges, ref uint privilegesLength, out uint grantedAccess, out bool accessStatus);
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationToken(IntPtr token, int informationClass, IntPtr buffer, int length, out int returned);
    [DllImport("kernelbase.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool DeriveCapabilitySidsFromName(string name, out IntPtr groups, out uint groupCount, out IntPtr capabilities, out uint capabilityCount);
    [DllImport("amsi.dll", CharSet=CharSet.Unicode)] private static extern int AmsiInitialize(string name, out IntPtr context);
    [DllImport("amsi.dll", CharSet=CharSet.Unicode)] private static extern int AmsiScanString(IntPtr context, string content, string name, IntPtr session, out uint result);
    [DllImport("amsi.dll")] private static extern void AmsiUninitialize(IntPtr context);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool CreateSymbolicLink(string link, string target, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool DeleteFile(string file);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool MoveFileEx(string source, string destination, uint flags);

    private static Dictionary<string, object> Record() { return new Dictionary<string, object>(); }
    private static string SafeError(Exception e)
    {
        Win32Exception w = e as Win32Exception;
        return e.GetType().Name + (w == null ? ":0x" + e.HResult.ToString("x8", CultureInfo.InvariantCulture) : ":Win32=" + w.NativeErrorCode.ToString(CultureInfo.InvariantCulture));
    }
    private static object SafeErrorChain(Exception error)
    {
        List<object> chain = new List<object>();
        for (int depth = 0; error != null && depth < 8; depth++, error = error.InnerException)
        {
            Dictionary<string, object> item = Record(); item["Error"] = SafeError(error);
            TypeInitializationException initializer = error as TypeInitializationException;
            if (initializer != null) item["InitializerType"] = initializer.TypeName;
            if (error.TargetSite != null) item["Method"] = (error.TargetSite.DeclaringType == null ? "" : error.TargetSite.DeclaringType.FullName + ".") + error.TargetSite.Name;
            // No Message, stack trace, input, file path or registry value.
            chain.Add(item);
        }
        return chain;
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static void WriteJson(string file, object value) { File.WriteAllText(file, Json.Serialize(value), new UTF8Encoding(false, true)); }
    private static void SetAcl(string path, SecurityIdentifier appSid, FileSystemRights? appRights, int broad)
    {
        DirectorySecurity acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
        SecurityIdentifier owner = WindowsIdentity.GetCurrent().User; acl.SetOwner(owner);
        InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (SecurityIdentifier sid in new SecurityIdentifier[] { owner, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        if (appSid != null && appRights.HasValue) acl.AddAccessRule(new FileSystemAccessRule(appSid, appRights.Value, inheritance, PropagationFlags.None, AccessControlType.Allow));
        if ((broad & 2) != 0)
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        if ((broad & 1) != 0)
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-15-2-1"), FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        Directory.SetAccessControl(path, acl);
    }
    private static void SetPrivateLowIntegrityLabel(string path)
    {
        IntPtr descriptor; uint size;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor("S:(ML;OICI;NW;;;LW)", 1, out descriptor, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            bool present, defaulted; IntPtr sacl;
            if (!GetSecurityDescriptorSacl(descriptor, out present, out sacl, out defaulted) || !present) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint error = SetNamedSecurityInfo(path, 1, 0x10, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, sacl);
            if (error != 0) throw new Win32Exception((int)error);
        }
        finally { LocalFree(descriptor); }
    }
    private static IntPtr ChildEnvironment(string data, int profileEnvironmentVariant, out bool processPolicyPreserved)
    {
        SortedDictionary<string, string> values = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string key in new string[] { "SystemRoot", "WINDIR", "SystemDrive", "ComSpec" })
        { string value = Environment.GetEnvironmentVariable(key); if (!String.IsNullOrEmpty(value)) values[key] = value; }
        string windows = Environment.GetEnvironmentVariable("SystemRoot");
        Check(!String.IsNullOrEmpty(windows), "SystemRoot is required for the synthetic host.");
        values["PATH"] = Path.Combine(windows, "System32");
        values["PSModulePath"] = Path.Combine(windows, "System32\\WindowsPowerShell\\v1.0\\Modules");
        values["TEMP"] = Path.Combine(data, "Temp"); values["TMP"] = values["TEMP"]; values["PSModuleAnalysisCachePath"] = "NUL";
        // Diagnose ERROR_ENVVAR_NOT_FOUND without inheriting personal paths or
        // credentials. Every added path is a fresh synthetic directory.
        string privateProfile = Path.Combine(data, "Profile");
        if (profileEnvironmentVariant >= 1) values["USERPROFILE"] = privateProfile;
        if (profileEnvironmentVariant >= 2)
        {
            values["LOCALAPPDATA"] = Path.Combine(privateProfile, "AppData\\Local");
            values["APPDATA"] = Path.Combine(privateProfile, "AppData\\Roaming");
        }
        string policy = Environment.GetEnvironmentVariable("PSExecutionPolicyPreference");
        processPolicyPreserved = policy != null;
        if (policy != null) values["PSExecutionPolicyPreference"] = policy;
        StringBuilder text = new StringBuilder();
        foreach (KeyValuePair<string, string> value in values) text.Append(value.Key).Append('=').Append(value.Value).Append('\0');
        text.Append('\0');
        return Marshal.StringToHGlobalUni(text.ToString());
    }
    private static int TokenInt(IntPtr token, int informationClass)
    {
        IntPtr buffer = Marshal.AllocHGlobal(4);
        try { int returned; if (!GetTokenInformation(token, informationClass, buffer, 4, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error()); return Marshal.ReadInt32(buffer); }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static string TokenUser(IntPtr token)
    {
        int size; GetTokenInformation(token, 1, IntPtr.Zero, 0, out size);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try { if (!GetTokenInformation(token, 1, buffer, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error()); return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value; }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static string TokenAppSid(IntPtr token)
    {
        int size; GetTokenInformation(token, 31, IntPtr.Zero, 0, out size);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try { if (!GetTokenInformation(token, 31, buffer, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error()); return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value; }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static int TokenCapabilitiesCount(IntPtr token)
    {
        int size; GetTokenInformation(token, 30, IntPtr.Zero, 0, out size);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try { if (!GetTokenInformation(token, 30, buffer, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error()); return Marshal.ReadInt32(buffer); }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static uint LpacAccessMask(IntPtr token)
    {
        // Kernel access-check semantics, also used by Chromium's LPAC tests:
        // the ordinary user gets bits 1|2, AAP gets bit 1, ARAP gets bit 2.
        // LPAC must receive exactly bit 2, not the AAP bit. No actual file or
        // registry ACL is changed by this in-memory descriptor.
        IntPtr descriptor = IntPtr.Zero, impersonation = IntPtr.Zero, privileges = IntPtr.Zero;
        try
        {
            uint size;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor("O:SYG:SYD:(A;;0x3;;;WD)(A;;0x1;;;S-1-15-2-1)(A;;0x2;;;S-1-15-2-2)", 1, out descriptor, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!DuplicateTokenEx(token, 0x8, IntPtr.Zero, 2, 2, out impersonation)) throw new Win32Exception(Marshal.GetLastWin32Error());
            GenericMapping mapping = new GenericMapping(); uint granted, length = 0; bool allowed;
            bool checkedWithoutBuffer = AccessCheck(descriptor, impersonation, 0x02000000, ref mapping, IntPtr.Zero, ref length, out granted, out allowed);
            if (!checkedWithoutBuffer)
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 122 || length == 0 || length > 65536) throw new Win32Exception(error);
                privileges = Marshal.AllocHGlobal((int)length);
                if (!AccessCheck(descriptor, impersonation, 0x02000000, ref mapping, privileges, ref length, out granted, out allowed)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            Check(allowed, "LPAC in-memory access check did not grant its synthetic ARAP right.");
            return granted;
        }
        finally
        {
            if (privileges != IntPtr.Zero) Marshal.FreeHGlobal(privileges);
            if (impersonation != IntPtr.Zero) CloseHandle(impersonation);
            if (descriptor != IntPtr.Zero) LocalFree(descriptor);
        }
    }
    private static SecurityIdentifier KnownCapabilitySid(string name)
    {
        IntPtr groups = IntPtr.Zero, capabilities = IntPtr.Zero; uint groupCount = 0, capabilityCount = 0;
        try
        {
            if (!DeriveCapabilitySidsFromName(name, out groups, out groupCount, out capabilities, out capabilityCount)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Check(capabilityCount == 1, "The selected synthetic capability must resolve to one SID.");
            return new SecurityIdentifier(Marshal.ReadIntPtr(capabilities));
        }
        finally
        {
            if (groups != IntPtr.Zero) { for (uint i = 0; i < groupCount; i++) LocalFree(Marshal.ReadIntPtr(groups, checked((int)i * IntPtr.Size))); LocalFree(groups); }
            if (capabilities != IntPtr.Zero) { for (uint i = 0; i < capabilityCount; i++) LocalFree(Marshal.ReadIntPtr(capabilities, checked((int)i * IntPtr.Size))); LocalFree(capabilities); }
        }
    }
    private static bool CapabilitiesMatch(IntPtr token, bool registryRead, bool instrumentation = false)
    {
        int count = TokenCapabilitiesCount(token);
        if (!registryRead) return count == 0;
        if (count != (instrumentation ? 2 : 1)) return false;
        int length; GetTokenInformation(token, 30, IntPtr.Zero, 0, out length);
        IntPtr value = Marshal.AllocHGlobal(length);
        try
        {
            if (!GetTokenInformation(token, 30, value, length, out length)) throw new Win32Exception(Marshal.GetLastWin32Error());
            HashSet<string> expected = new HashSet<string>(StringComparer.Ordinal);
            expected.Add(KnownCapabilitySid("registryRead").Value);
            if (instrumentation) expected.Add(KnownCapabilitySid("lpacInstrumentation").Value);
            for (int i = 0; i < count; i++)
            {
                int offset = (IntPtr.Size == 8 ? 8 : 4) + i * Marshal.SizeOf(typeof(SidAndAttributes));
                IntPtr sid = Marshal.ReadIntPtr(value, offset); uint attributes = unchecked((uint)Marshal.ReadInt32(value, offset + IntPtr.Size));
                if ((attributes & 4) == 0 || (attributes & 0x10) != 0 || !expected.Remove(new SecurityIdentifier(sid).Value)) return false;
            }
            return expected.Count == 0;
        }
        finally { Marshal.FreeHGlobal(value); }
    }
    private static void RecordLpacQueryDiagnostic(IntPtr token, Dictionary<string, object> report)
    {
        try { report["Win32TokenClass46Value"] = TokenInt(token, 46); }
        catch (Win32Exception e) { report["Win32TokenClass46Error"] = e.NativeErrorCode; }
        IntPtr value = Marshal.AllocHGlobal(4);
        try
        {
            int returned; int status = NtQueryInformationToken(token, 46, value, 4, out returned);
            report["NativeTokenClass46Status"] = "0x" + unchecked((uint)status).ToString("x8", CultureInfo.InvariantCulture);
            report["NativeTokenClass46ReturnedLength"] = returned;
            if (status >= 0) report["NativeTokenClass46Value"] = Marshal.ReadInt32(value);
        }
        finally { Marshal.FreeHGlobal(value); }
    }
    private static bool DeniedRead(string file)
    {
        try { using (FileStream stream = File.Open(file, FileMode.Open, FileAccess.Read, FileShare.Read)) { stream.ReadByte(); } return false; }
        catch (UnauthorizedAccessException) { return true; }
    }
    private static bool DeniedWrite(string file)
    {
        try { using (FileStream stream = File.Open(file, FileMode.Open, FileAccess.Write, FileShare.Read)) { stream.WriteByte(0x7f); stream.Flush(true); } return false; }
        catch (UnauthorizedAccessException) { return true; }
    }
    private static bool DeniedDelete(string file)
    {
        if (DeleteFile(file)) return false;
        int error = Marshal.GetLastWin32Error(); if (error == 5) return true;
        throw new Win32Exception(error);
    }
    private static bool DeniedRename(string file)
    {
        // File.Move first uses an existence check that masks access denial as
        // FileNotFoundException. Ask Windows for the actual operation result.
        if (MoveFileEx(file, file + ".renamed", 0)) return false;
        int error = Marshal.GetLastWin32Error(); if (error == 5) return true;
        throw new Win32Exception(error);
    }
    private static bool DeniedCreate(string directory)
    {
        try { using (FileStream stream = File.Open(Path.Combine(directory, "unexpected-new.txt"), FileMode.CreateNew, FileAccess.Write, FileShare.None)) { stream.WriteByte(1); } return false; }
        catch (UnauthorizedAccessException) { return true; }
    }
    private static void HostProbe(string root, Dictionary<string, object> result)
    {
        using (Runspace space = RunspaceFactory.CreateRunspace(new SyntheticHost()))
        {
            space.Open();
            using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = space;
                string payload = Path.Combine(root, "payload").Replace("'", "''");
                shell.AddScript("$ErrorActionPreference='Stop'; . '" + payload + "\\external.ps1'; Import-Module '" + payload + "\\synthetic.psm1' -ErrorAction Stop; [bool]($script:TaskPilotSyntheticExternalFlag -and (Get-TaskPilotSyntheticValue) -ceq 'SYNTHETIC_ONLY')");
                System.Collections.ObjectModel.Collection<PSObject> values = shell.Invoke();
                result["PowerShellExternalScriptAndModulePassed"] = values.Count == 1 && values[0].BaseObject is bool && (bool)values[0].BaseObject && shell.Streams.Error.Count == 0;
                result["PowerShellErrors"] = shell.Streams.Error.Count;
            }
        }
    }
    private static void AmsiProbe(Dictionary<string, object> result)
    {
        IntPtr context = IntPtr.Zero; result["AmsiSampleIsBenign"] = true;
        result["AmsiDetectionOfMalwareVerified"] = false;
        try
        {
            int initialized = AmsiInitialize("TaskPilotSyntheticConfinementProbe", out context);
            result["AmsiInitializeHresult"] = "0x" + unchecked((uint)initialized).ToString("x8", CultureInfo.InvariantCulture);
            result["AmsiInitialized"] = initialized >= 0 && context != IntPtr.Zero;
            if (initialized >= 0 && context != IntPtr.Zero)
            {
                uint scanResult; int status = AmsiScanString(context, "TaskPilot synthetic diagnostic only", "synthetic-only", IntPtr.Zero, out scanResult);
                result["AmsiScanHresult"] = "0x" + unchecked((uint)status).ToString("x8", CultureInfo.InvariantCulture);
                result["AmsiScanResult"] = scanResult; result["AmsiBenignScanCallSucceeded"] = status >= 0;
            }
        }
        finally { if (context != IntPtr.Zero) AmsiUninitialize(context); }
    }
    private static void FormsProbe(Dictionary<string, object> result)
    {
        System.Windows.Forms.Application.EnableVisualStyles();
        using (System.Windows.Forms.Form form = new System.Windows.Forms.Form())
        using (System.Windows.Forms.Button button = new System.Windows.Forms.Button())
        { button.Text = "SYNTHETIC_ONLY"; form.Controls.Add(button); result["WinFormsConstructDisposePassed"] = form.Controls.Count == 1; }
    }
    private sealed class SyntheticHost : PSHost
    {
        private readonly Guid id = Guid.NewGuid();
        public override Guid InstanceId { get { return id; } }
        public override string Name { get { return "TaskPilotSyntheticHost"; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override PSHostUserInterface UI { get { return null; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
        public override void SetShouldExit(int exitCode) { }
        public override void EnterNestedPrompt() { throw new NotSupportedException(); }
        public override void ExitNestedPrompt() { throw new NotSupportedException(); }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
    }
    private static int Child(string root)
    {
        Dictionary<string, object> result = Record(); result["Kind"] = "synthetic_child";
        result["Status"] = "NOT_READY"; result["ApplicationLaunched"] = false; result["ApplicationRunCalled"] = false;
        result["RealPersonalPathsOpenedByProbe"] = false; result["OsPolicyOrTrustChanged"] = false;
        bool securityFailure = false, tokenVerified = false;
        try
        {
            IntPtr token; if (!OpenProcessToken(Process.GetCurrentProcess().Handle, TokenQuery, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                result["IsAppContainer"] = TokenInt(token, 29) != 0;
                uint mask = LpacAccessMask(token);
                result["KernelLpacAccessMask"] = mask;
                result["LpacVerificationMethod"] = "AccessCheck: AAP bit absent; ARAP bit present";
                result["IsLessPrivilegedAppContainer"] = mask == 2;
                result["CapabilityCount"] = TokenCapabilitiesCount(token);
                result["CapabilitiesMatchBoundedExperiment"] = CapabilitiesMatch(token, (int)result["CapabilityCount"] > 0, (int)result["CapabilityCount"] == 2);
            }
            finally { CloseHandle(token); }
            Check((bool)result["IsAppContainer"] && (bool)result["IsLessPrivilegedAppContainer"] && (bool)result["CapabilitiesMatchBoundedExperiment"], "Kernel token does not satisfy LPAC experiment conditions.");
            Check(String.Equals(Process.GetCurrentProcess().MainModule.FileName, Path.Combine(Path.Combine(root, "payload"), "LpacProbe.exe"), StringComparison.OrdinalIgnoreCase), "The child root must match its payload image location.");
            tokenVerified = true;
            string data = Path.Combine(root, "private-data");
            string temp = Path.Combine(data, "Temp");
            Environment.SetEnvironmentVariable("TEMP", temp); Environment.SetEnvironmentVariable("TMP", temp);
            Environment.SetEnvironmentVariable("PSModuleAnalysisCachePath", "NUL");
            string own = Path.Combine(data, "private-canary.txt");
            File.WriteAllText(own, "SYNTHETIC_ONLY", new UTF8Encoding(false));
            result["PrivateReadWritePassed"] = File.ReadAllText(own) == "SYNTHETIC_ONLY";
            Check((bool)result["PrivateReadWritePassed"], "Private read/write control failed.");
            Dictionary<string, object> plan = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Path.Combine(root, "payload"), "ProbePlan.json")));
            result["KnownFolderPathsCaptured"] = false;
            try
            {
                string known = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string expected = plan.ContainsKey("CreatedAppContainerProfilePath") ? (string)plan["CreatedAppContainerProfilePath"] : null;
                result["KnownLocalAppDataAvailable"] = !String.IsNullOrEmpty(known);
                result["KnownLocalAppDataWithinCreatedAppContainerProfile"] = !String.IsNullOrEmpty(known) && !String.IsNullOrEmpty(expected) && (String.Equals(known, expected, StringComparison.OrdinalIgnoreCase) || known.StartsWith(expected.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
                result["TempWithinOwnFixture"] = Path.GetTempPath().StartsWith(data.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception e) { result["KnownFolderDiagnosticFailure"] = SafeError(e); }
            foreach (string fixture in new string[] { "normal-default", "normal-all-app-packages", "normal-everyone", "other-private" })
            {
                result["CurrentStage"] = fixture + ":read-write";
                string path = Path.Combine(Path.Combine(root, fixture), "canary.txt");
                bool deniedRead = DeniedRead(path), deniedWrite = DeniedWrite(path);
                result[fixture + "ReadDenied"] = deniedRead; result[fixture + "WriteDenied"] = deniedWrite;
                string folder = Path.GetDirectoryName(path);
                result["CurrentStage"] = fixture + ":delete";
                bool deniedDelete = DeniedDelete(Path.Combine(folder, "delete-canary.txt"));
                result["CurrentStage"] = fixture + ":rename";
                bool deniedRename = DeniedRename(Path.Combine(folder, "rename-canary.txt"));
                result["CurrentStage"] = fixture + ":create";
                bool deniedCreate = DeniedCreate(folder);
                result[fixture + "DeleteDenied"] = deniedDelete; result[fixture + "RenameDenied"] = deniedRename; result[fixture + "CreateDenied"] = deniedCreate;
                if (!deniedRead || !deniedWrite || !deniedDelete || !deniedRename || !deniedCreate) securityFailure = true;
            }
            string link = Path.Combine(data, "escape-link.txt");
            if ((bool)plan["SyntheticFileSymlinkCreated"]) { bool deniedRead = DeniedRead(link), deniedWrite = DeniedWrite(link); result["LinkEscapeReadDenied"] = deniedRead; result["LinkEscapeWriteDenied"] = deniedWrite; if (!deniedRead || !deniedWrite) securityFailure = true; }
            else result["LinkEscapeChildObservation"] = "NOT_AVAILABLE";
            result["CurrentStage"] = "PowerShell";
            try { AmsiProbe(result); } catch (Exception e) { result["AmsiDiagnosticFailure"] = SafeError(e); }
            try { HostProbe(root, result); } catch (Exception e) { result["PowerShellExternalScriptAndModulePassed"] = false; result["PowerShellFailure"] = SafeError(e); result["PowerShellFailureChain"] = SafeErrorChain(e); }
            result["CurrentStage"] = "WinForms";
            try { FormsProbe(result); } catch (Exception e) { result["WinFormsConstructDisposePassed"] = false; result["WinFormsFailure"] = SafeError(e); result["WinFormsFailureChain"] = SafeErrorChain(e); }
            result["CurrentStage"] = "Completed";
            result["UnexpectedOutsideAccess"] = securityFailure;
            result["ExperimentCompleted"] = true;
        }
        catch (Exception e) { result["ChildHarnessError"] = SafeError(e); result["ExperimentCompleted"] = false; }
        // Direct --child invocation under a normal token must not perform I/O.
        if (!tokenVerified) return 2;
        WriteJson(Path.Combine(Path.Combine(root, "private-data"), "ChildSummary.json"), result);
        return securityFailure || result.ContainsKey("ChildHarnessError") ? 2 : 0;
    }
    private static IntPtr MakeJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null); if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        ExtendedLimitInformation limits = new ExtendedLimitInformation(); limits.BasicLimitInformation.LimitFlags = 0x2000;
        IntPtr bytes = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ExtendedLimitInformation)));
        try { Marshal.StructureToPtr(limits, bytes, false); if (!SetInformationJobObject(job, 9, bytes, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) { int error = Marshal.GetLastWin32Error(); CloseHandle(job); throw new Win32Exception(error); } }
        finally { Marshal.FreeHGlobal(bytes); }
        return job;
    }
    private static int Parent(string root, bool registryRead, bool instrumentation = false)
    {
        Dictionary<string, object> report = Record(); report["Status"] = "NOT_READY"; report["NoGuiAuthorization"] = true;
        report["ActualTaskPilotLaunched"] = false; report["RealPersonalPathsOpenedByProbe"] = false;
        string[] capabilityNames = instrumentation ? new string[] { "registryRead", "lpacInstrumentation" } : registryRead ? new string[] { "registryRead" } : new string[0];
        report["OsPolicyOrTrustChanged"] = false; report["RequestedCapabilities"] = capabilityNames.Length;
        report["RequestedCapabilityNames"] = capabilityNames;
        report["RegistryIsolationVerified"] = false; report["RealUserCapabilitySafetyAudited"] = false;
        report["NetworkAccessVerified"] = false; report["WinFormsInteractiveGuiVerified"] = false;
        report["ExperimentOutcome"] = "NOT_RUN"; report["SyntheticProfileCreated"] = false;
        report["OnlyUniqueSyntheticAppContainerProfileApiUsed"] = true;
        report["ActualNormalPs2exeLoaderVerified"] = false;
        report["AllApplicationPackagesOptOutRequested"] = true; report["HarnessError"] = false;
        report["UnexpectedOutsideAccess"] = false; report["ProfileCleanupSucceeded"] = true;
        string profileName = "TaskPilotSyntheticProbe." + Guid.NewGuid().ToString("N");
        bool profileCreated = false, attributesInitialized = false, scratchValidated = false; IntPtr sid = IntPtr.Zero, attributes = IntPtr.Zero, capsMemory = IntPtr.Zero, optOutMemory = IntPtr.Zero, job = IntPtr.Zero, environment = IntPtr.Zero, capabilityArray = IntPtr.Zero;
        List<IntPtr> capabilitySids = new List<IntPtr>();
        ProcessInformation child = new ProcessInformation(); bool childCreated = false;
        Dictionary<string, byte[]> canaries = new Dictionary<string, byte[]>();
        Dictionary<string, string[]> expectedNames = new Dictionary<string, string[]>();
        try
        {
            Check(Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" && Environment.GetEnvironmentVariable("RUNNER_OS") == "Windows", "Disposable Windows CI only.");
            string runnerTemp = Environment.GetEnvironmentVariable("RUNNER_TEMP");
            Check(!String.IsNullOrEmpty(runnerTemp) && root.StartsWith(Path.GetFullPath(runnerTemp).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase), "The scratch directory must be below CI RUNNER_TEMP.");
            string self = Process.GetCurrentProcess().MainModule.FileName;
            Check(String.Equals(self, Path.Combine(root, "LpacProbe.exe"), StringComparison.OrdinalIgnoreCase), "Only the fresh scratch-compiled probe is accepted.");
            string cursor = root;
            while (!String.IsNullOrEmpty(cursor))
            {
                Check((File.GetAttributes(cursor) & FileAttributes.ReparsePoint) == 0, "Scratch ancestors must not be reparse points.");
                string next = Path.GetDirectoryName(cursor); if (next == cursor) break; cursor = next;
            }
            string[] initialEntries = Directory.GetFileSystemEntries(root);
            Check(initialEntries.Length == 1 && String.Equals(initialEntries[0], self, StringComparison.OrdinalIgnoreCase), "The new scratch directory must contain only this compiled probe.");
            scratchValidated = true;
            int hr = CreateAppContainerProfile(profileName, "Synthetic TaskPilot CI probe", "Synthetic LPAC feasibility only; no app authorization", IntPtr.Zero, 0, out sid);
            report["ProfileCreateHresult"] = hr;
            if (hr != 0) { report["MeasuredBlocker"] = "APP_CONTAINER_PROFILE_CREATION_FAILED_OR_NON_UNIQUE"; report["ExperimentOutcome"] = "BLOCKED_BEFORE_CHILD_CREATION"; return 0; }
            profileCreated = true; report["SyntheticProfileCreated"] = true;
            SecurityIdentifier appSid = new SecurityIdentifier(sid);
            SetAcl(root, appSid, FileSystemRights.Traverse, 0);
            string payload = Path.Combine(root, "payload"), data = Path.Combine(root, "private-data");
            Directory.CreateDirectory(payload); SetAcl(payload, appSid, FileSystemRights.ReadAndExecute, 0);
            Directory.CreateDirectory(data); SetAcl(data, appSid, FileSystemRights.Modify, 0);
            SetPrivateLowIntegrityLabel(data); report["OwnSyntheticPrivateDataLowIntegrityLabelSet"] = true;
            Directory.CreateDirectory(Path.Combine(data, "Temp"));
            Directory.CreateDirectory(Path.Combine(data, "Profile\\AppData\\Local"));
            Directory.CreateDirectory(Path.Combine(data, "Profile\\AppData\\Roaming"));
            string image = Path.Combine(payload, "LpacProbe.exe"); File.Copy(Process.GetCurrentProcess().MainModule.FileName, image, false);
            File.WriteAllText(Path.Combine(payload, "external.ps1"), "$script:TaskPilotSyntheticExternalFlag=$true\r\n", new UTF8Encoding(true));
            File.WriteAllText(Path.Combine(payload, "synthetic.psm1"), "function Get-TaskPilotSyntheticValue { 'SYNTHETIC_ONLY' }; Export-ModuleMember -Function Get-TaskPilotSyntheticValue\r\n", new UTF8Encoding(true));
            foreach (string fixture in new string[] { "normal-default", "normal-all-app-packages", "normal-everyone", "other-private" })
            {
                string folder = Path.Combine(root, fixture); Directory.CreateDirectory(folder); SetAcl(folder, null, null, fixture == "normal-all-app-packages" ? 1 : (fixture == "normal-everyone" ? 2 : 0));
                string[] leaves = new string[] { "canary.txt", "delete-canary.txt", "rename-canary.txt" };
                foreach (string leaf in leaves)
                {
                    string canary = Path.Combine(folder, leaf); byte[] bytes = Encoding.UTF8.GetBytes("SYNTHETIC_CANARY_" + fixture + "_" + leaf);
                    File.WriteAllBytes(canary, bytes); canaries.Add(canary, bytes);
                }
                expectedNames.Add(folder, leaves);
            }
            bool linkCreated = CreateSymbolicLink(Path.Combine(data, "escape-link.txt"), Path.Combine(Path.Combine(root, "normal-default"), "canary.txt"), 0);
            report["SyntheticFileSymlinkCreated"] = linkCreated;
            if (!linkCreated) report["SymlinkCreationWin32Error"] = Marshal.GetLastWin32Error();
            Dictionary<string, object> plan = Record(); plan["SyntheticFileSymlinkCreated"] = linkCreated;
            IntPtr profileFolder = IntPtr.Zero;
            try
            {
                int folderResult = GetAppContainerFolderPath(appSid.Value, out profileFolder); report["NewSyntheticProfileFolderQueryHresult"] = folderResult;
                if (folderResult >= 0 && profileFolder != IntPtr.Zero) plan["CreatedAppContainerProfilePath"] = Marshal.PtrToStringUni(profileFolder);
            }
            finally { if (profileFolder != IntPtr.Zero) Marshal.FreeCoTaskMem(profileFolder); }
            WriteJson(Path.Combine(payload, "ProbePlan.json"), plan);
            foreach (string file in Directory.GetFiles(payload)) PinnedPayload.Add(File.Open(file, FileMode.Open, FileAccess.Read, FileShare.Read));
            IntPtr listSize = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref listSize);
            attributes = Marshal.AllocHGlobal(listSize); if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref listSize)) throw new Win32Exception(Marshal.GetLastWin32Error()); attributesInitialized = true;
            SecurityCapabilities caps = new SecurityCapabilities(); caps.AppContainerSid = sid;
            if (registryRead)
            {
                int itemSize = Marshal.SizeOf(typeof(SidAndAttributes)); capabilityArray = Marshal.AllocHGlobal(itemSize * capabilityNames.Length);
                for (int i = 0; i < capabilityNames.Length; i++)
                {
                    SecurityIdentifier capability = KnownCapabilitySid(capabilityNames[i]);
                    byte[] bytes = new byte[capability.BinaryLength]; capability.GetBinaryForm(bytes, 0);
                    IntPtr capabilitySid = Marshal.AllocHGlobal(bytes.Length); capabilitySids.Add(capabilitySid); Marshal.Copy(bytes, 0, capabilitySid, bytes.Length);
                    SidAndAttributes item = new SidAndAttributes(); item.Sid = capabilitySid; item.Attributes = 4;
                    Marshal.StructureToPtr(item, IntPtr.Add(capabilityArray, itemSize * i), false);
                }
                caps.Capabilities = capabilityArray; caps.CapabilityCount = (uint)capabilityNames.Length;
            }
            capsMemory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SecurityCapabilities))); Marshal.StructureToPtr(caps, capsMemory, false);
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(SecurityCapabilitiesAttribute), capsMemory, new IntPtr(Marshal.SizeOf(typeof(SecurityCapabilities))), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            optOutMemory = Marshal.AllocHGlobal(4); Marshal.WriteInt32(optOutMemory, (int)AllApplicationPackagesOptOut);
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(AllApplicationPackagesPolicyAttribute), optOutMemory, new IntPtr(4), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            StartupInfoEx startup = new StartupInfoEx(); startup.StartupInfo.cb = Marshal.SizeOf(typeof(StartupInfoEx)); startup.AttributeList = attributes;
            StringBuilder command = new StringBuilder("\"" + image + "\" --child \"" + root + "\"");
            job = MakeJob();
            List<object> environmentAttempts = new List<object>();
            report["EnvironmentAttempts"] = environmentAttempts;
            for (int variant = 0; variant < 3; variant++)
            {
                if (environment != IntPtr.Zero) { Marshal.FreeHGlobal(environment); environment = IntPtr.Zero; }
                bool processPolicyPreserved; environment = ChildEnvironment(data, variant, out processPolicyPreserved);
                report["ParentProcessPolicyHintPreserved"] = processPolicyPreserved; report["ChildEnvironmentUsesAllowlist"] = true; report["ChildInheritedCiCredentials"] = false;
                Dictionary<string, object> attempt = Record(); attempt["Variant"] = variant;
                attempt["AddedPrivateEnvironmentKeys"] = variant == 0 ? new string[0] : variant == 1 ? new string[] { "USERPROFILE" } : new string[] { "USERPROFILE", "LOCALAPPDATA", "APPDATA" };
                // Token restrictions and all handles stay identical. Only
                // private environment paths differ; no ordinary fallback.
                child = new ProcessInformation();
                bool created = CreateProcess(image, new StringBuilder(command.ToString()), IntPtr.Zero, IntPtr.Zero, false, ExtendedStartupInfoPresent | CreateSuspended | CreateNoWindow | CreateUnicodeEnvironment, environment, data, ref startup, out child);
                int error = created ? 0 : Marshal.GetLastWin32Error();
                attempt["ProcessCreated"] = created; attempt["Win32Error"] = error;
                environmentAttempts.Add(attempt);
                if (created) { childCreated = true; report["SuccessfulEnvironmentVariant"] = variant; break; }
                report["CreateProcessWin32Error"] = error;
                if (error != 203) break;
            }
            if (!childCreated) { report["MeasuredBlocker"] = "LPAC_CREATE_PROCESS_FAILED"; report["ExperimentOutcome"] = "BLOCKED_BEFORE_CHILD_CREATION"; return 0; }
            report["ChildCreated"] = true;
            if (!AssignProcessToJobObject(job, child.Process)) throw new Win32Exception(Marshal.GetLastWin32Error());
            report["KillOnJobCloseEnabled"] = true;
            IntPtr childToken; if (!OpenProcessToken(child.Process, TokenQuery, out childToken)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                report["ChildSameOrdinaryUserSid"] = TokenUser(childToken) == WindowsIdentity.GetCurrent().User.Value;
                report["ChildKernelIsAppContainer"] = TokenInt(childToken, 29) != 0;
                RecordLpacQueryDiagnostic(childToken, report);
                uint mask = LpacAccessMask(childToken);
                report["ChildKernelLpacAccessMask"] = mask;
                report["ChildKernelIsLpac"] = mask == 2;
                report["LpacVerificationMethod"] = "AccessCheck: AAP bit absent; ARAP bit present; suspended ordinary-AC control";
                report["ChildKernelAppContainerSidMatchesUniqueProfile"] = TokenAppSid(childToken) == appSid.Value;
                report["ChildKernelCapabilityCount"] = TokenCapabilitiesCount(childToken);
                bool exactCapabilities = CapabilitiesMatch(childToken, registryRead, instrumentation); report["ChildKernelExactCapabilitiesMatch"] = exactCapabilities;
                Check((bool)report["ChildSameOrdinaryUserSid"] && (bool)report["ChildKernelIsAppContainer"] && (bool)report["ChildKernelIsLpac"] && (bool)report["ChildKernelAppContainerSidMatchesUniqueProfile"] && exactCapabilities, "Kernel token did not match requested LPAC conditions.");
            }
            finally { CloseHandle(childToken); }
            // Counterfactual control is another AppContainer, never an ordinary
            // full-trust process. It remains suspended and is never resumed.
            ProcessInformation control = new ProcessInformation(); bool controlCreated = false, controlAttributesInitialized = false;
            IntPtr controlAttributes = IntPtr.Zero;
            try
            {
                IntPtr controlSize = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref controlSize);
                controlAttributes = Marshal.AllocHGlobal(controlSize);
                if (!InitializeProcThreadAttributeList(controlAttributes, 1, 0, ref controlSize)) throw new Win32Exception(Marshal.GetLastWin32Error());
                controlAttributesInitialized = true;
                if (!UpdateProcThreadAttribute(controlAttributes, 0, new IntPtr(SecurityCapabilitiesAttribute), capsMemory, new IntPtr(Marshal.SizeOf(typeof(SecurityCapabilities))), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                StartupInfoEx controlStartup = new StartupInfoEx(); controlStartup.StartupInfo.cb = Marshal.SizeOf(typeof(StartupInfoEx)); controlStartup.AttributeList = controlAttributes;
                if (!CreateProcess(image, new StringBuilder(command.ToString()), IntPtr.Zero, IntPtr.Zero, false, ExtendedStartupInfoPresent | CreateSuspended | CreateNoWindow | CreateUnicodeEnvironment, environment, data, ref controlStartup, out control)) throw new Win32Exception(Marshal.GetLastWin32Error());
                controlCreated = true;
                if (!AssignProcessToJobObject(job, control.Process)) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr controlToken; if (!OpenProcessToken(control.Process, TokenQuery, out controlToken)) throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    Check(TokenInt(controlToken, 29) != 0 && TokenAppSid(controlToken) == appSid.Value && CapabilitiesMatch(controlToken, registryRead, instrumentation), "The suspended control token did not match the same AppContainer identity.");
                    uint mask = LpacAccessMask(controlToken);
                    report["SuspendedOrdinaryAppContainerAccessMask"] = mask;
                    Check(mask == 3, "The ordinary AppContainer control must grant both synthetic AAP/ARAP rights.");
                    report["SuspendedOrdinaryAppContainerControlVerified"] = true;
                }
                finally { CloseHandle(controlToken); }
            }
            finally
            {
                if (controlCreated)
                {
                    TerminateProcess(control.Process, 0); WaitForSingleObject(control.Process, 5000);
                    CloseHandle(control.Thread); CloseHandle(control.Process);
                }
                if (controlAttributes != IntPtr.Zero) { if (controlAttributesInitialized) DeleteProcThreadAttributeList(controlAttributes); Marshal.FreeHGlobal(controlAttributes); }
                report["OrdinaryAppContainerControlEverResumed"] = false;
            }
            if (ResumeThread(child.Thread) == UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint wait = WaitForSingleObject(child.Process, 45000);
            if (wait != 0) { TerminateProcess(child.Process, 3); WaitForSingleObject(child.Process, 5000); report["MeasuredBlocker"] = "LPAC_CHILD_TIMED_OUT"; report["ChildTimedOut"] = true; }
            uint exit; if (!GetExitCodeProcess(child.Process, out exit)) throw new Win32Exception(Marshal.GetLastWin32Error()); report["ChildExitCode"] = exit;
            string childReport = Path.Combine(data, "ChildSummary.json");
            if (File.Exists(childReport))
            {
                Dictionary<string, object> measured = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(childReport));
                report["Child"] = measured;
                if (measured.ContainsKey("UnexpectedOutsideAccess") && (bool)measured["UnexpectedOutsideAccess"]) report["UnexpectedOutsideAccess"] = true;
                if (!measured.ContainsKey("ExperimentCompleted") || !(bool)measured["ExperimentCompleted"] || exit != 0) report["HarnessError"] = true;
                report["FileBoundaryExperimentCompleted"] = measured.ContainsKey("ExperimentCompleted") && (bool)measured["ExperimentCompleted"];
                report["ExperimentOutcome"] = (bool)report["HarnessError"] || (bool)report["UnexpectedOutsideAccess"] ? "EXPERIMENT_FAILED" : "SYNTHETIC_LPAC_CORE_OBSERVED_NO_GUI_AUTHORIZATION";
            }
            else { report["MeasuredBlocker"] = "MANAGED_CHILD_DID_NOT_REACH_REPORT"; report["ManagedHostAvailable"] = false; report["FileBoundaryExperimentCompleted"] = false; report["ExperimentOutcome"] = "BLOCKED_BEFORE_MANAGED_CHILD_REPORT"; }
        }
        catch (Exception e) { report["HarnessError"] = true; report["BoundedError"] = SafeError(e); report["ExperimentOutcome"] = "HARNESS_OR_REQUIRED_CONDITION_FAILED"; }
        finally
        {
            if (childCreated)
            {
                if (WaitForSingleObject(child.Process, 0) != 0) { TerminateProcess(child.Process, 4); WaitForSingleObject(child.Process, 5000); }
                CloseHandle(child.Thread); CloseHandle(child.Process);
            }
            if (job != IntPtr.Zero) CloseHandle(job);
            foreach (FileStream pin in PinnedPayload) pin.Dispose(); PinnedPayload.Clear();
            if (attributes != IntPtr.Zero) { if (attributesInitialized) DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
            if (capsMemory != IntPtr.Zero) Marshal.FreeHGlobal(capsMemory);
            if (capabilityArray != IntPtr.Zero) Marshal.FreeHGlobal(capabilityArray);
            foreach (IntPtr capabilitySid in capabilitySids) Marshal.FreeHGlobal(capabilitySid);
            if (optOutMemory != IntPtr.Zero) Marshal.FreeHGlobal(optOutMemory);
            if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            bool unchanged = true;
            foreach (KeyValuePair<string, byte[]> canary in canaries)
            {
                try
                {
                    byte[] now = File.ReadAllBytes(canary.Key); if (now.Length != canary.Value.Length) unchanged = false;
                    else for (int i = 0; i < now.Length; i++) if (now[i] != canary.Value[i]) unchanged = false;
                }
                catch (Exception e) { unchanged = false; report["CanaryVerificationError"] = SafeError(e); }
            }
            foreach (KeyValuePair<string, string[]> fixture in expectedNames)
            {
                try
                {
                    string[] actual = Directory.GetFiles(fixture.Key); if (actual.Length != fixture.Value.Length) unchanged = false;
                    foreach (string file in actual) if (Array.IndexOf(fixture.Value, Path.GetFileName(file)) < 0) unchanged = false;
                }
                catch (Exception e) { unchanged = false; report["CanaryDirectoryVerificationError"] = SafeError(e); }
            }
            report["SyntheticNormalCanariesUnchanged"] = unchanged;
            if (!unchanged) report["UnexpectedOutsideAccess"] = true;
            if (profileCreated)
            {
                try { int cleanup = DeleteAppContainerProfile(profileName); report["ProfileDeleteHresult"] = cleanup; report["ProfileCleanupSucceeded"] = cleanup >= 0; }
                catch (Exception e) { report["ProfileCleanupSucceeded"] = false; report["ProfileCleanupError"] = SafeError(e); }
            }
            if (sid != IntPtr.Zero) FreeSid(sid);
            if (scratchValidated) WriteJson(Path.Combine(root, "ParentSummary.json"), report);
        }
        return (bool)report["HarnessError"] || (bool)report["UnexpectedOutsideAccess"] || !(bool)report["ProfileCleanupSucceeded"] ? 2 : 0;
    }
    [STAThread] public static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--child") return Child(Path.GetFullPath(args[1]));
        if (args.Length == 2 && args[0] == "--registry-read") return Parent(Path.GetFullPath(args[1]), true);
        if (args.Length == 2 && args[0] == "--registry-read-instrumentation") return Parent(Path.GetFullPath(args[1]), true, true);
        if (args.Length != 1) return 2;
        return Parent(Path.GetFullPath(args[0]), false);
    }
}
