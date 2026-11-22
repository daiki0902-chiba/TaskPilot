// Compile into TaskPilot.Acceptance.exe. Never load this guard from an external
// assembly at startup: it is the bootstrap used before reading package scripts.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace TaskPilot.Acceptance
{
    public sealed class PackageLease : IDisposable
    {
        private readonly Dictionary<string, SafeFileHandle> dirs = new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, SafeFileHandle> files = new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
        private readonly object sync = new object();
        private bool disposed;
        public string Root { get; private set; }
        public string[] Paths { get { lock (sync) { Live(); string[] result = new string[files.Count]; files.Keys.CopyTo(result, 0); Array.Sort(result, StringComparer.OrdinalIgnoreCase); return result; } } }
        [StructLayout(LayoutKind.Sequential)] private struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write; public uint Volume, High, Low, Links, IndexHigh, IndexLow; }
        [StructLayout(LayoutKind.Sequential)] private struct IoStatus { public IntPtr Status; public UIntPtr Information; }
        [StructLayout(LayoutKind.Sequential)] private struct Unicode { public ushort Length, MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)] private struct Objects { public int Length; public IntPtr Parent, Name; public uint Flags; public IntPtr Security, Quality; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info information);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, IntPtr information, uint length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
        [DllImport("ntdll.dll")] private static extern int NtCreateFile(out SafeFileHandle handle, uint access, ref Objects attributes, out IoStatus status, IntPtr allocation, uint fileAttributes, uint share, uint disposition, uint options, IntPtr ea, uint eaLength);
        [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern uint GetSecurityInfo(IntPtr handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll")] private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        private PackageLease() { }
        private static IOException Block() { return new IOException("TP-ACCEPTANCE-PACKAGE-BOUNDARY"); }
        private void Live() { if (disposed) throw new ObjectDisposedException("Acceptance package lease"); }
        private static string Normalize(string value)
        {
            if (String.IsNullOrWhiteSpace(value) || value.Length < 4 || !Char.IsLetter(value[0]) || value[1] != ':' || value[2] != '\\' || value.IndexOf('/') >= 0 || value.IndexOf('%') >= 0 || value.IndexOf(':', 2) >= 0 || value.IndexOf('\0') >= 0) throw Block();
            string result = value.TrimEnd('\\');
            foreach (string part in result.Substring(3).Split('\\')) ValidateLeaf(part);
            if (!String.Equals(Path.GetFullPath(result), result, StringComparison.OrdinalIgnoreCase)) throw Block();
            return result;
        }
        private static void ValidateLeaf(string part)
        {
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal) || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Regex.IsMatch(part, "\\A(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|\\z)")) throw Block();
        }
        private string Relative(string value)
        {
            if (String.IsNullOrWhiteSpace(value) || value[0] == '/' || value.IndexOf('\\') >= 0 || value.IndexOf(':') >= 0 || value.IndexOf('%') >= 0) throw Block();
            foreach (string part in value.Split('/')) ValidateLeaf(part);
            return value;
        }
        public string FullPath(string relative) { lock (sync) { Live(); return Path.Combine(Root, Relative(relative).Replace('/', '\\')); } }
        private Info Inspect(SafeFileHandle handle, string path, bool directory)
        {
            Info info;
            if (!GetFileInformationByHandle(handle, out info) || (info.Attributes & 0x400) != 0 || ((info.Attributes & 0x10) != 0) != directory || (!directory && info.Links != 1)) throw Block();
            StringBuilder actual = new StringBuilder(32768);
            uint count = GetFinalPathNameByHandleW(handle, actual, (uint)actual.Capacity, 0);
            if (count == 0 || count >= actual.Capacity) throw Block();
            string final = actual.ToString(); if (final.StartsWith("\\\\?\\", StringComparison.Ordinal)) final = final.Substring(4);
            if (!String.Equals(final.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) throw Block();
            return info;
        }
        private SafeFileHandle Child(string parent, string leaf, bool directory, bool stream)
        {
            SafeFileHandle parentHandle;
            if (!dirs.TryGetValue(parent, out parentHandle)) throw Block();
            Inspect(parentHandle, parent, true);
            IntPtr name = Marshal.StringToHGlobalUni(leaf), text = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Unicode)));
            SafeFileHandle handle = null;
            try
            {
                Unicode unicode = new Unicode { Length = checked((ushort)(leaf.Length * 2)), MaximumLength = checked((ushort)(leaf.Length * 2 + 2)), Buffer = name };
                Marshal.StructureToPtr(unicode, text, false);
                Objects objects = new Objects { Length = Marshal.SizeOf(typeof(Objects)), Parent = parentHandle.DangerousGetHandle(), Name = text, Flags = 0x40 | 0x1000 };
                IoStatus status;
                // All opens are relative, no reparse traversal, read-only and no
                // delete sharing. File leases also exclude existing/future writers.
                int result = NtCreateFile(out handle, 0x100000 | 0x20000 | 0x80 | 1, ref objects, out status, IntPtr.Zero, 0, directory ? 3u : 1u, 1, 0x20 | 0x00200000 | (directory ? 1u : 0x40u), IntPtr.Zero, 0);
                if (result < 0) { if (handle != null) handle.Dispose(); handle = null; throw new IOException("TP-ACCEPTANCE-PACKAGE-OPEN", new Win32Exception(unchecked((int)RtlNtStatusToDosError(result)))); }
                if (!stream) Inspect(handle, Path.Combine(parent, leaf), directory);
                SafeFileHandle answer = handle; handle = null; return answer;
            }
            finally { if (handle != null) handle.Dispose(); Marshal.FreeHGlobal(text); Marshal.FreeHGlobal(name); }
        }
        // The package installer must apply this policy only to its newly-created
        // tree. A checker never rewrites ACLs, attributes or origin streams.
        private static void InspectPolicy(SafeFileHandle handle, bool directory)
        {
            IntPtr owner, group, dacl, sacl, descriptor;
            if (GetSecurityInfo(handle.DangerousGetHandle(), 1, 4, out owner, out group, out dacl, out sacl, out descriptor) != 0) throw Block();
            try
            {
                uint length = GetSecurityDescriptorLength(descriptor);
                if (length == 0 || length > 1048576) throw Block();
                byte[] bytes = new byte[length]; Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                RawSecurityDescriptor policy = new RawSecurityDescriptor(bytes, 0);
                if (policy.DiscretionaryAcl == null) throw Block();
                bool attributeDeny = false, ownerDeny = false;
                foreach (GenericAce raw in policy.DiscretionaryAcl)
                {
                    CommonAce ace = raw as CommonAce;
                    if (ace == null || ace.IsCallback) throw Block();
                    if ((ace.AceFlags & AceFlags.InheritOnly) != 0) continue;
                    if (ace.AceQualifier == AceQualifier.AccessAllowed && (!attributeDeny || !ownerDeny)) throw Block();
                    if (ace.AceQualifier != AceQualifier.AccessDenied) continue;
                    if (directory && (ace.AceFlags & (AceFlags.ContainerInherit | AceFlags.ObjectInherit)) != (AceFlags.ContainerInherit | AceFlags.ObjectInherit)) continue;
                    if (ace.SecurityIdentifier.Value == "S-1-1-0" && (ace.AccessMask & 0x110) == 0x110) attributeDeny = true;
                    if (ace.SecurityIdentifier.Value == "S-1-3-4" && (ace.AccessMask & 0xc0000) == 0xc0000) ownerDeny = true;
                }
                if (!attributeDeny || !ownerDeny) throw Block();
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }
        public static PackageLease Open(string packageRoot)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8) throw new PlatformNotSupportedException("TP-ACCEPTANCE-WINDOWS-X64-REQUIRED");
            PackageLease lease = new PackageLease();
            try
            {
                lease.Root = Normalize(packageRoot);
                string drive = Path.GetPathRoot(lease.Root);
                DriveInfo volume = new DriveInfo(drive);
                if (volume.DriveType != DriveType.Fixed || !String.Equals(volume.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase)) throw Block();
                SafeFileHandle root = CreateFileW(drive, 0x80 | 1, 3, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
                if (root.IsInvalid) { root.Dispose(); throw Block(); }
                lease.Inspect(root, drive, true); lease.dirs.Add(drive, root);
                string parent = drive;
                foreach (string leaf in lease.Root.Substring(3).Split('\\')) { string next = Path.Combine(parent, leaf); SafeFileHandle handle = lease.Child(parent, leaf, true, false); lease.dirs.Add(next, handle); parent = next; }
                // Do not enumerate the tree before the purpose grant has been
                // authenticated. Only explicitly requested bootstrap files are
                // opened; unknown neighboring files are never read as content.
                lease.InspectPolicyRoot(); lease.AssertPinned("TaskPilot.Acceptance.exe");
                return lease;
            }
            catch { lease.Dispose(); throw; }
        }
        private void InspectPolicyRoot() { InspectPolicy(dirs[Root], true); }
        private void Walk(string path, int depth, HashSet<string> expected, HashSet<string> observed)
        {
            if (depth > 32 || files.Count + dirs.Count > 2048) throw Block();
            SafeFileHandle directory = dirs[path];
            IntPtr buffer = Marshal.AllocHGlobal(65536);
            bool any = false, restart = true;
            try
            {
                while (true)
                {
                    if (!GetFileInformationByHandleEx(directory, restart ? 11 : 10, buffer, 65536))
                    {
                        int code = Marshal.GetLastWin32Error(); if (code == 18) break; throw Block();
                    }
                    restart = false; int offset = 0;
                    while (true)
                    {
                        IntPtr entry = IntPtr.Add(buffer, offset);
                        int next = Marshal.ReadInt32(entry, 0), attributes = Marshal.ReadInt32(entry, 56), byteLength = Marshal.ReadInt32(entry, 60);
                        if (byteLength < 0 || byteLength % 2 != 0 || offset + 104 + byteLength > 65536) throw Block();
                        string leaf = Marshal.PtrToStringUni(IntPtr.Add(entry, 104), byteLength / 2);
                        if (leaf != "." && leaf != "..")
                        {
                            ValidateLeaf(leaf); any = true;
                            if ((attributes & 0x400) != 0) throw Block();
                            string child = Path.Combine(path, leaf); bool isDirectory = (attributes & 0x10) != 0;
                            string relative = child.Substring(Root.Length + 1).Replace('\\', '/');
                            if (isDirectory)
                            {
                                bool declared = false;
                                foreach (string candidate in expected) if (candidate.StartsWith(relative + "/", StringComparison.OrdinalIgnoreCase)) { declared = true; break; }
                                if (!declared || !dirs.ContainsKey(child)) throw Block();
                                Walk(child, depth + 1, expected, observed);
                            }
                            else
                            {
                                if (!expected.Contains(relative) || !files.ContainsKey(relative) || !observed.Add(relative)) throw Block();
                                Pinned(relative);
                            }
                        }
                        if (next == 0) break;
                        if (next < 104 || next > 65536 - offset) throw Block(); offset += next;
                    }
                }
                // Pinned leaf files keep each directory nonempty, excluding
                // in-place mountpoint/directory-symlink reparse installation.
                if (!any) throw Block();
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        private SafeFileHandle Pinned(string relative)
        {
            Live(); string key = Relative(relative); SafeFileHandle handle;
            if (!files.TryGetValue(key, out handle))
            {
                string[] components = key.Split('/'); string parent = Root;
                for (int index = 0; index < components.Length - 1; index++)
                {
                    string next = Path.Combine(parent, components[index]);
                    if (!dirs.ContainsKey(next))
                    {
                        SafeFileHandle directory = Child(parent, components[index], true, false);
                        try { InspectPolicy(directory, true); } catch { directory.Dispose(); throw; }
                        dirs.Add(next, directory);
                    }
                    parent = next;
                }
                handle = Child(parent, components[components.Length - 1], false, false);
                try { InspectPolicy(handle, false); } catch { handle.Dispose(); throw; }
                files.Add(key, handle);
                if (files.Count + dirs.Count > 2048) throw Block();
            }
            Inspect(handle, Path.Combine(Root, key.Replace('/', '\\')), false); InspectPolicy(handle, false);
            return handle;
        }
        public void AssertPinned(string relative) { lock (sync) { Pinned(relative); } }
        public void AssertInventory(string[] expectedPaths)
        {
            lock (sync)
            {
                Live(); if (expectedPaths == null || expectedPaths.Length > 2048) throw Block();
                HashSet<string> expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase), observed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (string path in expectedPaths) { if (!expected.Add(Relative(path))) throw Block(); Pinned(path); }
                Walk(Root, 0, expected, observed);
                if (observed.Count != expected.Count || files.Count != expected.Count) throw Block();
            }
        }
        private static byte[] Read(SafeFileHandle handle, int maximum)
        {
            if (maximum < 0 || maximum > 268435456) throw Block();
            using (SafeFileHandle borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
            using (FileStream stream = new FileStream(borrowed, FileAccess.Read, 65536, false))
            {
                if (stream.Length > maximum) throw Block(); stream.Seek(0, SeekOrigin.Begin);
                byte[] result = new byte[(int)stream.Length]; int used = 0;
                while (used < result.Length) { int read = stream.Read(result, used, result.Length - used); if (read == 0) throw Block(); used += read; }
                return result;
            }
        }
        public byte[] ReadBytes(string relative, int maximum) { lock (sync) { return Read(Pinned(relative), maximum); } }
        public string ReadText(string relative, int maximum)
        {
            byte[] bytes = ReadBytes(relative, maximum); int offset = bytes.Length >= 3 && bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191 ? 3 : 0;
            return new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset);
        }
        public string Sha256(string relative)
        {
            lock (sync)
            {
                SafeFileHandle handle = Pinned(relative);
                using (SafeFileHandle borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
                using (FileStream stream = new FileStream(borrowed, FileAccess.Read, 65536, false))
                using (SHA256 digest = SHA256.Create()) { if (stream.Length > 268435456) throw Block(); stream.Seek(0, SeekOrigin.Begin); return BitConverter.ToString(digest.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(); }
            }
        }
        public bool HasInternetZone(string relative)
        {
            lock (sync)
            {
                string path = FullPath(relative); Pinned(relative);
                try
                {
                    // Open the stream relative to its pinned parent, after the
                    // primary file identity/link policy has been checked.
                    using (SafeFileHandle stream = Child(Path.GetDirectoryName(path), Path.GetFileName(path) + ":Zone.Identifier", false, true))
                    {
                        string text = new UTF8Encoding(false, true).GetString(Read(stream, 4096));
                        Match match = Regex.Match(text, "(?m)^ZoneId=([0-9]+)\\s*$");
                        int zone; return !match.Success || !Int32.TryParse(match.Groups[1].Value, out zone) || zone < 0 || zone > 2;
                    }
                }
                catch (IOException failure)
                {
                    Win32Exception native = failure.InnerException as Win32Exception;
                    if (native != null && (native.NativeErrorCode == 2 || native.NativeErrorCode == 3)) return false;
                    throw;
                }
            }
        }
        public void Dispose()
        {
            lock (sync)
            {
                if (disposed) return; disposed = true;
                foreach (SafeFileHandle handle in files.Values) handle.Dispose(); files.Clear();
                List<SafeFileHandle> handles = new List<SafeFileHandle>(dirs.Values); handles.Reverse(); foreach (SafeFileHandle handle in handles) handle.Dispose(); dirs.Clear();
            }
        }
    }
}
