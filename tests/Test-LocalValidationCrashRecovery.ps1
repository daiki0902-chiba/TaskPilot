#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeAssembly,[Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Native Windows PowerShell Desktop 5.1 x64 is required. No native crash-recovery result was produced.'}
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer results directory is required.'}
$fixture=Join-Path $output ('LocalValidationCrash_'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $fixture 'SyntheticLocalAppData';$null=[IO.Directory]::CreateDirectory($profile)
$runtimePath=Get-TPBuildFullPath $RuntimeAssembly;Assert-TPBuildNoLinks $runtimePath
$runtimeSha=Get-TPBuildSha $runtimePath;$loaded=[Reflection.Assembly]::LoadFrom($runtimePath)
if(-not[string]::Equals($loaded.Location,$runtimePath,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $loaded.Location)-cne$runtimeSha){throw 'The exact local-validation package runtime is required.'}
$storagePath=Join-Path $repo 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
$cases=New-Object 'Collections.Generic.List[object]';$checks=0;$terminations=0
$activeChild=$null;$activeBroker=$null;$activeStore=$null;$activeModule=$null
function Assert-LocalCrash([bool]$Condition,[string]$Code){$script:checks++;if(-not$Condition){throw $Code}}
function Hash-LocalCrashBytes([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Case-LocalCrash([string]$CaseId,[string]$Name,[scriptblock]$Operation){
    try{&$Operation;$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Name;Passed=$true;Code=('TP-LOCAL-CRASH-'+$CaseId+'-PASSED')});Write-Host ('PASS: '+$CaseId+' '+$Name)}
    catch{$failureCode=if($_.Exception.GetBaseException().Message-cmatch'^TP-LOCAL-CRASH-[A-Z0-9-]+$'){$_.Exception.GetBaseException().Message}else{'TP-LOCAL-CRASH-NATIVE-OPERATION-FAILED'};$cases.Add([pscustomobject]@{Id=$CaseId;Name=$Name;Passed=$false;Code=$failureCode;ExceptionType=$_.Exception.GetType().FullName});Write-Host ('FAIL: '+$CaseId+' '+$failureCode+' : '+$_.Exception.GetType().FullName)}
    finally{Close-LocalCrashResources}
}
function Snapshot-LocalCrash([string]$SnapshotRoot){
    $rows=New-Object 'Collections.Generic.List[string]';$rows.Add('DIRECTORY . ACL '+[string](Get-Acl -LiteralPath $SnapshotRoot).Sddl)
    foreach($entry in @(Get-ChildItem -LiteralPath $SnapshotRoot -Recurse -Force|Sort-Object FullName)){
        if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'TP-LOCAL-CRASH-NORMAL-FIXTURE-LINK'}
        $relative=$entry.FullName.Substring($SnapshotRoot.Length+1).Replace('\','/');$acl=[string](Get-Acl -LiteralPath $entry.FullName).Sddl
        if($entry.PSIsContainer){$rows.Add('DIRECTORY '+$relative+' ACL '+$acl)}else{$rows.Add('FILE '+$relative+' '+$entry.Length+' '+(Get-TPBuildSha $entry.FullName)+' ACL '+$acl)}
    }
    return [string]::Join("`n",$rows.ToArray())
}
function Close-LocalCrashResources {
    if($null-ne$script:activeChild){try{if(-not$script:activeChild.HasExited){$script:activeChild.Kill();$null=$script:activeChild.WaitForExit(10000)}}finally{$script:activeChild.Dispose();$script:activeChild=$null}}
    try{if($null-ne$script:activeStore-and-not$script:activeStore.Closed){Close-TaskPilotStore $script:activeStore}}finally{
        $script:activeStore=$null
        try{if($null-ne$script:activeModule){Remove-Module $script:activeModule -Force -ErrorAction SilentlyContinue;$script:activeModule=$null}}finally{
            if($null-ne$script:activeBroker){$script:activeBroker.Dispose();$script:activeBroker=$null}
        }
    }
}
function Open-LocalCrashContext([string]$EnvironmentId,[string]$DatabasePath,[switch]$ReadOnly){
    Close-LocalCrashResources
    $script:activeBroker=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$EnvironmentId)
    $script:activeModule=Import-Module $storagePath -Force -PassThru
    $null=& $script:activeModule {param($broker)Set-TaskPilotTestSandbox $broker} $script:activeBroker
    if($DatabasePath){$script:activeStore=Open-TaskPilotStore -DatabasePath $DatabasePath -ReadOnly:$ReadOnly}
}
function New-LocalCrashSeed {
    $environmentId=[guid]::NewGuid().ToString('N')
    Open-LocalCrashContext $environmentId ''
    $databasePath=Join-Path $script:activeBroker.Data 'synthetic-crash.db';$null=New-TaskPilotDatabase -DatabasePath $databasePath
    $script:activeStore=Open-TaskPilotStore -DatabasePath $databasePath
    $task=Add-TaskPilotTask -Store $script:activeStore -Title 'SYNTHETIC BASE' -RegisteredOn '2026-11-23' -EstimatedHours ([decimal]'1.01')
    $data=[pscustomobject]@{EnvironmentId=$environmentId;DatabasePath=$databasePath;TaskId=[long]$task.task_id;Version=[long]$task.row_version;DatabaseSha256=(Hash-LocalCrashBytes ($script:activeBroker.ReadAllBytes($databasePath)));ReadyPath=(Join-Path $script:activeBroker.Temp 'child-ready.txt')}
    Close-LocalCrashResources
    return $data
}
function Sql-LocalCrash($Store,[string]$Query,[string]$Mode='Rows'){
    return & $script:activeModule {param($s,$q,$m)Invoke-TPSql $s $q -Mode $m} $Store $Query $Mode
}
function Quote-LocalCrashArgument([string]$Argument){
    if($Argument-match'["\x00\r\n]'){throw 'TP-LOCAL-CRASH-ARGUMENT-INVALID'}
    return '"'+$Argument+'"'
}

