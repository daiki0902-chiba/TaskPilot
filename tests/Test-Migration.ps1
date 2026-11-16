#requires -Version 5.1
[CmdletBinding()]
param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$module=Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
$providerArgs=@{}
if($TestProviderAssembly){$providerArgs.TestProviderAssembly=$TestProviderAssembly}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilot4C_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$script:passed=0;$script:failed=0;$script:assertions=0
$utf8=[Text.UTF8Encoding]::new($true)
function Assert-TPIntegration([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw $Message}}
function Reject-TPIntegration([scriptblock]$Action,[string]$Message,[string]$ExpectedError=''){
    $rejected=$false;$actualError=''
    try{$null=&$Action}catch{$rejected=$true;$actualError=$_.Exception.Message}
    Assert-TPIntegration $rejected $Message
    if($ExpectedError){Assert-TPIntegration ($actualError-match$ExpectedError) ('Unexpected rejection reason: '+$actualError)}
}
function Invoke-TPIntegrationCase([string]$Name,[scriptblock]$Action){
    try{&$Action;$script:passed++;Write-Output ('PASS: '+$Name)}
    catch{$script:failed++;Write-Output ('FAIL: '+$Name+' : '+$_.Exception.Message);Write-Output $_.ScriptStackTrace}
}
function Write-TPFixtureText([string]$Source,[string]$Relative,[string]$Text){
    $path=Join-Path $Source $Relative
    $parent=Split-Path -Parent $path
    if(-not(Test-Path -LiteralPath $parent)){$null=New-Item -ItemType Directory -Path $parent -Force}
    [IO.File]::WriteAllText($path,$Text,$utf8)
}
function ConvertTo-TPFixtureCsv([string[]]$Fields){
    return (($Fields|ForEach-Object{ '"'+$_.Replace('"','""')+'"' }) -join ',')
}
function New-TPFixture {
    $caseRoot=Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $source=Join-Path $caseRoot 'legacy'
    $null=New-Item -ItemType Directory -Path (Join-Path $source 'Data') -Force
    $header='ID,Date,Task,Priority,DueDate,Status,Memo'+"`r`n"
    Write-TPFixtureText $source 'Data/TaskList.csv' ($header+'1,2026/11/15,Fixture task,中,,未着手,'+"`r`n")
    Write-TPFixtureText $source 'Data/CompletedTask.csv' $header
    Write-TPFixtureText $source 'Data/NextId.txt' '5'
    return [pscustomobject]@{Root=$caseRoot;Source=$source;Database=(Join-Path $caseRoot 'migrated.db');Backup=(Join-Path $caseRoot 'verified-backup')}
}
function Get-TPFixtureDigest([string]$Root){
    $entries=@(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object{
        ($_.FullName.Substring($Root.Length).Replace('\','/')+'|'+$_.Length+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)
    })
    return $entries -join "`n"
}
function Get-TPFixtureRows($Store,[string]$Sql){
    return ,@(& $module {param($s,$q) Invoke-TPSql -Store $s -Sql $q} $Store $Sql)
}
function Import-TPFixture($Fixture,$Inspection,[switch]$Acknowledge){
    Import-TaskPilotLegacyData -SourceRoot $Fixture.Source -DatabasePath $Fixture.Database -BackupRoot $Fixture.Backup -ExpectedManifestSha256 $Inspection.ManifestSha256 -Apply -AcknowledgeWarnings:$Acknowledge @providerArgs
}
function Assert-TPFixtureRejectedBeforeWrites($Fixture){
    $inspection=Test-TaskPilotLegacyData -SourceRoot $Fixture.Source
    Assert-TPIntegration (-not$inspection.CanImport) 'Inspection must identify blocking errors.'
    Reject-TPIntegration {Import-TPFixture $Fixture $inspection -Acknowledge} 'Apply with errors must be rejected.'
    Assert-TPIntegration (-not(Test-Path -LiteralPath $Fixture.Database)) 'Rejected import must not publish a database.'
    Assert-TPIntegration (-not(Test-Path -LiteralPath $Fixture.Backup)) 'Invalid data must be rejected before creating a backup.'
}
try{
    Invoke-TPIntegrationCase 'Inspection is read-only and excludes task text from summary' {
        $f=New-TPFixture;$before=Get-TPFixtureDigest $f.Source
        $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        Assert-TPIntegration $report.CanImport 'Minimal valid legacy source must be importable.'
        Assert-TPIntegration (-not$report.RequiresWarningAcknowledgement) 'Missing optional legacy files use seeded defaults without warnings.'
        Assert-TPIntegration ($report.ManifestSha256 -cmatch '^[0-9a-f]{64}$') 'Manifest must be a lower-case SHA256 digest.'
        Assert-TPIntegration ((Get-TPFixtureDigest $f.Source) -ceq $before) 'Inspection changed a legacy file.'
        Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database) -and -not(Test-Path -LiteralPath $f.Backup)) 'Inspection created a database or backup.'
        Assert-TPIntegration (($report|ConvertTo-Json -Depth 20) -notmatch 'Fixture task') 'Summary must not include task titles or raw records.'
        Reject-TPIntegration {Import-TaskPilotLegacyData -SourceRoot $f.Source -DatabasePath $f.Database -BackupRoot $f.Backup -ExpectedManifestSha256 $report.ManifestSha256 @providerArgs} 'Import without Apply must be rejected.'
    }
    Invoke-TPIntegrationCase 'Minimal import preserves defaults, evidence and NextId' {
        $f=New-TPFixture;$before=Get-TPFixtureDigest $f.Source
        $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        $result=Import-TPFixture $f $report
        Assert-TPIntegration (Test-Path -LiteralPath $f.Database -PathType Leaf) 'Committed database is missing.'
        Assert-TPIntegration ((Get-TPFixtureDigest $f.Source) -ceq $before) 'Import changed the legacy source.'
        Assert-TPIntegration ((Get-TPFixtureDigest $f.Backup) -ceq $before) 'Full backup differs from the original.'
        $store=Open-TaskPilotStore -DatabasePath $f.Database @providerArgs
        try{
            $batches=Get-TPFixtureRows $store 'SELECT state,manifest_sha256 FROM import_batches'
            Assert-TPIntegration ($batches.Count-eq1 -and $batches[0].state-ceq'committed' -and $batches[0].manifest_sha256-ceq$report.ManifestSha256) 'Import batch was not committed with the expected manifest.'
            Assert-TPIntegration ((Get-TPFixtureRows $store 'SELECT * FROM calendar_weekdays').Count-eq5) 'Missing capacity settings must preserve Monday-Friday defaults.'
            $calendar=Get-TPFixtureRows $store 'SELECT daily_hours_x100,work_on_holidays FROM capacity_calendars'
            Assert-TPIntegration ($calendar.Count-eq1 -and $calendar[0].daily_hours_x100-eq800 -and $calendar[0].work_on_holidays-eq0) 'Default calendar was changed.'
            Assert-TPIntegration ((Get-TPFixtureRows $store 'SELECT * FROM import_source_files').Count-eq3) 'Required raw source evidence is missing.'
            $new=Add-TaskPilotTask -Store $store -Title 'New after migration' -RegisteredOn '2026-11-16'
            Assert-TPIntegration ($new.task_id-eq5) 'Legacy NextId was not preserved.'
        }finally{Close-TaskPilotStore $store}
    }
    Invoke-TPIntegrationCase 'Unicode CSV, separate actuals, raw evidence, orphans and complete backup' {
        $f=New-TPFixture
        $title='日本語の"見積"とSQL ''quoted'''
        $memo="一行目`r`n二行目,引用符`"と DROP TABLE tasks;"
        $header='ID,Date,Task,Priority,DueDate,Status,Memo'+"`r`n"
        Write-TPFixtureText $f.Source 'Data/TaskList.csv' ($header+(ConvertTo-TPFixtureCsv @('1','2026/11/15',$title,'高','2026/11/20','未着手',$memo))+"`r`n")
        Write-TPFixtureText $f.Source 'Data/CompletedTask.csv' ($header+'2,2026/11/14,Archived but pending,低,,未着手,'+"`r`n")
        Write-TPFixtureText $f.Source 'Data/PlannedDates.json' '{"1":"2026/11/16"}'
        Write-TPFixtureText $f.Source 'Data/WorkPlans.json' '{"1":{"StartDate":"2026/11/15","EstimatedHours":0.01},"900":{"StartDate":"2026/11/15","EstimatedHours":2}}'
        Write-TPFixtureText $f.Source 'Data/Subtasks.json' '[{"Id":"original-child-id","ParentId":"1","Title":"子の見積","Done":false}]'
        Write-TPFixtureText $f.Source 'Data/WorkLogs.json' '[{"EntryId":"original-log-id","TaskId":"1","WorkDate":"2026/11/15","Hours":0.01,"Memo":"日別の実績"}]'
        Write-TPFixtureText $f.Source 'Data/ActualHours.json' '{"1":{"CompletedDate":"2026/11/15","ActualHours":2.34,"TaskName":"完了時点の名前"}}'
        Write-TPFixtureText $f.Source 'Data/unknown-vendor.json' '{"retained":"未認識"}'
        [IO.File]::WriteAllBytes((Join-Path $f.Source 'Data/empty.bin'),[byte[]]@())
        Write-TPFixtureText $f.Source 'Backup/older.bin' 'Entire backup tree must be copied.'
        Write-TPFixtureText $f.Source 'Exports/old-report.csv' 'outside selected database evidence'
        $null=New-Item -ItemType Directory -Path (Join-Path $f.Source 'Logs/empty') -Force
        $before=Get-TPFixtureDigest $f.Source
        $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        Assert-TPIntegration $report.CanImport 'Retained orphan data should produce a warning, not a blocking error.'
        Assert-TPIntegration $report.RequiresWarningAcknowledgement 'Orphan/unknown file warnings require acknowledgement.'
        Reject-TPIntegration {Import-TPFixture $f $report} 'Unacknowledged warnings must block import.'
        Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database) -and -not(Test-Path -LiteralPath $f.Backup)) 'Unacknowledged warnings caused writes.'
        $null=Import-TPFixture $f $report -Acknowledge
        Assert-TPIntegration ((Get-TPFixtureDigest $f.Source)-ceq$before) 'Original source changed during import.'
        Assert-TPIntegration ((Get-TPFixtureDigest $f.Backup)-ceq$before) 'Backup does not match every original file.'
        Assert-TPIntegration (Test-Path -LiteralPath (Join-Path $f.Backup 'Logs/empty') -PathType Container) 'Empty source directory was not backed up.'
        $store=Open-TaskPilotStore -DatabasePath $f.Database @providerArgs
        try{
            $tasks=Get-TPFixtureRows $store 'SELECT task_id,title,memo,status,is_archived FROM tasks ORDER BY task_id'
            Assert-TPIntegration ($tasks.Count-eq2 -and $tasks[0].title-ceq$title -and $tasks[0].memo-ceq$memo) 'CSV Unicode, quote or newline content changed.'
            Assert-TPIntegration ($tasks[1].is_archived-eq1 -and $tasks[1].status-ceq'未着手') 'Archive membership must remain independent of task status.'
            $plan=Get-TPFixtureRows $store 'SELECT planned_on,work_start_on,estimated_hours_x100 FROM task_plans WHERE task_id=1'
            Assert-TPIntegration ($plan.Count-eq1 -and $plan[0].planned_on-ceq'2026-11-16' -and $plan[0].work_start_on-ceq'2026-11-15' -and $plan[0].estimated_hours_x100-eq1) 'Merged task plans or exact .01 hour were not preserved.'
            $logs=Get-TPFixtureRows $store 'SELECT entry_id,hours_x100 FROM work_logs'
            $actuals=Get-TPFixtureRows $store 'SELECT actual_hours_x100,task_name_snapshot FROM completion_actuals'
            Assert-TPIntegration ($logs.Count-eq1 -and $logs[0].entry_id-ceq'original-log-id' -and $logs[0].hours_x100-eq1) 'Original work-log identity or hours changed.'
            Assert-TPIntegration ($actuals.Count-eq1 -and $actuals[0].actual_hours_x100-eq234 -and $actuals[0].task_name_snapshot-ceq'完了時点の名前') 'Completion actual was merged with daily work-log hours.'
            Assert-TPIntegration ((Get-TPFixtureRows $store 'SELECT * FROM subtasks WHERE subtask_id=''original-child-id''').Count-eq1) 'Original subtask identity changed.'
            $orphans=Get-TPFixtureRows $store 'SELECT legacy_task_id_text,payload_json FROM legacy_unresolved_records'
            Assert-TPIntegration ($orphans.Count-eq1 -and $orphans[0].legacy_task_id_text-ceq'900' -and $orphans[0].payload_json-match'"EstimatedHours":2') 'Missing-parent payload was not preserved.'
            $sources=Get-TPFixtureRows $store 'SELECT relative_path,raw_bytes,sha256 FROM import_source_files'
            foreach($raw in $sources){
                $path=Join-Path $f.Source ([string]$raw.relative_path)
                $original=[IO.File]::ReadAllBytes($path)
                Assert-TPIntegration ([Convert]::ToBase64String([byte[]]$raw.raw_bytes)-ceq[Convert]::ToBase64String($original)) ('Source BLOB changed: '+$raw.relative_path)
                Assert-TPIntegration ($raw.sha256-ceq(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()) 'Raw source SHA256 differs.'
            }
            Assert-TPIntegration (@($sources|Where-Object{$_.relative_path-eq'Data/unknown-vendor.json'}).Count-eq1) 'Unknown selected source file was lost.'
            Assert-TPIntegration (@($sources|Where-Object{$_.relative_path-like'Backup/*'}).Count-eq0) 'Old backup tree should be externally copied rather than loaded into evidence BLOBs.'
            $new=Add-TaskPilotTask -Store $store -Title 'After orphan reservation' -RegisteredOn '2026-11-16'
            Assert-TPIntegration ($new.task_id-eq901) 'Numeric orphan task ID was reused.'
        }finally{Close-TaskPilotStore $store}
    }
    Invoke-TPIntegrationCase 'Existing target and backup are refused without overwrite' {
        $f=New-TPFixture;$report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        [IO.File]::WriteAllText($f.Database,'existing database sentinel')
        $before=(Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash
        Reject-TPIntegration {Import-TPFixture $f $report} 'Existing database must be refused.'
        Assert-TPIntegration ((Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash-ceq$before) 'Existing database changed.'
        Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Backup)) 'Existing database rejection should precede backup creation.'
        Remove-Item -LiteralPath $f.Database
        $null=New-Item -ItemType Directory -Path $f.Backup
        [IO.File]::WriteAllText((Join-Path $f.Backup 'sentinel.txt'),'existing backup sentinel')
        $backupBefore=Get-TPFixtureDigest $f.Backup
        Reject-TPIntegration {Import-TPFixture $f $report} 'Existing backup must be refused.'
        Assert-TPIntegration ((Get-TPFixtureDigest $f.Backup)-ceq$backupBefore) 'Existing backup changed.'
        Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database)) 'Backup rejection published a database.'
    }
    Invoke-TPIntegrationCase 'Source changes after inspection and source-contained destinations are rejected' {
        $f=New-TPFixture;$report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        Write-TPFixtureText $f.Source 'Data/NextId.txt' '6'
        Reject-TPIntegration {Import-TPFixture $f $report} 'Expected manifest must reject changed source.'
        Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database) -and -not(Test-Path -LiteralPath $f.Backup)) 'Changed manifest caused writes.'
        $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        Reject-TPIntegration {Import-TaskPilotLegacyData -SourceRoot $f.Source -DatabasePath (Join-Path $f.Source 'nested.db') -BackupRoot $f.Backup -ExpectedManifestSha256 $report.ManifestSha256 -Apply @providerArgs} 'Source-contained database must be refused.'
        Reject-TPIntegration {Import-TaskPilotLegacyData -SourceRoot $f.Source -DatabasePath $f.Database -BackupRoot (Join-Path $f.Source 'nested-backup') -ExpectedManifestSha256 $report.ManifestSha256 -Apply @providerArgs} 'Source-contained backup must be refused.'
        Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database) -and -not(Test-Path -LiteralPath $f.Backup)) 'Invalid destination caused writes.'
    }
    Invoke-TPIntegrationCase 'Duplicate numeric IDs, malformed CSV and invalid real dates block migration' {
        $f=New-TPFixture
        Write-TPFixtureText $f.Source 'Data/CompletedTask.csv' ("ID,Date,Task,Priority,DueDate,Status,Memo`r`n01,2026/11/15,Duplicate,中,,完了,`r`n")
        Assert-TPFixtureRejectedBeforeWrites $f
        $f=New-TPFixture
        Write-TPFixtureText $f.Source 'Data/TaskList.csv' ("ID,Date,Task,Priority,DueDate,Status,Memo`r`n1,2026/02/30,Invalid date,中,,未着手,`r`n")
        Assert-TPFixtureRejectedBeforeWrites $f
        $f=New-TPFixture
        Write-TPFixtureText $f.Source 'Data/TaskList.csv' ("ID,Date,Task,Priority,DueDate,Status,Memo`r`n1,2026/11/15,Too few,中,,未着手`r`n")
        Assert-TPFixtureRejectedBeforeWrites $f
    }
    Invoke-TPIntegrationCase 'Invalid JSON, Boolean coercion and fractional hour precision are rejected exactly' {
        foreach($hours in @('1e-100','0.010000000000000000000000000001','"0.01"','true')){
            $f=New-TPFixture
            Write-TPFixtureText $f.Source 'Data/WorkPlans.json' ('{"1":{"StartDate":"2026/11/15","EstimatedHours":'+$hours+'}}')
            Assert-TPFixtureRejectedBeforeWrites $f
        }
        $f=New-TPFixture
        Write-TPFixtureText $f.Source 'Data/WorkPlans.json' '{"1":{"StartDate":"2026/11/15","EstimatedHours":1,"EstimatedHours":2}}'
        Assert-TPFixtureRejectedBeforeWrites $f
        $f=New-TPFixture
        Write-TPFixtureText $f.Source 'Data/Subtasks.json' '[{"Id":"child","ParentId":"1","Title":"Boolean","Done":"false"}]'
        Assert-TPFixtureRejectedBeforeWrites $f
        $f=New-TPFixture
        [IO.File]::WriteAllBytes((Join-Path $f.Source 'Data/WorkPlans.json'),[byte[]]@(123,34,255,34,58,49,125))
        Assert-TPFixtureRejectedBeforeWrites $f
    }
    Invoke-TPIntegrationCase 'Missing core files and competing source lock prevent migration' {
        $f=New-TPFixture
        Remove-Item -LiteralPath (Join-Path $f.Source 'Data/CompletedTask.csv')
        Assert-TPFixtureRejectedBeforeWrites $f
        $f=New-TPFixture
        $lock=& $module {param($p) Enter-TPMigrationSourceLock -SourceRoot $p} $f.Source
        try{Reject-TPIntegration {Test-TaskPilotLegacyData -SourceRoot $f.Source} 'Live source lock should block inspection.'}
        finally{$lock.Dispose()}
    }
    Invoke-TPIntegrationCase 'Explicit empty weekday selection is preserved' {
        $f=New-TPFixture
        Write-TPFixtureText $f.Source 'Data/CapacitySettings.json' '{"Weekdays":[],"DailyHours":6.25,"WorkOnHolidays":true,"Overrides":{}}'
        $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
        Assert-TPIntegration ($report.CanImport -and -not$report.RequiresWarningAcknowledgement) 'Explicit empty weekday array is valid.'
        $null=Import-TPFixture $f $report
        $store=Open-TaskPilotStore -DatabasePath $f.Database @providerArgs
        try{
            Assert-TPIntegration ((Get-TPFixtureRows $store 'SELECT * FROM calendar_weekdays').Count-eq0) 'Explicit empty weekdays must not revert to default weekdays.'
            $calendar=Get-TPFixtureRows $store 'SELECT daily_hours_x100,work_on_holidays FROM capacity_calendars'
            Assert-TPIntegration ($calendar[0].daily_hours_x100-eq625 -and $calendar[0].work_on_holidays-eq1) 'Custom calendar values were not preserved.'
        }finally{Close-TaskPilotStore $store}
    }
    if($TestProviderAssembly){
        Invoke-TPIntegrationCase 'Late verification failure leaves verified backup and removes only staging database' {
            $f=New-TPFixture;$before=Get-TPFixtureDigest $f.Source
            $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
            & $module {$script:TPMigrationTestHook={param($store,$plan) $null=Invoke-TPSql $store "UPDATE tasks SET title='synthetic incorrect title' WHERE task_id=1" -Mode NonQuery}}
            try{Reject-TPIntegration {Import-TPFixture $f $report} 'Verification must reject changed normalized data.' 'Migration field verification failed'}
            finally{& $module {$script:TPMigrationTestHook=$null}}
            Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database)) 'Late failure published a partial database.'
            Assert-TPIntegration ((Get-TPFixtureDigest $f.Backup)-ceq$before) 'Verified backup must remain after late failure.'
            Assert-TPIntegration ((Get-TPFixtureDigest $f.Source)-ceq$before) 'Late database failure changed the source.'
            Assert-TPIntegration (@(Get-ChildItem -LiteralPath $f.Root -File -Force | Where-Object{$_.Name-like'.taskpilot*'}).Count-eq0) 'Failed staging database or sidecars were not removed.'
        }
        Invoke-TPIntegrationCase 'Raw BLOB readback detects byte tampering before publication' {
            $f=New-TPFixture;$before=Get-TPFixtureDigest $f.Source
            $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
            & $module {$script:TPMigrationTestHook={param($store,$plan)
                $raw=@(Invoke-TPSql $store 'SELECT source_file_id,raw_bytes FROM import_source_files ORDER BY source_file_id')[0]
                $bytes=[byte[]]$raw.raw_bytes.Clone();$bytes[0]=$bytes[0]-bxor1
                $null=Invoke-TPSql $store 'DROP TRIGGER import_source_no_update' -Mode NonQuery
                $null=Invoke-TPSql $store 'UPDATE import_source_files SET raw_bytes=@bytes WHERE source_file_id=@id' -Parameters @{bytes=$bytes;id=[long]$raw.source_file_id} -Mode NonQuery
            }}
            try{Reject-TPIntegration {Import-TPFixture $f $report} 'Raw evidence BLOB hash mismatch must abort publication.' 'BLOB hash verification failed'}
            finally{& $module {$script:TPMigrationTestHook=$null}}
            Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database)) 'Tampered evidence database was published.'
            Assert-TPIntegration ((Get-TPFixtureDigest $f.Backup)-ceq$before) 'Evidence mismatch removed or changed verified backup.'
            Assert-TPIntegration ((Get-TPFixtureDigest $f.Source)-ceq$before) 'Evidence mismatch changed source documents.'
        }
        Invoke-TPIntegrationCase 'Source changed after backup is detected before committing or publishing' {
            $f=New-TPFixture;$before=Get-TPFixtureDigest $f.Source
            $report=Test-TaskPilotLegacyData -SourceRoot $f.Source
            & $module {$script:TPMigrationTestHook={param($store,$plan)
                # Deliberate fixture-only external writer: migration itself never writes this path.
                [IO.File]::AppendAllText((Join-Path $plan.Snapshot.SourceRoot 'Data/NextId.txt'),'6')
            }}
            try{Reject-TPIntegration {Import-TPFixture $f $report} 'A source change during migration must abort publication.' 'source file changed|source files changed|manifest changed'}
            finally{& $module {$script:TPMigrationTestHook=$null}}
            Assert-TPIntegration (-not(Test-Path -LiteralPath $f.Database)) 'Changed source produced a published database.'
            Assert-TPIntegration ((Get-TPFixtureDigest $f.Backup)-ceq$before) 'Original pre-change backup should be retained.'
            Assert-TPIntegration (([IO.File]::ReadAllText((Join-Path $f.Source 'Data/NextId.txt')))-ceq'56') 'Migration overwrote the externally modified source.'
        }
    }else{Write-Output 'SKIP: synthetic in-transaction tampering hooks are restricted to an explicitly selected test provider.'}
    Write-Output ('Result: '+$script:passed+' migration cases passed, '+$script:failed+' failed; '+$script:assertions+' assertions.')
    if($script:failed-gt0){throw 'Migration integration tests failed.'}
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
