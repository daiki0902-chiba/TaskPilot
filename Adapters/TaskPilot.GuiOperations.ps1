#requires -Version 5.1
function Save-EditedTask($target,$value){
    Backup-Data
    $id=Save-TPGuiTaskAggregate -Target $target -Value $value
    Write-ActionLog '編集' ('ID='+$id)
    if($script:AutoReportsReady){Update-AutoReports}
    Refresh-List
}
function Add-TPGuiTaskFromDialog($Value){
    Backup-Data
    $id=Save-TPGuiTaskAggregate -Target $null -Value $Value
    if($script:AutoReportsReady){Update-AutoReports}
    return $id
}
function Remove-TPGuiSelectedTask($Task){
    Backup-Data
    Remove-TaskPilotTask -Store $script:TPGuiStore -TaskId ([long]$Task.ID) -ExpectedVersion ([long]$Task.TPRowVersion)|Out-Null
    Set-TPGuiReportDirty
    Write-ActionLog '削除' ('ID='+$Task.ID)
    if($script:AutoReportsReady){Update-AutoReports}
}
function Update-AutoReports {
    # Each report reads the same committed SQLite snapshot. Task writes completed earlier.
    if($null-ne$script:TPGuiStore.Transaction){throw '業務データの保存が終わってからExcelを更新してください。'}
    $script:ReportsNeedRefresh=$true;$script:ReportError=''
    $transaction=$null
    try{
        $modulePath=Join-Path $InstallRoot 'Modules/ImportExcel/ImportExcel.psd1'
        if(-not[IO.File]::Exists($modulePath)){throw '同梱のExcel出力モジュールがありません。配布パッケージを確認してください。タスクの保存は確定済みです。'}
        Import-Module -Name $modulePath -ErrorAction Stop
        $dataVersion=[long](Invoke-TPGuiSql 'PRAGMA data_version' -Mode Scalar)
        $transaction=$script:TPGuiStore.Connection.BeginTransaction([Data.IsolationLevel]::ReadCommitted)
        $script:TPGuiStore.Transaction=$transaction;$script:TPGuiStore.TransactionReadOnly=$true
        Publish-ExcelReport 'TaskList.xlsx' {param($p) Write-ExcelReport $false $p}
        Publish-ExcelReport 'CompletedTask.xlsx' {param($p) Write-CompletedReport $p}
        Publish-ExcelReport 'Dashboard.xlsx' {param($p) Write-ExcelReport $true $p}
        $transaction.Commit();$transaction.Dispose();$transaction=$null
        $script:TPGuiStore.Transaction=$null;$script:TPGuiStore.TransactionReadOnly=$false
        # Begin a short write unit before comparing the external-connection data version.
        $unchanged=Invoke-TPGuiTransaction {
            if([long](Invoke-TPGuiSql 'PRAGMA data_version' -Mode Scalar)-ne$dataVersion){return $false}
            $null=Invoke-TPGuiSql 'UPDATE report_state SET is_dirty=0,last_generated_at_utc=@now,last_error=NULL WHERE singleton_id=1' -Parameters @{now=[datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')} -Mode NonQuery
            return $true
        }
        $script:ReportsNeedRefresh=-not[bool]$unchanged
        if(-not$unchanged){$script:ReportError='Excel生成中にデータが更新されました。もう一度Excelを再出力してください。'}
        Write-ActionLog 'Excel自動更新' $(if($unchanged){'3ファイル更新完了'}else{'再出力待ち'})
    }catch{
        if($null-ne$transaction){try{$transaction.Rollback()}catch{};$transaction.Dispose();$transaction=$null}
        if($null-ne$script:TPGuiStore){$script:TPGuiStore.Transaction=$null;$script:TPGuiStore.TransactionReadOnly=$false;$script:TPGuiStore.TransactionFailed=$false}
        $script:ReportError=$_.Exception.Message
        Write-ErrorLog $_
        Write-ActionLog 'Excel自動更新失敗' $script:ReportError
    }
}