# This helper is a newly created CI fixture, never shipped in a local package.
# It uses the same native broker/store code as the application and signals only
# after the intended transaction stage. It never asks PowerShell to alter policy.
$childSource=@'
#requires -Version 5.1
[CmdletBinding()]
param([string]$RuntimeAssembly,[string]$StorageModule,[string]$SyntheticProfile,[string]$EnvironmentId,[string]$DatabasePath,[long]$TaskId,[long]$ExpectedVersion,[ValidateSet('BeforeCommit','AfterCommit')][string]$Stage)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$broker=$null;$store=$null;$module=$null
function Wait-LocalCrashParent {
    $waiter=New-Object Threading.ManualResetEvent($false)
    try{$null=$waiter.WaitOne(30000)}finally{$waiter.Dispose()}
    throw 'TP-LOCAL-CRASH-PARENT-TIMEOUT'
}
try{
    $null=[Reflection.Assembly]::LoadFrom($RuntimeAssembly)
    $broker=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($SyntheticProfile,$EnvironmentId)
    $module=Import-Module $StorageModule -Force -PassThru
    $null=&$module {param($scope)Set-TaskPilotTestSandbox $scope} $broker
    $store=Open-TaskPilotStore -DatabasePath $DatabasePath
    $signal=Join-Path $broker.Temp 'child-ready.txt'
    if($Stage-ceq'BeforeCommit'){
        Invoke-TaskPilotTransaction -Store $store -Action {
            param($transactionStore)
            $null=Set-TaskPilotTask -Store $transactionStore -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Title 'SYNTHETIC MUST NOT COMMIT'
            $changed=@(Get-TaskPilotTask -Store $transactionStore -TaskId $TaskId)[0]
            if($changed.title-cne'SYNTHETIC MUST NOT COMMIT'){throw 'TP-LOCAL-CRASH-UPDATE-NOT-REACHED'}
            $broker.WriteNew($signal,[Text.Encoding]::ASCII.GetBytes('TP_LOCAL_CRASH_BEFORE_READY'))
            Wait-LocalCrashParent
        }
    }else{
        $null=Set-TaskPilotTask -Store $store -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Title 'SYNTHETIC COMMITTED'
        $broker.WriteNew($signal,[Text.Encoding]::ASCII.GetBytes('TP_LOCAL_CRASH_AFTER_READY'))
        Wait-LocalCrashParent
    }
    exit 12
}catch{
    # Fixed code only: no ErrorRecord, task contents, filenames or provider text.
    [Console]::Error.WriteLine('TP-LOCAL-CRASH-CHILD-FAILED')
    exit 13
}finally{
    if($null-ne$store-and-not$store.Closed){try{Close-TaskPilotStore $store}catch{}}
    if($null-ne$module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
    if($null-ne$broker){$broker.Dispose()}
}
'@
$childPath=Join-Path $fixture 'Synthetic-Crash-Child.ps1';Write-TPBuildNewText $childPath $childSource
$childHash=Get-TPBuildSha $childPath
function Invoke-LocalCrashTermination($Seed,[string]$Stage){
    if([IO.File]::Exists($Seed.ReadyPath)){throw 'TP-LOCAL-CRASH-SIGNAL-MUST-BE-NEW'}
    $arguments=@('-NoProfile','-NonInteractive','-File',(Quote-LocalCrashArgument $childPath),'-RuntimeAssembly',(Quote-LocalCrashArgument $runtimePath),'-StorageModule',(Quote-LocalCrashArgument $storagePath),'-SyntheticProfile',(Quote-LocalCrashArgument $profile),'-EnvironmentId',(Quote-LocalCrashArgument $Seed.EnvironmentId),'-DatabasePath',(Quote-LocalCrashArgument $Seed.DatabasePath),'-TaskId',[string]$Seed.TaskId,'-ExpectedVersion',[string]$Seed.Version,'-Stage',$Stage)
    $script:activeChild=New-Object Diagnostics.Process
    $script:activeChild.StartInfo.FileName=Join-Path $PSHOME 'powershell.exe'
    $script:activeChild.StartInfo.Arguments=$arguments-join' '
    $script:activeChild.StartInfo.UseShellExecute=$false;$script:activeChild.StartInfo.CreateNoWindow=$true
    $script:activeChild.StartInfo.RedirectStandardOutput=$true;$script:activeChild.StartInfo.RedirectStandardError=$true
    Assert-LocalCrash ($script:activeChild.Start()) 'TP-LOCAL-CRASH-CHILD-NOT-STARTED'
    $clock=[Diagnostics.Stopwatch]::StartNew();$poll=New-Object Threading.ManualResetEvent($false)
    try{
        while(-not[IO.File]::Exists($Seed.ReadyPath)-and-not$script:activeChild.HasExited-and$clock.ElapsedMilliseconds-lt15000){$null=$poll.WaitOne(50)}
    }finally{$poll.Dispose();$clock.Stop()}
    Assert-LocalCrash ([IO.File]::Exists($Seed.ReadyPath)-and-not$script:activeChild.HasExited) 'TP-LOCAL-CRASH-CHILD-STAGE-NOT-REACHED'
    $expected=if($Stage-ceq'BeforeCommit'){'TP_LOCAL_CRASH_BEFORE_READY'}else{'TP_LOCAL_CRASH_AFTER_READY'}
    Assert-LocalCrash ([IO.File]::ReadAllText($Seed.ReadyPath)-ceq$expected) 'TP-LOCAL-CRASH-SIGNAL-INVALID'
    $script:activeChild.Kill()
    Assert-LocalCrash ($script:activeChild.WaitForExit(10000)-and$script:activeChild.ExitCode-ne0) 'TP-LOCAL-CRASH-TERMINATION-NOT-CONFIRMED'
    $script:terminations++
    $script:activeChild.Dispose();$script:activeChild=$null
}

foreach($relative in @('TaskPilot/Data','TaskPilot4/Data','TaskPilot4/Backup','TaskPilot4Logs','TaskPilotTest/previous-synthetic','TaskPilotAcceptance/previous-synthetic')){
    $directory=Join-Path $profile $relative;$null=[IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'synthetic-sentinel.txt'),'SYNTHETIC NORMAL OR HISTORICAL DATA')
}
$normalSnapshots=@{};foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs','TaskPilotTest','TaskPilotAcceptance')){$normalSnapshots[$leaf]=Snapshot-LocalCrash (Join-Path $profile $leaf)}
try{
    Case-LocalCrash 'C01' 'Forced termination before commit preserves the previous durable snapshot' {
        $seed=New-LocalCrashSeed
        Invoke-LocalCrashTermination $seed 'BeforeCommit'
        Assert-LocalCrash ((Get-TPBuildSha $seed.DatabasePath)-ceq$seed.DatabaseSha256) 'TP-LOCAL-CRASH-UNCOMMITTED-IMAGE-CHANGED'
        Open-LocalCrashContext $seed.EnvironmentId $seed.DatabasePath -ReadOnly
        $task=@(Get-TaskPilotTask -Store $script:activeStore -TaskId $seed.TaskId)[0]
        Assert-LocalCrash ($task.title-ceq'SYNTHETIC BASE'-and$task.row_version-eq$seed.Version-and$task.estimated_hours-eq[decimal]'1.01') 'TP-LOCAL-CRASH-UNCOMMITTED-STATE-SURVIVED'
        Assert-LocalCrash ((Sql-LocalCrash $script:activeStore 'PRAGMA integrity_check' -Mode Scalar)-ceq'ok'-and@(Sql-LocalCrash $script:activeStore 'PRAGMA foreign_key_check').Count-eq0) 'TP-LOCAL-CRASH-REOPEN-INTEGRITY'
        Assert-LocalCrash ((Get-TPBuildSha $seed.DatabasePath)-ceq$seed.DatabaseSha256) 'TP-LOCAL-CRASH-REOPEN-CHANGED-IMAGE'
    }
    Case-LocalCrash 'C02' 'Forced termination after durable commit preserves the committed snapshot' {
        $seed=New-LocalCrashSeed
        Invoke-LocalCrashTermination $seed 'AfterCommit'
        $committedHash=Get-TPBuildSha $seed.DatabasePath
        Assert-LocalCrash ($committedHash-cne$seed.DatabaseSha256) 'TP-LOCAL-CRASH-COMMIT-NOT-PUBLISHED'
        Open-LocalCrashContext $seed.EnvironmentId $seed.DatabasePath -ReadOnly
        $task=@(Get-TaskPilotTask -Store $script:activeStore -TaskId $seed.TaskId)[0]
        Assert-LocalCrash ($task.title-ceq'SYNTHETIC COMMITTED'-and$task.row_version-eq$seed.Version+1) 'TP-LOCAL-CRASH-COMMITTED-STATE-LOST'
        Assert-LocalCrash ((Sql-LocalCrash $script:activeStore 'PRAGMA integrity_check' -Mode Scalar)-ceq'ok'-and@(Sql-LocalCrash $script:activeStore 'PRAGMA foreign_key_check').Count-eq0) 'TP-LOCAL-CRASH-COMMITTED-INTEGRITY'
        Assert-LocalCrash ((Get-TPBuildSha $seed.DatabasePath)-ceq$committedHash) 'TP-LOCAL-CRASH-COMMITTED-REOPEN-WROTE'
    }
    Case-LocalCrash 'C03' 'Local backup restores only into a new image and retains purpose and original bytes' {
        $seed=New-LocalCrashSeed
        Open-LocalCrashContext $seed.EnvironmentId $seed.DatabasePath
        $original=Hash-LocalCrashBytes ($script:activeBroker.ReadAllBytes($seed.DatabasePath))
        $backup=Join-Path $script:activeBroker.Backup 'synthetic-crash-backup.db';$restored=Join-Path $script:activeBroker.Data 'synthetic-new-restore.db'
        $saved=New-TaskPilotDatabaseBackup -Store $script:activeStore -DestinationPath $backup
        $restore=Restore-TaskPilotDatabase -BackupPath $backup -DatabasePath $restored
        Assert-LocalCrash ($saved.Verified-and$restore.Verified-and-not$restore.ExistingDatabaseModified) 'TP-LOCAL-CRASH-RESTORE-NOT-VERIFIED'
        Assert-LocalCrash ((Hash-LocalCrashBytes ($script:activeBroker.ReadAllBytes($seed.DatabasePath)))-ceq$original-and(Get-TPBuildSha $backup)-ceq(Get-TPBuildSha $restored)) 'TP-LOCAL-CRASH-RESTORE-BYTES-CHANGED'
        Close-TaskPilotStore $script:activeStore;$script:activeStore=Open-TaskPilotStore -DatabasePath $restored -ReadOnly
        $task=@(Get-TaskPilotTask -Store $script:activeStore -TaskId $seed.TaskId)[0]
        Assert-LocalCrash ($task.title-ceq'SYNTHETIC BASE'-and(Sql-LocalCrash $script:activeStore 'PRAGMA integrity_check' -Mode Scalar)-ceq'ok') 'TP-LOCAL-CRASH-RESTORE-CONTENT-LOST'
        Assert-LocalCrash ((Sql-LocalCrash $script:activeStore 'SELECT description FROM schema_migrations WHERE version=40001' -Mode Scalar)-ceq('TaskPilot local validation environment:'+$seed.EnvironmentId)) 'TP-LOCAL-CRASH-RESTORE-PURPOSE-LOST'
    }
    Case-LocalCrash 'C04' 'A synthetic interrupted broker checkpoint is preserved and blocks automatic recovery' {
        $seed=New-LocalCrashSeed
        Open-LocalCrashContext $seed.EnvironmentId $seed.DatabasePath
        $bytes=$script:activeBroker.ReadAllBytes($seed.DatabasePath)
        $checkpoint=Join-Path $script:activeBroker.Root '.tp-rollback_synthetic-process-interruption.bin';$script:activeBroker.WriteNew($checkpoint,$bytes)
        Close-LocalCrashResources
        foreach($method in @('CreateLocalValidation','OpenExistingLocalValidation')){
            $failure=$null;try{if($method-ceq'CreateLocalValidation'){$unexpected=[TaskPilot.Runtime.Sandbox]::CreateLocalValidation($profile,$seed.EnvironmentId)}else{$unexpected=[TaskPilot.Runtime.Sandbox]::OpenExistingLocalValidation($profile,$seed.EnvironmentId)};$unexpected.Dispose()}catch{$failure=$_}
            Assert-LocalCrash ($null-ne$failure-and$failure.Exception.Message-match'interrupted broker write') 'TP-LOCAL-CRASH-CHECKPOINT-NOT-BLOCKED'
        }
        Assert-LocalCrash ((Get-TPBuildSha $seed.DatabasePath)-ceq$seed.DatabaseSha256-and(Get-TPBuildSha $checkpoint)-ceq$seed.DatabaseSha256) 'TP-LOCAL-CRASH-CHECKPOINT-OR-DB-CHANGED'
    }
}finally{Close-LocalCrashResources}
$normalUnchanged=$true;foreach($leaf in $normalSnapshots.Keys){if((Snapshot-LocalCrash (Join-Path $profile $leaf))-cne$normalSnapshots[$leaf]){$normalUnchanged=$false}}
Assert-LocalCrash ((Get-TPBuildSha $childPath)-ceq$childHash) 'TP-LOCAL-CRASH-HELPER-CHANGED'
$failed=@($cases|Where-Object {-not$_.Passed})
$report=[pscustomobject][ordered]@{
    Stage='Local validation real process termination and recovery';Passed=($failed.Count-eq0-and$cases.Count-eq4-and$normalUnchanged-and$terminations-eq2)
    Cases=$cases.ToArray();FailedCases=$failed.Count;Checks=$checks;RuntimeAssemblySha256=$runtimeSha
    ActualProcessTerminationPerformed=($terminations-eq2);TerminatedProcesses=$terminations
    NormalFixtureUnchanged=$normalUnchanged;PreviousIndependentAndAcceptanceFixturesUnchanged=$normalUnchanged
    ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11Verified=$false
    PowerLossVerified=$false;PartialDiskWriteFailureVerified=$false;SyntheticCheckpointPreservationTested=$true
    PolicyChanged=$false;CertificateStoreChanged=$false;SkippedDetails=@();TestRoot=$fixture
}
Write-TPBuildNewText (Join-Path $output ('LocalValidationCrashRecovery_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 12)
return $report
