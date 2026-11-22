#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VerificationRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# CI preparation only. Never launches TaskPilot, imports its storage module,
# edits user data, removes download-origin metadata or changes machine policy.
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or
   $PSVersionTable.PSEdition-ne'Desktop'-or
   $PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or
   -not[Environment]::Is64BitProcess){
    throw 'Acceptance preparation requires native 64-bit Windows PowerShell Desktop 5.1 on the Windows Server CI runner.'
}
foreach($name in @('RUNNER_TEMP','GITHUB_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT')){
    if([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))){throw ('Required CI environment field is absent: '+$name)}
}
if($env:GITHUB_SHA-cnotmatch'^[a-f0-9]{40}$'-or$env:GITHUB_RUN_ID-cnotmatch'^[0-9]+$'-or$env:GITHUB_RUN_ATTEMPT-cnotmatch'^[0-9]+$'){
    throw 'CI commit, run ID or attempt is invalid.'
}
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
$repo=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
$runnerTemp=Get-TPBuildFullPath $env:RUNNER_TEMP
$root=Get-TPBuildFullPath $VerificationRoot
$expectedRoot=Join-Path $runnerTemp ('TaskPilot-native-'+$env:GITHUB_RUN_ID+'-'+$env:GITHUB_RUN_ATTEMPT)
Assert-TPBuildNoLinks $root
if($root-ine$expectedRoot-or-not(Test-TPBuildBelow $root $runnerTemp)-or-not[IO.Directory]::Exists($root)){
    throw 'VerificationRoot must be the existing isolated output of this CI run.'
}
$candidateDirectory=Join-Path $root 'Candidate'
$candidate=Join-Path $candidateDirectory 'TaskPilot_0.4.0.2_DEVELOPMENT_NOT_FOR_SALE.zip'
$verificationPath=Join-Path $candidateDirectory 'WindowsVerification.json'
foreach($path in @($candidate,$verificationPath)){
    Assert-TPBuildNoLinks $path
    if(-not[IO.File]::Exists($path)){throw ('Native CI artifact is missing: '+$path)}
}
$proof=Get-Content -LiteralPath $verificationPath -Raw -Encoding UTF8|ConvertFrom-Json
if($proof.Commit-cne$env:GITHUB_SHA-or$proof.CandidateSha256-cnotmatch'^[a-f0-9]{64}$'-or
   $proof.TestReport-cnotmatch'^Commercial_[a-f0-9]{32}[.]json$'-or
   $proof.IsolatedModeTestReport-cnotmatch'^Isolated_[a-f0-9]{32}[.]json$'-or
   -not$proof.IsolatedModeAutomatedTestsPassed-or-not$proof.SyntheticNormalFixtureUnchanged-or
   $proof.NativeWindowsAutomatedGroupsPassed-ne8-or-not$proof.ExecutableGenerated-or
   $proof.SignatureStatus-cne'NotSigned'-or$proof.Windows10And11AcceptanceVerified-or
   $proof.InteractiveWinFormsVerified-or$proof.NotificationDeliveryVerified){
    throw 'Native CI proof must describe this unsigned build and preserve unverified Windows client acceptance.'
}
if((Get-TPBuildSha $candidate)-cne$proof.CandidateSha256){throw 'Native candidate ZIP does not match its CI proof.'}
$nativeTestReport=Join-Path (Join-Path $repo 'TestResults') $proof.TestReport
Assert-TPBuildNoLinks $nativeTestReport
if(-not[IO.File]::Exists($nativeTestReport)){throw 'The native commercial test report is missing.'}
$isolatedTestReport=Join-Path (Join-Path $repo 'TestResults') $proof.IsolatedModeTestReport
Assert-TPBuildNoLinks $isolatedTestReport
if(-not[IO.File]::Exists($isolatedTestReport)){throw 'The native independent-mode safety report is missing.'}
$isolated=Get-Content -LiteralPath $isolatedTestReport -Raw -Encoding UTF8|ConvertFrom-Json
if($isolated.SourceCommit-cne$env:GITHUB_SHA-or-not$isolated.Passed-or-not$isolated.NormalFixtureUnchanged-or
   -not$isolated.ActualExcelFilesGenerated-or$isolated.ApplicationRunCalled-or$isolated.WindowsClientGUIVerified-or
   $isolated.FailedCases-ne0-or@($isolated.Cases).Count-lt14-or@($isolated.SkippedDetails).Count-ne0){throw 'Independent-mode evidence does not authorize publishing this candidate.'}
