#requires -Version 5.1
# Legacy GUI DTO adapters over the SQLite store. No CSV/JSON persistence fallback.

function ConvertTo-TPGuiDomainInteger {
    param($Value,[long]$Minimum=0,[long]$Maximum=[long]::MaxValue)
    if($null-eq$Value-or$Value-is[string]-or$Value-is[bool]){throw '整数の数値が必要です。'}
    $number=[decimal]$Value
    if($number-ne[decimal]::Truncate($number)-or$number-lt$Minimum-or$number-gt$Maximum){throw '整数の値が範囲外です。'}
    return [long]$number
}
function ConvertFrom-TPGuiRule {
    param($Envelope)
    $r=$Envelope.Data
    $type=switch([string]$r.rule_type){daily{'毎日'};weekly{'毎週'};monthly_day{'毎月（日付）'};monthly_weekday{'毎月（第N曜日）'};monthly_business_day{'毎月（第N営業日）'};monthly_last_business_day{'毎月（最終営業日）'};default{throw 'Unknown stored recurring rule type.'}}
    $weekday=if($null-eq$r.weekday){'月'}else{@('日','月','火','水','木','金','土')[[int]$r.weekday]}
    [pscustomobject]@{Id=[string]$r.rule_id;Name=[string]$r.name;Type=$type;Weekday=$weekday;Day=$(if($null-eq$r.day_of_month){1}else{[int]$r.day_of_month});Nth=$(if($null-eq$r.nth){1}else{[int]$r.nth});StartDate=[string]$r.starts_on;Enabled=[bool]$r.enabled;Note=[string]$r.note;StorageToken=$Envelope.Token;StorageOrder=[long]$r.sort_order}
}
function ConvertTo-TPGuiRuleData {
    param($Rule,[long]$Order)
    $type=switch([string]$Rule.Type){'毎日'{'daily'};'毎週'{'weekly'};'毎月（日付）'{'monthly_day'};'毎月（第N曜日）'{'monthly_weekday'};'毎月（第N営業日）'{'monthly_business_day'};'毎月（最終営業日）'{'monthly_last_business_day'};default{throw '定期タスクの種類が不正です。'}}
    $weekday=$null;$day=$null;$nth=$null
    if($type-in@('weekly','monthly_weekday')){$weekday=[array]::IndexOf(@('日','月','火','水','木','金','土'),[string]$Rule.Weekday);if($weekday-lt0){throw '曜日が不正です。'};$weekday=[long]$weekday}
    if($type-eq'monthly_day'){$day=ConvertTo-TPGuiDomainInteger $Rule.Day -Minimum 1 -Maximum 31}
    if($type-in@('monthly_weekday','monthly_business_day')){$nth=ConvertTo-TPGuiDomainInteger $Rule.Nth -Minimum 1 -Maximum 31}
    if($Rule.Enabled-isnot[bool]){throw '定期タスクの有効状態は真偽値で指定してください。'}
    [pscustomobject][ordered]@{name=[string]$Rule.Name;rule_type=$type;weekday=$weekday;day_of_month=$day;nth=$nth;starts_on=[string]$Rule.StartDate;enabled=$Rule.Enabled;note=[string]$Rule.Note;calendar_id=[long]1;sort_order=$Order;business_day_policy='legacy_mon_fri_holidays_closures'}
}
function Read-RecurringRules {
    foreach($envelope in @(Get-TaskPilotRecurringRules -Store $script:TPGuiStore)){ConvertFrom-TPGuiRule $envelope}
}
function Save-RecurringRules {
    param([array]$rules,[array]$OriginalRules)
    if(-not$PSBoundParameters.ContainsKey('OriginalRules')){throw '定期タスクの保存には、編集開始時のOriginalRulesが必要です。'}
    $ruleOriginalMap=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($ruleOriginal in @($OriginalRules)){$ruleOriginalMap.Add([string]$ruleOriginal.Id,$ruleOriginal)}
    $ruleNewMap=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $rulePosition=[long]0
    foreach($ruleNew in @($rules)){$ruleNewMap.Add([string]$ruleNew.Id,[pscustomobject]@{Legacy=$ruleNew;Data=(ConvertTo-TPGuiRuleData $ruleNew $rulePosition)});$rulePosition++}
    $ruleCommitted=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    Invoke-TPGuiTransaction -Action {
        param($Store)
        foreach($ruleEntry in $ruleNewMap.GetEnumerator()){
            $ruleId=$ruleEntry.Key;$ruleData=$ruleEntry.Value.Data
            if($ruleOriginalMap.ContainsKey($ruleId)){
                $ruleOriginal=$ruleOriginalMap[$ruleId]
                $ruleOldData=ConvertTo-TPGuiRuleData $ruleOriginal ([long](Get-TPGuiValue $ruleOriginal 'StorageOrder' 0))
                $ruleBeforeJson=ConvertTo-Json -InputObject $ruleOldData -Depth 10 -Compress
                $ruleAfterJson=ConvertTo-Json -InputObject $ruleData -Depth 10 -Compress
                if($ruleBeforeJson-cne$ruleAfterJson){$null=Save-TaskPilotRecurringRule -Store $script:TPGuiStore -RuleId $ruleId -Data $ruleData -ExpectedToken ([string](Get-TPGuiValue $ruleOriginal 'StorageToken' ''))}
            }else{$null=Save-TaskPilotRecurringRule -Store $script:TPGuiStore -RuleId $ruleId -Data $ruleData -ExpectedToken 'new'}
        }
        foreach($ruleOldEntry in $ruleOriginalMap.GetEnumerator()){
            if(-not$ruleNewMap.ContainsKey($ruleOldEntry.Key)){$null=Remove-TaskPilotRecurringRule -Store $script:TPGuiStore -RuleId $ruleOldEntry.Key -ExpectedToken ([string](Get-TPGuiValue $ruleOldEntry.Value 'StorageToken' ''))}
        }
        foreach($ruleEnvelope in @(Get-TaskPilotRecurringRules -Store $script:TPGuiStore)){$ruleCommitted.Add([string]$ruleEnvelope.Data.rule_id,(ConvertFrom-TPGuiRule $ruleEnvelope))}
    } | Out-Null
    # Refresh values and token together. A fresh token on old unchanged values
    # would authorize a later stale overwrite of another writer's change.
    foreach($ruleNew in @($rules)){
        $freshLegacy=$ruleCommitted[[string]$ruleNew.Id]
        foreach($property in $freshLegacy.PSObject.Properties){$ruleNew|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force}
    }
    Set-TPGuiReportDirty
}
function Invoke-RecurringGeneration {
    param([datetime]$AsOf=(Get-Date))
    $generationCandidates=New-Object 'Collections.Generic.List[object]'
    foreach($rule in @(Read-RecurringRules)){
        if(-not$rule.Enabled){continue}
        try{$due=Get-LatestRecurringDate $rule $AsOf.Date}catch{Write-ActionLog '定期タスク生成保留' ($rule.Name+': '+$_.Exception.Message);continue}
        if($null-eq$due){continue}
        $date=$due.ToString('yyyy-MM-dd',[cultureinfo]::InvariantCulture)
        $existing=Invoke-TPGuiSql -Sql 'SELECT COUNT(*) FROM recurring_occurrences WHERE rule_id=@rule AND occurrence_date=@date' -Parameters @{rule=[string]$rule.Id;date=$date} -Mode Scalar
        if([long]$existing-eq0){$generationCandidates.Add([pscustomobject]@{RuleId=[string]$rule.Id;Date=$date})}
    }
    if($generationCandidates.Count-eq0){return 0}
    if($null-ne$script:TPGuiStore.Transaction){throw '定期タスク生成は既存トランザクションの外から実行してください。'}
    if(Get-Command Backup-Data -ErrorAction SilentlyContinue){Backup-Data}
    $generationResult=[pscustomobject]@{Added=0;Created=(New-Object 'Collections.Generic.List[object]')}
    Invoke-TPGuiTransaction -Action {
        param($Store)
        foreach($candidate in $generationCandidates){
            $result=Invoke-TaskPilotRecurringOccurrence -Store $script:TPGuiStore -RuleId $candidate.RuleId -OccurrenceDate $candidate.Date -RegisteredOn ($AsOf.ToString('yyyy-MM-dd',[cultureinfo]::InvariantCulture))
            if($result.Created){$generationResult.Added++;$generationResult.Created.Add($result)}
        }
    } | Out-Null
    foreach($created in $generationResult.Created){Write-ActionLog '定期タスク自動生成' ('ID='+$created.TaskId+', '+$created.RuleId+':'+$created.OccurrenceDate)}
    if($generationResult.Added-gt0){Set-TPGuiReportDirty}
    return [int]$generationResult.Added
}

