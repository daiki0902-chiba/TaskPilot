function ConvertFrom-TPJsonArray {
    param([string]$InputObject)
    if (-not $InputObject.TrimStart().StartsWith('[')) { throw 'Expected an internal JSON array.' }
    # Assignment followed by foreach normalizes PS5.1 and PS7 array enumeration.
    $parsedJson = ConvertFrom-Json -InputObject $InputObject
    foreach ($jsonEntry in $parsedJson) { $jsonEntry }
}
# TaskPilot domain storage APIs. Dot-sourced by TaskPilot.Storage.psm1.
# SQLite access is through the module's .NET provider; never calls Python.

function Get-TPDomainField {
    param($Object,[string]$Name,$Default=$null,[switch]$Required)
    if ($null -eq $Object) { if ($Required) { throw "Validation: $Name is required." }; return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } else {
        $property=$Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    if ($Required) { throw "Validation: $Name is required." }
    return $Default
}
function Assert-TPDomainText {
    param($Value,[string]$Name,[switch]$AllowEmpty)
    if ($null -eq $Value -or $Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) { throw "Validation: $Name must be text." }
    return [string]$Value
}
function ConvertTo-TPDomainInteger {
    param($Value,[string]$Name,[long]$Minimum=0,[long]$Maximum=[long]::MaxValue,[switch]$Nullable)
    if ($null -eq $Value -and $Nullable) { return $null }
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { throw "Validation: $Name must be an integer." }
    try { $number=[decimal]$Value } catch { throw "Validation: $Name must be an integer." }
    if ($number -ne [decimal]::Truncate($number) -or $number -lt $Minimum -or $number -gt $Maximum) { throw "Validation: $Name is outside its integer range." }
    return [long]$number
}
function ConvertTo-TPDomainBoolean {
    param($Value,[string]$Name)
    if ($Value -is [bool]) { return [long][int]$Value }
    return ConvertTo-TPDomainInteger -Value $Value -Name $Name -Minimum 0 -Maximum 1
}
function ConvertTo-TPDomainHours {
    param($Value,[string]$Name,[long]$Maximum=[long]::MaxValue,[switch]$Signed)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "Validation: $Name must be a numeric value." }
    try { $decimalValue=[decimal]$Value } catch { throw "Validation: $Name must be a finite number." }
    if ($Signed -and $decimalValue -lt 0) { return -(ConvertTo-TPHours -Value (-$decimalValue) -Maximum $Maximum) }
    return ConvertTo-TPHours -Value $decimalValue -Maximum $Maximum
}
function Assert-TPDomainUtc {
    param($Value,[string]$Name,[switch]$Nullable)
    if ($null -eq $Value -and $Nullable) { return $null }
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,7})?Z$') { throw "Validation: $Name must be an ISO UTC timestamp ending in Z." }
    Assert-TPDate $Value.Substring(0,10)
    return $Value
}
function ConvertFrom-TPDomainPrefixedRow {
    param($Row)
    # PS 5.1 JSON parsing may coerce ISO-looking strings into DateTime.
    # SQL prefixes all JSON text fields so the original text survives exactly.
    foreach($property in $Row.PSObject.Properties){
        if($null -ne $property.Value -and $property.Value -is [string]){
            if(-not $property.Value.StartsWith('~')){throw 'Invalid internal JSON text encoding.'}
            $property.Value=$property.Value.Substring(1)
        }
    }
    return $Row
}
function New-TPDomainEnvelope {
    param($Data)
    return [pscustomobject]@{Token=(Get-TPToken -Value $Data);Data=$Data}
}

