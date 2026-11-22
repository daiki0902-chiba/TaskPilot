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
        private readonly Dictionary<string, DatabasePin> databases = new Dictionary<string, DatabasePin>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, LockLease> locks = new Dictionary<string, LockLease>(StringComparer.OrdinalIgnoreCase);
        private bool disposed, faulted, readOnly;
        private string faultReason;
        private string ownerSid;
        private string defaultOwnerSid;

        private sealed class FilePin
        {
            internal SafeFileHandle Handle;
            internal int ManualCount, DatabaseCount;
        }
        private sealed class DatabasePin
        {
            internal int Count;
            internal string Journal;
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
            return OpenCore(profileRoot, environmentId, true);
        }
        public static Sandbox OpenExisting(string profileRoot, string environmentId)
        {
            return OpenCore(profileRoot, environmentId, false);
        }
        private static Sandbox OpenCore(string profileRoot, string environmentId, bool initialize)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("Independent test mode requires native 64-bit Windows.");
            if (environmentId == null || !Regex.IsMatch(environmentId, "\\A[a-f0-9]{32}\\z"))
                throw new ArgumentException("TestEnvironmentId must be exactly 32 lowercase hexadecimal characters.");
            Sandbox context = new Sandbox();
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
                context.Root = Path.Combine(context.ProfileRoot, "TaskPilotTest", environmentId);
                context.MarkerPath = Path.Combine(context.Root, ".taskpilot-test-environment");
                context.LockPath = Path.Combine(context.Root, "test.storage.lock");
                context.PinDirectoryChain(context.ProfileRoot, false);
                context.PinDirectoryChain(Path.Combine(context.ProfileRoot, "TaskPilotTest"), initialize);
                bool existed = context.TryPinDirectory(context.Root);
                if (!existed)
                {
                    if (!initialize) throw new DirectoryNotFoundException("The existing test environment was not found.");
                    context.PinDirectoryChain(context.Root, true);
                }
                string marker = "TaskPilot independent test environment v1\n" + environmentId + "\n";
                if (context.Exists(context.MarkerPath))
                {
                    if (!String.Equals(context.ReadAllText(context.MarkerPath), marker, StringComparison.Ordinal))
                        throw context.Violation("The test environment identity marker does not match its directory.");
                }
                else
                {
                    if (!initialize) throw context.Violation("The existing test environment has no identity marker.");
                    // An existing nonempty directory is never silently adopted.
                    if (existed && new DirectoryInfo(context.Root).GetFileSystemInfos().Length != 0)
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

        private Sandbox() { }
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
        private SafeFileHandle OpenFile(string path, uint access, uint disposition, uint share)
        {
            SafeFileHandle handle = CreateFileW(path, access | ReadAttributes, share, IntPtr.Zero, disposition, OpenReparsePoint, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw NativeError("Cannot open test file " + path); }
            try { Information(handle, path, false); return handle; }
            catch { handle.Dispose(); throw; }
        }
        private bool TryPinDirectory(string path)
        {
            SafeFileHandle pinned;
            if (directories.TryGetValue(path, out pinned)) { Information(pinned, path, true); VerifyDirectoryPolicy(path, pinned); return true; }
            // A list-directory lease participates in delete sharing. Directory
            // attribute changes require a separate ACL rule: metadata access
            // is not mediated by FILE_SHARE_WRITE.
            // FILE_LIST_DIRECTORY participates in Windows sharing checks;
            // FILE_READ_ATTRIBUTES alone does not establish a sharing lease.
            uint access = ReadAttributes | 1 | 0x20;
            if (RequiresDirectoryPolicy(path)) access |= 0x20000 | 2 | 4;
            else if (String.Equals(path, ProfileRoot, StringComparison.OrdinalIgnoreCase)) access |= 4;
            SafeFileHandle handle = CreateFileW(path, access, ShareReadWrite, IntPtr.Zero, OpenExistingFile, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int code = Marshal.GetLastWin32Error(); handle.Dispose();
                if (code == 2 || code == 3) return false;
                throw new IOException("Cannot pin test directory: " + path, new Win32Exception(code));
            }
            try { Information(handle, path, true); VerifyDirectoryPolicy(path, handle); directories.Add(path, handle); return true; }
            catch { handle.Dispose(); throw; }
        }
        private bool RequiresDirectoryPolicy(string path)
        {
            if (ProfileRoot == null) return false;
            string home = Path.Combine(ProfileRoot, "TaskPilotTest");
            return String.Equals(path, home, StringComparison.OrdinalIgnoreCase) || path.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase);
        }
        private byte[] NewDirectoryPolicy()
        {
            // Only newly created test directories receive this policy. Files
            // inherit normal owner access; the denials inherit to containers.
            string sddl = "O:" + ownerSid + "D:P(D;CI;0x100;;;S-1-1-0)(D;CI;0xc0000;;;S-1-3-4)(A;OICI;FA;;;" + ownerSid + ")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(sddl);
            byte[] bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0); return bytes;
        }
        private void VerifyDirectoryPolicy(string path, SafeFileHandle handle)
        {
            if (!RequiresDirectoryPolicy(path)) return;
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(handle.DangerousGetHandle(), 1, 5, out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new IOException("Cannot inspect test-directory protection.", new Win32Exception(unchecked((int)error)));
            try
            {
                uint size = GetSecurityDescriptorLength(descriptor);
                if (size == 0 || size > 1048576) throw Violation("Invalid test-directory security descriptor.");
                byte[] bytes = new byte[size]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                RawSecurityDescriptor policy = new RawSecurityDescriptor(bytes, 0);
                bool anchor = String.Equals(path, Path.Combine(ProfileRoot, "TaskPilotTest"), StringComparison.OrdinalIgnoreCase);
                // The anchor is protected against inherited weakening. Child
                // directories inherit both deny rules atomically; their owner
                // cannot disable that inheritance because WRITE_DAC is denied.
                if (policy.Owner == null || (policy.Owner.Value != ownerSid && policy.Owner.Value != defaultOwnerSid) || policy.DiscretionaryAcl == null || (anchor && (policy.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0))
                    throw Violation("An existing test directory does not have the required protected policy. It will not be modified or adopted.");
                bool attributesDenied = false, ownerChangeDenied = false;
                foreach (GenericAce raw in policy.DiscretionaryAcl)
                {
                    CommonAce ace = raw as CommonAce;
                    if (ace == null || ace.AceQualifier != AceQualifier.AccessDenied || (ace.AceFlags & AceFlags.InheritOnly) != 0 || (ace.AceFlags & AceFlags.ContainerInherit) == 0) continue;
                    if (ace.SecurityIdentifier.Value == "S-1-1-0" && (ace.AccessMask & 0x100) == 0x100) attributesDenied = true;
                    if (ace.SecurityIdentifier.Value == "S-1-3-4" && (ace.AccessMask & 0xc0000) == 0xc0000) ownerChangeDenied = true;
                }
                if (!attributesDenied || !ownerChangeDenied) throw Violation("Test-directory attribute/owner protection is missing. No policy was changed.");
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }
        private void CreateProtectedDirectory(string path)
        {
            string parent = Path.GetDirectoryName(path), leaf = Path.GetFileName(path);
            SafeFileHandle parentHandle;
            if (!directories.TryGetValue(parent, out parentHandle)) throw new IOException("The test directory parent is not pinned.");
            byte[] security = NewDirectoryPolicy();
            IntPtr securityMemory = Marshal.AllocHGlobal(security.Length), nameMemory = Marshal.StringToHGlobalUni(leaf), unicodeMemory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
            SafeFileHandle created = null;
            try
            {
                Marshal.Copy(security, 0, securityMemory, security.Length);
                UnicodeString name = new UnicodeString(); name.Length = checked((ushort)(leaf.Length * 2)); name.MaximumLength = checked((ushort)(name.Length + 2)); name.Buffer = nameMemory;
                Marshal.StructureToPtr(name, unicodeMemory, false);
                ObjectAttributes attributes = new ObjectAttributes(); attributes.Length = Marshal.SizeOf(typeof(ObjectAttributes)); attributes.RootDirectory = parentHandle.DangerousGetHandle(); attributes.ObjectName = unicodeMemory;
                attributes.Attributes = 0x40 | 0x1000;
                attributes.SecurityDescriptor = RequiresDirectoryPolicy(parent) ? IntPtr.Zero : securityMemory;
                IoStatusBlock result;
                int status = NtCreateFile(out created, 0x100000 | 0x20000 | ReadAttributes | 1 | 2 | 4 | 0x20, ref attributes, out result, IntPtr.Zero, DirectoryAttribute, ShareReadWrite, 2, 1 | 0x20 | OpenReparsePoint, IntPtr.Zero, 0);
                if (status < 0)
                {
                    int error = unchecked((int)RtlNtStatusToDosError(status));
                    if (error == 183) { if (!TryPinDirectory(path)) throw new DirectoryNotFoundException(path); return; }
                    throw new IOException("Cannot create protected test directory: " + path + ": " + new Win32Exception(error).Message + " (" + error.ToString() + ", NT=" + status.ToString("X8") + ")", new Win32Exception(error));
                }
                Information(created, path, true); VerifyDirectoryPolicy(path, created); directories.Add(path, created); created = null;
            }
            finally { if (created != null) created.Dispose(); Marshal.FreeHGlobal(unicodeMemory); Marshal.FreeHGlobal(nameMemory); Marshal.FreeHGlobal(securityMemory); }
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
            string parent = Path.GetDirectoryName(full);
            if (String.Equals(full, Root, StringComparison.OrdinalIgnoreCase)) return;
            PinDirectoryChain(parent, false);
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
                string full = Confine(path);
                if (directories.ContainsKey(full) || files.ContainsKey(full) || locks.ContainsKey(full)) return true;
                try { PinParent(full); }
                catch (DirectoryNotFoundException) { return false; }
                SafeFileHandle handle = CreateFileW(full, ReadAttributes, ShareReadWrite, IntPtr.Zero, OpenExistingFile, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
                if (handle.IsInvalid)
                {
                    int code = Marshal.GetLastWin32Error(); handle.Dispose();
                    if (code == 2 || code == 3) return false;
                    throw new IOException("Cannot inspect test path: " + full, new Win32Exception(code));
                }
                using (handle)
                {
                    FileInformation raw;
                    if (!GetFileInformationByHandle(handle, out raw)) throw NativeError("Cannot inspect test entry");
                    bool isDirectory = (raw.Attributes & DirectoryAttribute) != 0;
                    Information(handle, full, isDirectory);
                }
                return true;
            }
        }
        public void ValidateTree()
        {
            lock (sync)
            {
                CheckLive();
                Stack<string> pending = new Stack<string>(); pending.Push(Root);
                int count = 0;
                while (pending.Count != 0)
                {
                    string directory = pending.Pop(); PinDirectoryChain(directory, false);
                    foreach (FileSystemInfo entry in new DirectoryInfo(directory).GetFileSystemInfos())
                    {
                        if (++count > 100000) throw Violation("The test environment exceeds its validation entry limit.");
                        string full = Confine(entry.FullName);
                        if (locks.ContainsKey(full)) { Information(locks[full].Handle, full, false); continue; }
                        if (files.ContainsKey(full)) { Information(files[full].Handle, full, false); continue; }
                        // Attributes are read only inside pinned directories; never follow entries.
                        if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) throw Violation("Test environment contains a link: " + full);
                        if ((entry.Attributes & FileAttributes.Directory) != 0) { PinDirectoryChain(full, false); pending.Push(full); }
                        else { using (SafeFileHandle file = OpenFile(full, ReadAttributes, OpenExistingFile, ShareReadWrite)) { } }
                    }
                }
            }
        }
        public long GetFileLength(string path)
        {
            lock (sync)
            {
                string full = AssertPath(path);
                FilePin pin; LockLease lease;
                if (files.TryGetValue(full, out pin)) return Length(Information(pin.Handle, full, false));
                if (locks.TryGetValue(full, out lease)) return Length(Information(lease.Handle, full, false));
                using (SafeFileHandle file = OpenFile(full, ReadAttributes, OpenExistingFile, ShareReadWrite)) return Length(Information(file, full, false));
            }
        }
        public void CheckExistingFile(string path)
        {
            lock (sync)
            {
                string full = AssertPath(path);
                FilePin pin; LockLease lease;
                if (files.TryGetValue(full, out pin)) { Information(pin.Handle, full, false); return; }
                if (locks.TryGetValue(full, out lease)) { Information(lease.Handle, full, false); return; }
                using (SafeFileHandle file = OpenFile(full, ReadAttributes, OpenExistingFile, ShareReadWrite)) { }
            }
        }
        private static long Length(FileInformation info) { return ((long)info.FileSizeHigh << 32) | info.FileSizeLow; }
        public byte[] ReadPrefix(string path, int count)
        {
            if (count < 0 || count > 268435456) throw new ArgumentOutOfRangeException("count");
            lock (sync)
            {
                string full = AssertPath(path);
                using (SafeFileHandle handle = OpenFile(full, GenericRead, OpenExistingFile, ShareReadWrite))
                using (FileStream stream = new FileStream(handle, FileAccess.Read, 65536, false))
                {
                    int wanted = (int)Math.Min((long)count, stream.Length);
                    byte[] data = new byte[wanted]; int offset = 0;
                    while (offset < data.Length) { int read = stream.Read(data, offset, data.Length - offset); if (read == 0) throw new IOException("Test file changed during read."); offset += read; }
                    return data;
                }
            }
        }
        public byte[] ReadAllBytes(string path)
        {
            lock (sync)
            {
                string full = AssertPath(path);
                using (SafeFileHandle handle = OpenFile(full, GenericRead, OpenExistingFile, ShareReadWrite))
                using (FileStream stream = new FileStream(handle, FileAccess.Read, 65536, false))
                {
                    if (stream.Length > 268435456) throw new IOException("Test file exceeds the 256 MiB read limit.");
                    byte[] data = new byte[(int)stream.Length]; int offset = 0;
                    while (offset < data.Length) { int read = stream.Read(data, offset, data.Length - offset); if (read == 0) throw new IOException("Test file changed during read."); offset += read; }
                    return data;
                }
            }
        }
        public string ReadAllText(string path)
        {
            byte[] data = ReadAllBytes(path);
            int offset = data.Length >= 3 && data[0] == 239 && data[1] == 187 && data[2] == 191 ? 3 : 0;
            return new UTF8Encoding(false, true).GetString(data, offset, data.Length - offset);
        }
        public void WriteNew(string path, byte[] data)
        {
            if (data == null) throw new ArgumentNullException("data");
            lock (sync)
            {
                CheckWritable();
                string full = AssertPath(path);
                using (SafeFileHandle handle = OpenFile(full, GenericWrite, CreateNew, ShareReadWrite))
                using (FileStream stream = new FileStream(handle, FileAccess.Write, 65536, false)) { stream.Write(data, 0, data.Length); stream.Flush(true); }
            }
        }
        public void AppendText(string path, string text)
        {
            lock (sync)
            {
                CheckWritable();
                string full = AssertPath(path);
                using (SafeFileHandle handle = OpenFile(full, GenericWrite, OpenAlways, ShareReadWrite))
                using (FileStream stream = new FileStream(handle, FileAccess.Write, 65536, false))
                {
                    stream.Seek(0, SeekOrigin.End);
                    byte[] data = new UTF8Encoding(false, true).GetBytes(text);
                    stream.Write(data, 0, data.Length); stream.Flush(true);
                }
            }
        }
        private FilePin GetOrCreatePin(string full, bool create)
        {
            FilePin pin;
            if (files.TryGetValue(full, out pin)) { Information(pin.Handle, full, false); return pin; }
            // Read-data access is necessary for a persistent sharing lease;
            // metadata-only handles do not prevent a pathname replacement.
            pin = new FilePin(); pin.Handle = OpenFile(full, ReadAttributes | 1, create ? OpenAlways : OpenExistingFile, ShareReadWrite);
            files.Add(full, pin); return pin;
        }
        private void RemoveUnusedPin(string full, FilePin pin)
        {
            if (pin.ManualCount == 0 && pin.DatabaseCount == 0) { pin.Handle.Dispose(); files.Remove(full); }
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
                if (disposed) return;
                // Cleanup after a fault may release existing handles, but never opens a path.
                string full = Path.GetFullPath(path).TrimEnd('\\');
                FilePin pin;
                if (files.TryGetValue(full, out pin)) { pin.ManualCount = 0; RemoveUnusedPin(full, pin); }
            }
        }
        public IDisposable AcquireLock(string path)
        {
            lock (sync)
            {
                CheckWritable();
                string full = AssertPath(path);
                if (locks.ContainsKey(full)) throw new IOException("This test lock is already held.");
                SafeFileHandle handle = OpenFile(full, GenericRead | GenericWrite, OpenAlways, 0);
                LockLease lease = new LockLease(this, full, handle); locks.Add(full, lease); return lease;
            }
        }
        public void PrepareDatabase(string path, bool create)
        {
            lock (sync)
            {
                CheckWritable();
                string full = AssertPath(path); DatabasePin active;
                if (databases.TryGetValue(full, out active)) { active.Count++; return; }
                if (Exists(full + "-wal") || Exists(full + "-shm")) throw new IOException("WAL/SHM recovery files are not adopted in independent test mode. Preserve the test environment and use a verified test backup.");
                string journal = full + "-journal";
                FilePin database = null, journalPin = null;
                try
                {
                    database = GetOrCreatePin(full, create); database.DatabaseCount++;
                    journalPin = GetOrCreatePin(journal, true); journalPin.DatabaseCount++;
                    if (Length(Information(journalPin.Handle, journal, false)) != 0)
                        throw new IOException("A nonempty test recovery journal must be preserved. Automatic recovery is disabled in independent test mode.");
                    active = new DatabasePin(); active.Count = 1; active.Journal = journal; databases.Add(full, active);
                }
                catch
                {
                    if (journalPin != null) { journalPin.DatabaseCount--; RemoveUnusedPin(journal, journalPin); }
                    if (database != null) { database.DatabaseCount--; RemoveUnusedPin(full, database); }
                    throw;
                }
            }
        }
        public void PinDatabase(string path, bool create) { PrepareDatabase(path, create); }
        public void CompleteDatabase(string path)
        {
            lock (sync)
            {
                if (disposed) return;
                string full = Path.GetFullPath(path).TrimEnd('\\'); DatabasePin active;
                if (!databases.TryGetValue(full, out active)) return;
                if (--active.Count > 0) return;
                databases.Remove(full);
                FilePin database, journal;
                if (files.TryGetValue(full, out database)) { database.DatabaseCount--; RemoveUnusedPin(full, database); }
                bool removeJournal = false;
                if (files.TryGetValue(active.Journal, out journal))
                {
                    if (!faulted) removeJournal = Length(Information(journal.Handle, active.Journal, false)) == 0;
                    journal.DatabaseCount--; RemoveUnusedPin(active.Journal, journal);
                }
                if (removeJournal && !files.ContainsKey(active.Journal) && !faulted) DeleteFile(active.Journal);
            }
        }
        private void PrepareMutation(string full)
        {
            DatabasePin active;
            if (databases.TryGetValue(full, out active)) throw new IOException("A test database cannot be renamed/deleted while a connection lease is active.");
            FilePin pin;
            if (files.TryGetValue(full, out pin))
            {
                if (pin.DatabaseCount != 0) throw new IOException("A test file is in use by SQLite.");
                pin.Handle.Dispose(); files.Remove(full);
            }
            if (locks.ContainsKey(full)) throw new IOException("A held test lock cannot be renamed or deleted.");
        }
        private void RenameHandle(string source, string destination, bool replace)
        {
            string from = AssertPath(source), to = AssertPath(destination);
            if (String.Equals(from, to, StringComparison.OrdinalIgnoreCase)) throw new IOException("Source and destination must differ.");
            PrepareMutation(from); PrepareMutation(to);
            using (SafeFileHandle handle = OpenFile(from, DeleteAccess, OpenExistingFile, ShareReadWrite))
            {
                string parent = Path.GetDirectoryName(to), leaf = Path.GetFileName(to);
                SafeFileHandle targetDirectory = directories[parent];
                byte[] name = Encoding.Unicode.GetBytes(leaf);
                IntPtr buffer = Marshal.AllocHGlobal(20 + name.Length);
                try
                {
                    for (int i = 0; i < 20 + name.Length; i++) Marshal.WriteByte(buffer, i, 0);
                    Marshal.WriteInt32(buffer, 0, replace ? 1 : 0);
                    Marshal.WriteIntPtr(buffer, 8, targetDirectory.DangerousGetHandle());
                    Marshal.WriteInt32(buffer, 16, name.Length); Marshal.Copy(name, 0, IntPtr.Add(buffer, 20), name.Length);
                    // Use the native relative-directory contract directly;
                    // the Win32 wrapper rejects this form on Server 2022.
                    IoStatusBlock result;
                    int status = NtSetInformationFile(handle, out result, buffer, (uint)(20 + name.Length), 10);
                    if (status < 0) { int code = unchecked((int)RtlNtStatusToDosError(status)); throw new IOException("Cannot atomically rename a test file: " + new Win32Exception(code).Message + " (" + code.ToString() + ")", new Win32Exception(code)); }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        public void MoveNew(string source, string destination)
        {
            lock (sync) { CheckWritable(); RenameHandle(source, destination, false); }
        }
        public void Replace(string source, string destination, string backup)
        {
            lock (sync)
            {
                CheckWritable();
                string from = AssertPath(source), to = AssertPath(destination);
                if (!Exists(to)) { MoveNew(from, to); return; }
                if (!String.IsNullOrEmpty(backup))
                {
                    string previous = AssertPath(backup);
                    if (String.Equals(previous, from, StringComparison.OrdinalIgnoreCase) || String.Equals(previous, to, StringComparison.OrdinalIgnoreCase)) throw new IOException("Backup path must be a distinct new test file.");
                    WriteNew(previous, ReadAllBytes(to));
                }
                RenameHandle(from, to, true);
            }
        }
        public void AtomicWrite(string path, byte[] data, string previousPath)
        {
            lock (sync)
            {
                CheckWritable();
                string full = AssertPath(path);
                string stage = Path.Combine(Path.GetDirectoryName(full), ".atomic_" + Guid.NewGuid().ToString("N") + ".tmp");
                WriteNew(stage, data);
                // Keep any failed stage for diagnosis, rather than deleting unknown state.
                if (Exists(full)) Replace(stage, full, previousPath); else MoveNew(stage, full);
            }
        }
        public void DeleteFile(string path)
        {
            lock (sync)
            {
                CheckWritable();
                string full = AssertPath(path); PrepareMutation(full);
                if (!Exists(full)) return;
                using (SafeFileHandle handle = OpenFile(full, DeleteAccess, OpenExistingFile, ShareReadWrite))
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
                files.Clear(); databases.Clear();
                List<SafeFileHandle> handles = new List<SafeFileHandle>(directories.Values);
                handles.Reverse(); foreach (SafeFileHandle handle in handles) handle.Dispose();
                directories.Clear();
            }
        }
    }
}
