# TaskPilot STEP 3.5B - customer portable distribution (PowerShell 5.1+)
# Copyright and third-party module licenses must be reviewed before commercial release.
[CmdletBinding(PositionalBinding=$false)]
param([switch]$TestMode,[string]$TestEnvironmentId)

$ErrorActionPreference = 'Stop'
# TaskPilot STEP 3.1: keep application files separate from user data.
# This app is intended for one Windows user per data store.
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $InstallRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
} else {
    $InstallRoot = $PSScriptRoot
}
# Select the mode before assigning any normal user-state/log path. An invalid
# test request never falls back to normal startup or normal error logging.
if ($PSBoundParameters.ContainsKey('TestMode') -and -not $TestMode) { throw 'TestMode:false は受け付けません。通常起動は引数なしで実行してください。' }
if ($TestMode -and $TestEnvironmentId -cnotmatch '^[a-f0-9]{32}$') { throw 'TestMode には32桁の小文字16進数のTestEnvironmentIdが必要です。通常データは開いていません。' }
if (-not $TestMode -and $PSBoundParameters.ContainsKey('TestEnvironmentId')) { throw '空値を含むTestEnvironmentIdはTestModeと一緒に指定してください。通常データは開いていません。' }
. (Join-Path $InstallRoot 'Runtime/TaskPilot.Runtime.ps1')
$runtimeArguments=@{}
if($PSBoundParameters.ContainsKey('TestMode')){$runtimeArguments.TestMode=$TestMode}
if($PSBoundParameters.ContainsKey('TestEnvironmentId')){$runtimeArguments.TestEnvironmentId=$TestEnvironmentId}
$script:TPRuntimeContext = Initialize-TPRuntime @runtimeArguments
$LocalAppData = $script:TPRuntimeContext.ProfileRoot
$LegacyRoot = if ($script:TPRuntimeContext.IsTestMode) { $null } else { Join-Path $LocalAppData 'TaskPilot' }
$Root = $script:TPRuntimeContext.Root


$DataDir = $script:TPRuntimeContext.DataDir
$ExportDir = $script:TPRuntimeContext.ExportDir
$TaskFile = Join-Path $DataDir 'TaskList.csv'
$ArchiveFile = Join-Path $DataDir 'CompletedTask.csv'
$IdFile = Join-Path $DataDir 'NextId.txt'
$BackupDir = $script:TPRuntimeContext.BackupDir
$LogDir = $script:TPRuntimeContext.LogDir
$Columns = @('ID','Date','Task','Priority','DueDate','Status','Memo')
$SettingsFile = Join-Path $Root 'Settings.json'
$script:AppSettings = @{ NotifyOnStartup = $true; NotifyDays = 3; DailyNotifyEnabled = $false; DailyNotifyTime = "09:00" }


function Show-SettingsDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '設定'
    $dialog.Size = New-Object System.Drawing.Size(450,325)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = '起動時に期限アラートを表示'
    $check.SetBounds(22,22,350,30)
    $check.Checked = [bool]$script:AppSettings.NotifyOnStartup
    $dialog.Controls.Add($check)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = '期限間近とみなす日数（0～30）'
    $label.SetBounds(22,72,260,28)
    $dialog.Controls.Add($label)
    $days = New-Object System.Windows.Forms.NumericUpDown
    $days.SetBounds(295,70,80,28)
    $days.Minimum = 0; $days.Maximum = 30
    $days.Value = [decimal]$script:AppSettings.NotifyDays
    $dialog.Controls.Add($days)
    $ok = New-Object System.Windows.Forms.Button
    $dailyCheck = New-Object System.Windows.Forms.CheckBox
    $dailyCheck.Text = '指定時刻以降に毎日通知（アプリ起動中のみ）'
    $dailyCheck.SetBounds(22,123,395,30)
    $dailyCheck.Checked = [bool]$script:AppSettings.DailyNotifyEnabled
    $dialog.Controls.Add($dailyCheck)
    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = '通知時刻（HH:mm）'
    $timeLabel.SetBounds(22,170,210,28)
    $dialog.Controls.Add($timeLabel)
    $timeBox = New-Object System.Windows.Forms.MaskedTextBox('00:00')
    $timeBox.SetBounds(295,168,100,28)
    $timeBox.Text = [string]$script:AppSettings.DailyNotifyTime
    $dialog.Controls.Add($timeBox)
    $ok.Text = '保存'; $ok.SetBounds(185,230,90,32)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'キャンセル'; $cancel.SetBounds(285,230,100,32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok; $dialog.CancelButton = $cancel
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            if ($timeBox.Text -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
                [System.Windows.Forms.MessageBox]::Show($dialog,'通知時刻は 09:00 の形式で入力してください。') | Out-Null
                return
            }
            $script:AppSettings.DailyNotifyEnabled = $dailyCheck.Checked
            $script:AppSettings.DailyNotifyTime = $timeBox.Text
            $script:AppSettings.NotifyOnStartup = $check.Checked
            $script:AppSettings.NotifyDays = [int]$days.Value
            Save-AppSettings
            [System.Windows.Forms.MessageBox]::Show($form,'設定を保存しました。通知設定は次回起動時から確実に適用されます。') | Out-Null
        }
    } finally { $dialog.Dispose() }
}







function Get-ValidDueDate($task) {
    $due = [datetime]::MinValue
    if ([datetime]::TryParseExact([string]$task.DueDate, 'yyyy/MM/dd', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$due)) { return $due.Date }
    return $null
}
function Get-PriorityRank([string]$priority) {
    switch ($priority) { '高' { return 0 } '中' { return 1 } '低' { return 2 } default { return 3 } }
}





Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiIsolation.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiCommon.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiTasks.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiDomains.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiOperations.ps1')
. (Join-Path $InstallRoot 'Adapters/TaskPilot.GuiStartup.ps1')
    Initialize-TPGuiApplication


# STEP 3.3B: recurrence generation. Outlook sync and business-day calendars are not implemented.
$RecurringFile = Join-Path $DataDir 'RecurringRules.json'


# STEP 3.3B: generate the latest due occurrence only (not an unbounded backlog).
# Business-day rules are deliberately excluded until holiday/company-calendar support is available.
function Get-LatestRecurringDate($rule, [datetime]$today) {
    $start = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$rule.StartDate,'yyyy-MM-dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$start)) { throw "定期タスクの開始日が不正です: $($rule.Name)" }
    $start = $start.Date
    if ($start -gt $today) { return $null }
    $type = [string]$rule.Type
    if ($type -eq '毎日') { return $today }
    $weekdays = @{'日'=0;'月'=1;'火'=2;'水'=3;'木'=4;'金'=5;'土'=6}
    if ($type -eq '毎週') {
        if (-not $weekdays.ContainsKey([string]$rule.Weekday)) { throw '定期タスクの曜日が不正です。' }
        $offset = (([int]$today.DayOfWeek - [int]$weekdays[[string]$rule.Weekday]) + 7) % 7
        $candidate = $today.AddDays(-$offset)
        if ($candidate -ge $start) { return $candidate }
        return $null
    }
    for ($back=0; $back -le 1; $back++) {
        $month = ((Get-Date -Year $today.Year -Month $today.Month -Day 1).Date).AddMonths(-$back)
        $candidate = $null
        if ($type -eq '毎月（日付）') {
            $d = [int]$rule.Day
            if ($d -lt 1 -or $d -gt 31) { throw '定期タスクの日付指定が不正です。' }
            # 31日指定など、その日が存在しない月は月末に繰り上げる。
            $candidate = $month.AddDays([math]::Min($d,[datetime]::DaysInMonth($month.Year,$month.Month))-1)
        } elseif ($type -eq '毎月（第N曜日）') {
            if (-not $weekdays.ContainsKey([string]$rule.Weekday)) { throw '定期タスクの曜日が不正です。' }
            $nth = [int]$rule.Nth
            if ($nth -lt 1 -or $nth -gt 5) { throw '定期タスクの第N曜日指定が不正です。' }
            $delta = (([int]$weekdays[[string]$rule.Weekday] - [int]$month.DayOfWeek) + 7) % 7
            $candidate = $month.AddDays($delta + 7*($nth-1))
            if ($candidate.Month -ne $month.Month) { continue }
        } elseif ($type -eq '毎月（第N営業日）' -or $type -eq '毎月（最終営業日）') {
            $candidate = Get-BusinessOccurrence $rule $month
            if ($null -eq $candidate) { continue }
        } else { return $null }
        if ($candidate -le $today -and $candidate -ge $start) { return $candidate }
    }
    return $null
}



# STEP 3.3C-1: holiday data import and company closure management ONLY.
# Business-day recurrence calculation is intentionally NOT enabled in this build.
$HolidayFile = Join-Path $DataDir 'JapaneseHolidays.json'
$ClosureFile = Join-Path $DataDir 'CompanyClosures.json'
$OfficialHolidayUrl = 'https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv'



function Get-BusinessOccurrence($rule, [datetime]$month) {
    $holidays = Get-VerifiedHolidayCalendar $month.Year
    $closures = @{}
    foreach ($d in @(Read-CompanyClosures)) { $closures[[string]$d] = $true }
    $days = [System.Collections.Generic.List[datetime]]::new()
    $count = [datetime]::DaysInMonth($month.Year,$month.Month)
    for ($d=1; $d -le $count; $d++) {
        $date = (Get-Date -Year $month.Year -Month $month.Month -Day $d -Hour 0 -Minute 0 -Second 0).Date
        $key = $date.ToString('yyyy-MM-dd')
        if ($date.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)) { continue }
        if ($holidays.ContainsKey($key) -or $closures.ContainsKey($key)) { continue }
        $days.Add($date)
    }
    if ($days.Count -eq 0) { throw "${month}の営業日がありません。休業日設定を確認してください。" }
    if ([string]$rule.Type -eq '毎月（最終営業日）') { return $days[$days.Count-1] }
    $nth = [int]$rule.Nth
    if ($nth -lt 1 -or $nth -gt 31) { throw '第N営業日の指定が不正です。' }
    if ($nth -gt $days.Count) { return $null }
    return $days[$nth-1]
}
function Get-NextRecurringDate($rule, [datetime]$today) {
    $start = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$rule.StartDate,'yyyy-MM-dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$start)) { throw '定期タスクの開始日が不正です。' }
    $base = $today.Date
    if ($start -gt $base) { $base = $start.Date }
    $type = [string]$rule.Type
    if ($type -eq '毎日') { return $base }
    $weekdays = @{'日'=0;'月'=1;'火'=2;'水'=3;'木'=4;'金'=5;'土'=6}
    if ($type -eq '毎週') {
        if (-not $weekdays.ContainsKey([string]$rule.Weekday)) { throw '曜日指定が不正です。' }
        $offset = (([int]$weekdays[[string]$rule.Weekday] - [int]$base.DayOfWeek) + 7) % 7
        return $base.AddDays($offset)
    }
    for ($i=0; $i -lt 24; $i++) {
        $month = ((Get-Date -Year $base.Year -Month $base.Month -Day 1).Date).AddMonths($i)
        $candidate = $null
        if ($type -eq '毎月（日付）') {
            $day = [int]$rule.Day
            if ($day -lt 1 -or $day -gt 31) { throw '日付指定が不正です。' }
            $candidate = $month.AddDays([math]::Min($day,[datetime]::DaysInMonth($month.Year,$month.Month))-1)
        } elseif ($type -eq '毎月（第N曜日）') {
            if (-not $weekdays.ContainsKey([string]$rule.Weekday)) { throw '曜日指定が不正です。' }
            $nth = [int]$rule.Nth
            if ($nth -lt 1 -or $nth -gt 5) { throw '第N曜日指定が不正です。' }
            $delta = (([int]$weekdays[[string]$rule.Weekday] - [int]$month.DayOfWeek) + 7) % 7
            $candidate = $month.AddDays($delta+7*($nth-1))
            if ($candidate.Month -ne $month.Month) { continue }
        } elseif ($type -in @('毎月（第N営業日）','毎月（最終営業日）')) {
            $candidate = Get-BusinessOccurrence $rule $month
        }
        if ($null -ne $candidate -and $candidate -ge $base) { return $candidate }
    }
    return $null
}

