#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
. (Join-Path $repo 'acceptance/TaskPilot.Acceptance.Security.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing synthetic-test output directory is required.'}
$fixture=Join-Path $output ('AcceptanceAuthority_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$checks=0;$nativeChecks=0
function Assert-Authority([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Expect-AuthorityBlock([scriptblock]$Action){
    $failure=$null;try{$null=&$Action}catch{$failure=$_}
    Assert-Authority ($null-ne$failure-and$failure.Exception.GetBaseException().Message-cmatch'^TP-ACCEPTANCE-[A-Z0-9-]+$') 'The invalid synthetic input must fail with a bounded acceptance code.'
}
function Clone-Authority($Object){return ($Object|ConvertTo-Json -Depth 10|ConvertFrom-Json)}
$now=[datetime]::Parse('2026-11-22T12:00:00Z').ToUniversalTime()
$grant=[pscustomobject]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2';SyntheticOnly=$true;GeneralReleaseStopped=$true;EnvironmentId='1234567890abcdef1234567890abcdef';IssuedUtc='2026-11-22T11:00:00Z';ExpiresUtc='2026-11-23T12:00:00Z';PayloadManifestSha256=('a'*64)}
$null=Assert-TPAcceptanceGrantShape $grant $now
Assert-Authority $true 'The exact synthetic purpose-limited grant shape is valid.'
foreach($change in @(
    @{Name='Purpose';Value='GeneralRelease'},@{Name='Version';Value='0.4.0.1'},@{Name='SyntheticOnly';Value=$false},@{Name='SyntheticOnly';Value='true'},
    @{Name='GeneralReleaseStopped';Value=$false},@{Name='EnvironmentId';Value='..'},@{Name='EnvironmentId';Value=('A'*32)},
    @{Name='PayloadManifestSha256';Value=('A'*64)},@{Name='ExpiresUtc';Value='2026-11-21T12:00:00Z'},@{Name='ExpiresUtc';Value='2026-12-22T12:00:00Z'},
    @{Name='IssuedUtc';Value='2026-11-23T12:00:00Z'},@{Name='IssuedUtc';Value='2026-11-22T11:00:00'},@{Name='FormatVersion';Value=$true}
)){
    $changed=Clone-Authority $grant;$changed.($change.Name)=$change.Value
    Expect-AuthorityBlock {Assert-TPAcceptanceGrantShape $changed $now}
}
$changed=Clone-Authority $grant;$changed|Add-Member -NotePropertyName RootOverride -NotePropertyValue 'UNUSED_SYNTHETIC'
Expect-AuthorityBlock {Assert-TPAcceptanceGrantShape $changed $now}
$manifest=[pscustomobject]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2';Files=@(
    'TaskPilot.Acceptance.exe','acceptance/trusted-publishers.json','acceptance/vendor-code-lock.json','acceptance/TaskPilot.Acceptance.Security.ps1','acceptance/TaskPilot.Acceptance.Runtime.ps1','acceptance/TaskPilot.Acceptance.ps1'
    )|ForEach-Object {[pscustomobject]@{Path=$_;Sha256=('b'*64)}}}
$null=Assert-TPAcceptancePayloadShape $manifest
Assert-Authority $true 'The separate entry manifest is valid.'
foreach($badPath in @('../Settings.json','acceptance/../../Settings.json','acceptance\Settings.json','C:/Settings.json','TaskPilot.exe','other/TaskPilot.ps1','AcceptanceAuthorization.json','Modules/ImportExcel/../../Runtime/secret.dll')){
    $changed=Clone-Authority $manifest;$changed.Files+= [pscustomobject]@{Path=$badPath;Sha256=('b'*64)}
    Expect-AuthorityBlock {Assert-TPAcceptancePayloadShape $changed}
}
$changed=Clone-Authority $manifest;$changed.Files+=$changed.Files[0]
Expect-AuthorityBlock {Assert-TPAcceptancePayloadShape $changed}
$changed=Clone-Authority $manifest;$changed.Files[0].Sha256='broken'
Expect-AuthorityBlock {Assert-TPAcceptancePayloadShape $changed}
$vendor=[pscustomobject]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Files=@('Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Modules/ImportExcel/ImportExcel.psm1')|ForEach-Object {[pscustomobject]@{Path=$_;Sha256=('c'*64)}}}
$null=Assert-TPAcceptanceVendorCodeLock $vendor
Assert-Authority $true 'Original vendor-code paths have a bounded signed-hash policy.'
foreach($badVendor in @('acceptance/TaskPilot.Acceptance.Runtime.ps1','Runtime/TaskPilot.TestSandbox.dll','Modules/TaskPilot.Storage/TaskPilot.Storage.psm1','Modules/ImportExcel/../Runtime/malicious.dll','Modules/ImportExcel/Fake.exe')){
    $changed=Clone-Authority $vendor;$changed.Files+=[pscustomobject]@{Path=$badVendor;Sha256=('c'*64)}
    Expect-AuthorityBlock {Assert-TPAcceptanceVendorCodeLock $changed}
}
$changed=Clone-Authority $vendor;$changed.Files[0].Sha256='wrong'
Expect-AuthorityBlock {Assert-TPAcceptanceVendorCodeLock $changed}
$changed=Clone-Authority $vendor;$changed.Files+=$changed.Files[0]
Expect-AuthorityBlock {Assert-TPAcceptanceVendorCodeLock $changed}
$sentinel=Join-Path $fixture 'UnknownPackage'
$null=[IO.Directory]::CreateDirectory($sentinel)
$locked=Join-Path $sentinel 'AcceptanceAuthorization.json';[IO.File]::WriteAllText($locked,'SYNTHETIC NO-READ SENTINEL')
$handle=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{Expect-AuthorityBlock {Open-TPAcceptanceAuthorization -PackageRoot $sentinel}}finally{$handle.Dispose()}
Assert-Authority ([IO.File]::ReadAllText($locked)-ceq'SYNTHETIC NO-READ SENTINEL') 'Direct script invocation must stop before even reading a locked synthetic grant.'
$policy=[IO.File]::ReadAllText((Join-Path $repo 'acceptance/trusted-publishers.json'))|ConvertFrom-Json
Assert-Authority (@($policy.AllowedPublisherThumbprints).Count-eq0) 'No production publisher is implicitly trusted by this change.'
$nativeExecuted=$false
if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT-and$PSVersionTable.PSEdition-eq'Desktop'-and[Environment]::Is64BitProcess){
    $compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
    $parameters=New-Object CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable=$false;$parameters.GenerateInMemory=$false;$parameters.OutputAssembly=Join-Path $fixture 'Synthetic.PackageGuard.dll'
    $parameters.CompilerOptions='/target:library /platform:x64 /optimize+'
    $parameters.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($fixture,$false)
    foreach($reference in @('mscorlib.dll','System.dll','System.Core.dll')){$null=$parameters.ReferencedAssemblies.Add($reference)}
    $helper='using System; using System.Runtime.InteropServices; public static class SyntheticAcceptanceHardLink { [DllImport("kernel32.dll", CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateHardLinkW(string link,string existing,IntPtr security); }'
    try{
        $compiled=$compiler.CompileAssemblyFromSource($parameters,[string[]]@([IO.File]::ReadAllText((Join-Path $repo 'acceptance/TaskPilot.Acceptance.PackageGuard.cs')),$helper))
        if($compiled.Errors.HasErrors){throw (($compiled.Errors|ForEach-Object {$_.ToString()})-join[Environment]::NewLine)}
    }finally{$compiler.Dispose()}
    $assembly=[Reflection.Assembly]::LoadFrom($parameters.OutputAssembly)
    $guard=$assembly.GetType('TaskPilot.Acceptance.PackageLease',$true)
    function Protect-SyntheticPackageFile([string]$Path,[bool]$Directory){
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $inherit=if($Directory){'OICI'}else{''}
        $sddl='O:'+$sid+'D:P(D;'+$inherit+';0x110;;;S-1-1-0)(D;'+$inherit+';0xc0000;;;S-1-3-4)(A;'+$inherit+';FA;;;'+$sid+')(A;'+$inherit+';FA;;;SY)(A;'+$inherit+';FA;;;BA)'
        if($Directory){$security=New-Object Security.AccessControl.DirectorySecurity}else{$security=New-Object Security.AccessControl.FileSecurity}
        $security.SetSecurityDescriptorSddlForm($sddl)
        if($Directory){[IO.Directory]::SetAccessControl($Path,$security)}else{[IO.File]::SetAccessControl($Path,$security)}
    }
    $package=Join-Path $fixture 'ProtectedSyntheticPackage';$null=[IO.Directory]::CreateDirectory($package)
    $entry=Join-Path $package 'TaskPilot.Acceptance.exe';[IO.File]::WriteAllText($entry,'SYNTHETIC EXE IMAGE, NOT EXECUTED')
    $data=Join-Path $package 'payload.txt';[IO.File]::WriteAllText($data,'SYNTHETIC PAYLOAD')
    $unknown=Join-Path $package 'unknown.txt';[IO.File]::WriteAllText($unknown,'SYNTHETIC NEIGHBOR NOT DECLARED')
    foreach($file in @($entry,$data,$unknown)){Protect-SyntheticPackageFile $file $false}
    Protect-SyntheticPackageFile $package $true
    $lease=$guard::Open($package)
    try{
        Assert-Authority ($lease.Paths.Count-eq1-and$lease.Paths[0]-ceq'TaskPilot.Acceptance.exe') 'Opening a package must not enumerate or read neighboring files before authorization.';$nativeChecks++
        Assert-Authority ($lease.ReadText('payload.txt',1024)-ceq'SYNTHETIC PAYLOAD') 'The guarded synthetic file can be read through its pinned handle.';$nativeChecks++
        $failure=$null;try{$write=[IO.File]::Open($data,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$write.Dispose()}catch{$failure=$_}
        Assert-Authority ($null-ne$failure) 'The package lease must exclude concurrent file writers.';$nativeChecks++
        Expect-AuthorityBlock {$lease.AssertInventory([string[]]@('TaskPilot.Acceptance.exe','payload.txt'))};$nativeChecks++
        Assert-Authority ($lease.Paths.Count-eq2) 'Unknown neighbors must be rejected without opening them as data.';$nativeChecks++
    }finally{$lease.Dispose()}
    $hardPackage=Join-Path $fixture 'SyntheticHardLinkPackage';$null=[IO.Directory]::CreateDirectory($hardPackage)
    $hardEntry=Join-Path $hardPackage 'TaskPilot.Acceptance.exe';[IO.File]::WriteAllText($hardEntry,'SYNTHETIC EXE IMAGE')
    $normal=Join-Path $fixture 'SyntheticNormalData.bin';[IO.File]::WriteAllText($normal,'SYNTHETIC NORMAL DATA MUST BE UNCHANGED')
    $before=Get-TPBuildSha $normal
    $beforePolicy=[IO.File]::GetAccessControl($normal).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    $hardLink=Join-Path $hardPackage 'linked.bin'
    # Protect only the newly-created package before adding the attack link, so
    # Windows ACL inheritance cannot touch the synthetic normal-file target.
    Protect-SyntheticPackageFile $hardEntry $false;Protect-SyntheticPackageFile $hardPackage $true
    if(-not[SyntheticAcceptanceHardLink]::CreateHardLinkW($hardLink,$normal,[IntPtr]::Zero)){throw 'Synthetic hard-link positive control could not be created.'}
    $lease=$guard::Open($hardPackage)
    try{Expect-AuthorityBlock {$lease.ReadBytes('linked.bin',1024)};$nativeChecks++}finally{$lease.Dispose()}
    Assert-Authority ((Get-TPBuildSha $normal)-ceq$before) 'The synthetic ordinary sentinel remains byte-identical.';$nativeChecks++
    Assert-Authority ([IO.File]::GetAccessControl($normal).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)-ceq$beforePolicy) 'The synthetic ordinary sentinel ACL remains unchanged.';$nativeChecks++
    Expect-AuthorityBlock {$guard::Open($sentinel)};$nativeChecks++
    $nativeExecuted=$true
}
$report=[pscustomobject]@{Stage='Dedicated acceptance authority';Passed=$true;Checks=$checks;NativePackageBoundaryChecks=$nativeChecks;NativePackageBoundaryExecuted=$nativeExecuted;ProductionProfileAccessed=$false;ApplicationLaunched=$false;PublisherConfigured=$false;PositiveProductionAuthorizationVerified=$false;ClientWindows10And11Verified=$false;TestRoot=$fixture}
Write-TPBuildNewText (Join-Path $output ('AcceptanceAuthority_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 8)
return $report