function Get-TaskPilotCalendar {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[long]$CalendarId=1)
    Assert-TPStore -Store $Store
    $calendarRows=@(Invoke-TPSql -Store $Store -Mode Rows -Parameters @{id=$CalendarId} -Sql @'
SELECT c.*,
 (SELECT json_group_array(weekday) FROM (SELECT weekday FROM calendar_weekdays WHERE calendar_id=c.calendar_id ORDER BY weekday)) AS weekdays_json,
 (SELECT json_group_array('~'||closure_date) FROM (SELECT closure_date FROM company_closures WHERE calendar_id=c.calendar_id ORDER BY closure_date)) AS closures_json,
 (SELECT json_group_array(json_object('work_date','~'||work_date,'hours_x100',hours_x100)) FROM (SELECT work_date,hours_x100 FROM capacity_overrides WHERE calendar_id=c.calendar_id ORDER BY work_date)) AS overrides_json
FROM capacity_calendars c WHERE calendar_id=@id
'@)
    if ($calendarRows.Count -ne 1) { throw 'NotFound: Calendar does not exist.' }
    $calendarRow=$calendarRows[0]
    $calendarOverrides=@(ConvertFrom-TPJsonArray -InputObject $calendarRow.overrides_json | ForEach-Object { $calendarDecoded=ConvertFrom-TPDomainPrefixedRow $_; [pscustomobject][ordered]@{work_date=$calendarDecoded.work_date;hours=([decimal]$calendarDecoded.hours_x100/100)} })
    $calendarData=[pscustomobject][ordered]@{calendar_id=[long]$calendarRow.calendar_id;name=[string]$calendarRow.name;daily_hours=([decimal]$calendarRow.daily_hours_x100/100);work_on_holidays=[bool]$calendarRow.work_on_holidays;holiday_set_id=$calendarRow.holiday_set_id;weekdays=@(ConvertFrom-TPJsonArray -InputObject $calendarRow.weekdays_json);closures=@(ConvertFrom-TPJsonArray -InputObject $calendarRow.closures_json | ForEach-Object { $_.Substring(1) });overrides=$calendarOverrides}
    return New-TPDomainEnvelope $calendarData
}
function Set-TaskPilotCalendar {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[long]$CalendarId=1,[Parameter(Mandatory=$true)]$Data,[Parameter(Mandatory=$true)][string]$ExpectedToken)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    $calendarName=Assert-TPDomainText (Get-TPDomainField $Data 'name' -Required) 'name'
    $calendarDaily=ConvertTo-TPDomainHours (Get-TPDomainField $Data 'daily_hours' -Required) 'daily_hours' -Maximum 2400
    $calendarHolidayFlag=ConvertTo-TPDomainBoolean (Get-TPDomainField $Data 'work_on_holidays' -Required) 'work_on_holidays'
    $calendarHolidaySet=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'holiday_set_id' -Required) 'holiday_set_id' -Minimum 1 -Nullable
    $calendarDays=@(Get-TPDomainField $Data 'weekdays' -Required)
    $calendarClosures=@(Get-TPDomainField $Data 'closures' -Required)
    $calendarOverridesInput=@(Get-TPDomainField $Data 'overrides' -Required)
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        $calendarCurrent=Get-TaskPilotCalendar -Store $Store -CalendarId $CalendarId
        Assert-TPExpectedToken -Expected $ExpectedToken -Actual $calendarCurrent.Token
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'UPDATE capacity_calendars SET name=@name,daily_hours_x100=@hours,work_on_holidays=@flag,holiday_set_id=@holiday WHERE calendar_id=@id' -Parameters @{name=$calendarName;hours=$calendarDaily;flag=$calendarHolidayFlag;holiday=$calendarHolidaySet;id=$CalendarId} | Out-Null
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'DELETE FROM calendar_weekdays WHERE calendar_id=@id' -Parameters @{id=$CalendarId} | Out-Null
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'DELETE FROM company_closures WHERE calendar_id=@id' -Parameters @{id=$CalendarId} | Out-Null
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'DELETE FROM capacity_overrides WHERE calendar_id=@id' -Parameters @{id=$CalendarId} | Out-Null
        foreach ($calendarDay in $calendarDays) {
            $calendarDayNumber=ConvertTo-TPDomainInteger $calendarDay 'weekday' -Maximum 6
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO calendar_weekdays(calendar_id,weekday) VALUES(@id,@day)' -Parameters @{id=$CalendarId;day=$calendarDayNumber} | Out-Null
        }
        foreach ($calendarClosure in $calendarClosures) {
            Assert-TPDate $calendarClosure
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO company_closures(calendar_id,closure_date) VALUES(@id,@date)' -Parameters @{id=$CalendarId;date=$calendarClosure} | Out-Null
        }
        foreach ($calendarOverride in $calendarOverridesInput) {
            $calendarOverrideDate=Get-TPDomainField $calendarOverride 'work_date' -Required
            Assert-TPDate $calendarOverrideDate
            $calendarOverrideHours=ConvertTo-TPDomainHours (Get-TPDomainField $calendarOverride 'hours' -Required) 'override hours' -Maximum 2400
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO capacity_overrides(calendar_id,work_date,hours_x100) VALUES(@id,@date,@hours)' -Parameters @{id=$CalendarId;date=$calendarOverrideDate;hours=$calendarOverrideHours} | Out-Null
        }
        Get-TaskPilotCalendar -Store $Store -CalendarId $CalendarId
    }
}
function Get-TaskPilotHolidaySet {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$HolidaySetId)
    Assert-TPStore -Store $Store
    $holidayRows=@(Invoke-TPSql -Store $Store -Mode Rows -Parameters @{id=$HolidaySetId} -Sql @'
SELECT s.*,(SELECT json_group_array(json_object('holiday_date','~'||holiday_date,'name','~'||name)) FROM (SELECT holiday_date,name FROM public_holidays WHERE holiday_set_id=s.holiday_set_id ORDER BY holiday_date)) AS holidays_json
FROM holiday_sets s WHERE holiday_set_id=@id
'@)
    if ($holidayRows.Count -ne 1) { throw 'NotFound: Holiday set does not exist.' }
    $holidayRow=$holidayRows[0]
    return [pscustomobject][ordered]@{holiday_set_id=[long]$holidayRow.holiday_set_id;name=$holidayRow.name;source_name=$holidayRow.source_name;imported_at_utc=$holidayRow.imported_at_utc;first_date=$holidayRow.first_date;last_date=$holidayRow.last_date;source_file_id=$holidayRow.source_file_id;holidays=@(ConvertFrom-TPJsonArray -InputObject $holidayRow.holidays_json | ForEach-Object { ConvertFrom-TPDomainPrefixedRow $_ })}
}
function Add-TaskPilotHolidaySet {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)]$Data)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    $holidayName=Assert-TPDomainText (Get-TPDomainField $Data 'name' -Required) 'name'
    $holidaySourceName=Assert-TPDomainText (Get-TPDomainField $Data 'source_name' -Required) 'source_name'
    $holidayImported=Assert-TPDomainUtc (Get-TPDomainField $Data 'imported_at_utc' (Get-TPUtcNow)) 'imported_at_utc'
    $holidayFirst=Get-TPDomainField $Data 'first_date' -Required; Assert-TPDate $holidayFirst
    $holidayLast=Get-TPDomainField $Data 'last_date' -Required; Assert-TPDate $holidayLast
    $holidaySourceId=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'source_file_id') 'source_file_id' -Minimum 1 -Nullable
    $holidayEntries=@(Get-TPDomainField $Data 'holidays' -Required)
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO holiday_sets(name,source_name,imported_at_utc,first_date,last_date,source_file_id) VALUES(@name,@source,@at,@first,@last,@file)' -Parameters @{name=$holidayName;source=$holidaySourceName;at=$holidayImported;first=$holidayFirst;last=$holidayLast;file=$holidaySourceId} | Out-Null
        $holidayNewId=[long](Invoke-TPSql -Store $Store -Mode Scalar -Sql 'SELECT last_insert_rowid()' -Parameters @{})
        foreach ($holidayEntry in $holidayEntries) {
            $holidayDate=Get-TPDomainField $holidayEntry 'holiday_date' -Required; Assert-TPDate $holidayDate
            if ($holidayDate -lt $holidayFirst -or $holidayDate -gt $holidayLast) { throw 'Validation: Holiday falls outside the declared coverage.' }
            $holidayEntryName=Assert-TPDomainText (Get-TPDomainField $holidayEntry 'name' -Required) 'holiday name'
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO public_holidays(holiday_set_id,holiday_date,name) VALUES(@id,@date,@name)' -Parameters @{id=$holidayNewId;date=$holidayDate;name=$holidayEntryName} | Out-Null
        }
        Get-TaskPilotHolidaySet -Store $Store -HolidaySetId $holidayNewId
    }
}

