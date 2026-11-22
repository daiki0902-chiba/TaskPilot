#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VerificationRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native x64 Windows PowerShell 5.1 is required.'}
if(-not$env:RUNNER_TEMP-or$env:GITHUB_SHA-cnotmatch'^[a-f0-9]{40}$'-or$env:TASKPILOT_PUBLISH_CANDIDATE-cne'false'){throw 'A source-bound isolated CI run with publication disabled is required.'}
$root=Get-TPBuildFullPath $VerificationRoot;$runner=Get-TPBuildFullPath $env:RUNNER_TEMP
Assert-TPBuildNoLinks $root
if($root-eq$runner-or-not(Test-TPBuildBelow $root $runner)){throw 'VerificationRoot must be below RUNNER_TEMP.'}
$repo=Split-Path -Parent $PSScriptRoot;$reports=Join-Path $repo 'TestResults'
$buildRoot=Join-Path $root 'DesktopAcceptanceInternal'
Assert-TPBuildNoLinks $buildRoot
$builds=@(Get-ChildItem -LiteralPath $buildRoot -Directory -Force)
if($builds.Count-ne1){throw 'Exactly one blocked internal acceptance build is required.'}
$package=Join-Path $builds[0].FullName 'TaskPilot.Acceptance'
$info=Get-Content -LiteralPath (Join-Path $package 'AcceptanceBuildInfo.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($info.Status-cne'BLOCKED'-or$info.Distributable-or$null-ne$info.Zip){throw 'The internal acceptance package must remain blocked.'}
$runtime=Join-Path $package 'Runtime/TaskPilot.TestSandbox.dll'
Assert-TPBuildNoLinks $runtime
if((Get-TPBuildSha $runtime)-cne$info.RuntimeGuardSha256){throw 'Follow-up verification requires the exact internal package runtime.'}
$suiteResults=New-Object 'Collections.Generic.List[object]'
$boundary=& (Join-Path $repo 'tests/Test-AcceptancePackageBoundary.ps1') -OutputRoot $reports
if(-not$boundary.Passed-or-not$boundary.CompleteNativeCoverage-or$boundary.UnsafeVectorConfirmed-or-not$boundary.NormalFixtureUnchanged-or$boundary.NativeProbes-ne96-or@($boundary.Cases).Count-ne15-or@($boundary.SkippedDetails).Count-ne0-or$boundary.ProductionProfileAccessed-or$boundary.PrivilegesEnabled-or$boundary.OSProtectionSettingsChanged){throw 'New package guard boundary verification failed. Publication remains stopped.'}
$suiteResults.Add($boundary)
$diagnostics=& (Join-Path $repo 'tests/Test-DesktopAcceptanceDiagnostics.ps1') -OutputRoot $reports -RuntimeAssembly $runtime
if(-not$diagnostics.Passed-or-not$diagnostics.NativeReadonlyReopenExecuted-or@($diagnostics.NativeCases).Count-ne11-or-not$diagnostics.NormalFixtureUnchanged-or$diagnostics.RuntimeAssemblySha256-cne$info.RuntimeGuardSha256-or$diagnostics.ProductionProfileAccessed){throw 'Native read-only diagnostic verification failed.'}
foreach($index in 1..11){$case=@($diagnostics.NativeCases|Where-Object {$_.Id-ceq('D{0:00}'-f$index)});if($case.Count-ne1-or-not$case[0].Passed){throw 'All eleven native diagnostic cases are required.'}}
$suiteResults.Add($diagnostics)
$qualification=& (Join-Path $repo 'tests/Test-DesktopAcceptanceQualification.ps1') -OutputRoot $reports -RuntimeAssembly $runtime
if(-not$qualification.Passed-or-not$qualification.NativeExecuted-or@($qualification.NativeCases).Count-ne6-or-not$qualification.NormalFixtureUnchanged-or-not$qualification.PreviousIndependentFixtureUnchanged-or$qualification.RuntimeAssemblySha256-cne$info.RuntimeGuardSha256-or$qualification.ProductionProfileAccessed-or$qualification.FullClientQualificationImplemented){throw 'Native backend probe verification failed or incorrectly claimed full client qualification.'}
foreach($index in 1..6){$case=@($qualification.NativeCases|Where-Object {$_.Id-ceq('Q{0:00}'-f$index)});if($case.Count-ne1-or-not$case[0].Passed){throw 'All six native backend probe cases are required.'}}
$suiteResults.Add($qualification)
$msix=& (Join-Path $repo 'tests/Test-DesktopAcceptanceMsixPlan.ps1') -OutputRoot $reports
if(-not$msix.Passed){throw 'MSIX planning regression failed.'}
$suiteResults.Add($msix)
$hostPolicy=& (Join-Path $repo 'tests/Test-DesktopAcceptanceHostPolicy.ps1') -OutputRoot $reports
if(-not$hostPolicy.Passed-or-not$hostPolicy.NativeExecuted-or$hostPolicy.CanAuthorizeAcceptance-or$hostPolicy.PolicyChanged-or$hostPolicy.AuthorizationManagerChanged-or$hostPolicy.CertificateInstalled-or$hostPolicy.ProductionProfileAccessed){throw 'The default host policy observation must execute without overriding protections or authorizing acceptance.'}
$suiteResults.Add($hostPolicy)
# Test the full existing suites against this acceptance build's DLL as well as
# the ordinary build checked in the preceding job step. Fresh processes avoid
# provider mode or LoadFrom reuse from the qualification probe.
$bindingRoot=Join-Path $reports ('DesktopAcceptanceBinding_'+$env:GITHUB_RUN_ID+'_'+$env:GITHUB_RUN_ATTEMPT)
if(Test-TPBuildPathExists $bindingRoot){throw 'Acceptance binary binding results must use a new directory.'}
$null=[IO.Directory]::CreateDirectory($bindingRoot)
foreach($name in @('Test-IsolatedMemoryStore.ps1','Test-IsolatedTestMode.ps1')){
    $arguments=@('-NoProfile','-NonInteractive','-File',(Join-Path $repo ('tests/'+$name)),'-RuntimeAssembly',$runtime,'-OutputRoot',$bindingRoot)
    if($name-ceq'Test-IsolatedTestMode.ps1'){$arguments+=@('-DependencyRoot',(Join-Path $root 'Dependencies'))}
    & (Join-Path $PSHOME 'powershell.exe') @arguments
    if($LASTEXITCODE-ne0){throw ('Acceptance binary regression failed: '+$name)}
}
$memoryFiles=@(Get-ChildItem -LiteralPath $bindingRoot -File -Filter 'IsolatedMemory_*.json')
$isolatedFiles=@(Get-ChildItem -LiteralPath $bindingRoot -File -Filter 'Isolated_*.json')
if($memoryFiles.Count-ne1-or$isolatedFiles.Count-ne1){throw 'Both acceptance binary regression reports are required.'}
$memory=Get-Content -LiteralPath $memoryFiles[0].FullName -Raw -Encoding UTF8|ConvertFrom-Json
$isolated=Get-Content -LiteralPath $isolatedFiles[0].FullName -Raw -Encoding UTF8|ConvertFrom-Json
foreach($report in @($memory,$isolated)){if(-not$report.Passed-or$report.FailedCases-ne0-or$report.RuntimeAssemblySha256-cne$info.RuntimeGuardSha256-or$report.ProductionProfileAccessed-or@($report.SkippedDetails).Count-ne0-or-not$report.NormalFixtureUnchanged){throw 'Acceptance regression reports did not bind all passing cases to the exact internal runtime.'}}
if(@($memory.Cases).Count-ne8-or@($isolated.Cases).Count-ne27){throw 'All eight memory and twenty-seven isolation cases are required.'}
$result=[pscustomobject][ordered]@{
    FormatVersion=1;SourceCommit=$env:GITHUB_SHA;Status='A_FOLLOWUP_AUTOMATED_TESTS_PASSED_DESKTOP_BLOCKED'
    Platform='Windows Server 2022 / Windows PowerShell Desktop 5.1 x64';Suites=$suiteResults.ToArray()
    RuntimeAssemblySha256=$info.RuntimeGuardSha256;AcceptanceBinaryMemoryCases=8;AcceptanceBinaryIndependentCases=27
    GeneralReleaseBlocked=$true;IndependentModeReleaseBlocked=$true;DesktopAcceptanceReleaseBlocked=$true
    ExecutableUploaded=$false;DistributionZipCreated=$false;ProductionProfileAccessed=$false
    Windows10GuiVerified=$false;Windows11GuiVerified=$false;CanLaunch=$false
    RemainingA=@('Host compatibility design without policy overrides','OS-enforced installation integrated with package verifier','Provider-specific signing/authorization adapter after developer selection','End-to-end client qualification orchestration')
}
Write-TPBuildNewText (Join-Path $reports ('DesktopAcceptanceFollowup_'+$env:GITHUB_RUN_ID+'_'+$env:GITHUB_RUN_ATTEMPT+'.json')) (ConvertTo-Json -InputObject $result -Depth 20)
if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,"`nAcceptance follow-up: native boundary, readonly diagnostics, backend probes and unchanged-protection host observation passed. Desktop launch and all application publication remain BLOCKED.`n",[Text.UTF8Encoding]::new($false))}
$result
