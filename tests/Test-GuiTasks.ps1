#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../Adapters/TaskPilot.GuiCommon.ps1')
. (Join-Path $PSScriptRoot '../Adapters/TaskPilot.GuiTasks.ps1')
$TaskFile='TaskList.csv';$ArchiveFile='CompletedTask.csv'
$script:providerArgs=@{};if($TestProviderAssembly){$script:providerArgs.TestProviderAssembly=$TestProviderAssembly}
$modulePath=Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
$null=Import-Module $modulePath -Force
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotGuiTasks_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$script:passed=0;$script:failed=0;$script:assertions=0
function Assert-GuiTask([bool]$Ok,[string]$Message){$script:assertions++;if(-not$Ok){throw $Message}}
function Reject-GuiTask([scriptblock]$Action,[string]$Message){$failed=$false;try{$null=&$Action}catch{$failed=$true};Assert-GuiTask $failed $Message}
function New-GuiTaskValue([string]$Title='Task',[string]$Status='未着手'){
    [pscustomobject]@{Task=$Title;Priority='中';Status=$Status;DueDate='2026/12/01';Memo="日本語 'quoted'`r`nDROP TABLE tasks;";PlannedDate='2026/11/17';WorkStartDate='2026/11/16';EstimatedHours=[decimal]'0.01'}
}
function Invoke-GuiTaskCase([string]$Name,[scriptblock]$Action){
    $script:dbPath=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.db')
    $null=New-TaskPilotDatabase -DatabasePath $script:dbPath @script:providerArgs
    $store=Open-TaskPilotStore -DatabasePath $script:dbPath @script:providerArgs
    Initialize-TPGuiContext -Store $store -ModulePath $modulePath
    try{&$Action;$script:passed++;Write-Output ('PASS: '+$Name)}
    catch{$script:failed++;Write-Output ('FAIL: '+$Name+' : '+$_.Exception.Message);Write-Output $_.ScriptStackTrace}
    finally{Close-TaskPilotStore $store}
}
try{
    Invoke-GuiTaskCase 'Atomic task DTO create/edit preserves Unicode, exact hours and metadata' {
        $value=New-GuiTaskValue '日本語 "見積"'
        $id=Save-TPGuiTaskAggregate -Target $null -Value $value
        Assert-GuiTask ($id-is[long] -and $id-eq1) 'Aggregate must return only the reserved long task ID.'
        $task=@(Read-Tasks $TaskFile)[0]
        Assert-GuiTask ($task.ID-eq1 -and $task.Task-ceq$value.Task -and $task.Memo-ceq$value.Memo -and $task.TPRowVersion-eq1) 'Task DTO changed text or version.'
        $plans=Read-WorkPlans;$dates=Read-PlannedDates
        Assert-GuiTask ($plans['1'].EstimatedHours-eq[decimal]'0.01' -and $plans['1'].StartDate-ceq'2026/11/16' -and $dates['1']-ceq'2026/11/17') 'Metadata was not saved with the task.'
        $edit=[pscustomobject]@{Task='Changed';Priority='高';Status='対応中';DueDate='';Memo=''}
        $saved=Save-TPGuiTaskAggregate -Target $task -Value $edit
        $fresh=@(Read-Tasks $TaskFile)[0]
        Assert-GuiTask ($saved-eq$id -and $fresh.TPRowVersion-eq2 -and $fresh.Task-ceq'Changed' -and $fresh.DueDate-ceq'') 'Edit failed or version did not increment.'
        Assert-GuiTask ((Read-WorkPlans)['1'].EstimatedHours-eq[decimal]'0.01' -and (Read-PlannedDates)['1']-ceq'2026/11/17') 'Unspecified metadata was changed.'
    }
    Invoke-GuiTaskCase 'Original dialog version survives later list reads and rejects stale overwrite' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Original')
        $old=@(Read-Tasks $TaskFile)[0]
        $other=Open-TaskPilotStore -DatabasePath $script:dbPath @script:providerArgs
        try{$null=Set-TaskPilotTask -Store $other -TaskId $id -ExpectedVersion 1 -Title 'Concurrent winner'}finally{Close-TaskPilotStore $other}
        $null=@(Read-Tasks $TaskFile)
        Reject-GuiTask {Save-TPGuiTaskAggregate $old (New-GuiTaskValue 'Stale edit')} 'An old dialog target must not use a refreshed list token.'
        Assert-GuiTask (@(Read-Tasks $TaskFile)[0].Task-ceq'Concurrent winner') 'Stale dialog overwrote a newer title.'
    }
    Invoke-GuiTaskCase 'Late plan validation rolls back title, version and a new task reservation' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Before')
        $target=@(Read-Tasks $TaskFile)[0];$bad=New-GuiTaskValue 'Partial';$bad.EstimatedHours=[decimal]'0.001'
        Reject-GuiTask {Save-TPGuiTaskAggregate $target $bad} 'Overprecision must abort an edit.'
        $fresh=@(Read-Tasks $TaskFile)[0]
        Assert-GuiTask ($fresh.Task-ceq'Before' -and $fresh.TPRowVersion-eq1 -and (Read-WorkPlans)['1'].EstimatedHours-eq[decimal]'0.01') 'Late failure committed part of an edit.'
        Reject-GuiTask {Save-TPGuiTaskAggregate $null $bad} 'Overprecision must abort a new task.'
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq1) 'Failed add left a task.'
        $next=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'After failure')
        Assert-GuiTask ($next-eq2) 'Rolled-back reservation changed the task sequence.'
    }
    Invoke-GuiTaskCase 'Full-list saves require reserved new IDs and preserve a read snapshot' {
        $items=@(Read-Tasks $TaskFile)
        $row=[pscustomobject]@{ID=9;Date='2026/11/16';Task='Unreserved';Priority='中';DueDate='';Status='未着手';Memo=''}
        Reject-GuiTask {Save-Tasks $TaskFile @($row)} 'Unreserved explicit IDs must be rejected.'
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq0) 'Unreserved insert left a task.'
        $row.ID=Reserve-TaskId
        Save-Tasks $TaskFile @($row)
        $items=@(Read-Tasks $TaskFile)
        Assert-GuiTask ($items.Count-eq1 -and $items[0].ID-eq1) 'Reserved explicit ID did not persist.'
        $items[0].Task='Changed snapshot';Save-Tasks $TaskFile $items
        $fresh=@(Read-Tasks $TaskFile)[0]
        Assert-GuiTask ($fresh.Task-ceq'Changed snapshot' -and $fresh.TPRowVersion-eq2) 'Snapshot edit did not persist.'
        $other=Open-TaskPilotStore -DatabasePath $script:dbPath @script:providerArgs
        try{$null=Set-TaskPilotTask -Store $other -TaskId 1 -ExpectedVersion 2 -Title 'External'}finally{Close-TaskPilotStore $other}
        Reject-GuiTask {Save-Tasks $TaskFile @() -ExpectedSnapshotToken $fresh.TPReadToken} 'Omitted stale task must not be silently deleted.'
        Assert-GuiTask (@(Read-Tasks $TaskFile)[0].Task-ceq'External') 'Snapshot save overwrote concurrent change.'
    }
    Invoke-GuiTaskCase 'Task soft deletion retains children, logs and completion actuals' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Delete me' '完了')
        $task=@(Read-Tasks $TaskFile)[0]
        Save-ActualHours ([string]$id) ([datetime]'2026-11-16') ([decimal]'2.34') 'Name when completed' -ExpectedVersion $task.TPRowVersion
        $null=@(Read-Tasks $TaskFile);$children=@(Read-Subtasks)
        Save-Subtasks @($children+@([pscustomobject]@{Id='child-original';ParentId=[string]$id;Title='Kept child';Done=$false}))
        $null=@(Read-Tasks $TaskFile);$logs=@(Read-WorkLogs)
        Save-WorkLogs @($logs+@([pscustomobject]@{EntryId='log-original';TaskId=[string]$id;WorkDate='2026/11/16';Hours=[decimal]'0.01';Memo='Kept log'}))
        $deleteTarget=@(Read-Tasks $TaskFile)[0];Save-Tasks $TaskFile @() -ExpectedSnapshotToken $deleteTarget.TPReadToken
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq0) 'Deleted task remains in active list.'
        Assert-GuiTask ([long](Invoke-TPGuiSql 'SELECT is_deleted FROM tasks WHERE task_id=1' -Mode Scalar)-eq1) 'Omission must soft-delete the task.'
        Assert-GuiTask ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM subtasks' -Mode Scalar)-eq1 -and [long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM work_logs' -Mode Scalar)-eq1 -and [long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM completion_actuals' -Mode Scalar)-eq1) 'Task deletion removed retained child/history data.'
    }
    Invoke-GuiTaskCase 'Work-log append, remove and stale owner checks preserve exact .01 hours' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Parent')
        $second=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Other parent')
        $null=@(Read-Tasks $TaskFile);$logs=@(Read-WorkLogs)
        $log=[pscustomobject]@{EntryId='original';TaskId=[string]$id;WorkDate='2026/11/16';Hours=[decimal]'0.01';Memo='Quote '' + 日本語'}
        Save-WorkLogs @($logs+@($log))
        $logs=@(Read-WorkLogs)
        Assert-GuiTask ($logs.Count-eq1 -and $logs[0].EntryId-ceq'original' -and $logs[0].Hours-eq[decimal]'0.01') 'Work-log ID or hundredth hour changed.'
        $logs[0].TaskId=[string]$second
        Reject-GuiTask {Save-WorkLogs $logs} 'Existing work log must not move to another owner.'
        $logs=@(Read-WorkLogs);$logs[0].Memo='Stale memo'
        $parent=@(Get-TaskPilotTask -Store $script:TPGuiStore -TaskId $id)[0]
        $null=Set-TaskPilotTask -Store $script:TPGuiStore -TaskId $id -ExpectedVersion $parent.row_version -Title 'Updated parent'
        $null=@(Read-Tasks $TaskFile)
        Reject-GuiTask {Save-WorkLogs $logs} 'Parent version captured with work logs must remain authoritative.'
        Assert-GuiTask (@(Read-WorkLogs)[0].Memo-ceq$log.Memo) 'Stale log write changed stored memo.'
        $null=@(Read-WorkLogs);Save-WorkLogs @() -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'work_logs')
        Assert-GuiTask (@(Read-WorkLogs).Count-eq0) 'Explicit work-log removal failed.'
    }
    Invoke-GuiTaskCase 'Subtask Boolean and ownership validation, edits and explicit removals' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Parent')
        $other=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Other')
        $null=@(Read-Tasks $TaskFile);$null=@(Read-Subtasks)
        Reject-GuiTask {Save-Subtasks @([pscustomobject]@{Id='c';ParentId=[string]$id;Title='Child';Done='false'})} 'String false must not become true.'
        $null=@(Read-Subtasks)
        Save-Subtasks @([pscustomobject]@{Id='c';ParentId=[string]$id;Title='Child';Done=$false})
        $rows=@(Read-Subtasks);$rows[0].ParentId=[string]$other
        Reject-GuiTask {Save-Subtasks $rows} 'Child ownership must not change.'
        $rows=@(Read-Subtasks);$rows[0].Done=$true;Save-Subtasks $rows
        Assert-GuiTask (@(Read-Subtasks)[0].Done) 'Subtask completion was not saved.'
        $null=@(Read-Subtasks);Save-Subtasks @() -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')
        Assert-GuiTask (@(Read-Subtasks).Count-eq0) 'Explicit subtask removal failed.'
    }
    Invoke-GuiTaskCase 'Ambient transaction rollback contains all task and metadata changes' {
        Reject-GuiTask {Invoke-TPGuiTransaction {$null=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Temporary');throw 'Synthetic late operation failure'}} 'Ambient failure must be propagated.'
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq0 -and [long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM task_plans' -Mode Scalar)-eq0) 'Nested aggregate escaped outer rollback.'
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Durable')
        Assert-GuiTask ($id-eq1) 'Nested rollback left an identity reservation.'
    }
    Invoke-GuiTaskCase 'Later list reads cannot authorize omissions from an older caller snapshot' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'First')
        $old=@(Read-Tasks $TaskFile)
        $other=Open-TaskPilotStore -DatabasePath $script:dbPath @script:providerArgs
        try{$null=Add-TaskPilotTask -Store $other -Title 'Concurrent new task'}finally{Close-TaskPilotStore $other}
        $null=@(Read-Tasks $TaskFile)
        Reject-GuiTask {Save-Tasks $TaskFile $old} 'Old list must not omit a newly added task even after an unrelated fresh read.'
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq2) 'Old caller snapshot deleted the concurrent task.'
        Reject-GuiTask {Save-Tasks $TaskFile @()} 'Empty list cannot implicitly authorize deletion of all current tasks.'
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq2) 'Implicit empty save deleted current tasks.'
    }
    Invoke-GuiTaskCase 'Child snapshots retain their original rows and parent versions across later reads' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Parent')
        $null=@(Read-Subtasks)
        Save-Subtasks @([pscustomobject]@{Id='first';ParentId=[string]$id;Title='First';Done=$false})
        $old=@(Read-Subtasks)
        $parent=@(Get-TaskPilotTask -Store $script:TPGuiStore -TaskId $id)[0]
        $null=Add-TaskPilotSubtask -Store $script:TPGuiStore -TaskId $id -ExpectedVersion $parent.row_version -Title 'Concurrent second child'
        $null=@(Read-Subtasks)
        Reject-GuiTask {Save-Subtasks $old} 'Later child read must not authorize omissions from an old snapshot.'
        Assert-GuiTask (@(Read-Subtasks).Count-eq2) 'Old child snapshot deleted the concurrent child.'
        Reject-GuiTask {Save-Subtasks @()} 'Empty child save must require explicit original snapshot token.'
        Assert-GuiTask (@(Read-Subtasks).Count-eq2) 'Implicit empty child save removed stored children.'
    }
    Invoke-GuiTaskCase 'Archive membership is independent of completion status' {
        $null=@(Read-Tasks $ArchiveFile);$id=Reserve-TaskId
        Save-Tasks $ArchiveFile @([pscustomobject]@{ID=$id;Date='2026/11/16';Task='Archived pending';Priority='低';Status='未着手';DueDate='';Memo=''})
        $archived=@(Read-Tasks $ArchiveFile)
        Assert-GuiTask ($archived.Count-eq1 -and $archived[0].Status-ceq'未着手' -and $archived[0].TPIsArchived) 'Archive mapping changed task status.'
        Assert-GuiTask (@(Read-Tasks $TaskFile).Count-eq0) 'Archive task leaked into active partition.'
        $next=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Next active')
        Assert-GuiTask ($next-eq$id+1) 'Archive explicit ID did not preserve the shared sequence.'
    }
    Invoke-GuiTaskCase 'Imported task without an optional plan row can be edited atomically' {
        $null=Invoke-TPGuiSql -Sql "INSERT INTO tasks(task_id,registered_on,title,priority,status) VALUES(41,'2026-11-16','Imported task','中','未着手')" -Mode NonQuery
        $target=@(Read-Tasks $TaskFile)[0]
        Assert-GuiTask ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM task_plans' -Mode Scalar)-eq0) 'Fixture should not contain an optional plan row.'
        $id=Save-TPGuiTaskAggregate $target (New-GuiTaskValue 'Edited imported task')
        Assert-GuiTask ($id-eq41 -and (Read-WorkPlans)['41'].EstimatedHours-eq[decimal]'0.01') 'Editing an imported task failed to create its optional plan.'
    }
    Invoke-GuiTaskCase 'Retained imported child text is readable and survives an unrelated edit' {
        $id=Save-TPGuiTaskAggregate $null (New-GuiTaskValue 'Parent')
        $title='保管済みの長い名前' * 30
        $null=Invoke-TPGuiSql -Sql 'INSERT INTO subtasks(subtask_id,parent_task_id,title,is_done,sort_order) VALUES(@child,@id,@title,0,0)' -Parameters @{child='retained';id=$id;title=$title} -Mode NonQuery
        $children=@(Read-Subtasks)
        Assert-GuiTask ($children.Count-eq1 -and $children[0].Title-ceq$title) 'An imported title became unreadable or was shortened.'
        $children[0].Done=$true
        Save-Subtasks $children
        $saved=@(Read-Subtasks)
        Assert-GuiTask ($saved[0].Done -and $saved[0].Title-ceq$title) 'A checkbox edit changed retained imported text.'
    }
    Invoke-GuiTaskCase 'Exhausted identities refuse new tasks while retaining access to existing work' {
        $null=Invoke-TPGuiSql -Sql "INSERT INTO tasks(task_id,registered_on,title,priority,status) VALUES(2147483647,'2026-11-16','Last ID','中','未着手')" -Mode NonQuery
        Repair-NextTaskId
        $target=@(Read-Tasks $TaskFile)[0]
        Reject-GuiTask {Reserve-TaskId} 'An exhausted sequence must reject another reservation.'
        $id=Save-TPGuiTaskAggregate $target (New-GuiTaskValue 'Existing work remains editable')
        Assert-GuiTask ($id-eq2147483647) 'Existing task identity changed at sequence exhaustion.'
        Assert-GuiTask (@(Read-Tasks $TaskFile)[0].Task-ceq'Existing work remains editable') 'Existing tasks became inaccessible at sequence exhaustion.'
        Assert-GuiTask ([long](Invoke-TPGuiSql "SELECT seq FROM sqlite_sequence WHERE name='tasks'" -Mode Scalar)-eq2147483647) 'The exhausted sequence was reset or reused.'
    }
    Write-Output ('Result: '+$script:passed+' GUI task cases passed, '+$script:failed+' failed; '+$script:assertions+' assertions.')
    if($script:failed){throw 'GUI task adapter tests failed.'}
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
