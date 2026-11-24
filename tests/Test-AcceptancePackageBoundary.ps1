#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native Windows PowerShell Desktop 5.1 x64 is required. No Windows boundary result was produced.'}
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer report directory is required.'}
$fixture=Join-Path $output ('AcceptancePackageBoundary_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$normal=Join-Path $fixture 'SyntheticNormal';$null=[IO.Directory]::CreateDirectory($normal)
$sentinel=Join-Path $normal 'never-write.bin';[IO.File]::WriteAllText($sentinel,'SYNTHETIC NORMAL SENTINEL - NEVER WRITE THROUGH A LINK')
$cases=New-Object 'Collections.Generic.List[object]';$rows=New-Object 'Collections.Generic.List[object]'
$errors=New-Object 'Collections.Generic.List[string]';$checks=0;$mutationChecks=0;$lease=$null
$accesses=@(@('GenericWrite',[uint32]1073741824),@('WriteData',[uint32]2),@('WriteAttributes',[uint32]256),@('ReadAttributes',[uint32]128),@('Zero',[uint32]0),@('WriteEa',[uint32]16),@('AppendData',[uint32]4),@('MaximumAllowed',[uint32]33554432))
$requiredWritable=@('GenericWrite','WriteData','WriteAttributes')
function Assert-PackageBoundary([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Expect-PackageBoundaryDenial([scriptblock]$Operation,[string]$Detail){$caught=$null;try{$null=&$Operation}catch{$caught=$_};Assert-PackageBoundary ($null-ne$caught) $Detail}
function Case-PackageBoundary([string]$CaseId,[string]$Description,[scriptblock]$Operation){
    try{&$Operation;$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Description;Passed=$true});Write-Host ('PASS: '+$CaseId+' '+$Description)}
    catch{$errors.Add($_.Exception.ToString());$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Description;Passed=$false;Error=$_.Exception.Message});Write-Host ('FAIL: '+$CaseId+' '+$_.Exception.Message)}
}
function Snapshot-PackageBoundary([string]$SnapshotRoot){
    $records=New-Object 'Collections.Generic.List[string]';$records.Add('DIRECTORY . ACL '+[string](Get-Acl -LiteralPath $SnapshotRoot).Sddl)
    foreach($item in @(Get-ChildItem -LiteralPath $SnapshotRoot -Recurse -Force|Sort-Object FullName)){
        if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'The normal synthetic fixture unexpectedly contains a link.'}
        $relative=$item.FullName.Substring($SnapshotRoot.Length+1).Replace('\','/');$acl=[string](Get-Acl -LiteralPath $item.FullName).Sddl
        if($item.PSIsContainer){$records.Add('DIRECTORY '+$relative+' ACL '+$acl)}else{$records.Add('FILE '+$relative+' '+$item.Length+' '+(Get-TPBuildSha $item.FullName)+' ACL '+$acl)}
    }
    return [string]::Join("`n",$records.ToArray())
}
function New-PackageBoundarySecurity([bool]$Directory,[bool]$Protect){
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$inherit=if($Directory){'OICI'}else{''}
    $deny=if($Protect){'(D;'+$inherit+';0x110;;;S-1-1-0)(D;'+$inherit+';0xc0000;;;S-1-3-4)'}else{''}
    $sddl='O:'+$sid+'D:P'+$deny+'(A;'+$inherit+';FA;;;'+$sid+')(A;'+$inherit+';FA;;;SY)(A;'+$inherit+';FA;;;BA)'
    $security=if($Directory){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
    $security.SetSecurityDescriptorSddlForm($sddl);return $security
}
function Protect-PackageBoundaryPath([string]$OwnedPath,[bool]$Directory){
    $policy=New-PackageBoundarySecurity $Directory $true
    if($Directory){[IO.Directory]::SetAccessControl($OwnedPath,$policy)}else{[IO.File]::SetAccessControl($OwnedPath,$policy)}
}
function New-PackageBoundaryPackage([switch]$DeferDirectoryProtection) {
    # The lease requires protection on package entries, never on the real user
    # profile or any normal data. Every parent and entry here is newly invented.
    $parent=Join-Path $fixture ('PackageParent_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($parent)
    $package=Join-Path $parent 'TaskPilot.Acceptance';$null=[IO.Directory]::CreateDirectory($package)
    $nested=Join-Path $package 'payload';$null=[IO.Directory]::CreateDirectory($nested)
    $entry=Join-Path $package 'TaskPilot.Acceptance.exe';[IO.File]::WriteAllText($entry,'SYNTHETIC IMAGE - NEVER EXECUTED')
    $file=Join-Path $nested 'empty.bin';[IO.File]::WriteAllBytes($file,[byte[]]@())
    Protect-PackageBoundaryPath $entry $false;Protect-PackageBoundaryPath $file $false
    if(-not$DeferDirectoryProtection){Protect-PackageBoundaryPath $nested $true;Protect-PackageBoundaryPath $package $true}
    return [pscustomobject]@{Parent=$parent;Root=$package;Nested=$nested;Entry=$entry;File=$file}
}
function Protect-PackageBoundaryDirectories($OwnedPackage){
    # Call only before installing any attack reparse point or hard link. This
    # avoids propagating an inherited policy through an already-created link.
    Protect-PackageBoundaryPath ([string]$OwnedPackage.Nested) $true
    Protect-PackageBoundaryPath ([string]$OwnedPackage.Root) $true
}
function New-PackageBoundaryUnprotectedFile([string]$OwnedPath){
    # Supplying a protected DACL at creation avoids inheriting a parent's deny
    # ACE, and avoids rewriting ACLs through an already-created attack link.
    $policy=New-PackageBoundarySecurity $false $false
    $stream=[IO.FileStream]::new($OwnedPath,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$policy)
    $stream.Dispose()
}
function New-PackageBoundaryUnprotectedDirectory([string]$OwnedPath){$null=[IO.Directory]::CreateDirectory($OwnedPath,(New-PackageBoundarySecurity $true $false))}
function Add-PackageBoundaryProbe([string]$Vector,[bool]$Protected,[string]$AccessName,$Probe){
    $rows.Add([pscustomobject]@{Vector=$Vector;Protected=$Protected;Access=$AccessName;HandleOpened=[bool]$Probe.HandleOpened;ReparseSet=[bool]$Probe.ReparseSet;Win32Error=[int]$Probe.Win32Error})
}
$before=Snapshot-PackageBoundary $normal
$source=Join-Path $repo 'acceptance/TaskPilot.Acceptance.PackageGuard.cs';$sourceHash=Get-TPBuildSha $source
$probeSource=Join-Path $PSScriptRoot 'AcceptancePackage.NativeProbe.cs';$probeSourceHash=Get-TPBuildSha $probeSource
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters=New-Object CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable=$false;$parameters.GenerateInMemory=$false;$parameters.OutputAssembly=Join-Path $fixture 'Synthetic.Acceptance.PackageBoundary.dll'
$parameters.CompilerOptions='/target:library /platform:x64 /optimize+'
$parameters.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($fixture,$false)
foreach($reference in @('mscorlib.dll','System.dll','System.Core.dll')){$null=$parameters.ReferencedAssemblies.Add($reference)}
try{
    $compiled=$compiler.CompileAssemblyFromSource($parameters,[string[]]@([IO.File]::ReadAllText($source),[IO.File]::ReadAllText($probeSource)))
    if($compiled.Errors.HasErrors){throw (($compiled.Errors|ForEach-Object {$_.ToString()})-join[Environment]::NewLine)}
}finally{$compiler.Dispose()}
$assembly=[Reflection.Assembly]::LoadFrom($parameters.OutputAssembly)
$guardType=$assembly.GetType('TaskPilot.Acceptance.PackageLease',$true)
$probeType=$assembly.GetType('TaskPilot.AcceptanceBoundaryTests.NativeProbe',$true)
# Dispatch through the exact compiled types while letting PowerShell unbox its
# PSObject wrappers. Reflection Invoke(object[]) preserves those wrappers on
# Windows PowerShell 5.1 and cannot reliably bind native string arguments.
function Open-PackageBoundaryLease([string]$OwnedRoot){return $guardType::Open($OwnedRoot)}
function Invoke-PackageBoundaryProbe([string]$Source,[string]$Target,[uint32]$Access,[bool]$Symbolic){return $probeType::Set([string]$fixture,$Source,$Target,$Access,$Symbolic)}
function Clear-PackageBoundaryProbe([string]$Source,[bool]$Symbolic){$probeType::Clear([string]$fixture,$Source,$Symbolic)}
try{
    Case-PackageBoundary 'PB01' 'All eight file and empty/nonempty directory native controls execute' {
        foreach($accessEntry in $accesses){
            $emptyFile=Join-Path $fixture ('ControlFile_'+[guid]::NewGuid().ToString('N'));[IO.File]::WriteAllBytes($emptyFile,[byte[]]@())
            $probe=Invoke-PackageBoundaryProbe $emptyFile $sentinel $accessEntry[1] $true;Add-PackageBoundaryProbe 'FileSymbolicControl' $false $accessEntry[0] $probe
            if($accessEntry[0]-in$requiredWritable){Assert-PackageBoundary $probe.ReparseSet ('A mandatory file symbolic positive control failed for '+$accessEntry[0]+'. No privilege was enabled.')}
            if($probe.ReparseSet){Clear-PackageBoundaryProbe $emptyFile $true}
            foreach($symbolic in @($false,$true)){
                $emptyDirectory=Join-Path $fixture ('ControlDirectory_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($emptyDirectory)
                $probe=Invoke-PackageBoundaryProbe $emptyDirectory $normal $accessEntry[1] $symbolic;$kind=if($symbolic){'EmptyDirectorySymbolicControl'}else{'EmptyDirectoryJunctionControl'}
                Add-PackageBoundaryProbe $kind $false $accessEntry[0] $probe
                if($accessEntry[0]-in$requiredWritable){Assert-PackageBoundary $probe.ReparseSet ('A mandatory '+$kind+' positive control failed for '+$accessEntry[0]+'. No privilege was enabled.')}
                if($probe.ReparseSet){Clear-PackageBoundaryProbe $emptyDirectory $symbolic}
                $nonempty=Join-Path $fixture ('NonemptyControl_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($nonempty);[IO.File]::WriteAllText((Join-Path $nonempty 'child.txt'),'synthetic nonempty control')
                $probe=Invoke-PackageBoundaryProbe $nonempty $normal $accessEntry[1] $symbolic;$kind=if($symbolic){'NonemptyDirectorySymbolicControl'}else{'NonemptyDirectoryJunctionControl'}
                Add-PackageBoundaryProbe $kind $false $accessEntry[0] $probe
                Assert-PackageBoundary (-not$probe.ReparseSet) 'A nonempty directory unexpectedly accepted a native reparse point.'
                if($accessEntry[0]-in$requiredWritable){Assert-PackageBoundary ($probe.HandleOpened-and$probe.Win32Error-eq145) 'A writable nonempty directory control must produce ERROR_DIR_NOT_EMPTY.'}
            }
        }
    }
    Case-PackageBoundary 'PB02' 'Pinned zero-byte package files reject all in-place symbolic reparse requests' {
        foreach($accessEntry in $accesses){
            $owned=New-PackageBoundaryPackage;$lease=Open-PackageBoundaryLease $owned.Root
            try{
                $lease.AssertPinned('payload/empty.bin')
                $probe=Invoke-PackageBoundaryProbe ([string]$owned.File) $sentinel $accessEntry[1] $true;Add-PackageBoundaryProbe 'PinnedFileSymbolic' $true $accessEntry[0] $probe
                Assert-PackageBoundary (-not$probe.ReparseSet) ('A pinned package file became a symbolic reparse point with '+$accessEntry[0]+'.')
                Assert-PackageBoundary ($lease.ReadBytes('payload/empty.bin',1).Length-eq0) 'The pinned zero-byte package file changed or followed a target.'
            }finally{$lease.Dispose();$lease=$null}
        }
    }
    foreach($kindSpec in @(@('PB03','PinnedRootJunction','Root',$false),@('PB04','PinnedAncestorJunction','Parent',$false),@('PB05','PinnedLeafJunction','Nested',$false),@('PB06','PinnedRootSymbolic','Root',$true),@('PB07','PinnedAncestorSymbolic','Parent',$true),@('PB08','PinnedLeafSymbolic','Nested',$true))){
        Case-PackageBoundary $kindSpec[0] ($kindSpec[1]+' rejects every native access variant') {
            foreach($accessEntry in $accesses){
                $owned=New-PackageBoundaryPackage;$lease=Open-PackageBoundaryLease $owned.Root
                try{
                    $lease.AssertPinned('payload/empty.bin')
                    $probe=Invoke-PackageBoundaryProbe ([string]$owned.($kindSpec[2])) $normal $accessEntry[1] ([bool]$kindSpec[3]);Add-PackageBoundaryProbe $kindSpec[1] $true $accessEntry[0] $probe
                    Assert-PackageBoundary (-not$probe.ReparseSet) ('A pinned package directory became a reparse point: '+$kindSpec[1]+'/'+$accessEntry[0])
                    if($kindSpec[2]-ceq'Parent'-and$accessEntry[0]-in$requiredWritable){Assert-PackageBoundary ($probe.HandleOpened-and$probe.Win32Error-eq145) 'An outside-package pinned ancestor must remain nonempty without relying on package ACLs.'}
                    if($kindSpec[2]-cne'Parent'-and$accessEntry[0]-ceq'WriteData'){Assert-PackageBoundary ($probe.HandleOpened-and$probe.Win32Error-eq145) 'The metadata-ACL bypass access must encounter a genuinely nonempty package directory.'}
                    Assert-PackageBoundary ($lease.ReadBytes('payload/empty.bin',1).Length-eq0) 'A directory probe redirected a pinned read.'
                }finally{$lease.Dispose();$lease=$null}
            }
        }
    }
    Case-PackageBoundary 'PB09' 'Preexisting file symbolic links are refused before reading a locked normal target' {
        $owned=New-PackageBoundaryPackage -DeferDirectoryProtection;$link=Join-Path $owned.Root 'preexisting-file.bin';New-PackageBoundaryUnprotectedFile $link
        Protect-PackageBoundaryDirectories $owned
        $probe=Invoke-PackageBoundaryProbe $link $sentinel ([uint32]256) $true;Assert-PackageBoundary $probe.ReparseSet 'Preexisting file symbolic fixture did not install successfully.'
        $locked=[IO.File]::Open($sentinel,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$lease=Open-PackageBoundaryLease $owned.Root;Expect-PackageBoundaryDenial {$lease.ReadBytes('preexisting-file.bin',4096)} 'The guard followed a preexisting symbolic file.'}finally{if($null-ne$lease){$lease.Dispose();$lease=$null};$locked.Dispose()}
    }
    Case-PackageBoundary 'PB10' 'Preexisting package-root junction and directory symbolic links cannot be opened' {
        foreach($symbolic in @($false,$true)){
            $alias=Join-Path $fixture ('RootAlias_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($alias)
            $probe=Invoke-PackageBoundaryProbe $alias $normal ([uint32]256) $symbolic;Assert-PackageBoundary $probe.ReparseSet 'Preexisting root directory reparse fixture did not install successfully.'
            Expect-PackageBoundaryDenial {Open-PackageBoundaryLease $alias} 'The guard followed a preexisting package-root reparse point.'
        }
    }
    Case-PackageBoundary 'PB11' 'Lazy pinning refuses preexisting intermediate junctions and symbolic directories' {
        foreach($symbolic in @($false,$true)){
            $owned=New-PackageBoundaryPackage -DeferDirectoryProtection;$link=Join-Path $owned.Root 'preexisting-dir';New-PackageBoundaryUnprotectedDirectory $link
            Protect-PackageBoundaryDirectories $owned
            $probe=Invoke-PackageBoundaryProbe $link $normal ([uint32]256) $symbolic;Assert-PackageBoundary $probe.ReparseSet 'Preexisting intermediate directory fixture did not install successfully.'
            $lease=Open-PackageBoundaryLease $owned.Root
            try{Expect-PackageBoundaryDenial {$lease.ReadBytes('preexisting-dir/never-write.bin',4096)} 'Lazy pinning followed a preexisting intermediate reparse point.'}finally{$lease.Dispose();$lease=$null}
        }
    }
    Case-PackageBoundary 'PB12' 'Hard links are refused before payload content is returned' {
        $owned=New-PackageBoundaryPackage;$link=Join-Path $owned.Root 'hard-link.bin'
        Assert-PackageBoundary ($probeType::CreateHardLinkW([string]$link,[string]$sentinel,[IntPtr]::Zero)) 'Hard-link positive control failed.'
        $lease=Open-PackageBoundaryLease $owned.Root
        try{Expect-PackageBoundaryDenial {$lease.ReadBytes('hard-link.bin',4096)} 'The guard returned hard-linked normal content.'}finally{$lease.Dispose();$lease=$null}
    }
    Case-PackageBoundary 'PB13' 'Weak and noncanonical file policies cannot be adopted' {
        foreach($noncanonical in @($false,$true)){
            $owned=New-PackageBoundaryPackage -DeferDirectoryProtection;$file=Join-Path $owned.Root 'invalid-policy.bin';New-PackageBoundaryUnprotectedFile $file
            if($noncanonical){
                $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $raw=New-Object Security.AccessControl.RawSecurityDescriptor ('O:'+$sid+'D:P(A;;FA;;;'+$sid+')(D;;0x110;;;S-1-1-0)(D;;0xc0000;;;S-1-3-4)')
                $bytes=New-Object byte[] $raw.BinaryLength;$raw.GetBinaryForm($bytes,0)
                $policy=New-Object Security.AccessControl.FileSecurity;$policy.SetSecurityDescriptorBinaryForm($bytes)
                [IO.File]::SetAccessControl($file,$policy)
            }
            Protect-PackageBoundaryDirectories $owned
            $lease=Open-PackageBoundaryLease $owned.Root
            try{Expect-PackageBoundaryDenial {$lease.ReadBytes('invalid-policy.bin',4096)} 'An unprotected or noncanonical file policy was accepted.'}finally{$lease.Dispose();$lease=$null}
        }
    }
    Case-PackageBoundary 'PB14' 'Traversal absolute shared device ADS and environment-expanded paths are refused' {
        $owned=New-PackageBoundaryPackage;$lease=Open-PackageBoundaryLease $owned.Root
        try{
            foreach($bad in @('../never-write.bin','payload/../../never-write.bin','payload\empty.bin','C:/never-write.bin','//server/share/data','\\?\C:\data','payload/empty.bin:stream','%LOCALAPPDATA%/TaskPilot4/data','payload/./empty.bin')){
                Expect-PackageBoundaryDenial {$lease.ReadBytes($bad,4096)} 'A forbidden payload path was accepted.'
            }
        }finally{$lease.Dispose();$lease=$null}
    }
    Case-PackageBoundary 'PB15' 'Pinned executable and payload cannot be deleted renamed or externally overwritten' {
        $owned=New-PackageBoundaryPackage;$lease=Open-PackageBoundaryLease $owned.Root
        try{
            $lease.AssertPinned('payload/empty.bin')
            foreach($pinnedPath in @($owned.Entry,$owned.File)){
                Expect-PackageBoundaryDenial {[IO.File]::Delete($pinnedPath)} 'A pinned package file was deleted.';$script:mutationChecks++
                Expect-PackageBoundaryDenial {[IO.File]::Move($pinnedPath,$pinnedPath+'.moved')} 'A pinned package file was renamed.';$script:mutationChecks++
                Expect-PackageBoundaryDenial {[IO.File]::WriteAllText($pinnedPath,'must not replace')} 'A pinned package file was overwritten.';$script:mutationChecks++
            }
        }finally{$lease.Dispose();$lease=$null}
    }
}catch{$errors.Add($_.Exception.ToString())}finally{if($null-ne$lease){$lease.Dispose()}}
$normalUnchanged=(Snapshot-PackageBoundary $normal)-ceq$before
if(-not$normalUnchanged){$errors.Add('The synthetic normal bytes, directory structure, owner or DACL changed.')}
if((Get-TPBuildSha $source)-cne$sourceHash-or(Get-TPBuildSha $probeSource)-cne$probeSourceHash){$errors.Add('Native package-boundary compilation inputs changed during verification.')}
$expectedVectors=@('FileSymbolicControl','EmptyDirectoryJunctionControl','NonemptyDirectoryJunctionControl','EmptyDirectorySymbolicControl','NonemptyDirectorySymbolicControl','PinnedFileSymbolic','PinnedRootJunction','PinnedAncestorJunction','PinnedLeafJunction','PinnedRootSymbolic','PinnedAncestorSymbolic','PinnedLeafSymbolic')
$complete=$cases.Count-eq15-and@($cases|Where-Object {-not$_.Passed}).Count-eq0-and$rows.Count-eq96
foreach($vector in $expectedVectors){foreach($accessEntry in $accesses){if(@($rows|Where-Object {$_.Vector-ceq$vector-and$_.Access-ceq$accessEntry[0]}).Count-ne1){$complete=$false}}}
foreach($control in @('FileSymbolicControl','EmptyDirectoryJunctionControl','EmptyDirectorySymbolicControl')){foreach($requiredAccess in $requiredWritable){if(@($rows|Where-Object {$_.Vector-ceq$control-and$_.Access-ceq$requiredAccess-and$_.ReparseSet}).Count-ne1){$complete=$false}}}
$unsafe=@($rows|Where-Object {$_.Protected-and$_.ReparseSet}).Count-gt0
$report=[pscustomobject][ordered]@{
    Stage='Acceptance package native reparse and pre-content boundary';Passed=($errors.Count-eq0-and$complete-and$normalUnchanged-and-not$unsafe)
    Cases=$cases.ToArray();Checks=$checks;NativeProbes=$rows.Count;NativeProbeResults=$rows.ToArray();PinnedMutationChecks=$mutationChecks
    CompleteNativeCoverage=$complete;UnsafeVectorConfirmed=$unsafe;NormalFixtureUnchanged=$normalUnchanged;SnapshotIncludes=@('FileSha256','FileLength','DirectoryStructure','OwnerGroupAndDaclSddl')
    PackageGuardSourceSha256=$sourceHash;ProbeSourceSha256=$probeSourceHash;Errors=$errors.ToArray();SkippedDetails=@()
    ProductionProfileAccessed=$false;ApplicationLaunched=$false;PrivilegesEnabled=$false;OSProtectionSettingsChanged=$false;Windows10And11Verified=$false;TestRoot=$fixture
}
Write-TPBuildNewText (Join-Path $output ('AcceptancePackageBoundary_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 14)
return $report
