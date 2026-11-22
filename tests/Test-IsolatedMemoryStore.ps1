#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeAssembly,[Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or-not[Environment]::Is64BitProcess){throw 'Native x64 Windows PowerShell Desktop 5.1 is required. No Windows result was produced.'}
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'OutputRoot must be an existing developer report directory.'}
$fixture=Join-Path $output ('IsolatedMemory_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$profile=Join-Path $fixture 'SyntheticLocalAppData';$null=[IO.Directory]::CreateDirectory($profile)
$normal=Join-Path $profile 'TaskPilot4';$null=[IO.Directory]::CreateDirectory($normal)
$normalSentinel=Join-Path $normal 'normal-do-not-open-as-database.bin';[IO.File]::WriteAllText($normalSentinel,'SYNTHETIC NORMAL SENTINEL')
$runtimePath=Get-TPBuildFullPath $RuntimeAssembly
$runtimeLoaded=[Reflection.Assembly]::LoadFrom($runtimePath)
if(-not[string]::Equals([IO.Path]::GetFullPath($runtimeLoaded.Location),$runtimePath,[StringComparison]::OrdinalIgnoreCase)){throw 'The memory suite must execute the exact packaged runtime assembly.'}
$module=Import-Module (Join-Path $project 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
$sandbox=$null;$store=$null;$database=$null;$taskId=0;$id=[guid]::NewGuid().ToString('N')
$script:memoryCases=New-Object 'Collections.Generic.List[object]';$script:memoryChecks=0
function Check-Memory([bool]$Condition,[string]$Message){$script:memoryChecks++;if(-not$Condition){throw $Message}}
function Reject-Memory([scriptblock]$Action,[string]$Message,[string]$Pattern=''){
    $failure=$null;try{$null=&$Action}catch{$failure=$_}
    Check-Memory ($null-ne$failure) $Message
    if($Pattern){Check-Memory ($failure.Exception.Message-match$Pattern) ('Wrong failure: '+$failure.Exception.Message)}
}
function Case-Memory([string]$Id,[string]$Name,[scriptblock]$Action){
    try{&$Action;$script:memoryCases.Add([pscustomobject]@{Id=$Id;Name=$Name;Passed=$true;Error=$null});Write-Host ('PASS: '+$Id+' '+$Name)}
    catch{$script:memoryCases.Add([pscustomobject]@{Id=$Id;Name=$Name;Passed=$false;Error=$_.Exception.ToString();Stack=$_.ScriptStackTrace});Write-Host ('FAIL: '+$Id+' '+$Name+' : '+$_.Exception.Message)}
}
function Sql-Memory($Store,[string]$Sql,[hashtable]$Parameters=@{},[string]$Mode='Rows'){
    return & $module {param($s,$q,$p,$m) Invoke-TPSql $s $q -Parameters $p -Mode $m} $Store $Sql $Parameters $Mode
}
function Hash-Memory([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
$normalHash=Hash-Memory ([IO.File]::ReadAllBytes($normalSentinel))
try{
    Case-Memory 'M01' 'SQLite receives only an in-memory main database' {
        $script:sandbox=[TaskPilot.Runtime.Sandbox]::Create($profile,$id)
        & $module {param($s) Set-TaskPilotTestSandbox $s} $script:sandbox
        $script:database=Join-Path $script:sandbox.Root 'memory-test.db'
        $null=New-TaskPilotDatabase -DatabasePath $script:database
        $script:store=Open-TaskPilotStore -DatabasePath $script:database
        $list=@(Sql-Memory $script:store 'PRAGMA database_list')
        Check-Memory ($list.Count-eq1-and$list[0].name-ceq'main'-and[string]::IsNullOrEmpty([string]$list[0].file)) 'SQLite opened a durable filename.'
        Check-Memory ($script:store.Connection.ConnectionString-match'Data Source=:memory:') 'The native connection string is not memory-only.'
        Check-Memory ([long](Sql-Memory $script:store 'PRAGMA temp_store' -Mode Scalar)-eq2) 'SQLite temp storage is not memory-only.'
    }
    Case-Memory 'M02' 'Committed CRUD survives a full close and reopen' {
        $created=Add-TaskPilotTask -Store $script:store -Title 'Memory durable task' -RegisteredOn '2026-11-22' -EstimatedHours ([decimal]'1.01')
        $script:taskId=[long]$created.task_id
        $changed=Set-TaskPilotTask -Store $script:store -TaskId $script:taskId -ExpectedVersion $created.row_version -Title 'Committed memory task'
        $removed=Remove-TaskPilotTask -Store $script:store -TaskId $script:taskId -ExpectedVersion $changed.row_version
        $restored=Restore-TaskPilotTask -Store $script:store -TaskId $script:taskId -ExpectedVersion $removed.row_version
        Close-TaskPilotStore $script:store;$script:store=Open-TaskPilotStore -DatabasePath $script:database
        $fresh=@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0]
        Check-Memory ($fresh.title-ceq'Committed memory task'-and$fresh.estimated_hours-eq[decimal]'1.01'-and-not$fresh.is_deleted-and$fresh.row_version-eq$restored.row_version) 'The committed memory snapshot did not round-trip.'
    }
    Case-Memory 'M03' 'One writer owns the image and read-only connections remain immutable snapshots' {
        Reject-Memory {Open-TaskPilotStore -DatabasePath $script:database} 'Two private memory writers could overwrite the same durable image.' 'writable.*already owns'
        $reader=Open-TaskPilotStore -DatabasePath $script:database -ReadOnly
        try{
            $old=@(Get-TaskPilotTask -Store $reader -TaskId $script:taskId)[0]
            $current=@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0]
            $null=Set-TaskPilotTask -Store $script:store -TaskId $script:taskId -ExpectedVersion $current.row_version -Memo 'writer changed after reader snapshot'
            Check-Memory (@(Get-TaskPilotTask -Store $reader -TaskId $script:taskId)[0].row_version-eq$old.row_version) 'A read-only image changed beneath its snapshot.'
            Reject-Memory {Sql-Memory $reader "UPDATE tasks SET title='forbidden'" -Mode NonQuery} 'A direct SQL write bypassed the read-only image.'
            Reject-Memory {Sql-Memory $reader 'PRAGMA query_only=OFF' -Mode NonQuery} 'SQL turned read-only protection off.' 'authoriz'
        }finally{Close-TaskPilotStore $reader}
    }
    Case-Memory 'M04' 'Native authorizer refuses all filesystem database and extension paths' {
        $vacuum=Join-Path $fixture 'must-not-create-vacuum.db'
        Reject-Memory {Sql-Memory $script:store 'ATTACH DATABASE @path AS forbidden' @{path=$normalSentinel} -Mode NonQuery} 'ATTACH reached a synthetic normal file.' 'authoriz'
        Reject-Memory {Sql-Memory $script:store 'VACUUM main INTO @path' @{path=$vacuum} -Mode NonQuery} 'VACUUM INTO opened a filename.' 'authoriz'
        foreach($sql in @('PRAGMA temp_store=FILE','PRAGMA journal_mode=DELETE',"PRAGMA temp_store_directory='C:\untrusted'",'PRAGMA writable_schema=ON')){
            Reject-Memory {Sql-Memory $script:store $sql -Mode NonQuery} 'A pragma enabled pathname I/O or weakened schema checks.' 'authoriz'
        }
        Reject-Memory {Sql-Memory $script:store 'SELECT load_extension(@path)' @{path=$normalSentinel} -Mode Scalar} 'A SQL extension load was permitted.' 'authoriz'
        Check-Memory (-not[IO.File]::Exists($vacuum)) 'A denied VACUUM created an output.'
        Check-Memory ((Hash-Memory ([IO.File]::ReadAllBytes($normalSentinel)))-ceq$normalHash) 'A denied SQL path changed the synthetic normal sentinel.'
    }
    Case-Memory 'M05' 'A deferred foreign-key failure cannot publish an uncommitted snapshot' {
        $before=Hash-Memory ($script:sandbox.ReadAllBytes($script:database));$current=@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0]
        Reject-Memory {Invoke-TaskPilotTransaction -Store $script:store -Action {
            param($s)
            $null=Set-TaskPilotTask -Store $s -TaskId $script:taskId -ExpectedVersion $current.row_version -Title 'must roll back at commit'
            $null=Sql-Memory $s "INSERT INTO monthly_snapshots(calendar_id,month_key,current_revision) VALUES(1,'2026-11',999)" -Mode NonQuery
        }} 'The deferred constraint committed an invalid image.'
        $after=@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0]
        Check-Memory ($after.title-ceq$current.title-and$after.row_version-eq$current.row_version) 'The failed deferred commit changed memory.'
        Check-Memory ((Hash-Memory ($script:sandbox.ReadAllBytes($script:database)))-ceq$before) 'The failed deferred commit changed durable bytes.'
        Check-Memory ([long](Sql-Memory $script:store "SELECT COUNT(*) FROM monthly_snapshots WHERE month_key='2026-11'" -Mode Scalar)-eq0) 'The invalid monthly row survived rollback.'
    }
    Case-Memory 'M06' 'A simulated broker failure restores memory and leaves durable data unchanged' {
        $before=Hash-Memory ($script:sandbox.ReadAllBytes($script:database));$current=@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0]
        # Explicit test-only fault injection at the persistence call boundary.
        # No validation/authorizer/broker guard is replaced or disabled.
        & $module {$script:TPTestOriginalSave=${function:Save-TPMemoryConnection};Set-Item function:script:Save-TPMemoryConnection -Value {param($Connection) throw 'SIMULATED_BROKER_PUBLISH_FAILURE'}}
        try{
            Reject-Memory {Set-TaskPilotTask -Store $script:store -TaskId $script:taskId -ExpectedVersion $current.row_version -Title 'must roll back after native commit'} 'A failed durable publication was reported successful.' 'SIMULATED_BROKER_PUBLISH_FAILURE'
        }finally{& $module {Set-Item function:script:Save-TPMemoryConnection -Value $script:TPTestOriginalSave;Remove-Variable TPTestOriginalSave -Scope Script}}
        $after=@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0]
        Check-Memory ($after.title-ceq$current.title-and$after.row_version-eq$current.row_version) 'Publication failure left memory ahead of the saved image.'
        Check-Memory ((Hash-Memory ($script:sandbox.ReadAllBytes($script:database)))-ceq$before) 'The simulated failure changed durable bytes.'
        $null=Set-TaskPilotTask -Store $script:store -TaskId $script:taskId -ExpectedVersion $after.row_version -Memo 'a later real publication succeeds'
        Check-Memory (@(Get-TaskPilotTask -Store $script:store -TaskId $script:taskId)[0].row_version-eq$after.row_version+1) 'A safely rolled-back writer could not save again.'
        Reject-Memory {Sql-Memory $script:store 'ATTACH DATABASE @path AS forbidden' @{path=$normalSentinel} -Mode NonQuery} 'Restoring memory lost its native authorizer.' 'authoriz'
    }
    Case-Memory 'M07' 'Memory backup and new-file restore preserve the complete image' {
        $backup=Join-Path $script:sandbox.Backup 'memory-backup.db';$restored=Join-Path $script:sandbox.Root 'memory-restored.db'
        $saved=New-TaskPilotDatabaseBackup -Store $script:store -DestinationPath $backup
        Check-Memory $saved.Verified 'The serialized backup was not verified.'
        $result=Restore-TaskPilotDatabase -BackupPath $backup -DatabasePath $restored
        Check-Memory ($result.Verified-and-not$result.ExistingDatabaseModified) 'Restore changed an existing image.'
        Check-Memory ((Hash-Memory ($script:sandbox.ReadAllBytes($backup)))-ceq(Hash-Memory ($script:sandbox.ReadAllBytes($restored)))) 'Restore bytes differ from the verified image.'
        $restoredStore=Open-TaskPilotStore -DatabasePath $restored -ReadOnly
        try{
            Check-Memory (@(Get-TaskPilotTask -Store $restoredStore -TaskId $script:taskId)[0].memo-ceq'a later real publication succeeds') 'Restored task state was lost.'
            Check-Memory ((Sql-Memory $restoredStore 'PRAGMA integrity_check' -Mode Scalar)-ceq'ok') 'Restored integrity check failed.'
        }finally{Close-TaskPilotStore $restoredStore}
    }
    Case-Memory 'M08' 'An interrupted broker checkpoint is preserved and blocks startup without recovery' {
        [byte[]]$before=$script:sandbox.ReadAllBytes($script:database);$beforeHash=Hash-Memory $before
        $checkpoint=Join-Path $script:sandbox.Root '.tp-rollback_synthetic-interruption.bin'
        $script:sandbox.WriteNew($checkpoint,$before)
        Close-TaskPilotStore $script:store;$script:store=$null;$script:sandbox.Dispose();$script:sandbox=$null
        Reject-Memory {[TaskPilot.Runtime.Sandbox]::Create($profile,$id)} 'Startup ignored or automatically recovered an interrupted write.' 'interrupted broker write'
        Check-Memory ((Hash-Memory ([IO.File]::ReadAllBytes($script:database)))-ceq$beforeHash) 'Rejected startup changed the database.'
        Check-Memory ((Hash-Memory ([IO.File]::ReadAllBytes($checkpoint)))-ceq$beforeHash) 'Rejected startup changed the preserved rollback image.'
    }
}finally{
    if($null-ne$script:store-and-not$script:store.Closed){Close-TaskPilotStore $script:store}
    if($null-ne$script:sandbox){$script:sandbox.Dispose()}
    Remove-Module TaskPilot.Storage -Force -ErrorAction SilentlyContinue
}
$normalUnchanged=(Hash-Memory ([IO.File]::ReadAllBytes($normalSentinel)))-ceq$normalHash
$failures=@($script:memoryCases|Where-Object {-not$_.Passed})
$report=[pscustomobject][ordered]@{Stage='Native memory-only SQLite persistence';Passed=($failures.Count-eq0-and$normalUnchanged);Checks=$script:memoryChecks;Cases=$script:memoryCases.ToArray();FailedCases=$failures.Count;NormalFixtureUnchanged=$normalUnchanged;ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11Verified=$false;SkippedDetails=@();TestRoot=$fixture;FaultInjection='M06 replaces only the module persistence call with a throwing test function before broker publication; all security checks remain active.'}
Write-TPBuildNewText (Join-Path $output ('IsolatedMemory_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 12)
return $report
