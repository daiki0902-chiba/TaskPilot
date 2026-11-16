# Legacy domain normalization only. Does not open or modify any database or source file.
# All untrusted object access goes through ordinal dictionaries / Get-TPMField.

function ConvertTo-TPMDomainBoolean {
    param($Value)
    if($Value -isnot [bool]){throw 'Expected a JSON Boolean, not a string or number.'}
    return [long][int]$Value
}
function Get-TPMDomainNumber {
    param([string]$Lexeme)
    return New-Object TaskPilot.Migration.JsonNumber $Lexeme
}
function Get-TPMDomainDefaultField {
    param($Plan,$Object,[string]$Name,$Default,[string]$File,[string]$Locator)
    if(-not $Object.Contains($Name)){
        foreach($defaultEntry in $Object.GetEnumerator()){
            if([string]::Equals([string]$defaultEntry.Key,$Name,[StringComparison]::OrdinalIgnoreCase)){throw "A case-mismatched recognized field must not be replaced with a default: $Name"}
        }
        Add-TPMIssue -Plan $Plan -Severity warning -File $File -Locator $Locator -Code 'legacy_default_applied' -Message ("Missing '$Name' uses the documented legacy default; original source is retained.")
    }
    return ,(Get-TPMField -Object $Object -Name $Name -Default $Default)
}
function Reserve-TPMDomainNotificationIdentity {
    param($Plan,[string]$Key)
    # Only recognized alert-key structures are interpreted as task references.
    $keyParts=$Key.Split(@(':'),3,[StringSplitOptions]::None)
    if($keyParts.Count -eq 3 -and $keyParts[0] -cmatch '^[0-9]{8}$' -and $keyParts[1] -cmatch '^[0-9]+$'){
        $null=Resolve-TPMParent -Plan $Plan -Value $keyParts[1]
    }
}

