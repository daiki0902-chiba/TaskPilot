# Isolated integration tests of actual PowerShell/.NET storage API.
[CmdletBinding()]param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
$domainModule=Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
Import-Module $domainModule -Force
$domainTemp=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilot-domain-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $domainTemp
$domainDb=Join-Path $domainTemp '日本語 test.db'
$domainRuntime=@{};if($TestProviderAssembly){$domainRuntime.TestProviderAssembly=$TestProviderAssembly}
$domainCount=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:domainCount++}
function Fail([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Check $failed $Message}
$domainStore=$null
try{
 New-TaskPilotDatabase -DatabasePath $domainDb @domainRuntime | Out-Null
 $domainStore=Open-TaskPilotStore -DatabasePath $domainDb @domainRuntime
 $cal=Get-TaskPilotCalendar -Store $domainStore
 Check ($cal.Data.weekdays.Count -eq 5) 'Default weekdays array'
 $oldCalToken=$cal.Token
 $cal.Data.daily_hours=[decimal]7.01
 $cal.Data.closures=@('2026-08-13')
 $cal.Data.overrides=@([pscustomobject]@{work_date='2026-11-15';hours=[decimal]0},[pscustomobject]@{work_date='2026-11-16';hours=[decimal]4.01})
 $cal=Set-TaskPilotCalendar -Store $domainStore -Data $cal.Data -ExpectedToken $cal.Token
 Check ($cal.Data.daily_hours -eq [decimal]7.01 -and $cal.Data.overrides[1].hours -eq [decimal]4.01) 'Decimal hours survive calendar roundtrip'
 Fail {Set-TaskPilotCalendar -Store $domainStore -Data $cal.Data -ExpectedToken $oldCalToken} 'Stale calendar token rejected'
 $rollbackCalToken=$cal.Token
 $cal.Data.weekdays=@(1,1)
 Fail {Set-TaskPilotCalendar -Store $domainStore -Data $cal.Data -ExpectedToken $rollbackCalToken} 'Duplicate weekday fails aggregate update'
 $cal=Get-TaskPilotCalendar -Store $domainStore
 Check ($cal.Token -eq $rollbackCalToken -and $cal.Data.closures.Count -eq 1 -and $cal.Data.overrides.Count -eq 2) 'Failed calendar replacement rolls every collection back'
 $holiday=@{name='祝日';source_name='テストCSV';first_date='2025-01-01';last_date='2027-12-31';holidays=@(@{holiday_date='2026-01-01';name='元日'},@{holiday_date='2026-05-05';name='こどもの日'})}
 $holidaySaved=Add-TaskPilotHolidaySet -Store $domainStore -Data $holiday
 Check ($holidaySaved.holidays.Count -eq 2 -and $holidaySaved.source_file_id -eq $null) 'Holiday metadata and nullable source preserved'
 $cal.Data.holiday_set_id=[long]$holidaySaved.holiday_set_id
 $cal=Set-TaskPilotCalendar -Store $domainStore -Data $cal.Data -ExpectedToken $cal.Token
 $holiday.holidays=@(@{holiday_date='2026-01-01';name='元日'},@{holiday_date='2026-01-01';name='重複'})
 Fail {Add-TaskPilotHolidaySet -Store $domainStore -Data $holiday} 'Duplicate holidays abort set creation'
 Fail {Get-TaskPilotHolidaySet -Store $domainStore -HolidaySetId ($holidaySaved.holiday_set_id+1)} 'No partial holiday set remains'
 $ruleData=@{name="定例'日本語";rule_type='daily';starts_on='2026-01-01';enabled=$true;note='=1+1'}
 $rule=Save-TaskPilotRecurringRule -Store $domainStore -RuleId 'test-rule' -Data $ruleData -ExpectedToken new
 $firstOccurrence=Invoke-TaskPilotRecurringOccurrence -Store $domainStore -RuleId 'test-rule' -OccurrenceDate '2026-11-15'
 $secondOccurrence=Invoke-TaskPilotRecurringOccurrence -Store $domainStore -RuleId 'test-rule' -OccurrenceDate '2026-11-15'
 Check ($firstOccurrence.Created -and -not $secondOccurrence.Created -and $firstOccurrence.TaskId -eq $secondOccurrence.TaskId) 'Generated occurrence is idempotent'
 Check (@(Get-TaskPilotTask -Store $domainStore).Count -eq 1) 'Duplicate generation leaves one task'
 $ruleData.name='改訂定例'
 $newRule=Save-TaskPilotRecurringRule -Store $domainStore -RuleId 'test-rule' -Data $ruleData -ExpectedToken $rule.Token
 Fail {Save-TaskPilotRecurringRule -Store $domainStore -RuleId 'test-rule' -Data $ruleData -ExpectedToken $rule.Token} 'Stale recurring rule rejected'
 $removedRule=Remove-TaskPilotRecurringRule -Store $domainStore -RuleId 'test-rule' -ExpectedToken $newRule.Token
 Check ($removedRule.Data.is_deleted -eq 1) 'Rule soft deletion'
 Fail {Invoke-TaskPilotRecurringOccurrence -Store $domainStore -RuleId 'test-rule' -OccurrenceDate '2026-11-16'} 'Deleted rule cannot generate'
 Check (@(Get-TaskPilotTask -Store $domainStore).Count -eq 1) 'Rule deletion retains generated task'
 $settings=Get-TaskPilotSettings -Store $domainStore
 $oldSettings=$settings.Token
 $settings.Data.notify_days=10
 $settings=Set-TaskPilotSettings -Store $domainStore -Data $settings.Data -ExpectedToken $settings.Token
 Check ($settings.Data.notify_days -eq 10) 'Settings save'
 Fail {Set-TaskPilotSettings -Store $domainStore -Data $settings.Data -ExpectedToken $oldSettings} 'Stale settings token rejected'
 $settings.Data.daily_notify_time='24:00'
 Fail {Set-TaskPilotSettings -Store $domainStore -Data $settings.Data -ExpectedToken $settings.Token} 'Invalid daily time rejected'
 $monthData=@{capacity_hours=[decimal]160;workdays=20;planned_hours=[decimal]100;planned_rate=$null;logged_hours=[decimal]80;completed_actual_hours=[decimal]60;completed_count=2;difference_hours=[decimal]-40;source='確定データ';reason='初回確定'}
 $month=Save-TaskPilotMonthlySnapshot -Store $domainStore -MonthKey '2026-10' -Data $monthData -ExpectedRevision 0
 Check ($month.revision -eq 1 -and $null -eq $month.planned_rate -and $month.difference_hours -eq -40) 'Null rate and signed difference preserved'
 $monthData.planned_rate=[decimal]150.01;$monthData.reason='手動修正'
 $month=Save-TaskPilotMonthlySnapshot -Store $domainStore -MonthKey '2026-10' -Data $monthData -ExpectedRevision 1
 Check ($month.revision -eq 2 -and $month.planned_rate -eq [decimal]150.01) 'Monthly correction appends revision'
 Fail {Save-TaskPilotMonthlySnapshot -Store $domainStore -MonthKey '2026-10' -Data $monthData -ExpectedRevision 1} 'Stale monthly revision rejected'
 $monthHistory=Get-TaskPilotMonthlySnapshot -Store $domainStore -MonthKey '2026-10' -History
 Check ($monthHistory.Revisions.Count -eq 2 -and $monthHistory.Events.Count -eq 2 -and $monthHistory.Events[1].before_revision -eq 1) 'Monthly audit and current pointer agree'
 $monthData.source_file_id=[long]999
 Fail {Save-TaskPilotMonthlySnapshot -Store $domainStore -MonthKey '2026-09' -Data $monthData -ExpectedRevision 0} 'Bad source reference aborts first month'
 Check ($null -eq (Get-TaskPilotMonthlySnapshot -Store $domainStore -MonthKey '2026-09')) 'Failed first month leaves no pointer or revision'
 $notifications=Get-TaskPilotNotifications -Store $domainStore
 $notificationData=@{state=@(@{alert_key='20261115:unknown:期限超過';is_seen=$true;snoozed_until_utc='2026-11-15T01:00:00Z'});history=@(@{occurred_at_local_text='2026/11/15 10:00:00';action='確認済み';legacy_task_id_text='unknown';task_name_snapshot='削除されたタスク';category='期限超過'})}
 $notifications=Save-TaskPilotNotifications -Store $domainStore -Data $notificationData -ExpectedToken $notifications.Token
 Check ($notifications.Data.history.Count -eq 1 -and $null -eq $notifications.Data.history[0].occurred_at_utc -and $notifications.Data.history[0].task_name_snapshot -eq '削除されたタスク') 'Orphan notification history and unknown UTC preserved'
 $notificationToken=$notifications.Token
 $notifications=Save-TaskPilotNotifications -Store $domainStore -Data $notifications.Data -ExpectedToken $notificationToken
 Check ($notifications.Token -eq $notificationToken) 'Notification envelope roundtrip keeps stable token and event IDs'
 $notificationData.history+=@{occurred_at_local_text='local';action='確認済み';legacy_task_id_text='x';task_id=[long]999;task_name_snapshot='不正親';category='期限超過'}
 Fail {Save-TaskPilotNotifications -Store $domainStore -Data $notificationData -ExpectedToken $notifications.Token} 'Bad history reference aborts notification replacement'
 $notifications=Get-TaskPilotNotifications -Store $domainStore
 Check ($notifications.Token -eq $notificationToken -and $notifications.Data.state.Count -eq 1) 'Notification state and history roll back together'
 $taskCount=@(Get-TaskPilotTask -Store $domainStore).Count
 Fail {Invoke-TaskPilotTransaction -Store $domainStore -Action {
  param($Store)
  Add-TaskPilotTask -Store $Store -Title 'must rollback' | Out-Null
  try{Set-TaskPilotSettings -Store $Store -Data @{notify_on_startup=$true;notify_days=50;daily_notify_enabled=$false;daily_notify_time='09:00'} -ExpectedToken 'irrelevant'}catch{}
 }} 'Caught nested domain validation still marks outer rollback-only'
 Check (@(Get-TaskPilotTask -Store $domainStore).Count -eq $taskCount) 'Outer transaction did not keep earlier task after swallowed validation error'
 Close-TaskPilotStore $domainStore;$domainStore=$null
 $readOnly=Open-TaskPilotStore -DatabasePath $domainDb -ReadOnly @domainRuntime
 try{
  Check ((Get-TaskPilotCalendar -Store $readOnly).Data.daily_hours -eq [decimal]7.01) 'Read-only store supports aggregate getters'
  Fail {Set-TaskPilotSettings -Store $readOnly -Data (Get-TaskPilotSettings -Store $readOnly).Data -ExpectedToken (Get-TaskPilotSettings -Store $readOnly).Token} 'Read-only store rejects domain writes'
 }finally{Close-TaskPilotStore $readOnly}
 Write-Output "PASS: $domainCount domain API assertions (actual PowerShell/.NET SQLite adapter)."
}finally{
 if($null -ne $domainStore -and -not $domainStore.Closed){Close-TaskPilotStore $domainStore}
 Remove-Item -LiteralPath $domainTemp -Recurse -Force -ErrorAction SilentlyContinue
}
