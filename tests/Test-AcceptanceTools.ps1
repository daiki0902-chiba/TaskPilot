#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$kit=Get-TPBuildFullPath $PackageRoot
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $kit;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($kit)-or-not[IO.Directory]::Exists($output)-or(Test-TPBuildBelow $output $kit)){throw 'An intact package and an existing, separate test output directory are required.'}
$fixture=Join-Path $output ('AcceptanceTools_'+[guid]::NewGuid().ToString('N'))
if(Test-TPBuildPathExists $fixture){throw 'A new test fixture is required.'}
$null=[IO.Directory]::CreateDirectory($fixture)
$checker=Join-Path $repo 'tools/Test-TaskPilotAcceptancePackage.ps1'
$collector=Join-Path $repo 'tools/Collect-TaskPilotAcceptanceLogs.ps1'
$script:TPATChecks=0
$skips=New-Object 'Collections.Generic.List[string]'
$tpToolIsWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
function Assert-TPAT([bool]$Condition,[string]$Message){$script:TPATChecks++;if(-not$Condition){throw $Message}}
function Get-TPATCheck($Report,[string]$Name){
    $found=@($Report.Checks|Where-Object {$_.Name-ceq$Name})
    Assert-TPAT ($found.Count-eq1) ('Expected exactly one preflight check: '+$Name)
    return $found[0]
}
function Get-TPATSnapshot([string]$Root){
    return (@(Get-TPBuildFiles $Root|ForEach-Object {$_.FullName.Substring($Root.Length)+' '+(Get-TPBuildSha $_.FullName)})-join"`n")
}
$original=Get-TPATSnapshot $kit
$initial=& $checker -PackageRoot $kit -OutputRoot $fixture
Assert-TPAT ((Get-TPATCheck $initial 'PackageIntegrity').Passed) 'The intact package must pass file/evidence checks.'
Assert-TPAT ($initial.Status-cne'READY_FOR_MANUAL_TEST'-and$initial.Isolation-ceq'NOT_CHECKED') 'A file check without FirstUse must never approve launch.'
Assert-TPAT ([IO.File]::Exists($initial.ReportPath)) 'A preflight report must be written to a new results child.'
$fresh=& $checker -PackageRoot $kit -OutputRoot $fixture -FirstUse
$osCheck=Get-TPATCheck $fresh 'Windows10Or11Desktop51x64'
if(-not$osCheck.Passed){Assert-TPAT ($fresh.Status-ceq'BLOCKED') 'Server/Linux must not claim Windows 10/11 readiness.'}
if($tpToolIsWindows){Assert-TPAT ((Get-TPATCheck $fresh 'DownloadOrigin').Passed) 'Native fixture origin streams must be readable without security changes.'}

# Every negative mutation is in a new synthetic copy, never in the supplied kit.
$copy=Join-Path $fixture 'KitCopy'
$null=[IO.Directory]::CreateDirectory($copy)
foreach($file in @(Get-TPBuildFiles $kit)){
    $relative=$file.FullName.Substring($kit.Length+1)
    Copy-TPBuildNewFile $file.FullName (Join-Path $copy $relative) (Get-TPBuildSha $file.FullName)
}
$readme=Join-Path $copy 'README-ja.md'
[IO.File]::AppendAllText($readme,"`nSynthetic tamper test.")
$tampered=& $checker -PackageRoot $copy
Assert-TPAT (-not(Get-TPATCheck $tampered 'PackageIntegrity').Passed-and$tampered.Status-ceq'BLOCKED') 'Changed content must block launch.'
[IO.File]::WriteAllBytes($readme,[IO.File]::ReadAllBytes((Join-Path $kit 'README-ja.md')))
$extra=Join-Path $copy 'Unexpected.db'
Write-TPBuildNewText $extra 'Synthetic marker, not a database.'
$extraResult=& $checker -PackageRoot $copy
Assert-TPAT (-not(Get-TPATCheck $extraResult 'PackageIntegrity').Passed) 'Unexpected data must block a baseline package.'
# Remove only this test-owned marker so later independent cases use the same copy.
[IO.File]::Delete($extra)
$manifestPath=Join-Path $copy 'PACKAGE-MANIFEST.json'
$manifestBytes=[IO.File]::ReadAllBytes($manifestPath)
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
$manifest.Files[0].Path='../outside.txt'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
$unsafe=& $checker -PackageRoot $copy
Assert-TPAT (-not(Get-TPATCheck $unsafe 'PackageIntegrity').Passed-and$unsafe.Status-ceq'BLOCKED') 'Traversal must be refused before outside-file inspection.'
[IO.File]::WriteAllBytes($manifestPath,$manifestBytes)

if($tpToolIsWindows){
    # Introduce a block on a private fixture copy. The checker must retain it.
    $blockedDll=Join-Path $copy 'Application/TaskPilot/Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll'
    Set-Content -LiteralPath $blockedDll -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -ErrorAction Stop
    $blocked=& $checker -PackageRoot $copy -FirstUse
    Assert-TPAT ((Get-TPATCheck $blocked 'PackageIntegrity').Passed) 'ADS must not be confused with the payload byte hash.'
    Assert-TPAT (-not(Get-TPATCheck $blocked 'DownloadOrigin').Passed-and$blocked.Status-ceq'BLOCKED') 'Internet-origin DLL must block the candidate.'
    Assert-TPAT (((Get-Content -LiteralPath $blockedDll -Stream Zone.Identifier -Raw)-match'ZoneId=3')) 'The checker must not remove origin metadata.'
}else{$skips.Add('Windows ADS/signature checks require Windows; no native branch was claimed on Linux.')}

