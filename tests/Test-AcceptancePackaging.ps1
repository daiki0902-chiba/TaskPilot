#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateZipPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedCandidateSha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceCommit,
    [Parameter(Mandatory=$true)][string]$WindowsVerificationPath,
    [Parameter(Mandatory=$true)][string]$WindowsTestReportPath,
    [Parameter(Mandatory=$true)][string]$IsolatedModeTestReportPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$BasePullRequestHead,
    [Parameter(Mandatory=$true)][ValidatePattern('^https://github[.]com/daiki0902-chiba/TaskPilot/actions/runs/[0-9]+$')][string]$ServerEvidenceRunUrl
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:checks=0
function Assert-AcceptancePackaging([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
function Reject-AcceptancePackaging([scriptblock]$Action,[string]$Pattern){
    $caught=$null;try{& $Action|Out-Null}catch{$caught=$_}
    Assert-AcceptancePackaging ($null-ne$caught-and$caught.Exception.Message-like$Pattern) ('Expected refusal '+$Pattern+'; actual: '+$caught)
}
function New-AcceptanceTestZip([string]$Path,[string[]]$Names,[switch]$Symlink){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{foreach($name in $Names){
        $entry=$zip.CreateEntry($name)
        if($Symlink){$entry.ExternalAttributes=-1577123840}
        $write=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('synthetic 日本語');$write.Write($bytes,0,$bytes.Length)}finally{$write.Dispose()}
    }}finally{$zip.Dispose();$stream.Dispose()}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotAcceptancePackaging_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$builder=Join-Path $repo 'tools/New-TaskPilotAcceptancePackage.ps1'
$candidate=Get-TPBuildFullPath $CandidateZipPath
$before=Get-TPBuildSha $candidate
$arguments=@{ExpectedCandidateSha256=$ExpectedCandidateSha256;ExpectedSourceCommit=$ExpectedSourceCommit;BasePullRequestHead=$BasePullRequestHead;ServerEvidenceRunUrl=$ServerEvidenceRunUrl;WindowsVerificationPath=$WindowsVerificationPath;WindowsTestReportPath=$WindowsTestReportPath;IsolatedModeTestReportPath=$IsolatedModeTestReportPath}

# Load only the reviewed archive-validation functions; do not run the builder.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($builder,[ref]$tokens,[ref]$errors)
Assert-AcceptancePackaging ($errors.Count-eq0) 'Acceptance builder contains parse errors.'
foreach($functionName in @('Assert-TPAcceptanceRelative','Expand-TPAcceptanceCandidate')){
    $nodes=@($ast.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$functionName},$false))
    Assert-AcceptancePackaging ($nodes.Count-eq1) ('Missing validation function '+$functionName)
    Invoke-Expression $nodes[0].Extent.Text
}
$number=0
foreach($name in @('../outside','TaskPilot/../../outside','/absolute','TaskPilot/C:/bad','TaskPilot/a//b','TaskPilot/NUL.txt','TaskPilot/what?file','TaskPilot/a./b')){
    $number++;$archive=Join-Path $root ('unsafe_'+$number+'.zip');$target=Join-Path $root ('unsafe_output_'+$number)
    New-AcceptanceTestZip $archive @($name)
    Reject-AcceptancePackaging {Expand-TPAcceptanceCandidate $archive $target} '*Unsafe*'
    Assert-AcceptancePackaging (-not(Test-TPBuildPathExists $target)) 'Unsafe archive created an extraction directory.'
}
$duplicate=Join-Path $root 'duplicate.zip';$duplicateOutput=Join-Path $root 'duplicate-output'
New-AcceptanceTestZip $duplicate @('TaskPilot/A.txt','TaskPilot/a.txt')
Reject-AcceptancePackaging {Expand-TPAcceptanceCandidate $duplicate $duplicateOutput} '*Duplicate/case-colliding*'
Assert-AcceptancePackaging (-not(Test-TPBuildPathExists $duplicateOutput)) 'Duplicate archive created output.'
$linkZip=Join-Path $root 'link.zip';$linkOutput=Join-Path $root 'link-output'
New-AcceptanceTestZip $linkZip @('TaskPilot/link') -Symlink
Reject-AcceptancePackaging {Expand-TPAcceptanceCandidate $linkZip $linkOutput} '*Links and special*'
Assert-AcceptancePackaging (-not(Test-TPBuildPathExists $linkOutput)) 'Symlink archive created output.'
$windowsZip=Join-Path $root 'windows-separators.zip';$windowsOutput=Join-Path $root 'windows-separators-output'
New-AcceptanceTestZip $windowsZip @('TaskPilot\folder\file.txt')
Expand-TPAcceptanceCandidate $windowsZip $windowsOutput
Assert-AcceptancePackaging ([IO.File]::ReadAllText((Join-Path $windowsOutput 'TaskPilot/folder/file.txt'))-ceq'synthetic 日本語') 'Windows ZIP separators were not normalized safely.'
$changedOutput=Join-Path $root 'changed-output'
Reject-AcceptancePackaging {Expand-TPAcceptanceCandidate $windowsZip $changedOutput ('0'*64)} '*changed before extraction*'
Assert-AcceptancePackaging (-not(Test-TPBuildPathExists $changedOutput)) 'A candidate changed since inspection created extraction output.'

