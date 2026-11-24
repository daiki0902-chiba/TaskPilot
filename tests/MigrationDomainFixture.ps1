#requires -Version 5.1
# Synthetic fixture builders; no source files, databases or modules are opened.
function New-MigrationDomainFixture {
    param([switch]$CoreOnly)
    $domainFixture=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $domainFixture.Add('Data/TaskList.csv',"ID,Date,Task,Priority,DueDate,Status,Memo`r`n1,2026/11/01,定例,中,2026/11/16,未着手,[TP-RECUR:rule-daily:20261115]`r`n2,2026/11/02,完了済み,高,,完了,完了でも通常一覧`r`n")
    $domainFixture.Add('Data/CompletedTask.csv',"ID,Date,Task,Priority,DueDate,Status,Memo`r`n3,2026/10/01,過去タスク,低,2026/10/31,完了,アーカイブ`r`n")
    $domainFixture.Add('Data/NextId.txt',"100`r`n")
    if($CoreOnly){return ,$domainFixture}
    $domainFixture.Add('Data/PlannedDates.json','{"1":"2026/11/16","500":"2026/11/20"}')
    $domainFixture.Add('Data/WorkPlans.json','{"1":{"StartDate":"","EstimatedHours":0.0100},"2":{"StartDate":"2026/11/01","EstimatedHours":4.50}}')
    $domainFixture.Add('Data/Subtasks.json','[{"Id":"sub1","ParentId":"1","Title":"子","Done":false},{"Id":"sub-orphan","ParentId":"500","Title":"失われた親の子","Done":true}]')
    $domainFixture.Add('Data/WorkLogs.json','[{"EntryId":"log1","TaskId":"1","WorkDate":"2026/11/14","Hours":1e-2,"Memo":"2026-11-15T10:00:00+09:00"}]')
    $domainFixture.Add('Data/ActualHours.json','{"2":{"CompletedDate":"2026/11/15","ActualHours":2.01,"TaskName":"当時の完了名称"}}')
    $domainFixture.Add('Data/CapacitySettings.json','{"Weekdays":[],"DailyHours":7.01,"WorkOnHolidays":false,"Overrides":{"2026-11-16":0,"2026-11-17":4.01}}')
    $domainFixture.Add('Data/CompanyClosures.json','{"Version":1,"Dates":["2026-08-13","2026-08-14"]}')
    $domainFixture.Add('Data/JapaneseHolidays.json','{"Version":1,"Source":"Cabinet Office CSV","ImportedAt":"2026-11-15T10:00:00.1234567+09:00","FirstDate":"2025-01-01","LastDate":"2027-12-31","Holidays":[{"Date":"2026-01-01","Name":"元日"},{"Date":"2026-05-05","Name":"こどもの日"}]}')
    $domainFixture.Add('Data/RecurringRules.json',@'
{"Version":1,"Rules":[
{"Id":"rule-daily","Name":"毎日","Type":"毎日","Weekday":"月","Day":31,"Nth":31,"StartDate":"2026-01-01","Enabled":true,"Note":"原文"},
{"Id":"rule-weekly","Name":"毎週","Type":"毎週","Weekday":"日","Day":1,"Nth":31,"StartDate":"2026-01-01","Enabled":false,"Note":""},
{"Id":"rule-monthday","Name":"月末","Type":"毎月（日付）","Weekday":"月","Day":31,"Nth":31,"StartDate":"2026-01-01","Enabled":true,"Note":""},
{"Id":"rule-weekday","Name":"第5土曜","Type":"毎月（第N曜日）","Weekday":"土","Day":1,"Nth":5,"StartDate":"2026-01-01","Enabled":true,"Note":""},
{"Id":"rule-business","Name":"第3営業日","Type":"毎月（第N営業日）","Weekday":"月","Day":1,"Nth":3,"StartDate":"2026-01-01","Enabled":true,"Note":""},
{"Id":"rule-last","Name":"最終営業日","Type":"毎月（最終営業日）","Weekday":"月","Day":1,"Nth":31,"StartDate":"2026-01-01","Enabled":true,"Note":""}]}
'@)
    $domainLegacyMonth='{"Month":"2026/10","CapacityHours":160.00,"Workdays":40,"PlannedHours":100.01,"PlannedRate":null,"LoggedHours":80,"CompletedActualHours":60,"CompletedCount":2,"DifferenceHours":-40.01,"FinalizedAt":"2026-11-01T09:00:00.1234567+09:00","Source":"確定当時の出典","Revision":5,"Unknown":{"Large":9007199254740993,"Decimal":0.0100}}'
    $domainFixture.Add('Data/MonthlySnapshots.json','{"2026/10":'+$domainLegacyMonth+'}')
    $domainFixture.Add('Data/MonthlySnapshotAudit.json','[{"At":"2026-11-01T09:00:00.1234567+09:00","Month":"2026/10","Reason":"自動確定","Before":null,"After":'+$domainLegacyMonth+'},{"At":"2026-11-02T10:00:00+09:00","Month":"2026/10","Reason":"手動修正","Before":'+$domainLegacyMonth+',"After":'+$domainLegacyMonth+'}]')
    $domainFixture.Add('Data/NotificationState.json','{"Seen":["20261115:1:期限間近","20261115:700:期限超過"],"Snoozed":[{"Key":"20261115:1:期限間近","Until":"2020-01-01T00:00:00Z"},{"Key":"20261115:800:本日の作業予定","Until":"2026-11-16T10:00:00+09:00"}]}')
    $domainFixture.Add('Data/NotificationHistory.json','[{"Time":"2026/11/15 10:00:00","Action":"確認済み","ID":"1","Task":"当時の通知名称","Category":"期限間近"},{"Time":"2026/11/15 11:00:00","Action":"タスクを開く","ID":"900","Task":"削除済みの名称","Category":"期限超過"}]')
    $domainFixture.Add('Settings.json','{"NotifyOnStartup":false,"NotifyDays":9,"DailyNotifyEnabled":true,"DailyNotifyTime":"09:15"}')
    return ,$domainFixture
}
function New-MigrationDomainSnapshot {
    param($Documents)
    $domainFixtureFiles=New-Object 'Collections.Generic.List[object]'
    $domainFixtureEncoding=New-Object Text.UTF8Encoding($false)
    foreach($domainFixtureEntry in $Documents.GetEnumerator()){
        $domainFixtureBytes=$domainFixtureEncoding.GetBytes($domainFixtureEntry.Value)
        $domainFixtureFiles.Add([pscustomobject]@{RelativePath=$domainFixtureEntry.Key;Bytes=$domainFixtureBytes;Size=[long]$domainFixtureBytes.Length})
    }
    return [pscustomobject]@{Files=$domainFixtureFiles.ToArray()}
}