function Get-TaskPilotRecurringRule {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][string]$RuleId)
    Assert-TPStore -Store $Store
    $ruleRows=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT * FROM recurring_rules WHERE rule_id=@id' -Parameters @{id=$RuleId})
    if ($ruleRows.Count -ne 1) { throw 'NotFound: Recurring rule does not exist.' }
    return New-TPDomainEnvelope $ruleRows[0]
}
function Get-TaskPilotRecurringRules {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[switch]$IncludeDeleted)
    Assert-TPStore -Store $Store
    $ruleList=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT * FROM recurring_rules WHERE (@deleted=1 OR is_deleted=0) ORDER BY sort_order,rule_id' -Parameters @{deleted=[long][int][bool]$IncludeDeleted})
    foreach ($ruleListItem in $ruleList) { New-TPDomainEnvelope $ruleListItem }
}
function Save-TaskPilotRecurringRule {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][string]$RuleId,[Parameter(Mandatory=$true)]$Data,[Parameter(Mandatory=$true)][string]$ExpectedToken)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    $ruleKey=Assert-TPDomainText $RuleId 'rule_id'
    $ruleName=Assert-TPDomainText (Get-TPDomainField $Data 'name' -Required) 'name'
    $ruleType=Assert-TPDomainText (Get-TPDomainField $Data 'rule_type' -Required) 'rule_type'
    $ruleStart=Get-TPDomainField $Data 'starts_on' -Required; Assert-TPDate $ruleStart
    $ruleWeekday=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'weekday') 'weekday' -Maximum 6 -Nullable
    $ruleDay=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'day_of_month') 'day_of_month' -Minimum 1 -Maximum 31 -Nullable
    $ruleNth=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'nth') 'nth' -Minimum 1 -Maximum 31 -Nullable
    $ruleEnabled=ConvertTo-TPDomainBoolean (Get-TPDomainField $Data 'enabled' -Required) 'enabled'
    $ruleNote=Assert-TPDomainText (Get-TPDomainField $Data 'note' '') 'note' -AllowEmpty
    $ruleCalendar=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'calendar_id' ([long]1)) 'calendar_id' -Minimum 1
    $ruleOrder=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'sort_order' ([long]0)) 'sort_order'
    $rulePolicy=Get-TPDomainField $Data 'business_day_policy' 'legacy_mon_fri_holidays_closures'
    if ($rulePolicy -ne 'legacy_mon_fri_holidays_closures') { throw 'Validation: Unsupported business day policy.' }
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        $ruleExisting=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT * FROM recurring_rules WHERE rule_id=@id' -Parameters @{id=$ruleKey})
        $ruleValues=@{id=$ruleKey;name=$ruleName;type=$ruleType;weekday=$ruleWeekday;day=$ruleDay;nth=$ruleNth;start=$ruleStart;enabled=$ruleEnabled;note=$ruleNote;calendar=$ruleCalendar;policy=$rulePolicy;order=$ruleOrder}
        if ($ruleExisting.Count -eq 0) {
            if ($ExpectedToken -cne 'new') { throw 'Conflict: Recurring rule no longer exists.' }
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO recurring_rules(rule_id,name,rule_type,weekday,day_of_month,nth,starts_on,enabled,note,calendar_id,business_day_policy,sort_order) VALUES(@id,@name,@type,@weekday,@day,@nth,@start,@enabled,@note,@calendar,@policy,@order)' -Parameters $ruleValues | Out-Null
        } else {
            Assert-TPExpectedToken -Expected $ExpectedToken -Actual (Get-TPToken -Value $ruleExisting[0])
            if ([long]$ruleExisting[0].is_deleted -ne 0) { throw 'Validation: Deleted recurring rules cannot be edited.' }
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'UPDATE recurring_rules SET name=@name,rule_type=@type,weekday=@weekday,day_of_month=@day,nth=@nth,starts_on=@start,enabled=@enabled,note=@note,calendar_id=@calendar,business_day_policy=@policy,sort_order=@order WHERE rule_id=@id' -Parameters $ruleValues | Out-Null
        }
        Get-TaskPilotRecurringRule -Store $Store -RuleId $ruleKey
    }
}
function Remove-TaskPilotRecurringRule {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][string]$RuleId,[Parameter(Mandatory=$true)][string]$ExpectedToken)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        $ruleToRemove=Get-TaskPilotRecurringRule -Store $Store -RuleId $RuleId
        Assert-TPExpectedToken -Expected $ExpectedToken -Actual $ruleToRemove.Token
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'UPDATE recurring_rules SET is_deleted=1,enabled=0 WHERE rule_id=@id' -Parameters @{id=$RuleId} | Out-Null
        Get-TaskPilotRecurringRule -Store $Store -RuleId $RuleId
    }
}
function Invoke-TaskPilotRecurringOccurrence {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][string]$RuleId,[Parameter(Mandatory=$true)][string]$OccurrenceDate,[string]$RegisteredOn=(Get-Date -Format 'yyyy-MM-dd'))
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    Assert-TPDate $OccurrenceDate; Assert-TPDate $RegisteredOn
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        $generationRule=(Get-TaskPilotRecurringRule -Store $Store -RuleId $RuleId).Data
        if ([long]$generationRule.enabled -ne 1 -or [long]$generationRule.is_deleted -ne 0) { throw 'Validation: Recurring rule is disabled or deleted.' }
        if ($OccurrenceDate -lt $generationRule.starts_on) { throw 'Validation: Occurrence precedes the rule start date.' }
        $generationExisting=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT task_id FROM recurring_occurrences WHERE rule_id=@rule AND occurrence_date=@date' -Parameters @{rule=$RuleId;date=$OccurrenceDate})
        if ($generationExisting.Count -gt 0) { return [pscustomobject]@{Created=$false;TaskId=[long]$generationExisting[0].task_id;RuleId=$RuleId;OccurrenceDate=$OccurrenceDate} }
        $generationMarker='TP-RECUR:'+$RuleId+':'+$OccurrenceDate.Replace('-','')
        $generationMemo=(([string]$generationRule.note).Trim()+' ['+$generationMarker+']').Trim()
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO tasks(registered_on,title,priority,status,due_on,memo,calendar_id) VALUES(@registered,@title,@priority,@status,@due,@memo,@calendar)' -Parameters @{registered=$RegisteredOn;title=$generationRule.name;priority='中';status='未着手';due=$OccurrenceDate;memo=$generationMemo;calendar=$generationRule.calendar_id} | Out-Null
        $generationTaskId=[long](Invoke-TPSql -Store $Store -Mode Scalar -Sql 'SELECT last_insert_rowid()' -Parameters @{})
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO recurring_occurrences(rule_id,occurrence_date,task_id,generated_at_utc) VALUES(@rule,@date,@task,@at)' -Parameters @{rule=$RuleId;date=$OccurrenceDate;task=$generationTaskId;at=(Get-TPUtcNow)} | Out-Null
        return [pscustomobject]@{Created=$true;TaskId=$generationTaskId;RuleId=$RuleId;OccurrenceDate=$OccurrenceDate}
    }
}