$wrong=Join-Path $root 'wrong.zip';Write-TPBuildNewText $wrong 'not the native build'
$wrongOutput=Join-Path $root 'wrong-output'
Reject-AcceptancePackaging {& $builder -CandidateZipPath $wrong -OutputRoot $wrongOutput @arguments} '*SHA-256*'
Assert-AcceptancePackaging (-not(Test-TPBuildPathExists $wrongOutput)) 'Wrong candidate hash created output.'
$existing=Join-Path $root 'existing-output';$null=[IO.Directory]::CreateDirectory($existing)
$sentinel=Join-Path $existing 'keep.txt';Write-TPBuildNewText $sentinel 'existing output remains'
$sentinelHash=Get-TPBuildSha $sentinel
Reject-AcceptancePackaging {& $builder -CandidateZipPath $candidate -OutputRoot $existing @arguments} '*already exists*'
Assert-AcceptancePackaging ((Get-TPBuildSha $sentinel)-ceq$sentinelHash-and@(Get-TPBuildFiles $existing).Count-eq1) 'Existing output was changed.'
Reject-AcceptancePackaging {& $builder -CandidateZipPath $candidate -OutputRoot (Join-Path $repo 'forbidden-acceptance-test') @arguments} '*disjoint*'
Assert-AcceptancePackaging (-not(Test-TPBuildPathExists (Join-Path $repo 'forbidden-acceptance-test'))) 'Builder created output inside source.'

# A valid old/native regression report cannot replace proof of mode isolation.
# Tamper only new fixture copies of the supplied report, never its source.
$proofBefore=Get-TPBuildSha $IsolatedModeTestReportPath
$proofNumber=0
foreach($failure in @('NormalFixtureChanged','ExcelNotGenerated','ClientClaimed','SourceMismatch','SkippedBoundaryCase','TooFewCases','FailedNativeCase','MissingI28','DuplicateIds','ProductionClaimed','FileBoundaryUnverified')){
    $proofNumber++
    $fake=Get-Content -LiteralPath $IsolatedModeTestReportPath -Raw -Encoding UTF8|ConvertFrom-Json
    $pattern='*Boolean field*'
    switch($failure){
        'NormalFixtureChanged'{$fake.NormalFixtureUnchanged=$false}
        'ExcelNotGenerated'{$fake.ActualExcelFilesGenerated=$false}
        'ClientClaimed'{$fake.WindowsClientGUIVerified=$true}
        'SourceMismatch'{$fake.SourceCommit='0'*40;if($fake.SourceCommit-ceq$ExpectedSourceCommit){$fake.SourceCommit='1'*40};$pattern='*identify this source*'}
        'SkippedBoundaryCase'{$fake.SkippedDetails=@('synthetic missing boundary case');$pattern='*safety checks were skipped*'}
        'TooFewCases'{$fake.Cases=@($fake.Cases|Select-Object -First 1);$pattern='*required unique native cases*'}
        'FailedNativeCase'{$fake.Cases[0].Passed=$false;$pattern='*required unique native cases*'}
        'MissingI28'{$fake.Cases=@($fake.Cases|Where-Object {$_.Id-cne'I28'});$pattern='*required unique native cases*'}
        'DuplicateIds'{$fake.Cases[-1].Id=$fake.Cases[0].Id;$pattern='*required unique native cases*'}
        'ProductionClaimed'{$fake.ProductionProfileAccessed=$true}
        'FileBoundaryUnverified'{$fake.FileAndAncestorBoundary.CompleteNativeCoverage=$false}
    }
    $fakeProof=Join-Path (Join-Path $root ('invalid-isolation-proof_'+$proofNumber)) ([IO.Path]::GetFileName($IsolatedModeTestReportPath))
    Write-TPBuildNewText $fakeProof (ConvertTo-Json -InputObject $fake -Depth 20) $true
    $negativeArguments=$arguments.Clone();$negativeArguments.IsolatedModeTestReportPath=$fakeProof
    $negativeOutput=Join-Path $root ('invalid-isolation-output_'+$proofNumber)
    Reject-AcceptancePackaging {& $builder -CandidateZipPath $candidate -OutputRoot $negativeOutput @negativeArguments} $pattern
    Assert-AcceptancePackaging (-not(Test-TPBuildPathExists $negativeOutput)) ('Invalid isolated-mode evidence created output: '+$failure)
}
Assert-AcceptancePackaging ((Get-TPBuildSha $IsolatedModeTestReportPath)-ceq$proofBefore) 'The original isolated-mode report was changed.'

