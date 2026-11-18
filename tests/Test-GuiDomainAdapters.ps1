#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $repoRoot 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
. (Join-Path $repoRoot 'Adapters/TaskPilot.GuiCommon.ps1')
. (Join-Path $repoRoot 'Adapters/TaskPilot.GuiDomains.ps1')
. (Join-Path $PSScriptRoot 'MigrationDomainFixture.ps1')
$script:guiDomainChecks=0;$script:backupCalls=0
function Check($Value,[string]$Message){if(-not$Value){throw "FAILED: $Message"};$script:guiDomainChecks++}
function Fails([scriptblock]$Action,[string]$Message){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed $Message}
function Backup-Data {if($null-ne$script:TPGuiStore.Transaction){throw 'Backup must not run inside a write transaction.'};$script:backupCalls++}
function Write-ActionLog([string]$Action,[string]$Detail){}
# Load only the trusted, pure date algorithms; never run the legacy GUI or its file I/O.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'reference/TaskPilot_STEP3_6F_4.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Reference parser failure.'}
foreach($definition in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){
 if($definition.Name-in@('Get-LatestRecurringDate','Get-BusinessOccurrence','Get-NextRecurringDate','Get-DayCapacity')){. ([scriptblock]::Create($definition.Extent.Text))}
}
# Auto-finalization test isolates persistence from the unchanged allocation algorithm.
function Get-MonthlySnapshotData([datetime]$Month,[string]$Origin){return [ordered]@{Month=$Month.ToString('yyyy/MM');CapacityHours=[decimal]160;Workdays=20;PlannedHours=[decimal]100;PlannedRate=$null;LoggedHours=[decimal]80;CompletedActualHours=[decimal]60;CompletedCount=2;DifferenceHours=[decimal]-40;FinalizedAt=[datetime]::Now.ToString('o');Source=$Origin;Revision=1}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilot-GuiDomains-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$legacy=Join-Path $testRoot 'legacy';$db=Join-Path $testRoot 'gui.db';$backup=Join-Path $testRoot 'legacy-backup'
$null=New-Item -ItemType Directory -Path (Join-Path $legacy 'Data')
$runtime=@{};if($TestProviderAssembly){$runtime.TestProviderAssembly=$TestProviderAssembly}
$store=$null
try{
 $fixture=New-MigrationDomainFixture
 foreach($entry in $fixture.GetEnumerator()){[IO.File]::WriteAllText((Join-Path $legacy $entry.Key),$entry.Value,(New-Object Text.UTF8Encoding($true)))}
 $report=Test-TaskPilotLegacyData -SourceRoot $legacy
 $null=Import-TaskPilotLegacyData -SourceRoot $legacy -DatabasePath $db -BackupRoot $backup -ExpectedManifestSha256 $report.ManifestSha256 -Apply -AcknowledgeWarnings @runtime
 $store=Open-TaskPilotStore -DatabasePath $db @runtime
 Initialize-TPGuiContext -Store $store
 $cfg=Read-CapacitySettings
 Check ($cfg.DailyHours-eq[decimal]7.01-and$cfg.Weekdays.Count-eq0-and$cfg.Overrides.ContainsKey('2026-11-16')) 'Legacy calendar DTO and empty weekday set'
 $cfg.Weekdays=@(1,2,3,4,5);$cfg.DailyHours=[decimal]8.01
 Save-CapacitySettings $cfg
 Check ((Read-CapacitySettings).DailyHours-eq[decimal]8.01) 'Calendar adapter saves exact decimal hours'
 Add-CompanyClosure '2026-11-18';Add-CompanyClosure '2026-11-18'
 Check (@(Read-CompanyClosures|Where-Object{$_-eq'2026-11-18'}).Count-eq1) 'Atomic closure add is idempotent'
 $stale=Read-CapacitySettings
 Add-CompanyClosure '2026-11-19'
 $stale.DailyHours=[decimal]9
 Fails {Save-CapacitySettings $stale} 'Stale calendar editor cannot overwrite closure change'
 Check ((Read-CapacitySettings).DailyHours-eq[decimal]8.01-and@(Read-CompanyClosures)-contains'2026-11-19') 'Calendar conflict preserves committed values'
 Remove-CompanyClosure '2026-11-19'
 Check (@(Read-CompanyClosures)-notcontains'2026-11-19') 'Atomic closure remove targets one date'
 $holidayFile=Join-Path $testRoot 'official-fixture.csv'
 $holidayText="国民の祝日・休日月日,国民の祝日・休日名称`r`n2025/1/1,範囲始点`r`n"
 foreach($month in 1..12){$holidayText+='2026/'+$month+'/1,祝日'+$month+"`r`n"}
 $holidayText+="2027/12/31,範囲終点`r`n"
 [IO.File]::WriteAllText($holidayFile,$holidayText,[Text.Encoding]::GetEncoding(932))
 Check ((Import-JapaneseHolidayCsv $holidayFile)-eq14) 'CP932 holiday import selects newly created set atomically'
 $holidayDoc=Read-HolidaysDocument
 Check ($holidayDoc.Holidays.Count-eq14-and$holidayDoc.FirstDate-eq'2025-01-01'-and$holidayDoc.LastDate-eq'2027-12-31') 'Holiday document DTO comes from SQLite not JSON file'
 Check ((Get-VerifiedHolidayCalendar 2026).Count-eq12) 'Business recurrence verified holiday coverage'
 $holidayKeys=Get-CapacityHolidayKeys
 Check ($holidayKeys.ContainsKey('2026-12-01')-and$holidayKeys.ContainsKey('2026-08-13')) 'Capacity holidays include actual public and company rows'
 Check ((Get-DayCapacity ([datetime]'2026-12-01') (Read-CapacitySettings) $holidayKeys)-eq0) 'Stored holiday exclusion fixes old envelope-reading bug'
 $cfg=Read-CapacitySettings;$cfg.Overrides['2026-12-01']=[decimal]4.01;Save-CapacitySettings $cfg
 Check ((Get-DayCapacity ([datetime]'2026-12-01') (Read-CapacitySettings) (Get-CapacityHolidayKeys))-eq[decimal]4.01) 'Explicit override still wins over holiday'
 [IO.File]::AppendAllText($holidayFile,"2026/1/1,重複`r`n",[Text.Encoding]::GetEncoding(932))
 $beforeSets=[long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM holiday_sets' -Mode Scalar)
 Fails {Import-JapaneseHolidayCsv $holidayFile} 'Duplicate imported holiday aborts before replacing selected set'
 Check ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM holiday_sets' -Mode Scalar)-eq$beforeSets-and(Read-HolidaysDocument).Holidays.Count-eq14) 'Failed import leaves holiday rows and selection intact'
 $rules=@(Read-RecurringRules)
 Check ($rules.Count-eq6-and$rules[0].Type-eq'毎日'-and$rules[1].Weekday-eq'日') 'Legacy Japanese recurrence DTOs preserved'
 $created=Invoke-RecurringGeneration -AsOf ([datetime]'2026-11-15')
 Check ($created-eq4-and$script:backupCalls-eq1) 'All enabled remaining recurrence types generate with one pre-transaction backup'
 Check ((Invoke-RecurringGeneration -AsOf ([datetime]'2026-11-15'))-eq0-and$script:backupCalls-eq1) 'Repeated generation stays idempotent and creates no extra backup'
 Check ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM recurring_occurrences' -Mode Scalar)-eq5) 'Occurrence ledger covers migrated and newly generated tasks'
 $rules=@(Read-RecurringRules)
 $edited=@(foreach($rule in $rules){$rule.PSObject.Copy()})
 $edited[0].Name='GUIの変更'
 $external=Get-TaskPilotRecurringRule -Store $store -RuleId $rules[0].Id
 $external.Data.name='別の変更';$null=Save-TaskPilotRecurringRule -Store $store -RuleId $rules[0].Id -Data $external.Data -ExpectedToken $external.Token
 Fails {Save-RecurringRules $edited -OriginalRules $rules} 'Stale rule editor conflicts without overwriting external change'
 Check ((Read-RecurringRules|Where-Object{$_.Id-eq'rule-daily'}).Name-eq'別の変更') 'Committed rule survives stale full-list save'
 $rules=@(Read-RecurringRules);$edited=@(foreach($rule in $rules){$rule.PSObject.Copy()})
 $external=Get-TaskPilotRecurringRule -Store $store -RuleId 'rule-weekly';$external.Data.name='未編集ルールの外部変更';$null=Save-TaskPilotRecurringRule -Store $store -RuleId 'rule-weekly' -Data $external.Data -ExpectedToken $external.Token
 $edited[0].Note='別のルールのみ変更';Save-RecurringRules $edited -OriginalRules $rules
 $updatedWeekly=@($edited|Where-Object{$_.Id-eq'rule-weekly'})[0]
 Check ($updatedWeekly.Name-eq'未編集ルールの外部変更'-and$updatedWeekly.StorageToken-eq(Get-TaskPilotRecurringRule -Store $store -RuleId 'rule-weekly').Token) 'Rule values and concurrency token refresh together'
 $rules=@(Read-RecurringRules);$remaining=@($rules|Where-Object{$_.Id-ne'rule-last'})
 Save-RecurringRules $remaining -OriginalRules $rules
 Check (@(Read-RecurringRules).Count-eq5-and(Get-TaskPilotRecurringRule -Store $store -RuleId 'rule-last').Data.is_deleted-eq1) 'Rule deletion maps to soft deletion'
 Check ([long](Invoke-TPGuiSql "SELECT COUNT(*) FROM recurring_occurrences WHERE rule_id='rule-last'" -Mode Scalar)-eq1) 'Deleting rule retains generated occurrence'
 Fails {Save-RecurringRules $remaining} 'Rule save refuses to invent a fresh baseline token'
 $snapshots=Read-MonthlySnapshots
 Check ($snapshots['2026/10'].Revision-eq5-and$null-eq$snapshots['2026/10'].PlannedRate) 'Imported monthly revision and null rate remain legacy-readable'
 $audit=@(Read-MonthlyAudit)
 Check ($audit.Count-eq3-and@($audit|Where-Object{$_.StorageOrigin-eq'移行した旧版履歴'}).Count-eq2) 'Legacy and normalized audit both visible without legacy file existence'
 $old=$snapshots['2026/10'];$new=$old.PSObject.Copy();$new.Revision=6;$new.Source='手動修正';$new.PlannedRate=[decimal]150.01;$new.PlannedHours=[decimal]120.01
 $snapshots['2026/10']=$new
 Write-MonthlySnapshots $snapshots -ChangedMonth '2026/10' -ExpectedRevision 5 -Reason '手動修正'
 $eventsBefore=[long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM monthly_revision_events' -Mode Scalar)
 Add-MonthlyAudit '2026/10' '手動修正' $old $snapshots['2026/10']
 Check ($snapshots['2026/10'].Revision-eq6-and[long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM monthly_revision_events' -Mode Scalar)-eq$eventsBefore-and$eventsBefore-eq2) 'Monthly write appends one revision and one audit only'
 Check ((Read-MonthlySnapshots)['2026/10'].PlannedRate-eq[decimal]150.01) 'Manual finalized rate survives adapter roundtrip'
 Fails {Write-MonthlySnapshots $snapshots -ChangedMonth '2026/10' -ExpectedRevision 5 -Reason 'stale'} 'Stale month cannot update again'
 Invoke-MonthlyAutoFinalize -AsOf ([datetime]'2026-11-15')
 Check ($script:backupCalls-eq1) 'Existing finalized month is not recomputed or backed up again'
 Invoke-MonthlyAutoFinalize -AsOf ([datetime]'2026-12-15')
 Check ((Read-MonthlySnapshots)['2026/11'].Revision-eq1-and(Read-MonthlySnapshots)['2026/11'].Source.Contains('完全再現ではありません')-and$script:backupCalls-eq2) 'New auto-finalization labels reconstruction provenance and commits once'
 Load-AppSettings
 Check ($script:AppSettings.NotifyDays-eq9-and-not$script:AppSettings.NotifyOnStartup) 'Settings legacy DTO loaded'
 $script:AppSettings.NotifyDays=10;Save-AppSettings
 Check ($script:AppSettings.NotifyDays-eq10) 'Settings adapter commits and refreshes token'
 $settings=Get-TaskPilotSettings -Store $store;$settings.Data.notify_days=11;$null=Set-TaskPilotSettings -Store $store -Data $settings.Data -ExpectedToken $settings.Token
 $script:AppSettings.NotifyDays=12
 Fails {Save-AppSettings} 'Stale settings save fails'
 Check ($script:AppSettings.NotifyDays-eq11) 'Failed settings save restores globals from actual DB'
 Load-NotificationData
 Check ($script:NotificationHistory.Count-eq2-and-not$script:NotificationSnoozed.ContainsKey('20261115:1:期限間近')) 'History retained and expired snooze excluded only from active UI map'
 $script:NotificationSeen['20261116:1:本日の作業予定']=$true
 Add-NotificationHistory @([pscustomobject]@{ID='1';Name='通知時の名前';Category='本日の作業予定'}) '確認済み'
 $notice=Get-TaskPilotNotifications -Store $store
 Check ($notice.Data.history.Count-eq3-and$notice.Data.history[1].legacy_task_id_text-eq'900'-and$null-eq$notice.Data.history[1].occurred_at_utc) 'Adding new history preserves old orphan/local-time history'
 Check (@($notice.Data.state|Where-Object{$_.alert_key-eq'20261115:1:期限間近'})[0].snoozed_until_utc-eq'2020-01-01T00:00:00.0000000Z') 'Runtime save does not erase retained expired source state'
 Check ($null-ne$notice.Data.history[2].occurred_at_utc-and$notice.Data.history[2].task_name_snapshot-eq'通知時の名前') 'New history records current UTC while retaining alert name'
 $notice.Data.state+=,[pscustomobject]@{alert_key='external';is_seen=1;snoozed_until_utc=$null}
 $null=Save-TaskPilotNotifications -Store $store -Data $notice.Data -ExpectedToken $notice.Token
 $script:NotificationSeen['unsaved-local']=$true
 Fails {Save-NotificationData} 'Stale notification token conflicts'
 Check (-not$script:NotificationSeen.ContainsKey('unsaved-local')-and$script:NotificationSeen.ContainsKey('external')) 'Notification globals restored after failed acknowledgement'
 $historicalNotice=Get-TaskPilotNotifications -Store $store
 $historicalNotice.Data.history+=,[pscustomobject]@{occurred_at_local_text='';occurred_at_utc=$null;timezone_id=$null;action='';legacy_task_id_text='001';task_id=$null;task_name_snapshot='raw ID spelling';category='';sort_order=[long]3}
 $null=Save-TaskPilotNotifications -Store $store -Data $historicalNotice.Data -ExpectedToken $historicalNotice.Token
 Load-NotificationData
 Save-NotificationData
 $preservedNotice=Get-TaskPilotNotifications -Store $store
 $preservedHistorical=@($preservedNotice.Data.history|Where-Object{$_.legacy_task_id_text-ceq'001'})[0]
 Check ($preservedHistorical.occurred_at_local_text-ceq''-and$preservedHistorical.action-ceq''-and$preservedHistorical.category-ceq'') 'Empty historical text fields roundtrip unchanged'
 Check ($null-eq$preservedHistorical.task_id-and$preservedHistorical.legacy_task_id_text-ceq'001') 'Existing unresolved legacy ID001 is not rebound to current task1'
 Check ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM monthly_revision_events' -Mode Scalar)-eq3) 'No hidden duplicate audit writes across GUI paths'
 Write-Output "PASS: $guiDomainChecks headless GUI domain-adapter assertions using actual PowerShell/.NET SQLite."
}finally{
 if($null-ne$store-and-not$store.Closed){Close-TaskPilotStore $store}
 Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