$logs=Join-Path $fixture 'SyntheticLogs'
$logOutput=Join-Path $fixture 'CollectorResults'
$null=[IO.Directory]::CreateDirectory($logs);$null=[IO.Directory]::CreateDirectory($logOutput)
$app=Join-Path $kit 'Application/TaskPilot'
Write-TPBuildNewText (Join-Path $logs 'actions.log') 'UAT synthetic action'
Write-TPBuildNewText (Join-Path $logs 'errors.log') 'UAT synthetic error'
Write-TPBuildNewText (Join-Path $logs 'MigrationInspection_0123456789abcdef0123456789abcdef.json') '{}'
Write-TPBuildNewText (Join-Path $logs 'TaskList.csv') 'Synthetic excluded CSV'
Write-TPBuildNewText (Join-Path $logs 'TaskPilot.db') 'Synthetic excluded DB'
Write-TPBuildNewText (Join-Path $logs 'Nested/errors.log') 'Synthetic excluded nested log'
$beforeLogs=Get-TPATSnapshot $logs
$collected=& $collector -ApplicationDirectory $app -OutputRoot $logOutput -LogDirectory $logs -CaseId 'CI-TOOLS' -Reproduction 'Isolated synthetic logs; application was not launched.'
$copied=@(Get-TPBuildFiles (Join-Path $collected.Directory 'Logs'))
Assert-TPAT ($copied.Count-eq3) 'Only the three allowlisted top-level logs must be copied.'
Assert-TPAT (-not[IO.File]::Exists((Join-Path $collected.Directory 'Logs/TaskList.csv'))-and-not[IO.File]::Exists((Join-Path $collected.Directory 'Logs/TaskPilot.db'))-and-not[IO.Directory]::Exists((Join-Path $collected.Directory 'Logs/Nested'))) 'DB/CSV/nested data must not enter diagnostics.'
Assert-TPAT ((Get-TPATSnapshot $logs)-ceq$beforeLogs) 'Log collection must preserve source bytes.'
$again=& $collector -ApplicationDirectory $app -OutputRoot $logOutput -LogDirectory $logs
Assert-TPAT ($again.Directory-cne$collected.Directory) 'Repeated collection must create a new report, never overwrite.'
$rejected=$false
try{& $collector -ApplicationDirectory $app -OutputRoot $app -LogDirectory $logs|Out-Null}catch{$rejected=$true}
Assert-TPAT $rejected 'Diagnostic output inside the application must be refused.'
[IO.File]::WriteAllBytes((Join-Path $logs 'errors.log'),(New-Object byte[] 2097152))
$large=& $collector -ApplicationDirectory $app -OutputRoot $logOutput -LogDirectory $logs -MaximumLogFileMiB 1
$collection=Get-Content -LiteralPath (Join-Path $large.Directory 'Collection.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-TPAT (@($collection.Logs|Where-Object {$_.Name-ceq'errors.log'-and$_.Status-ceq'SkippedFileSizeLimit'}).Count-eq1) 'Oversized logs must be explicitly skipped.'
$link=Join-Path $logs 'MigrationResult_0123456789abcdef0123456789abcdef.json'
$linked=$false
try{$null=New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $logs 'actions.log') -ErrorAction Stop;$linked=$true}catch{$skips.Add('Symlink creation was unavailable; link rejection case not executed.')}
if($linked){
    $linkedResult=& $collector -ApplicationDirectory $app -OutputRoot $logOutput -LogDirectory $logs
    $collection=Get-Content -LiteralPath (Join-Path $linkedResult.Directory 'Collection.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-TPAT (@($collection.Logs|Where-Object {$_.Name-ceq[IO.Path]::GetFileName($link)-and$_.Status-ceq'ReadOrCopyFailed'}).Count-eq1) 'A log symlink must be refused without following it.'
    Assert-TPAT ([IO.File]::ReadAllText((Join-Path $logs 'actions.log'))-ceq'UAT synthetic action') 'Link inspection must preserve the target.'
}
$missing=& $collector -ApplicationDirectory $app -OutputRoot $logOutput -LogDirectory (Join-Path $fixture 'AbsentLogs')
Assert-TPAT ($missing.Warnings-ge1-and$missing.LogsSelected-eq0) 'Missing logs must be recorded, never inferred as success.'
if($tpToolIsWindows){
    $candidateFiles=@(Get-Content -LiteralPath (Join-Path $collected.Directory 'CandidateFiles.json') -Raw -Encoding UTF8|ConvertFrom-Json)
    foreach($relative in @('TaskPilot.exe','Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Modules/ImportExcel/EPPlus.dll')){
        $entry=@($candidateFiles|Where-Object {$_.Path-ceq$relative})
        Assert-TPAT ($entry.Count-eq1-and$entry[0].State-ceq'Present'-and$entry[0].SignatureStatus-ne'Unavailable'-and$entry[0].ZoneState-notin@('ReadFailed','Unavailable')) ('Windows metadata must be readable for '+$relative)
    }
}
Assert-TPAT ((Get-TPATSnapshot $kit)-ceq$original) 'Acceptance tools must not change any supplied application, guide or evidence bytes.'
foreach($skip in $skips){Write-Host ('SKIP: '+$skip)}
[pscustomobject]@{Passed=$true;Checks=$script:TPATChecks;SkippedDetails=$skips.ToArray();TestRoot=$fixture;ClientAcceptanceVerified=$false;ApplicationLaunched=$false;OriginalPackageModified=$false}