function Show-HolidayManagementDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '祝日・会社休業日管理'
    $dlg.Size = New-Object System.Drawing.Size(620,505)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(16,12)
    $status.Size = New-Object System.Drawing.Size(575,64)
    $status.Text = '祝日データ：未取り込み'
    if ($null -ne (Read-HolidaysDocument)) {
        try {
            $holidayObj = Read-HolidaysDocument
            $status.Text = "祝日データ：$(@($holidayObj.Holidays).Count)件`r`n収録期間：$($holidayObj.FirstDate) ～ $($holidayObj.LastDate)"
        } catch { $status.Text = '祝日データ：読み込みエラー（再取り込みが必要です）' }
    }
    $dlg.Controls.Add($status)
    $auto = New-Object System.Windows.Forms.Button
    $auto.Text = '公式CSVを自動取得'; $auto.Location = New-Object System.Drawing.Point(16,80); $auto.Size = New-Object System.Drawing.Size(175,34)
    $manual = New-Object System.Windows.Forms.Button
    $manual.Text = 'CSVを手動取り込み'; $manual.Location = New-Object System.Drawing.Point(202,80); $manual.Size = New-Object System.Drawing.Size(180,34)
    $dlg.Controls.AddRange([System.Windows.Forms.Control[]]@($auto,$manual))
    $label = New-Object System.Windows.Forms.Label
    $label.Text = '会社独自の休業日（土日・祝日以外）'; $label.Location = New-Object System.Drawing.Point(16,128); $label.AutoSize = $true
    $dlg.Controls.Add($label)
    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(16,157); $list.Size = New-Object System.Drawing.Size(355,248)
    $dlg.Controls.Add($list)
    $picker = New-Object System.Windows.Forms.DateTimePicker
    $picker.Format = 'Custom'; $picker.CustomFormat = 'yyyy/MM/dd'
    $picker.Location = New-Object System.Drawing.Point(390,157); $picker.Size = New-Object System.Drawing.Size(192,30)
    $add = New-Object System.Windows.Forms.Button
    $add.Text = '休業日を追加'; $add.Location = New-Object System.Drawing.Point(390,200); $add.Size = New-Object System.Drawing.Size(192,35)
    $remove = New-Object System.Windows.Forms.Button
    $remove.Text = '選択した休業日を削除'; $remove.Location = New-Object System.Drawing.Point(390,244); $remove.Size = New-Object System.Drawing.Size(192,35)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = '閉じる'; $close.Location = New-Object System.Drawing.Point(480,420); $close.Size = New-Object System.Drawing.Size(102,32)
    $dlg.Controls.AddRange([System.Windows.Forms.Control[]]@($picker,$add,$remove,$close))
    $close.Add_Click({ $dlg.Close() })
    $reload = {
        $list.Items.Clear()
        foreach ($date in @(Read-CompanyClosures)) { [void]$list.Items.Add($date) }
    }
    & $reload
    $manual.Add_Click({
        try {
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
            [System.Windows.Forms.MessageBox]::Show($dlg,"祝日データを $count 件取り込みました。`r`n画面を開き直すと収録期間を確認できます。",'TaskPilot') | Out-Null
        } catch { Show-Failure $_ }
    })
    $auto.Add_Click({
        $tmp = Get-TPGuiHolidayTemporaryPath
        try {
            $wc = New-Object System.Net.WebClient
            try { $holidayBytes = $wc.DownloadData($OfficialHolidayUrl); Save-TPGuiDownloadedHolidayCsv -Path $tmp -Bytes $holidayBytes } finally { $wc.Dispose() }
            $count = Import-JapaneseHolidayCsv $tmp
            [System.Windows.Forms.MessageBox]::Show($dlg,"公式CSVから $count 件取り込みました。`r`n画面を開き直すと収録期間を確認できます。",'TaskPilot') | Out-Null
        } catch { Show-Failure $_ } finally { Remove-TPGuiHolidayTemporaryFile -Path $tmp }
    })
    $add.Add_Click({
        try {
            $dates = @(Read-CompanyClosures)
            $date = $picker.Value.ToString('yyyy-MM-dd')
            if ($dates -contains $date) { return }
            Add-CompanyClosure $date
            & $reload
        } catch { Show-Failure $_ }
    })
    $remove.Add_Click({
        if ($null -eq $list.SelectedItem) { return }
        try {
            $selected = [string]$list.SelectedItem
            Remove-CompanyClosure $selected
            & $reload
        } catch { Show-Failure $_ }
    })
    try { [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}

function Show-RecurringRuleEditor($existing) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '定期タスクの登録・編集（STEP 3.3A）'
    $dlg.Size = New-Object System.Drawing.Size(510,535)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
    $controls = @{}
    $y = 18
    function Add-RuleRow([string]$caption,[System.Windows.Forms.Control]$control) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $caption; $label.Location = New-Object System.Drawing.Point(18,$script:rowY)
        $label.Size = New-Object System.Drawing.Size(145,29)
        $control.Location = New-Object System.Drawing.Point(166,$script:rowY)
        $control.Size = New-Object System.Drawing.Size(290,28)
        $dlg.Controls.Add($label); $dlg.Controls.Add($control)
        $script:rowY += 39
    }
    $script:rowY = 18
    $name = New-Object System.Windows.Forms.TextBox
    Add-RuleRow 'タスク名' $name
    $type = New-Object System.Windows.Forms.ComboBox
    $type.DropDownStyle = 'DropDownList'
    [void]$type.Items.AddRange([object[]]@('毎日','毎週','毎月（日付）','毎月（第N曜日）','毎月（第N営業日）','毎月（最終営業日）'))
    Add-RuleRow '繰り返し' $type
    $weekday = New-Object System.Windows.Forms.ComboBox
    $weekday.DropDownStyle = 'DropDownList'
    [void]$weekday.Items.AddRange([object[]]@('月','火','水','木','金','土','日'))
    Add-RuleRow '曜日' $weekday
    $day = New-Object System.Windows.Forms.NumericUpDown
    $day.Minimum = 1; $day.Maximum = 31
    Add-RuleRow '日付（1～31）' $day
    $nth = New-Object System.Windows.Forms.NumericUpDown
    $nth.Minimum = 1; $nth.Maximum = 31
    Add-RuleRow '第N（回／営業日）' $nth
    $start = New-Object System.Windows.Forms.DateTimePicker
    $start.Format = 'Custom'; $start.CustomFormat = 'yyyy/MM/dd'
    Add-RuleRow '開始日' $start
    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Text = '有効'; $enabled.Checked = $true
    Add-RuleRow '状態' $enabled
    $note = New-Object System.Windows.Forms.TextBox
    Add-RuleRow 'メモ' $note
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '※ 営業日指定には確認済みの祝日データが必要です。'
    $hint.Location = New-Object System.Drawing.Point(18,345)
    $hint.Size = New-Object System.Drawing.Size(455,45)
    $dlg.Controls.Add($hint)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '保存'; $ok.Location = New-Object System.Drawing.Point(272,408)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'キャンセル'; $cancel.Location = New-Object System.Drawing.Point(370,408)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel); $dlg.CancelButton = $cancel
    $type.Add_SelectedIndexChanged({
        $weekday.Enabled = @('毎週','毎月（第N曜日）') -contains [string]$type.SelectedItem
        $day.Enabled = [string]$type.SelectedItem -eq '毎月（日付）'
        $nth.Enabled = @('毎月（第N曜日）','毎月（第N営業日）') -contains [string]$type.SelectedItem
        if ([string]$type.SelectedItem -eq '毎月（第N曜日）') { $nth.Maximum = 5 }
        else { $nth.Maximum = 31 }
        if ($nth.Value -gt $nth.Maximum) { $nth.Value = $nth.Maximum }
    })
    $weekday.SelectedIndex = 0
    $type.SelectedIndex = 0
    if ($null -ne $existing) {
        $name.Text = [string]$existing.Name
        $type.SelectedItem = [string]$existing.Type
        $weekday.SelectedItem = [string]$existing.Weekday
        if ($null -ne $existing.Day -and [int]$existing.Day -ge 1 -and [int]$existing.Day -le 31) { $day.Value = [int]$existing.Day }
        if ($null -ne $existing.Nth -and [int]$existing.Nth -ge 1 -and [int]$existing.Nth -le [int]$nth.Maximum) { $nth.Value = [int]$existing.Nth }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$existing.StartDate,'yyyy-MM-dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { $start.Value = $parsed }
        $enabled.Checked = [bool]$existing.Enabled
        $note.Text = [string]$existing.Note
    }
    $ok.Add_Click({
        if ([string]::IsNullOrWhiteSpace($name.Text)) {
            [System.Windows.Forms.MessageBox]::Show($dlg,'タスク名を入力してください。') | Out-Null
            return
        }
        $dlg.Tag = [pscustomobject]@{
            Id = $(if ($null -ne $existing) { [string]$existing.Id } else { [guid]::NewGuid().ToString('N') })
            Name = $name.Text.Trim(); Type = [string]$type.SelectedItem
            Weekday = [string]$weekday.SelectedItem; Day = [int]$day.Value; Nth = [int]$nth.Value
            StartDate = $start.Value.ToString('yyyy-MM-dd'); Enabled = $enabled.Checked; Note = $note.Text
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    try {
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.Tag }
        return $null
    } finally { $dlg.Dispose() }
}
function Show-RecurringRulesDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '定期タスク管理（自動生成対応）'
    $dlg.Size = New-Object System.Drawing.Size(940,475)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false
    $list.Location = New-Object System.Drawing.Point(12,12)
    $list.Size = New-Object System.Drawing.Size(895,320)
    [void]$list.Columns.Add('タスク名',220)
    [void]$list.Columns.Add('繰り返し',160)
    [void]$list.Columns.Add('開始日',110)
    [void]$list.Columns.Add('状態',80)
    [void]$list.Columns.Add('次回実施日',165)
    $dlg.Controls.Add($list)
    $rules = [System.Collections.ArrayList]::new()
    foreach ($r in @(Read-RecurringRules)) { [void]$rules.Add($r) }
    function Refresh-RuleList {
        $list.Items.Clear()
        foreach ($r in $rules) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.Name)
            [void]$item.SubItems.Add([string]$r.Type)
            [void]$item.SubItems.Add([string]$r.StartDate)
            [void]$item.SubItems.Add($(if ($r.Enabled) { '有効' } else { '無効' }))
            $nextText = '無効'
            if ($r.Enabled) {
                try {
                    $nextDate = Get-NextRecurringDate $r (Get-Date).Date
                    $nextText = $(if ($null -ne $nextDate) { $nextDate.ToString('yyyy/MM/dd') } else { '該当なし' })
                } catch { $nextText = '確認不可（祝日等）' }
            }
            [void]$item.SubItems.Add($nextText)
            $item.Tag = [string]$r.Id
            [void]$list.Items.Add($item)
        }
    }
    $add = New-Object System.Windows.Forms.Button
    $add.Text = '新規登録'; $add.Location = New-Object System.Drawing.Point(12,348); $add.Size = New-Object System.Drawing.Size(110,34)
    $edit = New-Object System.Windows.Forms.Button
    $edit.Text = '編集'; $edit.Location = New-Object System.Drawing.Point(132,348); $edit.Size = New-Object System.Drawing.Size(100,34)
    $delete = New-Object System.Windows.Forms.Button
    $delete.Text = '削除'; $delete.Location = New-Object System.Drawing.Point(242,348); $delete.Size = New-Object System.Drawing.Size(100,34)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = '閉じる'; $close.Location = New-Object System.Drawing.Point(797,348); $close.Size = New-Object System.Drawing.Size(110,34)
    $dlg.Controls.AddRange([System.Windows.Forms.Control[]]@($add,$edit,$delete,$close))
    $close.Add_Click({ $dlg.Close() })
    $holidays = New-Object System.Windows.Forms.Button
    $holidays.Text = '祝日・休業日管理'
    $holidays.Location = New-Object System.Drawing.Point(352,348)
    $holidays.Size = New-Object System.Drawing.Size(165,34)
    $dlg.Controls.Add($holidays)
    $holidays.Add_Click({ try { Show-HolidayManagementDialog; Refresh-RuleList } catch { Show-Failure $_ } })
    $add.Add_Click({
        try {
            $new = Show-RecurringRuleEditor $null
            if ($null -ne $new) {
                $next = @($rules.ToArray()) + @($new)
                Save-RecurringRules $next -OriginalRules @($rules.ToArray())
                [void]$rules.Add($new)
                Refresh-RuleList
            }
        } catch { Show-Failure $_ }
    })
    $edit.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        try {
            $id = [string]$list.SelectedItems[0].Tag
            $old = @($rules | Where-Object { $_.Id -eq $id } | Select-Object -First 1)[0]
            $updated = Show-RecurringRuleEditor $old
            if ($null -ne $updated) {
                $next = @($rules | ForEach-Object { if ($_.Id -eq $id) { $updated } else { $_ } })
                Save-RecurringRules $next -OriginalRules @($rules.ToArray())
                $rules.Clear()
                foreach ($r in $next) { [void]$rules.Add($r) }
                Refresh-RuleList
            }
        } catch { Show-Failure $_ }
    })
    $delete.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        if (-not (Ask-Confirm '選択した定期タスクのルールを削除しますか？')) { return }
        try {
            $id = [string]$list.SelectedItems[0].Tag
            $next = @($rules | Where-Object { $_.Id -ne $id })
            Save-RecurringRules $next -OriginalRules @($rules.ToArray())
            $rules.Clear()
            foreach ($r in $next) { [void]$rules.Add($r) }
            Refresh-RuleList
        } catch { Show-Failure $_ }
    })
    Refresh-RuleList
    try { [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
    $generated = Invoke-RecurringGeneration
    Refresh-List
    if ($generated -gt 0) { [System.Windows.Forms.MessageBox]::Show($form,"定期タスクを $generated 件追加しました。",'定期タスク') | Out-Null }
}


function Ask-Confirm([string]$message) {
    return ([System.Windows.Forms.MessageBox]::Show($message,'確認','YesNo','Question') -eq [System.Windows.Forms.DialogResult]::Yes)
}
# STEP 3.4B: planned work dates are stored separately, keyed by immutable task ID.
# Existing TaskList.csv and recurrence marker fields are intentionally untouched.
$PlannedDatesFile = Join-Path $DataDir 'PlannedDates.json'


function Get-PlannedDate([string]$taskId) {
    $map = Read-PlannedDates
    if ($map.ContainsKey($taskId)) { return [string]$map[$taskId] }
    return ''
}
# STEP 3.6B: optional work plan metadata, separate from the legacy CSV.
$WorkPlansFile = Join-Path $DataDir 'WorkPlans.json'

function Get-WorkPlan([string]$taskId) {
    $map = Read-WorkPlans
    if ($map.ContainsKey($taskId)) { return $map[$taskId] }
    return $null
}

function Save-WorkPlanFromDialog([string]$taskId,$value) {
    if ($null -eq $value -or -not $value.PSObject.Properties['WorkStartDate']) { return }
    Save-WorkPlan $taskId ([string]$value.WorkStartDate) ([decimal]$value.EstimatedHours)
}

# STEP 3.6C: working calendar and completion history (stored independently of legacy CSV).
$script:CapacityFile = Join-Path $DataDir 'CapacitySettings.json'
$script:ActualFile = Join-Path $DataDir 'ActualHours.json'





# STEP 3.6D: daily work entries, independent from completion totals.
$script:WorkLogFile = Join-Path $DataDir 'WorkLogs.json'


function Get-LoggedHours([string]$taskId) {
    $sum = 0.0
    foreach ($r in @(Read-WorkLogs)) { if ([string]$r.TaskId -eq $taskId) { $sum += [double]$r.Hours } }
    return $sum
}
function Get-MonthLoggedHours([datetime]$month) {
    $sum=0.0; $count=0
    foreach ($r in @(Read-WorkLogs)) {
        $d=[datetime]::MinValue
        if ([datetime]::TryParse([string]$r.WorkDate,[ref]$d) -and $d.Year -eq $month.Year -and $d.Month -eq $month.Month) { $sum += [double]$r.Hours; $count++ }
    }
    return [pscustomobject]@{Hours=$sum; Count=$count}
}
function Show-WorkLogDialog {
    $task=Selected-Task
    if ($null -eq $task) { [void][System.Windows.Forms.MessageBox]::Show('タスクを選択してください。'); return }
    $script:WorkLogDialogTaskId=[string]$task.ID
    $dlg=New-Object System.Windows.Forms.Form
    $dlg.Text="作業実績（日別） - [$script:WorkLogDialogTaskId] $($task.Task)"
    $dlg.Size=New-Object System.Drawing.Size(650,485); $dlg.StartPosition='CenterParent'
    $dlg.Font=New-Object System.Drawing.Font('Yu Gothic UI',10)
    $dlg.BackColor=[System.Drawing.Color]::FromArgb(22,33,51); $dlg.ForeColor=[System.Drawing.Color]::White
    $script:WorkLogDialogCaption=New-Object System.Windows.Forms.Label; $script:WorkLogDialogCaption.SetBounds(20,15,595,45); $dlg.Controls.Add($script:WorkLogDialogCaption)
    $script:WorkLogDialogList=New-Object System.Windows.Forms.ListBox; $script:WorkLogDialogList.SetBounds(20,70,590,230); $dlg.Controls.Add($script:WorkLogDialogList)
    $script:WorkLogDialogDay=New-Object System.Windows.Forms.DateTimePicker; $script:WorkLogDialogDay.Format='Custom'; $script:WorkLogDialogDay.CustomFormat='yyyy/MM/dd'; $script:WorkLogDialogDay.SetBounds(20,318,150,30); $dlg.Controls.Add($script:WorkLogDialogDay)
    $script:WorkLogDialogHours=New-Object System.Windows.Forms.NumericUpDown; $script:WorkLogDialogHours.SetBounds(185,318,105,30); $script:WorkLogDialogHours.DecimalPlaces=2; $script:WorkLogDialogHours.Increment=[decimal]0.25; $script:WorkLogDialogHours.Minimum=0.25; $script:WorkLogDialogHours.Maximum=24; $script:WorkLogDialogHours.Value=1; $dlg.Controls.Add($script:WorkLogDialogHours)
    $script:WorkLogDialogMemo=New-Object System.Windows.Forms.TextBox; $script:WorkLogDialogMemo.SetBounds(305,318,305,30); $dlg.Controls.Add($script:WorkLogDialogMemo)
    $add=New-Object System.Windows.Forms.Button; $add.Text='追加'; $add.SetBounds(20,365,100,35); $dlg.Controls.Add($add)
    $remove=New-Object System.Windows.Forms.Button; $remove.Text='選択行を削除'; $remove.SetBounds(130,365,145,35); $dlg.Controls.Add($remove)
    $close=New-Object System.Windows.Forms.Button; $close.Text='閉じる'; $close.SetBounds(510,365,100,35); $dlg.Controls.Add($close)
    $script:WorkLogDialogTaskIds=New-Object 'System.Collections.Generic.List[string]'
    $script:WorkLogDialogRefresh={
        $script:WorkLogDialogList.Items.Clear(); $script:WorkLogDialogTaskIds.Clear()
        $total=Get-LoggedHours $script:WorkLogDialogTaskId
        $plan=Get-WorkPlan $script:WorkLogDialogTaskId
        $estimated=0.0; if ($null -ne $plan) { $estimated=[double]$plan.EstimatedHours }
        $script:WorkLogDialogCaption.Text=('予定：{0:N2}h  作業記録：{1:N2}h  残り見込み：{2:N2}h（下限0）' -f $estimated,$total,[math]::Max(0.0,$estimated-$total))
        foreach ($r in @(Read-WorkLogs | Where-Object { [string]$_.TaskId -eq $script:WorkLogDialogTaskId } | Sort-Object WorkDate)) {
            [void]$script:WorkLogDialogTaskIds.Add([string]$r.EntryId)
            [void]$script:WorkLogDialogList.Items.Add(('{0}  {1:N2}h  {2}' -f $r.WorkDate,[double]$r.Hours,[string]$r.Memo))
        }
    }
    $add.Add_Click({
        try {
            $rows=@(Read-WorkLogs)
            $rows+= [pscustomobject]@{EntryId=[guid]::NewGuid().ToString('N');TaskId=$script:WorkLogDialogTaskId;WorkDate=$script:WorkLogDialogDay.Value.ToString('yyyy/MM/dd');Hours=[double]$script:WorkLogDialogHours.Value;Memo=$script:WorkLogDialogMemo.Text}
            Save-WorkLogs $rows -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'work_logs')
            & $script:WorkLogDialogRefresh; Update-TopCapacity; Update-AutoReports
        } catch { Show-Failure $_ }
    })
    $remove.Add_Click({
        try {
            if ($script:WorkLogDialogList.SelectedIndex -lt 0) { return }
            $removeId=$script:WorkLogDialogTaskIds[$script:WorkLogDialogList.SelectedIndex]
            $rows=@(Read-WorkLogs | Where-Object { [string]$_.EntryId -ne $removeId })
            Save-WorkLogs $rows -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'work_logs')
            & $script:WorkLogDialogRefresh; Update-TopCapacity; Update-AutoReports
        } catch { Show-Failure $_ }
    })
    $close.Add_Click({ $dlg.Close() })
    try { & $script:WorkLogDialogRefresh; [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}


function Get-DayCapacity([datetime]$date,$cfg,$holidays) {
    $key = $date.ToString('yyyy-MM-dd')
    if ($cfg.Overrides.ContainsKey($key)) { return [double]$cfg.Overrides[$key] }
    $weekday = [int]$date.DayOfWeek
    if ($weekday -notin @($cfg.Weekdays)) { return 0.0 }
    if (-not $cfg.WorkOnHolidays -and $holidays.ContainsKey($key)) { return 0.0 }
    return [double]$cfg.DailyHours
}
function Get-MonthCapacity([datetime]$month,$cfg,$holidays) {
    $first = (Get-Date -Year $month.Year -Month $month.Month -Day 1).Date
    $days = [datetime]::DaysInMonth($month.Year,$month.Month)
    $hours = 0.0; $workdays = 0
    for ($i=0; $i -lt $days; $i++) {
        $h = Get-DayCapacity $first.AddDays($i) $cfg $holidays
        if ($h -gt 0) { $workdays++ }; $hours += $h
    }
    return [pscustomobject]@{ Workdays=$workdays; Hours=$hours }
}
function Get-TaskMonthAllocation($task,[datetime]$month,$cfg,$holidays,$plans) {
    if ([string]$task.Status -eq '完了') { return 0.0 }
    $id = [string]$task.ID
    if (-not $plans.ContainsKey($id)) { return 0.0 }
    $plan = $plans[$id]
    $estimate = [math]::Max(0.0,([double]$plan.EstimatedHours - (Get-LoggedHours $id)))
    if ($estimate -le 0) { return 0.0 }
    $start = [datetime]::MinValue; $end = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$plan.StartDate,[ref]$start)) { return 0.0 }
    if (-not [datetime]::TryParse([string]$task.DueDate,[ref]$end)) { return 0.0 }
    if ($end.Date -lt $start.Date) { return 0.0 }
    $monthStart = (Get-Date -Year $month.Year -Month $month.Month -Day 1).Date
    $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
    if ($end.Date -lt $monthStart -or $start.Date -gt $monthEnd) { return 0.0 }
    $total = 0.0; $part = 0.0
    for ($day=$start.Date; $day -le $end.Date; $day=$day.AddDays(1)) {
        $h = Get-DayCapacity $day $cfg $holidays
        $total += $h
        if ($day -ge $monthStart -and $day -le $monthEnd) { $part += $h }
    }
    if ($total -le 0) { return 0.0 }
    return ($estimate * $part / $total)
}
function Get-RemainingMonthCapacity([datetime]$month,[datetime]$asOf,$cfg,$holidays) {
    $first = (Get-Date -Year $month.Year -Month $month.Month -Day 1).Date
    $end = $first.AddMonths(1).AddDays(-1)
    $start = $first
    if ($asOf.Date -gt $start) { $start = $asOf.Date }
    $hours = 0.0; $days = 0
    for ($day=$start; $day -le $end; $day=$day.AddDays(1)) {
        $h = Get-DayCapacity $day $cfg $holidays
        if ($h -gt 0) { $days++ }; $hours += $h
    }
    return [pscustomobject]@{ Workdays=$days; Hours=$hours }
}
function Get-MonthPlanTotal([datetime]$month,$cfg,$holidays) {
    $plans = Read-WorkPlans
    $planned = 0.0
    foreach ($task in @(Read-Tasks $TaskFile)) {
        $planned += Get-TaskMonthAllocation $task $month $cfg $holidays $plans
    }
    return $planned
}
function Update-TopCapacity {
    if ($null -eq $script:topCapacityLabel) { return }
    try {
        $now=(Get-Date).Date
        $cfg=Read-CapacitySettings
        $holidays=Get-CapacityHolidayKeys
        $cap=Get-MonthCapacity $now $cfg $holidays
        $left=Get-RemainingMonthCapacity $now $now $cfg $holidays
        $planned=Get-MonthPlanTotal $now $cfg $holidays
        $free=$left.Hours-$planned
        $script:topCapacityLabel.Text = ('今月の総稼働可能時間：{0:N2}h（{1}日）  |  当月残り稼働可能時間：{2:N2}h（{3}日・本日含む）  |  今月の未完了予定工数：{4:N2}h  |  追加受入目安：{5:N2}h' -f $cap.Hours,$cap.Workdays,$left.Hours,$left.Workdays,$planned,$free)
        if ($free -lt 0) { $script:topCapacityLabel.ForeColor=[System.Drawing.Color]::FromArgb(255,113,122) }
        else { $script:topCapacityLabel.ForeColor=[System.Drawing.Color]::FromArgb(111,195,255) }
    } catch {
        $script:topCapacityLabel.Text='稼働情報を取得できません（設定・休日データを確認してください）'
        Write-ErrorLog $_
    }
}
function Show-CapacitySettingsDialog {
    $cfg = Read-CapacitySettings
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text='稼働カレンダー設定'; $dlg.Size=New-Object System.Drawing.Size(640,520)
    $dlg.StartPosition='CenterParent'; $dlg.Font=New-Object System.Drawing.Font('Yu Gothic UI',10)
    $dlg.BackColor=[System.Drawing.Color]::FromArgb(22,33,51); $dlg.ForeColor=[System.Drawing.Color]::White
    $title=New-Object System.Windows.Forms.Label; $title.Text='基本稼働曜日（チェックした曜日に稼働）'; $title.SetBounds(20,18,540,28); $dlg.Controls.Add($title)
    $checks=@(); $names=@('日','月','火','水','木','金','土')
    for ($i=0;$i -lt 7;$i++) {
        $c=New-Object System.Windows.Forms.CheckBox; $c.Text=$names[$i]; $c.SetBounds((20+$i*83),54,75,28)
        $c.Checked=($i -in @($cfg.Weekdays)); $dlg.Controls.Add($c); $checks+= $c
    }
    $hLabel=New-Object System.Windows.Forms.Label; $hLabel.Text='通常の1日実働時間'; $hLabel.SetBounds(20,100,230,28); $dlg.Controls.Add($hLabel)
    $daily=New-Object System.Windows.Forms.NumericUpDown; $daily.SetBounds(255,100,120,28); $daily.DecimalPlaces=2; $daily.Increment=[decimal]0.25; $daily.Minimum=0; $daily.Maximum=24; $daily.Value=[decimal]$cfg.DailyHours; $dlg.Controls.Add($daily)
    $holiday=New-Object System.Windows.Forms.CheckBox; $holiday.Text='祝日・会社休日も基本曜日どおり稼働する'; $holiday.SetBounds(20,143,500,30); $holiday.Checked=$cfg.WorkOnHolidays; $dlg.Controls.Add($holiday)
    $note=New-Object System.Windows.Forms.Label; $note.Text='個別日付の上書き（0時間なら休業、休日出勤も指定可能）'; $note.SetBounds(20,194,580,26); $dlg.Controls.Add($note)
    $date=New-Object System.Windows.Forms.DateTimePicker; $date.Format='Custom'; $date.CustomFormat='yyyy/MM/dd'; $date.SetBounds(20,228,165,28); $dlg.Controls.Add($date)
    $special=New-Object System.Windows.Forms.NumericUpDown; $special.SetBounds(200,228,120,28); $special.DecimalPlaces=2; $special.Increment=[decimal]0.25; $special.Minimum=0; $special.Maximum=24; $dlg.Controls.Add($special)
    $list=New-Object System.Windows.Forms.ListBox; $list.SetBounds(20,274,580,120); $dlg.Controls.Add($list)
    $render={ $list.Items.Clear(); foreach($k in @($cfg.Overrides.Keys | Sort-Object)) { [void]$list.Items.Add("$k : $($cfg.Overrides[$k]) 時間") } }
    & $render
    $add=New-Object System.Windows.Forms.Button; $add.Text='日付を登録'; $add.SetBounds(340,228,125,30); $dlg.Controls.Add($add)
    $remove=New-Object System.Windows.Forms.Button; $remove.Text='選択日付を削除'; $remove.SetBounds(470,228,130,30); $dlg.Controls.Add($remove)
    $add.Add_Click({ $cfg.Overrides[$date.Value.ToString('yyyy-MM-dd')]=[double]$special.Value; & $render })
    $remove.Add_Click({ if($list.SelectedItem) { $key=([string]$list.SelectedItem).Substring(0,10); [void]$cfg.Overrides.Remove($key); & $render } })
    $save=New-Object System.Windows.Forms.Button; $save.Text='保存'; $save.SetBounds(400,414,95,32); $dlg.Controls.Add($save)
    $close=New-Object System.Windows.Forms.Button; $close.Text='キャンセル'; $close.SetBounds(505,414,95,32); $dlg.Controls.Add($close)
    $close.Add_Click({$dlg.Close()})
    $save.Add_Click({
        try {
            $cfg.Weekdays=@(for($i=0;$i -lt 7;$i++) { if($checks[$i].Checked) {$i} })
            $cfg.DailyHours=[double]$daily.Value; $cfg.WorkOnHolidays=$holiday.Checked
            Save-CapacitySettings $cfg
            $dlg.DialogResult=[System.Windows.Forms.DialogResult]::OK; $dlg.Close()
        } catch { Show-Failure $_ }
    })
    try { [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}
function Show-ActualHoursDialog {
    $task = Selected-Task
    if ($null -eq $task) { [System.Windows.Forms.MessageBox]::Show('タスクを選択してください。') | Out-Null; return }
    if ([string]$task.Status -ne '完了') { [System.Windows.Forms.MessageBox]::Show('完了済みタスクを選択してください。') | Out-Null; return }
    $existing = Read-ActualHours
    $plan = Get-WorkPlan ([string]$task.ID)
    $dlg=New-Object System.Windows.Forms.Form; $dlg.Text='完了タスクの実績工数'; $dlg.Size=New-Object System.Drawing.Size(465,250); $dlg.StartPosition='CenterParent'
    $dlg.Font=New-Object System.Drawing.Font('Yu Gothic UI',10)
    $label=New-Object System.Windows.Forms.Label; $label.Text="[$($task.ID)] $($task.Task)"; $label.SetBounds(18,15,420,32); $dlg.Controls.Add($label)
    $day=New-Object System.Windows.Forms.DateTimePicker; $day.Format='Custom'; $day.CustomFormat='yyyy/MM/dd'; $day.SetBounds(18,65,175,28); $dlg.Controls.Add($day)
    $hours=New-Object System.Windows.Forms.NumericUpDown; $hours.SetBounds(215,65,180,28); $hours.DecimalPlaces=2; $hours.Increment=[decimal]0.25; $hours.Maximum=100000; $dlg.Controls.Add($hours)
    if ($existing.ContainsKey([string]$task.ID)) {
        $old=$existing[[string]$task.ID]; $dt=[datetime]::MinValue
        if ([datetime]::TryParse([string]$old.CompletedDate,[ref]$dt)) { $day.Value=$dt }
        $hours.Value=[decimal]$old.ActualHours
    } elseif ($null -ne $plan) { $hours.Value=[decimal]$plan.EstimatedHours }
    $note=New-Object System.Windows.Forms.Label; $note.Text='左：完了日（集計月の判定に使用）　右：実際にかかった時間'; $note.SetBounds(18,110,425,28); $dlg.Controls.Add($note)
    $save=New-Object System.Windows.Forms.Button; $save.Text='実績を保存'; $save.SetBounds(185,153,120,32); $dlg.Controls.Add($save)
    $cancel=New-Object System.Windows.Forms.Button; $cancel.Text='閉じる'; $cancel.SetBounds(320,153,90,32); $dlg.Controls.Add($cancel)
    $cancel.Add_Click({$dlg.Close()})
    $save.Add_Click({ try { Save-ActualHours ([string]$task.ID) $day.Value ([decimal]$hours.Value) ([string]$task.Task) -ExpectedVersion ([long]$task.TPRowVersion); $script:ReportsNeedRefresh = $true; Update-AutoReports; if ($script:ReportsNeedRefresh) { [System.Windows.Forms.MessageBox]::Show("完了実績は保存されましたが、Excelの更新に失敗しました。`r`n$script:ReportError`r`nExcelを閉じて「ファイル表示 → Excelを再出力」を実行してください。",'Excel更新待ち') | Out-Null }; $dlg.Close() } catch { Show-Failure $_ } })
    try { [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}
function Show-MonthlyCapacityDialog {
    $dlg=New-Object System.Windows.Forms.Form; $dlg.Text='月間稼働率・予定工数・完了実績'; $dlg.Size=New-Object System.Drawing.Size(740,570)
    $dlg.StartPosition='CenterParent'; $dlg.Font=New-Object System.Drawing.Font('Yu Gothic UI',11)
    $dlg.BackColor=[System.Drawing.Color]::FromArgb(22,33,51); $dlg.ForeColor=[System.Drawing.Color]::White
    $script:capacityMonth=(Get-Date -Day 1).Date
    $month=New-Object System.Windows.Forms.Label; $month.SetBounds(275,18,195,36); $month.TextAlign='MiddleCenter'; $dlg.Controls.Add($month)
    $prev=New-Object System.Windows.Forms.Button; $prev.Text='◀ 前月'; $prev.SetBounds(140,18,110,32); $dlg.Controls.Add($prev)
    $next=New-Object System.Windows.Forms.Button; $next.Text='翌月 ▶'; $next.SetBounds(495,18,110,32); $dlg.Controls.Add($next)
    $body=New-Object System.Windows.Forms.Label; $body.SetBounds(45,68,650,330); $body.Font=New-Object System.Drawing.Font('Yu Gothic UI',14); $dlg.Controls.Add($body)
    $help=New-Object System.Windows.Forms.Label
    $help.Text='※実績は完了済みタスクをメイン画面で選択→「完了実績入力」で保存。完了日の月に集計。追加受入目安は残り時間から当月の未完了予定工数全額を控除。'
    $help.SetBounds(45,375,650,36); $help.Font=New-Object System.Drawing.Font('Yu Gothic UI',8)
    $dlg.Controls.Add($help)
    $progress=New-Object System.Windows.Forms.ProgressBar; $progress.SetBounds(45,410,645,25); $progress.Minimum=0; $progress.Maximum=100; $dlg.Controls.Add($progress)
    $settings=New-Object System.Windows.Forms.Button; $settings.Text='稼働カレンダー設定'; $settings.SetBounds(45,462,185,35); $dlg.Controls.Add($settings)
    $actual=New-Object System.Windows.Forms.Button; $actual.Text='完了タスクの実績入力'; $actual.SetBounds(250,462,215,35); $dlg.Controls.Add($actual)
    $exit=New-Object System.Windows.Forms.Button; $exit.Text='閉じる'; $exit.SetBounds(575,462,115,35); $dlg.Controls.Add($exit)
    $refresh={
        $cfg=Read-CapacitySettings; $holidays=Get-CapacityHolidayKeys; $plans=Read-WorkPlans
        $cap=Get-MonthCapacity $script:capacityMonth $cfg $holidays
        $snapshotMap=Read-MonthlySnapshots
        $snapshotKey=$script:capacityMonth.ToString('yyyy/MM')
        $savedSnapshot=$null
        if ($snapshotMap.ContainsKey($snapshotKey)) { $savedSnapshot=$snapshotMap[$snapshotKey] }
        $remainingCap=Get-RemainingMonthCapacity $script:capacityMonth (Get-Date).Date $cfg $holidays
        $planned=Get-MonthPlanTotal $script:capacityMonth $cfg $holidays
        $workLogged=Get-MonthLoggedHours $script:capacityMonth
        $actuals=Read-ActualHours; $actualHours=0.0; $actualCount=0; $unrecorded=0
        foreach($key in @($actuals.Keys)) {
            $row=$actuals[$key]; $dt=[datetime]::MinValue
            if ([datetime]::TryParse([string]$row.CompletedDate,[ref]$dt) -and $dt.Year -eq $script:capacityMonth.Year -and $dt.Month -eq $script:capacityMonth.Month) {
                $actualHours += [double]$row.ActualHours; $actualCount++
            }
        }
        foreach($task in @(Read-Tasks $TaskFile)) {
            if ([string]$task.Status -eq '完了' -and -not $actuals.ContainsKey([string]$task.ID)) { $unrecorded++ }
        }
        if ($null -ne $savedSnapshot) {
            $cap.Hours=[double]$savedSnapshot.CapacityHours; $cap.Workdays=[int]$savedSnapshot.Workdays
            $planned=[double]$savedSnapshot.PlannedHours; $workLogged.Hours=[double]$savedSnapshot.LoggedHours
            $actualHours=[double]$savedSnapshot.CompletedActualHours; $actualCount=[int]$savedSnapshot.CompletedCount
        }
        $rate=$null
        if ($null -ne $savedSnapshot) { $rate=$savedSnapshot.PlannedRate }
        elseif ($cap.Hours -gt 0) { $rate=100.0*$planned/$cap.Hours }
        $rateText=if($null -eq $rate){'算出なし'}else{([math]::Round([double]$rate,1)).ToString()+' %'}
        $remaining=$cap.Hours-$planned
        $month.Text=$script:capacityMonth.ToString('yyyy年M月')
        $acceptance=$remainingCap.Hours-$planned
        $body.Text= "総稼働日数： $($cap.Workdays) 日`r`n総稼働可能時間： $([math]::Round($cap.Hours,2)) 時間`r`n残り稼働日数： $($remainingCap.Workdays) 日`r`n当月残り稼働可能時間： $([math]::Round($remainingCap.Hours,2)) 時間`r`n未完了タスクの月間予定工数： $([math]::Round($planned,2)) 時間`r`n月間予定稼働率： $rateText`r`n追加受入目安： $([math]::Round($acceptance,2)) 時間`r`n`r`n当月作業記録： $([math]::Round($workLogged.Hours,2)) 時間（$($workLogged.Count) 件）`r`n当月完了実績： $([math]::Round($actualHours,2)) 時間（$actualCount 件）`r`n実績未入力の完了タスク： $unrecorded 件（全期間）"
        if ($cap.Hours -le 0) { $body.Text += "`r`n※稼働可能時間が0のため稼働率は算出できません。" }
        if ($null -ne $savedSnapshot) { $body.Text += "`r`n※この月は確定済みです（保存値を表示）。" }
        $progress.Value=[int][math]::Min(100,[math]::Max(0.0,[math]::Round([double]$rate)))
    }
    $prev.Add_Click({ try { $script:capacityMonth=$script:capacityMonth.AddMonths(-1); & $refresh } catch { Show-Failure $_ } })
    $next.Add_Click({ try { $script:capacityMonth=$script:capacityMonth.AddMonths(1); & $refresh } catch { Show-Failure $_ } })
    $settings.Add_Click({ try { Show-CapacitySettingsDialog; & $refresh; Update-TopCapacity } catch { Show-Failure $_ } })
    $actual.Add_Click({ try { Show-ActualHoursDialog; & $refresh; Update-TopCapacity } catch { Show-Failure $_ } })
    $exit.Add_Click({$dlg.Close()})
    try { & $refresh; [void]$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}

function New-TaskDialog($task, $calendarDate = $null) {
    $editing = ($null -ne $task)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $(if ($editing) {'タスク編集'} else {'タスク追加'})
    $dialog.Size = New-Object System.Drawing.Size(490,550)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $labels = @('タスク名','優先度','期限','ステータス','備考','実施予定日','作業開始日','予定所要時間')
    for ($i=0; $i -lt $labels.Count; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $labels[$i]
        $label.Location = New-Object System.Drawing.Point(18,(25 + $i*52))
        $label.AutoSize = $true
        $dialog.Controls.Add($label)
    }
    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.SetBounds(115,21,320,26)
    $priorityBox = New-Object System.Windows.Forms.ComboBox
    $priorityBox.SetBounds(115,73,320,26)
    $priorityBox.DropDownStyle = 'DropDownList'
    [void]$priorityBox.Items.AddRange([object[]]@('高','中','低'))
    $dueBox = New-Object System.Windows.Forms.DateTimePicker
    $dueBox.SetBounds(115,125,320,26)
    $dueBox.Format = 'Custom'
    $dueBox.CustomFormat = 'yyyy/MM/dd'
    $statusBox = New-Object System.Windows.Forms.ComboBox
    $statusBox.SetBounds(115,177,320,26)
    $statusBox.DropDownStyle = 'DropDownList'
    [void]$statusBox.Items.AddRange([object[]]@('未着手','対応中','完了'))
    $memoBox = New-Object System.Windows.Forms.TextBox
    $memoBox.SetBounds(115,229,320,26)
    foreach ($c in @($nameBox,$priorityBox,$dueBox,$statusBox,$memoBox)) { $dialog.Controls.Add($c) }
    $plannedCheck = New-Object System.Windows.Forms.CheckBox
    $plannedCheck.Text = '指定する'
    $plannedCheck.SetBounds(115,281,100,26)
    $plannedBox = New-Object System.Windows.Forms.DateTimePicker
    $plannedBox.SetBounds(220,281,215,26)
    $plannedBox.Format = 'Custom'
    $plannedBox.CustomFormat = 'yyyy/MM/dd'
    $plannedBox.Enabled = $false
    $plannedCheck.Add_CheckedChanged({ $plannedBox.Enabled = $plannedCheck.Checked })
    $dialog.Controls.Add($plannedCheck)
    $dialog.Controls.Add($plannedBox)
    $workStartCheck = New-Object System.Windows.Forms.CheckBox
    $workStartCheck.Text = '指定する'
    $workStartCheck.SetBounds(115,333,100,26)
    $workStartBox = New-Object System.Windows.Forms.DateTimePicker
    $workStartBox.SetBounds(220,333,215,26)
    $workStartBox.Format = 'Custom'
    $workStartBox.CustomFormat = 'yyyy/MM/dd'
    $workStartBox.Enabled = $false
    $workStartCheck.Add_CheckedChanged({ $workStartBox.Enabled = $workStartCheck.Checked })
    $dialog.Controls.Add($workStartCheck)
    $dialog.Controls.Add($workStartBox)
    $hoursBox = New-Object System.Windows.Forms.NumericUpDown
    $hoursBox.SetBounds(115,385,235,26)
    $hoursBox.DecimalPlaces = 2
    $hoursBox.Increment = [decimal]0.25
    $hoursBox.Minimum = [decimal]0
    $hoursBox.Maximum = [decimal]100000
    $dialog.Controls.Add($hoursBox)
    $hoursUnit = New-Object System.Windows.Forms.Label
    $hoursUnit.Text = '時間（0.25時間単位）'
    $hoursUnit.SetBounds(355,389,125,25)
    $dialog.Controls.Add($hoursUnit)

    $priorityBox.SelectedIndex = 1
    $statusBox.SelectedIndex = 0
    if (-not $editing -and $null -ne $calendarDate) {
        $plannedCheck.Checked = $true
        $plannedBox.Value = [datetime]$calendarDate
        $dueBox.Value = [datetime]$calendarDate
    }
    if ($editing) {
        $nameBox.Text = [string]$task.Task
        $priorityBox.SelectedItem = [string]$task.Priority
        $statusBox.SelectedItem = [string]$task.Status
        $memoBox.Text = [string]$task.Memo
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$task.DueDate,[ref]$parsed)) { $dueBox.Value = $parsed }
        $oldWorkPlan = Get-WorkPlan ([string]$task.ID)
        if ($null -ne $oldWorkPlan) {
            $oldStart = [datetime]::MinValue
            if ([datetime]::TryParseExact([string]$oldWorkPlan.StartDate,'yyyy/MM/dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$oldStart)) {
                $workStartCheck.Checked = $true
                $workStartBox.Value = $oldStart
            }
            $storedHours = [decimal]0
            if ([decimal]::TryParse([string]$oldWorkPlan.EstimatedHours,[Globalization.NumberStyles]::Number,[cultureinfo]::InvariantCulture,[ref]$storedHours) -and $storedHours -ge 0 -and $storedHours -le $hoursBox.Maximum) {
                $hoursBox.Value = $storedHours
            }
        }
        $oldPlanned = Get-PlannedDate ([string]$task.ID)
        if (-not [string]::IsNullOrWhiteSpace($oldPlanned)) {
            $plannedCheck.Checked = $true
            $plannedBox.Value = [datetime]::ParseExact($oldPlanned,'yyyy/MM/dd',[cultureinfo]::InvariantCulture)
        }
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '保存'
    $ok.SetBounds(250,450,85,30)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'キャンセル'
    $cancel.SetBounds(345,450,90,30)
    $cancel.DialogResult = 'Cancel'
    $dialog.Controls.AddRange([System.Windows.Forms.Control[]]@($ok,$cancel))
    $dialog.CancelButton = $cancel
    $ok.Add_Click({
        if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show('タスク名を入力してください。') | Out-Null
            return
        }
        $dialog.Tag = [pscustomobject]@{
            Task=$nameBox.Text.Trim(); Priority=[string]$priorityBox.SelectedItem
            DueDate=$dueBox.Value.ToString('yyyy/MM/dd'); Status=[string]$statusBox.SelectedItem
            Memo=$memoBox.Text
            PlannedDate=$(if ($plannedCheck.Checked) { $plannedBox.Value.ToString('yyyy/MM/dd') } else { '' })
            WorkStartDate=$(if ($workStartCheck.Checked) { $workStartBox.Value.ToString('yyyy/MM/dd') } else { '' })
            EstimatedHours=[decimal]$hoursBox.Value
        }
        $dialog.DialogResult = 'OK'
        $dialog.Close()
    })
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(22,33,51)
    $dialog.ForeColor = [System.Drawing.Color]::FromArgb(231,239,249)
    foreach ($control in $dialog.Controls) {
        if ($control -is [System.Windows.Forms.TextBox] -or $control -is [System.Windows.Forms.ComboBox]) {
            $control.BackColor = [System.Drawing.Color]::FromArgb(31,46,67)
            $control.ForeColor = [System.Drawing.Color]::White
        }
        if ($control -is [System.Windows.Forms.Button]) {
            $control.FlatStyle = 'Flat'
            $control.BackColor = [System.Drawing.Color]::FromArgb(35,75,116)
            $control.ForeColor = [System.Drawing.Color]::White
        }
    }
    $result = $dialog.ShowDialog($form)
    $value = $dialog.Tag
    $dialog.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $value }
    return $null
}
# STEP 3.6D-1: export task metadata and work entries without altering legacy CSV files.
function ConvertTo-SafeExcelRows {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process {
        if ($null -ne $InputObject) {
            $copy = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $value = $property.Value
                # ImportExcel interprets leading '=' as a formula. Keep user input as text.
                if ($value -is [string] -and $value -match '^[\s\x00-\x20]*[=+@-]') { $value = "'" + $value }
                $copy[$property.Name] = $value
            }
            [pscustomobject]$copy
        }
    }
}
function Get-TaskExcelRows($tasks) {
    $plans = Read-WorkPlans
    $actuals = Read-ActualHours
    $plannedDates = Read-PlannedDates
    $subtasks = @(Read-Subtasks)
    $logs = @(Read-WorkLogs)
    foreach ($t in @($tasks)) {
        if ($null -eq $t) { continue }
        $id = [string]$t.ID
        $plan = $null
        if ($plans.ContainsKey($id)) { $plan = $plans[$id] }
        $estimated = 0.0; $start = ''
        if ($null -ne $plan) { $estimated = [double]$plan.EstimatedHours; $start = [string]$plan.StartDate }
        $logged = 0.0
        foreach ($entry in $logs) { if ([string]$entry.TaskId -eq $id) { $logged += [double]$entry.Hours } }
        $children = @($subtasks | Where-Object { [string]$_.ParentId -eq $id })
        $done = @($children | Where-Object { [bool]$_.Done }).Count
        $actual = $null
        if ($actuals.ContainsKey($id)) { $actual = $actuals[$id] }
        $scheduled = ''
        if ($plannedDates.ContainsKey($id)) { $scheduled = [string]$plannedDates[$id] }
        [pscustomobject]@{
            ID=$t.ID; 登録日=$t.Date; タスク名=$t.Task; 優先度=$t.Priority
            実施予定日=$scheduled; 作業開始日=$start; 期限=$t.DueDate; 状態=$t.Status
            予定所要時間_h=$estimated; 作業記録合計_h=$logged
            残り予定工数_h=[math]::Max(0.0,$estimated-$logged)
            完了実績_h=$(if ($null -ne $actual) { $actual.ActualHours } else { $null })
            完了日=$(if ($null -ne $actual) { $actual.CompletedDate } else { '' })
            サブタスク数=$children.Count; サブタスク完了数=$done; 備考=$t.Memo
        }
    }
}
function Add-ExtendedExcelSheets([string]$path) {
    $logs = @(Read-WorkLogs)
    $logRows = @($logs | ForEach-Object { [pscustomobject]@{ 記録ID=$_.EntryId; タスクID=$_.TaskId; 作業日=$_.WorkDate; 作業時間_h=$_.Hours; 作業内容=$_.Memo } })
    if ($logRows.Count -eq 0) { $logRows = @([pscustomobject]@{ 記録ID=''; タスクID=''; 作業日=''; 作業時間_h=$null; 作業内容='' }) }
    $logRows | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName '作業記録' -AutoSize -BoldTopRow -ErrorAction Stop
    $children = @(Read-Subtasks)
    $subRows = @($children | ForEach-Object { [pscustomobject]@{ 親タスクID=$_.ParentId; サブタスク名=$_.Title; 完了=$_.Done; ID=$_.Id } })
    if ($subRows.Count -eq 0) { $subRows = @([pscustomobject]@{ 親タスクID=''; サブタスク名=''; 完了=''; ID='' }) }
    $subRows | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'サブタスク' -AutoSize -BoldTopRow -ErrorAction Stop
    $cfg = Read-CapacitySettings
    $holidays = Get-CapacityHolidayKeys
    $month = Get-Date -Day 1
    $capacity = Get-MonthCapacity $month $cfg $holidays
    $remaining = Get-RemainingMonthCapacity $month (Get-Date) $cfg $holidays
    $planned = Get-MonthPlanTotal $month $cfg $holidays
    $monthly = @([pscustomobject]@{ 対象月=$month.ToString('yyyy/MM'); 総稼働日数=$capacity.Workdays; 総稼働可能時間_h=$capacity.Hours; 残り稼働日数=$remaining.Workdays; 残り稼働可能時間_h=$remaining.Hours; 未完了予定工数_h=[math]::Round($planned,2); 追加受入目安_h=[math]::Round(($remaining.Hours-$planned),2); 当月作業記録_h=(Get-MonthLoggedHours $month).Hours })
    $monthly | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName '月間稼働' -AutoSize -BoldTopRow -ErrorAction Stop
}
# STEP 3.6E: historical analytics. Data remains in TaskPilot's existing storage.

# STEP 3.6F: monthly snapshots, audit history and editable finalized figures.
$script:MonthlySnapshotFile = Join-Path $DataDir 'MonthlySnapshots.json'
$script:MonthlyAuditFile = Join-Path $DataDir 'MonthlySnapshotAudit.json'


function Get-MonthlySnapshotData([datetime]$month,[string]$origin) {
    $cfg=Read-CapacitySettings; $holidays=Get-CapacityHolidayKeys
    $cap=Get-MonthCapacity $month $cfg $holidays
    $planned=Get-MonthPlanTotal $month $cfg $holidays
    $logs=Get-MonthLoggedHours $month
    $actual=0.0; $count=0
    foreach($row in @( (Read-ActualHours).Values )) {
        $dt=[datetime]::MinValue
        if ([datetime]::TryParse([string]$row.CompletedDate,[ref]$dt) -and $dt.Year -eq $month.Year -and $dt.Month -eq $month.Month) { $actual += [double]$row.ActualHours; $count++ }
    }
    $rate=$null
    if ($cap.Hours -gt 0) { $rate=[math]::Round(100*$planned/$cap.Hours,2) }
    return [ordered]@{
        Month=$month.ToString('yyyy/MM'); CapacityHours=[math]::Round($cap.Hours,2)
        Workdays=[int]$cap.Workdays; PlannedHours=[math]::Round($planned,2)
        PlannedRate=$rate; LoggedHours=[math]::Round($logs.Hours,2)
        CompletedActualHours=[math]::Round($actual,2); CompletedCount=$count
        DifferenceHours=[math]::Round(($actual-$planned),2)
        FinalizedAt=(Get-Date).ToString('o'); Source=$origin; Revision=1
    }
}


function Show-MonthlySnapshotsDialog {
    $dlg=New-Object System.Windows.Forms.Form
    $dlg.Text='月次確定データ・修正履歴'; $dlg.Size=New-Object System.Drawing.Size(850,630)
    $dlg.StartPosition='CenterParent'; $dlg.BackColor=[System.Drawing.Color]::FromArgb(22,33,51)
    $dlg.ForeColor=[System.Drawing.Color]::White; $dlg.Font=New-Object System.Drawing.Font('Yu Gothic UI',10)
    $label=New-Object System.Windows.Forms.Label; $label.Text='確定月を選択（未確定の月は表示されません）'; $label.SetBounds(20,15,560,28); $dlg.Controls.Add($label)
    $picker=New-Object System.Windows.Forms.ComboBox; $picker.DropDownStyle='DropDownList'; $picker.SetBounds(20,48,240,30); $dlg.Controls.Add($picker)
    $map=Read-MonthlySnapshots
    foreach($key in @($map.Keys | Sort-Object -Descending)) { [void]$picker.Items.Add($key) }
    $fields=@('CapacityHours','Workdays','PlannedHours','PlannedRate','LoggedHours','CompletedActualHours','CompletedCount','DifferenceHours')
    $names=@('総稼働可能時間(h)','稼働日数','未完了予定工数(h)','予定稼働率(%)','日別作業記録(h)','完了申告実績(h)','完了件数','予定対完了差(h)')
    $boxes=@{}
    for($i=0;$i -lt $fields.Count;$i++) {
        $r=[math]::Floor($i/2); $c=$i%2; $x=20+($c*405); $y=95+($r*57)
        $l=New-Object System.Windows.Forms.Label; $l.Text=$names[$i]; $l.SetBounds($x,$y,185,26); $dlg.Controls.Add($l)
        $box=New-Object System.Windows.Forms.TextBox; $box.SetBounds(($x+195),$y,185,27); $dlg.Controls.Add($box); $boxes[$fields[$i]]=$box
    }
    $info=New-Object System.Windows.Forms.Label; $info.SetBounds(20,325,790,45); $dlg.Controls.Add($info)
    $history=New-Object System.Windows.Forms.TextBox; $history.Multiline=$true; $history.ReadOnly=$true; $history.ScrollBars='Vertical'; $history.SetBounds(20,375,790,145); $dlg.Controls.Add($history)
    $load={
        $key=[string]$picker.SelectedItem
        if (-not $map.ContainsKey($key)) { return }
        $item=$map[$key]
        foreach($field in $fields) { $boxes[$field].Text=[string]$item.$field }
        $info.Text=('確定日時: {0} / 版: {1} / {2}' -f $item.FinalizedAt,$item.Revision,$item.Source)
        $history.Text=''
        if ($true) {
            $audit=@(Read-MonthlyAudit)
            $history.Lines=@($audit | Where-Object { $_.Month -eq $key } | ForEach-Object { '{0}  {1}' -f $_.At,$_.Reason })
        }
    }
    $picker.Add_SelectedIndexChanged($load)
    $save=New-Object System.Windows.Forms.Button; $save.Text='修正して保存'; $save.SetBounds(480,540,155,34); $dlg.Controls.Add($save)
    $save.Add_Click({
        try {
            $key=[string]$picker.SelectedItem
            if (-not $map.ContainsKey($key)) { return }
            $values=@{}
            foreach($field in $fields) {
                if ($field -eq 'PlannedRate' -and [string]::IsNullOrWhiteSpace($boxes[$field].Text)) { $values[$field]=$null; continue }
                $number=0.0
                if (-not [double]::TryParse($boxes[$field].Text,[ref]$number)) { throw "数値が不正です: $field" }
                if ($field -in @('Workdays','CompletedCount') -and ($number -lt 0 -or $number -ne [math]::Truncate($number))) { throw "整数で入力してください: $field" }
                if ($field -notin @('DifferenceHours') -and $number -lt 0) { throw "負数は入力できません: $field" }
                $values[$field]=$number
            }
            $old=$map[$key]; $before=ConvertTo-Json -InputObject $old -Depth 12
            $new=@{}; $oldObject=$before | ConvertFrom-Json; foreach($p in $oldObject.PSObject.Properties) { $new[$p.Name]=$p.Value }
            foreach($field in $fields) { $new[$field]=$values[$field] }
            $new['Revision']=[long]$old.Revision+1; $new['Source']='手動修正'
            $new['FinalizedAt']=(Get-Date).ToString('o')
            Backup-Data
            $map[$key]=$new; try { Write-MonthlySnapshots $map -ChangedMonth $key -ExpectedRevision ([long]$old.Revision) -Reason '手動修正' } catch { $map[$key]=$old; throw }

            & $load
            Update-AutoReports
            [System.Windows.Forms.MessageBox]::Show($dlg,'保存しました。Excelを再生成しました。','TaskPilot') | Out-Null
        } catch { Show-Failure $_ }
    })
    $close=New-Object System.Windows.Forms.Button; $close.Text='閉じる'; $close.SetBounds(660,540,150,34); $close.Add_Click({$dlg.Close()}); $dlg.Controls.Add($close)
    if ($picker.Items.Count -gt 0) { $picker.SelectedIndex=0 }
    [void]$dlg.ShowDialog($form); $dlg.Dispose()
}

function Add-AnalyticsExcelSheets([string]$path) {
    $cfg = Read-CapacitySettings
    $holidays = Get-CapacityHolidayKeys
    $actuals = Read-ActualHours
    $logs = @(Read-WorkLogs)
    $plans = Read-WorkPlans
    $tasks = @(Read-Tasks $TaskFile) + @(Read-Tasks $ArchiveFile)
    $unique = @{}
    $distinct = @()
    foreach ($t in $tasks) {
        if ($null -eq $t -or [string]::IsNullOrWhiteSpace([string]$t.ID)) { continue }
        $key = [string]$t.ID
        if (-not $unique.ContainsKey($key)) { $unique[$key]=$true; $distinct += $t }
    }
    $today = (Get-Date).Date
    $firstMonth = (Get-Date -Year $today.Year -Month $today.Month -Day 1).Date
    $months = @()
    $finalized = Read-MonthlySnapshots
    for ($i=11; $i -ge 0; $i--) {
        $month = $firstMonth.AddMonths(-$i)
        $capacity = Get-MonthCapacity $month $cfg $holidays
        $planned = Get-MonthPlanTotal $month $cfg $holidays
        $recorded = 0.0
        foreach ($log in $logs) {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse([string]$log.WorkDate,[ref]$d) -and $d.Year -eq $month.Year -and $d.Month -eq $month.Month) { $recorded += [double]$log.Hours }
        }
        $finished = 0.0
        foreach ($a in @($actuals.Values)) {
            $d = [datetime]::MinValue
            if ([datetime]::TryParse([string]$a.CompletedDate,[ref]$d) -and $d.Year -eq $month.Year -and $d.Month -eq $month.Month) { $finished += [double]$a.ActualHours }
        }
        $isCurrent = ($month.Year -eq $today.Year -and $month.Month -eq $today.Month)
        $remaining = if ($isCurrent) { Get-RemainingMonthCapacity $month $today $cfg $holidays } else { $null }
        $key=$month.ToString('yyyy/MM')
        $snapshot=$null
        if ($finalized.ContainsKey($key)) { $snapshot=$finalized[$key] }
        if ($null -ne $snapshot) {
            $capacity.Hours=[double]$snapshot.CapacityHours
            $planned=[double]$snapshot.PlannedHours
            $recorded=[double]$snapshot.LoggedHours
            $finished=[double]$snapshot.CompletedActualHours
        }
        $months += [pscustomobject]@{
            対象月=$month.ToString('yyyy/MM'); 稼働可能時間_h=[math]::Round($capacity.Hours,2)
            未完了予定工数_h=[math]::Round($planned,2)
            予定稼働率_pct=$(if ($null -ne $snapshot) { $snapshot.PlannedRate } elseif ($capacity.Hours -gt 0) { [math]::Round(100*$planned/$capacity.Hours,2) } else { $null })
            日別作業記録_h=[math]::Round($recorded,2)
            完了時申告実績_h=[math]::Round($finished,2)
            当月残り稼働可能時間_h=$(if ($isCurrent) { [math]::Round($remaining.Hours,2) } else { $null })
            当月追加受入目安_h=$(if ($isCurrent) { [math]::Round(($remaining.Hours-$planned),2) } else { $null })
            確定状態=$(if ($null -ne $snapshot) { '確定済み' } else { '未確定（参考）' })
        }
    }
    $months | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName '月別分析' -AutoSize -BoldTopRow -ErrorAction Stop
    $comparisons = @()
    foreach ($t in $distinct) {
        $id=[string]$t.ID
        $estimate=$null
        if ($plans.ContainsKey($id)) { $estimate=[double]$plans[$id].EstimatedHours }
        $logged=0.0
        foreach ($log in $logs) { if ([string]$log.TaskId -eq $id) { $logged += [double]$log.Hours } }
        $actual=$null; $doneDate=''
        if ($actuals.ContainsKey($id)) { $actual=[double]$actuals[$id].ActualHours; $doneDate=[string]$actuals[$id].CompletedDate }
        $comparisons += [pscustomobject]@{
            ID=$id; タスク名=[string]$t.Task; 状態=[string]$t.Status
            予定工数_h=$estimate; 日別作業記録_h=[math]::Round($logged,2)
            完了時申告実績_h=$actual
            予定対完了実績差_h=$(if ($null -ne $estimate -and $null -ne $actual) { [math]::Round(($actual-$estimate),2) } else { $null })
            完了日=$doneDate
        }
    }
    if ($comparisons.Count -eq 0) { $comparisons=@([pscustomobject]@{ ID=''; タスク名=''; 状態=''; 予定工数_h=$null; 日別作業記録_h=$null; 完了時申告実績_h=$null; 予定対完了実績差_h=$null; 完了日='' }) }
    $comparisons | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'タスク工数比較' -AutoSize -BoldTopRow -ErrorAction Stop
    $package = Open-TPGuiReportPackage -Path $path -ErrorAction Stop
    try {
        $ws = $package.Workbook.Worksheets['月別分析']
        $ws.View.FreezePanes(2,2)
        $ws.Cells['A1:I1'].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws.Cells['A1:I1'].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(30,58,90))
        $ws.Cells['A1:I1'].Style.Font.Color.SetColor([System.Drawing.Color]::White)
        $ws.Cells['B2:H13'].Style.Numberformat.Format = '0.00'
        $ws.Cells['J2'].Value = '集計上の注意'
        $ws.Cells['J3'].Value = '確定済み月は保存済みの数値を使用。未確定月は現在のデータから再計算した参考値です。'
        $ws.Cells['J4'].Value = '日別作業記録と完了時申告実績は別指標です。合算すると二重計上の可能性があります。'
        $ws.Cells['J5'].Value = '残り稼働時間と追加受入目安は当月のみ表示します。'
        $ws.Column(10).Width=100
        $chart = $ws.Drawings.AddChart('MonthlyUtilizationTrend',[OfficeOpenXml.Drawing.Chart.eChartType]::Line)
        $chart.Title.Text='月別 予定稼働率の推移（確定値／参考値）'
        [void]$chart.Series.Add($ws.Cells['D2:D13'],$ws.Cells['A2:A13'])
        $chart.SetPosition(15,0,0,0); $chart.SetSize(1100,400)
        $chart2 = $ws.Drawings.AddChart('MonthlyHours',[OfficeOpenXml.Drawing.Chart.eChartType]::ColumnClustered)
        $chart2.Title.Text='月別 稼働可能時間と日別作業記録'
        [void]$chart2.Series.Add($ws.Cells['B2:B13'],$ws.Cells['A2:A13'])
        [void]$chart2.Series.Add($ws.Cells['E2:E13'],$ws.Cells['A2:A13'])
        $chart2.SetPosition(38,0,0,0); $chart2.SetSize(1100,400)
        $compare = $package.Workbook.Worksheets['タスク工数比較']
        $compare.View.FreezePanes(2,3)
        $compare.Cells['A1:H1'].Style.Fill.PatternType=[OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $compare.Cells['A1:H1'].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(30,58,90))
        $compare.Cells['A1:H1'].Style.Font.Color.SetColor([System.Drawing.Color]::White)
        $compare.Cells['J2'].Value='途中進捗は日別作業記録の累計です。完了時申告実績とは別指標であり、合算しません。完了時申告実績がないタスクの差分は空欄です。'
        $compare.Column(10).Width=60
        $count=[math]::Min(20,$comparisons.Count)
        if ($count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$comparisons[0].ID)) {
            $last=1+$count
            $c=$compare.Drawings.AddChart('TaskEstimateVsActual',[OfficeOpenXml.Drawing.Chart.eChartType]::BarClustered)
            $c.Title.Text='タスク別 予定・途中進捗・完了実績（先頭20件）'
            $plannedSeries = $c.Series.Add($compare.Cells["D2:D$last"],$compare.Cells["B2:B$last"])
            $plannedSeries.Header = '予定工数'
            $progressSeries = $c.Series.Add($compare.Cells["E2:E$last"],$compare.Cells["B2:B$last"])
            $progressSeries.Header = '途中進捗（日別作業記録）'
            $actualSeries = $c.Series.Add($compare.Cells["F2:F$last"],$compare.Cells["B2:B$last"])
            $actualSeries.Header = '完了時申告実績'
            $c.SetPosition(3,0,10,0); $c.SetSize(1250,750)
        }
        Close-TPGuiReportPackage $package -ErrorAction Stop
    } catch {
        try { (Dispose-TPGuiReportPackage $package) } catch {}
        throw
    }
}

