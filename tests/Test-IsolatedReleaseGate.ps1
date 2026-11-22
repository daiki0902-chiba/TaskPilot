#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer results directory is required.'}
$fixture=Join-Path $output ('IsolatedReleaseGate_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$package=Join-Path $fixture 'SyntheticPackage'
$results=Join-Path $fixture 'Results'
$null=[IO.Directory]::CreateDirectory($package)
$null=[IO.Directory]::CreateDirectory($results)
$manifest=Join-Path $package 'PACKAGE-MANIFEST.json'
[IO.File]::WriteAllText($manifest,'SYNTHETIC SENTINEL: contents must not be inspected')
$checks=0
function Assert-ReleaseGate([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Expect-ReleaseBlock([scriptblock]$Action){
    $caught=$null;try{$null=&$Action}catch{$caught=$_}
    Assert-ReleaseGate ($null-ne$caught-and$caught.Exception.Message-like'*TP-ISOLATION-BLOCKED*') 'The public entry point must stop at the explicit isolation release gate.'
}
. (Join-Path $repo 'Runtime/TaskPilot.Runtime.ps1')
Expect-ReleaseBlock {Initialize-TPRuntime -TestMode -TestEnvironmentId '1234567890abcdef1234567890abcdef'}
foreach($invalid in @({Initialize-TPRuntime -TestEnvironmentId ''},{Initialize-TPRuntime -Arguments @('-TestEnvironmentId','')})){
    $errorRecord=$null;try{$null=&$invalid}catch{$errorRecord=$_}
    Assert-ReleaseGate ($null-ne$errorRecord-and$errorRecord.Exception.Message-like'*requires TestMode*') 'An empty explicitly supplied ID must not fall back to normal initialization.'
}
$context=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
Assert-ReleaseGate ($null-eq$context-or$null-eq$context.Value) 'Blocked initialization must not select a runtime context or normal fallback.'
# An exclusive sentinel makes accidental manifest content reads observable.
$lease=[IO.File]::Open($manifest,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $check=& (Join-Path $repo 'tools/Test-TaskPilotAcceptancePackage.ps1') -PackageRoot $package -OutputRoot $results -TestMode -TestEnvironmentId '1234567890abcdef1234567890abcdef'
    Assert-ReleaseGate ($check.Status-ceq'BLOCKED'-and-not$check.TestAreaPrepared) 'The checker must never prepare a test area while release is blocked.'
    $denial=@($check.Checks|Where-Object {$_.Name-ceq'TestModeReleaseAuthorization'})
    Assert-ReleaseGate ($denial.Count-eq1-and-not$denial[0].Passed) 'The checker must disclose the release blocker.'
    $integrity=@($check.Checks|Where-Object {$_.Name-ceq'PackageIntegrity'})
    Assert-ReleaseGate ($integrity.Count-eq1-and-not$integrity[0].Passed-and$integrity[0].Detail-like'*TP-ISOLATION-BLOCKED*') 'Package inspection must stop before reading even a locked manifest.'
    Assert-ReleaseGate (@($check.Checks|Where-Object {$_.Name-ceq'FirstUseIsolation'}).Count-eq0) 'A blocked independent request must not inspect normal-profile state.'
    $emptyIdCheck=& (Join-Path $repo 'tools/Test-TaskPilotAcceptancePackage.ps1') -PackageRoot $package -FirstUse -TestEnvironmentId ''
    Assert-ReleaseGate ($emptyIdCheck.Status-ceq'BLOCKED'-and-not$emptyIdCheck.TestAreaPrepared-and@($emptyIdCheck.Checks|Where-Object {$_.Name-ceq'FirstUseIsolation'}).Count-eq0) 'An empty explicitly supplied ID must not enter the normal FirstUse inspection.'
    Assert-ReleaseGate ([IO.File]::Exists($check.ReportPath)) 'The explicit blocked result must remain reviewable.'
    Expect-ReleaseBlock {& (Join-Path $repo 'tools/Collect-TaskPilotAcceptanceLogs.ps1') -ApplicationDirectory $package -OutputRoot $results -TestMode -TestEnvironmentId '1234567890abcdef1234567890abcdef' -CaseId 'RELEASE-GATE'}
}finally{$lease.Dispose()}
Assert-ReleaseGate ([IO.File]::ReadAllText($manifest)-ceq'SYNTHETIC SENTINEL: contents must not be inspected') 'The sentinel changed.'
$report=[pscustomobject]@{Stage='Independent-mode public release gate';Passed=$true;Checks=$checks;ApplicationLaunched=$false;ProductionProfileAccessed=$false;TestAreaPrepared=$false;Windows10And11Verified=$false;TestRoot=$fixture}
Write-TPBuildNewText (Join-Path $output ('IsolatedReleaseGate_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 8)
return $report
