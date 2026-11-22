#requires -Version 5.1
# Reproducible integration of the recorded local STEP3 reference. Never modifies the reference.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$reference=Join-Path $project 'reference/TaskPilot_STEP3_6F_4.ps1'
if((Get-FileHash -LiteralPath $reference).Hash.ToLowerInvariant()-cne'ab0c5e2dbc31128563298d70adf51c59d3e081643899575aaba1d0183d47188d'){throw 'Unknown reference revision. Review it before integrating.'}
$text=[IO.File]::ReadAllText($reference).Replace("`r`n","`n")
$overrides=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($name in @('Initialize-TaskPilotStorage','Initialize-Store','Test-BackupFolder','Invoke-RestoreSnapshot')){$null=$overrides.Add($name)}
foreach($file in Get-ChildItem -LiteralPath (Join-Path $project 'Adapters') -Filter '*.ps1'){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Adapter parse error: '+$file.Name)}
    foreach($function in $ast.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){$null=$overrides.Add($function.Name)}
}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
$definitions=@($ast.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object {$overrides.Contains($_.Name)}|Sort-Object {$_.Extent.StartOffset} -Descending)
foreach($function in $definitions){$text=$text.Remove($function.Extent.StartOffset,$function.Extent.EndOffset-$function.Extent.StartOffset)}
$parameterBlock=@'
[CmdletBinding(PositionalBinding=$false)]
param([switch]$TestMode,[string]$TestEnvironmentId)

'@
$text=$text.Replace("`$ErrorActionPreference = 'Stop'",$parameterBlock+"`n`$ErrorActionPreference = 'Stop'")
$oldPaths=@'
$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw 'LOCALAPPDATA を取得できません。' }
$Root = Join-Path $LocalAppData 'TaskPilot'
'@
$newPaths=@'
# Select the mode before assigning any normal user-state/log path. An invalid
# test request never falls back to normal startup or normal error logging.
if ($PSBoundParameters.ContainsKey('TestMode') -and -not $TestMode) { throw 'TestMode:false は受け付けません。通常起動は引数なしで実行してください。' }
if ($TestMode -and $TestEnvironmentId -cnotmatch '^[a-f0-9]{32}$') { throw 'TestMode には32桁の小文字16進数のTestEnvironmentIdが必要です。通常データは開いていません。' }
if (-not $TestMode -and -not [string]::IsNullOrEmpty($TestEnvironmentId)) { throw 'TestEnvironmentId はTestModeと一緒に指定してください。通常データは開いていません。' }
. (Join-Path $InstallRoot 'Runtime/TaskPilot.Runtime.ps1')
$script:TPRuntimeContext = Initialize-TPRuntime -TestMode:$TestMode -TestEnvironmentId $TestEnvironmentId
$LocalAppData = $script:TPRuntimeContext.ProfileRoot
$LegacyRoot = if ($script:TPRuntimeContext.IsTestMode) { $null } else { Join-Path $LocalAppData 'TaskPilot' }
$Root = $script:TPRuntimeContext.Root
'@
if(-not$text.Contains($oldPaths)){throw 'Initial user-state configuration was not found.'}
$text=$text.Replace($oldPaths,$newPaths)
$text=$text.Replace("`$DataDir = Join-Path `$Root 'Data'","`$DataDir = `$script:TPRuntimeContext.DataDir")
$text=$text.Replace("`$ExportDir = Join-Path `$Root 'Export'","`$ExportDir = `$script:TPRuntimeContext.ExportDir")
$text=$text.Replace("`$BackupDir = Join-Path `$Root 'Backup'","`$BackupDir = `$script:TPRuntimeContext.BackupDir")
$text=$text.Replace("`$LogDir = Join-Path `$Root 'Logs'","`$LogDir = `$script:TPRuntimeContext.LogDir")
$bootstrap=@'
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiIsolation.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiCommon.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiTasks.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiDomains.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiOperations.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiStartup.ps1')
    Initialize-TPGuiApplication