function Write-ExcelReport([bool]$dashboard, [string]$path) {
    $items = @(Read-Tasks $TaskFile)
    $archive = @(Read-Tasks $ArchiveFile)
    if (-not $dashboard) {
        $rows = if ($items.Count -gt 0) { $items } else { @([pscustomobject]@{ ID=''; Date=''; Task=''; Priority=''; DueDate=''; Status=''; Memo='' }) }
        Get-TaskExcelRows $rows | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'TaskList' -AutoSize -BoldTopRow -ErrorAction Stop
        Add-ExtendedExcelSheets $path
        Add-AnalyticsExcelSheets $path
        return
    }

    # 集計対象は未アーカイブとアーカイブ済みの両方。
    $all = @($items | Where-Object { $null -ne $_ })
    $all += @($archive | Where-Object { $null -ne $_ })
    $today = (Get-Date).Date
    $soonEnd = $today.AddDays(3)
    $overdue = 0
    $soon = 0
    foreach ($task in $items) {
        if ($task.Status -eq '完了') { continue }
        $due = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$task.DueDate,'yyyy/MM/dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$due)) { continue }
        if ($due.Date -lt $today) { $overdue++ }
        elseif ($due.Date -le $soonEnd) { $soon++ }
    }
    $done = @($all | Where-Object { $_.Status -eq '完了' }).Count
    $total = $all.Count
    $rate = if ($total -gt 0) { [math]::Round(100.0 * $done / $total,1) } else { 0 }
    $summary = @('未着手','対応中','完了') | ForEach-Object {
        $status = $_
        [pscustomobject]@{ Status=$status; Count=@($all | Where-Object { $_.Status -eq $status }).Count }
    }
    $priorities = @('高','中','低') | ForEach-Object {
        $priority = $_
        [pscustomobject]@{ Priority=$priority; Count=@($items | Where-Object { $_.Priority -eq $priority -and $_.Status -ne '完了' }).Count }
    }
    # 一つのシートに集計値を配置し、グラフは集計セルを参照する。
    $package = $summary | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'Dashboard' -StartRow 4 -StartColumn 1 -AutoSize -BoldTopRow -PassThru
    try {
        $ws = $package.Workbook.Worksheets['Dashboard']
        $ws.Cells['A1'].Value = 'タスク管理ダッシュボード'
        $ws.Cells['A2'].Value = '集計日時'
        $ws.Cells['B2'].Value = (Get-Date).ToString('yyyy/MM/dd HH:mm')
        $ws.Cells['D4'].Value = '指標'
        $ws.Cells['E4'].Value = '値'
        $metrics = @(
            [pscustomobject]@{ Label='全タスク数'; Value=$total }
            [pscustomobject]@{ Label='完了数'; Value=$done }
            [pscustomobject]@{ Label='完了率 (%)'; Value=$rate }
            [pscustomobject]@{ Label='期限切れ'; Value=$overdue }
            [pscustomobject]@{ Label='期限間近 (今日～3日後)'; Value=$soon }
        )
        for ($i=0; $i -lt $metrics.Count; $i++) {
            $row = 5 + $i
            $ws.Cells[$row,4].Value = [string]$metrics[$i].Label
            $ws.Cells[$row,5].Value = [double]$metrics[$i].Value
        }
        $ws.Cells['G4'].Value = '優先度'
        $ws.Cells['H4'].Value = '未完了件数'
        for ($i=0; $i -lt $priorities.Count; $i++) {
            $row = 5 + $i
            $ws.Cells[$row,7].Value = [string]$priorities[$i].Priority
            $ws.Cells[$row,8].Value = [int]$priorities[$i].Count
        }
        $ws.Cells['D11'].Value = '期限切れ: 昨日以前の未完了タスク'
        $ws.Cells['D12'].Value = '期限間近: 今日から3日後までの未完了タスク'
        $ws.Cells['D13'].Value = '完了率: アーカイブ済みを含む全タスクに対する完了割合'
        $ws.Cells['D14'].Value = '優先度別: アーカイブ済み・完了済みを除外'
        # Visual KPI cards: numeric values are already in E5:E9.
        $ws.Cells['D5:E9'].Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Hair
        $ws.Cells['E5:E9'].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
        $ws.Cells['E5:E9'].Style.Font.Size = 16
        $ws.Cells['E5:E9'].Style.Font.Bold = $true
        $ws.Cells['D16'].Value = '期限切れタスク一覧'
        $ws.Cells['D16:G16'].Merge = $true
        foreach ($header in @('ID','タスク','期限','優先度')) {
            $col = 4 + @('ID','タスク','期限','優先度').IndexOf($header)
            $ws.Cells[17,$col].Value = $header
        }
        $ws.Cells['D16:G16'].Style.Font.Bold = $true
        $ws.Cells['D17:G17'].Style.Font.Bold = $true
        $ws.Cells['E18:E200'].Style.WrapText = $true
        $ws.Cells['D17:G17'].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws.Cells['D17:G17'].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::MistyRose)
        $row = 18
        foreach ($task in $items) {
            if ($task.Status -eq '完了') { continue }
            $due = [datetime]::MinValue
            if (-not [datetime]::TryParseExact([string]$task.DueDate,'yyyy/MM/dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$due)) { continue }
            if ($due.Date -ge $today) { continue }
            $ws.Cells[$row,4].Value = [string]$task.ID
            $ws.Cells[$row,5].Value = [string]$task.Task
            $ws.Cells[$row,6].Value = [string]$task.DueDate
            $ws.Cells[$row,7].Value = [string]$task.Priority
            $row++
        }
        if ($row -eq 18) { $ws.Cells['D18'].Value = '期限切れなし' }
        $ws.Cells['A1:C1'].Merge = $true
        $ws.Cells['A1'].Style.Font.Bold = $true
        $ws.Cells['A1'].Style.Font.Size = 20
        $ws.View.ZoomScale = 100
        foreach ($range in @('A4:B4','D4:E4','G4:H4')) {
            $ws.Cells[$range].Style.Font.Bold = $true
            $ws.Cells[$range].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $ws.Cells[$range].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::LightSteelBlue)
        }
        $ws.Column(1).Width = 22
        $ws.Column(3).Width = 4
        $ws.Column(6).Width = 18
        $ws.Column(2).Width = 17
        $ws.Column(4).Width = 29
        $ws.Column(5).Width = 16
        $ws.Column(7).Width = 18
        $ws.Column(8).Width = 18
        $ws.Cells['E7'].Style.Numberformat.Format = '0.0"%"'
        # Highlight overdue / upcoming counts and completion rate.
        $ws.Cells['E7'].Style.Font.Bold = $true
        $ws.Cells['E7'].Style.Font.Size = 16
        $ws.Cells['E8'].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws.Cells['E8'].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::MistyRose)
        $ws.Cells['E8'].Style.Font.Color.SetColor([System.Drawing.Color]::DarkRed)
        $ws.Cells['E9'].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws.Cells['E9'].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::LightYellow)
        $ws.Cells['E9'].Style.Font.Color.SetColor([System.Drawing.Color]::DarkGoldenrod)

        # データが0件のときは円グラフを作らない（Excelの空グラフを防止）。
        if ($total -gt 0) {
            $chart = $ws.Drawings.AddChart('StatusPie', [OfficeOpenXml.Drawing.Chart.eChartType]::Pie)
            $chart.Title.Text = 'ステータス別の割合'
            $chart.SetPosition([Math]::Max(22, $row + 2) - 1,0,0,0)
            $chart.SetSize(320,210)
            $series = $chart.Series.Add($ws.Cells['B5:B7'], $ws.Cells['A5:A7'])
            $series.Header = 'タスク件数'
            $chart.Legend.Position = [OfficeOpenXml.Drawing.Chart.eLegendPosition]::Right
        }
        # Priority bar chart: only outstanding tasks.
        $priorityChart = $ws.Drawings.AddChart('PriorityBar', [OfficeOpenXml.Drawing.Chart.eChartType]::BarClustered)
        $priorityChart.Title.Text = '未完了タスクの優先度別件数'
        $priorityChart.SetPosition([Math]::Max(22, $row + 2) - 1,0,4,0)
        $priorityChart.SetSize(340,210)
        $prioritySeries = $priorityChart.Series.Add($ws.Cells['H5:H7'], $ws.Cells['G5:G7'])
        $prioritySeries.Header = '未完了件数'
        $priorityChart.Legend.Remove()
        (Save-TPGuiReportPackage $package)
    } finally { (Dispose-TPGuiReportPackage $package) }
    if ($items.Count -gt 0) { $items | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'TaskList' -AutoSize -BoldTopRow }
    if ($archive.Count -gt 0) { $archive | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'CompletedTask' -AutoSize -BoldTopRow }
}



