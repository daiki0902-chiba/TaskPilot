#requires -Version 5.1
# Comprehensive in-memory legacy fixture. Runs real module normalizers; no DB or user files.
$ErrorActionPreference='Stop'
$migrationDomainModule=Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
$script:migrationDomainChecks=0
function Check-MigrationDomain($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:migrationDomainChecks++}
. (Join-Path $PSScriptRoot "MigrationDomainFixture.ps1")
function New-MigrationDomainPlan {
    param($Documents)
    $domainFixtureSnapshot=New-MigrationDomainSnapshot $Documents
    return & $migrationDomainModule {param($domainSnapshot) New-TPMMemoryPlan $domainSnapshot} $domainFixtureSnapshot
}
function Get-MigrationDomainErrors($DomainPlan){return @($DomainPlan.Issues | Where-Object {$_.Severity -eq 'error'})}

$fixture=New-MigrationDomainFixture
Check-MigrationDomain ($fixture.Count -eq 17) 'Fixture contains all17 current legacy files'
$plan=New-MigrationDomainPlan $fixture
$errors=@(Get-MigrationDomainErrors $plan)
if($errors.Count){$errors|Format-List|Out-String|Write-Host}
Check-MigrationDomain ($errors.Count -eq 0) 'Comprehensive legacy fixture normalizes without blocking errors'
Check-MigrationDomain ($plan.Rows.tasks.Count -eq 3) 'Both CSV files imported'
Check-MigrationDomain ($plan.Rows.tasks[1].Values.status -eq '完了' -and $plan.Rows.tasks[1].Values.is_archived -eq 0 -and $plan.Rows.tasks[2].Values.is_archived -eq 1) 'Archive membership is not inferred from status'
Check-MigrationDomain ($plan.Rows.task_plans[0].Values.estimated_hours_x100 -eq 1 -and $null -eq $plan.Rows.task_plans[0].Values.work_start_on -and $plan.Rows.task_plans[0].Values.planned_on -eq '2026-11-16') 'Planned and work data merge without decimal or null loss'
Check-MigrationDomain ($plan.Rows.work_logs[0].Values.hours_x100 -eq 1 -and $plan.Rows.work_logs[0].Values.memo -ceq '2026-11-15T10:00:00+09:00') 'Exact exponent hours and ISO-like memo stay intact'
Check-MigrationDomain ($plan.Rows.completion_actuals[0].Values.actual_hours_x100 -eq 201 -and $plan.Rows.completion_actuals[0].Values.task_name_snapshot -ceq '当時の完了名称') 'Completion declaration remains separate with old name'
Check-MigrationDomain ($plan.HighWater -eq 900) 'Live, orphan, seen, snoozed and history IDs reserve highwater'
Check-MigrationDomain ($plan.Unresolved.Count -eq 2) 'Unmatched planned date and subtask retained as unresolved'
Check-MigrationDomain ($plan.Rows.capacity_calendars.Count -eq 1 -and $plan.Rows.capacity_calendars[0].Values.daily_hours_x100 -eq 701 -and $plan.Rows.capacity_calendars[0].Values.holiday_set_id -eq 1) 'Calendar and holiday selection combine into one row'
Check-MigrationDomain ($plan.Rows.calendar_weekdays.Count -eq 0 -and $plan.Documents.ContainsKey('Data/CapacitySettings.json')) 'Explicit empty weekdays remain distinguishable from absent settings'
Check-MigrationDomain ($plan.Rows.capacity_overrides.Count -eq 2 -and $plan.Rows.capacity_overrides[0].Values.hours_x100 -eq 0 -and $plan.Rows.capacity_overrides[1].Values.hours_x100 -eq 401) 'Zero and fractional capacity overrides retained'
Check-MigrationDomain ($plan.Rows.company_closures.Count -eq 2 -and $plan.Rows.public_holidays.Count -eq 2) 'Dates and Holidays wrappers both unwrapped'
Check-MigrationDomain ($plan.Rows.holiday_sets[0].Values.imported_at_utc -ceq '2026-11-15T01:00:00.1234567Z') 'Holiday import instant converted without replacing time or fractional precision'
Check-MigrationDomain ($plan.Rows.recurring_rules.Count -eq 6 -and $plan.Rules.Count -eq 6) 'All6 legacy recurrence types represented'
Check-MigrationDomain ($null -eq $plan.Rules['rule-daily'].weekday -and $null -eq $plan.Rules['rule-daily'].nth -and $null -eq $plan.Rules['rule-daily'].day_of_month) 'Unused recurrence options normalized only in domain columns'
Check-MigrationDomain ($plan.Rules['rule-weekly'].weekday -eq 0 -and $plan.Rules['rule-weekday'].weekday -eq 6 -and $plan.Rules['rule-weekday'].nth -eq 5) 'Weekday and nth options mapped correctly'
Check-MigrationDomain ($plan.Rows.recurring_occurrences.Count -eq 1 -and $plan.Rows.recurring_occurrences[0].Values.occurrence_date -eq '2026-11-15' -and $plan.Rows.tasks[0].Values.due_on -eq '2026-11-16') 'Marker occurrence stays distinct from user-edited deadline'
$month=$plan.Rows.monthly_snapshot_revisions[0].Values
Check-MigrationDomain ($month.revision -eq 5 -and $plan.Rows.monthly_snapshots[0].Values.current_revision -eq 5) 'Original monthly revision5 retained'
Check-MigrationDomain ($month.finalized_at_utc -ceq '2026-11-01T00:00:00.1234567Z' -and $month.source -ceq '確定当時の出典') 'Monthly time instant and source not fabricated'
Check-MigrationDomain ($null -eq $month.planned_rate_x100 -and $month.difference_hours_x100 -eq -4001 -and $month.workdays -eq 40) 'Nullable rate, negative variance and legacy manual count preserved'
Check-MigrationDomain ($plan.Rows.legacy_monthly_audit.Count -eq 2 -and $null -eq $plan.Rows.legacy_monthly_audit[0].Values.before_json -and $plan.Rows.legacy_monthly_audit[1].Values.source_ordinal -eq 1) 'Both old audit rows and null Before retained in order'
$auditRaw=[TaskPilot.Migration.Codec]::ParseJson($plan.Rows.legacy_monthly_audit[0].Values.after_json)
Check-MigrationDomain ($auditRaw['Unknown']['Large'].Lexeme -ceq '9007199254740993' -and $auditRaw['Unknown']['Decimal'].Lexeme -ceq '0.0100') 'Audit unknown fields retain exact numeric lexemes'
Check-MigrationDomain ($plan.Rows.notification_state.Count -eq 3 -and $plan.Rows.notification_state[0].Values.is_seen -eq 1 -and $plan.Rows.notification_state[0].Values.snoozed_until_utc -ceq '2020-01-01T00:00:00.0000000Z') 'Seen+snoozed merge and expired snooze retained'
Check-MigrationDomain ($plan.Rows.notification_history.Count -eq 2 -and $plan.Rows.notification_history[1].Values.legacy_task_id_text -ceq '900' -and $null -eq $plan.Rows.notification_history[1].Values.task_id -and $null -eq $plan.Rows.notification_history[1].Values.occurred_at_utc) 'Notification orphan ID/name and unknown UTC retained'
Check-MigrationDomain ($plan.Rows.app_settings[0].Values.notify_on_startup -eq 0 -and $plan.Rows.app_settings[0].Values.notify_days -eq 9 -and $plan.Rows.app_settings[0].Values.daily_notify_time -ceq '09:15') 'Four settings mapped without Boolean coercion'
Check-MigrationDomain (@($plan.Issues|Where-Object {$_.Code -eq 'unknown_field_retained'}).Count -ge 1) 'Unknown snapshot fields explicitly reported and raw retained'

