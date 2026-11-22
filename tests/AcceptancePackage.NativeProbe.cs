using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace TaskPilot.AcceptanceBoundaryTests {
    public sealed class ProbeResult {
        public bool HandleOpened, ReparseSet;
        public int Win32Error;
    }
    public static class NativeProbe {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool CreateHardLinkW(string link, string existing, IntPtr security);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
        private static string Confine(string root, string path) {
            string scope=Path.GetFullPath(root).TrimEnd('\\')+"\\";
            string full=Path.GetFullPath(path).TrimEnd('\\');
            if(!full.StartsWith(scope,StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Native diagnostic paths must stay inside the new synthetic fixture.");
            return full;
        }
        private static void PlainParents(string path) {
            // These probes operate only on newly-created test fixtures. Refuse
            // an already-reparsed ancestor before asking the OS to mutate a
            // leaf. This is a fixture precondition, not a replacement for the
            // product guard's pinned-parent concurrency boundary.
            string parent=Path.GetDirectoryName(path);
            string current=Path.GetPathRoot(parent);
            string rest=parent.Substring(current.Length);
            if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)
                throw new ArgumentException("A synthetic probe ancestor is a reparse point.");
            foreach(string component in rest.Split(new char[]{'\\'},StringSplitOptions.RemoveEmptyEntries)) {
                current=Path.Combine(current,component);
                if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)
                    throw new ArgumentException("A synthetic probe ancestor is a reparse point.");
            }
        }
        public static ProbeResult Set(string root, string source, string target, uint access, bool symbolicFile) {
            source=Confine(root,source); target=Confine(root,target);
            PlainParents(source); PlainParents(target);
            uint tag=symbolicFile?0xA000000Cu:0xA0000003u;
            byte[] substitute=Encoding.Unicode.GetBytes("\\??\\"+target), print=Encoding.Unicode.GetBytes(target);
            int prefix=symbolicFile?20:16;
            byte[] data=new byte[prefix+substitute.Length+2+print.Length+2];
            Array.Copy(BitConverter.GetBytes(tag),0,data,0,4);
            Array.Copy(BitConverter.GetBytes((ushort)(data.Length-8)),0,data,4,2);
            Array.Copy(BitConverter.GetBytes((ushort)substitute.Length),0,data,10,2);
            Array.Copy(BitConverter.GetBytes((ushort)(substitute.Length+2)),0,data,12,2);
            Array.Copy(BitConverter.GetBytes((ushort)print.Length),0,data,14,2);
            Array.Copy(substitute,0,data,prefix,substitute.Length);
            Array.Copy(print,0,data,prefix+substitute.Length+2,print.Length);
            ProbeResult result=new ProbeResult();
            using(SafeFileHandle handle=CreateFileW(source,access,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                if(handle.IsInvalid){result.Win32Error=Marshal.GetLastWin32Error();return result;}
                result.HandleOpened=true;
                uint returned;
                result.ReparseSet=DeviceIoControl(handle,0x000900A4,data,(uint)data.Length,IntPtr.Zero,0,out returned,IntPtr.Zero);
                result.Win32Error=result.ReparseSet?0:Marshal.GetLastWin32Error();
                return result;
            }
        }
        public static void Clear(string root, string path, bool symbolicFile) {
            path=Confine(root,path);
            PlainParents(path);
            byte[] data=new byte[8];
            Array.Copy(BitConverter.GetBytes(symbolicFile?0xA000000Cu:0xA0000003u),0,data,0,4);
            using(SafeFileHandle handle=CreateFileW(path,0x100,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                if(handle.IsInvalid) throw new IOException("Cannot open the synthetic reparse object for nonrecursive cleanup: "+Marshal.GetLastWin32Error());
                uint returned;
                if(!DeviceIoControl(handle,0x000900AC,data,(uint)data.Length,IntPtr.Zero,0,out returned,IntPtr.Zero))
                    throw new IOException("Cannot clear the synthetic reparse object without traversing it: "+Marshal.GetLastWin32Error());
            }
        }
    }
}