# Reports are derived artifacts; CSV files remain the authoritative data store.
$script:ReportsNeedRefresh = $true
$script:ReportError = ''

function Write-CompletedReport([string]$path) {
    $current = @(Read-Tasks $TaskFile | Where-Object { $_.Status -eq '完了' })
    $historic = @(Read-Tasks $ArchiveFile | Where-Object { $_.Status -eq '完了' })
    $seen = @{}
    $completed = @()
    foreach ($task in @($historic) + @($current)) {
        $key = [string]$task.ID
        if (-not $seen.ContainsKey($key)) { $completed += $task; $seen[$key] = $true }
    }
    if ($completed.Count -eq 0) {
        $completed = @([pscustomobject]@{ ID=''; Date=''; Task=''; Priority=''; DueDate=''; Status=''; Memo='' })
    }
    Get-TaskExcelRows $completed | ConvertTo-SafeExcelRows | Export-TPGuiReportRows -Path $path -WorksheetName 'CompletedTask' -AutoSize -BoldTopRow -ErrorAction Stop
}










# STEP 3.5A: Subtasks are stored independently; existing task CSV format is unchanged.
$script:SubtaskFile = Join-Path $DataDir 'Subtasks.json'


function Get-SubtaskProgress([string]$parentId) {
    $children = @(Read-Subtasks | Where-Object { [string]$_.ParentId -eq $parentId })
    if ($children.Count -eq 0) { return 'サブタスク: なし' }
    $done = @($children | Where-Object { [bool]$_.Done }).Count
    return "サブタスク: $done/$($children.Count) 完了 ($([math]::Round(100*$done/$children.Count))%)"
}
function Show-SubtasksDialog($parent) {
    if ($null -eq $parent) { return }
    $parentId = [string]$parent.ID
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "サブタスク管理 - [$parentId] $($parent.Task)"
    $dlg.Size = New-Object System.Drawing.Size(730,490)
    $dlg.MinimumSize = New-Object System.Drawing.Size(620,390)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(13,20,34)
    $dlg.ForeColor = [System.Drawing.Color]::White
    $heading = New-Object System.Windows.Forms.Label
    $heading.SetBounds(16,12,680,32)
    $heading.Anchor = 'Top,Left,Right'
    $heading.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
    $dlg.Controls.Add($heading)
    $list = New-Object System.Windows.Forms.ListView
    $list.SetBounds(16,52,680,290)
    $list.Anchor = 'Top,Bottom,Left,Right'
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false
    $list.CheckBoxes = $true
    $list.BackColor = [System.Drawing.Color]::FromArgb(22,33,51)
    $list.ForeColor = [System.Drawing.Color]::White
    [void]$list.Columns.Add('サブタスク',500)
    [void]$list.Columns.Add('状態',130)
    $dlg.Controls.Add($list)
    $subtaskNameBox = New-Object System.Windows.Forms.TextBox
    $subtaskNameBox.SetBounds(16,354,380,29)
    $subtaskNameBox.Anchor = 'Bottom,Left,Right'
    $dlg.Controls.Add($subtaskNameBox)
    $add = New-Object System.Windows.Forms.Button
    $add.Text = '＋ 追加'; $add.SetBounds(405,353,90,31); $add.Anchor = 'Bottom,Right'
    $dlg.Controls.Add($add)
    $delete = New-Object System.Windows.Forms.Button
    $delete.Text = '選択を削除'; $delete.SetBounds(502,353,100,31); $delete.Anchor = 'Bottom,Right'
    $dlg.Controls.Add($delete)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = '閉じる'; $close.SetBounds(608,353,88,31); $close.Anchor = 'Bottom,Right'
    $dlg.Controls.Add($close)
    $script:SubtaskListRefreshing = $false
    $refresh = {
        $script:SubtaskListRefreshing = $true
        try {
            $list.Items.Clear()
            $children = @(Read-Subtasks | Where-Object { [string]$_.ParentId -eq $parentId })
            foreach ($child in $children) {
                $entry = New-Object System.Windows.Forms.ListViewItem([string]$child.Title)
                $entry.Tag = [string]$child.Id
                $entry.Checked = [bool]$child.Done
                [void]$entry.SubItems.Add($(if ([bool]$child.Done) { '完了' } else { '未完了' }))
                [void]$list.Items.Add($entry)
            }
            $heading.Text = Get-SubtaskProgress $parentId
        } finally { $script:SubtaskListRefreshing = $false }
    }
    $add.Add_Click({
        try {
            $title = $subtaskNameBox.Text.Trim()
            if (-not $title) { return }
            if ($title.Length -gt 200) { throw 'サブタスク名は200文字以内にしてください。' }
            $all = @(Read-Subtasks)
            $new = [pscustomobject]@{ Id=[guid]::NewGuid().ToString('N'); ParentId=$parentId; Title=$title; Done=$false }
            Save-Subtasks @($all + @($new)) -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')
            $subtaskNameBox.Clear()
            & $refresh
            Refresh-Details
        } catch { Show-Failure $_ }
    })
    $list.Add_ItemChecked({
        param($sender,$e)
        if ($script:SubtaskListRefreshing) { return }
        try {
            $all = @(Read-Subtasks)
            foreach ($child in $all) { if ([string]$child.Id -eq [string]$e.Item.Tag) { $child.Done = [bool]$e.Item.Checked } }
            Save-Subtasks $all -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')
            & $refresh
            Refresh-Details
        } catch { Show-Failure $_; & $refresh }
    })
    $delete.Add_Click({
        try {
            if ($list.SelectedItems.Count -eq 0) { return }
            $id = [string]$list.SelectedItems[0].Tag
            if (-not (Ask-Confirm '選択したサブタスクを削除しますか？')) { return }
            $all = @(Read-Subtasks | Where-Object { [string]$_.Id -ne $id })
            Save-Subtasks $all -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')
            & $refresh
            Refresh-Details
        } catch { Show-Failure $_ }
    })
    $close.Add_Click({ $dlg.Close() })
    & $refresh
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    Refresh-Details
}