$minimal=New-MigrationDomainPlan (New-MigrationDomainFixture -CoreOnly)
Check-MigrationDomain (@(Get-MigrationDomainErrors $minimal).Count -eq 0 -and $minimal.Rows.capacity_calendars.Count -eq 0 -and $minimal.Rows.calendar_weekdays.Count -eq 0 -and $minimal.Rows.app_settings.Count -eq 0) 'Missing optional files leave schema calendar/settings seeds unchanged'
Check-MigrationDomain ($minimal.HighWater -eq 99) 'NextId above live IDs remains highwater'

$partial=New-MigrationDomainFixture -CoreOnly
$partial.Add('Settings.json','{"NotifyDays":4}')
$partial.Add('Data/CapacitySettings.json','{}')
$partialPlan=New-MigrationDomainPlan $partial
Check-MigrationDomain (@(Get-MigrationDomainErrors $partialPlan).Count -eq 0 -and $partialPlan.Rows.calendar_weekdays.Count -eq 5 -and $partialPlan.Rows.capacity_calendars[0].Values.daily_hours_x100 -eq 800) 'Genuinely absent legacy optional fields use documented defaults'
Check-MigrationDomain ($partialPlan.Rows.app_settings[0].Values.notify_on_startup -eq 1 -and $partialPlan.Rows.app_settings[0].Values.notify_days -eq 4 -and @($partialPlan.Issues|Where-Object {$_.Code -eq 'legacy_default_applied'}).Count -eq 7) 'Missing-field default decisions have explicit warnings'