function ConvertFrom-TPMonthlyRow {
    param($Row)
    if ($null -eq $Row) { return $null }
    return [pscustomobject][ordered]@{calendar_id=[long]$Row.calendar_id;month_key=$Row.month_key;revision=[long]$Row.revision;capacity_hours=([decimal]$Row.capacity_hours_x100/100);workdays=[long]$Row.workdays;planned_hours=([decimal]$Row.planned_hours_x100/100);planned_rate=$(if($null -eq $Row.planned_rate_x100){$null}else{[decimal]$Row.planned_rate_x100/100});logged_hours=([decimal]$Row.logged_hours_x100/100);completed_actual_hours=([decimal]$Row.completed_actual_hours_x100/100);completed_count=[long]$Row.completed_count;difference_hours=([decimal]$Row.difference_hours_x100/100);finalized_at_utc=$Row.finalized_at_utc;source=$Row.source;reason=$Row.reason;source_file_id=$Row.source_file_id}
}
function Get-TaskPilotMonthlySnapshot {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[long]$CalendarId=1,[Parameter(Mandatory=$true)][string]$MonthKey,[switch]$History)
    Assert-TPStore -Store $Store
    Assert-TPDate ($MonthKey+'-01')
    if (-not $History) {
        $monthRows=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT * FROM current_monthly_snapshots WHERE calendar_id=@calendar AND month_key=@month' -Parameters @{calendar=$CalendarId;month=$MonthKey})
        if ($monthRows.Count -eq 0) { return $null }
        return ConvertFrom-TPMonthlyRow $monthRows[0]
    }
    $monthRows=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT r.*,e.before_revision,e.reason AS audit_reason,e.changed_at_utc,(r.revision=s.current_revision) AS is_current FROM monthly_snapshot_revisions r JOIN monthly_snapshots s USING(calendar_id,month_key) JOIN monthly_revision_events e USING(calendar_id,month_key,revision) WHERE r.calendar_id=@calendar AND r.month_key=@month ORDER BY r.revision' -Parameters @{calendar=$CalendarId;month=$MonthKey})
    $monthCurrent=$null; $monthRevisions=@(); $monthEvents=@()
    foreach($monthRow in $monthRows) {
        $monthValue=ConvertFrom-TPMonthlyRow $monthRow; $monthRevisions+=,$monthValue
        if([long]$monthRow.is_current -eq 1){$monthCurrent=$monthValue}
        $monthEvents+=,[pscustomobject][ordered]@{revision=[long]$monthRow.revision;before_revision=$monthRow.before_revision;reason=$monthRow.audit_reason;changed_at_utc=$monthRow.changed_at_utc}
    }
    return [pscustomobject]@{Current=$monthCurrent;Revisions=$monthRevisions;Events=$monthEvents}
}
function Save-TaskPilotMonthlySnapshot {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[long]$CalendarId=1,[Parameter(Mandatory=$true)][string]$MonthKey,[Parameter(Mandatory=$true)]$Data,[Parameter(Mandatory=$true)][long]$ExpectedRevision)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    Assert-TPDate ($MonthKey+'-01')
    if($ExpectedRevision -lt 0 -or $ExpectedRevision -eq [long]::MaxValue){throw 'Validation: ExpectedRevision is outside its range.'}
    $monthCapacity=ConvertTo-TPDomainHours (Get-TPDomainField $Data 'capacity_hours' -Required) 'capacity_hours'
    $monthWorkdays=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'workdays' -Required) 'workdays'
    $monthPlanned=ConvertTo-TPDomainHours (Get-TPDomainField $Data 'planned_hours' -Required) 'planned_hours'
    $monthRateInput=Get-TPDomainField $Data 'planned_rate' -Required
    $monthRate=$null; if($null -ne $monthRateInput){$monthRate=ConvertTo-TPDomainHours $monthRateInput 'planned_rate'}
    $monthLogged=ConvertTo-TPDomainHours (Get-TPDomainField $Data 'logged_hours' -Required) 'logged_hours'
    $monthActual=ConvertTo-TPDomainHours (Get-TPDomainField $Data 'completed_actual_hours' -Required) 'completed_actual_hours'
    $monthCompleted=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'completed_count' -Required) 'completed_count'
    $monthDifference=ConvertTo-TPDomainHours (Get-TPDomainField $Data 'difference_hours' -Required) 'difference_hours' -Signed
    $monthSource=Assert-TPDomainText (Get-TPDomainField $Data 'source' -Required) 'source'
    $monthReason=Assert-TPDomainText (Get-TPDomainField $Data 'reason' -Required) 'reason'
    $monthSourceFile=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'source_file_id') 'source_file_id' -Minimum 1 -Nullable
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        $monthBefore=Get-TaskPilotMonthlySnapshot -Store $Store -CalendarId $CalendarId -MonthKey $MonthKey
        $monthActualRevision=0; if($null -ne $monthBefore){$monthActualRevision=[long]$monthBefore.revision}
        if($monthActualRevision -ne $ExpectedRevision){throw 'Conflict: Monthly revision changed.'}
        $monthNewRevision=$ExpectedRevision+1
        if($ExpectedRevision -eq 0){Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO monthly_snapshots(calendar_id,month_key,current_revision) VALUES(@calendar,@month,@revision)' -Parameters @{calendar=$CalendarId;month=$MonthKey;revision=$monthNewRevision} | Out-Null}
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO monthly_snapshot_revisions(calendar_id,month_key,revision,capacity_hours_x100,workdays,planned_hours_x100,planned_rate_x100,logged_hours_x100,completed_actual_hours_x100,completed_count,difference_hours_x100,finalized_at_utc,source,reason,source_file_id) VALUES(@calendar,@month,@revision,@capacity,@days,@planned,@rate,@logged,@actual,@count,@difference,@at,@source,@reason,@file)' -Parameters @{calendar=$CalendarId;month=$MonthKey;revision=$monthNewRevision;capacity=$monthCapacity;days=$monthWorkdays;planned=$monthPlanned;rate=$monthRate;logged=$monthLogged;actual=$monthActual;count=$monthCompleted;difference=$monthDifference;at=(Get-TPUtcNow);source=$monthSource;reason=$monthReason;file=$monthSourceFile} | Out-Null
        Get-TaskPilotMonthlySnapshot -Store $Store -CalendarId $CalendarId -MonthKey $MonthKey
    }
}