'@
$text=$text.Replace('[System.Windows.Forms.Application]::EnableVisualStyles()',$bootstrap)
$start=$text.LastIndexOf('$script:StorageLock = $null',[StringComparison]::Ordinal)
if($start-lt0){throw 'Startup boundary not found.'}
$text=$text.Substring(0,$start)+@'
    Set-TPGuiTestModeVisuals -Form $form
    Repair-NextTaskId
    Load-AppSettings
    Load-NotificationData
    Invoke-MonthlyAutoFinalize
    $script:AutoReportsReady = $true
    $generatedCount = Invoke-RecurringGeneration
    Update-AutoReports
    Refresh-List
    if ($generatedCount -gt 0) { [System.Windows.Forms.MessageBox]::Show($form,"定期タスクを $generatedCount 件追加しました。",'定期タスク') | Out-Null }
    $form.Add_Shown({
        if ([bool]$script:AppSettings.NotifyOnStartup) { try { Show-TaskPilotAlertPopup } catch { Show-Failure $_ } }
        $script:NotificationTimer.Start()
        try { Invoke-DailyNotificationCheck } catch { if(Test-TPGuiIsolatedMode){Show-Failure $_}else{Write-ErrorLog $_} }
    })
    [void][System.Windows.Forms.Application]::Run($form)
} catch {
    if(Get-Command Show-Failure -ErrorAction SilentlyContinue){Show-Failure $_}
    else{Write-ErrorLog $_;[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'TaskPilot 起動エラー',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null}
} finally {
    try { if(Get-Command Close-TPGuiApplication -ErrorAction SilentlyContinue){Close-TPGuiApplication} }
    finally { if(Get-Command Close-TPRuntime -ErrorAction SilentlyContinue){Close-TPRuntime} }
}
'@
$pattern='(?m)^(?<indent>[ \t]*)\$items = @\(Read-Tasks \$TaskFile\)\n[ \t]*\$id = Reserve-TaskId\n[\s\S]*?Save-WorkPlanFromDialog \(\[string\]\$id\) \$value[^\n]*'
$matches=[regex]::Matches($text,$pattern)
if($matches.Count-ne3){throw ('Expected three GUI creation paths, got '+$matches.Count)}
$text=[regex]::Replace($text,$pattern,('${indent}$id = Add-TPGuiTaskFromDialog $value'))
$delete=@'
        $items = @(Read-Tasks $TaskFile | Where-Object { [string]$_.ID -ne [string]$task.ID })
        Backup-Data
        Save-Tasks $TaskFile $items
        Write-ActionLog '削除' ("ID=$($task.ID)")
'@
if(-not$text.Contains($delete)){throw 'Delete callsite not found.'}
$text=$text.Replace($delete,'        Remove-TPGuiSelectedTask $task')
$text=$text.Replace('Save-CompanyClosures @($dates + @($date))','Add-CompanyClosure $date')
$text=$text.Replace('Save-CompanyClosures @((Read-CompanyClosures) | Where-Object { $_ -ne $selected })','Remove-CompanyClosure $selected')
$text=$text.Replace('try { Invoke-DailyNotificationCheck } catch { Write-ErrorLog $_; $script:NotificationTimer.Stop() }','try { Invoke-DailyNotificationCheck } catch { try { if(Test-TPGuiIsolatedMode){Show-Failure $_}else{Write-ErrorLog $_} } finally { $script:NotificationTimer.Stop() } }')
$oldHolidayPicker=@'
            $choose = New-Object System.Windows.Forms.OpenFileDialog
            $choose.Filter = 'CSVファイル (*.csv)|*.csv'
            if ($choose.ShowDialog($dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $count = Import-JapaneseHolidayCsv $choose.FileName
'@
$newHolidayPicker=@'
            if (Test-TPGuiIsolatedMode) {
                $selectedCsv = Select-TPGuiIsolatedFile -Directory (Get-TPGuiSandbox).Input -Extension '.csv'
                if ([string]::IsNullOrEmpty($selectedCsv)) { return }
            } else {
                $choose = New-Object System.Windows.Forms.OpenFileDialog
                $choose.Filter = 'CSVファイル (*.csv)|*.csv'
                try { if ($choose.ShowDialog($dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }; $selectedCsv = $choose.FileName }
                finally { $choose.Dispose() }
            }
            $count = Import-JapaneseHolidayCsv $selectedCsv
'@
if(-not$text.Contains($oldHolidayPicker)){throw 'Holiday CSV selection path was not found.'}
$text=$text.Replace($oldHolidayPicker,$newHolidayPicker)
$text=$text.Replace("`$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('TaskPilotHoliday_' + [guid]::NewGuid().ToString('N') + '.csv')",'`$tmp = Get-TPGuiHolidayTemporaryPath'.Replace('`$','$'))
$text=$text.Replace('try { $wc.DownloadFile($OfficialHolidayUrl,$tmp) } finally { $wc.Dispose() }','try { $holidayBytes = $wc.DownloadData($OfficialHolidayUrl); Save-TPGuiDownloadedHolidayCsv -Path $tmp -Bytes $holidayBytes } finally { $wc.Dispose() }')
$text=$text.Replace('finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }','finally { Remove-TPGuiHolidayTemporaryFile -Path $tmp }')
$text=$text.Replace('if (Test-Path -LiteralPath $HolidayFile) {','if ($null -ne (Read-HolidaysDocument)) {')
$text=$text.Replace('$holidayObj = Get-Content -LiteralPath $HolidayFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop','$holidayObj = Read-HolidaysDocument')
$text=$text.Replace('if (Test-Path -LiteralPath $script:MonthlyAuditFile) {','if ($true) {')
$text=$text.Replace('$audit=@(Get-Content -LiteralPath $script:MonthlyAuditFile -Raw -Encoding UTF8 | ConvertFrom-Json)','$audit=@(Read-MonthlyAudit)')
$text=$text.Replace('$map[$key]=$new; Write-MonthlySnapshots $map',"`$map[`$key]=`$new; try { Write-MonthlySnapshots `$map -ChangedMonth `$key -ExpectedRevision ([long]`$old.Revision) -Reason '手動修正' } catch { `$map[`$key]=`$old; throw }")
$text=$text.Replace("`$new['Revision']=[int]`$old.Revision+1","`$new['Revision']=[long]`$old.Revision+1")
$text=$text.Replace("            Add-MonthlyAudit `$key '手動修正' (`$before | ConvertFrom-Json) `$new",'')
$text=$text.Replace('foreach($field in $fields) {'+"`n"+'                $number=0.0',('foreach($field in $fields) {'+"`n"+"                if (`$field -eq 'PlannedRate' -and [string]::IsNullOrWhiteSpace(`$boxes[`$field].Text)) { `$values[`$field]=`$null; continue }`n"+'                $number=0.0'))
$rate=@'
        $rate=0.0
        if ($cap.Hours -gt 0) { $rate=100.0*$planned/$cap.Hours }
'@
$newRate=@'
        $rate=$null
        if ($null -ne $savedSnapshot) { $rate=$savedSnapshot.PlannedRate }
        elseif ($cap.Hours -gt 0) { $rate=100.0*$planned/$cap.Hours }
        $rateText=if($null -eq $rate){'算出なし'}else{([math]::Round([double]$rate,1)).ToString()+' %'}
'@
$text=$text.Replace($rate,$newRate).Replace('月間予定稼働率： $([math]::Round($rate,1)) %','月間予定稼働率： $rateText')
# An integer 0 selects Math.Max(Int32,Int32) in PowerShell and loses fractional hours.
$text=$text.Replace('[math]::Max(0,','[math]::Max(0.0,')
$text=$text.Replace('[math]::Round($rate)))','[math]::Round([double]$rate)))')
$text=$text.Replace("$([char]36)form.Text = 'TaskPilot - 0.9.20.5（販売準備レビュー版）'","`$form.Text = 'TaskPilot - SQLite統合 開発候補版'")
# Calendar boundaries must not inherit the time at which Get-Date is called.
$calendarAst=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
$calendarCommands=@($calendarAst.FindAll({param($n) $n-is[Management.Automation.Language.CommandAst] -and $n.GetCommandName()-eq'Get-Date' -and $n.Extent.Text-match'-Year ' -and $n.Extent.Text-match'-Month ' -and $n.Extent.Text-match'-Day '},$true)|Sort-Object {$_.Extent.StartOffset} -Descending)
foreach($command in $calendarCommands){$text=$text.Remove($command.Extent.StartOffset,$command.Extent.EndOffset-$command.Extent.StartOffset).Insert($command.Extent.StartOffset,('('+$command.Extent.Text+').Date'))}
# Append concurrency tokens to commands using AST offsets, including inline event handlers.
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$commands=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.CommandAst] -and $n.GetCommandName()-in@('Save-Subtasks','Save-WorkLogs','Save-ActualHours','Save-RecurringRules')},$true)|Sort-Object {$_.Extent.StartOffset} -Descending)
foreach($command in $commands){
    $addition=switch($command.GetCommandName()){
        'Save-Subtasks'{" -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')"}
        'Save-WorkLogs'{" -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'work_logs')"}
        'Save-ActualHours'{' -ExpectedVersion ([long]$task.TPRowVersion)'}
        'Save-RecurringRules'{' -OriginalRules @($rules.ToArray())'}
    }
    $text=$text.Insert($command.Extent.EndOffset,$addition)
}
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
[IO.File]::WriteAllText((Join-Path $project 'TaskPilot.ps1'),$text.Replace("`n","`r`n"),[Text.UTF8Encoding]::new($true))
Write-Output ([pscustomobject]@{RemovedLegacyFunctions=$definitions.Count;GuiCreationPaths=$matches.Count;TokenCallsites=$commands.Count;Syntax='Passed';WindowsGUI='未検証'})