function Refresh-SubtaskPreview($task) {
    if ($null -eq $script:subtaskPreviewList) { return }
    $script:subtaskPreviewBusy = $true
    try {
        $script:subtaskPreviewList.Items.Clear()
        if ($null -eq $task) {
            $script:subtaskPreviewHeading.Text = 'サブタスク（タスクを選択してください）'
            return
        }
        $children = @(Read-Subtasks | Where-Object { [string]$_.ParentId -eq [string]$task.ID })
        $done = @($children | Where-Object { [bool]$_.Done }).Count
        $rate = if ($children.Count -gt 0) { [math]::Round(100 * $done / $children.Count) } else { 0 }
        $script:subtaskPreviewHeading.Text = "サブタスク  $done/$($children.Count) 完了 ($rate%)"
        foreach ($child in $children) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$child.Title)
            $item.Tag = [string]$child.Id
            $item.Checked = [bool]$child.Done
            [void]$script:subtaskPreviewList.Items.Add($item)
        }
    } finally { $script:subtaskPreviewBusy = $false }
}

function Refresh-Details {
    if ($null -eq $detailValue) { return }
    $task = Selected-Task
    Refresh-SubtaskPreview $task
    if ($null -eq $task) {
        $detailValue.Text = 'タスクを選択すると詳細が表示されます。'
        return
    }
    $plannedText = Get-PlannedDate ([string]$task.ID)
    $workPlan = Get-WorkPlan ([string]$task.ID)
    $startText = if ($null -ne $workPlan -and $workPlan.StartDate) { [string]$workPlan.StartDate } else { '未設定' }
    $hoursText = if ($null -ne $workPlan) { [string]$workPlan.EstimatedHours } else { '0' }
    $detailValue.Text = "ID: $($task.ID)    タスク: $($task.Task)`r`n優先度: $($task.Priority)    実施予定日: $plannedText    期限: $($task.DueDate)    状態: $($task.Status)`r`n作業開始日: $startText    予定所要時間: $hoursText 時間`r`n備考: $($task.Memo)`r`n$(Get-SubtaskProgress ([string]$task.ID))"
}
function Update-RecurringPreview {
    if ($null -eq $script:recurringPreview) { return }
    try {
        $today = (Get-Date).Date
        $upcoming = @()
        $unavailable = 0
        foreach ($rule in @(Read-RecurringRules)) {
            if (-not [bool]$rule.Enabled) { continue }
            try {
                $date = Get-NextRecurringDate $rule $today
                if ($null -ne $date) {
                    $upcoming += [pscustomobject]@{ Date=$date; Name=[string]$rule.Name }
                } else { $unavailable++ }
            } catch {
                $unavailable++
                Write-ActionLog '次回予定の計算保留' ("$($rule.Name): $($_.Exception.Message)")
            }
        }
        $upcoming = @($upcoming | Sort-Object Date,Name)
        if ($upcoming.Count -eq 0) {
            $message = if ($unavailable -gt 0) { '次回の定期タスク：日付を確認できません（祝日データ・ルールを確認）' } else { '次回の定期タスク：予定なし' }
        } else {
            $parts = @($upcoming | Select-Object -First 3 | ForEach-Object { $_.Date.ToString('MM/dd') + ' ' + $_.Name })
            $message = '次回の定期タスク：' + ($parts -join '  /  ')
            if ($upcoming.Count -gt 3) { $message += "  ほか $($upcoming.Count-3) 件" }
            if ($unavailable -gt 0) { $message += "  ※日付未確認 $unavailable 件" }
        }
        $script:recurringPreview.Text = $message
        $script:recurringPreview.AccessibleDescription = $message
    } catch {
        $script:recurringPreview.Text = '次回の定期タスク：確認できません（設定を確認）'
        Write-ActionLog '次回予定の表示失敗' $_.Exception.Message
    }
}
function Refresh-List {
    $selectedId = $null
    if ($null -ne $grid.CurrentRow -and -not $grid.CurrentRow.IsNewRow) { $selectedId = [string]$grid.CurrentRow.Cells['ID'].Value }
    $grid.Rows.Clear()
    $items = @(Read-Tasks $TaskFile)
    $today = (Get-Date).Date
    $overdue = 0; $soon = 0; $completed = 0
    foreach ($task in $items) {
        if ($task.Status -eq '完了') { $completed++; continue }
        $due = Get-ValidDueDate $task
        if ($null -eq $due) { continue }
        if ($due -lt $today) { $overdue++ }
        elseif ($due -le $today.AddDays(3)) { $soon++ }
    }
    $sortIndex = $sortBox.SelectedIndex
    switch ($sortIndex) {
        1 { $items = @($items | Sort-Object @{Expression={ $d=Get-ValidDueDate $_; if ($null -eq $d) { [datetime]::MaxValue } else { $d } }}, @{Expression={ [int]$_.ID }}) }
        2 { $items = @($items | Sort-Object @{Expression={ Get-PriorityRank ([string]$_.Priority) }}, @{Expression={ [int]$_.ID }}) }
        3 { $items = @($items | Sort-Object @{Expression={ switch ($_.Status) { '未着手' {0} '対応中' {1} '完了' {2} default {3} } }}, @{Expression={ [int]$_.ID }}) }
        default { $items = @($items | Sort-Object @{Expression={ [int]$_.ID }}) }
    }
    $search = $searchBox.Text.Trim()
    $restoreRow = -1
    foreach ($task in $items) {
        if ($search -and (([string]$task.Task).IndexOf($search,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) -and (([string]$task.Memo).IndexOf($search,[System.StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        if ($filterBox.SelectedIndex -eq 1 -and $task.Status -ne '未着手') { continue }
        if ($filterBox.SelectedIndex -eq 2 -and $task.Status -ne '対応中') { continue }
        if ($filterBox.SelectedIndex -eq 3 -and $task.Status -ne '完了') { continue }
        if ($filterBox.SelectedIndex -eq 4 -and $task.Priority -ne '高') { continue }
        $idx = $grid.Rows.Add([string]$task.ID,[string]$task.Task,[string]$task.Priority,[string]$task.DueDate,[string]$task.Status,[string]$task.Memo)
        if ([string]$task.ID -eq $selectedId) { $restoreRow = $idx }
    }
    $grid.ClearSelection()
    if ($restoreRow -ge 0) { $grid.Rows[$restoreRow].Selected = $true; $grid.CurrentCell = $grid.Rows[$restoreRow].Cells[1] }
    elseif ($grid.Rows.Count -gt 0) { $grid.CurrentCell = $grid.Rows[0].Cells[1] }
    if ($null -ne $calendarView -and $calendarView.Visible) { Update-TaskCalendar }
    $summary.Text = "全 $($items.Count) 件  |  期限切れ $overdue 件  |  期限間近 $soon 件"
    $cardAll.Text = "全タスク`r`n$($items.Count) 件"
    $cardOpen.Text = "未完了`r`n$($items.Count - $completed) 件"
    $cardOverdue.Text = "期限切れ`r`n$overdue 件"
    $cardDone.Text = "完了`r`n$completed 件"
    $urgent = @($items | Where-Object {
        if ($_.Status -eq '完了') { return $false }
        $d = Get-ValidDueDate $_
        return ($null -ne $d -and $d -le $today)
    } | Sort-Object @{Expression={ Get-ValidDueDate $_ }}, @{Expression={ [int]$_.ID }})
    if ($urgent.Count -eq 0) { $todayValue.Text = '対象なし' }
    else {
        $preview = @($urgent | Select-Object -First 3 | ForEach-Object { "[$($_.ID)] $($_.Task) ($($_.DueDate))" })
        $suffix = if ($urgent.Count -gt 3) { "  ほか $($urgent.Count - 3) 件" } else { '' }
        $todayValue.Text = "対象 $($urgent.Count) 件：" + ($preview -join '  /  ') + $suffix
    }
    Refresh-Details
    Update-ActionButtons
    Update-RecurringPreview
    Update-TopCapacity
}
function Selected-Task {
    if ($null -eq $grid.CurrentRow -or $grid.CurrentRow.IsNewRow) { return $null }
    $id = [string]$grid.CurrentRow.Cells[0].Value
    return @(Read-Tasks $TaskFile | Where-Object { [string]$_.ID -eq $id }) | Select-Object -First 1
}


$form = New-Object System.Windows.Forms.Form
$form.Text = 'TaskPilot - SQLite統合 開発候補版'
$form.Size = New-Object System.Drawing.Size(1120,760)
$form.MinimumSize = New-Object System.Drawing.Size(850,500)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 6
$layout.Margin = New-Object System.Windows.Forms.Padding(0)
$layout.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100)))
foreach ($height in @(50,112,84,112)) {
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,[single]$height)))
}
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,[single]200)))
$form.Controls.Add($layout)

