#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VerificationRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT -or
   $PSVersionTable.PSEdition-ne'Desktop' -or
   $PSVersionTable.PSVersion.Major-ne5 -or $PSVersionTable.PSVersion.Minor-ne1 -or
   -not[Environment]::Is64BitProcess){
    throw 'Native verification requires 64-bit Windows PowerShell Desktop 5.1 on Windows.'
}
if(-not$env:RUNNER_TEMP){throw 'RUNNER_TEMP must identify the isolated CI temporary directory.'}
if($env:GITHUB_SHA-cnotmatch'^[a-f0-9]{40}$'){throw 'A full CI source commit is required for isolated-mode evidence.'}
$env:TASKPILOT_PUBLISH_CANDIDATE='false'
if($env:GITHUB_ENV){[IO.File]::AppendAllText($env:GITHUB_ENV,('TASKPILOT_PUBLISH_CANDIDATE=false'+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))}
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
$root=Get-TPBuildFullPath $VerificationRoot
$runnerTemp=Get-TPBuildFullPath $env:RUNNER_TEMP
Assert-TPBuildNoLinks $root
if($root-eq$runnerTemp -or -not(Test-TPBuildBelow $root $runnerTemp)){
    throw 'VerificationRoot must be a new directory below RUNNER_TEMP.'
}
if(Test-TPBuildPathExists $root){throw 'VerificationRoot already exists; choose a new CI directory.'}
$null=[IO.Directory]::CreateDirectory($root)
$repo=Split-Path -Parent $PSScriptRoot
$dependencyRoot=Join-Path $root 'Dependencies'
$buildRoot=Join-Path $root 'Build'
$reportRoot=Join-Path $repo 'TestResults'
$null=[IO.Directory]::CreateDirectory($reportRoot)

# The provisioner checks the pinned dependency lock and creates no system modules.
$prepared=& (Join-Path $PSScriptRoot 'Get-TaskPilotBuildDependencies.ps1') -DestinationRoot $dependencyRoot
if(-not$prepared.Verified){throw 'Pinned dependency preparation did not return a verified result.'}

# Use the bundled Windows SQLite provider. No TestProviderAssembly/Mono adapter,
# application entry point, WinForms window, or generated EXE is launched here.
$reportRoot=Join-Path $repo 'TestResults'
$null=[IO.Directory]::CreateDirectory($reportRoot)
$releaseGate=& (Join-Path $repo 'tests/Test-IsolatedReleaseGate.ps1') -OutputRoot $reportRoot
if(-not$releaseGate.Passed-or$releaseGate.ApplicationLaunched-or$releaseGate.ProductionProfileAccessed-or$releaseGate.TestAreaPrepared){throw 'The disabled public test-mode entry points did not fail closed.'}
Write-Host ('PASS: public independent-mode release gate; '+$releaseGate.Checks+' assertions; no production profile or application launch.')
$oldReports=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if([IO.Directory]::Exists($reportRoot)){
    foreach($file in @(Get-ChildItem -LiteralPath $reportRoot -Filter 'Commercial_*.json' -File)){$null=$oldReports.Add($file.FullName)}
}
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $repo 'Test-TaskPilotCommercial.ps1') -DependencyRoot $dependencyRoot
if($LASTEXITCODE-ne0){throw ('Native commercial test runner failed with exit code '+$LASTEXITCODE+'.')}
$newReports=@(Get-ChildItem -LiteralPath $reportRoot -Filter 'Commercial_*.json' -File | Where-Object {-not$oldReports.Contains($_.FullName)})
if($newReports.Count-ne1){throw 'Expected exactly one new commercial test report.'}
$report=Get-Content -LiteralPath $newReports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if($report.Failed-ne0 -or $report.Passed-ne8 -or -not$report.AllEightGroupsExecuted -or @($report.UnselectedSuites).Count-ne0 -or $report.TestOnlyProvider -or
   -not$report.PinnedBuildDependenciesSupplied -or $report.ProcessBits-ne64 -or $report.PowerShell-notlike'5.1.*'){
    throw 'Native test report did not confirm all eight groups with Windows PowerShell 5.1 and pinned dependencies.'
}

