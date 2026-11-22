#requires -Version 5.1
# Loaded before any TaskPilot user-state path is assigned. Test selection is
# immutable for this process and never comes from settings or an environment var.
function Test-TPRuntimeTestMode {
    $value=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    return $null-ne$value -and $null-ne$value.Value -and [bool]$value.Value.IsTestMode
}
function Get-TPRuntimeContext {
    $value=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$value -or $null-eq$value.Value){throw 'TaskPilot runtime has not been initialized.'}
    return $value.Value
}
function Get-TPRuntimeSandbox {
    $context=Get-TPRuntimeContext
    if(-not$context.IsTestMode -or $null-eq$context.Sandbox){throw 'This operation requires independent test mode.'}
    return $context.Sandbox
}
function Assert-TPRuntimePath([string]$Path) {
    if(Test-TPRuntimeTestMode){return (Get-TPRuntimeSandbox).AssertPath($Path)}
    return $Path
}
function Initialize-TPRuntime {
    [CmdletBinding()]
    param([switch]$TestMode,[string]$TestEnvironmentId,[string[]]$Arguments)
    $existing=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-ne$existing -and $null-ne$existing.Value){throw 'TaskPilot runtime mode is immutable and has already been selected.'}
    if($PSBoundParameters.ContainsKey('Arguments')){
        if($PSBoundParameters.ContainsKey('TestMode')-or$PSBoundParameters.ContainsKey('TestEnvironmentId')){throw 'Choose named runtime arguments or an argument array, not both.'}
        $seenMode=$false;$seenId=$false
        for($index=0;$index-lt$Arguments.Count;$index++){
            $argument=$Arguments[$index]
            if($argument-ceq'-TestMode'){
                if($seenMode){throw 'TestMode was specified more than once.'}
                $seenMode=$true;$TestMode=[System.Management.Automation.SwitchParameter]::new($true)
            }elseif($argument-ceq'-TestEnvironmentId'){
                if($seenId-or$index+1-ge$Arguments.Count){throw 'TestEnvironmentId must have exactly one value.'}
                $seenId=$true;$index++;$TestEnvironmentId=$Arguments[$index]
            }else{throw ('Unknown TaskPilot runtime argument: '+$argument)}
        }
    }
    if(-not$TestMode -and -not[string]::IsNullOrEmpty($TestEnvironmentId)){throw 'TestEnvironmentId requires TestMode. No normal data was opened.'}
    if($TestMode -and $TestEnvironmentId-cnotmatch'^[a-f0-9]{32}$'){throw 'TestEnvironmentId must be exactly 32 lowercase hexadecimal characters. No normal data was opened.'}
    # Release gate, deliberately before even resolving the real profile.
    # Native synthetic tests I25/I28 demonstrated in-place reparse changes
    # despite sharing leases. Only developer fixtures may exercise this draft
    # boundary until every pathname consumer has a proven safe replacement.
    if($TestMode){throw 'TP-ISOLATION-BLOCKED: 独立テストモードは安全性試験 I25/I28 の不合格により利用を停止しています。保存領域の取得・通常データの参照・テスト領域の作成は行っていません。'}
    $profile=[Environment]::GetFolderPath('LocalApplicationData')
    if([string]::IsNullOrWhiteSpace($profile)){throw 'The Windows LocalApplicationData folder is unavailable.'}
    $sandbox=$null
    if($TestMode){
        if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or-not[Environment]::Is64BitProcess-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1){throw 'Independent test mode requires native x64 Windows PowerShell Desktop 5.1.'}
        $assemblyPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'TaskPilot.TestSandbox.dll'))
        if(-not[IO.File]::Exists($assemblyPath)){throw 'The bundled test-mode runtime DLL is missing. No normal data was opened.'}
        # The DLL is produced by the build; no startup Add-Type/CodeDom compilation.
        # File-integrity/origin checks are also performed by the acceptance checker.
        $assemblyHash=(Get-FileHash -LiteralPath $assemblyPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $assembly=[Reflection.Assembly]::LoadFrom($assemblyPath)
        if(-not[IO.Path]::GetFullPath($assembly.Location).Equals($assemblyPath,[StringComparison]::OrdinalIgnoreCase)-or(Get-FileHash -LiteralPath $assemblyPath -Algorithm SHA256 -ErrorAction Stop).Hash-cne$assemblyHash){throw 'The runtime DLL was reused from a different package or changed during loading. Start a fresh process; no normal data was opened.'}
        $sandboxType=$assembly.GetType('TaskPilot.Runtime.Sandbox',$true)
        try{$sandbox=$sandboxType.GetMethod('Create').Invoke($null,@($profile,$TestEnvironmentId))}
        catch{throw $_.Exception.GetBaseException()}
        $context=[pscustomobject][ordered]@{
            IsTestMode=$true;TestMode=$true;EnvironmentId=$TestEnvironmentId;ProfileRoot=$profile
            Root=$sandbox.Root;DataDir=$sandbox.Data;ExportDir=$sandbox.Export;BackupDir=$sandbox.Backup
            LogDir=$sandbox.Logs;TempDir=$sandbox.Temp;InputDir=$sandbox.Input;LockPath=$sandbox.LockPath;Sandbox=$sandbox
        }
        # Process-only caches are selected before provider/Codec/ImportExcel loads.
        # No machine/user environment or policy is changed, and no existing TEMP is removed.
        $env:TEMP=$sandbox.Temp
        $env:TMP=$sandbox.Temp
        $env:SQLITE_TMPDIR=$sandbox.Temp
        $env:PSModuleAnalysisCachePath=Join-Path $sandbox.Temp 'PowerShellModuleAnalysisCache'
        $script:TPRuntimeSandbox=$sandbox
        $codecPath=Join-Path $PSScriptRoot '../Codec/TaskPilotMigrationCodec.dll'
        if(-not[IO.File]::Exists($codecPath)){$sandbox.Dispose();throw 'The precompiled codec DLL is missing. No normal data was opened.'}
        try{$codecAssembly=[Reflection.Assembly]::LoadFrom($codecPath);$null=$codecAssembly.GetType('TaskPilot.Migration.Codec',$true)}catch{$sandbox.Dispose();throw}
    }else{
        $root=Join-Path $profile 'TaskPilot4'
        $context=[pscustomobject][ordered]@{
            IsTestMode=$false;TestMode=$false;EnvironmentId=$null;ProfileRoot=$profile
            Root=$root;DataDir=(Join-Path $root 'Data');ExportDir=(Join-Path $root 'Export');BackupDir=(Join-Path $root 'Backup')
            LogDir=(Join-Path $profile 'TaskPilot4Logs');TempDir=$null;InputDir=$null;LockPath=(Join-Path $profile 'TaskPilot4.storage.lock');Sandbox=$null
        }
        $script:TPRuntimeSandbox=$null
    }
    $script:TPRuntimeContext=$context
    return $context
}
function Close-TPRuntime {
    $value=Get-Variable -Name TPRuntimeSandbox -Scope Script -ErrorAction SilentlyContinue
    if($null-ne$value-and$null-ne$value.Value){$value.Value.Dispose()}
    # Keep the selected context in place: no later initialization or mode switch.
}
