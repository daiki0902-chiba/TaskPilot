#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateZipPath,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedCandidateSha256='e977b31a8f6eb25c66b8d6d0658b421db13b2db1849b00c33a3234d5d1b70795',
    [ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceCommit='9c7ad91674f7c47784b51305c080405f7c534d80',
    [string]$WindowsVerificationPath,
    [string]$WindowsTestReportPath,
    [ValidatePattern('^[0-9a-f]{40}$')][string]$BasePullRequestHead='c683d4ee80dcd9e66656e3feca04e96072910517',
    [string]$ServerEvidenceRunUrl='https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44640521434'
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
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
$arguments=@{ExpectedCandidateSha256=$ExpectedCandidateSha256;ExpectedSourceCommit=$ExpectedSourceCommit;BasePullRequestHead=$BasePullRequestHead;ServerEvidenceRunUrl=$ServerEvidenceRunUrl}
foreach($name in @('WindowsVerificationPath','WindowsTestReportPath')){if($PSBoundParameters.ContainsKey($name)){$arguments[$name]=$PSBoundParameters[$name]}}

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

$built=& $builder -CandidateZipPath $candidate -OutputRoot (Join-Path $root 'new-package') @arguments
Assert-AcceptancePackaging ([IO.File]::Exists($built.Zip)-and(Get-TPBuildSha $built.Zip)-ceq$built.Sha256) 'Package ZIP/hash differs from the result.'
Assert-AcceptancePackaging ($built.ApplicationFiles-eq136-and-not$built.Windows10Verified-and-not$built.Windows11Verified) 'Packaging claimed client acceptance or lost application files.'
$manifest=Get-Content -LiteralPath (Join-Path $built.PackageRoot 'PACKAGE-MANIFEST.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-AcceptancePackaging ($manifest.CandidateZipSha256-ceq$before-and$manifest.CandidateSourceCommit-ceq$ExpectedSourceCommit) 'Candidate provenance differs.'
Assert-AcceptancePackaging ($manifest.Stage-like'*NOT FOR SALE*'-and-not$manifest.Windows10Verified-and-not$manifest.Windows11Verified-and-not$manifest.InteractiveGuiVerified) 'Manifest overstates commercial or client verification.'
Assert-AcceptancePackaging ($manifest.Files.Count+1-eq$built.FileCount-and@(Get-TPBuildFiles $built.PackageRoot).Count-eq$built.FileCount) 'Manifest does not account for every package file.'
$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($entry in $manifest.Files){
    Assert-AcceptancePackaging ($seen.Add($entry.Path)) 'Duplicate manifest file.'
    $path=Join-Path $built.PackageRoot ($entry.Path.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
    Assert-AcceptancePackaging ([IO.File]::Exists($path)-and([IO.FileInfo]$path).Length-eq$entry.Bytes-and(Get-TPBuildSha $path)-ceq$entry.Sha256) ('Manifest content differs: '+$entry.Path)
}
foreach($required in @('README-ja.md','TEST-CASES-ja.md','RESULT-TEMPLATE-ja.md','LOGS-ja.md','DISTRIBUTION-OPTIONS-ja.md','FILE-LIST.tsv','Tools/Test-TaskPilotAcceptancePackage.ps1','Tools/Collect-TaskPilotAcceptanceLogs.ps1','Evidence/windows-native-results.json','Evidence/windows-native-verification.json','Evidence/windows-build-info.json','Application/TaskPilot/TaskPilot.exe','Application/TaskPilot/TaskPilot.exe.config','Application/TaskPilot/Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Application/TaskPilot/Modules/ImportExcel/EPPlus.dll')){
    Assert-AcceptancePackaging ($seen.Contains($required)) ('Required acceptance item missing: '+$required)
}
$list=Get-Content -LiteralPath (Join-Path $built.PackageRoot 'FILE-LIST.tsv') -Encoding UTF8
Assert-AcceptancePackaging ($list.Count-eq137-and$list[0]-like'Path*SHA256*Purpose') 'Application inventory must list all 136 native files.'
$original=[IO.Compression.ZipFile]::OpenRead($candidate);$compared=0
try{foreach($entry in $original.Entries){
    $name=$entry.FullName.Replace('\','/');if($name.EndsWith('/')){continue}
    $stream=$entry.Open();try{$hash=Get-TPBuildStreamSha $stream}finally{$stream.Dispose()}
    $copied=Join-Path $built.PackageRoot ('Application/'+$name).Replace('/',[string][IO.Path]::DirectorySeparatorChar)
    Assert-AcceptancePackaging ((Get-TPBuildSha $copied)-ceq$hash) ('Native application bytes changed: '+$name)
    $compared++
}}finally{$original.Dispose()}
Assert-AcceptancePackaging ($compared-eq136) 'Not all original application bytes were compared.'
$wrapped=[IO.Compression.ZipFile]::OpenRead($built.Zip)
try{
    Assert-AcceptancePackaging ($wrapped.Entries.Count-eq$built.FileCount) 'ZIP lost or added files.'
    foreach($entry in $wrapped.Entries){Assert-AcceptancePackaging ($entry.FullName.StartsWith('TaskPilot_Acceptance_0.4.0.1/',[StringComparison]::Ordinal)-and-not$entry.FullName.Contains('\')) 'ZIP must use portable relative paths beneath one root.'}
}finally{$wrapped.Dispose()}
Assert-AcceptancePackaging ((Get-TPBuildSha $candidate)-ceq$before) 'Original candidate ZIP was changed.'
return [pscustomobject]@{Passed=$true;Checks=$script:checks;TestRoot=$root;PackageRoot=$built.PackageRoot;ApplicationFiles=$compared;Windows10Verified=$false;Windows11Verified=$false;InteractiveGuiVerified=$false}
