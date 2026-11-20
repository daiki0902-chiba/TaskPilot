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
$candidateRoot=Join-Path $root 'Candidate'

# The provisioner checks the pinned dependency lock and creates no system modules.
$prepared=& (Join-Path $PSScriptRoot 'Get-TaskPilotBuildDependencies.ps1') -DestinationRoot $dependencyRoot
if(-not$prepared.Verified){throw 'Pinned dependency preparation did not return a verified result.'}

# Use the bundled Windows SQLite provider. No TestProviderAssembly/Mono adapter,
# application entry point, WinForms window, or generated EXE is launched here.
$reportRoot=Join-Path $repo 'TestResults'
$oldReports=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if([IO.Directory]::Exists($reportRoot)){
    foreach($file in @(Get-ChildItem -LiteralPath $reportRoot -Filter 'Commercial_*.json' -File)){$null=$oldReports.Add($file.FullName)}
}
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'Test-TaskPilotCommercial.ps1') -DependencyRoot $dependencyRoot
if($LASTEXITCODE-ne0){throw ('Native commercial test runner failed with exit code '+$LASTEXITCODE+'.')}
$newReports=@(Get-ChildItem -LiteralPath $reportRoot -Filter 'Commercial_*.json' -File | Where-Object {-not$oldReports.Contains($_.FullName)})
if($newReports.Count-ne1){throw 'Expected exactly one new commercial test report.'}
$report=Get-Content -LiteralPath $newReports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if($report.Failed-ne0 -or $report.Passed-ne8 -or $report.TestOnlyProvider -or
   -not$report.PinnedBuildDependenciesSupplied -or $report.ProcessBits-ne64 -or $report.PowerShell-notlike'5.1.*'){
    throw 'Native test report did not confirm all eight groups with Windows PowerShell 5.1 and pinned dependencies.'
}

# Build-TaskPilot returns a result object; compiler informational output is not
# the artifact contract. Keep build products disjoint from developer dependencies.
$buildOutput=@(& (Join-Path $PSScriptRoot 'Build-TaskPilot.ps1') -Version '0.4.0.1' -DependencyRoot $dependencyRoot -OutputRoot $buildRoot)
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
$null=[IO.Directory]::CreateDirectory($candidateRoot)
$candidateName='TaskPilot_0.4.0.1_DEVELOPMENT_NOT_FOR_SALE.zip'
Copy-TPBuildNewFile $zip (Join-Path $candidateRoot $candidateName) $build.Sha256
Write-TPBuildNewText (Join-Path $candidateRoot ($candidateName+'.sha256')) ($build.Sha256+'  '+$candidateName+"`n")
foreach($name in @('BuildInfo.json','SoftwareBillOfMaterials.json','FileHashes.json')){
    $source=Join-Path (Join-Path $release 'TaskPilot') $name
    Copy-TPBuildNewFile $source (Join-Path $candidateRoot $name) (Get-TPBuildSha $source)
}
$verification=[ordered]@{
    Status='DEVELOPMENT CANDIDATE - NOT FOR SALE'
    CapturedAtUtc=[datetime]::UtcNow.ToString('o')
    Commit=$env:GITHUB_SHA
    RunnerOS=[Environment]::OSVersion.ToString()
    RunnerImage=$env:ImageOS
    PowerShellEdition=$PSVersionTable.PSEdition
    PowerShellVersion=$PSVersionTable.PSVersion.ToString()
    NativeWindowsAutomatedGroupsPassed=$report.Passed
    TestReport=$newReports[0].Name
    SkippedDetails=@($report.SkippedDetails)
    ExecutableGenerated=$build.ExecutableGenerated
    CandidateSha256=$build.Sha256
    SignatureStatus=$build.SignatureStatus
    Windows10And11AcceptanceVerified=$false
    InteractiveWinFormsVerified=$false
    NotificationDeliveryVerified=$false
    RuntimeAcceptance=$build.RuntimeAcceptance
}
Write-TPBuildNewText (Join-Path $candidateRoot 'WindowsVerification.json') (ConvertTo-Json -InputObject $verification -Depth 8)
$notice='DEVELOPMENT CANDIDATE - NOT FOR SALE. Unsigned. Automated native tests and compilation run on Windows Server 2022. Windows 10/11 acceptance, interactive WinForms behavior and notification delivery remain unverified. Complete the Windows acceptance checklist before sales distribution.'
Write-TPBuildNewText (Join-Path $candidateRoot 'DEVELOPMENT_NOT_FOR_SALE.txt') ($notice+"`n")
if($env:GITHUB_STEP_SUMMARY){[IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,('Native automated test groups passed: '+$report.Passed+".`n`n"+$notice+"`n"),[Text.UTF8Encoding]::new($false))}
Write-Host $notice
Write-Host ('Candidate artifacts: '+$candidateRoot)