$invalidCases=[ordered]@{
 duplicate_closure=@('Data/CompanyClosures.json','{"Version":1,"Dates":["2026-08-13","2026-08-13"]}')
 duplicate_seen=@('Data/NotificationState.json','{"Seen":["20261115:1:期限間近","20261115:1:期限間近"],"Snoozed":[]}')
 duplicate_snoozed=@('Data/NotificationState.json','{"Seen":[],"Snoozed":[{"Key":"x","Until":"2026-01-01T00:00:00Z"},{"Key":"x","Until":"2026-01-02T00:00:00Z"}]}')
 exact_duplicate_json_key=@('Settings.json','{"NotifyDays":3,"NotifyDays":4}')
 escaped_alias_duplicate=@('Settings.json','{"NotifyDays":3,"\u004EotifyDays":4}')
 mismatched_case_default=@('Data/CapacitySettings.json','{"dailyhours":12}')
 subcentihour_underflow=@('Data/CapacitySettings.json','{"DailyHours":1e-100}')
 decimal_rounding=@('Data/CapacitySettings.json','{"DailyHours":1.00000000000000000000000000001}')
 numeric_bool=@('Settings.json','{"NotifyOnStartup":0}')
 invalid_notify_time=@('Settings.json','{"DailyNotifyTime":"24:00"}')
 offsetless_month=@('Data/MonthlySnapshots.json','{"2026/10":{"Month":"2026/10","CapacityHours":0,"Workdays":0,"PlannedHours":0,"PlannedRate":null,"LoggedHours":0,"CompletedActualHours":0,"CompletedCount":0,"DifferenceHours":0,"FinalizedAt":"2026-11-01T00:00:00","Source":"x","Revision":5}}')
 inconsistent_month=@('Data/MonthlySnapshots.json','{"2026/10":{"Month":"2026/11","CapacityHours":0,"Workdays":0,"PlannedHours":0,"PlannedRate":null,"LoggedHours":0,"CompletedActualHours":0,"CompletedCount":0,"DifferenceHours":0,"FinalizedAt":"2026-11-01T00:00:00Z","Source":"x","Revision":5}}')
 unsupported_wrapper_version=@('Data/CompanyClosures.json','{"Version":2,"Dates":[]}')
}
foreach($invalidCase in $invalidCases.GetEnumerator()){
 $invalidFixture=New-MigrationDomainFixture -CoreOnly
 $invalidFixture[$invalidCase.Value[0]]=$invalidCase.Value[1]
 $invalidPlan=New-MigrationDomainPlan $invalidFixture
 Check-MigrationDomain (@(Get-MigrationDomainErrors $invalidPlan).Count -ge 1) ('Blocking error for '+$invalidCase.Key)
}
Write-Output "PASS: $migrationDomainChecks legacy-domain normalization assertions; in-memory synthetic17-file fixture; no source/DB writes."
