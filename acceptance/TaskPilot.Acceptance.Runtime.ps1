#requires -Version 5.1
# Dedicated desktop acceptance runtime. This is never loaded by TaskPilot.exe.
function Initialize-TPDesktopAcceptanceRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $selected=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-ne$selected-and$null-ne$selected.Value){throw 'TP-ACCEPTANCE-MODE-IMMUTABLE'}
    $launcher='TaskPilot.Acceptance.Launcher' -as [type]
    if($null-eq$launcher-or-not$launcher.GetProperty('IsDedicatedLauncher').GetValue($null,$null)){
        throw 'TP-ACCEPTANCE-DEDICATED-LAUNCHER-REQUIRED'
    }
    # Authority verification must precede even KnownFolder resolution. The
    # authority holds checked package files against replacement until disposal.
    $authority=$null;$sandbox=$null
    try{
        $authority=Open-TPAcceptanceAuthorization -PackageRoot $InstallRoot
        $preflight=& (Join-Path $InstallRoot 'tools/Test-TaskPilotDesktopAcceptance.ps1') -PackageRoot $InstallRoot
        if($null-eq$preflight-or$preflight.Status-cne'READY_FOR_DESKTOP_ACCEPTANCE'-or
           $preflight.CanLaunch-isnot[bool]-or-not$preflight.CanLaunch){
            throw 'TP-ACCEPTANCE-PREFLIGHT-BLOCKED'
        }
        # The current preflight deliberately has no READY path. These operations
        # remain unreachable until a separately reviewed native client qualifier
        # exists; no boolean, environment switch, or command argument opens them.
        if($authority.Purpose-cne'DesktopAcceptanceSyntheticOnly'-or
           $authority.Version-cne'0.4.0.2'-or
           $authority.EnvironmentId-cnotmatch'^[a-f0-9]{32}$'){
            throw 'TP-ACCEPTANCE-AUTHORIZATION-INVALID'
        }
        $profile=[Environment]::GetFolderPath('LocalApplicationData')
        if([string]::IsNullOrWhiteSpace($profile)){throw 'TP-ACCEPTANCE-KNOWN-FOLDER-UNAVAILABLE'}
        $guardPath=$authority.PackageLease.FullPath('Runtime/TaskPilot.TestSandbox.dll')
        $null=$authority.PackageLease.AssertPinned('Runtime/TaskPilot.TestSandbox.dll')
        $assembly=[Reflection.Assembly]::LoadFrom($guardPath)
        if(-not[string]::Equals($assembly.Location,$guardPath,[StringComparison]::OrdinalIgnoreCase)){
            throw 'TP-ACCEPTANCE-RUNTIME-ASSEMBLY-MISMATCH'
        }
        $sandboxType=$assembly.GetType('TaskPilot.Runtime.Sandbox',$true)
        try{$sandbox=$sandboxType.GetMethod('CreateAcceptance').Invoke($null,@($profile,$authority.EnvironmentId))}
        catch{throw 'TP-ACCEPTANCE-SYNTHETIC-BOUNDARY-FAILED'}
        $env:TEMP=$sandbox.Temp;$env:TMP=$sandbox.Temp;$env:SQLITE_TMPDIR=$sandbox.Temp
        $env:PSModuleAnalysisCachePath='NUL'
        $codecPath=$authority.PackageLease.FullPath('Codec/TaskPilotMigrationCodec.dll')
        $null=$authority.PackageLease.AssertPinned('Codec/TaskPilotMigrationCodec.dll')
        $codec=[Reflection.Assembly]::LoadFrom($codecPath)
        if(-not[string]::Equals($codec.Location,$codecPath,[StringComparison]::OrdinalIgnoreCase)){
            throw 'TP-ACCEPTANCE-CODEC-ASSEMBLY-MISMATCH'
        }
        $null=$codec.GetType('TaskPilot.Migration.Codec',$true)
        $context=[pscustomobject][ordered]@{
            IsTestMode=$true;TestMode=$true;IsAcceptance=$true;EnvironmentId=$authority.EnvironmentId
            ProfileRoot=$profile;Root=$sandbox.Root;DataDir=$sandbox.Data;ExportDir=$sandbox.Export
            BackupDir=$sandbox.Backup;LogDir=$sandbox.Logs;TempDir=$sandbox.Temp;InputDir=$sandbox.Input
            LockPath=$sandbox.LockPath;Sandbox=$sandbox;Authorization=$authority
        }
        $script:TPRuntimeSandbox=$sandbox
        $script:TPRuntimeContext=$context
        return $context
    }catch{
        if($null-ne$sandbox){$sandbox.Dispose()}
        if($null-ne$authority){$authority.Dispose()}
        throw
    }
}
function Close-TPDesktopAcceptanceRuntime {
    $selected=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$selected-or$null-eq$selected.Value){return}
    $context=$selected.Value
    if(-not$context.IsAcceptance){throw 'TP-ACCEPTANCE-CONTEXT-MISMATCH'}
    try{if($null-ne$context.Sandbox){$context.Sandbox.Dispose()}}
    finally{if($null-ne$context.Authorization){$context.Authorization.Dispose()}}
    # Keep the selected context immutable; no fallback or normal-mode restart.
}
