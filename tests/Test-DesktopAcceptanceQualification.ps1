#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot,[string]$RuntimeAssembly)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
. (Join-Path $repo 'acceptance/TaskPilot.Acceptance.Qualification.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer results directory is required.'}
$checks=0;$nativeExecuted=$false;$nativeCases=@();$nativeProbeChecks=0
function Assert-Qualification([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Snapshot-QualificationFixture([string]$Directory){
    $entries=New-Object 'Collections.Generic.List[string]'
    $sections=[Security.AccessControl.AccessControlSections]::Owner-bor[Security.AccessControl.AccessControlSections]::Group-bor[Security.AccessControl.AccessControlSections]::Access
    $entries.Add('DIRECTORY . '+[IO.Directory]::GetAccessControl($Directory).GetSecurityDescriptorSddlForm($sections))
    foreach($entry in @(Get-ChildItem -LiteralPath $Directory -Force -Recurse|Sort-Object FullName)){
        if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'A synthetic snapshot must not traverse links.'}
        $relative=$entry.FullName.Substring($Directory.Length+1).Replace('\','/')
        if($entry.PSIsContainer){$entries.Add('DIRECTORY '+$relative+' '+[IO.Directory]::GetAccessControl($entry.FullName).GetSecurityDescriptorSddlForm($sections))}
        else{$entries.Add('FILE '+$relative+' '+$entry.Length+' '+(Get-TPBuildSha $entry.FullName)+' '+[IO.File]::GetAccessControl($entry.FullName).GetSecurityDescriptorSddlForm($sections))}
    }
    return [string]::Join("`n",$entries.ToArray())
}
$readiness=Get-TPAcceptanceQualificationReadiness
Assert-Qualification ($readiness.Status-ceq'BLOCKED'-and-not$readiness.CanLaunch-and-not$readiness.ProductionLaunchAuthorized) 'Backend probes cannot authorize GUI.'
Assert-Qualification ($readiness.BackendProbeImplemented-and-not$readiness.FullClientQualificationImplemented) 'Partial implementation must be reported accurately.'
Assert-Qualification (-not$readiness.ProfileAccessed-and-not$readiness.UserDataIncluded) 'Readiness must not inspect profiles or include user data.'
Assert-Qualification (@($readiness.RequiredCodes).Count-eq2) 'Installation and target-boundary requirements remain explicit.'
$failure=$null;try{$null=Get-TPAcceptanceQualificationReadiness -CanLaunch $true}catch{$failure=$_}
Assert-Qualification ($null-ne$failure) 'Caller approval flags cannot manufacture qualification readiness.'
$failure=$null;try{$null=Invoke-TPAcceptanceQualification -Authority ([pscustomobject]@{Status='AUTHORIZED_FOR_DESKTOP_ACCEPTANCE';Purpose='DesktopAcceptanceSyntheticOnly'})}catch{$failure=$_}
Assert-Qualification ($null-ne$failure-and$failure.Exception.Message-like'*DEDICATED-LAUNCHER-REQUIRED*') 'A fabricated authority object cannot invoke the production entry.'
$source=[IO.File]::ReadAllText((Join-Path $repo 'acceptance/TaskPilot.Acceptance.Qualification.ps1'))
Assert-Qualification (-not$source.Contains('GetFolderPath(')-and-not$source.Contains('GetTempPath(')) 'The qualification core may not choose real profile or temporary paths.'
$tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
Assert-Qualification ($parseErrors.Count-eq0) 'Qualification source must parse.'
$normalUnchanged=$null;$oldUnchanged=$null;$runtimeSha=$null
if($RuntimeAssembly){
    if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native runtime qualification tests require x64 Windows PowerShell 5.1.'}
    $fixture=Join-Path $output ('AcceptanceQualification_'+[guid]::NewGuid().ToString('N'))
    $profile=Join-Path $fixture 'SyntheticLocalAppData';$null=[IO.Directory]::CreateDirectory($profile)
    $normal=Join-Path $profile 'TaskPilot4';$null=[IO.Directory]::CreateDirectory($normal)
    $sentinel=Join-Path $normal 'synthetic-private.txt';[IO.File]::WriteAllText($sentinel,'SYNTHETIC NORMAL DATA MUST REMAIN UNCHANGED')
    $normalBefore=Get-TPBuildSha $sentinel
    $normalPolicyBefore=[IO.File]::GetAccessControl($sentinel).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    $normalTreeBefore=Snapshot-QualificationFixture $normal
    $runtimePath=Get-TPBuildFullPath $RuntimeAssembly;Assert-TPBuildNoLinks $runtimePath;$runtimeSha=Get-TPBuildSha $runtimePath
    $assembly=[Reflection.Assembly]::LoadFrom($runtimePath)
    if(-not[string]::Equals([IO.Path]::GetFullPath($assembly.Location),$runtimePath,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $assembly.Location)-cne$runtimeSha){throw 'The exact packaged runtime assembly is required.'}
    $environmentId=[guid]::NewGuid().ToString('N')
    $old=[TaskPilot.Runtime.Sandbox]::Create($profile,$environmentId)
    $oldSentinel=Join-Path $old.Data 'previous-independent.txt';$old.WriteNew($oldSentinel,[Text.Encoding]::UTF8.GetBytes('SYNTHETIC OLD INDEPENDENT DATA'))
    $old.Dispose();$oldBefore=Get-TPBuildSha $oldSentinel
    $oldPolicyBefore=[IO.File]::GetAccessControl($oldSentinel).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    $oldTreeBefore=Snapshot-QualificationFixture (Join-Path $profile 'TaskPilotTest')
    $broker=$null;$module=$null
    try{
        $module=Import-Module (Join-Path $repo 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
        $wrongPurpose=[TaskPilot.Runtime.Sandbox]::Create($profile,$environmentId)
        try{
            $failure=$null;try{$null=Invoke-TPAcceptanceQualificationCore -Sandbox $wrongPurpose -StorageModule $module}catch{$failure=$_}
            Assert-Qualification ($null-ne$failure-and$failure.Exception.Message-like'*ACCEPTANCE-BROKER-REQUIRED*') 'The qualification core may not use an independent-mode environment.'
        }finally{$wrongPurpose.Dispose()}
        $broker=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$environmentId)
        $broker.Dispose();$broker=[TaskPilot.Runtime.Sandbox]::OpenExistingAcceptance($profile,$environmentId)
        $failure=$null;try{$null=Invoke-TPAcceptanceQualificationCore -Sandbox $broker -StorageModule $module}catch{$failure=$_}
        Assert-Qualification ($null-ne$failure-and$failure.Exception.Message-like'*ACCEPTANCE-BROKER-REQUIRED*') 'The qualification core may not write through a read-only diagnostic broker.'
        $broker.Dispose();$broker=[TaskPilot.Runtime.Sandbox]::CreateAcceptance($profile,$environmentId)
        $probe=Invoke-TPAcceptanceQualificationCore -Sandbox $broker -StorageModule $module
        foreach($case in $probe.Cases){Write-Host (($case.Id)+': '+$case.Code)}
        Assert-Qualification ($probe.CorePassed-and$probe.Status-ceq'BACKEND_PROBE_PASSED_GUI_BLOCKED') 'The native backend qualification core failed.'
        Assert-Qualification ($probe.Cases.Count-eq6-and$probe.FailedCases-eq0) 'All six backend cases must run and pass.'
        foreach($index in 1..6){$case=@($probe.Cases|Where-Object {$_.Id-ceq('Q{0:00}'-f$index)});Assert-Qualification ($case.Count-eq1-and$case[0].Passed) 'A required backend case is absent or failed.'}
        Assert-Qualification (-not$probe.FullClientQualificationVerified-and-not$probe.ProductionLaunchAuthorized-and-not$probe.GuiExecuted) 'Backend success must not authorize client GUI.'
        $serialized=$probe|ConvertTo-Json -Depth 10
        Assert-Qualification ($serialized-notmatch'Users|SYNTHETIC ACCEPTANCE PROBE|SYNTHETIC CHILD|SyntheticLocalAppData|private|Exception|Stack|DatabasePath') 'Probe report must contain fixed codes, not data or paths.'
        $scope=Join-Path $broker.Temp ('qualification_'+$probe.RunId)
        Assert-Qualification ($broker.Exists((Join-Path $scope 'synthetic-probe.db'))) 'The probe must preserve only its own scoped synthetic evidence.'
        Assert-Qualification (@($broker.ListDirectory($broker.Data)).Count-eq0-and@($broker.ListDirectory($broker.Export)).Count-eq0-and@($broker.ListDirectory($broker.Backup)).Count-eq0) 'The backend core wrote application data, export or backup directories.'
        $failure=$null;try{$null=Invoke-TPAcceptanceQualificationCore -Sandbox $broker -StorageModule $module}catch{$failure=$_}
        Assert-Qualification ($null-ne$failure-and$failure.Exception.Message-like'*FRESH-STORAGE-MODULE-REQUIRED*') 'Qualification must not reset/reuse an initialized storage mode.'
        $nativeCases=$probe.Cases;$nativeProbeChecks=$probe.Checks;$nativeExecuted=$true
    }finally{
        if($null-ne$broker){$broker.Dispose()}
        if($null-ne$module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
    }
    $normalUnchanged=(Get-TPBuildSha $sentinel)-ceq$normalBefore-and[IO.File]::GetAccessControl($sentinel).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)-ceq$normalPolicyBefore-and(Snapshot-QualificationFixture $normal)-ceq$normalTreeBefore
    $oldUnchanged=(Get-TPBuildSha $oldSentinel)-ceq$oldBefore-and[IO.File]::GetAccessControl($oldSentinel).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)-ceq$oldPolicyBefore-and(Snapshot-QualificationFixture (Join-Path $profile 'TaskPilotTest'))-ceq$oldTreeBefore
    Assert-Qualification $normalUnchanged 'The synthetic normal data and ACL changed.'
    Assert-Qualification $oldUnchanged 'The synthetic independent data and ACL changed.'
}
$report=[pscustomobject][ordered]@{Stage='Acceptance backend qualification core';Passed=$true;Checks=$checks;NativeExecuted=$nativeExecuted;NativeCases=$nativeCases;NativeProbeChecks=$nativeProbeChecks;NormalFixtureUnchanged=$normalUnchanged;PreviousIndependentFixtureUnchanged=$oldUnchanged;RuntimeAssemblySha256=$runtimeSha;FullClientQualificationImplemented=$false;ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11Verified=$false}
Write-TPBuildNewText (Join-Path $output ('DesktopAcceptanceQualification_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 12)
return $report