$script:MenuActions = @{}
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Fill'
$panel.Height = 112
$panel.Padding = New-Object System.Windows.Forms.Padding(8,7,0,0)
$panel.WrapContents = $true
$layout.Controls.Add($panel,0,1)
function Add-Button([string]$label,[scriptblock]$action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $label
    $b.AutoSize = $true
    $b.Height = 32
    $b.Margin = New-Object System.Windows.Forms.Padding(3,0,5,0)
    $b.Add_Click($action)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(54,78,111)
    $b.BackColor = [System.Drawing.Color]::FromArgb(27,43,65)
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:MenuActions[$label] = $action
    if ($label -eq '＋ 追加') { $panel.Controls.Add($b) }
    return $b
}
[void](Add-Button '＋ 追加' {
    try {
        $value = New-TaskDialog $null
        if ($null -eq $value) { return }
        $id = Add-TPGuiTaskFromDialog $value
        Write-ActionLog '追加' ("ID=$id")
        Refresh-List
    } catch { Show-Failure $_ }
})
$script:editButton = Add-Button '編集' {
    try {
        $task = Selected-Task
        if ($null -eq $task) { return }
        $value = New-TaskDialog $task
        if ($null -ne $value) { Save-EditedTask $task $value }
    } catch { Show-Failure $_ }
}
$script:completeButton = Add-Button '完了' {
    try {
        $task = Selected-Task
        if ($null -eq $task) { return }
        if ($task.Status -eq '完了') { return }
        $value = [pscustomobject]@{Task=$task.Task;Priority=$task.Priority;DueDate=$task.DueDate;Status='完了';Memo=$task.Memo}
        Save-EditedTask $task $value
    } catch { Show-Failure $_ }
}
$script:deleteButton = Add-Button '削除' {
    try {
        $task = Selected-Task
        if ($null -eq $task) { return }
        if (-not (Ask-Confirm "ID $($task.ID) : $($task.Task) を削除しますか？`r`n関連サブタスクは保持されます（復元用）。")) { return }
        Remove-TPGuiSelectedTask $task
        Refresh-List
    } catch { Show-Failure $_ }
}
# STEP 3.2.1: Report buttons open already-generated Excel files.
$completedReportButton = Add-Button '完了タスクを開く' { try { Open-AutoReport 'CompletedTask.xlsx' } catch { Show-Failure $_ } }
$taskListReportButton = Add-Button 'タスク一覧を開く' { try { Open-AutoReport 'TaskList.xlsx' } catch { Show-Failure $_ } }
$dashboardReportButton = Add-Button 'ダッシュボードを開く' { try { Open-AutoReport 'Dashboard.xlsx' } catch { Show-Failure $_ } }
$reportToolTip = New-Object System.Windows.Forms.ToolTip
$reportToolTip.InitialDelay = 450
$reportToolTip.ReshowDelay = 150
$reportToolTip.AutoPopDelay = 7000
$reportToolTip.ShowAlways = $true
$reportToolTip.SetToolTip($completedReportButton, '完了済みタスクのExcelファイルを開きます。')
$reportToolTip.SetToolTip($taskListReportButton, '最新のタスク一覧のExcelファイルを開きます。')
$reportToolTip.SetToolTip($dashboardReportButton, '最新の集計ダッシュボードのExcelファイルを開きます。')
[void](Add-Button 'サブタスク管理' { try { Show-SubtasksDialog (Selected-Task) } catch { Show-Failure $_ } })
[void](Add-Button '定期タスク管理' { try { Show-RecurringRulesDialog } catch { Show-Failure $_ } })
[void](Add-Button 'バックアップ復元' { try { Restore-GuiBackup } catch { Show-Failure $_ } })
[void](Add-Button '更新' { try { Refresh-List } catch { Show-Failure $_ } })
[void](Add-Button 'Excelを再出力' { try { Update-AutoReports; if ($script:ReportsNeedRefresh) { [System.Windows.Forms.MessageBox]::Show("Excelを更新できませんでした。`r`n$script:ReportError",'Excel出力エラー') | Out-Null } else { [System.Windows.Forms.MessageBox]::Show('Excelレポートを更新しました。','Excel更新完了') | Out-Null } } catch { Show-Failure $_ } })
[void](Add-Button '設定' { try { Show-SettingsDialog } catch { Show-Failure $_ } })
[void](Add-Button '月間稼働状況' { try { Show-MonthlyCapacityDialog } catch { Show-Failure $_ } })
[void](Add-Button '稼働カレンダー設定' { try { Show-CapacitySettingsDialog } catch { Show-Failure $_ } })
[void](Add-Button '作業実績（日別）' { try { Show-WorkLogDialog } catch { Show-Failure $_ } })
[void](Add-Button '月次確定データ管理' { try { Show-MonthlySnapshotsDialog } catch { Show-Failure $_ } })
[void](Add-Button '完了実績入力' { try { Show-ActualHoursDialog } catch { Show-Failure $_ } })
# Compact grouped navigation. Keep the primary Add button visible.
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.Dock = 'Top'
$menuStrip.BackColor = [System.Drawing.Color]::FromArgb(27,43,65)
$menuStrip.ForeColor = [System.Drawing.Color]::White
$menuStrip.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
function Add-TaskPilotMenu([string]$title,[string[]]$labels) {
    $parent = New-Object System.Windows.Forms.ToolStripMenuItem($title)
    foreach ($label in $labels) {
        $entry = New-Object System.Windows.Forms.ToolStripMenuItem($label)
        $action = $script:MenuActions[$label]
        $entry.Add_Click($action)
        [void]$parent.DropDownItems.Add($entry)
        if ($label -eq '編集') { $script:menuEdit = $entry }
        if ($label -eq '完了') { $script:menuComplete = $entry }
        if ($label -eq '削除') { $script:menuDelete = $entry }
    }
    [void]$menuStrip.Items.Add($parent)
}
Add-TaskPilotMenu 'タスク操作 ▼' @('編集','完了','削除','サブタスク管理','作業実績（日別）','更新')
Add-TaskPilotMenu 'ファイル表示 ▼' @('完了タスクを開く','タスク一覧を開く','ダッシュボードを開く','Excelを再出力')
Add-TaskPilotMenu '定期タスク ▼' @('定期タスク管理')
$holidayMenu = New-Object System.Windows.Forms.ToolStripMenuItem('祝日・休業日管理')
$holidayMenu.Add_Click({ try { Show-HolidayManagementDialog; Update-RecurringPreview } catch { Show-Failure $_ } })
[void]$menuStrip.Items[2].DropDownItems.Add($holidayMenu)
Add-TaskPilotMenu '設定・管理 ▼' @('設定','バックアップ復元','稼働カレンダー設定','月間稼働状況','月次確定データ管理','完了実績入力')
$notificationMenu = New-Object System.Windows.Forms.ToolStripMenuItem('通知 ▼')
$manualNotifyItem = New-Object System.Windows.Forms.ToolStripMenuItem('通知を手動確認')
$manualNotifyItem.Add_Click({ try { Show-TaskPilotAlertPopup $true } catch { Show-Failure $_ } })
[void]$notificationMenu.DropDownItems.Add($manualNotifyItem)
$historyNotifyItem = New-Object System.Windows.Forms.ToolStripMenuItem('通知履歴')
$historyNotifyItem.Add_Click({ try { Show-NotificationHistory } catch { Show-Failure $_ } })
[void]$notificationMenu.DropDownItems.Add($historyNotifyItem)
[void]$menuStrip.Items.Add($notificationMenu)
$panel.Controls.Add($menuStrip)
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Fill'
$bar.Height = 50
$layout.Controls.Add($bar,0,0)
$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = '検索'
$searchLabel.SetBounds(15,12,40,25)
$bar.Controls.Add($searchLabel)
$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.SetBounds(60,8,225,27)
$bar.Controls.Add($searchBox)
$filterBox = New-Object System.Windows.Forms.ComboBox
$filterBox.SetBounds(300,8,145,27)
$filterBox.DropDownStyle = 'DropDownList'
[void]$filterBox.Items.AddRange([object[]]@('すべて','未着手','対応中','完了','優先度：高'))
$filterBox.SelectedIndex = 0
$bar.Controls.Add($filterBox)
$sortBox = New-Object System.Windows.Forms.ComboBox
$sortBox.SetBounds(460,8,160,27)
$sortBox.DropDownStyle = 'DropDownList'
[void]$sortBox.Items.AddRange([object[]]@('ID順','期限が近い順','優先度が高い順','ステータス順'))
$sortBox.SelectedIndex = 0
$bar.Controls.Add($sortBox)
$summary = New-Object System.Windows.Forms.Label
$summary.AutoSize = $true
$summary.Location = New-Object System.Drawing.Point(635,12)
$bar.Controls.Add($summary)
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.Margin = New-Object System.Windows.Forms.Padding(0)
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
foreach ($column in @(@('ID','ID'),@('Task','タスク名'),@('Priority','優先度'),@('DueDate','期限'),@('Status','状態'),@('Memo','備考'))) {
    [void]$grid.Columns.Add($column[0],$column[1])
}
$grid.Columns['ID'].FillWeight = 35
$grid.Columns['Task'].FillWeight = 180
$grid.Columns['Memo'].FillWeight = 160
# STEP 3.4A: share the task-list area with a read-only monthly calendar.
$viewHost = New-Object System.Windows.Forms.Panel
$viewHost.Dock = 'Fill'
$viewHost.Controls.Add($grid)
$layout.Controls.Add($viewHost,0,4)
$calendarView = New-Object System.Windows.Forms.Panel
$calendarView.Dock = 'Fill'
$calendarView.Visible = $false
$calendarView.BackColor = [System.Drawing.Color]::FromArgb(13,20,34)
$viewHost.Controls.Add($calendarView)
$calendarHeader = New-Object System.Windows.Forms.Panel
$calendarHeader.Dock = 'Top'
$calendarHeader.Height = 43
$calendarView.Controls.Add($calendarHeader)
$calendarMonthLabel = New-Object System.Windows.Forms.Label
$calendarMonthLabel.SetBounds(130,8,165,30)
$calendarMonthLabel.ForeColor = [System.Drawing.Color]::White
$calendarHeader.Controls.Add($calendarMonthLabel)
$calendarPrev = New-Object System.Windows.Forms.Button
$calendarPrev.Text = '前月へ'
$calendarPrev.SetBounds(8,5,105,30)
$calendarPrev.UseVisualStyleBackColor = $false
$calendarPrev.FlatStyle = 'Flat'
$calendarPrev.BackColor = [System.Drawing.Color]::FromArgb(38,64,93)
$calendarPrev.ForeColor = [System.Drawing.Color]::White
$calendarPrev.Font = New-Object System.Drawing.Font('Yu Gothic UI',10,[System.Drawing.FontStyle]::Bold)
$calendarHeader.Controls.Add($calendarPrev)
$calendarNext = New-Object System.Windows.Forms.Button
$calendarNext.Text = '翌月へ'
$calendarNext.SetBounds(310,5,105,30)
$calendarNext.UseVisualStyleBackColor = $false
$calendarNext.FlatStyle = 'Flat'
$calendarNext.BackColor = [System.Drawing.Color]::FromArgb(38,64,93)
$calendarNext.ForeColor = [System.Drawing.Color]::White
$calendarNext.Font = New-Object System.Drawing.Font('Yu Gothic UI',10,[System.Drawing.FontStyle]::Bold)
$calendarHeader.Controls.Add($calendarNext)
$calendarToday = New-Object System.Windows.Forms.Button
$calendarToday.Text = '今月に戻る'
$calendarToday.SetBounds(428,5,125,30)
$calendarToday.UseVisualStyleBackColor = $false
$calendarToday.FlatStyle = 'Flat'
$calendarToday.BackColor = [System.Drawing.Color]::FromArgb(38,64,93)
$calendarToday.ForeColor = [System.Drawing.Color]::White
$calendarToday.Font = New-Object System.Drawing.Font('Yu Gothic UI',10,[System.Drawing.FontStyle]::Bold)
$calendarHeader.Controls.Add($calendarToday)
$calendarDays = New-Object System.Windows.Forms.TableLayoutPanel
$calendarDays.Dock = 'Fill'
$calendarDays.ColumnCount = 7
$calendarDays.RowCount = 7
$calendarDays.Padding = New-Object System.Windows.Forms.Padding(4)
for ($i=0; $i -lt 7; $i++) { [void]$calendarDays.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,[single](100.0/7)))) }
for ($i=0; $i -lt 7; $i++) { [void]$calendarDays.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,[single](100.0/7)))) }
$calendarView.Controls.Add($calendarDays)
$calendarDays.BringToFront()
$script:calendarMonth = (Get-Date).Date.AddDays(1-(Get-Date).Day)
# STEP 3.4C: Calendar actions use the same save paths as the main task form.
function Show-CalendarDay([datetime]$date) {
    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = ('{0:yyyy/MM/dd} のタスク' -f $date)
    $popup.Size = New-Object System.Drawing.Size(680,430)
    $popup.MinimumSize = New-Object System.Drawing.Size(570,340)
    $popup.StartPosition = 'CenterParent'
    $popup.BackColor = [System.Drawing.Color]::FromArgb(22,33,51)
    $popup.ForeColor = [System.Drawing.Color]::White
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'
    $list.Font = New-Object System.Drawing.Font('Yu Gothic UI',11)
    $list.BackColor = [System.Drawing.Color]::FromArgb(31,46,67)
    $list.ForeColor = [System.Drawing.Color]::White
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'
    $bar.Height = 53
    $bar.Padding = New-Object System.Windows.Forms.Padding(8)
    $add = New-Object System.Windows.Forms.Button
    $add.Text = '＋ この日に追加'
    $add.Width = 160
    $edit = New-Object System.Windows.Forms.Button
    $edit.Text = '選択したタスクを編集'
    $edit.Width = 180
    $close = New-Object System.Windows.Forms.Button
    $close.Text = '閉じる'
    $close.Width = 90
    foreach ($button in @($add,$edit,$close)) {
        $button.Height = 30
        $button.BackColor = [System.Drawing.Color]::FromArgb(35,75,116)
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatStyle = 'Flat'
        [void]$bar.Controls.Add($button)
    }
    $popup.Controls.Add($list)
    $popup.Controls.Add($bar)
    $script:calendarDayTaskMap = @{}
    $reload = {
        $list.Items.Clear()
        $script:calendarDayTaskMap = @{}
        $plans = Read-PlannedDates
        $tasks = @(Read-Tasks $TaskFile | Where-Object {
            $d = Get-ValidDueDate $_
            ($null -ne $d -and $d.Date -eq $date.Date) -or ($plans.ContainsKey([string]$_.ID) -and $plans[[string]$_.ID] -eq $date.ToString('yyyy/MM/dd'))
        })
        foreach ($task in $tasks) {
            $isPlanned = $plans.ContainsKey([string]$task.ID) -and $plans[[string]$task.ID] -eq $date.ToString('yyyy/MM/dd')
            $due = Get-ValidDueDate $task
            $isDue = $null -ne $due -and $due.Date -eq $date.Date
            $kind = if ($isPlanned -and $isDue) { '作業予定・期限' } elseif ($isPlanned) { '作業予定' } else { '期限' }
            $entry = ('[{0}] {1}  [{2}] ({3})' -f $task.ID,$task.Task,$kind,$task.Status)
            [void]$list.Items.Add($entry)
            $script:calendarDayTaskMap[$entry] = [string]$task.ID
        }
        $edit.Enabled = ($list.Items.Count -gt 0)
    }
    & $reload
    $add.Add_Click({
        try {
            $value = New-TaskDialog $null $date
            if ($null -ne $value) {
                $id = Add-TPGuiTaskFromDialog $value
                Write-ActionLog '追加（カレンダー）' ("ID=$id")
                Refresh-List
                & $reload
                Update-TaskCalendar
            }
        } catch { Show-Failure $_ }
    })
    $editAction = {
        try {
            if ($null -eq $list.SelectedItem) { return }
            $key = [string]$list.SelectedItem
            if (-not $script:calendarDayTaskMap.ContainsKey($key)) { return }
            $taskId = $script:calendarDayTaskMap[$key]
            $task = @(Read-Tasks $TaskFile | Where-Object { [string]$_.ID -eq $taskId }) | Select-Object -First 1
            if ($null -eq $task) { [System.Windows.Forms.MessageBox]::Show('タスクが見つかりません。') | Out-Null; & $reload; return }
            $value = New-TaskDialog $task
            if ($null -ne $value) {
                Save-EditedTask $task $value
                & $reload
                Update-TaskCalendar
            }
        } catch { Show-Failure $_ }
    }
    $edit.Add_Click($editAction)
    $list.Add_DoubleClick($editAction)
    $close.Add_Click({ $popup.Close() })
    [void]$popup.ShowDialog($form)
    $popup.Dispose()
}

