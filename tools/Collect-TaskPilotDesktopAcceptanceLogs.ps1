#requires -Version 5.1
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
# No folder picker, normal-log fallback, transcripts, directory inventory,
# screenshot capture, automatic upload, or user-supplied output path.
$lease=$null;$sandbox=$null;$diagnosticLock=$null;$profileAccessed=$false
try{
    $launcher='TaskPilot.Acceptance.Launcher'-as[type]
    if($null-eq$launcher-or-not$launcher::IsDedicatedLauncher){throw 'TP-ACCEPTANCE-LAUNCHER-REQUIRED'}
    if(-not[string]::Equals($PackageRoot,$launcher::PackageRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'TP-ACCEPTANCE-PACKAGE-ROOT'}
    # Native launcher pins and verifies this script and the security script before
    # invoking us. The shared authority checks the entire signed package again.
    . (Join-Path $PackageRoot 'acceptance/TaskPilot.Acceptance.Security.ps1')
    $authority=Open-TPAcceptanceAuthorization -PackageRoot $PackageRoot
    $lease=$authority
    $result=& (Join-Path $PackageRoot 'tools/Test-TaskPilotDesktopAcceptance.ps1') -PackageRoot $PackageRoot
    if($result.Status-cne'READY_FOR_DESKTOP_ACCEPTANCE'-or$result.CanLaunch-isnot[bool]-or-not$result.CanLaunch){throw 'TP-ACCEPTANCE-PREFLIGHT'}
    # No user profile is resolved until authorization and the reviewed readiness
    # gate both pass. Current missing signing/installation conditions still block
    # here; implementing reopening must not silently authorize client execution.
    $lease.PackageLease.AssertPinned('Runtime/TaskPilot.TestSandbox.dll')
    $runtimePath=$lease.PackageLease.FullPath('Runtime/TaskPilot.TestSandbox.dll')
    $runtime=[Reflection.Assembly]::LoadFrom($runtimePath)
    if(-not[string]::Equals($runtime.Location,$runtimePath,[StringComparison]::OrdinalIgnoreCase)){throw 'TP-ACCEPTANCE-DIAGNOSTIC-ASSEMBLY'}
    $lease.PackageLease.AssertPinned('acceptance/TaskPilot.Acceptance.Diagnostics.ps1')
    . ($lease.PackageLease.FullPath('acceptance/TaskPilot.Acceptance.Diagnostics.ps1'))
    $profile=[Environment]::GetFolderPath('LocalApplicationData');$profileAccessed=$true
    if([string]::IsNullOrWhiteSpace($profile)){throw 'TP-ACCEPTANCE-DIAGNOSTIC-PROFILE'}
    $sandboxType=$runtime.GetType('TaskPilot.Runtime.Sandbox',$true)
    # This factory neither creates directories/markers nor repairs old data.
    $sandbox=$sandboxType.GetMethod('OpenExistingAcceptance').Invoke($null,@($profile,[string]$lease.EnvironmentId))
    $diagnosticLock=$sandbox.AcquireExistingAcceptanceDiagnosticLock()
    $summary=Get-TPAcceptanceDiagnosticSummaryFromSandbox -Sandbox $sandbox
    [pscustomobject][ordered]@{FormatVersion=1;Status='COLLECTED';Code='TP-ACCEPTANCE-DIAGNOSTIC-SUMMARY';Purpose=$summary.Purpose;Version=$summary.Version;EventCounts=$summary.EventCounts;RawLogsIncluded=$false;UserDataIncluded=$false;ProfileAccessed=$true;Uploaded=$false}
}catch{
    [pscustomobject][ordered]@{FormatVersion=1;Status='BLOCKED';Code='TP-ACCEPTANCE-DIAGNOSTIC-NOT-READY';RawLogsIncluded=$false;UserDataIncluded=$false;ProfileAccessed=$profileAccessed;Uploaded=$false}
}finally{try{if($null-ne$diagnosticLock){$diagnosticLock.Dispose()}}finally{try{if($null-ne$sandbox){$sandbox.Dispose()}}finally{if($null-ne$lease){$lease.Dispose()}}}}