function Read-CompanyClosures {
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT closure_date FROM company_closures WHERE calendar_id=1 ORDER BY closure_date')){[string]$row.closure_date}
}
function Save-CompanyClosures {
    param([array]$dates,[string]$ExpectedToken)
    if([string]::IsNullOrWhiteSpace($ExpectedToken)){throw '休業日の一括保存には、編集開始時のExpectedTokenが必要です。'}
    $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
    $calendar.Data.closures=@($dates)
    $null=Set-TaskPilotCalendar -Store $script:TPGuiStore -Data $calendar.Data -ExpectedToken $ExpectedToken
    Set-TPGuiReportDirty
}
function Add-CompanyClosure {
    param([string]$Date)
    Invoke-TPGuiTransaction -Action {
        param($Store)
        $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
        if(@($calendar.Data.closures)-contains$Date){return}
        $calendar.Data.closures=@($calendar.Data.closures)+@($Date)
        $null=Set-TaskPilotCalendar -Store $script:TPGuiStore -Data $calendar.Data -ExpectedToken $calendar.Token
    } | Out-Null
    Set-TPGuiReportDirty
}
function Remove-CompanyClosure {
    param([string]$Date)
    Invoke-TPGuiTransaction -Action {
        param($Store)
        $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
        $calendar.Data.closures=@($calendar.Data.closures|Where-Object {$_-cne$Date})
        $null=Set-TaskPilotCalendar -Store $script:TPGuiStore -Data $calendar.Data -ExpectedToken $calendar.Token
    } | Out-Null
    Set-TPGuiReportDirty
}
function Read-HolidaysDocument {
    $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
    if($null-eq$calendar.Data.holiday_set_id){return $null}
    $set=Get-TaskPilotHolidaySet -Store $script:TPGuiStore -HolidaySetId ([long]$calendar.Data.holiday_set_id)
    [pscustomobject]@{Version=1;Source=[string]$set.source_name;ImportedAt=[string]$set.imported_at_utc;FirstDate=[string]$set.first_date;LastDate=[string]$set.last_date;Holidays=@($set.holidays|ForEach-Object {[pscustomobject]@{Date=[string]$_.holiday_date;Name=[string]$_.name}})}
}
function Get-VerifiedHolidayCalendar {
    param([int]$year)
    $doc=Read-HolidaysDocument
    if($null-eq$doc){throw '祝日データがありません。祝日・休業日管理から公式CSVを取り込んでください。'}
    $first=[datetime]::ParseExact($doc.FirstDate,'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
    $last=[datetime]::ParseExact($doc.LastDate,'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
    if($year-le$first.Year-or$year-ge$last.Year){throw "${year}年の祝日データの完全性を確認できません。最新の公式CSVを確認してください。"}
    $holidays=@{}
    foreach($entry in $doc.Holidays){$date=[datetime]::ParseExact($entry.Date,'yyyy-MM-dd',[cultureinfo]::InvariantCulture);if($date.Year-eq$year){$holidays[$entry.Date]=$true}}
    if($holidays.Count-lt12){throw "${year}年の祝日データが不足しています。"}
    return $holidays
}
function Import-JapaneseHolidayCsv {
    param([string]$path)
    $mode=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-ne$mode-and$null-ne$mode.Value-and[bool]$mode.Value.IsTestMode){
        $sandbox=Get-TPGuiSandbox
        $path=$sandbox.AssertPath($path)
        $allowedParents=@([IO.Path]::GetFullPath([string]$sandbox.Input),[IO.Path]::GetFullPath([string]$sandbox.Temp))
        if($allowedParents-notcontains[IO.Path]::GetDirectoryName($path)){throw '独立テストモードではInputの試験CSVまたはTempの公式取得CSVだけを読み込みます。'}
        if([IO.Path]::GetExtension($path)-ine'.csv'){throw '試験用の.csvファイルを選択してください。'}
        $size=$sandbox.GetFileLength($path)
        if($size-lt20-or$size-gt2000000){throw '祝日CSVのファイルサイズが想定外です。'}
        $bytes=$sandbox.ReadAllBytes($path)
    }else{$bytes=[IO.File]::ReadAllBytes($path)}
    if($bytes.Length-lt20-or$bytes.Length-gt2000000){throw '祝日CSVのファイルサイズが想定外です。'}
    $encoding=[Text.Encoding]::GetEncoding(932,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback)
    $text=$encoding.GetString($bytes)
    . (Join-Path $PSScriptRoot '../Codec/Import-TaskPilotMigrationCodec.ps1')
    $csv=[TaskPilot.Migration.Codec]::ParseCsv($text)
    if($csv.Length-lt2-or$csv[0].Length-lt2-or-not$csv[0][0].Contains('国民の祝日')){throw '内閣府の祝日CSVとして認識できません。'}
    $entries=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    for($index=1;$index-lt$csv.Length;$index++){
        if($csv[$index].Length-ne2-or[string]::IsNullOrWhiteSpace($csv[$index][1])){throw '祝日CSVに不正な行があります。'}
        $parsed=[datetime]::MinValue
        if(-not[datetime]::TryParseExact($csv[$index][0].Trim(),[string[]]@('yyyy/M/d','yyyy/MM/dd'),[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw '祝日CSVの日付が不正です。'}
        $key=$parsed.ToString('yyyy-MM-dd',[cultureinfo]::InvariantCulture)
        if($entries.ContainsKey($key)){throw '祝日CSVの日付が重複しています。'}
        $entries.Add($key,$csv[$index][1].Trim())
    }
    if($entries.Count-lt10){throw '祝日データが少なすぎるため取り込みを中止しました。'}
    $keys=@($entries.Keys|Sort-Object)
    $holidayData=[pscustomobject]@{name='日本の祝日';source_name='Cabinet Office CSV';first_date=$keys[0];last_date=$keys[-1];holidays=@($keys|ForEach-Object {[pscustomobject]@{holiday_date=$_;name=$entries[$_]}})}
    Invoke-TPGuiTransaction -Action {
        param($Store)
        $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
        $holiday=Add-TaskPilotHolidaySet -Store $script:TPGuiStore -Data $holidayData
        $calendar.Data.holiday_set_id=[long]$holiday.holiday_set_id
        $null=Set-TaskPilotCalendar -Store $script:TPGuiStore -Data $calendar.Data -ExpectedToken $calendar.Token
    } | Out-Null
    Set-TPGuiReportDirty
    return [int]$entries.Count
}
function Read-CapacitySettings {
    $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
    $overrides=@{};foreach($entry in $calendar.Data.overrides){$overrides[[string]$entry.work_date]=[decimal]$entry.hours}
    return @{Weekdays=@($calendar.Data.weekdays);DailyHours=[decimal]$calendar.Data.daily_hours;WorkOnHolidays=[bool]$calendar.Data.work_on_holidays;Overrides=$overrides;StorageToken=$calendar.Token}
}
function Save-CapacitySettings {
    param($cfg)
    $calendar=Get-TaskPilotCalendar -Store $script:TPGuiStore
    $calendar.Data.weekdays=@($cfg.Weekdays);$calendar.Data.daily_hours=[decimal]$cfg.DailyHours;$calendar.Data.work_on_holidays=$cfg.WorkOnHolidays
    $calendar.Data.overrides=@(foreach($date in @($cfg.Overrides.Keys|Sort-Object)){[pscustomobject]@{work_date=[string]$date;hours=[decimal]$cfg.Overrides[$date]}})
    $saved=Set-TaskPilotCalendar -Store $script:TPGuiStore -Data $calendar.Data -ExpectedToken ([string](Get-TPGuiValue $cfg 'StorageToken' ''))
    $cfg.StorageToken=$saved.Token
    Set-TPGuiReportDirty
}
function Get-CapacityHolidayKeys {
    $keys=@{}
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT h.holiday_date AS day FROM public_holidays h JOIN capacity_calendars c ON c.holiday_set_id=h.holiday_set_id WHERE c.calendar_id=1 UNION SELECT closure_date AS day FROM company_closures WHERE calendar_id=1')){$keys[[string]$row.day]=$true}
    return $keys
}

function ConvertFrom-TPGuiMonthlySnapshot {
    param($row)
    [pscustomobject]@{Month=([string]$row.month_key).Replace('-','/');CapacityHours=[decimal]$row.capacity_hours;Workdays=[long]$row.workdays;PlannedHours=[decimal]$row.planned_hours;PlannedRate=$row.planned_rate;LoggedHours=[decimal]$row.logged_hours;CompletedActualHours=[decimal]$row.completed_actual_hours;CompletedCount=[long]$row.completed_count;DifferenceHours=[decimal]$row.difference_hours;FinalizedAt=[string]$row.finalized_at_utc;Source=[string]$row.source;Revision=[long]$row.revision}
}
function Read-MonthlySnapshots {
    $map=@{}
    foreach($row in @(Invoke-TPGuiSql -Sql 'SELECT calendar_id,month_key,revision,capacity_hours_x100,workdays,planned_hours_x100,planned_rate_x100,logged_hours_x100,completed_actual_hours_x100,completed_count,difference_hours_x100,finalized_at_utc,source,reason,source_file_id FROM current_monthly_snapshots WHERE calendar_id=1 ORDER BY month_key')){
        $value=[pscustomobject]@{month_key=$row.month_key;revision=$row.revision;capacity_hours=([decimal]$row.capacity_hours_x100/100);workdays=$row.workdays;planned_hours=([decimal]$row.planned_hours_x100/100);planned_rate=$(if($null-eq$row.planned_rate_x100){$null}else{[decimal]$row.planned_rate_x100/100});logged_hours=([decimal]$row.logged_hours_x100/100);completed_actual_hours=([decimal]$row.completed_actual_hours_x100/100);completed_count=$row.completed_count;difference_hours=([decimal]$row.difference_hours_x100/100);finalized_at_utc=$row.finalized_at_utc;source=$row.source}
        $legacy=ConvertFrom-TPGuiMonthlySnapshot $value;$map[$legacy.Month]=$legacy
    }
    return $map
}
function Write-MonthlySnapshots {
    param($map,[string]$ChangedMonth,[long]$ExpectedRevision,[string]$Reason)
    if(-not$PSBoundParameters.ContainsKey('ExpectedRevision')-or[string]::IsNullOrWhiteSpace($ChangedMonth)-or[string]::IsNullOrWhiteSpace($Reason)){throw '月次保存には変更月・編集開始時の版・修正理由が必要です。'}
    $candidate=$map[$ChangedMonth]
    if($null-eq$candidate-or[long]$candidate.Revision-ne$ExpectedRevision+1){throw '月次候補の版が編集開始時の版と一致しません。'}
    $data=[pscustomobject]@{capacity_hours=[decimal]$candidate.CapacityHours;workdays=(ConvertTo-TPGuiDomainInteger $candidate.Workdays);planned_hours=[decimal]$candidate.PlannedHours;planned_rate=$(if($null-eq$candidate.PlannedRate){$null}else{[decimal]$candidate.PlannedRate});logged_hours=[decimal]$candidate.LoggedHours;completed_actual_hours=[decimal]$candidate.CompletedActualHours;completed_count=(ConvertTo-TPGuiDomainInteger $candidate.CompletedCount);difference_hours=[decimal]$candidate.DifferenceHours;source=[string]$candidate.Source;reason=$Reason}
    $isoMonth=(ConvertTo-TPGuiIsoDate ($ChangedMonth+'/01')).Substring(0,7)
    $saved=Save-TaskPilotMonthlySnapshot -Store $script:TPGuiStore -MonthKey $isoMonth -Data $data -ExpectedRevision $ExpectedRevision
    $map[$ChangedMonth]=ConvertFrom-TPGuiMonthlySnapshot $saved
    Set-TPGuiReportDirty
}
function Read-MonthlyAudit {
    . (Join-Path $PSScriptRoot '../Codec/Import-TaskPilotMigrationCodec.ps1')
    foreach($old in @(Invoke-TPGuiSql -Sql 'SELECT month_text,at_text,reason,before_json,after_json,source_ordinal FROM legacy_monthly_audit ORDER BY source_file_id,source_ordinal')){
        [pscustomobject]@{Month=[string]$old.month_text;At=[string]$old.at_text;Reason=[string]$old.reason;Before=$(if($null-eq$old.before_json){$null}else{[TaskPilot.Migration.Codec]::ParseJson($old.before_json)});After=[TaskPilot.Migration.Codec]::ParseJson($old.after_json);BeforeJson=$old.before_json;AfterJson=$old.after_json;StorageOrigin='移行した旧版履歴'}
    }
    foreach($audit in @(Invoke-TPGuiSql -Sql 'SELECT calendar_id,month_key,revision,before_revision,reason,changed_at_utc FROM monthly_revision_events WHERE calendar_id=1 ORDER BY month_key,revision')){
        [pscustomobject]@{Month=([string]$audit.month_key).Replace('-','/');At=[string]$audit.changed_at_utc;Reason=[string]$audit.reason;BeforeRevision=$audit.before_revision;Revision=[long]$audit.revision;StorageOrigin='SQLite確定履歴'}
    }
}
function Add-MonthlyAudit {
    param([string]$month,[string]$reason,$before,$after)
    $isoMonth=(ConvertTo-TPGuiIsoDate ($month+'/01')).Substring(0,7)
    $current=Get-TaskPilotMonthlySnapshot -Store $script:TPGuiStore -MonthKey $isoMonth
    if($null-eq$current-or[long]$current.revision-ne[long]$after.Revision){throw '月次履歴は確定値と同時に保存する必要があります。'}
    # Compatibility only: Save-TaskPilotMonthlySnapshot already created the audit atomically.
}
function Invoke-MonthlyAutoFinalize {
    param([datetime]$AsOf=(Get-Date))
    $previous=$AsOf.Date.AddDays(1-$AsOf.Day).AddMonths(-1)
    $key=$previous.ToString('yyyy/MM',[cultureinfo]::InvariantCulture)
    if($null-ne(Get-TaskPilotMonthlySnapshot -Store $script:TPGuiStore -MonthKey $previous.ToString('yyyy-MM'))){return}
    if($null-ne$script:TPGuiStore.Transaction){throw '月次自動確定は既存トランザクションの外から実行してください。'}
    if(Get-Command Backup-Data -ErrorAction SilentlyContinue){Backup-Data}
    Invoke-TPGuiTransaction -Action {
        param($Store)
        if($null-ne(Get-TaskPilotMonthlySnapshot -Store $script:TPGuiStore -MonthKey $previous.ToString('yyyy-MM'))){return}
        $entry=Get-MonthlySnapshotData $previous '起動時の再計算（過去月末時点の完全再現ではありません）'
        $map=@{};$map[$key]=$entry
        Write-MonthlySnapshots $map -ChangedMonth $key -ExpectedRevision 0 -Reason '自動確定'
    } | Out-Null
}

function Load-AppSettings {
    $settings=Get-TaskPilotSettings -Store $script:TPGuiStore
    $script:AppSettings=@{NotifyOnStartup=[bool]$settings.Data.notify_on_startup;NotifyDays=[int]$settings.Data.notify_days;DailyNotifyEnabled=[bool]$settings.Data.daily_notify_enabled;DailyNotifyTime=[string]$settings.Data.daily_notify_time;StorageToken=$settings.Token}
}
function Save-AppSettings {
    try{
        $data=[pscustomobject]@{notify_on_startup=$script:AppSettings.NotifyOnStartup;notify_days=(ConvertTo-TPGuiDomainInteger $script:AppSettings.NotifyDays -Maximum 30);daily_notify_enabled=$script:AppSettings.DailyNotifyEnabled;daily_notify_time=[string]$script:AppSettings.DailyNotifyTime}
        $null=Set-TaskPilotSettings -Store $script:TPGuiStore -Data $data -ExpectedToken ([string](Get-TPGuiValue $script:AppSettings 'StorageToken' ''));Load-AppSettings
    }catch{Load-AppSettings;throw}
}
function Load-NotificationData {
    $notifications=Get-TaskPilotNotifications -Store $script:TPGuiStore
    $script:TPGuiNotificationBaseline=$notifications
    $script:NotificationSeen=@{};$script:NotificationSnoozed=@{}
    foreach($state in $notifications.Data.state){
        if([bool]$state.is_seen){$script:NotificationSeen[[string]$state.alert_key]=$true}
        if($null-ne$state.snoozed_until_utc){$until=[DateTimeOffset]::Parse([string]$state.snoozed_until_utc,[cultureinfo]::InvariantCulture).LocalDateTime;if($until-gt(Get-Date)){$script:NotificationSnoozed[[string]$state.alert_key]=$until}}
    }
    $script:NotificationHistory=@(foreach($event in $notifications.Data.history){[pscustomobject]@{Time=[string]$event.occurred_at_local_text;Action=[string]$event.action;ID=[string]$event.legacy_task_id_text;Task=[string]$event.task_name_snapshot;Category=[string]$event.category;StorageEventId=[long]$event.event_id;StorageTaskId=$event.task_id;OccurredAtUtc=$event.occurred_at_utc;TimezoneId=$event.timezone_id;StorageOrder=[long]$event.sort_order}})
}
function Save-NotificationData {
    if($null-eq$script:TPGuiNotificationBaseline){throw '通知を読み直してから保存してください。'}
    try{
        $states=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach($old in $script:TPGuiNotificationBaseline.Data.state){$states.Add([string]$old.alert_key,[pscustomobject]@{alert_key=[string]$old.alert_key;is_seen=[bool]$old.is_seen;snoozed_until_utc=$old.snoozed_until_utc})}
        foreach($key in $script:NotificationSeen.Keys){if(-not$states.ContainsKey([string]$key)){$states.Add([string]$key,[pscustomobject]@{alert_key=[string]$key;is_seen=$false;snoozed_until_utc=$null})};$states[[string]$key].is_seen=[bool]$script:NotificationSeen[$key]}
        foreach($key in $script:NotificationSnoozed.Keys){if(-not$states.ContainsKey([string]$key)){$states.Add([string]$key,[pscustomobject]@{alert_key=[string]$key;is_seen=$false;snoozed_until_utc=$null})};$states[[string]$key].snoozed_until_utc=([datetime]$script:NotificationSnoozed[$key]).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[cultureinfo]::InvariantCulture)}
        $historyPosition=[long]0
        $history=@(foreach($event in $script:NotificationHistory){
            $legacyId=[string]$event.ID;$taskId=Get-TPGuiValue $event 'StorageTaskId';$eventId=Get-TPGuiValue $event 'StorageEventId';$candidateId=[long]0
            # Historical null references are deliberate migration decisions. Only
            # a newly generated event may resolve its current canonical task ID.
            if($null-eq$eventId-and$null-eq$taskId-and[long]::TryParse($legacyId,[ref]$candidateId)-and$candidateId-gt0){$resolved=Invoke-TPGuiSql -Sql 'SELECT task_id FROM tasks WHERE task_id=@id' -Parameters @{id=$candidateId} -Mode Scalar;if($null-ne$resolved){$taskId=[long]$resolved}}
            [pscustomobject]@{event_id=$eventId;occurred_at_local_text=[string]$event.Time;occurred_at_utc=(Get-TPGuiValue $event 'OccurredAtUtc');timezone_id=(Get-TPGuiValue $event 'TimezoneId');action=[string]$event.Action;legacy_task_id_text=$legacyId;task_id=$taskId;task_name_snapshot=[string]$event.Task;category=[string]$event.Category;sort_order=$historyPosition};$historyPosition++
        })
        $data=[pscustomobject]@{state=@($states.Values);history=$history}
        $null=Save-TaskPilotNotifications -Store $script:TPGuiStore -Data $data -ExpectedToken $script:TPGuiNotificationBaseline.Token
        Load-NotificationData
    }catch{Load-NotificationData;throw}
}
function Add-NotificationHistory {
    param([object[]]$alerts,[string]$action)
    $newEvents=@(foreach($alert in $alerts){[pscustomobject]@{Time=(Get-Date).ToString('yyyy/MM/dd HH:mm:ss',[cultureinfo]::InvariantCulture);Action=$action;ID=[string]$alert.ID;Task=[string]$alert.Name;Category=[string]$alert.Category;OccurredAtUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[cultureinfo]::InvariantCulture);TimezoneId=[TimeZoneInfo]::Local.Id}})
    $script:NotificationHistory=@($script:NotificationHistory)+$newEvents
    Save-NotificationData
}