function Update-TaskCalendar {
    if ($null -eq $calendarDays) { return }
    $calendarDays.SuspendLayout()
    try {
        $calendarDays.Controls.Clear()
        $calendarMonthLabel.Text = ('{0:yyyy年M月}' -f $script:calendarMonth)
        $headers = @('日','月','火','水','木','金','土')
        for ($col=0; $col -lt 7; $col++) {
            $head = New-Object System.Windows.Forms.Label
            $head.Text = $headers[$col]
            $head.Dock = 'Fill'
            $head.TextAlign = 'MiddleCenter'
            $head.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
            [void]$calendarDays.Controls.Add($head,$col,0)
        }
        $first = [datetime]::new($script:calendarMonth.Year,$script:calendarMonth.Month,1)
        $start = $first.AddDays(-[int]$first.DayOfWeek)
        $counts = @{}
        $plans = Read-PlannedDates
        foreach ($task in @(Read-Tasks $TaskFile)) {
            $planned = if ($plans.ContainsKey([string]$task.ID)) { [string]$plans[[string]$task.ID] } else { '' }
            if ($planned) {
                $plannedKey = $planned.Replace('/','')
                if (-not $counts.ContainsKey($plannedKey)) { $counts[$plannedKey] = New-Object System.Collections.ArrayList }
                [void]$counts[$plannedKey].Add([pscustomobject]@{Task=('予定: ' + [string]$task.Task)})
            }
            $due = Get-ValidDueDate $task
            if ($null -eq $due) { continue }
            $key = $due.ToString('yyyyMMdd')
            if (-not $counts.ContainsKey($key)) { $counts[$key] = New-Object System.Collections.ArrayList }
            [void]$counts[$key].Add($task)
        }
        for ($i=0; $i -lt 42; $i++) {
            $day = $start.AddDays($i)
            $key = $day.ToString('yyyyMMdd')
            $taskCount = 0
            $preview = ''
            if ($counts.ContainsKey($key)) {
                $taskCount = $counts[$key].Count
                $preview = [string]$counts[$key][0].Task
                if ($preview.Length -gt 12) { $preview = $preview.Substring(0,12) + '…' }
            }
            $button = New-Object System.Windows.Forms.Button
            $button.Dock = 'Fill'
            $button.Margin = New-Object System.Windows.Forms.Padding(2)
            $button.FlatStyle = 'Flat'
            $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(49,67,90)
            $button.TextAlign = 'TopLeft'
            $button.Font = New-Object System.Drawing.Font('Yu Gothic UI',9)
            $button.Text = [string]$day.Day
            if ($taskCount -gt 0) { $button.Text += "`r`n● $taskCount 件`r`n$preview" }
            $button.Tag = $day
            $button.BackColor = [System.Drawing.Color]::FromArgb(31,46,67)
            $button.ForeColor = [System.Drawing.Color]::White
            if ($day.Month -ne $first.Month) { $button.ForeColor = [System.Drawing.Color]::FromArgb(128,145,165) }
            if ($day.Date -eq (Get-Date).Date) { $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(111,195,255); $button.FlatAppearance.BorderSize = 2 }
            $button.Add_Click({ try { Show-CalendarDay ([datetime]$this.Tag) } catch { Show-Failure $_ } })
            $button.Add_DoubleClick({
                try {
                    $date = [datetime]$this.Tag
                    $value = New-TaskDialog $null $date
                    if ($null -eq $value) { return }
                    $id = Add-TPGuiTaskFromDialog $value
                    Write-ActionLog '追加（カレンダー）' ("ID=$id")
                    Refresh-List
                    Update-TaskCalendar
                } catch { Show-Failure $_ }
            })
            [void]$calendarDays.Controls.Add($button,($i % 7),([int][math]::Floor($i / 7)+1))
        }
    } finally { $calendarDays.ResumeLayout($true) }
}
function Set-TaskPilotView([bool]$showCalendar) {
    if ($showCalendar) { Update-TaskCalendar }
    $calendarView.Visible = $showCalendar
    $grid.Visible = -not $showCalendar
    if ($showCalendar) { $calendarView.BringToFront() }
}
$calendarPrev.Add_Click({ $script:calendarMonth = $script:calendarMonth.AddMonths(-1); Update-TaskCalendar })
$calendarNext.Add_Click({ $script:calendarMonth = $script:calendarMonth.AddMonths(1); Update-TaskCalendar })
$calendarToday.Add_Click({ $script:calendarMonth = (Get-Date).Date.AddDays(1-(Get-Date).Day); Update-TaskCalendar })
$calendarViewButton = New-Object System.Windows.Forms.Button
$calendarViewButton.Text = 'カレンダー'
$calendarViewButton.Size = New-Object System.Drawing.Size(112,30)
$calendarViewButton.Add_Click({
    try {
        $pop = New-Object System.Windows.Forms.Form
        $pop.Text = 'TaskPilot - カレンダー'
        $pop.Size = New-Object System.Drawing.Size(1050,700)
        $pop.StartPosition = 'CenterParent'
        $pop.BackColor = [System.Drawing.Color]::FromArgb(13,20,34)
        # Move the same calendar temporarily, then restore it on closing.
        $wasVisible = $calendarView.Visible
        $calendarView.Parent = $pop
        $calendarView.Visible = $true
        Update-TaskCalendar
        $pop.Add_FormClosing({ $calendarView.Parent = $viewHost; $calendarView.Dock = 'Fill' })
        [void]$pop.ShowDialog($form)
        $calendarView.Parent = $viewHost
        $calendarView.Dock = 'Fill'
        $calendarView.Visible = $wasVisible
        if ($wasVisible) { $calendarView.BringToFront() }
        $pop.Dispose()
    } catch {
        if ($null -ne $pop -and $null -ne $calendarView -and $null -ne $viewHost) { $calendarView.Parent = $viewHost }
        Show-Failure $_
    }
})
$panel.Controls.Add($calendarViewButton)
$listViewButton = New-Object System.Windows.Forms.Button
$listViewButton.Text = 'タスク一覧'
$listViewButton.Size = New-Object System.Drawing.Size(110,30)
$listViewButton.Add_Click({ Set-TaskPilotView $false })
$panel.Controls.Add($listViewButton)
# The second line of the existing toolbar is used for upcoming recurring dates.
$script:recurringPreview = New-Object System.Windows.Forms.Label
$script:recurringPreview.Text = '次回の定期タスク：確認中...'
$script:recurringPreview.AutoSize = $false
$script:recurringPreview.Width = 940
$script:recurringPreview.Height = 30
$script:recurringPreview.Margin = New-Object System.Windows.Forms.Padding(10,6,0,0)
$script:recurringPreview.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
$script:recurringPreview.AutoEllipsis = $true
$panel.Controls.Add($script:recurringPreview)
$panel.Add_SizeChanged({
    if ($null -ne $script:recurringPreview) {
        $script:recurringPreview.Width = [math]::Max(280,$panel.ClientSize.Width - 32)
    }
})
$panel.WrapContents = $true
$panel.AutoScroll = $true


# KPI cards and a selected-task details pane, laid out without overlaying the grid.
$cards = New-Object System.Windows.Forms.TableLayoutPanel
$cards.Dock = 'Fill'
$cards.Height = 84
$cards.ColumnCount = 4
$cards.RowCount = 1
for ($i=0; $i -lt 4; $i++) { [void]$cards.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,25))) }
function New-KpiCard([string]$label,[System.Drawing.Color]$color) {
    $box = New-Object System.Windows.Forms.Label
    $box.Text = "$label`r`n0 件"
    $box.Dock = 'Fill'
    $box.TextAlign = 'MiddleCenter'
    $box.Margin = New-Object System.Windows.Forms.Padding(7)
    $box.Font = New-Object System.Drawing.Font('Yu Gothic UI',12,[System.Drawing.FontStyle]::Bold)
    $box.BackColor = [System.Drawing.Color]::FromArgb(27,43,65)
    $box.ForeColor = $color
    return $box
}
$cardAll = New-KpiCard '全タスク' ([System.Drawing.Color]::FromArgb(231,239,249))
$cardOpen = New-KpiCard '未完了' ([System.Drawing.Color]::FromArgb(111,195,255))
$cardOverdue = New-KpiCard '期限切れ' ([System.Drawing.Color]::FromArgb(255,113,122))
$cardDone = New-KpiCard '完了' ([System.Drawing.Color]::FromArgb(94,217,157))
[void]$cards.Controls.Add($cardAll,0,0)
[void]$cards.Controls.Add($cardOpen,1,0)
[void]$cards.Controls.Add($cardOverdue,2,0)
[void]$cards.Controls.Add($cardDone,3,0)
$layout.Controls.Add($cards,0,2)
# Today's work panel: includes due today and overdue incomplete tasks.
$todayPanel = New-Object System.Windows.Forms.Panel
$todayPanel.Dock = 'Fill'
$todayPanel.Padding = New-Object System.Windows.Forms.Padding(12,7,12,5)
$todayPanel.BackColor = [System.Drawing.Color]::FromArgb(22,33,51)
$todayTitle = New-Object System.Windows.Forms.Label
$todayTitle.Text = '今日対応するタスク（期限切れ・本日期限）'
$todayTitle.Dock = 'Top'
$todayTitle.Height = 25
$todayTitle.Font = New-Object System.Drawing.Font('Yu Gothic UI',10,[System.Drawing.FontStyle]::Bold)
$todayTitle.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
$todayValue = New-Object System.Windows.Forms.Label
$todayValue.Dock = 'Fill'
$todayValue.AutoEllipsis = $true
$todayValue.ForeColor = [System.Drawing.Color]::FromArgb(231,239,249)
$todayPanel.Controls.Add($todayValue)
$todayPanel.Controls.Add($todayTitle)
$script:topCapacityLabel = New-Object System.Windows.Forms.Label
$script:topCapacityLabel.Dock = 'Bottom'
$script:topCapacityLabel.Height = 48
$script:topCapacityLabel.AutoEllipsis = $true
$script:topCapacityLabel.Font = New-Object System.Drawing.Font('Yu Gothic UI',10,[System.Drawing.FontStyle]::Bold)
$script:topCapacityLabel.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
$script:topCapacityLabel.Text = '稼働情報を計算中...'
$todayPanel.Controls.Add($script:topCapacityLabel)
$layout.Controls.Add($todayPanel,0,3)

