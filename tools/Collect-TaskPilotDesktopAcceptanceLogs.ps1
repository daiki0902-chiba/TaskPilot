#requires -Version 5.1
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
# No folder picker, normal-log fallback, transcripts, directory inventory,
# screenshot capture, automatic upload, or user-supplied output path.
$lease=$null
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
    if($result.Status-cne'READY_FOR_DESKTOP_ACCEPTANCE'){throw 'TP-ACCEPTANCE-PREFLIGHT'}
    # A client qualification runner and reviewed diagnostic reopen protocol are
    # prerequisites. Do not inspect any existing user directory in their absence.
    throw 'TP-ACCEPTANCE-DIAGNOSTIC-REOPEN-NOT-IMPLEMENTED'
}catch{
    [pscustomobject][ordered]@{FormatVersion=1;Status='BLOCKED';Code='TP-ACCEPTANCE-DIAGNOSTIC-NOT-READY';RawLogsIncluded=$false;UserDataIncluded=$false;ProfileAccessed=$false;Uploaded=$false}
}finally{if($null-ne$lease){$lease.Dispose()}}