# Build-TaskPilot returns a result object; compiler informational output is not
# the artifact contract. Keep build products disjoint from developer dependencies.
$buildOutput=@(& (Join-Path $PSScriptRoot 'Build-TaskPilot.ps1') -Version '0.4.0.2' -DependencyRoot $dependencyRoot -OutputRoot $buildRoot)
$buildResults=@($buildOutput | Where-Object {$null-ne$_.PSObject.Properties['Zip'] -and $null-ne$_.PSObject.Properties['ReleaseRoot']})
if($buildResults.Count-ne1){throw 'Builder did not return exactly one artifact result.'}
$build=$buildResults[0]
if(-not$build.ExecutableGenerated -or $build.SignatureStatus-ne'NotSigned'){
    throw 'Expected an unsigned development candidate from the native builder.'
}
$zip=Get-TPBuildFullPath $build.Zip
$release=Get-TPBuildFullPath $build.ReleaseRoot
if(-not(Test-TPBuildBelow $zip $buildRoot) -or -not(Test-TPBuildBelow $release $buildRoot) -or
   -not[IO.File]::Exists($zip) -or (Get-TPBuildSha $zip)-cne$build.Sha256){
    throw 'Builder artifact paths or ZIP hash did not match the candidate build.'
}
# Shared boundary regressions use an entirely synthetic ordinary profile.
# The executable remains unpublished after these checks. The suite starts
# only its synthetic normal-lock holder, never TaskPilot/Application.Run.
$runtimeAssembly=Join-Path (Join-Path $release 'TaskPilot') 'Runtime/TaskPilot.TestSandbox.dll'
Assert-TPBuildNoLinks $runtimeAssembly
if(-not[IO.File]::Exists($runtimeAssembly)){throw 'The precompiled independent-mode runtime DLL is missing.'}
$nativeBuildInfo=Get-Content -LiteralPath (Join-Path (Join-Path $release 'TaskPilot') 'BuildInfo.json') -Raw -Encoding UTF8|ConvertFrom-Json
if(-not$nativeBuildInfo.IndependentTestModeImplemented-or$nativeBuildInfo.Version-cne'0.4.0.2'-or
   $nativeBuildInfo.RuntimeGuardSha256-cne(Get-TPBuildSha $runtimeAssembly)){throw 'The compiled runtime does not match the candidate build metadata.'}