function Convert-TPMLegacyDomains {
    param([Parameter(Mandatory=$true)]$Plan)
    $domainContext=[pscustomobject]@{
        Calendar=[ordered]@{calendar_id=[long]1;name='既定の稼働条件';daily_hours_x100=[long]800;work_on_holidays=[long]0;holiday_set_id=$null}
        CalendarFile=$null
        NotificationStates=(New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal))
        SeenKeys=(New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal))
        SnoozedKeys=(New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal))
    }

    $domainFile='Data/CapacitySettings.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $capacityDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $capacityDoc
            Test-TPMKnownFields -Plan $Plan -Object $capacityDoc -Names @('Weekdays','DailyHours','WorkOnHolidays','Overrides') -File $domainFile -Locator '$'
            $capacityDaily=Get-TPMDomainDefaultField -Plan $Plan -Object $capacityDoc -Name 'DailyHours' -Default (Get-TPMDomainNumber '8') -File $domainFile -Locator '$.DailyHours'
            $capacityFlag=Get-TPMDomainDefaultField -Plan $Plan -Object $capacityDoc -Name 'WorkOnHolidays' -Default $false -File $domainFile -Locator '$.WorkOnHolidays'
            $domainContext.Calendar.daily_hours_x100=ConvertTo-TPMHours -Value $capacityDaily -Maximum 2400
            $domainContext.Calendar.work_on_holidays=ConvertTo-TPMDomainBoolean $capacityFlag
            $capacityDefaultDays=[object[]]@((Get-TPMDomainNumber '1'),(Get-TPMDomainNumber '2'),(Get-TPMDomainNumber '3'),(Get-TPMDomainNumber '4'),(Get-TPMDomainNumber '5'))
            $capacityWeekdays=Get-TPMDomainDefaultField -Plan $Plan -Object $capacityDoc -Name 'Weekdays' -Default $capacityDefaultDays -File $domainFile -Locator '$.Weekdays'
            Assert-TPMArray -Value $capacityWeekdays
            for($capacityDayIndex=0;$capacityDayIndex -lt $capacityWeekdays.Length;$capacityDayIndex++){
                $capacityDayValue=$capacityWeekdays[$capacityDayIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Weekdays['+$capacityDayIndex+']') -Block {
                    $capacityDayNumber=ConvertTo-TPMInteger -Value $capacityDayValue -Maximum 6
                    Add-TPMRow -Plan $Plan -Table 'calendar_weekdays' -Values ([ordered]@{calendar_id=[long]1;weekday=$capacityDayNumber}) -File $domainFile -Locator ('$.Weekdays['+$capacityDayIndex+']')
                }
            }
            $capacityOverrides=Get-TPMDomainDefaultField -Plan $Plan -Object $capacityDoc -Name 'Overrides' -Default (New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)) -File $domainFile -Locator '$.Overrides'
            Assert-TPMObject -Value $capacityOverrides
            foreach($capacityOverrideEntry in $capacityOverrides.GetEnumerator()){
                $capacityOverrideDateText=[string]$capacityOverrideEntry.Key
                $capacityOverrideValue=$capacityOverrideEntry.Value
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Overrides/'+$capacityOverrideDateText) -Block {
                    $capacityOverrideDate=ConvertTo-TPMDate -Value $capacityOverrideDateText -Format 'yyyy-MM-dd'
                    $capacityOverrideHours=ConvertTo-TPMHours -Value $capacityOverrideValue -Maximum 2400
                    Add-TPMRow -Plan $Plan -Table 'capacity_overrides' -Values ([ordered]@{calendar_id=[long]1;work_date=$capacityOverrideDate;hours_x100=$capacityOverrideHours}) -File $domainFile -Locator ('$.Overrides/'+$capacityOverrideDateText)
                }
            }
            $domainContext.CalendarFile=$domainFile
        }
    }

    $domainFile='Data/CompanyClosures.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $closureDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $closureDoc
            Test-TPMKnownFields -Plan $Plan -Object $closureDoc -Names @('Version','Dates') -File $domainFile -Locator '$'
            $closureVersion=ConvertTo-TPMInteger -Value (Get-TPMField -Object $closureDoc -Name 'Version' -Required) -Minimum 1 -Maximum 1
            $closureDates=Get-TPMField -Object $closureDoc -Name 'Dates' -Required
            Assert-TPMArray -Value $closureDates
            for($closureIndex=0;$closureIndex -lt $closureDates.Length;$closureIndex++){
                $closureInput=$closureDates[$closureIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Dates['+$closureIndex+']') -Block {
                    $closureDate=ConvertTo-TPMDate -Value $closureInput -Format 'yyyy-MM-dd'
                    Add-TPMRow -Plan $Plan -Table 'company_closures' -Values ([ordered]@{calendar_id=[long]1;closure_date=$closureDate}) -File $domainFile -Locator ('$.Dates['+$closureIndex+']')
                }
            }
        }
    }

    $domainFile='Data/JapaneseHolidays.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $holidayDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $holidayDoc
            Test-TPMKnownFields -Plan $Plan -Object $holidayDoc -Names @('Version','Source','ImportedAt','FirstDate','LastDate','Holidays') -File $domainFile -Locator '$'
            $holidayVersion=ConvertTo-TPMInteger -Value (Get-TPMField -Object $holidayDoc -Name 'Version' -Required) -Minimum 1 -Maximum 1
            $holidaySource=ConvertTo-TPMString -Value (Get-TPMField -Object $holidayDoc -Name 'Source' -Required) -AllowEmpty
            $holidayImported=ConvertTo-TPMUtc -Value (Get-TPMField -Object $holidayDoc -Name 'ImportedAt' -Required)
            $holidayFirst=ConvertTo-TPMDate -Value (Get-TPMField -Object $holidayDoc -Name 'FirstDate' -Required) -Format 'yyyy-MM-dd'
            $holidayLast=ConvertTo-TPMDate -Value (Get-TPMField -Object $holidayDoc -Name 'LastDate' -Required) -Format 'yyyy-MM-dd'
            if($holidayFirst -gt $holidayLast){throw 'Holiday coverage starts after it ends.'}
            $holidayItems=Get-TPMField -Object $holidayDoc -Name 'Holidays' -Required
            Assert-TPMArray -Value $holidayItems
            Add-TPMRow -Plan $Plan -Table 'holiday_sets' -Values ([ordered]@{holiday_set_id=[long]1;name='移行した日本の祝日';source_name=$holidaySource;imported_at_utc=$holidayImported;first_date=$holidayFirst;last_date=$holidayLast;source_file_id=$null}) -File $domainFile -Locator '$'
            for($holidayIndex=0;$holidayIndex -lt $holidayItems.Length;$holidayIndex++){
                $holidayItem=$holidayItems[$holidayIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Holidays['+$holidayIndex+']') -Block {
                    Assert-TPMObject -Value $holidayItem
                    Test-TPMKnownFields -Plan $Plan -Object $holidayItem -Names @('Date','Name') -File $domainFile -Locator ('$.Holidays['+$holidayIndex+']')
                    $holidayDate=ConvertTo-TPMDate -Value (Get-TPMField -Object $holidayItem -Name 'Date' -Required) -Format 'yyyy-MM-dd'
                    if($holidayDate -lt $holidayFirst -or $holidayDate -gt $holidayLast){throw 'Holiday lies outside its declared source coverage.'}
                    $holidayName=ConvertTo-TPMString -Value (Get-TPMField -Object $holidayItem -Name 'Name' -Required) -AllowEmpty
                    Add-TPMRow -Plan $Plan -Table 'public_holidays' -Values ([ordered]@{holiday_set_id=[long]1;holiday_date=$holidayDate;name=$holidayName}) -File $domainFile -Locator ('$.Holidays['+$holidayIndex+']')
                }
            }
            $domainContext.Calendar.holiday_set_id=[long]1
            if($null -eq $domainContext.CalendarFile){$domainContext.CalendarFile=$domainFile}
        }
    }
    if($null -ne $domainContext.CalendarFile){
        Add-TPMRow -Plan $Plan -Table 'capacity_calendars' -Values $domainContext.Calendar -File $domainContext.CalendarFile -Locator '$'
    }

    $domainFile='Data/RecurringRules.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $recurringDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $recurringDoc
            Test-TPMKnownFields -Plan $Plan -Object $recurringDoc -Names @('Version','Rules') -File $domainFile -Locator '$'
            $recurringVersion=ConvertTo-TPMInteger -Value (Get-TPMField -Object $recurringDoc -Name 'Version' -Required) -Minimum 1 -Maximum 1
            $recurringItems=Get-TPMField -Object $recurringDoc -Name 'Rules' -Required
            Assert-TPMArray -Value $recurringItems
            for($recurringIndex=0;$recurringIndex -lt $recurringItems.Length;$recurringIndex++){
                $recurringItem=$recurringItems[$recurringIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Rules['+$recurringIndex+']') -Block {
                    Assert-TPMObject -Value $recurringItem
                    Test-TPMKnownFields -Plan $Plan -Object $recurringItem -Names @('Id','Name','Type','Weekday','Day','Nth','StartDate','Enabled','Note') -File $domainFile -Locator ('$.Rules['+$recurringIndex+']')
                    $recurringId=ConvertTo-TPMString -Value (Get-TPMField -Object $recurringItem -Name 'Id' -Required)
                    if($Plan.Rules.ContainsKey($recurringId)){throw 'Duplicate recurring rule ID; no rule is overwritten.'}
                    $recurringName=ConvertTo-TPMString -Value (Get-TPMField -Object $recurringItem -Name 'Name' -Required)
                    $recurringTypeName=ConvertTo-TPMString -Value (Get-TPMField -Object $recurringItem -Name 'Type' -Required)
                    $recurringWeekday=$null;$recurringDay=$null;$recurringNth=$null
                    switch -CaseSensitive ($recurringTypeName){
                        '毎日'{$recurringType='daily'}
                        '毎週'{$recurringType='weekly'}
                        '毎月（日付）'{$recurringType='monthly_day'}
                        '毎月（第N曜日）'{$recurringType='monthly_weekday'}
                        '毎月（第N営業日）'{$recurringType='monthly_business_day'}
                        '毎月（最終営業日）'{$recurringType='monthly_last_business_day'}
                        default{throw 'Unknown recurring rule Type.'}
                    }
                    if($recurringType -in @('weekly','monthly_weekday')){
                        $recurringWeekdayName=ConvertTo-TPMString -Value (Get-TPMField -Object $recurringItem -Name 'Weekday' -Required)
                        switch -CaseSensitive ($recurringWeekdayName){'日'{$recurringWeekday=[long]0};'月'{$recurringWeekday=[long]1};'火'{$recurringWeekday=[long]2};'水'{$recurringWeekday=[long]3};'木'{$recurringWeekday=[long]4};'金'{$recurringWeekday=[long]5};'土'{$recurringWeekday=[long]6};default{throw 'Invalid recurring weekday.'}}
                    }
                    if($recurringType -eq 'monthly_day'){$recurringDay=ConvertTo-TPMInteger -Value (Get-TPMField -Object $recurringItem -Name 'Day' -Required) -Minimum 1 -Maximum 31}
                    if($recurringType -eq 'monthly_weekday'){$recurringNth=ConvertTo-TPMInteger -Value (Get-TPMField -Object $recurringItem -Name 'Nth' -Required) -Minimum 1 -Maximum 5}
                    if($recurringType -eq 'monthly_business_day'){$recurringNth=ConvertTo-TPMInteger -Value (Get-TPMField -Object $recurringItem -Name 'Nth' -Required) -Minimum 1 -Maximum 31}
                    $recurringStart=ConvertTo-TPMDate -Value (Get-TPMField -Object $recurringItem -Name 'StartDate' -Required) -Format 'yyyy-MM-dd'
                    $recurringEnabled=ConvertTo-TPMDomainBoolean (Get-TPMField -Object $recurringItem -Name 'Enabled' -Required)
                    $recurringNote=ConvertTo-TPMString -Value (Get-TPMField -Object $recurringItem -Name 'Note' -Default '') -AllowEmpty
                    $recurringValues=[ordered]@{rule_id=$recurringId;name=$recurringName;rule_type=$recurringType;weekday=$recurringWeekday;day_of_month=$recurringDay;nth=$recurringNth;starts_on=$recurringStart;enabled=$recurringEnabled;note=$recurringNote;calendar_id=[long]1;business_day_policy='legacy_mon_fri_holidays_closures';is_deleted=[long]0;sort_order=[long]$recurringIndex}
                    $Plan.Rules.Add($recurringId,$recurringValues)
                    Add-TPMRow -Plan $Plan -Table 'recurring_rules' -Values $recurringValues -File $domainFile -Locator ('$.Rules['+$recurringIndex+']')
                }
            }
        }
    }

    $domainFile='Data/MonthlySnapshots.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $snapshotDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $snapshotDoc
            foreach($snapshotEntry in $snapshotDoc.GetEnumerator()){
                $snapshotKey=[string]$snapshotEntry.Key;$snapshotItem=$snapshotEntry.Value
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$/'+$snapshotKey) -Block {
                    Assert-TPMObject -Value $snapshotItem
                    Test-TPMKnownFields -Plan $Plan -Object $snapshotItem -Names @('Month','CapacityHours','Workdays','PlannedHours','PlannedRate','LoggedHours','CompletedActualHours','CompletedCount','DifferenceHours','FinalizedAt','Source','Revision') -File $domainFile -Locator ('$/'+$snapshotKey)
                    if($snapshotKey -cnotmatch '^[0-9]{4}/(0[1-9]|1[0-2])$'){throw 'Invalid legacy snapshot month key.'}
                    $snapshotMonth=(ConvertTo-TPMDate -Value ($snapshotKey+'/01')).Substring(0,7)
                    $snapshotDeclared=ConvertTo-TPMString -Value (Get-TPMField -Object $snapshotItem -Name 'Month' -Required)
                    if($snapshotDeclared -cne $snapshotKey){throw 'Snapshot Month contradicts its map key.'}
                    $snapshotRevision=ConvertTo-TPMInteger -Value (Get-TPMField -Object $snapshotItem -Name 'Revision' -Required) -Minimum 1
                    $snapshotRateInput=Get-TPMField -Object $snapshotItem -Name 'PlannedRate' -Required
                    $snapshotRate=$null;if($null -ne $snapshotRateInput){$snapshotRate=ConvertTo-TPMHours -Value $snapshotRateInput}
                    $snapshotValues=[ordered]@{
                        calendar_id=[long]1;month_key=$snapshotMonth;revision=$snapshotRevision
                        capacity_hours_x100=(ConvertTo-TPMHours -Value (Get-TPMField -Object $snapshotItem -Name 'CapacityHours' -Required))
                        workdays=(ConvertTo-TPMInteger -Value (Get-TPMField -Object $snapshotItem -Name 'Workdays' -Required))
                        planned_hours_x100=(ConvertTo-TPMHours -Value (Get-TPMField -Object $snapshotItem -Name 'PlannedHours' -Required));planned_rate_x100=$snapshotRate
                        logged_hours_x100=(ConvertTo-TPMHours -Value (Get-TPMField -Object $snapshotItem -Name 'LoggedHours' -Required))
                        completed_actual_hours_x100=(ConvertTo-TPMHours -Value (Get-TPMField -Object $snapshotItem -Name 'CompletedActualHours' -Required))
                        completed_count=(ConvertTo-TPMInteger -Value (Get-TPMField -Object $snapshotItem -Name 'CompletedCount' -Required))
                        difference_hours_x100=(ConvertTo-TPMHours -Value (Get-TPMField -Object $snapshotItem -Name 'DifferenceHours' -Required) -Signed)
                        finalized_at_utc=(ConvertTo-TPMUtc -Value (Get-TPMField -Object $snapshotItem -Name 'FinalizedAt' -Required))
                        source=(ConvertTo-TPMString -Value (Get-TPMField -Object $snapshotItem -Name 'Source' -Required) -AllowEmpty)
                        reason='旧版の確定値を移行（旧版の修正履歴は別途保持）';source_file_id=$null
                    }
                    Add-TPMRow -Plan $Plan -Table 'monthly_snapshots' -Values ([ordered]@{calendar_id=[long]1;month_key=$snapshotMonth;current_revision=$snapshotRevision}) -File $domainFile -Locator ('$/'+$snapshotKey)
                    Add-TPMRow -Plan $Plan -Table 'monthly_snapshot_revisions' -Values $snapshotValues -File $domainFile -Locator ('$/'+$snapshotKey)
                }
            }
        }
    }

    $domainFile='Data/MonthlySnapshotAudit.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $auditDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMArray -Value $auditDoc
            for($auditIndex=0;$auditIndex -lt $auditDoc.Length;$auditIndex++){
                $auditItem=$auditDoc[$auditIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$['+$auditIndex+']') -Block {
                    Assert-TPMObject -Value $auditItem
                    Test-TPMKnownFields -Plan $Plan -Object $auditItem -Names @('At','Month','Reason','Before','After') -File $domainFile -Locator ('$['+$auditIndex+']')
                    $auditBefore=Get-TPMField -Object $auditItem -Name 'Before' -Required
                    $auditAfter=Get-TPMField -Object $auditItem -Name 'After' -Required
                    if($null -ne $auditBefore){Assert-TPMObject -Value $auditBefore};Assert-TPMObject -Value $auditAfter
                    $auditBeforeJson=$null;if($null -ne $auditBefore){$auditBeforeJson=[TaskPilot.Migration.Codec]::ToJson($auditBefore)}
                    Add-TPMRow -Plan $Plan -Table 'legacy_monthly_audit' -Values ([ordered]@{
                        source_file_id=$null;source_ordinal=[long]$auditIndex
                        month_text=(ConvertTo-TPMString -Value (Get-TPMField -Object $auditItem -Name 'Month' -Required) -AllowEmpty)
                        at_text=(ConvertTo-TPMString -Value (Get-TPMField -Object $auditItem -Name 'At' -Required) -AllowEmpty)
                        reason=(ConvertTo-TPMString -Value (Get-TPMField -Object $auditItem -Name 'Reason' -Required) -AllowEmpty)
                        before_json=$auditBeforeJson;after_json=([TaskPilot.Migration.Codec]::ToJson($auditAfter))
                    }) -File $domainFile -Locator ('$['+$auditIndex+']')
                }
            }
        }
    }

    $domainFile='Settings.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $settingsDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $settingsDoc
            Test-TPMKnownFields -Plan $Plan -Object $settingsDoc -Names @('NotifyOnStartup','NotifyDays','DailyNotifyEnabled','DailyNotifyTime') -File $domainFile -Locator '$'
            $settingsStartup=Get-TPMDomainDefaultField -Plan $Plan -Object $settingsDoc -Name 'NotifyOnStartup' -Default $true -File $domainFile -Locator '$.NotifyOnStartup'
            $settingsDays=Get-TPMDomainDefaultField -Plan $Plan -Object $settingsDoc -Name 'NotifyDays' -Default (Get-TPMDomainNumber '3') -File $domainFile -Locator '$.NotifyDays'
            $settingsDaily=Get-TPMDomainDefaultField -Plan $Plan -Object $settingsDoc -Name 'DailyNotifyEnabled' -Default $false -File $domainFile -Locator '$.DailyNotifyEnabled'
            $settingsTime=Get-TPMDomainDefaultField -Plan $Plan -Object $settingsDoc -Name 'DailyNotifyTime' -Default '09:00' -File $domainFile -Locator '$.DailyNotifyTime'
            $settingsTime=ConvertTo-TPMString -Value $settingsTime
            if($settingsTime -cnotmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$'){throw 'Invalid legacy DailyNotifyTime.'}
            Add-TPMRow -Plan $Plan -Table 'app_settings' -Values ([ordered]@{singleton_id=[long]1;notify_on_startup=(ConvertTo-TPMDomainBoolean $settingsStartup);notify_days=(ConvertTo-TPMInteger -Value $settingsDays -Maximum 30);daily_notify_enabled=(ConvertTo-TPMDomainBoolean $settingsDaily);daily_notify_time=$settingsTime}) -File $domainFile -Locator '$'
        }
    }

    $domainFile='Data/NotificationState.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $notificationDoc=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMObject -Value $notificationDoc
            Test-TPMKnownFields -Plan $Plan -Object $notificationDoc -Names @('Seen','Snoozed') -File $domainFile -Locator '$'
            $notificationSeen=Get-TPMDomainDefaultField -Plan $Plan -Object $notificationDoc -Name 'Seen' -Default ([object[]]@()) -File $domainFile -Locator '$.Seen'
            $notificationSnoozed=Get-TPMDomainDefaultField -Plan $Plan -Object $notificationDoc -Name 'Snoozed' -Default ([object[]]@()) -File $domainFile -Locator '$.Snoozed'
            Assert-TPMArray -Value $notificationSeen;Assert-TPMArray -Value $notificationSnoozed
            for($seenIndex=0;$seenIndex -lt $notificationSeen.Length;$seenIndex++){
                $seenItem=$notificationSeen[$seenIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Seen['+$seenIndex+']') -Block {
                    $seenKey=ConvertTo-TPMString -Value $seenItem
                    if($domainContext.SeenKeys.Contains($seenKey)){throw 'Duplicate Seen notification key; no entry is silently dropped.'}
                    $domainContext.SeenKeys.Add($seenKey,$true)
                    Reserve-TPMDomainNotificationIdentity -Plan $Plan -Key $seenKey
                    if(-not $domainContext.NotificationStates.Contains($seenKey)){$domainContext.NotificationStates.Add($seenKey,[ordered]@{alert_key=$seenKey;is_seen=[long]0;snoozed_until_utc=$null})}
                    $domainContext.NotificationStates[$seenKey].is_seen=[long]1
                }
            }
            for($snoozedIndex=0;$snoozedIndex -lt $notificationSnoozed.Length;$snoozedIndex++){
                $snoozedItem=$notificationSnoozed[$snoozedIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$.Snoozed['+$snoozedIndex+']') -Block {
                    Assert-TPMObject -Value $snoozedItem
                    Test-TPMKnownFields -Plan $Plan -Object $snoozedItem -Names @('Key','Until') -File $domainFile -Locator ('$.Snoozed['+$snoozedIndex+']')
                    $snoozedKey=ConvertTo-TPMString -Value (Get-TPMField -Object $snoozedItem -Name 'Key' -Required)
                    if($domainContext.SnoozedKeys.Contains($snoozedKey)){throw 'Duplicate Snoozed notification key; no time is overwritten.'}
                    $domainContext.SnoozedKeys.Add($snoozedKey,$true)
                    $snoozedUntil=ConvertTo-TPMUtc -Value (Get-TPMField -Object $snoozedItem -Name 'Until' -Required)
                    Reserve-TPMDomainNotificationIdentity -Plan $Plan -Key $snoozedKey
                    if(-not $domainContext.NotificationStates.Contains($snoozedKey)){$domainContext.NotificationStates.Add($snoozedKey,[ordered]@{alert_key=$snoozedKey;is_seen=[long]0;snoozed_until_utc=$null})}
                    $domainContext.NotificationStates[$snoozedKey].snoozed_until_utc=$snoozedUntil
                }
            }
            foreach($notificationStateEntry in $domainContext.NotificationStates.GetEnumerator()){
                Add-TPMRow -Plan $Plan -Table 'notification_state' -Values $notificationStateEntry.Value -File $domainFile -Locator ('$/'+[string]$notificationStateEntry.Key)
            }
        }
    }

    $domainFile='Data/NotificationHistory.json'
    if($Plan.Documents.ContainsKey($domainFile)){
        $notificationHistory=Get-TPMDocument -Plan $Plan -File $domainFile
        Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator '$' -Block {
            Assert-TPMArray -Value $notificationHistory
            for($historyIndex=0;$historyIndex -lt $notificationHistory.Length;$historyIndex++){
                $historyItem=$notificationHistory[$historyIndex]
                Invoke-TPMRecord -Plan $Plan -File $domainFile -Locator ('$['+$historyIndex+']') -Block {
                    Assert-TPMObject -Value $historyItem
                    Test-TPMKnownFields -Plan $Plan -Object $historyItem -Names @('Time','Action','ID','Task','Category') -File $domainFile -Locator ('$['+$historyIndex+']')
                    $historyIdText=ConvertTo-TPMString -Value (Get-TPMField -Object $historyItem -Name 'ID' -Required) -AllowEmpty
                    $historyParent=Resolve-TPMParent -Plan $Plan -Value $historyIdText
                    if($null -eq $historyParent){Add-TPMIssue -Plan $Plan -Severity warning -File $domainFile -Locator ('$['+$historyIndex+']') -Code 'notification_missing_task' -Message 'Notification keeps its legacy task ID/name without inventing a missing parent.'}
                    Add-TPMRow -Plan $Plan -Table 'notification_history' -Values ([ordered]@{
                        occurred_at_local_text=(ConvertTo-TPMString -Value (Get-TPMField -Object $historyItem -Name 'Time' -Required) -AllowEmpty)
                        occurred_at_utc=$null;timezone_id=$null
                        action=(ConvertTo-TPMString -Value (Get-TPMField -Object $historyItem -Name 'Action' -Required) -AllowEmpty)
                        legacy_task_id_text=$historyIdText;task_id=$historyParent
                        task_name_snapshot=(ConvertTo-TPMString -Value (Get-TPMField -Object $historyItem -Name 'Task' -Required) -AllowEmpty)
                        category=(ConvertTo-TPMString -Value (Get-TPMField -Object $historyItem -Name 'Category' -Required) -AllowEmpty)
                        sort_order=[long]$historyIndex
                    }) -File $domainFile -Locator ('$['+$historyIndex+']')
                }
            }
        }
    }
}
