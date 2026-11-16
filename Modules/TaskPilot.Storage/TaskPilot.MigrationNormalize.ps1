# Strict legacy inspection. Values are built in memory; this file performs no writes.
function Get-TPMField {
    param($Object,[string]$Name,[switch]$Required,$Default=$null)
    Assert-TPMObject $Object
    if($Object.Contains($Name)){return ,($Object[$Name])}
    if($Required){throw "Missing required field: $Name"}
    return ,$Default
}
function Assert-TPMObject($Value){if($Value -isnot [Collections.IDictionary]){throw 'Expected a JSON object.'}}
function Assert-TPMArray($Value){if($Value -isnot [object[]]){throw 'Expected a JSON array.'}}
function ConvertTo-TPMString($Value,[switch]$AllowEmpty){
    if($Value -isnot [string] -or (-not$AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))){throw 'Expected a text value.'}
    return [string]$Value
}
function ConvertTo-TPMScaledInteger {
    param($Value,[int]$Scale=0,[long]$Minimum=0,[long]$Maximum=[long]::MaxValue)
    if($Value -is [TaskPilot.Migration.JsonNumber]){$lexeme=$Value.Lexeme}
    elseif($Value -is [long] -or $Value -is [int] -or $Value -is [decimal]){$lexeme=$Value.ToString([cultureinfo]::InvariantCulture)}
    else{throw 'Expected a JSON numeric value (no string, Boolean or floating-point conversion).'}
    $match=[regex]::Match($lexeme,'^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$')
    if(-not$match.Success){throw 'Invalid numeric literal.'}
    $digits=($match.Groups[2].Value+$match.Groups[3].Value).TrimStart('0')
    if($digits.Length-eq0){if($Minimum-gt0){throw 'Zero is outside the supported range.'};return [long]0}
    $exponent=0
    if($match.Groups[4].Success -and -not[int]::TryParse($match.Groups[4].Value,[Globalization.NumberStyles]::AllowLeadingSign,[cultureinfo]::InvariantCulture,[ref]$exponent)){throw 'Numeric exponent is outside the exact supported range.'}
    $shift=[long]$exponent-$match.Groups[3].Value.Length+$Scale
    if($shift-ge0){
        if($digits.Length+$shift-gt19){throw 'Numeric value exceeds Int64 range.'}
        $integerText=$digits+('0'*[int]$shift)
    }else{
        $remove=-$shift
        if($remove-gt$digits.Length -or $digits.Substring($digits.Length-[int]$remove)-match'[^0]'){throw 'Numeric value cannot be converted without rounding or truncation.'}
        $integerText=$digits.Substring(0,$digits.Length-[int]$remove)
    }
    if($match.Groups[1].Value-eq'-'){$integerText='-'+$integerText}
    $result=[long]0
    if(-not[long]::TryParse($integerText,[Globalization.NumberStyles]::AllowLeadingSign,[cultureinfo]::InvariantCulture,[ref]$result) -or $result-lt$Minimum -or $result-gt$Maximum){throw 'Numeric value is outside the supported range.'}
    return $result
}
function ConvertTo-TPMInteger {param($Value,[long]$Minimum=0,[long]$Maximum=[long]::MaxValue);ConvertTo-TPMScaledInteger $Value -Minimum $Minimum -Maximum $Maximum}
function ConvertTo-TPMHours {param($Value,[long]$Maximum=[long]::MaxValue,[switch]$Signed);$min=if($Signed){[long]::MinValue}else{[long]0};ConvertTo-TPMScaledInteger $Value -Scale 2 -Minimum $min -Maximum $Maximum}
function ConvertTo-TPMDate {
    param($Value,[string]$Format='yyyy/MM/dd',[switch]$Optional)
    if($Optional -and ($null-eq$Value -or ($Value-is[string]-and$Value.Length-eq0))){return $null}
    $text=ConvertTo-TPMString $Value
    $date=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($text,$Format,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){throw "Invalid legacy date (expected $Format)."}
    return $date.ToString('yyyy-MM-dd',[cultureinfo]::InvariantCulture)
}
function ConvertTo-TPMUtc($Value){
    $text=ConvertTo-TPMString $Value
    if($text -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$'){throw 'Timestamp must include an explicit ISO UTC offset.'}
    $date=[DateTimeOffset]::MinValue
    if(-not[DateTimeOffset]::TryParse($text,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){throw 'Invalid offset timestamp.'}
    return $date.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[cultureinfo]::InvariantCulture)
}
function Get-TPMDocument($Plan,[string]$File){return ,($Plan.Documents[$File])}
function Add-TPMIssue {
    param($Plan,[ValidateSet('error','warning')][string]$Severity,[string]$File,[string]$Locator,[string]$Code,[string]$Message)
    $Plan.Issues.Add([ordered]@{Severity=$Severity;File=$File;Locator=$Locator;Code=$Code;Message=$Message})
}
function Invoke-TPMRecord {
    param($Plan,[string]$File,[string]$Locator,[scriptblock]$Block)
    try{& $Block}catch{Add-TPMIssue $Plan -Severity error -File $File -Locator $Locator -Code 'invalid_record' -Message $_.Exception.Message}
}
function Add-TPMRow {
    param($Plan,[string]$Table,[Collections.IDictionary]$Values,[string]$File,[string]$Locator)
    if(-not$Plan.Rows.Contains($Table)){throw "Unknown normalized table: $Table"}
    $Plan.Rows[$Table].Add([pscustomobject]@{Values=$Values;File=$File;Locator=$Locator})
}
function Test-TPMKnownFields {
    param($Plan,$Object,[string[]]$Names,[string]$File,[string]$Locator)
    Assert-TPMObject $Object
    foreach($key in $Object.Keys){if($Names-cnotcontains[string]$key){Add-TPMIssue $Plan -Severity warning -File $File -Locator $Locator -Code 'unknown_field_retained' -Message ('An unrecognized field is retained in the captured source: '+[string]$key)}}
}
function Resolve-TPMParent {
    param($Plan,$Value)
    if($Value-is[TaskPilot.Migration.JsonNumber]){$text=(ConvertTo-TPMInteger $Value -Minimum 1 -Maximum ([int]::MaxValue)).ToString([cultureinfo]::InvariantCulture)}
    elseif($Value-is[string]){$text=$Value}else{throw 'Task reference must be text or an exact integer.'}
    if($text-cmatch'^[0-9]+$'){
        $number=[long]0
        if(-not[long]::TryParse($text,[ref]$number) -or $number-lt1 -or $number-gt[int]::MaxValue){throw 'Task reference is outside the positive Int32 range.'}
        if($number-gt$Plan.HighWater){$Plan.HighWater=$number}
    }
    if($Plan.Tasks.ContainsKey($text)){return [long]$Plan.Tasks[$text]}
    return $null
}
function Add-TPMOrphan {
    param($Plan,[string]$File,[string]$Locator,[string]$Kind,[string]$LegacyTaskId,$Payload,[string]$Reason)
    $Plan.Unresolved.Add([ordered]@{File=$File;Locator=$Locator;Kind=$Kind;LegacyTaskId=$LegacyTaskId;Reason=$Reason;PayloadJson=[TaskPilot.Migration.Codec]::ToJson($Payload)})
    Add-TPMIssue $Plan -Severity warning -File $File -Locator $Locator -Code 'orphan_retained' -Message $Reason
}
function Get-TPMPlanValues($Plan,[long]$TaskId,[string]$File){
    $key=$TaskId.ToString([cultureinfo]::InvariantCulture)
    if(-not$Plan.Plans.Contains($key)){
        $values=[ordered]@{task_id=$TaskId;planned_on=$null;work_start_on=$null;estimated_hours_x100=[long]0}
        $Plan.Plans.Add($key,$values)
        Add-TPMRow $Plan -Table task_plans -Values $values -File $File -Locator ('task/'+$key)
    }
    return ,($Plan.Plans[$key])
}
function New-TPMMemoryPlan($Snapshot){
    . (Join-Path $script:TPModuleRoot '../../Codec/Import-TaskPilotMigrationCodec.ps1')
    $rows=[ordered]@{}
    foreach($name in @('tasks','task_plans','subtasks','work_logs','completion_actuals','holiday_sets','public_holidays','capacity_calendars','calendar_weekdays','company_closures','capacity_overrides','recurring_rules','recurring_occurrences','monthly_snapshots','monthly_snapshot_revisions','legacy_monthly_audit','app_settings','notification_state','notification_history')){$rows[$name]=New-Object 'Collections.Generic.List[object]'}
    $plan=[pscustomobject]@{Snapshot=$Snapshot;Rows=$rows;Issues=(New-Object 'Collections.Generic.List[object]');Unresolved=(New-Object 'Collections.Generic.List[object]');Files=(New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase));Documents=(New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase));Tasks=(New-Object 'Collections.Generic.Dictionary[string,long]' ([StringComparer]::Ordinal));Rules=(New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal));Plans=(New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal));HighWater=[long]0;CapturedAtUtc=(Get-TPUtcNow);SourceCounts=[ordered]@{}}
    $known=@('Data/TaskList.csv','Data/CompletedTask.csv','Data/NextId.txt','Data/PlannedDates.json','Data/WorkPlans.json','Data/Subtasks.json','Data/WorkLogs.json','Data/ActualHours.json','Data/CapacitySettings.json','Data/CompanyClosures.json','Data/JapaneseHolidays.json','Data/RecurringRules.json','Data/MonthlySnapshots.json','Data/MonthlySnapshotAudit.json','Data/NotificationState.json','Data/NotificationHistory.json','Settings.json')
    foreach($file in $Snapshot.Files){
        $plan.Files.Add($file.RelativePath,$file)
        if($known-inotcontains$file.RelativePath){Add-TPMIssue $plan -Severity warning -File $file.RelativePath -Locator '$' -Code 'unknown_file_retained' -Message 'Unrecognized Data file is preserved as raw bytes and in the full backup.';continue}
        if($file.RelativePath.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)){
            try{
                $text=[Text.UTF8Encoding]::new($false,$true).GetString($file.Bytes)
                $value=[TaskPilot.Migration.Codec]::ParseJson($text)
                $plan.Documents.Add($file.RelativePath,$value)
            }catch{Add-TPMIssue $plan -Severity error -File $file.RelativePath -Locator '$' -Code 'invalid_json' -Message $_.Exception.Message}
        }
    }
    foreach($required in @('Data/TaskList.csv','Data/CompletedTask.csv','Data/NextId.txt')){if(-not$plan.Files.ContainsKey($required)){Add-TPMIssue $plan -Severity error -File $required -Locator '$' -Code 'missing_required_file' -Message 'Required legacy core file is missing; no empty replacement will be created.'}}
    foreach($taskFile in @('Data/TaskList.csv','Data/CompletedTask.csv')){
        if(-not$plan.Files.ContainsKey($taskFile)){continue}
        Invoke-TPMRecord $plan -File $taskFile -Locator '$' -Block {
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($plan.Files[$taskFile].Bytes)
            $csv=[TaskPilot.Migration.Codec]::ParseCsv($text)
            $columns=@('ID','Date','Task','Priority','DueDate','Status','Memo')
            if($csv.Length-lt1 -or $csv[0].Length-ne7){throw 'Task CSV header is missing or has an incorrect column count.'}
            for($c=0;$c-lt7;$c++){if($csv[0][$c]-cne$columns[$c]){throw 'Task CSV columns differ from the supported legacy format.'}}
            $plan.SourceCounts[$taskFile]=[long]($csv.Length-1)
            for($rowIndex=1;$rowIndex-lt$csv.Length;$rowIndex++){
                $record=$csv[$rowIndex]
                Invoke-TPMRecord $plan -File $taskFile -Locator ('row['+$rowIndex+']') -Block {
                    if($record.Length-ne7){throw 'CSV record has an incorrect column count.'}
                    $rawId=$record[0];$id=[long]0
                    if($rawId-cnotmatch'^[0-9]+$' -or -not[long]::TryParse($rawId,[ref]$id) -or $id-lt1 -or $id-gt[int]::MaxValue){throw 'Task ID must be a positive Int32 value.'}
                    foreach($existing in $plan.Tasks.Values){if($existing-eq$id){throw 'Duplicate numeric task ID across legacy task files.'}}
                    $registered=ConvertTo-TPMDate $record[1];$title=ConvertTo-TPMString $record[2];$due=ConvertTo-TPMDate $record[4] -Optional
                    if(@('高','中','低')-cnotcontains$record[3] -or @('未着手','対応中','完了')-cnotcontains$record[5]){throw 'Unsupported priority or task status.'}
                    if($rawId-cne$id.ToString([cultureinfo]::InvariantCulture)){Add-TPMIssue $plan -Severity warning -File $taskFile -Locator ('row['+$rowIndex+']') -Code 'noncanonical_task_id' -Message 'Task ID text is normalized numerically; raw source and exact reference spelling are retained.'}
                    $plan.Tasks.Add($rawId,$id);if($id-gt$plan.HighWater){$plan.HighWater=$id}
                    Add-TPMRow $plan -Table tasks -Values ([ordered]@{task_id=$id;registered_on=$registered;title=$title;priority=$record[3];status=$record[5];due_on=$due;memo=$record[6];is_archived=[long][int]($taskFile-eq'Data/CompletedTask.csv')}) -File $taskFile -Locator ('row['+$rowIndex+']')
                }
            }
        }
    }
    if($plan.Files.ContainsKey('Data/NextId.txt')){
        Invoke-TPMRecord $plan -File 'Data/NextId.txt' -Locator '$' -Block {
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($plan.Files['Data/NextId.txt'].Bytes).Trim([char]0xFEFF,[char]13,[char]10,[char]32,[char]9)
            $next=[long]0
            if($text-cnotmatch'^[0-9]+$' -or -not[long]::TryParse($text,[ref]$next) -or $next-lt1 -or $next-gt[int]::MaxValue){throw 'NextId.txt is not a positive Int32 integer.'}
            if(($next-1)-gt$plan.HighWater){$plan.HighWater=$next-1}
        }
    }
    Convert-TPMLegacyTaskMetadata $plan
    Convert-TPMLegacyDomains $plan
    Convert-TPMLegacyMarkers $plan
    if($plan.HighWater-ge[int]::MaxValue){Add-TPMIssue $plan -Severity error -File 'Data/NextId.txt' -Locator '$' -Code 'task_id_exhausted' -Message 'The preserved ID high-water mark leaves no supported new task ID.'}
    Test-TPMPlanUniqueKeys $plan
    return $plan
}
function Convert-TPMLegacyTaskMetadata($Plan){
    foreach($metadataFile in @('Data/PlannedDates.json','Data/WorkPlans.json','Data/ActualHours.json')){
        if(-not$Plan.Documents.ContainsKey($metadataFile)){continue}
        $doc=Get-TPMDocument $Plan $metadataFile
        Invoke-TPMRecord $Plan -File $metadataFile -Locator '$' -Block {
            Assert-TPMObject $doc;$Plan.SourceCounts[$metadataFile]=[long]$doc.Count
            foreach($entry in $doc.GetEnumerator()){
                $legacyId=[string]$entry.Key;$item=$entry.Value
                Invoke-TPMRecord $Plan -File $metadataFile -Locator ('$/'+$legacyId) -Block {
                    $parent=Resolve-TPMParent $Plan -Value $legacyId
                    if($null-eq$parent){Add-TPMOrphan $Plan -File $metadataFile -Locator ('$/'+$legacyId) -Kind $metadataFile -LegacyTaskId $legacyId -Payload $item -Reason 'No exact legacy task ID matches this record. It is retained without attaching to a different task.';return}
                    switch($metadataFile){
                        'Data/PlannedDates.json'{$values=Get-TPMPlanValues $Plan $parent $metadataFile;$values.planned_on=ConvertTo-TPMDate $item}
                        'Data/WorkPlans.json'{Assert-TPMObject $item;Test-TPMKnownFields $Plan -Object $item -Names @('StartDate','EstimatedHours') -File $metadataFile -Locator ('$/'+$legacyId);$start=ConvertTo-TPMDate (Get-TPMField $item 'StartDate' -Required) -Optional;$hours=ConvertTo-TPMHours (Get-TPMField $item 'EstimatedHours' -Required);$values=Get-TPMPlanValues $Plan $parent $metadataFile;$values.work_start_on=$start;$values.estimated_hours_x100=$hours}
                        'Data/ActualHours.json'{Assert-TPMObject $item;Test-TPMKnownFields $Plan -Object $item -Names @('CompletedDate','ActualHours','TaskName') -File $metadataFile -Locator ('$/'+$legacyId);Add-TPMRow $Plan -Table completion_actuals -Values ([ordered]@{task_id=$parent;completed_on=(ConvertTo-TPMDate (Get-TPMField $item 'CompletedDate' -Required));actual_hours_x100=(ConvertTo-TPMHours (Get-TPMField $item 'ActualHours' -Required));task_name_snapshot=(ConvertTo-TPMString (Get-TPMField $item 'TaskName' -Required) -AllowEmpty)}) -File $metadataFile -Locator ('$/'+$legacyId)}
                    }
                }
            }
        }
    }
    foreach($childFile in @('Data/Subtasks.json','Data/WorkLogs.json')){
        if(-not$Plan.Documents.ContainsKey($childFile)){continue}
        $doc=Get-TPMDocument $Plan $childFile
        Invoke-TPMRecord $Plan -File $childFile -Locator '$' -Block {
            Assert-TPMArray $doc;$Plan.SourceCounts[$childFile]=[long]$doc.Length
            for($childIndex=0;$childIndex-lt$doc.Length;$childIndex++){
                $item=$doc[$childIndex]
                Invoke-TPMRecord $Plan -File $childFile -Locator ('$['+$childIndex+']') -Block {
                    Assert-TPMObject $item
                    $parentField=if($childFile-eq'Data/Subtasks.json'){'ParentId'}else{'TaskId'}
                    $parentValue=Get-TPMField $item $parentField -Required;$parent=Resolve-TPMParent $Plan $parentValue
                    $legacyId=[string]$parentValue
                    if($null-eq$parent){Add-TPMOrphan $Plan -File $childFile -Locator ('$['+$childIndex+']') -Kind $childFile -LegacyTaskId $legacyId -Payload $item -Reason 'Missing legacy parent; complete child record retained for review.';return}
                    if($childFile-eq'Data/Subtasks.json'){
                        Test-TPMKnownFields $Plan -Object $item -Names @('Id','ParentId','Title','Done') -File $childFile -Locator ('$['+$childIndex+']')
                        $done=Get-TPMField $item 'Done' -Required;if($done-isnot[bool]){throw 'Subtask Done must be a JSON Boolean.'}
                        Add-TPMRow $Plan -Table subtasks -Values ([ordered]@{subtask_id=(ConvertTo-TPMString (Get-TPMField $item 'Id' -Required));parent_task_id=$parent;title=(ConvertTo-TPMString (Get-TPMField $item 'Title' -Required));is_done=[long][int]$done;sort_order=[long]$childIndex}) -File $childFile -Locator ('$['+$childIndex+']')
                    }else{
                        Test-TPMKnownFields $Plan -Object $item -Names @('EntryId','TaskId','WorkDate','Hours','Memo') -File $childFile -Locator ('$['+$childIndex+']')
                        $hours=ConvertTo-TPMHours (Get-TPMField $item 'Hours' -Required) -Maximum 2400;if($hours-lt1){throw 'Work log hours must be positive.'}
                        Add-TPMRow $Plan -Table work_logs -Values ([ordered]@{entry_id=(ConvertTo-TPMString (Get-TPMField $item 'EntryId' -Required));task_id=$parent;work_date=(ConvertTo-TPMDate (Get-TPMField $item 'WorkDate' -Required));hours_x100=$hours;memo=(ConvertTo-TPMString (Get-TPMField $item 'Memo' -Required) -AllowEmpty);sort_order=[long]$childIndex}) -File $childFile -Locator ('$['+$childIndex+']')
                    }
                }
            }
        }
    }
}
function Convert-TPMLegacyMarkers($Plan){
    foreach($taskRow in $Plan.Rows.tasks){
        $matches=[regex]::Matches([string]$taskRow.Values.memo,'\[TP-RECUR:(?<rule>[^\]\r\n]+):(?<date>[0-9]{8})\]')
        if($matches.Count-gt1){Add-TPMIssue $Plan -Severity error -File $taskRow.File -Locator $taskRow.Locator -Code 'ambiguous_occurrence_markers' -Message 'Task has multiple recurrence markers; no occurrence was selected automatically.';continue}
        if($matches.Count-eq0){if(([string]$taskRow.Values.memo).Contains('TP-RECUR:')){Add-TPMIssue $Plan -Severity warning -File $taskRow.File -Locator $taskRow.Locator -Code 'unparsed_occurrence_marker' -Message 'Memo includes an unsupported recurrence-marker form; original text is retained.'};continue}
        $match=$matches[0];$ruleId=$match.Groups['rule'].Value
        Invoke-TPMRecord $Plan -File $taskRow.File -Locator ($taskRow.Locator+'/marker') -Block {
            $date=ConvertTo-TPMDate $match.Groups['date'].Value -Format yyyyMMdd
            if(-not$Plan.Rules.ContainsKey($ruleId)){Add-TPMOrphan $Plan -File $taskRow.File -Locator ($taskRow.Locator+'/marker') -Kind recurring_occurrence -LegacyTaskId ([string]$taskRow.Values.task_id) -Payload ([ordered]@{RuleId=$ruleId;Date=$date;TaskId=$taskRow.Values.task_id;Marker=$match.Value}) -Reason 'Referenced recurring rule is absent; original marker and task are retained.';return}
            Add-TPMRow $Plan -Table recurring_occurrences -Values ([ordered]@{rule_id=$ruleId;occurrence_date=$date;task_id=$taskRow.Values.task_id;generated_at_utc=$null;legacy_marker_text=$match.Value}) -File $taskRow.File -Locator ($taskRow.Locator+'/marker')
        }
    }
}
function Test-TPMPlanUniqueKeys($Plan){
    $keys=@{subtasks=@('subtask_id');work_logs=@('entry_id');calendar_weekdays=@('calendar_id','weekday');company_closures=@('calendar_id','closure_date');capacity_overrides=@('calendar_id','work_date');public_holidays=@('holiday_set_id','holiday_date');recurring_rules=@('rule_id');recurring_occurrences=@('rule_id','occurrence_date');notification_state=@('alert_key');monthly_snapshots=@('calendar_id','month_key')}
    foreach($table in $keys.Keys){
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($row in $Plan.Rows[$table]){
            $parts=@(foreach($column in $keys[$table]){$row.Values[$column]})
            $key=[TaskPilot.Migration.Codec]::ToJson([object[]]$parts)
            if(-not$seen.Add($key)){Add-TPMIssue $Plan -Severity error -File $row.File -Locator $row.Locator -Code 'duplicate_key' -Message ('Duplicate normalized key in '+$table+'; no record was overwritten.')}
        }
    }
}
