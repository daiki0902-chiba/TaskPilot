#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RuntimeAssembly,
    [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'This diagnostic requires native Windows PowerShell Desktop 5.1 x64. No Windows result was produced.'}
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'OutputRoot must be an existing developer results directory.'}
$assembly=Get-TPBuildFullPath $RuntimeAssembly
Assert-TPBuildNoLinks $assembly
$null=[Reflection.Assembly]::LoadFrom($assembly)
if($null-eq('TaskPilot.Runtime.Sandbox'-as[type])){throw 'The supplied assembly does not contain the independent-mode runtime.'}
$fixture=Join-Path $output ('IsolatedFileBoundary_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$normal=Join-Path $fixture 'SyntheticNormal'
$null=[IO.Directory]::CreateDirectory($normal)
$sentinel=Join-Path $normal 'never-write.bin'
[IO.File]::WriteAllBytes($sentinel,[Text.Encoding]::UTF8.GetBytes('SYNTHETIC NORMAL SENTINEL - DO NOT CHANGE'))
$compiler=Join-Path $fixture 'DeveloperProbeCompiler'
$null=[IO.Directory]::CreateDirectory($compiler)
$oldEnvironment=@{}
foreach($name in @('TEMP','TMP')){$oldEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$rows=New-Object 'Collections.Generic.List[object]'
$errors=New-Object 'Collections.Generic.List[string]'
$unverified=New-Object 'Collections.Generic.List[string]'
$sandbox=$null
function Get-FileBoundaryHash([string]$Path){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
}
$before=Get-FileBoundaryHash $sentinel
try{
    # This compiler and every probe path belong to the newly created fixture.
    # No privileges are enabled and no OS protection settings are changed.
    $env:TEMP=$compiler;$env:TMP=$compiler
    if($null-eq('TaskPilot.FileBoundaryTests.NativeProbe'-as[type])){
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace TaskPilot.FileBoundaryTests {
    public sealed class ProbeResult {
        public bool HandleOpened, ReparseSet;
        public int Win32Error;
    }
    public static class NativeProbe {
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
        public static ProbeResult Set(string root, string source, string target, uint access, bool symbolicFile) {
            source=Confine(root,source); target=Confine(root,target);
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
'@ -ErrorAction Stop
    }
    $accesses=@(@('GenericWrite',[uint32]1073741824),@('WriteData',[uint32]2),@('WriteAttributes',[uint32]256),@('ReadAttributes',[uint32]128),@('Zero',[uint32]0))
    $profile=Join-Path $fixture 'SyntheticLocalAppData'
    $null=[IO.Directory]::CreateDirectory($profile)
    foreach($access in $accesses){
        $control=Join-Path $fixture ('UnpinnedFile_'+[guid]::NewGuid().ToString('N')+'.bin')
        [IO.File]::WriteAllBytes($control,[byte[]]@())
        $controlResult=[TaskPilot.FileBoundaryTests.NativeProbe]::Set($fixture,$control,$sentinel,$access[1],$true)
        $rows.Add([pscustomobject]@{Vector='FileSymbolicReparse';Protected=$false;Access=$access[0];HandleOpened=$controlResult.HandleOpened;ReparseSet=$controlResult.ReparseSet;Win32Error=$controlResult.Win32Error})
        if($controlResult.ReparseSet){[TaskPilot.FileBoundaryTests.NativeProbe]::Clear($fixture,$control,$true)}
        $sandbox=[TaskPilot.Runtime.Sandbox]::Create($profile,[guid]::NewGuid().ToString('N'))
        $pinned=Join-Path $sandbox.Input 'pinned-zero-byte-journal-control.bin'
        $sandbox.WriteNew($pinned,[byte[]]@());$sandbox.PinExistingFile($pinned)
        $result=$null
        try{
            $result=[TaskPilot.FileBoundaryTests.NativeProbe]::Set($fixture,$pinned,$sentinel,$access[1],$true)
            $rows.Add([pscustomobject]@{Vector='FileSymbolicReparse';Protected=$true;Access=$access[0];HandleOpened=$result.HandleOpened;ReparseSet=$result.ReparseSet;Win32Error=$result.Win32Error})
            if($result.ReparseSet){$errors.Add('A pinned test file became a symbolic reparse point using '+$access[0]+'. Native pathname consumers are not proven safe.')}
        }finally{
            $sandbox.Dispose();$sandbox=$null
            if(($null-ne$result)-and$result.ReparseSet){[TaskPilot.FileBoundaryTests.NativeProbe]::Clear($fixture,$pinned,$true)}
        }
    }
    foreach($access in $accesses){
        # The unprotected control is nonempty, just like the pinned ancestor.
        # This distinguishes filesystem restrictions from sharing/DACL guards.
        $control=Join-Path $fixture ('UnpinnedNonemptyAncestor_'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($control)
        [IO.File]::WriteAllText((Join-Path $control 'child.txt'),'synthetic nonempty ancestor control')
        $controlResult=[TaskPilot.FileBoundaryTests.NativeProbe]::Set($fixture,$control,$normal,$access[1],$false)
        $rows.Add([pscustomobject]@{Vector='NonemptyAncestorJunction';Protected=$false;Access=$access[0];HandleOpened=$controlResult.HandleOpened;ReparseSet=$controlResult.ReparseSet;Win32Error=$controlResult.Win32Error})
        if($controlResult.ReparseSet){[TaskPilot.FileBoundaryTests.NativeProbe]::Clear($fixture,$control,$false)}
        $ancestor=Join-Path $fixture ('AncestorProfile_'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($ancestor)
        [IO.File]::WriteAllText((Join-Path $ancestor 'child.txt'),'synthetic pinned ancestor sentinel')
        $sandbox=[TaskPilot.Runtime.Sandbox]::Create($ancestor,[guid]::NewGuid().ToString('N'))
        $result=$null
        try{
            $result=[TaskPilot.FileBoundaryTests.NativeProbe]::Set($fixture,$ancestor,$normal,$access[1],$false)
            $rows.Add([pscustomobject]@{Vector='NonemptyAncestorJunction';Protected=$true;Access=$access[0];HandleOpened=$result.HandleOpened;ReparseSet=$result.ReparseSet;Win32Error=$result.Win32Error})
            if($result.ReparseSet){$errors.Add('A pinned nonempty profile ancestor became a junction using '+$access[0]+'. Absolute pathname confinement is not proven safe.')}
        }finally{
            $sandbox.Dispose();$sandbox=$null
            if(($null-ne$result)-and$result.ReparseSet){[TaskPilot.FileBoundaryTests.NativeProbe]::Clear($fixture,$ancestor,$false)}
        }
    }
}catch{$errors.Add($_.Exception.ToString())}
finally{
    if($null-ne$sandbox){$sandbox.Dispose()}
    foreach($name in $oldEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$oldEnvironment[$name],'Process')}
}
$normalUnchanged=(Get-FileBoundaryHash $sentinel)-ceq$before
if(-not$normalUnchanged){$errors.Add('The synthetic normal sentinel changed.')}
foreach($vector in @('FileSymbolicReparse','NonemptyAncestorJunction')){
    $supported=@($rows|Where-Object {$_.Vector-ceq$vector-and-not$_.Protected-and$_.ReparseSet}).Count-gt0
    if(-not$supported){
        $codes=@($rows|Where-Object {$_.Vector-ceq$vector-and-not$_.Protected}|ForEach-Object {$_.Access+':'+$_.Win32Error})-join', '
        $unverified.Add($vector+' has no successful unprotected native positive control on this token/filesystem ('+$codes+'). No privileges were enabled.')
    }
}
$unsafe=@($rows|Where-Object {$_.Protected-and$_.ReparseSet}).Count-gt0
$report=[pscustomobject][ordered]@{
    Stage='Native synthetic file and ancestor reparse boundary diagnostic'
    CapturedAtUtc=[datetime]::UtcNow.ToString('o')
    PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();ProcessBits=[IntPtr]::Size*8
    Status=$(if($errors.Count-gt0){'FAIL'}elseif($unverified.Count-gt0){'PARTIAL - UNSUPPORTED POSITIVE CONTROL'}else{'PASS'})
    Passed=($errors.Count-eq0-and$unverified.Count-eq0)
    UnsafeVectorConfirmed=$unsafe;NormalFixtureUnchanged=$normalUnchanged
    NativeRejectedFileReparse=(@($rows|Where-Object {$_.Vector-ceq'FileSymbolicReparse'-and-not$_.Protected}).Count-eq5-and@($rows|Where-Object {$_.Vector-ceq'FileSymbolicReparse'-and-not$_.Protected-and$_.ReparseSet}).Count-eq0)
    NativeRejectedAncestorReparse=(@($rows|Where-Object {$_.Vector-ceq'NonemptyAncestorJunction'-and-not$_.Protected}).Count-eq5-and@($rows|Where-Object {$_.Vector-ceq'NonemptyAncestorJunction'-and-not$_.Protected-and$_.ReparseSet}).Count-eq0)
    CompleteNativeCoverage=($unverified.Count-eq0)
    Cases=$rows.ToArray();Errors=$errors.ToArray();UnverifiedVectors=$unverified.ToArray()
    TestRoot=$fixture;RuntimeAssemblySha256=(Get-FileBoundaryHash $assembly)
    ProductionProfileAccessed=$false;PrivilegesEnabled=$false;OSProtectionSettingsChanged=$false
    Limits=@('No existing business profile is used.','A failed native positive control is reported as partial coverage, never as a guard pass.','Windows 10/11 client GUI and developer-mode configurations remain unverified.')
}
Write-TPBuildNewText (Join-Path $fixture 'IsolatedFileBoundaryResult.json') (ConvertTo-Json -InputObject $report -Depth 12)
return $report