$reportDirectory=Join-Path (Join-Path $repo 'TestResults') ('AcceptancePreparation_'+$env:GITHUB_RUN_ID+'_'+$env:GITHUB_RUN_ATTEMPT)
Assert-TPBuildNoLinks $reportDirectory
if(Test-TPBuildPathExists $reportDirectory){throw 'Acceptance preparation needs a new report directory.'}
$null=[IO.Directory]::CreateDirectory($reportDirectory)
$summary=[ordered]@{
    Stage='Windows Server acceptance preparation - NOT FOR SALE'
    CapturedAtUtc=[datetime]::UtcNow.ToString('o')
    Status='RUNNING'
    SourceCommit=$env:GITHUB_SHA
    ServerRunUrl=('https://github.com/daiki0902-chiba/TaskPilot/actions/runs/'+$env:GITHUB_RUN_ID)
    ServerOnly=$true
    Windows10AcceptanceVerified=$false
    Windows11AcceptanceVerified=$false
    InteractiveGuiVerified=$false
    NotificationDeliveryVerified=$false
    WindowsClientExcelOutputVerified=$false
    ApplicationLaunched=$false
    SourceDataModified=$false
    Package=$null
    PackagingTests=$null
    ToolsTests=$null
    PreflightStatus=$null
    IndependentPreflightStatus=$null
    IndependentModeSyntheticChecksPassed=$true
    ActualExcelGeneratedBySyntheticSuite=$true
    Collector=$null
    Error=$null
}
try{
    $arguments=@{
        CandidateZipPath=$candidate
        ExpectedCandidateSha256=[string]$proof.CandidateSha256
        ExpectedSourceCommit=$env:GITHUB_SHA
        WindowsVerificationPath=$verificationPath
        WindowsTestReportPath=$nativeTestReport
        IsolatedModeTestReportPath=$isolatedTestReport
        BasePullRequestHead=$env:GITHUB_SHA
        ServerEvidenceRunUrl=$summary.ServerRunUrl
    }
    $packagingTests=& (Join-Path $repo 'tests/Test-AcceptancePackaging.ps1') @arguments
    if(-not$packagingTests.Passed-or$packagingTests.Windows10Verified-or$packagingTests.Windows11Verified-or$packagingTests.InteractiveGuiVerified){
        throw 'Acceptance packaging tests failed or made an unsupported client acceptance claim.'
    }
    Write-TPBuildNewText (Join-Path $reportDirectory 'PackagingTests.json') (ConvertTo-Json -InputObject $packagingTests -Depth 8)
    $summary.PackagingTests=$packagingTests
    $package=& (Join-Path $PSScriptRoot 'New-TaskPilotAcceptancePackage.ps1') @arguments -OutputRoot (Join-Path $root 'Acceptance')
    if($package.ApplicationFiles-lt139-or$package.FileCount-lt153-or$package.Windows10Verified-or$package.Windows11Verified-or
       (Get-TPBuildSha $package.Zip)-cne$package.Sha256){throw 'Acceptance kit output or safety boundaries did not match the packaging contract.'}
    $summary.Package=$package
    Write-TPBuildNewText (Join-Path $reportDirectory 'AcceptancePackage.json') (ConvertTo-Json -InputObject $package -Depth 8)

    # This runner is deliberately not Windows 10/11. The checker must reject
    # the host while still verifying the candidate files and their origin ADS.
    $preflight=& (Join-Path $PSScriptRoot 'Test-TaskPilotAcceptancePackage.ps1') -PackageRoot $package.PackageRoot -OutputRoot $reportDirectory -FirstUse
    $hostChecks=@($preflight.Checks|Where-Object {$_.Name-ceq'Windows10Or11Desktop51x64'})
    $integrityChecks=@($preflight.Checks|Where-Object {$_.Name-ceq'PackageIntegrity'})
    $originChecks=@($preflight.Checks|Where-Object {$_.Name-ceq'DownloadOrigin'})
    if($preflight.Status-cne'BLOCKED'-or$preflight.Environment.ProductType-notin@(2,3)-or
       $hostChecks.Count-ne1-or$hostChecks[0].Passed-or$integrityChecks.Count-ne1-or-not$integrityChecks[0].Passed-or
       $originChecks.Count-ne1-or-not$originChecks[0].Passed){
        throw 'Server preflight must block the client-only host check while verifying package integrity and origin without launching the application.'
    }
    $summary.PreflightStatus=$preflight.Status
    Write-TPBuildNewText (Join-Path $reportDirectory 'Preflight.json') (ConvertTo-Json -InputObject $preflight -Depth 12)

    # On Server, the independent-mode check must stop at the client-host gate.
    # It must not inspect ordinary TaskPilot paths or create a real profile's
    # test environment just to make this CI check green.
    $independent=& (Join-Path $PSScriptRoot 'Test-TaskPilotAcceptancePackage.ps1') -PackageRoot $package.PackageRoot -OutputRoot $reportDirectory -TestMode -TestEnvironmentId ([guid]::NewGuid().ToString('N'))
    $independentChecks=@($independent.Checks|Where-Object {$_.Name-ceq'TestModeIsolation'})
    if($independent.Status-cne'BLOCKED'-or$independentChecks.Count-ne1-or$independentChecks[0].Passed-or$independent.TestAreaPrepared){
        throw 'Server independent-mode preflight must be blocked without preparing any real profile test area.'
    }
    $summary.IndependentPreflightStatus=$independent.Status
    Write-TPBuildNewText (Join-Path $reportDirectory 'IndependentPreflight.json') (ConvertTo-Json -InputObject $independent -Depth 12)

    $toolsTests=& (Join-Path $repo 'tests/Test-AcceptanceTools.ps1') -PackageRoot $package.PackageRoot -OutputRoot $reportDirectory
    if(-not$toolsTests.Passed-or$toolsTests.ClientAcceptanceVerified-or$toolsTests.ApplicationLaunched){throw 'Acceptance diagnostic/preflight fixture tests failed or made an unsupported client/app-execution claim.'}
    $summary.ToolsTests=$toolsTests
    Write-TPBuildNewText (Join-Path $reportDirectory 'ToolsTests.json') (ConvertTo-Json -InputObject $toolsTests -Depth 12)

    # Explicit empty synthetic logs, never the runner profile's app logs.
    $emptyLogs=Join-Path $reportDirectory 'EmptySyntheticLogs'
    if(Test-TPBuildPathExists $emptyLogs){throw 'Synthetic log directory must be new.'}
    $null=[IO.Directory]::CreateDirectory($emptyLogs)
    $collector=& (Join-Path $PSScriptRoot 'Collect-TaskPilotAcceptanceLogs.ps1') -ApplicationDirectory (Join-Path $package.PackageRoot 'Application/TaskPilot') -OutputRoot $reportDirectory -LogDirectory $emptyLogs -CaseId 'CI-PREPARATION' -Reproduction 'Windows Server preparation only. No application, provider, GUI or generated EXE was launched. No user logs were read.'
    if($collector.SourceDataModified-or$collector.Uploaded-or$collector.LogsSelected-ne0){throw 'CI diagnostic collection exceeded the empty synthetic log boundary.'}
    $summary.Collector=$collector
    foreach($name in @('Environment.json','CandidateFiles.json','Collection.json')){
        $source=Join-Path $collector.Directory $name
        Copy-TPBuildNewFile $source (Join-Path $reportDirectory ('Collector'+$name)) (Get-TPBuildSha $source)
    }
    $summary.Status='PASSED_SERVER_PREPARATION_ONLY'
    $notice='Independent-mode acceptance kit preparation passed on Windows Server 2022. Both client preflight modes correctly report BLOCKED on Server. Synthetic independent-mode storage and real Excel generation were verified; Windows 10/11 generated-EXE startup, interactive UI, notification delivery and external Excel viewing remain unverified.'
    if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,($notice+"`n"),[Text.UTF8Encoding]::new($false))}
    Write-Host $notice
}catch{$summary.Status='FAILED';$summary.Error=$_.Exception.Message;throw}
finally{
    Write-TPBuildNewText (Join-Path $reportDirectory 'PreparationSummary.json') (ConvertTo-Json -InputObject $summary -Depth 14)
}