$detailPanel = New-Object System.Windows.Forms.Panel
$detailPanel.Dock = 'Fill'
$detailPanel.Height = 118
$detailPanel.Padding = New-Object System.Windows.Forms.Padding(14,8,14,8)
$detailTitle = New-Object System.Windows.Forms.Label
$detailTitle.Text = '選択中のタスク詳細'
$detailTitle.Dock = 'Top'
$detailTitle.Height = 26
$detailTitle.Font = New-Object System.Drawing.Font('Yu Gothic UI',11,[System.Drawing.FontStyle]::Bold)
$detailValue = New-Object System.Windows.Forms.Label
$detailValue.Dock = 'Fill'
$detailValue.AutoEllipsis = $true
# STEP 3.6A: Show subtasks for the selected task in the main window.
$subtaskPreviewPanel = New-Object System.Windows.Forms.Panel
$subtaskPreviewPanel.Dock = 'Right'
$subtaskPreviewPanel.Width = 410
$subtaskPreviewPanel.Padding = New-Object System.Windows.Forms.Padding(8,0,0,0)
$script:subtaskPreviewHeading = New-Object System.Windows.Forms.Label
$script:subtaskPreviewHeading.Text = 'サブタスク（タスクを選択してください）'
$script:subtaskPreviewHeading.Dock = 'Top'
$script:subtaskPreviewHeading.Height = 26
$script:subtaskPreviewHeading.Font = New-Object System.Drawing.Font('Yu Gothic UI',10,[System.Drawing.FontStyle]::Bold)
$script:subtaskPreviewHeading.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
$script:subtaskPreviewList = New-Object System.Windows.Forms.ListView
$script:subtaskPreviewList.Dock = 'Fill'
$script:subtaskPreviewList.View = 'List'
$script:subtaskPreviewList.CheckBoxes = $true
$script:subtaskPreviewList.BackColor = [System.Drawing.Color]::FromArgb(31,46,67)
$script:subtaskPreviewList.ForeColor = [System.Drawing.Color]::White
$script:subtaskPreviewList.Add_ItemChecked({
    param($sender,$e)
    if ($script:subtaskPreviewBusy) { return }
    try {
        $parent = Selected-Task
        if ($null -eq $parent) { return }
        $all = @(Read-Subtasks)
        $found = $false
        foreach ($child in $all) {
            if ([string]$child.Id -eq [string]$e.Item.Tag -and [string]$child.ParentId -eq [string]$parent.ID) {
                $child.Done = [bool]$e.Item.Checked
                $found = $true
                break
            }
        }
        if ($found) { Save-Subtasks $all -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks') }
        Refresh-Details
    } catch {
        Show-Failure $_
        try { Refresh-Details } catch { Show-Failure $_ }
    }
})
$subtaskPreviewPanel.Controls.Add($script:subtaskPreviewList)
$subtaskPreviewPanel.Controls.Add($script:subtaskPreviewHeading)
$detailPanel.Controls.Add($subtaskPreviewPanel)
$detailPanel.Controls.Add($detailValue)
$detailPanel.Controls.Add($detailTitle)
$layout.Controls.Add($detailPanel,0,5)
# STEP 2.2: appearance only; CSV/backup/Excel processing remains unchanged.
$script:DarkBg = [System.Drawing.Color]::FromArgb(13,20,34)
$script:DarkSurface = [System.Drawing.Color]::FromArgb(22,33,51)
$script:DarkInput = [System.Drawing.Color]::FromArgb(31,46,67)
$script:DarkText = [System.Drawing.Color]::FromArgb(231,239,249)
$form.BackColor = $script:DarkBg
$form.ForeColor = $script:DarkText
$panel.BackColor = $script:DarkSurface
$bar.BackColor = $script:DarkSurface
$searchLabel.ForeColor = $script:DarkText
$summary.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
$searchBox.BackColor = $script:DarkInput
$searchBox.ForeColor = $script:DarkText
$searchBox.BorderStyle = 'FixedSingle'
$filterBox.BackColor = $script:DarkInput
$filterBox.ForeColor = $script:DarkText
$filterBox.FlatStyle = 'Flat'
$sortBox.BackColor = $script:DarkInput
$sortBox.ForeColor = $script:DarkText
$sortBox.FlatStyle = 'Flat'
$cards.BackColor = $script:DarkBg
$detailPanel.BackColor = $script:DarkSurface
$detailTitle.ForeColor = [System.Drawing.Color]::FromArgb(111,195,255)
$detailValue.ForeColor = $script:DarkText
$grid.BackgroundColor = $script:DarkBg
$grid.BorderStyle = 'None'
$grid.GridColor = [System.Drawing.Color]::FromArgb(49,67,90)
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30,48,73)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:DarkText
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(30,48,73)
$grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $script:DarkText
$grid.ColumnHeadersHeight = 36
$grid.RowTemplate.Height = 32
$grid.DefaultCellStyle.BackColor = $script:DarkSurface
$grid.DefaultCellStyle.ForeColor = $script:DarkText
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(35,103,168)
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(27,41,61)
$grid.AlternatingRowsDefaultCellStyle.ForeColor = $script:DarkText
$grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(35,103,168)
$grid.AlternatingRowsDefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$grid.Add_CellFormatting({
    param($sender,$e)
    if ($e.RowIndex -lt 0) { return }
    $row = $sender.Rows[$e.RowIndex]
    if ($null -eq $row -or $row.IsNewRow) { return }
    $status = [string]$row.Cells['Status'].Value
    $dueText = [string]$row.Cells['DueDate'].Value
    $due = [datetime]::MinValue
    $valid = [datetime]::TryParseExact($dueText,'yyyy/MM/dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$due)
    if ($status -eq '完了') {
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(94,217,157)
    } elseif ($valid -and $due.Date -lt (Get-Date).Date) {
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255,113,122)
    } elseif ($valid -and $due.Date -le (Get-Date).Date.AddDays($script:AppSettings.NotifyDays)) {
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(255,210,110)
    } elseif ($status -eq '対応中' -and $e.ColumnIndex -eq $sender.Columns['Status'].Index) {
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(112,190,255)
    }
})
# Right-click menu: select the clicked row before invoking any operation.
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$contextMenu.ShowImageMargin = $false
$ctxEdit = $contextMenu.Items.Add('編集')
$ctxComplete = $contextMenu.Items.Add('完了にする')
$ctxStatus = New-Object System.Windows.Forms.ToolStripMenuItem('ステータス変更')
foreach ($statusName in @('未着手','対応中','完了')) {
    $entry = New-Object System.Windows.Forms.ToolStripMenuItem($statusName)
    $entry.Tag = $statusName
    $entry.Add_Click({
        try {
            $task = Selected-Task
            if ($null -eq $task) { return }
            $newStatus = [string]$this.Tag
            if ($task.Status -eq $newStatus) { return }
            $value = [pscustomobject]@{Task=$task.Task;Priority=$task.Priority;DueDate=$task.DueDate;Status=$newStatus;Memo=$task.Memo}
            Save-EditedTask $task $value
        } catch { Show-Failure $_ }
    })
    [void]$ctxStatus.DropDownItems.Add($entry)
}
[void]$contextMenu.Items.Add($ctxStatus)
[void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$ctxDelete = $contextMenu.Items.Add('削除')
$ctxEdit.Add_Click({ $script:editButton.PerformClick() })
$ctxComplete.Add_Click({ $script:completeButton.PerformClick() })
$ctxDelete.Add_Click({ $script:deleteButton.PerformClick() })
$grid.ContextMenuStrip = $contextMenu
$grid.Add_CellMouseDown({
    param($sender,$e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    if ($e.RowIndex -lt 0) { return }
    $sender.ClearSelection()
    $sender.Rows[$e.RowIndex].Selected = $true
    $sender.CurrentCell = $sender.Rows[$e.RowIndex].Cells[0]
})
$contextMenu.Add_Opening({
    $task = Selected-Task
    if ($null -eq $task) { $contextMenu.Items[0].Enabled = $false; $contextMenu.Items[1].Enabled = $false; $ctxStatus.Enabled = $false; $ctxDelete.Enabled = $false; return }
    $ctxEdit.Enabled = $true
    $ctxComplete.Enabled = ($task.Status -ne '完了')
    $ctxStatus.Enabled = $true
    $ctxDelete.Enabled = $true
})
# Open editor by double-clicking an existing row.
$grid.Add_CellDoubleClick({
    param($sender,$e)
    if ($e.RowIndex -lt 0) { return }
    try {
        $task = Selected-Task
        if ($null -eq $task) { return }
        $value = New-TaskDialog $task
        if ($null -ne $value) { Save-EditedTask $task $value }
    } catch { Show-Failure $_ }
})
function Update-ActionButtons {
    if ($null -eq $script:editButton) { return }
    $task = Selected-Task
    $selected = ($null -ne $task)
    $script:editButton.Enabled = $selected
    $script:deleteButton.Enabled = $selected
    $script:completeButton.Enabled = ($selected -and $task.Status -ne '完了')
    if ($null -ne $script:menuEdit) { $script:menuEdit.Enabled = $selected }
    if ($null -ne $script:menuDelete) { $script:menuDelete.Enabled = $selected }
    if ($null -ne $script:menuComplete) { $script:menuComplete.Enabled = ($selected -and $task.Status -ne '完了') }
}
$searchBox.Add_TextChanged({ try { Refresh-List } catch { Show-Failure $_ } })
$filterBox.Add_SelectedIndexChanged({ try { Refresh-List } catch { Show-Failure $_ } })
$sortBox.Add_SelectedIndexChanged({ try { Refresh-List } catch { Show-Failure $_ } })
$grid.Add_SelectionChanged({ Refresh-Details; Update-ActionButtons })
# STEP 3.4D-2: persisted notification state; separate from task CSV.
$script:NotificationStateFile = Join-Path $DataDir 'NotificationState.json'
$script:NotificationHistoryFile = Join-Path $DataDir 'NotificationHistory.json'
$script:NotificationSeen = @{}
$script:NotificationSnoozed = @{}
$script:NotificationHistory = @()
$script:NotificationBusy = $false
$script:NotificationTimer = New-Object System.Windows.Forms.Timer
$script:NotificationTimer.Interval = 60000 # Check once per minute while app is open.



function Show-NotificationHistory {
    $window = New-Object System.Windows.Forms.Form
    try {
        $window.Text = 'TaskPilot - 通知履歴（最新500件）'
        $window.Size = New-Object System.Drawing.Size(790,510)
        $window.StartPosition = 'CenterParent'
        $window.BackColor = [System.Drawing.Color]::FromArgb(13,20,34)
        $box = New-Object System.Windows.Forms.ListBox
        $box.Dock = 'Fill'
        $box.BackColor = [System.Drawing.Color]::FromArgb(28,42,62)
        $box.ForeColor = [System.Drawing.Color]::White
        $box.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
        foreach ($h in @($script:NotificationHistory | Select-Object -Last 500 | Sort-Object Time -Descending)) {
            [void]$box.Items.Add("$($h.Time)  [$($h.Action)]  $($h.Category)  $($h.Task)  (ID:$($h.ID))")
        }
        $window.Controls.Add($box)
        [void]$window.ShowDialog($form)
    } finally { $window.Dispose() }
}
function Invoke-DailyNotificationCheck {
    if (-not [bool]$script:AppSettings.DailyNotifyEnabled) { return }
    if ((Get-Date).ToString('HH:mm') -lt [string]$script:AppSettings.DailyNotifyTime) { return }
    # Daily check is non-forced: previously acknowledged alerts remain dismissed today.
    Show-TaskPilotAlertPopup
}
function Get-TaskPilotAlerts {
    $today = (Get-Date).Date
    $plans = Read-PlannedDates
    $alerts = @()
    foreach ($task in @(Read-Tasks $TaskFile)) {
        if ([string]$task.Status -eq '完了') { continue }
        $id = [string]$task.ID
        $due = Get-ValidDueDate $task
        $category = ''
        $dateText = ''
        if ($null -ne $due -and $due -lt $today) {
            $category = '期限超過'; $dateText = $due.ToString('yyyy/MM/dd')
        } elseif ($null -ne $due -and $due -le $today.AddDays([int]$script:AppSettings.NotifyDays)) {
            $category = '期限間近'; $dateText = $due.ToString('yyyy/MM/dd')
        } elseif ($plans.ContainsKey($id) -and [string]$plans[$id] -eq $today.ToString('yyyy/MM/dd')) {
            $category = '本日の作業予定'; $dateText = [string]$plans[$id]
        }
        if ($category -eq '') { continue }
        $key = $today.ToString('yyyyMMdd') + ':' + $id + ':' + $category
        if ($script:NotificationSeen.ContainsKey($key)) { continue }
        if ($script:NotificationSnoozed.ContainsKey($key) -and $script:NotificationSnoozed[$key] -gt (Get-Date)) { continue }
        $planned = if ($plans.ContainsKey($id)) { [string]$plans[$id] } else { '未設定' }
        $alerts += [pscustomobject]@{ Key=$key; ID=$id; Name=[string]$task.Task; Category=$category; Due=[string]$task.DueDate; Planned=$planned; Priority=[string]$task.Priority }
    }
    return @($alerts)
}
function Show-TaskPilotAlertPopup([bool]$manual = $false) {
    if ($script:NotificationBusy -or (-not $manual -and -not [bool]$script:AppSettings.NotifyOnStartup -and -not [bool]$script:AppSettings.DailyNotifyEnabled)) { return }
    $alerts = @(Get-TaskPilotAlerts)
    if ($alerts.Count -eq 0) {
        if ($manual) { [System.Windows.Forms.MessageBox]::Show($form,'未通知の対象タスクはありません。','TaskPilot') | Out-Null }
        return
    }
    $script:NotificationBusy = $true
    $popup = New-Object System.Windows.Forms.Form
    try {
        $popup.Text = 'TaskPilot - タスク通知'
        $popup.Size = New-Object System.Drawing.Size(610,430)
        $popup.MinimumSize = New-Object System.Drawing.Size(550,380)
        $popup.StartPosition = 'CenterParent'
        $popup.BackColor = [System.Drawing.Color]::FromArgb(13,20,34)
        $popup.ForeColor = [System.Drawing.Color]::White
        $popup.Font = New-Object System.Drawing.Font('Yu Gothic UI',10)
        $header = New-Object System.Windows.Forms.Label
        $header.Text = "タスクのお知らせ  ($($alerts.Count) 件)"
        $header.Font = New-Object System.Drawing.Font('Yu Gothic UI',15,[System.Drawing.FontStyle]::Bold)
        $header.SetBounds(20,15,540,35)
        $popup.Controls.Add($header)
        $list = New-Object System.Windows.Forms.ListBox
        $list.SetBounds(20,60,550,190)
        $list.Anchor = 'Top,Left,Right,Bottom'
        $list.BackColor = [System.Drawing.Color]::FromArgb(28,42,62)
        $list.ForeColor = [System.Drawing.Color]::White
        foreach ($a in $alerts) { [void]$list.Items.Add("[$($a.Category)]  $($a.Name)  (ID:$($a.ID))") }
        $popup.Controls.Add($list)
        $details = New-Object System.Windows.Forms.Label
        $details.SetBounds(20,260,550,45)
        $details.Anchor = 'Left,Right,Bottom'
        $popup.Controls.Add($details)
        $list.Add_SelectedIndexChanged({
            if ($list.SelectedIndex -ge 0) {
                $a = $alerts[$list.SelectedIndex]
                $details.Text = "実施予定日: $($a.Planned)    期限: $($a.Due)    優先度: $($a.Priority)"
            }
        })
        $list.SelectedIndex = 0
        $open = New-Object System.Windows.Forms.Button
        $open.Text = 'タスクを開く'; $open.SetBounds(20,325,150,35)
        $open.Anchor = 'Left,Bottom'
        $open.Add_Click({
            if ($list.SelectedIndex -lt 0) { return }
            $a = $alerts[$list.SelectedIndex]
            $script:NotificationSeen[$a.Key] = $true
            Add-NotificationHistory @($a) 'タスクを開く'
            $popup.Tag = [string]$a.ID
            $popup.Close()
        })
        $popup.Controls.Add($open)
        $snooze = New-Object System.Windows.Forms.Button
        $snooze.Text = '30分後に再通知'; $snooze.SetBounds(185,325,170,35)
        $snooze.Anchor = 'Left,Bottom'
        $snooze.Add_Click({
            if ($list.SelectedIndex -lt 0) { return }
            $a = $alerts[$list.SelectedIndex]
            $script:NotificationSnoozed[$a.Key] = (Get-Date).AddMinutes(30)
            Add-NotificationHistory @($a) '30分後に再通知'
            $popup.Close()
        })
        $popup.Controls.Add($snooze)
        $close = New-Object System.Windows.Forms.Button
        $close.Text = '閉じる'; $close.SetBounds(370,325,130,35)
        $close.Anchor = 'Left,Bottom'
        $close.Add_Click({ $popup.Close() })
        $popup.Controls.Add($close)
        [void]$popup.ShowDialog($form)
        # Dismiss remaining items for this session, except snoozed ones.
        $dismissed = @()
        foreach ($a in $alerts) {
            if (-not $script:NotificationSnoozed.ContainsKey($a.Key)) {
                $script:NotificationSeen[$a.Key] = $true
                $dismissed += $a
            }
        }
        if ($dismissed.Count -gt 0) { Add-NotificationHistory $dismissed '確認済み' }
        else { Save-NotificationData }
        if (-not [string]::IsNullOrWhiteSpace([string]$popup.Tag)) {
            $targetId = [string]$popup.Tag
            $searchBox.Text = ''
            $filterBox.SelectedIndex = 0
            Refresh-List
            foreach ($row in $grid.Rows) {
                if ([string]$row.Cells['ID'].Value -eq $targetId) {
                    $grid.CurrentCell = $row.Cells['Task']; $row.Selected = $true
                    if ($script:editButton.Enabled) { $script:editButton.PerformClick() }
                    break
                }
            }
        }
    } finally {
        $popup.Dispose()
        $script:NotificationBusy = $false
    }
}
$script:NotificationTimer.Add_Tick({
    try { Invoke-DailyNotificationCheck } catch { try { if(Test-TPGuiIsolatedMode){Show-Failure $_}else{Write-ErrorLog $_} } finally { $script:NotificationTimer.Stop() } }
})
$form.Add_FormClosed({ $script:NotificationTimer.Stop(); $script:NotificationTimer.Dispose() })

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