# The suite proof must identify the compiled guard that will be distributed.
# This validation can require inspecting the new extraction; no ZIP may be
# published from that partial output when the proof refers to another guard.
$wrongRuntime=Get-Content -LiteralPath $IsolatedModeTestReportPath -Raw -Encoding UTF8|ConvertFrom-Json
$wrongRuntime.RuntimeAssemblySha256='0'*64
$wrongRuntimeProof=Join-Path (Join-Path $root 'invalid-runtime-proof') ([IO.Path]::GetFileName($IsolatedModeTestReportPath))
Write-TPBuildNewText $wrongRuntimeProof (ConvertTo-Json -InputObject $wrongRuntime -Depth 20) $true
$runtimeArguments=$arguments.Clone();$runtimeArguments.IsolatedModeTestReportPath=$wrongRuntimeProof
$wrongRuntimeOutput=Join-Path $root 'invalid-runtime-output'
Reject-AcceptancePackaging {& $builder -CandidateZipPath $candidate -OutputRoot $wrongRuntimeOutput @runtimeArguments} '*tested runtime*'
Assert-AcceptancePackaging (-not[IO.File]::Exists((Join-Path $wrongRuntimeOutput 'TaskPilot_Windows_Acceptance_0.4.0.2.zip'))) 'A mismatched runtime proof published a kit ZIP.'

