#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VerificationRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native x64 Windows PowerShell 5.1 is required.'}
if(-not$env:RUNNER_TEMP-or$env:GITHUB_SHA-cnotmatch'^[a-f0-9]{40}$'){throw 'Isolated CI roots and source identity are required.'}
$root=Get-TPBuildFullPath $VerificationRoot;$runnerTemp=Get-TPBuildFullPath $env:RUNNER_TEMP
Assert-TPBuildNoLinks $root
if(-not(Test-TPBuildBelow $root $runnerTemp)-or$root-eq$runnerTemp){throw 'VerificationRoot must be below RUNNER_TEMP.'}
$dependency=Join-Path $root 'Dependencies'
if(-not[IO.Directory]::Exists($dependency)){throw 'Verified dependencies from the ordinary regression job are required.'}
$repo=Split-Path -Parent $PSScriptRoot
$reports=Join-Path $repo 'TestResults';$null=[IO.Directory]::CreateDirectory($reports)
$env:TASKPILOT_DESKTOP_ACCEPTANCE_PUBLISH='false'
if($env:GITHUB_ENV){[IO.File]::AppendAllText($env:GITHUB_ENV,('TASKPILOT_DESKTOP_ACCEPTANCE_PUBLISH=false'+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))}
$suites=New-Object 'Collections.Generic.List[object]'
foreach($name in @('Test-AcceptanceAuthority.ps1','Test-DesktopAcceptanceEntry.ps1','Test-DesktopAcceptancePreflight.ps1','Test-DesktopAcceptanceDiagnostics.ps1')){
    $report=& (Join-Path $repo ('tests/'+$name)) -OutputRoot $reports
    if($null-eq$report-or$report.Passed-isnot[bool]-or-not$report.Passed){throw ('Dedicated acceptance regression failed: '+$name)}
    if($name-ceq'Test-AcceptanceAuthority.ps1'-and(-not$report.NativePackageBoundaryExecuted-or$report.NativePackageBoundaryChecks-ne9)){throw 'All nine native package-boundary checks are required on Windows CI.'}
    if($name-ceq'Test-DesktopAcceptanceEntry.ps1'-and-not$report.CompleteEntryNegativeInvoked){throw 'The complete Windows acceptance entry must be invoked and denied before profile access.'}
    $suites.Add($report)
}
$build=@(& (Join-Path $PSScriptRoot 'Build-TaskPilotDesktopAcceptance.ps1') -DependencyRoot $dependency -OutputRoot (Join-Path $root 'DesktopAcceptanceInternal') -InternalCompile)
$built=@($build|Where-Object {$null-ne$_.PSObject.Properties['ExecutableGenerated']})
if($built.Count-ne1-or-not$built[0].ExecutableGenerated-or$built[0].Status-cne'BLOCKED'-or$built[0].Distributable-or$null-ne$built[0].Zip){throw 'Acceptance compiler must produce only a BLOCKED internal negative-test executable.'}
$internal=$built[0]
if($internal.SignatureStatus-cne'NotSigned'){throw 'The CI internal fixture must not be mistaken for an authorized signed build.'}
$sandboxReport=& (Join-Path $repo 'tests/Test-DesktopAcceptanceSandbox.ps1') -RuntimeAssembly (Join-Path $internal.PackageRoot 'Runtime/TaskPilot.TestSandbox.dll') -OutputRoot $reports
if($null-eq$sandboxReport-or-not$sandboxReport.Passed-or$sandboxReport.FailedCases-ne0-or@($sandboxReport.Cases).Count-ne6-or
   -not$sandboxReport.NormalFixtureUnchanged-or-not$sandboxReport.PreviousIndependentFixtureUnchanged-or
   $sandboxReport.ProductionProfileAccessed-or@($sandboxReport.SkippedDetails).Count-ne0-or
   $sandboxReport.RuntimeAssemblySha256-cne$internal.RuntimeGuardSha256){throw 'The acceptance-specific storage namespace regression failed.'}
foreach($id in 1..6){$case=@($sandboxReport.Cases|Where-Object {$_.Id-ceq('A{0:00}'-f$id)});if($case.Count-ne1-or-not$case[0].Passed){throw 'All six acceptance-specific namespace cases are required.'}}
$suites.Add($sandboxReport)
$packaging=& (Join-Path $repo 'tests/Test-DesktopAcceptanceBuild.ps1') -DependencyRoot $dependency -TestRoot (Join-Path $root 'DesktopAcceptancePackagingTests') -InternalPackageRoot $internal.PackageRoot
if($null-eq$packaging-or-not$packaging.Passed){throw 'Dedicated acceptance packaging regression failed.'}
$suites.Add($packaging)
# Invoke ONLY the fixed headless negative-check entry. No GUI is started, no
# process execution policy is changed, and no real profile should be resolved.
$process=New-Object Diagnostics.Process
$process.StartInfo.FileName=$internal.Executable
$process.StartInfo.Arguments='--preflight'
$process.StartInfo.UseShellExecute=$false
$process.StartInfo.CreateNoWindow=$true
try{
    if(-not$process.Start()){throw 'Internal negative-check process did not start.'}
    if(-not$process.WaitForExit(15000)){try{$process.Kill()}catch{};throw 'Internal negative-check process timed out.'}
    if($process.ExitCode-ne2){throw 'Unsigned internal acceptance EXE must deny launch with exit code 2.'}
}finally{$process.Dispose()}
$result=[pscustomobject][ordered]@{
    FormatVersion=1;SourceCommit=$env:GITHUB_SHA;Status='AUTOMATED_TESTS_PASSED_ACCEPTANCE_BLOCKED'
    Platform='Windows Server CI / Windows PowerShell Desktop 5.1 x64';Suites=$suites.ToArray()
    NegativeExecutableExitCode=2;GeneralDistributionBlocked=$true;IndependentModeDistributionBlocked=$true
    InternalExecutableSha256=$internal.ExecutableSha256;RuntimeGuardSha256=$internal.RuntimeGuardSha256
    LauncherSourceSha256=$internal.LauncherSourceSha256;PackageGuardSourceSha256=$internal.PackageGuardSourceSha256
    TrustConfigurationSha256=$internal.TrustConfigurationSha256
    DesktopAcceptanceDistributionBlocked=$true;ExecutableUploaded=$false;ZipCreated=$false
    ProductionProfileAccessed=$false;Windows10GuiVerified=$false;Windows11GuiVerified=$false
    MissingConditions=@('Trusted publisher and signed purpose authorization','Reviewed signed distribution with protected package ACL and original vendor provenance','Safe Windows 10/11 native qualification runner','Reviewed diagnostic reopen protocol','Windows 10/11 interactive acceptance')
}
Write-TPBuildNewText (Join-Path $reports ('DesktopAcceptanceVerification_'+$env:GITHUB_RUN_ID+'_'+$env:GITHUB_RUN_ATTEMPT+'.json')) (ConvertTo-Json -InputObject $result -Depth 16)
if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,"`nDedicated acceptance host compiled and denied unsigned launch. Reports only; EXE/ZIP not uploaded. Desktop acceptance remains BLOCKED.`n",[Text.UTF8Encoding]::new($false))}
$result
