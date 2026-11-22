#requires -Version 5.1
# Test-mode GUI I/O. Normal-mode branches retain the reviewed STEP3 behavior.
function Set-TPGuiTestModeVisuals {
    param([Parameter(Mandatory=$true)]$Form)
    if(-not(Test-TPGuiIsolatedMode)){return}
    $sandbox=Get-TPGuiSandbox
    if(-not$Form.Text.StartsWith('[TEST MODE]',[StringComparison]::Ordinal)){$Form.Text='[TEST MODE] '+$Form.Text}
    $strip=New-Object System.Windows.Forms.StatusStrip
    $strip.Name='TaskPilotTestModeStatus';$strip.Dock=[System.Windows.Forms.DockStyle]::Bottom
    $strip.BackColor=[Drawing.Color]::LightGoldenrodYellow;$strip.ForeColor=[Drawing.Color]::DarkRed
    $strip.SizingGrip=$false
    $label=New-Object System.Windows.Forms.ToolStripStatusLabel
    $label.Name='TaskPilotTestModeLabel'
    $label.Text='テスト環境：'+[string]$sandbox.EnvironmentId+' （通常版へ切替不可）'
    $label.ToolTipText='専用保存先：'+[string]$sandbox.Root
    $label.AutoToolTip=$false;$label.Spring=$true;$label.TextAlign=[Drawing.ContentAlignment]::MiddleLeft
    $null=$strip.Items.Add($label);$Form.Controls.Add($strip);$strip.BringToFront()
    $Form.AccessibleDescription='独立テストモード。通常版のデータは取り込まず、このテスト環境だけを使用します。'
}
function Write-ActionLog([string]$action,[string]$detail){
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $safeDetail=$detail-replace'[\r\n]+',' '
        $line='{0} | {1} | {2}'-f(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$action,$safeDetail
        $sandbox.AppendText((Join-Path ([string]$sandbox.Logs) 'actions.log'),$line+[Environment]::NewLine)
        return
    }
    try{
        if(-not(Test-Path -LiteralPath $LogDir)){New-Item -ItemType Directory -Path $LogDir -Force|Out-Null}
        $safeDetail=$detail-replace'[\r\n]+',' '
        Add-Content -LiteralPath (Join-Path $LogDir 'actions.log') -Value ('{0} | {1} | {2}'-f(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$action,$safeDetail) -Encoding UTF8
    }catch{}
}
function Write-ErrorLog($record){
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        if($sandbox.IsFaulted){throw 'テスト環境の保存境界が停止したため、ログの追加も停止しました。'}
        $sourceLine=if($null-ne$record.InvocationInfo){[string]$record.InvocationInfo.Line}else{''}
        $sourceNumber=if($null-ne$record.InvocationInfo){$record.InvocationInfo.ScriptLineNumber}else{0}
        $line='{0} | {1} | line {2} | {3}'-f(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$record.Exception.Message,$sourceNumber,$sourceLine.Trim()
        $sandbox.AppendText((Join-Path ([string]$sandbox.Logs) 'errors.log'),($line+[Environment]::NewLine+[string]$record.ScriptStackTrace+[Environment]::NewLine))
        return
    }
    try{
        if(-not(Test-Path -LiteralPath $LogDir)){New-Item -ItemType Directory -Path $LogDir -Force|Out-Null}
        $log=Join-Path $LogDir 'errors.log'
        $line='{0} | {1} | line {2} | {3}'-f(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$record.Exception.Message,$record.InvocationInfo.ScriptLineNumber,$record.InvocationInfo.Line.Trim()
        Add-Content -LiteralPath $log -Value ($line+[Environment]::NewLine+[string]$record.ScriptStackTrace) -Encoding UTF8
    }catch{Write-Host 'エラーログの保存に失敗しました。' -ForegroundColor Yellow}
}
function Show-Failure($record){
    if(Test-TPGuiIsolatedMode){
        $fatal=$false
        try{
            $sandbox=Get-TPGuiSandbox
            $fatal=[bool]$sandbox.IsFaulted
            if(-not$fatal){Write-ErrorLog $record}
        }catch{$fatal=$true}
        $message=[string]$record.Exception.Message
        if($fatal){$message+="`r`n`r`nテスト環境の保存処理を停止します。通常版へは切り替えません。"}
        [System.Windows.Forms.MessageBox]::Show($message,'[TEST MODE] テスト環境のエラー','OK','Error')|Out-Null
        if($fatal){
            $timer=Get-Variable -Name NotificationTimer -Scope Script -ErrorAction SilentlyContinue
            if($null-ne$timer-and$null-ne$timer.Value){try{$timer.Value.Stop()}catch{}}
            $window=Get-Variable -Name form -Scope Script -ErrorAction SilentlyContinue
            if($null-ne$window-and$null-ne$window.Value){$window.Value.Close()}
        }
        return
    }
    Write-ErrorLog $record
    [System.Windows.Forms.MessageBox]::Show($record.Exception.Message,'エラー','OK','Error')|Out-Null
}
function Replace-FileSafely([string]$source,[string]$destination){
    $backup=Join-Path (Split-Path -Parent $destination) ('.replace_backup_'+[guid]::NewGuid().ToString('N'))
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $sandbox.Replace($source,$destination,$backup)
        if($sandbox.Exists($backup)){$sandbox.DeleteFile($backup)}
        return
    }
    try{[IO.File]::Replace($source,$destination,$backup)}
    finally{if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}}
}
function Publish-ExcelReport([string]$name,[scriptblock]$writer){
    if($name-notin@('TaskList.xlsx','CompletedTask.xlsx','Dashboard.xlsx')){throw '未対応のExcelレポート名です。'}
    $target=Join-Path $ExportDir $name
    $temporary=Join-Path $ExportDir ('.report_'+[guid]::NewGuid().ToString('N')+'.xlsx')
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $null=$sandbox.AssertPath($target)
        $null=$sandbox.AssertPath($temporary)
        # Pin the fresh entry before EPPlus opens its pathname. Parent handles
        # and the no-delete file handle prevent directory/file substitution.
        $sandbox.ReserveFile($temporary)
        try{
            & $writer $temporary
            if($sandbox.GetFileLength($temporary)-eq0){throw "Excel出力ファイルが空です: $name"}
            if($sandbox.Exists($target)){Replace-FileSafely $temporary $target}
            else{$sandbox.MoveNew($temporary,$target)}
        }finally{
            if(-not$sandbox.IsFaulted-and$sandbox.Exists($temporary)){$sandbox.DeleteFile($temporary)}
        }
        return
    }
    try{
        & $writer $temporary
        if(-not(Test-Path -LiteralPath $temporary -PathType Leaf)){throw "Excel出力ファイルが作成されませんでした: $name"}
        if((Get-Item -LiteralPath $temporary).Length-eq0){throw "Excel出力ファイルが空です: $name"}
        if(Test-Path -LiteralPath $target){Replace-FileSafely $temporary $target}
        else{[IO.File]::Move($temporary,$target)}
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}
function Open-AutoReport([string]$name){
    if($name-notin@('TaskList.xlsx','CompletedTask.xlsx','Dashboard.xlsx')){throw '未対応のExcelレポート名です。'}
    $target=Join-Path $ExportDir $name
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $target=$sandbox.AssertPath($target)
        if($script:ReportsNeedRefresh-or-not$sandbox.Exists($target)){Update-AutoReports}
        if($script:ReportsNeedRefresh){
            [System.Windows.Forms.MessageBox]::Show("Excelの自動更新に失敗しました。`r`n$script:ReportError",'[TEST MODE] Excel出力エラー')|Out-Null
            return
        }
        if(-not$sandbox.Exists($target)){throw "ファイルがありません: $target"}
        [System.Windows.Forms.MessageBox]::Show("テスト用Excelを生成しました。`r`n$target`r`n`r`n独立テストモードから外部の閲覧アプリは自動起動しません。必要な場合は試験者がこのテスト出力を別途確認してください。",'[TEST MODE] テスト用Excel')|Out-Null
        return
    }
    if($script:ReportsNeedRefresh-or-not(Test-Path -LiteralPath $target)){Update-AutoReports}
    if($script:ReportsNeedRefresh){
        [System.Windows.Forms.MessageBox]::Show("Excelの自動更新に失敗しました。`r`n$script:ReportError`r`n`r`n古いファイルを誤って開かないよう、今回は開きません。`r`nExcelを閉じて再度お試しください。",'Excel出力エラー')|Out-Null
        return
    }
    if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ファイルがありません: $target"}
    Start-Process -FilePath $target -ErrorAction Stop
}
function Select-TPGuiIsolatedFile {
    param([Parameter(Mandatory=$true)][string]$Directory,[Parameter(Mandatory=$true)][ValidateSet('.db','.csv')][string]$Extension)
    $sandbox=Get-TPGuiSandbox
    $directoryFull=$sandbox.AssertPath($Directory)
    $expected=if($Extension-ceq'.db'){[string]$sandbox.Backup}else{[string]$sandbox.Input}
    if($directoryFull-ine$expected){throw 'テスト環境内の専用フォルダーだけを選択できます。'}
    $sandbox.ValidateTree()
    $files=@(([IO.DirectoryInfo]$directoryFull).GetFiles('*'+$Extension)|Sort-Object Name)
    foreach($file in $files){$sandbox.CheckExistingFile($file.FullName)}
    if($files.Count-eq0){
        [System.Windows.Forms.MessageBox]::Show("このテスト環境に選択できるファイルがありません。`r`n$directoryFull",'[TEST MODE] テスト用ファイル')|Out-Null
        return $null
    }
    $dialog=New-Object System.Windows.Forms.Form
    $dialog.Text='[TEST MODE] テスト環境内のファイルを選択'
    $dialog.Size=New-Object System.Drawing.Size(610,370)
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $label=New-Object System.Windows.Forms.Label;$label.Text="テスト環境内のみ: $directoryFull";$label.SetBounds(15,15,565,44);$dialog.Controls.Add($label)
    $list=New-Object System.Windows.Forms.ListBox;$list.SetBounds(15,65,565,210)
    foreach($file in $files){$null=$list.Items.Add($file.Name)}
    $dialog.Controls.Add($list)
    $ok=New-Object System.Windows.Forms.Button;$ok.Text='選択';$ok.SetBounds(370,287,100,32);$ok.DialogResult=[System.Windows.Forms.DialogResult]::OK;$dialog.Controls.Add($ok)
    $cancel=New-Object System.Windows.Forms.Button;$cancel.Text='キャンセル';$cancel.SetBounds(480,287,100,32);$cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$dialog.Controls.Add($cancel)
    $dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
    try{
        if($dialog.ShowDialog($form)-ne[System.Windows.Forms.DialogResult]::OK-or$null-eq$list.SelectedItem){return $null}
        $selected=$sandbox.AssertPath((Join-Path $directoryFull ([string]$list.SelectedItem)))
        $sandbox.CheckExistingFile($selected)
        return $selected
    }finally{$dialog.Dispose()}
}
function Get-TPGuiHolidayTemporaryPath {
    $parent=if(Test-TPGuiIsolatedMode){[string](Get-TPGuiSandbox).Temp}else{[IO.Path]::GetTempPath()}
    return Join-Path $parent ('TaskPilotHoliday_'+[guid]::NewGuid().ToString('N')+'.csv')
}
function Save-TPGuiDownloadedHolidayCsv {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][byte[]]$Bytes)
    if($Bytes.Length-lt20-or$Bytes.Length-gt2000000){throw '取得した祝日CSVのサイズが想定外です。'}
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $full=$sandbox.AssertPath($Path)
        if([IO.Path]::GetDirectoryName($full)-ine[IO.Path]::GetFullPath([string]$sandbox.Temp)){throw '祝日取得の一時ファイルはテスト用Tempだけに保存できます。'}
        $sandbox.WriteNew($full,$Bytes)
    }else{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    }
}
function Remove-TPGuiHolidayTemporaryFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $full=$sandbox.AssertPath($Path)
        if([IO.Path]::GetDirectoryName($full)-ine[IO.Path]::GetFullPath([string]$sandbox.Temp)){throw '祝日取得の一時ファイルはテスト用Tempだけで削除できます。'}
        if(-not$sandbox.IsFaulted-and$sandbox.Exists($full)){$sandbox.DeleteFile($full)}
    }elseif(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue}
}