$built=& $builder -CandidateZipPath $candidate -OutputRoot (Join-Path $root 'new-package') @arguments
Assert-AcceptancePackaging ([IO.File]::Exists($built.Zip)-and(Get-TPBuildSha $built.Zip)-ceq$built.Sha256) 'Package ZIP/hash differs from the result.'
Assert-AcceptancePackaging ($built.ApplicationFiles-ge140-and$built.ApplicationFiles-le256-and-not$built.Windows10Verified-and-not$built.Windows11Verified) 'Packaging claimed client acceptance or lost independent-mode application files.'
$manifest=Get-Content -LiteralPath (Join-Path $built.PackageRoot 'PACKAGE-MANIFEST.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-AcceptancePackaging ($manifest.CandidateZipSha256-ceq$before-and$manifest.CandidateSourceCommit-ceq$ExpectedSourceCommit) 'Candidate provenance differs.'
Assert-AcceptancePackaging ($manifest.BinaryVersion-ceq'0.4.0.2'-and$manifest.ApplicationFiles-eq$built.ApplicationFiles) 'The kit must identify the isolated test-mode binary.'
Assert-AcceptancePackaging ($manifest.Stage-like'*NOT FOR SALE*'-and-not$manifest.Windows10Verified-and-not$manifest.Windows11Verified-and-not$manifest.InteractiveGuiVerified) 'Manifest overstates commercial or client verification.'
Assert-AcceptancePackaging ($manifest.Files.Count+1-eq$built.FileCount-and@(Get-TPBuildFiles $built.PackageRoot).Count-eq$built.FileCount) 'Manifest does not account for every package file.'
$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($entry in $manifest.Files){
    Assert-AcceptancePackaging ($seen.Add($entry.Path)) 'Duplicate manifest file.'
    $path=Join-Path $built.PackageRoot ($entry.Path.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
    Assert-AcceptancePackaging ([IO.File]::Exists($path)-and([IO.FileInfo]$path).Length-eq$entry.Bytes-and(Get-TPBuildSha $path)-ceq$entry.Sha256) ('Manifest content differs: '+$entry.Path)
}
foreach($required in @('README-ja.md','TEST-MODE-ja.md','TEST-CASES-ja.md','RESULT-TEMPLATE-ja.md','LOGS-ja.md','DISTRIBUTION-OPTIONS-ja.md','FILE-LIST.tsv','Tools/Test-TaskPilotAcceptancePackage.ps1','Tools/Collect-TaskPilotAcceptanceLogs.ps1','Evidence/windows-native-results.json','Evidence/windows-native-verification.json','Evidence/windows-build-info.json','Evidence/windows-isolated-mode-results.json','Application/TaskPilot/TaskPilot.exe','Application/TaskPilot/TaskPilot.exe.config','Application/TaskPilot/Adapters/TaskPilot.GuiIsolation.ps1','Application/TaskPilot/Runtime/TaskPilot.Runtime.ps1','Application/TaskPilot/Runtime/TaskPilot.TestSandbox.dll','Application/TaskPilot/Codec/TaskPilotMigrationCodec.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Application/TaskPilot/Modules/ImportExcel/EPPlus.dll')){
    Assert-AcceptancePackaging ($seen.Contains($required)) ('Required acceptance item missing: '+$required)
}
$buildEvidence=Get-Content -LiteralPath (Join-Path $built.PackageRoot 'Evidence/windows-build-info.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-AcceptancePackaging ($buildEvidence.IndependentTestModeSupported-is[bool]-and$buildEvidence.IndependentTestModeSupported) 'The built application must explicitly support independent test mode.'
foreach($compiled in @(@('RuntimeGuardSha256','Runtime/TaskPilot.TestSandbox.dll'),@('CodecRuntimeSha256','Codec/TaskPilotMigrationCodec.dll'))){
    $declared=$buildEvidence.PSObject.Properties[$compiled[0]]
    $actual=Get-TPBuildSha (Join-Path $built.PackageRoot ('Application/TaskPilot/'+$compiled[1]))
    Assert-AcceptancePackaging ($null-ne$declared-and$declared.Value-is[string]-and$declared.Value-ceq$actual) ('Compiled runtime DLL must match its native build evidence: '+$compiled[1])
}
$list=Get-Content -LiteralPath (Join-Path $built.PackageRoot 'FILE-LIST.tsv') -Encoding UTF8
Assert-AcceptancePackaging ($list.Count-eq$built.ApplicationFiles+1-and$list[0]-like'Path*SHA256*Purpose') 'Application inventory must list all native files.'
$original=[IO.Compression.ZipFile]::OpenRead($candidate);$compared=0
try{foreach($entry in $original.Entries){
    $name=$entry.FullName.Replace('\','/');if($name.EndsWith('/')){continue}
    $stream=$entry.Open();try{$hash=Get-TPBuildStreamSha $stream}finally{$stream.Dispose()}
    $copied=Join-Path $built.PackageRoot ('Application/'+$name).Replace('/',[string][IO.Path]::DirectorySeparatorChar)
    Assert-AcceptancePackaging ((Get-TPBuildSha $copied)-ceq$hash) ('Native application bytes changed: '+$name)
    $compared++
}}finally{$original.Dispose()}
Assert-AcceptancePackaging ($compared-eq$built.ApplicationFiles) 'Not all original application bytes were compared.'
$wrapped=[IO.Compression.ZipFile]::OpenRead($built.Zip)
try{
    Assert-AcceptancePackaging ($wrapped.Entries.Count-eq$built.FileCount) 'ZIP lost or added files.'
    foreach($entry in $wrapped.Entries){Assert-AcceptancePackaging ($entry.FullName.StartsWith('TaskPilot_Acceptance_0.4.0.2/',[StringComparison]::Ordinal)-and-not$entry.FullName.Contains('\')) 'ZIP must use portable relative paths beneath one root.'}
}finally{$wrapped.Dispose()}
Assert-AcceptancePackaging ((Get-TPBuildSha $candidate)-ceq$before) 'Original candidate ZIP was changed.'
return [pscustomobject]@{Passed=$true;Checks=$script:checks;TestRoot=$root;PackageRoot=$built.PackageRoot;ApplicationFiles=$compared;Windows10Verified=$false;Windows11Verified=$false;InteractiveGuiVerified=$false}
