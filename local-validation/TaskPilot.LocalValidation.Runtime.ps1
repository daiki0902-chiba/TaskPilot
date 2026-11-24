#requires -Version 5.1
# Local-only runtime. General and formal acceptance initializers never call it.
function Assert-TPLocalValidationHost {
    [CmdletBinding()]
    param()
    $nativeHost='TaskPilot.LocalValidation.Host'-as[type]
    if($null-eq$nativeHost){throw 'TP-LOCAL-DEDICATED-HOST-REQUIRED'}
    foreach($propertyName in @('IsLocalValidationHost','HasProtectedParent','PackageRoot')){
        if($null-eq$nativeHost.GetProperty($propertyName)){throw 'TP-LOCAL-DEDICATED-HOST-REQUIRED'}
    }
    if(-not$nativeHost::IsLocalValidationHost-or-not$nativeHost::HasProtectedParent-or
       $null-eq$nativeHost.GetMethod('OpenCurrentSession')){throw 'TP-LOCAL-PROTECTED-PARENT-REQUIRED'}
    return $nativeHost
}
function Initialize-TPLocalValidationRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $selected=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-ne$selected-and$null-ne$selected.Value){throw 'TP-LOCAL-MODE-IMMUTABLE'}
    $nativeHost=Assert-TPLocalValidationHost
    if(-not[string]::Equals($InstallRoot,$nativeHost::PackageRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'TP-LOCAL-PACKAGE-ROOT'}
    $session=$null;$sandbox=$null
    try{
        # The native host authenticates the scope-bound receipt and live parent;
        # a caller-supplied approval object or environment switch is not accepted.
        $session=$nativeHost::OpenCurrentSession()
        if($null-eq$session-or$session.Purpose-cne'LocalDeveloperValidationSyntheticOnly'-or
           $session.Version-cne'0.4.0.2'-or$session.EnvironmentId-cnotmatch'^[a-f0-9]{32}$'){
            throw 'TP-LOCAL-SESSION-INVALID'
        }
        $preflight=& (Join-Path $InstallRoot 'tools/Test-TaskPilotLocalValidation.ps1') -PackageRoot $InstallRoot
        if($null-eq$preflight-or$preflight.Status-cne'READY_FOR_LOCAL_VALIDATION'-or
           $preflight.CanLaunch-isnot[bool]-or-not$preflight.CanLaunch){throw 'TP-LOCAL-PREFLIGHT-BLOCKED'}
        # Kept unreachable while native host, clean-environment admission, or
        # unchanged-policy compatibility is incomplete. No normal-path fallback.
        $profileRoot=[Environment]::GetFolderPath('LocalApplicationData')
        if([string]::IsNullOrWhiteSpace($profileRoot)){throw 'TP-LOCAL-KNOWN-FOLDER-UNAVAILABLE'}
        $null=$session.PackageLease.AssertPinned('Runtime/TaskPilot.TestSandbox.dll')
        $guardPath=$session.PackageLease.FullPath('Runtime/TaskPilot.TestSandbox.dll')
        $guard=[Reflection.Assembly]::LoadFrom($guardPath)
        if(-not[string]::Equals($guard.Location,$guardPath,[StringComparison]::OrdinalIgnoreCase)){throw 'TP-LOCAL-RUNTIME-ASSEMBLY'}
        $sandboxType=$guard.GetType('TaskPilot.Runtime.Sandbox',$true)
        try{$sandbox=$sandboxType::CreateLocalValidation($profileRoot,[string]$session.EnvironmentId)}
        catch{throw 'TP-LOCAL-SYNTHETIC-BOUNDARY'}
        if(-not$sandbox.IsLocalValidation){throw 'TP-LOCAL-SYNTHETIC-PURPOSE'}
        $env:TEMP=$sandbox.Temp;$env:TMP=$sandbox.Temp;$env:SQLITE_TMPDIR=$sandbox.Temp
        $env:PSModuleAnalysisCachePath='NUL'
        $null=$session.PackageLease.AssertPinned('Codec/TaskPilotMigrationCodec.dll')
        $codecPath=$session.PackageLease.FullPath('Codec/TaskPilotMigrationCodec.dll')
        $codec=[Reflection.Assembly]::LoadFrom($codecPath)
        if(-not[string]::Equals($codec.Location,$codecPath,[StringComparison]::OrdinalIgnoreCase)){throw 'TP-LOCAL-CODEC-ASSEMBLY'}
        $null=$codec.GetType('TaskPilot.Migration.Codec',$true)
        $context=[pscustomobject][ordered]@{
            IsTestMode=$true;TestMode=$true;IsLocalValidation=$true;IsAcceptance=$false
            EnvironmentId=$session.EnvironmentId;ProfileRoot=$profileRoot
            Root=$sandbox.Root;DataDir=$sandbox.Data;ExportDir=$sandbox.Export;BackupDir=$sandbox.Backup
            LogDir=$sandbox.Logs;TempDir=$sandbox.Temp;InputDir=$sandbox.Input;LockPath=$sandbox.LockPath
            Sandbox=$sandbox;LocalSession=$session
        }
        $script:TPRuntimeSandbox=$sandbox;$script:TPRuntimeContext=$context
        return $context
    }catch{
        if($null-ne$sandbox){$sandbox.Dispose()}
        if($null-ne$session){$session.Dispose()}
        throw 'TP-LOCAL-INITIALIZATION-BLOCKED'
    }
}
function Close-TPLocalValidationRuntime {
    $selected=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$selected-or$null-eq$selected.Value){return}
    $context=$selected.Value
    if(-not$context.IsLocalValidation-or$context.IsAcceptance){throw 'TP-LOCAL-CONTEXT-MISMATCH'}
    try{if($null-ne$context.Sandbox){$context.Sandbox.Dispose()}}
    finally{if($null-ne$context.LocalSession){$context.LocalSession.Dispose()}}
    # Preserve the selected context; switching to the normal app is forbidden.
}