# One ordinary build is the source of the shared-code runtime under test.
# A separate smoke process avoids LoadFrom reuse; no second DLL is compiled.
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -File (Join-Path $repo 'tests/Test-SandboxHandleSmoke.ps1') -RuntimeAssembly $runtimeAssembly -OutputRoot $reportRoot
if($LASTEXITCODE-ne0){throw 'Native handle smoke failed; see its JSON report.'}
$memory=& (Join-Path $repo 'tests/Test-IsolatedMemoryStore.ps1') -RuntimeAssembly $runtimeAssembly -OutputRoot $reportRoot
$memoryPassed=$null-ne$memory-and$memory.Passed-is[bool]-and$memory.Passed-and$memory.FailedCases-eq0-and@($memory.Cases).Count-eq8-and$memory.NormalFixtureUnchanged-is[bool]-and$memory.NormalFixtureUnchanged-and$memory.ProductionProfileAccessed-is[bool]-and-not$memory.ProductionProfileAccessed-and@($memory.SkippedDetails).Count-eq0-and$memory.RuntimeAssemblySha256-ceq$nativeBuildInfo.RuntimeGuardSha256
if($memoryPassed){
    foreach($index in 1..8){
        $case=@($memory.Cases|Where-Object {$_.Id-ceq('M{0:00}'-f$index)})
        if($case.Count-ne1-or$case[0].Passed-isnot[bool]-or-not$case[0].Passed){$memoryPassed=$false;break}
    }
}
$isolated=& (Join-Path $repo 'tests/Test-IsolatedTestMode.ps1') -RuntimeAssembly $runtimeAssembly -DependencyRoot $dependencyRoot -OutputRoot $reportRoot
$requiredIsolationIds=@(1..22|ForEach-Object {'I{0:00}'-f$_})+@(24..28|ForEach-Object {'I{0:00}'-f$_})
$completeIsolationCases=$null-ne$isolated-and@($isolated.Cases).Count-eq$requiredIsolationIds.Count
if($completeIsolationCases){
    foreach($id in $requiredIsolationIds){
        $case=@($isolated.Cases|Where-Object {$_.Id-ceq$id})
        if($case.Count-ne1-or$case[0].Passed-isnot[bool]-or-not$case[0].Passed){$completeIsolationCases=$false;break}
    }
}
if($null-eq$isolated-or$isolated.Passed-isnot[bool]-or-not$isolated.Passed-or
   -not$memoryPassed-or
   -not$completeIsolationCases-or$isolated.ProductionProfileAccessed-isnot[bool]-or$isolated.ProductionProfileAccessed-or
   $null-eq$isolated.FileAndAncestorBoundary-or-not$isolated.FileAndAncestorBoundary.Passed-or
   -not$isolated.FileAndAncestorBoundary.CompleteNativeCoverage-or$isolated.FileAndAncestorBoundary.UnsafeVectorConfirmed-or
   -not$isolated.FileAndAncestorBoundary.NormalFixtureUnchanged-or
   $isolated.NormalFixtureUnchanged-isnot[bool]-or-not$isolated.NormalFixtureUnchanged-or
   $isolated.ActualExcelFilesGenerated-isnot[bool]-or-not$isolated.ActualExcelFilesGenerated-or
   $isolated.WindowsClientGUIVerified-isnot[bool]-or$isolated.WindowsClientGUIVerified-or
   $isolated.ApplicationRunCalled-isnot[bool]-or$isolated.ApplicationRunCalled-or
   $isolated.RuntimeAssemblySha256-cne$nativeBuildInfo.RuntimeGuardSha256-or
   $isolated.FailedCases-ne0-or@($isolated.Cases).Count-lt14-or@($isolated.SkippedDetails).Count-ne0){
    # Preserve the failed proof as well; the workflow always uploads these
    # reports, but does not upload an executable or acceptance kit on failure.
    if($null-ne$isolated){
        $isolated|Add-Member -NotePropertyName SourceCommit -NotePropertyValue $env:GITHUB_SHA -Force
        Write-TPBuildNewText (Join-Path $reportRoot ('Isolated_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $isolated -Depth 16)
    }
    throw 'Independent-mode safety verification failed, was skipped, or made an unsupported Windows client claim. No candidate will be published.'
}
$isolated|Add-Member -NotePropertyName SourceCommit -NotePropertyValue $env:GITHUB_SHA -Force
$isolated|Add-Member -NotePropertyName RunnerImage -NotePropertyValue $env:ImageOS -Force
$isolatedName='Isolated_'+[guid]::NewGuid().ToString('N')+'.json'
Write-TPBuildNewText (Join-Path $reportRoot $isolatedName) (ConvertTo-Json -InputObject $isolated -Depth 16)
# The ordinary product is the only build. Shared boundary tests are test
# harnesses over its common modules, not additional supported application modes.
# Publication cannot be re-enabled by changing build metadata or environment.
$validation=[pscustomobject][ordered]@{
    Status='NORMAL_PRODUCT_TESTS_PASSED_DISTRIBUTION_BLOCKED';SourceCommit=$env:GITHUB_SHA
    ProductEntry='TaskPilot.exe';ProductBuilds=1;SpecialFlavorBuilds=0
    NativeNormalGroupsPassed=8;PublicReleaseGateChecks=$releaseGate.Checks
    NormalSkippedDetails=@($report.SkippedDetails)
    MemoryCasesPassed=@($memory.Cases).Count;SharedBoundaryCasesPassed=@($isolated.Cases).Count
    NormalFixtureUnchanged=$isolated.NormalFixtureUnchanged;ActualExcelFilesGenerated=$isolated.ActualExcelFilesGenerated
    RuntimeAssemblySha256=$nativeBuildInfo.RuntimeGuardSha256;SharedBoundaryReport=$isolatedName
    Windows10And11AcceptanceVerified=$false;ApplicationLaunched=$false;ProductionProfileAccessed=$false
    ExecutableGenerated=$true;ExecutablePublished=$false;DistributionZipPublished=$false
    GeneralDistributionBlocked=$true;IndependentModeBlocked=$true;FormalAcceptanceBlocked=$true
    FrozenFlavorSources=@('acceptance/','local-validation/')
    Reason='Normal product and common-code regressions passed on Windows Server. No GUI launch or application artifact publication is authorized.'
}
Write-TPBuildNewText (Join-Path $reportRoot ('NormalVerification_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $validation -Depth 10)
if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,('One normal product build; eight normal groups and shared protection regressions passed once. DISTRIBUTION REMAINS BLOCKED.'+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))}
$validation
