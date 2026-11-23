#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VerificationRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native Windows PowerShell 5.1 x64 is required.'}
if(-not$env:RUNNER_TEMP-or$env:GITHUB_SHA-cnotmatch'^[a-f0-9]{40}$'-or$env:TASKPILOT_PUBLISH_CANDIDATE-cne'false'){throw 'A source-bound isolated runner with publication stopped is required.'}
$root=Get-TPBuildFullPath $VerificationRoot;$runner=Get-TPBuildFullPath $env:RUNNER_TEMP;Assert-TPBuildNoLinks $root
if($root-eq$runner-or-not(Test-TPBuildBelow $root $runner)){throw 'VerificationRoot must be below RUNNER_TEMP.'}
$repo=Split-Path -Parent $PSScriptRoot;$reports=Join-Path $repo 'TestResults';$dependency=Join-Path $root 'Dependencies'
$suites=New-Object 'Collections.Generic.List[object]';$failures=New-Object 'Collections.Generic.List[string]'
function Invoke-LocalEvidence([string]$LocalSuiteName,[scriptblock]$LocalOperation){
    try{return (&$LocalOperation)}catch{$failures.Add($LocalSuiteName);Write-Host ('FAIL: '+$LocalSuiteName+' : '+$_.Exception.GetBaseException().Message);return $null}
}
foreach($name in @('Test-LocalValidationPolicy.ps1','Test-LocalValidationEntry.ps1')){
    $value=Invoke-LocalEvidence $name {& (Join-Path $repo ('tests/'+$name)) -OutputRoot $reports}
    if($null-ne$value){
        $valid=$value.Passed-and-not$value.ProductionProfileAccessed-and-not$value.ApplicationLaunched
        if($name-ceq'Test-LocalValidationPolicy.ps1'){$valid=$valid-and$value.NativeWindowsRuntimeCompiled-and@($value.Cases).Count-eq12-and-not$value.CanLaunch-and-not$value.PrivateKeyPersisted}
        if($name-ceq'Test-LocalValidationEntry.ps1'){$valid=$valid-and$value.CompleteEntryNegativeInvoked-and-not$value.LocalStartAuthorized}
        if(-not$valid){$failures.Add($name)}else{$suites.Add($value)}
    }
}
$plan=Invoke-LocalEvidence 'Plan' {& (Join-Path $repo 'tests/Test-LocalValidationPlan.ps1') -OutputRoot $reports -TestRoot (Join-Path $root 'LocalPlanFixture')}
if($null-ne$plan){if(-not$plan.Passed-or$plan.CanLaunch-or$plan.ExecutableOrZipCreated){$failures.Add('Plan')}else{$suites.Add($plan)}}
$build=@(& (Join-Path $PSScriptRoot 'Build-TaskPilotLocalValidation.ps1') -DependencyRoot $dependency -OutputRoot (Join-Path $root 'LocalInternalBuild') -InternalCompile)
$compiled=@($build|Where-Object {$null-ne$_.PSObject.Properties['ExecutableGenerated']})
if($compiled.Count-ne1-or-not$compiled[0].ExecutableGenerated-or$compiled[0].Distributable-or$compiled[0].ExecutionAuthorized-or$null-ne$compiled[0].Zip){throw 'Only a blocked internal local refusal build may be compiled.'}
$local=$compiled[0];$runtime=Join-Path $local.PackageRoot 'Runtime/TaskPilot.TestSandbox.dll'
if((Get-TPBuildSha $runtime)-cne$local.RuntimeGuardSha256){throw 'The exact local runtime is required.'}
$scope=Invoke-LocalEvidence 'Scope' {
    $v=& (Join-Path $repo 'tests/Test-LocalValidationScope.ps1') -RuntimeAssembly $runtime -OutputRoot $reports
    if(-not$v.Passed-or$v.FailedCases-ne0-or@($v.Cases).Count-ne9-or@($v.SkippedDetails).Count-ne0-or-not$v.NormalFixtureUnchanged-or-not$v.PreviousIndependentAndAcceptanceFixturesUnchanged-or$v.RuntimeAssemblySha256-cne$local.RuntimeGuardSha256){throw 'Local namespace/database ownership verification failed.'}
    foreach($index in 1..9){$case=@($v.Cases|Where-Object {$_.Id-ceq('L{0:00}'-f$index)});if($case.Count-ne1-or-not$case[0].Passed){throw 'All nine local scope cases are required.'}}
    $v
}
if($null-ne$scope){$suites.Add($scope)}
$packaging=Invoke-LocalEvidence 'Packaging' {& (Join-Path $repo 'tests/Test-LocalValidationBuild.ps1') -DependencyRoot $dependency -OutputRoot $reports -TestRoot (Join-Path $root 'LocalBuildFixture') -InternalPackageRoot $local.PackageRoot}
if($null-ne$packaging){if(-not$packaging.Passed-or-not$packaging.InternalCompileChecked-or$packaging.ExecutionAuthorized-or$packaging.Distributable){$failures.Add('Packaging')}else{$suites.Add($packaging)}}
$gate=Invoke-LocalEvidence 'Gate' {& (Join-Path $repo 'tests/Test-LocalValidationGate.ps1') -OutputRoot $reports -LocalExecutable $local.Executable}
if($null-ne$gate){if(-not$gate.Passed-or-not$gate.NativeExecutableTested-or$gate.CanLaunch-or$gate.ProductionProfileAccessed){$failures.Add('Gate')}else{$suites.Add($gate)}}
$crash=Invoke-LocalEvidence 'CrashRecovery' {& (Join-Path $repo 'tests/Test-LocalValidationCrashRecovery.ps1') -OutputRoot $reports -RuntimeAssembly $runtime}
if($null-ne$crash){if(-not$crash.Passed-or-not$crash.ActualProcessTerminationPerformed-or$crash.TerminatedProcesses-ne2-or@($crash.Cases).Count-ne4-or-not$crash.NormalFixtureUnchanged-or$crash.RuntimeAssemblySha256-cne$local.RuntimeGuardSha256-or$crash.PowerLossVerified-or$crash.ProductionProfileAccessed){$failures.Add('CrashRecovery')}else{$suites.Add($crash)}}
$result=[pscustomobject][ordered]@{
    FormatVersion=1;SourceCommit=$env:GITHUB_SHA;Platform='Windows Server 2022 / Windows PowerShell Desktop 5.1 x64'
    Status=$(if($failures.Count-eq0){'LOCAL_PREPARATION_TESTS_PASSED_NOT_READY'}else{'LOCAL_PREPARATION_TESTS_FAILED_NOT_READY'})
    Passed=($failures.Count-eq0);Suites=$suites.ToArray();FailedSuites=$failures.ToArray()
    LocalRuntimeSha256=$local.RuntimeGuardSha256;LocalExecutableSha256=$local.ExecutableSha256
    CanLaunch=$false;ProtectedParentProtocolImplemented=$false;ActualCleanVMVerified=$false
    PaidCertificateRequiredForCore=$false;CertificateStoreChanged=$false;PolicyChanged=$false
    ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11GuiVerified=$false
    GeneralPublicationBlocked=$true;IndependentPublicationBlocked=$true;FormalAcceptancePublicationBlocked=$true;LocalExecutableOrZipPublished=$false
}
Write-TPBuildNewText (Join-Path $reports ('LocalValidationVerification_'+$env:GITHUB_RUN_ID+'_'+$env:GITHUB_RUN_ATTEMPT+'.json')) (ConvertTo-Json -InputObject $result -Depth 22)
if($failures.Count-ne0){throw ('Local preparation failures: '+($failures.ToArray()-join', ')+'. All publication remains stopped.')}
$result
