// TaskPilot developer test-mode filesystem boundary. Compile for .NET Framework
// 4.6 in the build; the application never invokes a C# compiler to load this file.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace TaskPilot.Runtime
{
    public sealed class SandboxViolationException : IOException
    {
        public SandboxViolationException(string message) : base(message) { }
    }

    public sealed class Sandbox : IDisposable
    {
        private const uint ReadAttributes = 0x80, GenericRead = 0x80000000,
            GenericWrite = 0x40000000, DeleteAccess = 0x10000;
        private const uint ShareRead = 1, ShareReadWrite = 3, OpenExistingFile = 3, OpenAlways = 4,
            CreateNew = 1, OpenReparsePoint = 0x00200000, BackupSemantics = 0x02000000;
        private const uint ReparsePoint = 0x400, DirectoryAttribute = 0x10;
        private readonly object sync = new object();
        private readonly Dictionary<string, SafeFileHandle> directories = new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, FilePin> files = new Dictionary<string, FilePin>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, LockLease> locks = new Dictionary<string, LockLease>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, WriterLease> writers = new Dictionary<string, WriterLease>(StringComparer.OrdinalIgnoreCase);
        private const string DirectoryGuardName = ".taskpilot-directory-guard";
        private static readonly byte[] DirectoryGuardBytes = Encoding.UTF8.GetBytes("TaskPilot pinned directory guard v2\n");
        private enum SandboxPurpose { IndependentTest, DesktopAcceptance }
        private readonly string sandboxNamespace;
        private readonly string markerHeading;
        private readonly string markerFileName;
        private bool disposed, faulted, readOnly;
        private string faultReason;
        private string ownerSid;
        private string defaultOwnerSid;

        private sealed class FilePin
        {
            internal SafeFileHandle Handle;
            internal int ManualCount, DatabaseCount;
            internal bool IsGuard;
        }
        private sealed class WriterLease : IDisposable
        {
            internal Sandbox Owner;
            internal string Path;
            public void Dispose()
            {
                Sandbox current = Owner;
                if (current == null) return;
                lock (current.sync)
                {
                    if (Owner == null) return;
                    current.writers.Remove(Path);
                    FilePin pin;
                    if (current.files.TryGetValue(Path, out pin)) { pin.DatabaseCount--; current.RemoveUnusedPin(Path, pin); }
                    Owner = null;
                }
            }
        }
        public sealed class DirectoryEntry
        {
            public string Name { get; internal set; }
            public string FullName { get; internal set; }
            public string Extension { get { return System.IO.Path.GetExtension(Name); } }
            public FileAttributes Attributes { get; internal set; }
            public bool IsDirectory { get { return (Attributes & FileAttributes.Directory) != 0; } }
            public long Length { get; internal set; }
        }
        private sealed class LockLease : IDisposable
        {
            private Sandbox owner;
            internal readonly string Path;
            internal SafeFileHandle Handle;
            internal LockLease(Sandbox owner, string path, SafeFileHandle handle) { this.owner = owner; Path = path; Handle = handle; }
            public void Dispose()
            {
                Sandbox current = owner;
                if (current == null) return;
                lock (current.sync)
                {
                    if (owner == null) return;
                    Handle.Dispose(); current.locks.Remove(Path); owner = null;
                }
            }
        }

        public string ProfileRoot { get; private set; }
        public string EnvironmentId { get; private set; }
        public string Root { get; private set; }
        public string Data { get; private set; }
        public string Export { get; private set; }
        public string Backup { get; private set; }
        public string Logs { get; private set; }
        public string Temp { get; private set; }
        public string Input { get; private set; }
        public string LockPath { get; private set; }
        public string MarkerPath { get; private set; }
        public bool IsFaulted { get { lock (sync) { return faulted; } } }
        public bool IsDisposed { get { lock (sync) { return disposed; } } }
        public bool IsReadOnly { get { return readOnly; } }
        public bool HasAcceptanceDiagnosticLock { get { lock (sync) { return !disposed && readOnly && sandboxNamespace == "TaskPilotAcceptance" && locks.ContainsKey(LockPath); } } }
        public string FaultReason { get { lock (sync) { return faultReason; } } }
        public string[] InfrastructurePaths { get { return new string[] { MarkerPath, LockPath }; } }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            internal uint Attributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
            internal uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder name, uint length, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetVolumeInformationW(string root, StringBuilder volume, uint volumeLength, out uint serial, out uint maximumComponent, out uint flags, StringBuilder filesystem, uint filesystemLength);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectoryW(string path, IntPtr security);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }
        [StructLayout(LayoutKind.Sequential)]
        private struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ObjectAttributes { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
        [DllImport("ntdll.dll")]
        private static extern int NtCreateFile(out SafeFileHandle handle, uint access, ref ObjectAttributes attributes, out IoStatusBlock status, IntPtr allocationSize, uint fileAttributes, uint share, uint disposition, uint options, IntPtr ea, uint eaLength);
        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(SafeFileHandle handle, out IoStatusBlock status, IntPtr information, uint size, int informationClass);
        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);
        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityInfo(IntPtr handle, int objectType, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        public static Sandbox Create(string profileRoot, string environmentId)
        {
            return OpenCore(profileRoot, environmentId, true, SandboxPurpose.IndependentTest);
        }
        public static Sandbox OpenExisting(string profileRoot, string environmentId)
        {
            return OpenCore(profileRoot, environmentId, false, SandboxPurpose.IndependentTest);
        }
        public static Sandbox CreateAcceptance(string profileRoot, string environmentId)
        {
            return OpenCore(profileRoot, environmentId, true, SandboxPurpose.DesktopAcceptance);
        }
        public static Sandbox OpenExistingAcceptance(string profileRoot, string environmentId)
        {
            return OpenCore(profileRoot, environmentId, false, SandboxPurpose.DesktopAcceptance);
        }
        private static Sandbox OpenCore(string profileRoot, string environmentId, bool initialize, SandboxPurpose purpose)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("Independent test mode requires native 64-bit Windows.");
            if (environmentId == null || !Regex.IsMatch(environmentId, "\\A[a-f0-9]{32}\\z"))
                throw new ArgumentException("TestEnvironmentId must be exactly 32 lowercase hexadecimal characters.");
            Sandbox context = new Sandbox(purpose);
            context.readOnly = !initialize;
            try
            {
                context.ProfileRoot = context.NormalizeAbsolute(profileRoot);
                context.ownerSid = WindowsIdentity.GetCurrent().User.Value;
                context.defaultOwnerSid = WindowsIdentity.GetCurrent().Owner.Value;
                string drive = Path.GetPathRoot(context.ProfileRoot);
                DriveInfo info = new DriveInfo(drive);
                if (info.DriveType != DriveType.Fixed) throw context.Violation("Test mode requires a local fixed NTFS drive.");
                uint serial, maximum, flags;
                StringBuilder filesystem = new StringBuilder(64);
                if (!GetVolumeInformationW(drive, null, 0, out serial, out maximum, out flags, filesystem, 64))
                    throw NativeError("Cannot inspect test-mode volume");
                if (!String.Equals(filesystem.ToString(), "NTFS", StringComparison.OrdinalIgnoreCase))
                    throw context.Violation("Test mode currently supports NTFS only.");
                context.EnvironmentId = environmentId;
                context.Root = Path.Combine(context.ProfileRoot, context.sandboxNamespace, environmentId);
                context.MarkerPath = Path.Combine(context.Root, context.markerFileName);
                context.LockPath = Path.Combine(context.Root, "test.storage.lock");
                context.PinDirectoryChain(context.ProfileRoot, false);
                context.PinDirectoryChain(Path.Combine(context.ProfileRoot, context.sandboxNamespace), initialize);
                bool existed = context.TryPinDirectory(context.Root);
                if (!existed)
                {
                    if (!initialize) throw new DirectoryNotFoundException("The existing test environment was not found.");
                    context.PinDirectoryChain(context.Root, true);
                }
                string marker = context.markerHeading + environmentId + "\n";
                if (context.Exists(context.MarkerPath))
                {
                    if (!String.Equals(context.ReadAllText(context.MarkerPath), marker, StringComparison.Ordinal))
                        throw context.Violation("The test environment identity marker does not match its directory.");
                }
                else
                {
                    if (!initialize) throw context.Violation("The existing test environment has no identity marker.");
                    // An existing nonempty directory is never silently adopted.
                    if (existed && context.ListDirectory(context.Root).Length != 0)
                        throw context.Violation("An existing nonempty test directory has no identity marker. It will not be adopted or cleared.");
                    context.WriteNew(context.MarkerPath, new UTF8Encoding(false, true).GetBytes(marker));
                }
                context.ValidateTree();
                context.Data = Path.Combine(context.Root, "Data");
                context.Export = Path.Combine(context.Root, "Export");
                context.Backup = Path.Combine(context.Root, "Backup");
                context.Logs = Path.Combine(context.Root, "Logs");
                context.Temp = Path.Combine(context.Root, "Temp");
                context.Input = Path.Combine(context.Root, "Input");
                if (initialize)
                {
                    context.EnsureDirectory(context.Data); context.EnsureDirectory(context.Export);
                    context.EnsureDirectory(context.Backup); context.EnsureDirectory(context.Logs);
                    context.EnsureDirectory(context.Temp); context.EnsureDirectory(context.Input);
                }
                return context;
            }
            catch { context.Dispose(); throw; }
        }

        private Sandbox(SandboxPurpose purpose)
        {
            // Namespace and purpose are chosen exclusively by fixed public
            // factories. They are never caller-supplied paths or settings.
            bool acceptance = purpose == SandboxPurpose.DesktopAcceptance;
            sandboxNamespace = acceptance ? "TaskPilotAcceptance" : "TaskPilotTest";
            markerFileName = acceptance ? ".taskpilot-acceptance-environment" : ".taskpilot-test-environment";
            markerHeading = acceptance ? "TaskPilot desktop acceptance synthetic-only environment v1\n" : "TaskPilot independent test environment v2\n";
        }
        private static IOException NativeError(string action)
        {
            int code = Marshal.GetLastWin32Error();
            return new IOException(action + ": " + new Win32Exception(code).Message + " (" + code.ToString() + ")", new Win32Exception(code));
        }
        private SandboxViolationException Violation(string detail)
        {
            faulted = true;
            if (faultReason == null) faultReason = detail;
            return new SandboxViolationException("Test-mode boundary violation: " + detail);
        }
        private void CheckLive()
        {
            if (disposed) throw new ObjectDisposedException("TaskPilot test sandbox");
            if (faulted) throw new SandboxViolationException("The test environment was stopped after a boundary violation: " + faultReason);
        }
        private void CheckWritable()
        {
            CheckLive();
            if (readOnly) throw new InvalidOperationException("This existing test environment was opened for read-only diagnostics.");
        }
        private string NormalizeAbsolute(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || path.Length < 3 || path[1] != ':' || path[2] != '\\' || !Char.IsLetter(path[0]) || path.StartsWith("\\", StringComparison.Ordinal))
                throw Violation("Only fully qualified local drive paths are accepted.");
            if (path.IndexOf('/') >= 0 || path.IndexOf('%') >= 0 || path.IndexOf('\0') >= 0 || path.IndexOf(':', 2) >= 0)
                throw Violation("Device paths, environment tokens, alternate streams and alternate separators are not accepted.");
            string rest = path.Substring(3).TrimEnd('\\');
            if (rest.Length != 0)
            {
                foreach (string component in rest.Split('\\'))
                {
                    if (component.Length == 0 || component == "." || component == ".." || component.EndsWith(".", StringComparison.Ordinal) || component.EndsWith(" ", StringComparison.Ordinal) || component.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Regex.IsMatch(component, "\\A(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|\\z)"))
                        throw Violation("Unsafe or noncanonical path component.");
                }
            }
            string full = Path.GetFullPath(path);
            return full.Length > 3 ? full.TrimEnd('\\') : full;
        }
        private string Confine(string path)
        {
            CheckLive();
            string full = NormalizeAbsolute(path);
            if (Root == null || (!String.Equals(full, Root, StringComparison.OrdinalIgnoreCase) && !full.StartsWith(Root + "\\", StringComparison.OrdinalIgnoreCase)))
                throw Violation("The requested state path is outside this test environment.");
            return full;
        }
        private FileInformation Information(SafeFileHandle handle, string expected, bool directory)
        {
            FileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) throw NativeError("Cannot inspect an open test handle");
            if ((info.Attributes & ReparsePoint) != 0) throw Violation("Links and junctions are not permitted: " + expected);
            if (((info.Attributes & DirectoryAttribute) != 0) != directory) throw Violation("A path has an unexpected file/directory type: " + expected);
            if (!directory && info.NumberOfLinks != 1) throw Violation("Files with multiple hard links are not permitted: " + expected);
            StringBuilder actual = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, actual, (uint)actual.Capacity, 0);
            if (length == 0 || length >= actual.Capacity) throw NativeError("Cannot resolve an open test handle");
            string final = actual.ToString();
            if (final.StartsWith("\\\\?\\", StringComparison.Ordinal)) final = final.Substring(4);
            if (!String.Equals(final.TrimEnd('\\'), expected.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                throw Violation("The resolved handle path differs from the pinned test path: " + expected);
            return info;
        }

        private static bool Missing(Exception failure)
        {
            Win32Exception native = failure.InnerException as Win32Exception;
            return native != null && (native.NativeErrorCode == 2 || native.NativeErrorCode == 3);
        }
        private SafeFileHandle OpenRelative(string path, uint access, uint disposition, uint share, bool? directory, byte[] policy)
        {
            string parent = Path.GetDirectoryName(path), leaf = Path.GetFileName(path);
            SafeFileHandle parentHandle;
            if (!directories.TryGetValue(parent, out parentHandle)) throw new IOException("A relative-open parent is not pinned: " + parent);
            Information(parentHandle, parent, true);
            IntPtr nameMemory = Marshal.StringToHGlobalUni(leaf), unicodeMemory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString))), securityMemory = IntPtr.Zero;
            SafeFileHandle handle = null;
            try
            {
                UnicodeString name = new UnicodeString(); name.Length = checked((ushort)(leaf.Length * 2)); name.MaximumLength = checked((ushort)(name.Length + 2)); name.Buffer = nameMemory;
                Marshal.StructureToPtr(name, unicodeMemory, false);
                if (policy != null) { securityMemory = Marshal.AllocHGlobal(policy.Length); Marshal.Copy(policy, 0, securityMemory, policy.Length); }
                ObjectAttributes attributes = new ObjectAttributes(); attributes.Length = Marshal.SizeOf(typeof(ObjectAttributes)); attributes.RootDirectory = parentHandle.DangerousGetHandle(); attributes.ObjectName = unicodeMemory;
                attributes.Attributes = 0x40 | 0x1000; attributes.SecurityDescriptor = securityMemory;
                uint options = 0x20 | OpenReparsePoint;
                if (directory.HasValue) options |= directory.Value ? 1u : 0x40u;
                uint nativeDisposition = disposition == CreateNew ? 2u : (disposition == OpenAlways ? 3u : 1u);
                IoStatusBlock result;
                int status = NtCreateFile(out handle, access | ReadAttributes | 0x100000, ref attributes, out result, IntPtr.Zero, directory == true ? DirectoryAttribute : 0x80u, share, nativeDisposition, options, IntPtr.Zero, 0);
                if (status < 0)
                {
                    int code = unchecked((int)RtlNtStatusToDosError(status));
                    if (handle != null) { handle.Dispose(); handle = null; }
                    if (code == 1920 || unchecked((uint)status) == 0xC000050Bu) throw Violation("Relative open encountered a reparse point: " + path);
                    throw new IOException("Cannot open a test entry relative to its pinned parent: " + path + " (" + code.ToString() + ")", new Win32Exception(code));
                }
                SafeFileHandle answer = handle; handle = null; return answer;
            }
            finally { if (handle != null) handle.Dispose(); if (securityMemory != IntPtr.Zero) Marshal.FreeHGlobal(securityMemory); Marshal.FreeHGlobal(unicodeMemory); Marshal.FreeHGlobal(nameMemory); }
        }
        private SafeFileHandle Borrow(SafeFileHandle owner)
        {
            // A non-owning wrapper leaves the broker lease alive when a
            // FileStream is disposed. Calls hold sync for the whole I/O.
            return new SafeFileHandle(owner.DangerousGetHandle(), false);
        }
        private SafeFileHandle OpenFile(string path, uint access, uint disposition, uint share)
        {
            FilePin pinned;
            if (files.TryGetValue(path, out pinned))
            {
                if (disposition == CreateNew) throw new IOException("The new file already exists.");
                if (pinned.IsGuard && (access & (GenericWrite | DeleteAccess | 2u | 4u)) != 0) throw new IOException("A directory guard is immutable while its environment is open.");
                Information(pinned.Handle, path, false); VerifyProtection(path, pinned.Handle, false);
                return Borrow(pinned.Handle);
            }
            bool writing = (access & (GenericWrite | DeleteAccess | 2u | 4u)) != 0;
            uint specific = 0x20000 | ReadAttributes;
            if ((access & GenericRead) != 0 || writing || (access & 1) != 0) specific |= 1;
            if (writing) specific |= 2 | 4 | DeleteAccess;
            SafeFileHandle handle = OpenRelative(path, specific, disposition, writing ? ShareRead : 7u, false, null);
            try { Information(handle, path, false); VerifyProtection(path, handle, false); return handle; }
            catch { handle.Dispose(); throw; }
        }
        private bool TryPinDirectory(string path)
        {
            SafeFileHandle pinned;
            if (directories.TryGetValue(path, out pinned)) { Information(pinned, path, true); VerifyProtection(path, pinned, true); return true; }
            uint access = ReadAttributes | 1 | 0x20;
            if (RequiresDirectoryPolicy(path)) access |= 0x20000 | 2 | 4;
            else if (String.Equals(path, ProfileRoot, StringComparison.OrdinalIgnoreCase)) access |= 4;
            SafeFileHandle handle;
            try
            {
                if (String.Equals(path, Path.GetPathRoot(path), StringComparison.OrdinalIgnoreCase))
                {
                    // The volume root is the sole absolute open. Every user
                    // path component thereafter is opened by parent handle.
                    handle = CreateFileW(path, access, ShareReadWrite, IntPtr.Zero, OpenExistingFile, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
                    if (handle.IsInvalid) { handle.Dispose(); throw NativeError("Cannot pin the volume root"); }
                }
                else handle = OpenRelative(path, access, OpenExistingFile, ShareReadWrite, true, null);
            }
            catch (IOException failure) { if (Missing(failure)) return false; throw; }
            try
            {
                Information(handle, path, true); VerifyProtection(path, handle, true); directories.Add(path, handle);
                AttachDirectoryGuard(path, false);
                return true;
            }
            catch { directories.Remove(path); handle.Dispose(); throw; }
        }
        private bool RequiresDirectoryPolicy(string path)
        {
            if (ProfileRoot == null) return false;
            string home = Path.Combine(ProfileRoot, sandboxNamespace);
            return String.Equals(path, home, StringComparison.OrdinalIgnoreCase) || path.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase);
        }
        private bool RequiresGuard(string path)
        {
            return Root != null && (String.Equals(path, Root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(Root + "\\", StringComparison.OrdinalIgnoreCase));
        }
        private byte[] NewDirectoryPolicy()
        {
            // Both files and containers inherit attribute and owner-policy
            // denials. Only this newly-created test namespace is affected.
            string sddl = "O:" + ownerSid + "D:P(D;OICI;0x110;;;S-1-1-0)(D;OICI;0xc0000;;;S-1-3-4)(A;OICI;FA;;;" + ownerSid + ")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(sddl);
            byte[] bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0); return bytes;
        }
        private void VerifyProtection(string path, SafeFileHandle handle, bool directory)
        {
            if (!RequiresDirectoryPolicy(path)) return;
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(handle.DangerousGetHandle(), 1, 5, out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new IOException("Cannot inspect test-entry protection.", new Win32Exception(unchecked((int)error)));
            try
            {
                uint size = GetSecurityDescriptorLength(descriptor);
                if (size == 0 || size > 1048576) throw Violation("Invalid test-entry security descriptor.");
                byte[] bytes = new byte[size]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                RawSecurityDescriptor policy = new RawSecurityDescriptor(bytes, 0);
                bool anchor = String.Equals(path, Path.Combine(ProfileRoot, sandboxNamespace), StringComparison.OrdinalIgnoreCase);
                if (policy.Owner == null || (policy.Owner.Value != ownerSid && policy.Owner.Value != defaultOwnerSid) || policy.DiscretionaryAcl == null || (anchor && (policy.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0))
                    throw Violation("An existing entry does not have the required protected policy. It will not be modified or adopted.");
                bool attributesDenied = false, ownerChangeDenied = false;
                foreach (GenericAce raw in policy.DiscretionaryAcl)
                {
                    CommonAce ace = raw as CommonAce;
                    if (ace == null || ace.IsCallback || (ace.AceQualifier != AceQualifier.AccessDenied && ace.AceQualifier != AceQualifier.AccessAllowed)) throw Violation("Unsupported test-entry access policy.");
                    if ((ace.AceFlags & AceFlags.InheritOnly) != 0) continue;
                    if (ace.AceQualifier == AceQualifier.AccessAllowed && (!attributesDenied || !ownerChangeDenied)) throw Violation("Test-entry grants precede the required denials.");
                    if (ace.AceQualifier != AceQualifier.AccessDenied || (directory && (ace.AceFlags & (AceFlags.ContainerInherit | AceFlags.ObjectInherit)) != (AceFlags.ContainerInherit | AceFlags.ObjectInherit))) continue;
                    if (ace.SecurityIdentifier.Value == "S-1-1-0" && (ace.AccessMask & 0x110) == 0x110) attributesDenied = true;
                    if (ace.SecurityIdentifier.Value == "S-1-3-4" && (ace.AccessMask & 0xc0000) == 0xc0000) ownerChangeDenied = true;
                }
                if (!attributesDenied || !ownerChangeDenied) throw Violation("Test-entry attribute/owner protection is missing. No policy was changed.");
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }
        private void AttachDirectoryGuard(string path, bool create)
        {
            if (!RequiresGuard(path)) return;
            string guardPath = Path.Combine(path, DirectoryGuardName);
            FilePin known;
            if (files.TryGetValue(guardPath, out known)) { Information(known.Handle, guardPath, false); return; }
            SafeFileHandle handle = null;
            try
            {
                if (create) handle = OpenFile(guardPath, GenericWrite, CreateNew, ShareRead);
                else handle = OpenFile(guardPath, readOnly ? GenericRead : GenericWrite, OpenExistingFile, ShareRead);
                if (readOnly && !create)
                {
                    // Read-only diagnostics must also keep this marker from
                    // being deleted or written for their entire lifetime.
                    handle.Dispose();
                    handle = OpenRelative(guardPath, 1 | 0x20000, OpenExistingFile, ShareRead, false, null);
                    Information(handle, guardPath, false); VerifyProtection(guardPath, handle, false);
                }
                if (create) WriteHandle(handle, DirectoryGuardBytes);
                else if (!EqualBytes(ReadHandle(handle, 4096), DirectoryGuardBytes)) throw Violation("The nonempty-directory guard is invalid.");
                files.Add(guardPath, new FilePin { Handle = handle, ManualCount = 1, IsGuard = true }); handle = null;
            }
            finally { if (handle != null) handle.Dispose(); }
        }
        private void CreateProtectedDirectory(string path)
        {
            string parent = Path.GetDirectoryName(path);
            SafeFileHandle created = OpenRelative(path, 0x20000 | ReadAttributes | 1 | 2 | 4 | 0x20, CreateNew, ShareReadWrite, true, RequiresDirectoryPolicy(parent) ? null : NewDirectoryPolicy());
            try
            {
                Information(created, path, true); VerifyProtection(path, created, true); directories.Add(path, created);
                AttachDirectoryGuard(path, true); created = null;
            }
            finally { if (created != null) { directories.Remove(path); created.Dispose(); } }
        }
        private void PinDirectoryChain(string full, bool create)
        {
            string drive = Path.GetPathRoot(full);
            if (!TryPinDirectory(drive)) throw new DirectoryNotFoundException(drive);
            string cursor = drive;
            foreach (string component in full.Substring(drive.Length).Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                cursor = Path.Combine(cursor, component);
                if (TryPinDirectory(cursor)) continue;
                if (!create) throw new DirectoryNotFoundException(cursor);
                CreateProtectedDirectory(cursor);
            }
        }
        private void PinParent(string full)
        {
            if (!String.Equals(full, Root, StringComparison.OrdinalIgnoreCase)) PinDirectoryChain(Path.GetDirectoryName(full), false);
        }
        public string AssertPath(string path)
        {
            lock (sync) { string full = Confine(path); PinParent(full); return full; }
        }
        public string EnsureDirectory(string path)
        {
            lock (sync) { CheckWritable(); string full = Confine(path); PinDirectoryChain(full, true); return full; }
        }
        public bool Exists(string path)
        {
            lock (sync)
            {
                string full = Confine(path); SafeFileHandle directory; FilePin pin; LockLease lease;
                if (directories.TryGetValue(full, out directory)) { Information(directory, full, true); return true; }
                if (files.TryGetValue(full, out pin)) { Information(pin.Handle, full, false); return true; }
                if (locks.TryGetValue(full, out lease)) { Information(lease.Handle, full, false); return true; }
                try { PinParent(full); }
                catch (DirectoryNotFoundException) { return false; }
                try
                {
                    using (SafeFileHandle handle = OpenRelative(full, ReadAttributes | 0x20000, OpenExistingFile, 7, null, null))
                    {
                        FileInformation info;
                        if (!GetFileInformationByHandle(handle, out info)) throw NativeError("Cannot inspect an existing entry");
                        Information(handle, full, (info.Attributes & DirectoryAttribute) != 0);
                    }
                    return true;
                }
                catch (IOException failure) { if (Missing(failure)) return false; throw; }
            }
        }
        private DirectoryEntry[] EnumerateHandle(string directory, bool includeGuard)
        {
            SafeFileHandle handle = directories[directory]; Information(handle, directory, true);
            List<DirectoryEntry> entries = new List<DirectoryEntry>();
            IntPtr buffer = Marshal.AllocHGlobal(65536);
            try
            {
                bool restart = true;
                while (true)
                {
                    bool success = GetFileInformationByHandleEx(handle, restart ? 11 : 10, buffer, 65536); restart = false;
                    if (!success)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 18) break;
                        throw new IOException("Cannot enumerate a pinned directory.", new Win32Exception(error));
                    }
                    int offset = 0;
                    while (true)
                    {
                        if (offset < 0 || offset > 65536 - 104) throw Violation("Invalid native directory entry.");
                        IntPtr entry = IntPtr.Add(buffer, offset);
                        int next = Marshal.ReadInt32(entry), nameLength = Marshal.ReadInt32(entry, 60);
                        if (nameLength < 0 || (nameLength & 1) != 0 || nameLength > 65536 - offset - 104) throw Violation("Invalid native directory filename.");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(entry, 104), nameLength / 2);
                        if (name != "." && name != ".." && (includeGuard || name != DirectoryGuardName))
                        {
                            string full = Path.Combine(directory, name);
                            if (name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) throw Violation("Invalid native directory filename.");
                            entries.Add(new DirectoryEntry { Name = name, FullName = full, Attributes = (FileAttributes)Marshal.ReadInt32(entry, 56), Length = Marshal.ReadInt64(entry, 40) });
                            if (entries.Count > 100000) throw Violation("A directory exceeds the entry limit.");
                        }
                        if (next == 0) break;
                        if (next < 104 || next > 65536 - offset) throw Violation("Invalid native directory offset.");
                        offset += next;
                    }
                }
                return entries.ToArray();
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        public DirectoryEntry[] ListDirectory(string path)
        {
            lock (sync) { string full = Confine(path); PinDirectoryChain(full, false); return EnumerateHandle(full, false); }
        }
        public void ValidateTree()
        {
            lock (sync)
            {
                CheckLive(); Stack<string> pending = new Stack<string>(); pending.Push(Root); int count = 0;
                while (pending.Count != 0)
                {
                    string directory = pending.Pop(); PinDirectoryChain(directory, false);
                    foreach (DirectoryEntry entry in EnumerateHandle(directory, true))
                    {
                        if (++count > 100000) throw Violation("The test environment exceeds its validation entry limit.");
                        string full = Confine(entry.FullName);
                        if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) throw Violation("Test environment contains a link: " + full);
                        if (entry.Name.StartsWith(".tp-rollback_", StringComparison.Ordinal)) throw new IOException("An interrupted broker write must be preserved for recovery; automatic recovery is disabled: " + full);
                        if (entry.IsDirectory) { PinDirectoryChain(full, false); pending.Push(full); }
                        else CheckExistingFile(full);
                    }
                }
            }
        }
        public long GetFileLength(string path)
        {
            lock (sync) { string full = AssertPath(path); using (SafeFileHandle handle = OpenFile(full, 1, OpenExistingFile, 7)) return Length(Information(handle, full, false)); }
        }
        public void CheckExistingFile(string path)
        {
            lock (sync)
            {
                string full = AssertPath(path); LockLease lease;
                if (locks.TryGetValue(full, out lease)) { Information(lease.Handle, full, false); return; }
                using (SafeFileHandle handle = OpenFile(full, 1, OpenExistingFile, 7)) { }
            }
        }
        private static long Length(FileInformation info) { return ((long)info.FileSizeHigh << 32) | info.FileSizeLow; }
        private static byte[] ReadHandle(SafeFileHandle handle, int limit)
        {
            using (SafeFileHandle borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
            using (FileStream stream = new FileStream(borrowed, FileAccess.Read, 65536, false))
            {
                stream.Seek(0, SeekOrigin.Begin);
                if (stream.Length > limit) throw new IOException("A test file exceeds its read limit.");
                byte[] data = new byte[(int)stream.Length]; int offset = 0;
                while (offset < data.Length) { int read = stream.Read(data, offset, data.Length - offset); if (read == 0) throw new IOException("Test file changed during read."); offset += read; }
                return data;
            }
        }
        private static void WriteHandle(SafeFileHandle handle, byte[] data)
        {
            using (SafeFileHandle borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
            using (FileStream stream = new FileStream(borrowed, FileAccess.Write, 65536, false))
            {
                stream.Seek(0, SeekOrigin.Begin); stream.Write(data, 0, data.Length); stream.SetLength(data.Length); stream.Flush(true);
            }
        }
        private static bool EqualBytes(byte[] first, byte[] second)
        {
            if (first.Length != second.Length) return false;
            int difference = 0; for (int i = 0; i < first.Length; i++) difference |= first[i] ^ second[i]; return difference == 0;
        }
        public byte[] ReadPrefix(string path, int count)
        {
            if (count < 0 || count > 268435456) throw new ArgumentOutOfRangeException("count");
            lock (sync)
            {
                string full = AssertPath(path);
                using (SafeFileHandle handle = OpenFile(full, GenericRead, OpenExistingFile, 7))
                using (SafeFileHandle borrowed = Borrow(handle))
                using (FileStream stream = new FileStream(borrowed, FileAccess.Read, 65536, false))
                {
                    stream.Seek(0, SeekOrigin.Begin); int wanted = (int)Math.Min((long)count, stream.Length); byte[] data = new byte[wanted]; int offset = 0;
                    while (offset < data.Length) { int read = stream.Read(data, offset, data.Length - offset); if (read == 0) throw new IOException("Test file changed during read."); offset += read; }
                    return data;
                }
            }
        }
        public byte[] ReadAllBytes(string path)
        {
            lock (sync) { string full = AssertPath(path); using (SafeFileHandle handle = OpenFile(full, GenericRead, OpenExistingFile, 7)) return ReadHandle(handle, 268435456); }
        }
        public string ReadAllText(string path)
        {
            byte[] data = ReadAllBytes(path); int offset = data.Length >= 3 && data[0] == 239 && data[1] == 187 && data[2] == 191 ? 3 : 0;
            return new UTF8Encoding(false, true).GetString(data, offset, data.Length - offset);
        }
        public string ReadAllTextLimited(string path, int maximumBytes)
        {
            if (maximumBytes < 0 || maximumBytes > 65536) throw new ArgumentOutOfRangeException("maximumBytes");
            lock (sync)
            {
                string full = AssertPath(path);
                // OpenFile intentionally permits shared normal reads. Limited
                // diagnostics instead exclude existing/future data writers for
                // the entire size check and read, using one native handle.
                using (SafeFileHandle handle = OpenRelative(full, 1 | 0x20000, OpenExistingFile, ShareRead, false, null))
                {
                    Information(handle, full, false); VerifyProtection(full, handle, false);
                    byte[] data = ReadHandle(handle, maximumBytes);
                    int offset = data.Length >= 3 && data[0] == 239 && data[1] == 187 && data[2] == 191 ? 3 : 0;
                    return new UTF8Encoding(false, true).GetString(data, offset, data.Length - offset);
                }
            }
        }
        public void WriteNew(string path, byte[] data)
        {
            if (data == null || data.Length > 268435456) throw new ArgumentException("Invalid or oversized file image.");
            lock (sync) { CheckWritable(); string full = AssertPath(path); using (SafeFileHandle handle = OpenFile(full, GenericWrite, CreateNew, ShareRead)) WriteHandle(handle, data); }
        }
        public void AppendText(string path, string text)
        {
            lock (sync)
            {
                CheckWritable(); string full = AssertPath(path);
                using (SafeFileHandle handle = OpenFile(full, GenericWrite, OpenAlways, ShareRead))
                using (SafeFileHandle borrowed = Borrow(handle))
                using (FileStream stream = new FileStream(borrowed, FileAccess.Write, 65536, false))
                {
                    stream.Seek(0, SeekOrigin.End); byte[] data = new UTF8Encoding(false, true).GetBytes(text); stream.Write(data, 0, data.Length); stream.Flush(true);
                }
            }
        }
        private FilePin GetOrCreatePin(string full, bool create)
        {
            FilePin pin;
            if (files.TryGetValue(full, out pin)) { Information(pin.Handle, full, false); return pin; }
            pin = new FilePin(); pin.Handle = OpenFile(full, readOnly ? GenericRead : GenericWrite, create ? OpenAlways : OpenExistingFile, ShareRead);
            files.Add(full, pin); return pin;
        }
        private void RemoveUnusedPin(string full, FilePin pin)
        {
            if (!pin.IsGuard && pin.ManualCount == 0 && pin.DatabaseCount == 0) { pin.Handle.Dispose(); files.Remove(full); }
        }
        public void PinExistingFile(string path)
        {
            lock (sync) { string full = AssertPath(path); GetOrCreatePin(full, false).ManualCount++; }
        }
        public void ReserveFile(string path)
        {
            lock (sync) { CheckWritable(); string full = AssertPath(path); WriteNew(full, new byte[0]); GetOrCreatePin(full, false).ManualCount++; }
        }
        public void ReleaseFile(string path)
        {
            lock (sync)
            {
                if (disposed) return; string full = Path.GetFullPath(path).TrimEnd('\\'); FilePin pin;
                if (files.TryGetValue(full, out pin) && !pin.IsGuard) { pin.ManualCount = 0; RemoveUnusedPin(full, pin); }
            }
        }
        public IDisposable AcquireLock(string path)
        {
            lock (sync)
            {
                CheckWritable(); string full = AssertPath(path); if (locks.ContainsKey(full)) throw new IOException("This test lock is already held.");
                SafeFileHandle handle = OpenFile(full, GenericWrite, OpenAlways, 0);
                // OpenRelative must carry the requested exclusive share for locks.
                handle.Dispose(); handle = OpenRelative(full, 1 | 2 | 4 | DeleteAccess | 0x20000, OpenExistingFile, 0, false, null);
                Information(handle, full, false); VerifyProtection(full, handle, false);
                LockLease lease = new LockLease(this, full, handle); locks.Add(full, lease); return lease;
            }
        }
        public IDisposable AcquireExistingAcceptanceDiagnosticLock()
        {
            lock (sync)
            {
                CheckLive();
                if (!readOnly || sandboxNamespace != "TaskPilotAcceptance") throw new InvalidOperationException("Read-only acceptance diagnostics are required.");
                string full = AssertPath(LockPath);
                if (locks.ContainsKey(full)) throw new IOException("This diagnostic lock is already held.");
                // FILE_OPEN only: a missing lock means no authorized GUI session
                // prepared this environment. Never create or repair it here.
                SafeFileHandle handle = OpenRelative(full, 1 | 0x20000, OpenExistingFile, 0, false, null);
                try
                {
                    Information(handle, full, false); VerifyProtection(full, handle, false);
                    LockLease lease = new LockLease(this, full, handle); locks.Add(full, lease); handle = null; return lease;
                }
                finally { if (handle != null) handle.Dispose(); }
            }
        }
        public IDisposable AcquireDatabaseWriter(string path)
        {
            lock (sync)
            {
                CheckWritable(); string full = AssertPath(path);
                if (writers.ContainsKey(full)) throw new IOException("A writable in-memory store already owns this test database. Open a read-only snapshot or close the writer first.");
                AssertNoRecoverySidecars(full); FilePin pin = GetOrCreatePin(full, false); pin.DatabaseCount++;
                WriterLease lease = new WriterLease { Owner = this, Path = full }; writers.Add(full, lease); return lease;
            }
        }
        private void AssertNoRecoverySidecars(string full)
        {
            foreach (string suffix in new string[] { "-wal", "-shm", "-journal" })
            {
                if (Exists(full + suffix)) throw new IOException("A SQLite recovery sidecar must be preserved; test mode never asks native SQLite to recover it.");
            }
        }
        public void PrepareDatabase(string path, bool create)
        {
            lock (sync) { CheckWritable(); string full = AssertPath(path); AssertNoRecoverySidecars(full); }
        }
        public void PinDatabase(string path, bool create) { PrepareDatabase(path, create); }
        public void CompleteDatabase(string path) { }
        private void PrepareMutation(string full)
        {
            FilePin pin;
            if (files.TryGetValue(full, out pin) && (pin.IsGuard || pin.ManualCount != 0 || pin.DatabaseCount != 0)) throw new IOException("An active file/guard lease cannot be renamed or deleted.");
            if (locks.ContainsKey(full)) throw new IOException("A held test lock cannot be renamed or deleted.");
        }
        private void RenameHandle(string source, string destination)
        {
            string from = AssertPath(source), to = AssertPath(destination);
            if (String.Equals(from, to, StringComparison.OrdinalIgnoreCase)) throw new IOException("Source and destination must differ.");
            PrepareMutation(from); PrepareMutation(to);
            using (SafeFileHandle handle = OpenFile(from, GenericWrite, OpenExistingFile, ShareRead))
            {
                SafeFileHandle targetDirectory = directories[Path.GetDirectoryName(to)]; Information(targetDirectory, Path.GetDirectoryName(to), true);
                byte[] name = Encoding.Unicode.GetBytes(Path.GetFileName(to)); IntPtr buffer = Marshal.AllocHGlobal(20 + name.Length);
                try
                {
                    for (int i = 0; i < 20 + name.Length; i++) Marshal.WriteByte(buffer, i, 0);
                    Marshal.WriteIntPtr(buffer, 8, targetDirectory.DangerousGetHandle()); Marshal.WriteInt32(buffer, 16, name.Length); Marshal.Copy(name, 0, IntPtr.Add(buffer, 20), name.Length);
                    IoStatusBlock result; int status = NtSetInformationFile(handle, out result, buffer, (uint)(20 + name.Length), 10);
                    if (status < 0) { int code = unchecked((int)RtlNtStatusToDosError(status)); throw new IOException("Cannot publish a new owned file without overwrite.", new Win32Exception(code)); }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        public void MoveNew(string source, string destination)
        {
            lock (sync) { CheckWritable(); RenameHandle(source, destination); }
        }
        public void Replace(string source, string destination, string backup)
        {
            lock (sync)
            {
                CheckWritable(); string from = AssertPath(source), to = AssertPath(destination);
                if (from.Equals(to, StringComparison.OrdinalIgnoreCase)) throw new IOException("Source and destination must differ.");
                AtomicWrite(to, ReadAllBytes(from), backup); DeleteFile(from);
            }
        }
        public void AtomicWrite(string path, byte[] data, string previousPath)
        {
            if (data == null || data.Length > 268435456) throw new ArgumentException("Invalid or oversized file image.");
            lock (sync)
            {
                CheckWritable(); string full = AssertPath(path);
                if (!Exists(full)) { WriteNew(full, data); return; }
                using (SafeFileHandle target = OpenFile(full, GenericWrite, OpenExistingFile, ShareRead))
                {
                    byte[] before = ReadHandle(target, 268435456);
                    if (!String.IsNullOrEmpty(previousPath)) WriteNew(AssertPath(previousPath), before);
                    string checkpoint = Path.Combine(Path.GetDirectoryName(full), ".tp-rollback_" + Guid.NewGuid().ToString("N") + ".bin");
                    SafeFileHandle saved = OpenFile(checkpoint, GenericWrite, CreateNew, ShareRead);
                    bool mayRemoveCheckpoint = false;
                    try
                    {
                        WriteHandle(saved, before);
                        try { WriteHandle(target, data); mayRemoveCheckpoint = true; }
                        catch
                        {
                            try { WriteHandle(target, before); mayRemoveCheckpoint = true; }
                            catch { throw Violation("A failed write could not be restored. The original image remains in " + checkpoint); }
                            throw;
                        }
                    }
                    finally
                    {
                        saved.Dispose();
                        // A flushed success or restored old image is complete.
                        // Cleanup must never report an otherwise durable save
                        // as failed and roll back only the memory image.
                        if (mayRemoveCheckpoint) { try { DeleteFile(checkpoint); } catch { } }
                    }
                }
            }
        }
        public void DeleteFile(string path)
        {
            lock (sync)
            {
                CheckWritable(); string full = AssertPath(path); PrepareMutation(full); if (!Exists(full)) return;
                using (SafeFileHandle handle = OpenFile(full, GenericWrite, OpenExistingFile, ShareRead))
                {
                    IntPtr buffer = Marshal.AllocHGlobal(4);
                    try { Marshal.WriteInt32(buffer, 1); if (!SetFileInformationByHandle(handle, 4, buffer, 4)) throw NativeError("Cannot delete a test-owned file"); }
                    finally { Marshal.FreeHGlobal(buffer); }
                }
            }
        }
        public void Dispose()
        {
            lock (sync)
            {
                if (disposed) return;
                disposed = true;
                foreach (LockLease lease in new List<LockLease>(locks.Values)) lease.Dispose();
                foreach (FilePin pin in files.Values) pin.Handle.Dispose();
                files.Clear(); writers.Clear();
                List<SafeFileHandle> handles = new List<SafeFileHandle>(directories.Values);
                handles.Reverse(); foreach (SafeFileHandle handle in handles) handle.Dispose();
                directories.Clear();
            }
        }
    }
}
