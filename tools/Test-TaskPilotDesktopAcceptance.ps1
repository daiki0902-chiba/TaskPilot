#requires -Version 5.1
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# Acceptance-only preflight. The dedicated native launcher supplies its own
# pinned installation directory; this script never chooses a data directory.
# A successful package check does not authorize a GUI run by itself. Until a
# reviewed client-native qualification runner is delivered, this checker has
# deliberately NO READY path and does not even resolve the actual user profile.
$checks=New-Object 'Collections.Generic.List[object]'
$authority=$null
$hostVerified=$false
$frameworkVerified=$false
function Add-TPDesktopPreflightCheck([string]$Name,[bool]$Passed,[string]$Code){
    $checks.Add([pscustomobject][ordered]@{Name=$Name;Passed=$Passed;Code=$Code})
}
function Get-TPDesktopPreflightDenial($Record){
    # Exception messages can contain paths, certificate subjects or other input.
    # Export only the known authorization codes, never arbitrary exception text.
    foreach($code in @('TP-ACCEPTANCE-PUBLISHER-NOT-CONFIGURED','TP-ACCEPTANCE-LAUNCHER-REQUIRED')){
        if([string]$Record.Exception.Message-like('*'+$code+'*')){return $code}
    }
    return 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
}
try{
    $securityPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'acceptance/TaskPilot.Acceptance.Security.ps1'
    if(-not[IO.File]::Exists($securityPath)){throw 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    . $securityPath
    # Open verifies the native launcher attestation, fixed package root, signer,
    # purpose, lifetime, full payload and download-origin policy before returning.
    # No environment, configuration or argument can select another data root.
    $authority=Open-TPAcceptanceAuthorization -PackageRoot $PackageRoot
    if($null-eq$authority-or$authority.Status-cne'AUTHORIZED_FOR_DESKTOP_ACCEPTANCE'){
        throw 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
    }
    Add-TPDesktopPreflightCheck 'AcceptanceAuthorization' $true 'TP-ACCEPTANCE-AUTHORITY-VERIFIED'

    $nativeHost=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT-and
        [Environment]::Is64BitProcess-and$PSVersionTable.PSVersion.Major-eq5-and
        $PSVersionTable.PSVersion.Minor-eq1-and$PSVersionTable.PSEdition-ceq'Desktop'
    if($nativeHost){
        try{
            # Select only machine OS fields. Do not collect usernames, domain,
            # computer names, serial numbers, registration or installed software.
            $os=Get-CimInstance -ClassName Win32_OperatingSystem -Property ProductType,Version,BuildNumber,Caption -ErrorAction Stop
            $hostVerified=[int]$os.ProductType-eq1-and[string]$os.Version-like'10.0.*'-and
                [string]$os.BuildNumber-match'^[0-9]+$'-and[long]$os.BuildNumber-ge10240-and
                [string]$os.Caption-match'Windows (10|11)(\s|$)'
        }catch{$hostVerified=$false}
    }
    Add-TPDesktopPreflightCheck 'Windows10Or11Desktop51x64' $hostVerified $(if($hostVerified){'TP-ACCEPTANCE-CLIENT-HOST-VERIFIED'}else{'TP-ACCEPTANCE-CLIENT-HOST-REQUIRED'})
    if($hostVerified){
        try{
            $release=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
            $frameworkVerified=[long]$release.Release-ge528040
        }catch{$frameworkVerified=$false}
        Add-TPDesktopPreflightCheck 'DotNetFramework48' $frameworkVerified $(if($frameworkVerified){'TP-ACCEPTANCE-FRAMEWORK-VERIFIED'}else{'TP-ACCEPTANCE-FRAMEWORK-REQUIRED'})
    }
    if($hostVerified-and$frameworkVerified){
        # Windows Server CI is not proof that the safety boundary, SQLite
        # snapshot backend and restart checks pass on this Windows 10/11 client.
        # The reviewed client-native runner is not present in this revision.
        # Do not create a marker, weaken a check, or accept a caller Boolean.
        Add-TPDesktopPreflightCheck 'ClientNativeQualification' $false 'TP-ACCEPTANCE-CLIENT-QUALIFICATION-REQUIRED'
    }
}catch{
    Add-TPDesktopPreflightCheck 'AcceptanceAuthorization' $false (Get-TPDesktopPreflightDenial $_)
}finally{
    if($null-ne$authority){
        try{$null=$authority.Dispose()}catch{
            Add-TPDesktopPreflightCheck 'AuthorizationLeaseClosed' $false 'TP-ACCEPTANCE-AUTHORITY-CLOSE-FAILED'
        }
    }
}
return [pscustomobject][ordered]@{
    FormatVersion=1
    Purpose='DesktopAcceptanceSyntheticOnly'
    Version='0.4.0.2'
    Status='BLOCKED'
    CanLaunch=$false
    Checks=$checks.ToArray()
    WindowsClientHostVerified=$hostVerified
    DotNetFramework48Verified=$frameworkVerified
    ClientNativeQualificationVerified=$false
    ProfileAccessed=$false
    SyntheticAreaPrepared=$false
    ApplicationLaunched=$false
    GeneralReleaseAuthorized=$false
    IndependentModeReleaseAuthorized=$false
}
