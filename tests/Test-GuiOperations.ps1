#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
# Orchestration only: Excel generation, Windows Forms and Windows remain 未検証.
# This suite uses actual SQLite transactions with synthetic data and a stub exporter.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../Adapters/TaskPilot.GuiCommon.ps1')
. (Join-Path $PSScriptRoot '../Adapters/TaskPilot.GuiTasks.ps1')
. (Join-Path $PSScriptRoot '../Adapters/TaskPilot.GuiOperations.ps1')
$script:realReports=(Get-Command Update-AutoReports).ScriptBlock
$script:realTransaction=(Get-Command Invoke-TPGuiTransaction).ScriptBlock
$modulePath=Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
$null=Import-Module $modulePath -Force
$providerArgs=@{};if($TestProviderAssembly){$providerArgs.TestProviderAssembly=$TestProviderAssembly}
$root=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotGuiOperations_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$InstallRoot=Join-Path $root 'fake-package'
$fakeModule=Join-Path $InstallRoot 'Modules/ImportExcel'
$null=[IO.Directory]::CreateDirectory($fakeModule)
[IO.File]::WriteAllText((Join-Path $fakeModule 'FakeImportExcel.psm1'),'# Deliberately empty test exporter module.')
[IO.File]::WriteAllText((Join-Path $fakeModule 'ImportExcel.psd1'),"@{RootModule='FakeImportExcel.psm1';ModuleVersion='0.0.1';GUID='ea370ea1-1db0-4ba1-afc5-5495ddf35947'}")
$TaskFile='TaskList.csv';$ArchiveFile='CompletedTask.csv'
$script:AutoReportsReady=$true;$script:ReportsNeedRefresh=$true;$script:ReportError=''
$script:passed=0;$script:failed=0;$script:checks=0
function Assert-GuiOperation([bool]$Ok,[string]$Message){$script:checks++;if(-not$Ok){throw $Message}}
function Reject-GuiOperation([scriptblock]$Action,[string]$Message){$rejected=$false;try{$null=&$Action}catch{$rejected=$true};Assert-GuiOperation $rejected $Message}
function New-OperationValue([string]$Title){[pscustomobject]@{Task=$Title;Priority='中';Status='未着手';DueDate='';Memo='日本語';PlannedDate='2026/11/17';WorkStartDate='2026/11/16';EstimatedHours=[decimal]'0.01'}}
function Backup-Data {Assert-GuiOperation ($null-eq$script:TPGuiStore.Transaction) 'Backup must run before a write transaction.';$script:backups++}
function Write-ActionLog {param($Action,$Detail);$script:logs.Add([string]$Action)}
function Write-ErrorLog {param($Record);$script:errors.Add($Record.Exception.Message)}
function Refresh-List {$script:refreshes++}
function Write-ExcelReport {param($Dashboard,$Path);$script:exportTitles.Add([string](Invoke-TPGuiSql 'SELECT title FROM tasks WHERE task_id=1' -Mode Scalar))}
function Write-CompletedReport {param($Path);$script:exportTitles.Add([string](Invoke-TPGuiSql 'SELECT title FROM tasks WHERE task_id=1' -Mode Scalar))}
function Publish-ExcelReport {
    param($Name,$Writer)
    $script:publishes++
    Assert-GuiOperation ($null-ne$script:TPGuiStore.Transaction -and $script:TPGuiStore.TransactionReadOnly) 'Report output must run inside the read snapshot.'
    if($script:reportMode-eq'fail' -and $script:publishes-eq2){throw [IO.IOException]::new('Synthetic Excel sharing failure')}
    if($script:reportMode-eq'try-write'){
        Reject-GuiOperation {Invoke-TPGuiSql "UPDATE tasks SET title='Unexpected' WHERE task_id=1" -Mode NonQuery} 'Snapshot write must be rejected.'
        $script:readonlyChecks++
    }
    & $Writer (Join-Path $root $Name)
}
function Invoke-OperationCase([string]$Name,[scriptblock]$Action){
    $db=Join-Path $root ([guid]::NewGuid().ToString('N')+'.db')
    $null=New-TaskPilotDatabase -DatabasePath $db @providerArgs
    $store=Open-TaskPilotStore -DatabasePath $db @providerArgs
    Initialize-TPGuiContext -Store $store -ModulePath $modulePath
    $script:db=$db;$script:backups=0;$script:refreshes=0;$script:publishes=0;$script:readonlyChecks=0
    $script:logs=New-Object 'Collections.Generic.List[string]';$script:errors=New-Object 'Collections.Generic.List[string]';$script:exportTitles=New-Object 'Collections.Generic.List[string]'
    $script:reportMode='normal';$script:ReportsNeedRefresh=$true;$script:ReportError=''
    Set-Item Function:Update-AutoReports $script:realReports
    Set-Item Function:Invoke-TPGuiTransaction $script:realTransaction
    try{$null=Save-TPGuiTaskAggregate $null (New-OperationValue 'Before');&$Action;$script:passed++;Write-Output ('PASS: '+$Name)}
    catch{$script:failed++;Write-Output ('FAIL: '+$Name+' : '+$_.Exception.Message);Write-Output $_.ScriptStackTrace}
    finally{
        Set-Item Function:Update-AutoReports $script:realReports
        Set-Item Function:Invoke-TPGuiTransaction $script:realTransaction
        if($null-ne$store.Transaction){try{$store.Transaction.Rollback()}catch{};$store.Transaction.Dispose();$store.Transaction=$null;$store.TransactionReadOnly=$false}
        Close-TaskPilotStore $store
    }
}
try{
    Invoke-OperationCase 'Edit commits task and plans before report/UI callbacks' {
        function Update-AutoReports {
            Assert-GuiOperation ($null-eq$script:TPGuiStore.Transaction) 'Report began inside task transaction.'
            Assert-GuiOperation ([string](Invoke-TPGuiSql 'SELECT title FROM tasks WHERE task_id=1' -Mode Scalar)-ceq'Changed') 'Report observed an old task title.'
            Assert-GuiOperation ([long](Invoke-TPGuiSql 'SELECT estimated_hours_x100 FROM task_plans WHERE task_id=1' -Mode Scalar)-eq123) 'Report observed incomplete plan metadata.'
            $script:reports++
        }
        $script:reports=0;$target=@(Read-Tasks $TaskFile)[0];$value=New-OperationValue 'Changed';$value.EstimatedHours=[decimal]'1.23'
        Save-EditedTask $target $value
        Assert-GuiOperation ($script:reports-eq1 -and $script:backups-eq1 -and $script:refreshes-eq1) 'Edit orchestration callbacks did not run exactly once.'
        Assert-GuiOperation (@(Read-Tasks $TaskFile)[0].TPRowVersion-eq2) 'Successful edit did not advance the version.'
    }
    Invoke-OperationCase 'Export failure preserves committed task and cleans the read transaction' {
        $target=@(Read-Tasks $TaskFile)[0];$script:reportMode='fail'
        Save-EditedTask $target (New-OperationValue 'Saved despite export failure')
        Assert-GuiOperation ([string](Invoke-TPGuiSql 'SELECT title FROM tasks WHERE task_id=1' -Mode Scalar)-ceq'Saved despite export failure') 'Report failure rolled back a committed task.'
        Assert-GuiOperation ($null-eq$script:TPGuiStore.Transaction -and -not$script:TPGuiStore.TransactionReadOnly) 'Report failure leaked a transaction.'
        Assert-GuiOperation ($script:ReportsNeedRefresh -and $script:ReportError-like'*Synthetic Excel*' -and $script:errors.Count-eq1) 'Report failure did not remain visible for retry.'
        Assert-GuiOperation ([long](Invoke-TPGuiSql 'SELECT is_dirty FROM report_state WHERE singleton_id=1' -Mode Scalar)-eq1) 'Failed report incorrectly cleared the dirty flag.'
        $script:reportMode='normal';$script:publishes=0;Update-AutoReports
        Assert-GuiOperation (-not$script:ReportsNeedRefresh -and $script:publishes-eq3) 'A later clean export could not recover.'
    }
    Invoke-OperationCase 'Ambient write transaction is rejected without being cleared' {
        $null=Invoke-TPGuiTransaction {
            $original=$script:TPGuiStore.Transaction
            Reject-GuiOperation {Update-AutoReports} 'Export inside an active unit must throw.'
            Assert-GuiOperation ([object]::ReferenceEquals($original,$script:TPGuiStore.Transaction)) 'Report guard cleared the caller transaction.'
            $null=Invoke-TPGuiSql "UPDATE tasks SET title='Caller still owns transaction' WHERE task_id=1" -Mode NonQuery
        }
        Assert-GuiOperation ([string](Invoke-TPGuiSql 'SELECT title FROM tasks WHERE task_id=1' -Mode Scalar)-ceq'Caller still owns transaction') 'Caller could not commit after the report guard.'
        Assert-GuiOperation ($script:publishes-eq0) 'Ambient guard allowed an exporter to start.'
    }
    Invoke-OperationCase 'All report callbacks share a read-only snapshot and clean up on success' {
        $script:reportMode='try-write';Update-AutoReports
        Assert-GuiOperation ($script:readonlyChecks-eq3 -and $script:exportTitles.Count-eq3) 'Not every report used the read-only snapshot.'
        Assert-GuiOperation (@($script:exportTitles|Where-Object {$_-cne'Before'}).Count-eq0) 'Report snapshot unexpectedly changed.'
        Assert-GuiOperation (-not$script:ReportsNeedRefresh -and $null-eq$script:TPGuiStore.Transaction) 'Successful export did not clean up.'
        Assert-GuiOperation ([long](Invoke-TPGuiSql 'SELECT is_dirty FROM report_state WHERE singleton_id=1' -Mode Scalar)-eq0) 'Successful current reports remain dirty.'
    }
    Invoke-OperationCase 'External commit at snapshot release prevents a stale clean report flag' {
        # Emulate a writer queued during export and committed immediately after its
        # read lock is released, before the short report-status transaction starts.
        function Invoke-TPGuiTransaction {
            param([scriptblock]$Action)
            if($script:publishExternal){
                $script:publishExternal=$false
                $other=Open-TaskPilotStore -DatabasePath $script:db @providerArgs
                try{$current=Get-TaskPilotTask -Store $other -TaskId 1;$null=Set-TaskPilotTask -Store $other -TaskId 1 -ExpectedVersion $current.row_version -Title 'Concurrent after snapshot'}finally{Close-TaskPilotStore $other}
            }
            & $script:realTransaction -Action $Action
        }
        $script:publishExternal=$true;Update-AutoReports
        Assert-GuiOperation ($script:ReportsNeedRefresh -and $script:ReportError-like'*Excel*') 'A changed source must leave reports pending.'
        Assert-GuiOperation ([long](Invoke-TPGuiSql 'SELECT is_dirty FROM report_state WHERE singleton_id=1' -Mode Scalar)-eq1) 'External update was incorrectly marked clean.'
        Assert-GuiOperation ([string](Invoke-TPGuiSql 'SELECT title FROM tasks WHERE task_id=1' -Mode Scalar)-ceq'Concurrent after snapshot') 'External commit was lost.'
        Assert-GuiOperation (@($script:exportTitles|Where-Object {$_-cne'Before'}).Count-eq0) 'Synthetic exports should represent the previous snapshot.'
    }
    Write-Output ('Result: '+$script:passed+' GUI orchestration cases passed, '+$script:failed+' failed; '+$script:checks+' assertions. Excel/Windows 未検証.')
    if($script:failed){throw 'GUI orchestration tests failed.'}
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
