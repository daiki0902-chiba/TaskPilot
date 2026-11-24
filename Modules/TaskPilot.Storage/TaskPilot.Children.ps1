function Get-TaskPilotSubtask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId)
    $null=Get-TPTaskRequired $Store $TaskId -AllowDeleted
    Invoke-TPSql $Store 'SELECT * FROM subtasks WHERE parent_task_id=@id ORDER BY sort_order,subtask_id' -Parameters @{id=$TaskId}
}
function Add-TaskPilotSubtask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Title)
    Invoke-TPUnitOfWork $Store {
        if([string]::IsNullOrWhiteSpace($Title)-or $Title.Length -gt 200){throw 'Subtask title must contain 1 to 200 characters.'}
        Touch-TPTask $Store $TaskId $ExpectedVersion
        $subId=[guid]::NewGuid().ToString('N');$sort=[long](Invoke-TPSql $Store 'SELECT COALESCE(MAX(sort_order),-1)+1 FROM subtasks WHERE parent_task_id=@id' -Parameters @{id=$TaskId} -Mode Scalar)
        $null=Invoke-TPSql $Store 'INSERT INTO subtasks(subtask_id,parent_task_id,title,is_done,sort_order) VALUES(@sub,@task,@title,0,@sort)' -Parameters @{sub=$subId;task=$TaskId;title=$Title;sort=$sort} -Mode NonQuery
        [pscustomobject]@{Task=Get-TPTaskRequired $Store $TaskId;Subtask=@(Get-TaskPilotSubtask $Store $TaskId|Where-Object{$_.subtask_id-eq$subId})[0]}
    }
}
function Set-TaskPilotSubtask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$SubtaskId,[Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Title,[Parameter(Mandatory=$true)][object]$Done)
    Invoke-TPUnitOfWork $Store {
        if($Done -isnot [bool]){throw 'Done must be a Boolean.'}
        if([string]::IsNullOrWhiteSpace($Title)-or $Title.Length -gt 200){throw 'Subtask title must contain 1 to 200 characters.'};Touch-TPTask $Store $TaskId $ExpectedVersion
        $n=Invoke-TPSql $Store 'UPDATE subtasks SET title=@title,is_done=@done WHERE subtask_id=@sub AND parent_task_id=@task' -Parameters @{title=$Title;done=$Done;sub=$SubtaskId;task=$TaskId} -Mode NonQuery
        if($n-ne 1){throw 'Subtask does not belong to the selected task.'}
        [pscustomobject]@{Task=Get-TPTaskRequired $Store $TaskId;Subtask=@(Get-TaskPilotSubtask $Store $TaskId|Where-Object{$_.subtask_id-eq$SubtaskId})[0]}
    }
}
function Remove-TaskPilotSubtask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$SubtaskId)
    Invoke-TPUnitOfWork $Store {Touch-TPTask $Store $TaskId $ExpectedVersion;$n=Invoke-TPSql $Store 'DELETE FROM subtasks WHERE subtask_id=@sub AND parent_task_id=@task' -Parameters @{sub=$SubtaskId;task=$TaskId} -Mode NonQuery;if($n-ne 1){throw 'Subtask does not belong to the selected task.'};Get-TPTaskRequired $Store $TaskId}
}
function Get-TaskPilotWorkLog {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId)
    $null=Get-TPTaskRequired $Store $TaskId -AllowDeleted
    foreach($row in @(Invoke-TPSql $Store 'SELECT * FROM work_logs WHERE task_id=@id ORDER BY sort_order,entry_id' -Parameters @{id=$TaskId})){$row|Add-Member -NotePropertyName hours -NotePropertyValue ([decimal]$row.hours_x100/100);$row}
}
function Add-TaskPilotWorkLog {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$WorkDate,[Parameter(Mandatory=$true)][decimal]$Hours,[string]$Memo='')
    Invoke-TPUnitOfWork $Store {
        Assert-TPDate $WorkDate;$h=ConvertTo-TPHours $Hours -Maximum 2400;if($h-lt 25){throw 'Work log hours must be between 0.25 and 24.'};Touch-TPTask $Store $TaskId $ExpectedVersion
        $logId=[guid]::NewGuid().ToString('N');$sort=[long](Invoke-TPSql $Store 'SELECT COALESCE(MAX(sort_order),-1)+1 FROM work_logs' -Mode Scalar)
        $null=Invoke-TPSql $Store 'INSERT INTO work_logs(entry_id,task_id,work_date,hours_x100,memo,sort_order) VALUES(@entry,@task,@date,@hours,@memo,@sort)' -Parameters @{entry=$logId;task=$TaskId;date=$WorkDate;hours=$h;memo=$Memo;sort=$sort} -Mode NonQuery
        [pscustomobject]@{Task=Get-TPTaskRequired $Store $TaskId;WorkLog=@(Get-TaskPilotWorkLog $Store $TaskId|Where-Object{$_.entry_id-eq$logId})[0]}
    }
}
function Set-TaskPilotWorkLog {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$EntryId,[Parameter(Mandatory=$true)][string]$WorkDate,[Parameter(Mandatory=$true)][decimal]$Hours,[string]$Memo='')
    Invoke-TPUnitOfWork $Store {
        Assert-TPDate $WorkDate;$h=ConvertTo-TPHours $Hours -Maximum 2400;if($h-lt 25){throw 'Work log hours must be between 0.25 and 24.'};Touch-TPTask $Store $TaskId $ExpectedVersion
        $n=Invoke-TPSql $Store 'UPDATE work_logs SET work_date=@date,hours_x100=@hours,memo=@memo WHERE entry_id=@entry AND task_id=@task' -Parameters @{entry=$EntryId;task=$TaskId;date=$WorkDate;hours=$h;memo=$Memo} -Mode NonQuery
        if($n-ne 1){throw 'Work log does not belong to the selected task.'}
        [pscustomobject]@{Task=Get-TPTaskRequired $Store $TaskId;WorkLog=@(Get-TaskPilotWorkLog $Store $TaskId|Where-Object{$_.entry_id-eq$EntryId})[0]}
    }
}
function Remove-TaskPilotWorkLog {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$EntryId)
    Invoke-TPUnitOfWork $Store {Touch-TPTask $Store $TaskId $ExpectedVersion;$n=Invoke-TPSql $Store 'DELETE FROM work_logs WHERE entry_id=@entry AND task_id=@task' -Parameters @{entry=$EntryId;task=$TaskId} -Mode NonQuery;if($n-ne 1){throw 'Work log does not belong to the selected task.'};Get-TPTaskRequired $Store $TaskId}
}
function Get-TaskPilotCompletionActual {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId)
    $null=Get-TPTaskRequired $Store $TaskId -AllowDeleted
    foreach($row in @(Invoke-TPSql $Store 'SELECT * FROM completion_actuals WHERE task_id=@id' -Parameters @{id=$TaskId})){$row|Add-Member -NotePropertyName actual_hours -NotePropertyValue ([decimal]$row.actual_hours_x100/100);$row}
}
function Set-TaskPilotCompletionActual {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$CompletedOn,[Parameter(Mandatory=$true)][decimal]$ActualHours)
    Invoke-TPUnitOfWork $Store {
        Assert-TPDate $CompletedOn;$h=ConvertTo-TPHours $ActualHours -Maximum 10000000;$task=Get-TPTaskRequired $Store $TaskId
        if($task.status-ne'完了'){throw 'Completion actuals can be entered only for completed tasks.'};Touch-TPTask $Store $TaskId $ExpectedVersion
        $null=Invoke-TPSql $Store 'INSERT INTO completion_actuals(task_id,completed_on,actual_hours_x100,task_name_snapshot) VALUES(@id,@date,@hours,@name) ON CONFLICT(task_id) DO UPDATE SET completed_on=excluded.completed_on,actual_hours_x100=excluded.actual_hours_x100,task_name_snapshot=excluded.task_name_snapshot' -Parameters @{id=$TaskId;date=$CompletedOn;hours=$h;name=$task.title} -Mode NonQuery
        [pscustomobject]@{Task=Get-TPTaskRequired $Store $TaskId;Actual=Get-TaskPilotCompletionActual $Store $TaskId}
    }
}
function Complete-TaskPilotTask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[Nullable[decimal]]$ActualHours,[string]$CompletedOn=(Get-Date).ToString('yyyy-MM-dd'))
    Invoke-TPUnitOfWork $Store {
        $completedTask=Set-TaskPilotTask -Store $Store -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Status '完了'
        if($null-ne$ActualHours){$result=Set-TaskPilotCompletionActual -Store $Store -TaskId $TaskId -ExpectedVersion $completedTask.row_version -CompletedOn $CompletedOn -ActualHours $ActualHours;return $result}
        [pscustomobject]@{Task=$completedTask;Actual=Get-TaskPilotCompletionActual $Store $TaskId}
    }
}
function Get-TaskPilotReadSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store)
    Assert-TPStore $Store
    if($null-ne$Store.Transaction){throw 'Begin a read snapshot outside another transaction.'}
    $Store.Transaction=$Store.Connection.BeginTransaction([Data.IsolationLevel]::ReadCommitted);$Store.TransactionReadOnly=$true
    try {
        $data=[ordered]@{}
        foreach($table in @('tasks','task_plans','subtasks','work_logs','completion_actuals','capacity_calendars','calendar_weekdays','company_closures','capacity_overrides','holiday_sets','public_holidays','recurring_rules','recurring_occurrences','monthly_snapshots','monthly_snapshot_revisions','monthly_revision_events','app_settings','notification_state','notification_history','report_state')){
            $data[$table]=@(Invoke-TPSql $Store ('SELECT * FROM '+$table+' ORDER BY rowid'))
        }
        $Store.Transaction.Commit()
        return [pscustomobject]@{CapturedAtUtc=Get-TPUtcNow;Data=$data;Token=Get-TPToken $data}
    } catch{try{$Store.Transaction.Rollback()}catch{};throw}
    finally{$Store.Transaction.Dispose();$Store.Transaction=$null;$Store.TransactionReadOnly=$false;$Store.TransactionFailed=$false}
}
