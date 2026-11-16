#requires -Version 5.1
<# Isolated review regressions. No legacy store is opened or changed. #>
[CmdletBinding()]
param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force
function Assert-Review([bool]$Condition,[string]$Message){if(-not$Condition){throw ('REVIEW ASSERTION: '+$Message)}}
function Expect-ReviewFailure([scriptblock]$Action,[string]$Message){$didFail=$false;try{$null=&$Action}catch{$didFail=$true};Assert-Review $didFail $Message}
$providerArgs=@{};if($TestProviderAssembly){$providerArgs.TestProviderAssembly=$TestProviderAssembly}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilot_CoreReview_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$db=Join-Path $fixture '日本語 ; review.db'
$stores=New-Object 'System.Collections.Generic.List[object]'
$script:unexpectedStore=$null
try {
    $created=New-TaskPilotDatabase -DatabasePath $db @providerArgs
    Assert-Review ($created.SchemaVersion-eq40001) 'Schema version'
    $hash=(Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash
    Expect-ReviewFailure {New-TaskPilotDatabase -DatabasePath $db @providerArgs} 'Existing DB must not be overwritten'
    Assert-Review ((Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash-eq$hash) 'Existing DB bytes unchanged'
    Assert-Review (@(Get-ChildItem -LiteralPath $fixture -Filter '.taskpilot4b_*').Count-eq0) 'No stage leak'
    $missing=Join-Path $fixture 'absent.db'
    Expect-ReviewFailure {Open-TaskPilotStore -DatabasePath $missing @providerArgs} 'Open never creates a missing DB'
    Assert-Review (-not(Test-Path -LiteralPath $missing)) 'Missing DB remains absent'
    $s=Open-TaskPilotStore -DatabasePath $db @providerArgs;$stores.Add($s)
    $other=Open-TaskPilotStore -DatabasePath $db @providerArgs;$stores.Add($other)
    $task=Add-TaskPilotTask -Store $s -Title '日本語 ; "quoted" @id' -Memo ('line1'+[Environment]::NewLine+'line2') -EstimatedHours 0.01
    Assert-Review ($task.estimated_hours_x100-eq1 -and $task.estimated_hours-eq[decimal]0.01) 'Exact hundredth-hour'
    Assert-Review ($task.title-ceq'日本語 ; "quoted" @id') 'Parameterized Unicode and punctuation'
    $stale=Get-TaskPilotTask -Store $other -TaskId $task.task_id
    $task=Set-TaskPilotTask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'committed'
    Expect-ReviewFailure {Set-TaskPilotTask -Store $other -TaskId $stale.task_id -ExpectedVersion $stale.row_version -Title 'stale' -EstimatedHours 9.99} 'Stale writer must fail'
    $now=Get-TaskPilotTask -Store $s -TaskId $task.task_id
    Assert-Review ($now.title-ceq'committed' -and $now.estimated_hours_x100-eq1 -and $now.row_version-eq$task.row_version) 'Stale write changes no task/plan/version'
    Expect-ReviewFailure {Complete-TaskPilotTask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version -ActualHours 0.001} 'Nested validation rolls back completion'
    $now=Get-TaskPilotTask -Store $s -TaskId $task.task_id
    Assert-Review ($now.status-ceq'未着手' -and $now.row_version-eq$task.row_version) 'Completion status and version roll back together'
    Assert-Review (@(Get-TaskPilotCompletionActual -Store $s -TaskId $task.task_id).Count-eq0) 'No partial completion actual'
    $child=Add-TaskPilotSubtask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version -Title 'child'
    $task=$child.Task
    Expect-ReviewFailure {Set-TaskPilotTask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version -Archived 'false'} 'Archived must reject string-to-bool coercion'
    Expect-ReviewFailure {Set-TaskPilotSubtask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version -SubtaskId $child.Subtask.subtask_id -Title 'child' -Done 'false'} 'Done must reject string-to-bool coercion'
    Assert-Review ((Get-TaskPilotTask -Store $s -TaskId $task.task_id).row_version-eq$task.row_version) 'Rejected Boolean input changes no parent version'
    $another=Add-TaskPilotTask -Store $s -Title 'other parent'
    Expect-ReviewFailure {Set-TaskPilotSubtask -Store $s -TaskId $another.task_id -ExpectedVersion $another.row_version -SubtaskId $child.Subtask.subtask_id -Title 'wrong parent' -Done $true} 'Subtask parent identity enforced'
    Assert-Review ((Get-TaskPilotTask -Store $s -TaskId $another.task_id).row_version-eq$another.row_version) 'Wrong-parent child write restores parent version'
    $childAgain=@(Get-TaskPilotSubtask -Store $s -TaskId $task.task_id)[0]
    Assert-Review ($childAgain.title-ceq'child' -and $childAgain.is_done-eq0) 'Wrong-parent child write preserves child'
    $before=@(Get-TaskPilotTask -Store $s).Count
    Expect-ReviewFailure {
        Invoke-TaskPilotTransaction -Store $s -Action {
            param($transactionStore)
            $null=Add-TaskPilotTask -Store $transactionStore -Title 'must roll back'
            try{$null=Add-TaskPilotTask -Store $transactionStore -Title 'invalid calendar' -CalendarId 999999}catch{}
        }
    } 'Caught nested SQL failure marks transaction rollback-only'
    Assert-Review (@(Get-TaskPilotTask -Store $s).Count-eq$before) 'Caught nested failure commits no partial task'
    Assert-Review ($null-eq$s.Transaction -and -not$s.TransactionFailed) 'Transaction state cleaned after rollback'
    $readOnly=Open-TaskPilotStore -DatabasePath $db -ReadOnly @providerArgs;$stores.Add($readOnly)
    Expect-ReviewFailure {Add-TaskPilotTask -Store $readOnly -Title 'must not write'} 'Read-only API blocks writes'
    $rawReadOnlyCommand=$readOnly.Connection.CreateCommand()
    try {
        $rawReadOnlyCommand.CommandText="INSERT INTO tasks(registered_on,title,priority,status) VALUES('2026-11-15','raw write blocked','中','未着手')"
        Expect-ReviewFailure {$rawReadOnlyCommand.ExecuteNonQuery()} 'Native connection itself is read-only'
    } finally {$rawReadOnlyCommand.Dispose()}
    $snapshot=Get-TaskPilotReadSnapshot -Store $readOnly
    Assert-Review ($snapshot.Data.tasks.Count-eq$before) 'Read-only snapshot works'
    Assert-Review ($null-eq$readOnly.Transaction -and -not$readOnly.TransactionReadOnly) 'Snapshot state cleaned'
    $task=Remove-TaskPilotTask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version
    Assert-Review (@(Get-TaskPilotTask -Store $s -TaskId $task.task_id).Count-eq0) 'Soft-deleted task hidden'
    Assert-Review (@(Get-TaskPilotSubtask -Store $s -TaskId $task.task_id).Count-eq1) 'Soft deletion retains subtask'
    $task=Restore-TaskPilotTask -Store $s -TaskId $task.task_id -ExpectedVersion $task.row_version
    Assert-Review (@(Get-TaskPilotTask -Store $s -TaskId $task.task_id).Count-eq1) 'Restore re-exposes task'
    foreach($suffix in @('-journal','-wal','-shm')){
        $sideDb=Join-Path $fixture ('sidecar'+$suffix+'.db');$side=$sideDb+$suffix
        [IO.File]::WriteAllText($side,'synthetic-recovery-marker')
        Expect-ReviewFailure {New-TaskPilotDatabase -DatabasePath $sideDb @providerArgs} 'Destination sidecars refused'
        Assert-Review ([IO.File]::ReadAllText($side)-ceq'synthetic-recovery-marker') 'Existing recovery file retained'
        Assert-Review (-not(Test-Path -LiteralPath $sideDb)) 'No DB published beside recovery file'
    }
    $link=Join-Path $fixture 'linked-directory'
    $linkCreated=$false
    try {$null=New-Item -ItemType SymbolicLink -Path $link -Target $fixture -ErrorAction Stop;$linkCreated=$true} catch { Write-Output 'SKIP: link creation requires unavailable platform privileges.' }
    if($linkCreated){
        Expect-ReviewFailure {New-TaskPilotDatabase -DatabasePath (Join-Path $link 'linked-new.db') @providerArgs} 'Linked ancestor blocked before creating a DB'
        Expect-ReviewFailure {Open-TaskPilotStore -DatabasePath (Join-Path $link '日本語 ; review.db') @providerArgs} 'Linked ancestor blocked before opening a DB'
        Assert-Review (-not(Test-Path -LiteralPath (Join-Path $fixture 'linked-new.db'))) 'Link refusal creates no destination DB'
        Remove-Item -LiteralPath $link -Force
    }
    Write-Output 'PASS: core creation, no overwrite, Unicode parameters, hour precision, stale writers, nested rollback-only, child ownership, read-only snapshots, soft-delete restoration and sidecar preservation.'
    # Test-provider mode must be explicit for every Open/New call, even after caching.
    if($TestProviderAssembly){
        Expect-ReviewFailure {$script:unexpectedStore=Open-TaskPilotStore -DatabasePath $db} 'Cached test provider must never be used implicitly'
        $copyAdapter=Join-Path $fixture 'Copied.Mono.Data.Sqlite.dll'
        Copy-Item -LiteralPath $TestProviderAssembly -Destination $copyAdapter
        Expect-ReviewFailure {$script:unexpectedStore=Open-TaskPilotStore -DatabasePath $db -TestProviderAssembly $copyAdapter} 'Cached adapter path cannot change within one process'
        Write-Output 'PASS: explicit test-provider mode required after cache initialization.'
    }
} finally {
    if($null-ne$script:unexpectedStore){try{Close-TaskPilotStore $script:unexpectedStore}catch{}}
    foreach($store in $stores){try{if(-not$store.Closed){Close-TaskPilotStore $store}}catch{}}
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