function Get-TaskPilotSettings {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store)
    Assert-TPStore -Store $Store
    $settingsRows=@(Invoke-TPSql -Store $Store -Mode Rows -Sql 'SELECT notify_on_startup,notify_days,daily_notify_enabled,daily_notify_time FROM app_settings WHERE singleton_id=1' -Parameters @{})
    if($settingsRows.Count -ne 1){throw 'NotFound: Application settings are missing.'}
    $settingsRow=$settingsRows[0]
    return New-TPDomainEnvelope ([pscustomobject][ordered]@{notify_on_startup=[bool]$settingsRow.notify_on_startup;notify_days=[long]$settingsRow.notify_days;daily_notify_enabled=[bool]$settingsRow.daily_notify_enabled;daily_notify_time=$settingsRow.daily_notify_time})
}
function Set-TaskPilotSettings {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)]$Data,[Parameter(Mandatory=$true)][string]$ExpectedToken)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    $settingsStartup=ConvertTo-TPDomainBoolean (Get-TPDomainField $Data 'notify_on_startup' -Required) 'notify_on_startup'
    $settingsDays=ConvertTo-TPDomainInteger (Get-TPDomainField $Data 'notify_days' -Required) 'notify_days' -Maximum 30
    $settingsDaily=ConvertTo-TPDomainBoolean (Get-TPDomainField $Data 'daily_notify_enabled' -Required) 'daily_notify_enabled'
    $settingsTime=Get-TPDomainField $Data 'daily_notify_time' -Required
    if($settingsTime -isnot [string] -or $settingsTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$'){throw 'Validation: daily_notify_time must be HH:mm.'}
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        Assert-TPExpectedToken -Expected $ExpectedToken -Actual (Get-TaskPilotSettings -Store $Store).Token
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'UPDATE app_settings SET notify_on_startup=@startup,notify_days=@days,daily_notify_enabled=@daily,daily_notify_time=@time WHERE singleton_id=1' -Parameters @{startup=$settingsStartup;days=$settingsDays;daily=$settingsDaily;time=$settingsTime} | Out-Null
        Get-TaskPilotSettings -Store $Store
    }
}
function Get-TaskPilotNotifications {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store)
    Assert-TPStore -Store $Store
    $notificationRows=@(Invoke-TPSql -Store $Store -Mode Rows -Sql @'
SELECT (SELECT json_group_array(json_object('alert_key','~'||alert_key,'is_seen',is_seen,'snoozed_until_utc','~'||snoozed_until_utc)) FROM (SELECT * FROM notification_state ORDER BY alert_key)) AS state_json,
 (SELECT json_group_array(json_object('event_id',event_id,'occurred_at_local_text','~'||occurred_at_local_text,'occurred_at_utc','~'||occurred_at_utc,'timezone_id','~'||timezone_id,'action','~'||action,'legacy_task_id_text','~'||legacy_task_id_text,'task_id',task_id,'task_name_snapshot','~'||task_name_snapshot,'category','~'||category,'sort_order',sort_order)) FROM (SELECT * FROM notification_history ORDER BY sort_order,event_id)) AS history_json
'@ -Parameters @{})
    $notificationRow=$notificationRows[0]
    $notificationData=[pscustomobject][ordered]@{state=@(ConvertFrom-TPJsonArray -InputObject $notificationRow.state_json | ForEach-Object { ConvertFrom-TPDomainPrefixedRow $_ });history=@(ConvertFrom-TPJsonArray -InputObject $notificationRow.history_json | ForEach-Object { ConvertFrom-TPDomainPrefixedRow $_ })}
    return New-TPDomainEnvelope $notificationData
}
function Save-TaskPilotNotifications {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)]$Data,[Parameter(Mandatory=$true)][string]$ExpectedToken)
    trap { if($null -ne $Store -and $null -ne $Store.PSObject.Properties['Transaction'] -and $null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw $_ }
    Assert-TPStore -Store $Store -Write
    $notificationStateInput=@(Get-TPDomainField $Data 'state' -Required)
    $notificationHistoryInput=@(Get-TPDomainField $Data 'history' -Required)
    Invoke-TPUnitOfWork -Store $Store -Block {
        param($Store)
        Assert-TPExpectedToken -Expected $ExpectedToken -Actual (Get-TaskPilotNotifications -Store $Store).Token
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'DELETE FROM notification_state' -Parameters @{} | Out-Null
        Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'DELETE FROM notification_history' -Parameters @{} | Out-Null
        foreach($notificationStateEntry in $notificationStateInput){
            $notificationKey=Assert-TPDomainText (Get-TPDomainField $notificationStateEntry 'alert_key' -Required) 'alert_key'
            $notificationSeen=ConvertTo-TPDomainBoolean (Get-TPDomainField $notificationStateEntry 'is_seen' -Required) 'is_seen'
            $notificationUntil=Assert-TPDomainUtc (Get-TPDomainField $notificationStateEntry 'snoozed_until_utc') 'snoozed_until_utc' -Nullable
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO notification_state(alert_key,is_seen,snoozed_until_utc) VALUES(@key,@seen,@until)' -Parameters @{key=$notificationKey;seen=$notificationSeen;until=$notificationUntil} | Out-Null
        }
        $notificationPosition=0
        foreach($notificationHistoryEntry in $notificationHistoryInput){
            $notificationEventId=ConvertTo-TPDomainInteger (Get-TPDomainField $notificationHistoryEntry 'event_id') 'event_id' -Minimum 1 -Nullable
            $notificationLocal=Assert-TPDomainText (Get-TPDomainField $notificationHistoryEntry 'occurred_at_local_text' -Required) 'occurred_at_local_text' -AllowEmpty
            $notificationUtc=Assert-TPDomainUtc (Get-TPDomainField $notificationHistoryEntry 'occurred_at_utc') 'occurred_at_utc' -Nullable
            $notificationTimezone=Get-TPDomainField $notificationHistoryEntry 'timezone_id'
            if($null -ne $notificationTimezone){$notificationTimezone=Assert-TPDomainText $notificationTimezone 'timezone_id'}
            $notificationAction=Assert-TPDomainText (Get-TPDomainField $notificationHistoryEntry 'action' -Required) 'action' -AllowEmpty
            $notificationLegacyTask=Assert-TPDomainText (Get-TPDomainField $notificationHistoryEntry 'legacy_task_id_text' -Required) 'legacy_task_id_text' -AllowEmpty
            $notificationTask=ConvertTo-TPDomainInteger (Get-TPDomainField $notificationHistoryEntry 'task_id') 'task_id' -Minimum 1 -Nullable
            $notificationTitle=Assert-TPDomainText (Get-TPDomainField $notificationHistoryEntry 'task_name_snapshot' -Required) 'task_name_snapshot' -AllowEmpty
            $notificationCategory=Assert-TPDomainText (Get-TPDomainField $notificationHistoryEntry 'category' -Required) 'category' -AllowEmpty
            $notificationOrder=ConvertTo-TPDomainInteger (Get-TPDomainField $notificationHistoryEntry 'sort_order' ([long]$notificationPosition)) 'sort_order'
            Invoke-TPSql -Store $Store -Mode NonQuery -Sql 'INSERT INTO notification_history(event_id,occurred_at_local_text,occurred_at_utc,timezone_id,action,legacy_task_id_text,task_id,task_name_snapshot,category,sort_order) VALUES(@id,@local,@utc,@timezone,@action,@legacy,@task,@title,@category,@order)' -Parameters @{id=$notificationEventId;local=$notificationLocal;utc=$notificationUtc;timezone=$notificationTimezone;action=$notificationAction;legacy=$notificationLegacyTask;task=$notificationTask;title=$notificationTitle;category=$notificationCategory;order=$notificationOrder} | Out-Null
            $notificationPosition++
        }
        Get-TaskPilotNotifications -Store $Store
    }
}
