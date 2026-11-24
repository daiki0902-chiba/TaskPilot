#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
$fullDomainModule=Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
. (Join-Path $PSScriptRoot 'MigrationDomainFixture.ps1')
$script:fullDomainChecks=0
$script:fullDomainStore=$null
function Check-FullMigrationDomain($Condition,[string]$Message){if(-not $Condition){throw "FAILED: $Message"};$script:fullDomainChecks++}
function Read-FullMigrationRows([string]$Sql){
    return & $fullDomainModule {param($domainTestStore,$domainTestSql) Invoke-TPSql -Store $domainTestStore -Sql $domainTestSql -Mode Rows} $script:fullDomainStore $Sql
}
function Get-FullMigrationTreeHash([string]$Root){
    $hashes=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach($file in Get-ChildItem -LiteralPath $Root -File -Recurse){
        $relative=$file.FullName.Substring($Root.Length+1).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        $hashes.Add($relative,(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
    }
    return ,$hashes
}
$fullDomainRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilot-full-domains-日本語-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fullDomainRoot
$fullDomainSource=Join-Path $fullDomainRoot 'legacy-app-copy'
$fullDomainBackup=Join-Path $fullDomainRoot 'separate-backup'
$fullDomainDatabase=Join-Path $fullDomainRoot 'migrated-full.db'
$fullDomainProvider=@{};if($TestProviderAssembly){$fullDomainProvider.TestProviderAssembly=$TestProviderAssembly}
try{
    $null=New-Item -ItemType Directory -Path (Join-Path $fullDomainSource 'Data')
    $fullDomainFixture=New-MigrationDomainFixture
    foreach($fullDomainFile in $fullDomainFixture.GetEnumerator()){
        $fullDomainPath=Join-Path $fullDomainSource ($fullDomainFile.Key.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
        if($fullDomainFile.Key -eq 'Data/NextId.txt'){$fullDomainEncoding=[Text.Encoding]::ASCII}else{$fullDomainEncoding=New-Object Text.UTF8Encoding($true)}
        [IO.File]::WriteAllText($fullDomainPath,$fullDomainFile.Value,$fullDomainEncoding)
    }
    [IO.File]::WriteAllBytes((Join-Path $fullDomainSource 'Data/unrecognized.bin'),[byte[]]@(0,255,128,13,10,1))
    [IO.File]::WriteAllBytes((Join-Path $fullDomainSource 'RootExtra.dat'),[byte[]]@(10,20,30))
    $null=New-Item -ItemType Directory -Path (Join-Path $fullDomainSource 'Export')
    [IO.File]::WriteAllText((Join-Path $fullDomainSource 'Export/old-export.txt'),'Old derived output must be backed up, never executed.')
    $null=New-Item -ItemType Directory -Path (Join-Path $fullDomainSource 'KeepEmptyDirectory')
    $fullDomainBefore=Get-FullMigrationTreeHash $fullDomainSource
    $fullDomainInspection=Test-TaskPilotLegacyData -SourceRoot $fullDomainSource
    if(-not $fullDomainInspection.CanImport){$fullDomainInspection.Issues|Format-List|Out-String|Write-Host}
    Check-FullMigrationDomain ($fullDomainInspection.CanImport -and $fullDomainInspection.ErrorCount -eq 0) 'Public inspection accepts complete synthetic legacy store'
    Check-FullMigrationDomain ($fullDomainInspection.RequiresWarningAcknowledgement -and $fullDomainInspection.WarningCount -gt 0) 'Unknown fields/files and orphans require explicit warning acknowledgement'
    Check-FullMigrationDomain ($fullDomainInspection.SourceFileCount -eq 18 -and $fullDomainInspection.BackupFileCount -eq 20) 'Captured sources and complete backup inventory differ intentionally'
    Check-FullMigrationDomain (-not [IO.File]::Exists($fullDomainDatabase) -and -not [IO.Directory]::Exists($fullDomainBackup)) 'Inspection does not create DB or backup'
    $fullDomainImported=Import-TaskPilotLegacyData -SourceRoot $fullDomainSource -DatabasePath $fullDomainDatabase -BackupRoot $fullDomainBackup -ExpectedManifestSha256 $fullDomainInspection.ManifestSha256 -Apply -AcknowledgeWarnings @fullDomainProvider
    Check-FullMigrationDomain ([IO.File]::Exists($fullDomainDatabase) -and $fullDomainImported.BackupVerified) 'Coordinator publishes DB only after verified backup/import'
    Check-FullMigrationDomain (-not $fullDomainImported.LegacyFilesModified -and -not $fullDomainImported.AppSwitched) 'Old app/store remains the active untouched version'
    $fullDomainAfter=Get-FullMigrationTreeHash $fullDomainSource
    Check-FullMigrationDomain ($fullDomainBefore.Count -eq $fullDomainAfter.Count) 'Source tree file count unchanged'
    foreach($fullDomainHash in $fullDomainBefore.GetEnumerator()){
        Check-FullMigrationDomain ($fullDomainAfter.ContainsKey($fullDomainHash.Key) -and $fullDomainAfter[$fullDomainHash.Key] -ceq $fullDomainHash.Value) ('Original bytes unchanged: '+$fullDomainHash.Key)
    }
    $fullDomainBackupHashes=Get-FullMigrationTreeHash $fullDomainBackup
    Check-FullMigrationDomain ($fullDomainBefore.Count -eq $fullDomainBackupHashes.Count) 'Full backup retains every source file'
    foreach($fullDomainHash in $fullDomainBefore.GetEnumerator()){
        Check-FullMigrationDomain ($fullDomainBackupHashes.ContainsKey($fullDomainHash.Key) -and $fullDomainBackupHashes[$fullDomainHash.Key] -ceq $fullDomainHash.Value) ('Backup bytes verified: '+$fullDomainHash.Key)
    }
    Check-FullMigrationDomain ([IO.Directory]::Exists((Join-Path $fullDomainBackup 'KeepEmptyDirectory'))) 'Empty source directory preserved in backup'
    $fullDomainAgain=Test-TaskPilotLegacyData -SourceRoot $fullDomainSource
    Check-FullMigrationDomain ($fullDomainAgain.ManifestSha256 -ceq $fullDomainInspection.ManifestSha256) 'Source manifest unchanged after full import'
    $script:fullDomainStore=Open-TaskPilotStore -DatabasePath $fullDomainDatabase @fullDomainProvider
    $fullDomainExpectedCounts=[ordered]@{tasks=3;task_plans=2;subtasks=1;work_logs=1;completion_actuals=1;holiday_sets=1;public_holidays=2;capacity_calendars=1;calendar_weekdays=0;company_closures=2;capacity_overrides=2;recurring_rules=6;recurring_occurrences=1;app_settings=1;notification_state=3;notification_history=2;monthly_snapshots=1;monthly_snapshot_revisions=1;monthly_revision_events=1;legacy_monthly_audit=2;legacy_unresolved_records=2;import_batches=1;import_source_files=18}
    foreach($fullDomainTable in $fullDomainExpectedCounts.GetEnumerator()){
        $fullDomainCount=@(Read-FullMigrationRows ('SELECT COUNT(*) AS n FROM '+$fullDomainTable.Key))[0].n
        Check-FullMigrationDomain ($fullDomainCount -eq $fullDomainTable.Value) ('Actual normalized count: '+$fullDomainTable.Key)
    }
    $fullDomainCalendar=Get-TaskPilotCalendar -Store $script:fullDomainStore
    Check-FullMigrationDomain ($fullDomainCalendar.Data.daily_hours -eq [decimal]7.01 -and $fullDomainCalendar.Data.weekdays.Count -eq 0 -and $fullDomainCalendar.Data.holiday_set_id -eq 1) 'Public calendar getter retains zero weekdays and exact daily hours'
    Check-FullMigrationDomain ($fullDomainCalendar.Data.overrides.Count -eq 2 -and $fullDomainCalendar.Data.overrides[0].hours -eq 0 -and $fullDomainCalendar.Data.overrides[1].hours -eq [decimal]4.01) 'Public override getter preserves zero and .01h precision'
    $fullDomainMonth=Get-TaskPilotMonthlySnapshot -Store $script:fullDomainStore -MonthKey '2026-10'
    Check-FullMigrationDomain ($fullDomainMonth.revision -eq 5 -and $fullDomainMonth.finalized_at_utc -ceq '2026-11-01T00:00:00.1234567Z' -and $fullDomainMonth.source -ceq '確定当時の出典') 'Actual DB retains source monthly revision5/time/source'
    Check-FullMigrationDomain ($null -eq $fullDomainMonth.planned_rate -and $fullDomainMonth.difference_hours -eq [decimal]-40.01 -and $fullDomainMonth.workdays -eq 40) 'Actual monthly nullable/signed/manual values unchanged'
    $fullDomainMonthHistory=Get-TaskPilotMonthlySnapshot -Store $script:fullDomainStore -MonthKey '2026-10' -History
    Check-FullMigrationDomain ($fullDomainMonthHistory.Revisions.Count -eq 1 -and $fullDomainMonthHistory.Events.Count -eq 1 -and $null -eq $fullDomainMonthHistory.Events[0].before_revision) 'No fictitious revisions1..4 or prior normalized event invented'
    $fullDomainAudit=@(Read-FullMigrationRows 'SELECT source_ordinal,before_json,after_json,at_text FROM legacy_monthly_audit ORDER BY source_ordinal')
    $fullDomainAuditParsed=[TaskPilot.Migration.Codec]::ParseJson($fullDomainAudit[0].after_json)
    Check-FullMigrationDomain ($null -eq $fullDomainAudit[0].before_json -and $fullDomainAudit[1].source_ordinal -eq 1 -and $fullDomainAudit[0].at_text -ceq '2026-11-01T09:00:00.1234567+09:00') 'Actual legacy audit order/null/original offset text retained'
    Check-FullMigrationDomain ($fullDomainAuditParsed['Unknown']['Large'].Lexeme -ceq '9007199254740993' -and $fullDomainAuditParsed['Unknown']['Decimal'].Lexeme -ceq '0.0100') 'Actual audit JSON keeps exact large integer and fractional lexemes'
    $fullDomainNotifications=Get-TaskPilotNotifications -Store $script:fullDomainStore
    Check-FullMigrationDomain ($fullDomainNotifications.Data.history[1].legacy_task_id_text -ceq '900' -and $null -eq $fullDomainNotifications.Data.history[1].task_id -and $null -eq $fullDomainNotifications.Data.history[1].occurred_at_utc -and $fullDomainNotifications.Data.history[1].task_name_snapshot -ceq '削除済みの名称') 'Actual notification orphan, old name and unknown UTC retained'
    $fullDomainExpired=@($fullDomainNotifications.Data.state | Where-Object {$_.alert_key -ceq '20261115:1:期限間近'})[0]
    Check-FullMigrationDomain ($fullDomainExpired.is_seen -eq 1 -and $fullDomainExpired.snoozed_until_utc -ceq '2020-01-01T00:00:00.0000000Z') 'Actual merged state retains expired snooze without pruning'
    $fullDomainEvidence=@(Read-FullMigrationRows 'SELECT relative_path,raw_bytes,sha256,byte_count FROM import_source_files ORDER BY source_file_id')
    $fullDomainSha=[Security.Cryptography.SHA256]::Create()
    try{
        foreach($fullDomainBlob in $fullDomainEvidence){
            $fullDomainOriginalPath=Join-Path $fullDomainSource ($fullDomainBlob.relative_path.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
            $fullDomainExpectedHash=(Get-FileHash -LiteralPath $fullDomainOriginalPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $fullDomainActualHash=([BitConverter]::ToString($fullDomainSha.ComputeHash([byte[]]$fullDomainBlob.raw_bytes))).Replace('-','').ToLowerInvariant()
            Check-FullMigrationDomain ($fullDomainActualHash -ceq $fullDomainExpectedHash -and $fullDomainBlob.sha256 -ceq $fullDomainExpectedHash -and $fullDomainBlob.byte_count -eq $fullDomainBlob.raw_bytes.LongLength) ('Captured BLOB exact bytes/hash: '+$fullDomainBlob.relative_path)
        }
    }finally{$fullDomainSha.Dispose()}
    $fullDomainSourceLink=@(Read-FullMigrationRows "SELECT r.source_file_id,s.relative_path FROM monthly_snapshot_revisions r JOIN import_source_files s USING(source_file_id)")
    Check-FullMigrationDomain ($fullDomainSourceLink[0].relative_path -ceq 'Data/MonthlySnapshots.json') 'Coordinator fills source provenance IDs correctly'
    $fullDomainHigh=@(Read-FullMigrationRows "SELECT seq FROM sqlite_sequence WHERE name='tasks'")[0].seq
    Check-FullMigrationDomain ($fullDomainHigh -eq 900) 'Real SQLite task identity highwater includes orphan references'
    $fullDomainNew=Add-TaskPilotTask -Store $script:fullDomainStore -Title '移行後の追加'
    Check-FullMigrationDomain ($fullDomainNew.task_id -eq 901) 'New task cannot acquire old orphaned ID'
    Check-FullMigrationDomain (@(Read-FullMigrationRows 'PRAGMA foreign_key_check').Count -eq 0 -and @(Read-FullMigrationRows 'PRAGMA integrity_check')[0].integrity_check -ceq 'ok') 'Final real database passes foreign-key and integrity checks'
    Check-FullMigrationDomain (@(Read-FullMigrationRows "SELECT name FROM sqlite_schema WHERE type='trigger' AND name='import_source_no_update'").Count -eq 1) 'Evidence immutability trigger remains installed'
    $minimalDomainSource=Join-Path $fullDomainRoot 'minimal-copy'
    $minimalDomainBackup=Join-Path $fullDomainRoot 'minimal-backup'
    $minimalDomainDatabase=Join-Path $fullDomainRoot 'minimal.db'
    $null=New-Item -ItemType Directory -Path (Join-Path $minimalDomainSource 'Data')
    $minimalDomainFixture=New-MigrationDomainFixture -CoreOnly
    foreach($minimalDomainFile in $minimalDomainFixture.GetEnumerator()){
        $minimalDomainPath=Join-Path $minimalDomainSource ($minimalDomainFile.Key.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
        [IO.File]::WriteAllText($minimalDomainPath,$minimalDomainFile.Value,(New-Object Text.UTF8Encoding($true)))
    }
    $minimalDomainInspection=Test-TaskPilotLegacyData -SourceRoot $minimalDomainSource
    Check-FullMigrationDomain ($minimalDomainInspection.CanImport) 'Core-only source remains importable with optional files absent'
    $null=Import-TaskPilotLegacyData -SourceRoot $minimalDomainSource -DatabasePath $minimalDomainDatabase -BackupRoot $minimalDomainBackup -ExpectedManifestSha256 $minimalDomainInspection.ManifestSha256 -Apply -AcknowledgeWarnings @fullDomainProvider
    $minimalDomainStore=Open-TaskPilotStore -DatabasePath $minimalDomainDatabase @fullDomainProvider
    try{
        $minimalDomainCalendar=Get-TaskPilotCalendar -Store $minimalDomainStore
        $minimalDomainSettings=Get-TaskPilotSettings -Store $minimalDomainStore
        Check-FullMigrationDomain ($minimalDomainCalendar.Data.weekdays.Count -eq 5 -and $minimalDomainCalendar.Data.daily_hours -eq [decimal]8 -and $null -eq $minimalDomainCalendar.Data.holiday_set_id) 'Missing optional calendar file preserves actual seeded five weekdays and eight hours'
        Check-FullMigrationDomain ($minimalDomainSettings.Data.notify_days -eq 3 -and $minimalDomainSettings.Data.notify_on_startup -and -not $minimalDomainSettings.Data.daily_notify_enabled) 'Missing optional settings file preserves actual schema defaults'
        Check-FullMigrationDomain ($null -eq (Get-TaskPilotMonthlySnapshot -Store $minimalDomainStore -MonthKey '2026-10')) 'Absent monthly file does not invent finalized history'
    }finally{Close-TaskPilotStore $minimalDomainStore}
    Write-Output "PASS: $fullDomainChecks full-domain migration assertions; actual PowerShell/.NET SQLite; synthetic17-file source + unknown files/export/empty directory."
}finally{
    if($null -ne $script:fullDomainStore -and -not $script:fullDomainStore.Closed){Close-TaskPilotStore $script:fullDomainStore}
    Remove-Item -LiteralPath $fullDomainRoot -Recurse -Force -ErrorAction SilentlyContinue
}
