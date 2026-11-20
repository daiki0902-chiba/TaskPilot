# Run from Test-TaskPilotStep4B.ps1. All databases belong to the unique test sandbox.
Test-Case 'Provider identity, schema and 26 tables' {
    $info=Get-TaskPilotStoreInfo $script:s
    Assert ($info.SchemaVersion-eq40001 -and $info.Tables-eq26) 'Wrong database identity'
    Assert ([version]$info.SQLiteVersion-ge[version]'3.38') 'SQLite runtime is too old'
}
Test-Case 'New database path refuses existing file' {
    Close-TaskPilotStore $script:s
    $before=Get-FileHash -LiteralPath $script:dbPath -Algorithm SHA256
    Must-Fail {New-TaskPilotDatabase $script:dbPath @script:providerArgs} 'exists'
    Assert ((Get-FileHash $script:dbPath -Algorithm SHA256).Hash-eq$before.Hash) 'Existing database changed'
}
Test-Case 'Opening a missing file never creates an empty database' {
    $absent=Join-Path $script:testRoot 'missing.db'
    Must-Fail {Open-TaskPilotStore $absent @script:providerArgs} 'does not exist'
    Assert (-not(Test-Path -LiteralPath $absent)) 'Open created a database'
}
Test-Case 'Existing recovery sidecar is preserved' {
    $target=Join-Path $script:testRoot 'sidecar-only.db';$side=$target+'-journal'
    [IO.File]::WriteAllText($side,'preserve-me')
    Must-Fail {New-TaskPilotDatabase $target @script:providerArgs} 'sidecar'
    Assert ([IO.File]::ReadAllText($side)-eq'preserve-me' -and -not(Test-Path $target)) 'Recovery evidence changed'
}
Test-Case 'Legacy TaskPilot location is rejected before writing' {
    $local=[Environment]::GetFolderPath('LocalApplicationData')
    if($local){$target=Join-Path (Join-Path $local 'TaskPilot') 'STEP4B-test-must-not-exist.db';Must-Fail {New-TaskPilotDatabase $target @script:providerArgs} 'legacy'}
}
Test-Case 'Unicode quotes newlines and SQL-looking input round-trip' {
    $title="日本語 'quote' `"double`"`nDROP TABLE tasks;";$memo='=HYPERLINK("https://example.invalid")'
    $task=Add-TaskPilotTask $script:s -Title $title -Memo $memo
    $read=@(Get-TaskPilotTask $script:s -TaskId $task.task_id)[0]
    Assert ($read.title-ceq$title -and $read.memo-ceq$memo) 'Text did not round-trip'
}
Test-Case 'One hundredth hour is preserved exactly' {
    $task=Add-TaskPilotTask $script:s -Title 'precision' -EstimatedHours 0.01
    Assert ($task.estimated_hours_x100-eq1 -and $task.estimated_hours-eq[decimal]'0.01') 'Precision lost'
}
Test-Case 'Partial date and plan edits retain other fields' {
    $task=Add-TaskPilotTask $script:s -Title 'dates' -RegisteredOn '2026-01-02' -DueOn '2026-02-03' -PlannedOn '2026-02-01' -WorkStartOn '2026-01-31' -EstimatedHours 8.25
    $changed=Set-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'renamed'
    Assert ($changed.registered_on-eq'2026-01-02' -and $changed.due_on-eq'2026-02-03' -and $changed.planned_on-eq'2026-02-01' -and $changed.work_start_on-eq'2026-01-31' -and $changed.estimated_hours_x100-eq825) 'Unspecified fields were overwritten'
    $cleared=Set-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $changed.row_version -DueOn '' -PlannedOn '' -WorkStartOn ''
    Assert ($null-eq$cleared.due_on -and $null-eq$cleared.planned_on -and $null-eq$cleared.work_start_on -and $cleared.estimated_hours_x100-eq825) 'Explicit date clearing failed'
}
Test-Case 'Invalid real dates and excess decimal precision are rejected' {
    Must-Fail {Add-TaskPilotTask $script:s -Title 'invalid' -DueOn '2026-02-30'} 'Invalid'
    Must-Fail {Add-TaskPilotTask $script:s -Title 'invalid' -EstimatedHours 0.001} 'decimal'
    Assert (@(Get-TaskPilotTask $script:s).Count-eq0) 'Failed adds left tasks'
}
Test-Case 'Aggregate update rolls back title version and plan on a late failure' {
    $task=Add-TaskPilotTask $script:s -Title 'before' -EstimatedHours 2
    Must-Fail {Set-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'partial' -EstimatedHours 1.001} 'decimal'
    $read=@(Get-TaskPilotTask $script:s -TaskId $task.task_id)[0]
    Assert ($read.title-eq'before' -and $read.row_version-eq$task.row_version -and $read.estimated_hours_x100-eq200) 'Partial aggregate was committed'
}
Test-Case 'Task expected version rejects stale edits from another connection' {
    $task=Add-TaskPilotTask $script:s -Title 'concurrency'
    $other=Open-TaskPilotStore $script:dbPath @script:providerArgs
    try{
        $fresh=Set-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'winner'
        Must-Fail {Set-TaskPilotTask $other -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'stale'} 'Concurrency'
        Assert (@(Get-TaskPilotTask $other -TaskId $task.task_id)[0].title-eq'winner') 'Stale writer overwrote data'
    }finally{Close-TaskPilotStore $other}
}
Test-Case 'Caller transaction rolls back all successful nested operations' {
    Must-Fail {Invoke-TaskPilotTransaction $script:s {param($db);$null=Add-TaskPilotTask $db -Title 'temporary';throw 'injected failure'}} 'injected'
    Assert (@(Get-TaskPilotTask $script:s).Count-eq0) 'Task escaped rollback'
}
Test-Case 'Caught nested storage failure still prevents commit' {
    Must-Fail {Invoke-TaskPilotTransaction $script:s {param($db);$null=Add-TaskPilotTask $db -Title 'temporary';try{$null=Add-TaskPilotTask $db -Title 'broken' -DueOn 'bad'}catch{}}} 'rollback-only'
    Assert (@(Get-TaskPilotTask $script:s).Count-eq0) 'Rollback-only transaction committed'
}
Test-Case 'Subtask mutation increments parent and checks ownership' {
    $parent=Add-TaskPilotTask $script:s -Title 'parent';$other=Add-TaskPilotTask $script:s -Title 'other'
    $added=Add-TaskPilotSubtask $script:s -TaskId $parent.task_id -ExpectedVersion $parent.row_version -Title 'child'
    Assert ($added.Task.row_version-gt$parent.row_version) 'Child mutation did not update parent version'
    Must-Fail {Set-TaskPilotSubtask $script:s -TaskId $other.task_id -ExpectedVersion $other.row_version -SubtaskId $added.Subtask.subtask_id -Title 'hijack' -Done $true} 'belong'
    $updated=Set-TaskPilotSubtask $script:s -TaskId $parent.task_id -ExpectedVersion $added.Task.row_version -SubtaskId $added.Subtask.subtask_id -Title 'done' -Done $true
    Assert ($updated.Subtask.is_done-eq1) 'Subtask not saved'
}
Test-Case 'Soft deletion retains children and restoration keeps identity' {
    $task=Add-TaskPilotTask $script:s -Title 'restore';$child=Add-TaskPilotSubtask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'retained'
    $deleted=Remove-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $child.Task.row_version
    Assert (@(Get-TaskPilotTask $script:s).Count-eq0 -and @(Get-TaskPilotSubtask $script:s -TaskId $task.task_id).Count-eq1) 'Deletion removed child history'
    $restored=Restore-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $deleted.row_version
    Assert ($restored.task_id-eq$task.task_id -and $restored.is_deleted-eq0) 'Identity not restored'
}
Test-Case 'Work log and completion actual are separate measures' {
    $task=Add-TaskPilotTask $script:s -Title 'work'
    $log=Add-TaskPilotWorkLog $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -WorkDate '2026-11-15' -Hours 1.26 -Memo 'daily'
    $done=Complete-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $log.Task.row_version -ActualHours 2.01 -CompletedOn '2026-11-15'
    Assert ($done.Task.status-eq'完了' -and $done.Actual.actual_hours_x100-eq201) 'Completion report missing'
    Assert (@(Get-TaskPilotWorkLog $script:s -TaskId $task.task_id)[0].hours_x100-eq126) 'Daily log changed during completion'
}
Test-Case 'Completion status rolls back when actual report fails' {
    $task=Add-TaskPilotTask $script:s -Title 'atomic completion'
    Must-Fail {Complete-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -ActualHours 0.001} 'decimal'
    $read=@(Get-TaskPilotTask $script:s -TaskId $task.task_id)[0]
    Assert ($read.status-eq'未着手' -and $read.row_version-eq$task.row_version) 'Status escaped rollback'
}
Test-Case 'Read-only handle allows reads and rejects all writes' {
    $task=Add-TaskPilotTask $script:s -Title 'read-only'
    $reader=Open-TaskPilotStore $script:dbPath -ReadOnly @script:providerArgs
    try{
        Assert (@(Get-TaskPilotTask $reader).Count-eq1) 'Read-only read failed'
        Must-Fail {Add-TaskPilotTask $reader -Title 'blocked'} 'read-only'
        $snapshot=Get-TaskPilotReadSnapshot $reader
        Assert ($snapshot.Data.tasks.Count-eq1) 'Snapshot missing data'
    }finally{Close-TaskPilotStore $reader}
}
Test-Case 'Archive membership is independent of completed status' {
    $task=Add-TaskPilotTask $script:s -Title 'archive' -Status '完了'
    Assert (@(Get-TaskPilotTask $script:s).Count-eq1) 'Completion silently archived task'
    $saved=Set-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Archived $true
    Assert (@(Get-TaskPilotTask $script:s).Count-eq0 -and @(Get-TaskPilotTask $script:s -IncludeArchived).Count-eq1) 'Archive query failed'
}
Test-Case 'Boolean flags reject strings rather than treating false text as true' {
    $task=Add-TaskPilotTask $script:s -Title 'booleans'
    Must-Fail {Set-TaskPilotTask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Archived 'false'} 'Boolean'
    $child=Add-TaskPilotSubtask $script:s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'bool child'
    Must-Fail {Set-TaskPilotSubtask $script:s -TaskId $task.task_id -ExpectedVersion $child.Task.row_version -SubtaskId $child.Subtask.subtask_id -Title 'bad' -Done 'false'} 'Boolean'
}
Test-Case 'File is closed and can be renamed after store disposal' {
    Close-TaskPilotStore $script:s
    $renamed=$script:dbPath+'.renamed';[IO.File]::Move($script:dbPath,$renamed)
    Assert (Test-Path -LiteralPath $renamed) 'SQLite handle remained open'
}

