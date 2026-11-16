# STEP4C coordinator. No source document is ever executed or rewritten.
function Get-TPMigrationReport($Plan){
    $counts=[ordered]@{}
    foreach($table in $Plan.Rows.Keys){$counts[$table]=[long]$Plan.Rows[$table].Count}
    $counts['unresolved_records']=[long]$Plan.Unresolved.Count
    $errors=@($Plan.Issues | Where-Object {$_.Severity -eq 'error'}).Count
    $warnings=@($Plan.Issues | Where-Object {$_.Severity -eq 'warning'}).Count
    $total=[long]0;foreach($entry in $Plan.Snapshot.Tree){$total+=[long]$entry.Size}
    return [pscustomobject]@{
        Step='4.0C';SourceRoot=$Plan.Snapshot.SourceRoot;CapturedAtUtc=$Plan.CapturedAtUtc
        ManifestSha256=$Plan.Snapshot.ManifestSha256;CanImport=($errors-eq0)
        RequiresWarningAcknowledgement=($warnings-gt0);ErrorCount=$errors;WarningCount=$warnings
        Counts=[pscustomobject]$counts;ReservedTaskIdHighWater=$Plan.HighWater
        SourceFileCount=$Plan.Snapshot.Files.Count;BackupFileCount=$Plan.Snapshot.Tree.Count;BackupBytes=$total
        Files=@($Plan.Snapshot.Files | Select-Object RelativePath,Size,Sha256,ModifiedAtUtc)
        Issues=@($Plan.Issues | ForEach-Object {[pscustomobject]$_})
        LegacyFilesModified=$false;AppSwitched=$false
    }
}
function Test-TaskPilotLegacyData {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$SourceRoot,[long]$MaxFileBytes=67108864)
    $sourceLock=$null
    try{
        $sourceLock=Enter-TPMigrationSourceLock -SourceRoot $SourceRoot
        $snapshot=Get-TPMigrationSourceSnapshot -SourceRoot $SourceRoot -MaxFileBytes $MaxFileBytes
        $plan=New-TPMMemoryPlan $snapshot
        $null=Test-TPMigrationSourceUnchanged $snapshot
        return Get-TPMigrationReport $plan
    }finally{if($null-ne$sourceLock){$sourceLock.Dispose()}}
}
function Assert-TPMigrationNewDatabase([string]$Path,[string]$SourceRoot){
    $full=Get-TPResolvedPath $Path
    Assert-TPMigrationNoLinks $full
    if([IO.Path]::GetExtension($full)-notin@('.db','.sqlite','.sqlite3')){throw 'Choose a new .db, .sqlite or .sqlite3 destination.'}
    if(Test-TPMigrationEqualOrBelow $full $SourceRoot){throw 'The new database must be outside the legacy source directory.'}
    if(-not[IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))){throw 'Database destination parent must already exist.'}
    foreach($suffix in @('','-journal','-wal','-shm')){if(Test-TPMigrationPathExists ($full+$suffix)){throw 'Database destination or a recovery sidecar already exists; no existing file will be overwritten.'}}
    return $full
}
function Invoke-TPMigrationInsert($Store,[string]$Table,[Collections.IDictionary]$Values){
    # Identifiers originate exclusively in the normalizers, never in source keys.
    if($Table-cnotmatch'^[a-z_][a-z0-9_]*$'){throw 'Invalid internal table identifier.'}
    $columns=@($Values.Keys);$parameters=@{};$names=New-Object 'Collections.Generic.List[string]'
    for($i=0;$i-lt$columns.Count;$i++){
        if([string]$columns[$i]-cnotmatch'^[a-z_][a-z0-9_]*$'){throw 'Invalid internal column identifier.'}
        $name='p'+$i;$names.Add('@'+$name);$parameters[$name]=$Values[$columns[$i]]
    }
    $null=Invoke-TPSql $Store ('INSERT INTO '+$Table+' ('+($columns-join',')+') VALUES ('+($names-join',')+')') -Parameters $parameters -Mode NonQuery
}
function Invoke-TPMigrationSeedUpdate($Store,[string]$Table,[Collections.IDictionary]$Values,[string]$Key){
    $sets=New-Object 'Collections.Generic.List[string]';$parameters=@{identity=$Values[$Key]};$i=0
    foreach($column in $Values.Keys){if($column-eq$Key){continue};$name='p'+$i;$i++;$sets.Add($column+'=@'+$name);$parameters[$name]=$Values[$column]}
    $changed=Invoke-TPSql $Store ('UPDATE '+$Table+' SET '+($sets-join',')+' WHERE '+$Key+'=@identity') -Parameters $parameters -Mode NonQuery
    if($changed-ne1){throw 'A required schema singleton was absent.'}
}
function Get-TPMigrationExpectedTables($Plan,$FileIds){
    $expected=[ordered]@{}
    foreach($table in $Plan.Rows.Keys){
        $expected[$table]=New-Object 'Collections.Generic.List[object]'
        foreach($row in $Plan.Rows[$table]){
            $values=[ordered]@{};foreach($column in $row.Values.Keys){$values[$column]=$row.Values[$column]}
            if($values.Contains('source_file_id')){$values.source_file_id=[long]$FileIds[$row.File]}
            $expected[$table].Add($values)
        }
    }
    if($expected.capacity_calendars.Count-eq0){$expected.capacity_calendars.Add([ordered]@{calendar_id=[long]1;name='既定の稼働条件';daily_hours_x100=[long]800;work_on_holidays=[long]0;holiday_set_id=$null})}
    if(-not$Plan.Documents.ContainsKey('Data/CapacitySettings.json')){foreach($day in 1..5){$expected.calendar_weekdays.Add([ordered]@{calendar_id=[long]1;weekday=[long]$day})}}
    if($expected.app_settings.Count-eq0){$expected.app_settings.Add([ordered]@{singleton_id=[long]1;notify_on_startup=[long]1;notify_days=[long]3;daily_notify_enabled=[long]0;daily_notify_time='09:00'})}
    return ,$expected
}
function Assert-TPMigrationRows($Store,[string]$Table,$ExpectedRows){
    $actualCount=[long](Invoke-TPSql $Store ('SELECT COUNT(*) FROM '+$Table) -Mode Scalar)
    if($actualCount-ne$ExpectedRows.Count){throw ('Migration row-count verification failed: '+$Table)}
    if($ExpectedRows.Count-eq0){return}
    $columns=@($ExpectedRows[0].Keys)
    $expectedStrings=New-Object 'Collections.Generic.List[string]'
    foreach($row in $ExpectedRows){
        $values=[object[]]@(foreach($column in $columns){$row[$column]})
        $expectedStrings.Add([TaskPilot.Migration.Codec]::ToJson($values))
    }
    $actualStrings=New-Object 'Collections.Generic.List[string]'
    foreach($row in @(Invoke-TPSql $Store ('SELECT '+($columns-join',')+' FROM '+$Table))){
        $values=[object[]]@(foreach($column in $columns){$row.$column})
        $actualStrings.Add([TaskPilot.Migration.Codec]::ToJson($values))
    }
    $expectedStrings.Sort([StringComparer]::Ordinal);$actualStrings.Sort([StringComparer]::Ordinal)
    for($i=0;$i-lt$expectedStrings.Count;$i++){if($expectedStrings[$i]-cne$actualStrings[$i]){throw ('Migration field verification failed: '+$Table)}}
}
function Assert-TPMigrationDatabase($Store,$Plan,$Expected,$Evidence,[string]$BatchId){
    foreach($table in $Expected.Keys){Assert-TPMigrationRows $Store $table $Expected[$table]}
    foreach($table in @('import_batches','import_source_files','import_issues','legacy_unresolved_records')){Assert-TPMigrationRows $Store $table $Evidence[$table]}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        # Prefixing text prevents provider-specific automatic date conversion.
        $raw=@(Invoke-TPSql $Store 'SELECT source_file_id,raw_bytes FROM import_source_files')
        if($raw.Count-ne$Plan.Snapshot.Files.Count){throw 'Captured source count verification failed.'}
        for($i=0;$i-lt$raw.Count;$i++){
            $entry=$raw[$i];$file=$Plan.Snapshot.Files[[int]$entry.source_file_id-1]
            if($entry.raw_bytes-isnot[byte[]] -or $entry.raw_bytes.LongLength-ne$file.Size){throw 'Captured BLOB length verification failed.'}
            $hash=([BitConverter]::ToString($sha.ComputeHash([byte[]]$entry.raw_bytes))).Replace('-','').ToLowerInvariant()
            if($hash-cne$file.Sha256){throw 'Captured source BLOB hash verification failed.'}
        }
    }finally{$sha.Dispose()}
    $events=New-Object 'Collections.Generic.List[object]'
    foreach($row in $Expected.monthly_snapshot_revisions){$events.Add([ordered]@{calendar_id=$row.calendar_id;month_key=$row.month_key;revision=$row.revision;before_revision=$null;reason=$row.reason;changed_at_utc=$row.finalized_at_utc})}
    Assert-TPMigrationRows $Store monthly_revision_events $events
    if([long](Invoke-TPSql $Store "SELECT seq FROM sqlite_sequence WHERE name='tasks'" -Mode Scalar)-ne$Plan.HighWater){throw 'Task identity high-water verification failed.'}
    if([string](Invoke-TPSql $Store 'PRAGMA integrity_check' -Mode Scalar)-cne'ok'){throw 'SQLite integrity check failed.'}
    if(@(Invoke-TPSql $Store 'PRAGMA foreign_key_check').Count-ne0){throw 'SQLite foreign-key check failed.'}
    if([long](Invoke-TPSql $Store 'SELECT is_dirty FROM report_state WHERE singleton_id=1' -Mode Scalar)-ne1){throw 'Imported reports must be regenerated explicitly.'}
}
function Import-TaskPilotLegacyData {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)][string]$SourceRoot,
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [Parameter(Mandatory=$true)][string]$BackupRoot,
        [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedManifestSha256,
        [switch]$Apply,[switch]$AcknowledgeWarnings,[string]$TestProviderAssembly,[long]$MaxFileBytes=67108864
    )
    if(-not$Apply){throw 'Import requires -Apply. Inspect first with Test-TaskPilotLegacyData.'}
    $sourceLock=$null;$store=$null;$stage=$null;$ownedStage=$false
    try{
        $sourceLock=Enter-TPMigrationSourceLock -SourceRoot $SourceRoot
        $snapshot=Get-TPMigrationSourceSnapshot -SourceRoot $SourceRoot -MaxFileBytes $MaxFileBytes
        if($snapshot.ManifestSha256-cne$ExpectedManifestSha256){throw 'Legacy source changed since inspection. Inspect again; no database or backup was created.'}
        $plan=New-TPMMemoryPlan $snapshot;$report=Get-TPMigrationReport $plan
        if(-not$report.CanImport){throw ('Migration inspection has '+$report.ErrorCount+' error(s). Resolve them before importing; no database or backup was created.')}
        if($report.RequiresWarningAcknowledgement -and -not$AcknowledgeWarnings){throw 'Review inspection warnings and explicitly use -AcknowledgeWarnings before importing. No database or backup was created.'}
        $final=Assert-TPMigrationNewDatabase $DatabasePath $snapshot.SourceRoot
        $backupPath=Get-TPMigrationFullPath $BackupRoot;Assert-TPMigrationNoLinks $backupPath
        if((Test-TPMigrationEqualOrBelow $final $backupPath)-or(Test-TPMigrationEqualOrBelow $backupPath $final)){throw 'Database and backup destinations must be disjoint.'}
        # Provider preflight happens before the potentially large external backup.
        $null=Get-TaskPilotProviderInfo -TestProviderAssembly $TestProviderAssembly
        $backup=Copy-TPMigrationBackup -Snapshot $snapshot -DestinationRoot $backupPath
        $stage=Join-Path ([IO.Path]::GetDirectoryName($final)) ('.taskpilot4c_'+[guid]::NewGuid().ToString('N')+'.db')
        $null=New-TaskPilotDatabase -DatabasePath $stage -TestProviderAssembly $TestProviderAssembly;$ownedStage=$true
        $store=Open-TaskPilotStore -DatabasePath $stage -TestProviderAssembly $TestProviderAssembly
        $batchId=[guid]::NewGuid().ToString('N')
        $null=Invoke-TPUnitOfWork $store {
            $evidence=[ordered]@{};foreach($name in @('import_batches','import_source_files','import_issues','legacy_unresolved_records')){$evidence[$name]=New-Object 'Collections.Generic.List[object]'}
            $batch=[ordered]@{batch_id=$batchId;captured_at_utc=$plan.CapturedAtUtc;committed_at_utc=$null;source_label=$snapshot.SourceRoot;state='staged';manifest_sha256=$snapshot.ManifestSha256}
            Invoke-TPMigrationInsert $store import_batches $batch
            $fileIds=New-Object 'Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
            $fileId=[long]0
            foreach($file in $snapshot.Files){
                $fileId++;$fileIds.Add($file.RelativePath,$fileId)
                $values=[ordered]@{source_file_id=$fileId;batch_id=$batchId;relative_path=$file.RelativePath;sha256=$file.Sha256;byte_count=[long]$file.Size;raw_bytes=[byte[]]$file.Bytes;source_modified_at_text=$file.ModifiedAtUtc}
                Invoke-TPMigrationInsert $store import_source_files $values
                # BLOBs are checked by byte length and SHA256 separately.
                $metadata=[ordered]@{};foreach($key in $values.Keys){if($key-ne'raw_bytes'){$metadata[$key]=$values[$key]}}
                $evidence.import_source_files.Add($metadata)
            }
            foreach($issue in $plan.Issues){
                $values=[ordered]@{source_file_id=$fileIds[$issue.File];severity=$issue.Severity;record_locator=$issue.Locator;code=$issue.Code;message=$issue.Message}
                Invoke-TPMigrationInsert $store import_issues $values;$evidence.import_issues.Add($values)
            }
            foreach($orphan in $plan.Unresolved){
                $values=[ordered]@{source_file_id=$fileIds[$orphan.File];record_locator=$orphan.Locator;entity_kind=$orphan.Kind;legacy_task_id_text=$orphan.LegacyTaskId;reason=$orphan.Reason;payload_json=$orphan.PayloadJson;resolution_state='unresolved';resolution_note=$null}
                Invoke-TPMigrationInsert $store legacy_unresolved_records $values;$evidence.legacy_unresolved_records.Add($values)
            }
            $expected=Get-TPMigrationExpectedTables $plan $fileIds
            if($plan.Documents.ContainsKey('Data/CapacitySettings.json')){$null=Invoke-TPSql $store 'DELETE FROM calendar_weekdays WHERE calendar_id=1' -Mode NonQuery}
            $order=@('holiday_sets','public_holidays','capacity_calendars','calendar_weekdays','company_closures','capacity_overrides','tasks','task_plans','subtasks','work_logs','completion_actuals','recurring_rules','recurring_occurrences','app_settings','notification_state','notification_history','monthly_snapshots','monthly_snapshot_revisions','legacy_monthly_audit')
            foreach($table in $order){
                # Defaults are already seeded; insert only source-provided rows.
                foreach($row in $plan.Rows[$table]){
                    $values=[ordered]@{};foreach($column in $row.Values.Keys){$values[$column]=$row.Values[$column]}
                    if($values.Contains('source_file_id')){$values.source_file_id=[long]$fileIds[$row.File]}
                    if($table-eq'capacity_calendars'){Invoke-TPMigrationSeedUpdate $store $table $values calendar_id}
                    elseif($table-eq'app_settings'){Invoke-TPMigrationSeedUpdate $store $table $values singleton_id}
                    else{Invoke-TPMigrationInsert $store $table $values}
                }
            }
            $null=Invoke-TPSql $store "INSERT INTO sqlite_sequence(name,seq) SELECT 'tasks',@high WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='tasks')" -Parameters @{high=$plan.HighWater} -Mode NonQuery
            $null=Invoke-TPSql $store "UPDATE sqlite_sequence SET seq=MAX(seq,@high) WHERE name='tasks'" -Parameters @{high=$plan.HighWater} -Mode NonQuery
            $committed=Get-TPUtcNow
            $null=Invoke-TPSql $store "UPDATE import_batches SET state='committed',committed_at_utc=@now WHERE batch_id=@id" -Parameters @{now=$committed;id=$batchId} -Mode NonQuery
            $batch.state='committed';$batch.committed_at_utc=$committed;$evidence.import_batches.Add($batch)
            if($TestProviderAssembly -and (Test-Path variable:script:TPMigrationTestHook) -and $null-ne$script:TPMigrationTestHook){& $script:TPMigrationTestHook $store $plan}
            Assert-TPMigrationDatabase $store $plan $expected $evidence $batchId
            $null=Test-TPMigrationSourceUnchanged $snapshot
        }
        Close-TaskPilotStore $store;$store=$null
        $null=Test-TPMigrationSourceUnchanged $snapshot
        $null=Assert-TPMigrationNewDatabase $final $snapshot.SourceRoot
        [IO.File]::Move($stage,$final);$ownedStage=$false
        return [pscustomobject]@{Step='4.0C';DatabasePath=$final;BackupRoot=$backup.Root;BackupVerified=$backup.Verified;BatchId=$batchId;ManifestSha256=$snapshot.ManifestSha256;Counts=$report.Counts;WarningCount=$report.WarningCount;LegacyFilesModified=$false;AppSwitched=$false;TestOnly=[bool]$TestProviderAssembly}
    }finally{
        if($null-ne$store -and -not$store.Closed){Close-TaskPilotStore $store}
        if($ownedStage){foreach($suffix in @('','-journal','-wal','-shm')){if([IO.File]::Exists($stage+$suffix)){Remove-Item -LiteralPath ($stage+$suffix) -Force -ErrorAction SilentlyContinue}}}
        if($null-ne$sourceLock){$sourceLock.Dispose()}
    }
}