Test-Case 'Unknown app header is rejected before native recovery or writes' {
    $cmd=$script:s.Connection.CreateCommand()
    try{$cmd.CommandText='PRAGMA application_id=0';$null=$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}
    Close-TaskPilotStore $script:s
    $before=(Get-FileHash -LiteralPath $script:dbPath -Algorithm SHA256).Hash
    Must-Fail {Open-TaskPilotStore $script:dbPath @script:providerArgs} 'different app'
    Assert ((Get-FileHash -LiteralPath $script:dbPath -Algorithm SHA256).Hash-eq$before) 'Foreign database was modified'
}
Test-Case 'Incompatible schema header is rejected without upgrading' {
    $cmd=$script:s.Connection.CreateCommand()
    try{$cmd.CommandText='PRAGMA user_version=40002';$null=$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}
    Close-TaskPilotStore $script:s
    $before=(Get-FileHash -LiteralPath $script:dbPath -Algorithm SHA256).Hash
    Must-Fail {Open-TaskPilotStore $script:dbPath @script:providerArgs} 'different app'
    Assert ((Get-FileHash -LiteralPath $script:dbPath -Algorithm SHA256).Hash-eq$before) 'Unknown schema was changed'
}

Test-Case 'Committed data survives closing and reopening the connection' {
    $task=Add-TaskPilotTask $script:s -Title 'persisted 日本語' -EstimatedHours 3.01
    Close-TaskPilotStore $script:s
    $script:s=Open-TaskPilotStore $script:dbPath @script:providerArgs
    $saved=@(Get-TaskPilotTask $script:s -TaskId $task.task_id)[0]
    Assert (($saved.title-ceq'persisted 日本語' -and $saved.estimated_hours_x100-eq301)) 'Committed values were not persisted'
}
Test-Case 'Competing writer fails cleanly and can save after lock release' {
    $other=Open-TaskPilotStore $script:dbPath @script:providerArgs
    try{
        Invoke-TaskPilotTransaction $script:s {
            param($writer)
            $null=Add-TaskPilotTask $writer -Title 'locked winner'
            Must-Fail {Add-TaskPilotTask $other -Title 'must not persist'} 'locked|busy'
        }
        Assert (@(Get-TaskPilotTask $other).Count-eq1) 'Failed competitor left a partial task'
        $null=Add-TaskPilotTask $other -Title 'after lock release'
        Assert (@(Get-TaskPilotTask $script:s).Count-eq2) 'Connection did not recover after contention'
    }finally{Close-TaskPilotStore $other}
}
