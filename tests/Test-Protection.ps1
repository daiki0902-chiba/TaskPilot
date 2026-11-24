#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$protectionModule=Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
. (Join-Path $PSScriptRoot 'MigrationDomainFixture.ps1')
$providerArgs=@{};if($TestProviderAssembly){$providerArgs.TestProviderAssembly=$TestProviderAssembly}
$protectionRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotProtection_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $protectionRoot
$script:protectionPassed=0;$script:protectionFailed=0;$script:protectionAssertions=0
function Check-Protection($Condition,[string]$Message){$script:protectionAssertions++;if(-not$Condition){throw $Message}}
function Reject-Protection([scriptblock]$Action,[string]$Message,[string]$ExpectedPattern=''){$rejected=$false;try{$null=&$Action}catch{$rejected=$true;if($ExpectedPattern-and$_.Exception.Message-notmatch$ExpectedPattern){throw}};Check-Protection $rejected $Message}
function Case-Protection([string]$Name,[scriptblock]$Action){
    try{&$Action;$script:protectionPassed++;Write-Output ('PASS: '+$Name)}
    catch{$script:protectionFailed++;Write-Output ('FAIL: '+$Name+' : '+$_.Exception.Message);Write-Output $_.ScriptStackTrace}
}
function Get-ProtectionRows($Store,[string]$Sql,[hashtable]$Parameters=@{}){return @(& $protectionModule {param($s,$q,$p) Invoke-TPSql $s $q -Parameters $p} $Store $Sql $Parameters)}
function Invoke-ProtectionSql($Store,[string]$Sql,[hashtable]$Parameters=@{}){return & $protectionModule {param($s,$q,$p) Invoke-TPSql $s $q -Parameters $p -Mode NonQuery} $Store $Sql $Parameters}
function New-ProtectionCase{
    $root=Join-Path $protectionRoot ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $root
    return [pscustomobject]@{Root=$root;Source=(Join-Path $root 'source.db');Backup=(Join-Path $root 'backup.db');Restored=(Join-Path $root 'restored.db')}
}
function New-ProtectionSimple($Case){
    $null=New-TaskPilotDatabase -DatabasePath $Case.Source @providerArgs
    $s=Open-TaskPilotStore -DatabasePath $Case.Source @providerArgs
    try{$null=Add-TaskPilotTask -Store $s -Title '原本の日本語タスク' -RegisteredOn '2026-11-15' -Memo "引用符'と改行`r`n次の行"}finally{Close-TaskPilotStore $s}
}
function Get-ProtectionContentSignature($Store){
    $tableNames=@(Get-ProtectionRows $Store "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name")
    $signature=New-Object 'Collections.Generic.List[string]'
    foreach($table in $tableNames){
        $rows=New-Object 'Collections.Generic.List[string]'
        $quoted='"'+([string]$table.name).Replace('"','""')+'"'
        foreach($row in @(Get-ProtectionRows $Store ('SELECT * FROM '+$quoted))){
            $values=[ordered]@{}
            foreach($property in $row.PSObject.Properties){
                if($property.Value-is[byte[]]){$values[$property.Name]=[ordered]@{BlobBase64=[Convert]::ToBase64String($property.Value)}}else{$values[$property.Name]=$property.Value}
            }
            $rows.Add([TaskPilot.Migration.Codec]::ToJson($values))
        }
        $rows.Sort([StringComparer]::Ordinal);$signature.Add([string]$table.name+':'+($rows-join"`n"))
    }
    return $signature-join"`n"
}
function Assert-ProtectionNoStages([string]$Root){Check-Protection (@(Get-ChildItem -LiteralPath $Root -Filter '.taskpilot-*' -Force).Count-eq0) 'An owned temporary stage was left behind.'}
try{
    Case-Protection 'Complete snapshot and restore retain every row, raw BLOB, monthly revision and next ID' {
        $f=New-ProtectionCase;$legacy=Join-Path $f.Root 'legacy';$null=New-Item -ItemType Directory -Path (Join-Path $legacy 'Data') -Force
        $fixture=New-MigrationDomainFixture
        foreach($entry in $fixture.GetEnumerator()){
            $path=Join-Path $legacy ($entry.Key.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
            [IO.File]::WriteAllText($path,$entry.Value,[Text.UTF8Encoding]::new($true))
        }
        [IO.File]::WriteAllBytes((Join-Path $legacy 'Data/empty.bin'),[byte[]]@())
        $inspection=Test-TaskPilotLegacyData -SourceRoot $legacy
        Check-Protection $inspection.CanImport 'Comprehensive synthetic migration fixture was not importable.'
        $null=Import-TaskPilotLegacyData -SourceRoot $legacy -DatabasePath $f.Source -BackupRoot (Join-Path $f.Root 'legacy-backup') -ExpectedManifestSha256 $inspection.ManifestSha256 -Apply -AcknowledgeWarnings @providerArgs
        $originalHash=(Get-FileHash -LiteralPath $f.Source -Algorithm SHA256).Hash
        $s=Open-TaskPilotStore -DatabasePath $f.Source -ReadOnly @providerArgs
        try{
            $before=Get-ProtectionContentSignature $s
            $backup=New-TaskPilotDatabaseBackup -Store $s -DestinationPath $f.Backup
            Check-Protection ($backup.Verified -and $backup.SchemaVersion-eq40001 -and $backup.ByteCount-gt0) 'Backup result lacks verification metadata.'
        }finally{Close-TaskPilotStore $s}
        Check-Protection ((Get-FileHash -LiteralPath $f.Source -Algorithm SHA256).Hash-ceq$originalHash) 'Backup changed the source database bytes.'
        $backupHash=(Get-FileHash -LiteralPath $f.Backup -Algorithm SHA256).Hash
        $restored=Restore-TaskPilotDatabase -BackupPath $f.Backup -DatabasePath $f.Restored @providerArgs
        Check-Protection ($restored.Verified -and -not$restored.ExistingDatabaseModified -and -not$restored.AppSwitched) 'Restore must publish a new file without switching the app.'
        Check-Protection ((Get-FileHash -LiteralPath $f.Backup -Algorithm SHA256).Hash-ceq$backupHash) 'Restore changed backup bytes.'
        Check-Protection ((Get-FileHash -LiteralPath $f.Restored -Algorithm SHA256).Hash-ceq$backupHash) 'Restore differs from the verified snapshot bytes.'
        $s=Open-TaskPilotStore -DatabasePath $f.Restored @providerArgs
        try{
            Check-Protection ((Get-ProtectionContentSignature $s)-ceq$before) 'Restored table contents, evidence or sqlite_sequence changed.'
            $month=Get-TaskPilotMonthlySnapshot -Store $s -MonthKey '2026-10' -History
            Check-Protection ($month.Current.revision-eq5 -and $month.Events.Count-eq1) 'Original monthly revision/event was not retained.'
            Check-Protection ($month.Current.finalized_at_utc-ceq'2026-11-01T00:00:00.1234567Z') 'Original finalized time was changed.'
            Reject-Protection {Invoke-ProtectionSql $s 'UPDATE monthly_snapshot_revisions SET completed_count=999'} 'Monthly history became mutable.'
            Reject-Protection {Invoke-ProtectionSql $s 'DELETE FROM import_source_files'} 'Original source evidence became deletable.'
            $next=Add-TaskPilotTask -Store $s -Title '復元後の新規タスク' -RegisteredOn '2026-11-16'
            Check-Protection ($next.task_id-eq901) 'Orphan-aware task high-water was lost.'
        }finally{Close-TaskPilotStore $s}
        Assert-ProtectionNoStages $f.Root
    }
    Case-Protection 'An active caller transaction refuses backup without creating a destination' {
        $f=New-ProtectionCase;New-ProtectionSimple $f;$s=Open-TaskPilotStore -DatabasePath $f.Source @providerArgs
        try{Reject-Protection {Invoke-TaskPilotTransaction -Store $s -Action {New-TaskPilotDatabaseBackup -Store $s -DestinationPath $f.Backup}} 'An active transaction was accepted.'}finally{Close-TaskPilotStore $s}
        Check-Protection (-not[IO.File]::Exists($f.Backup)) 'Rejected transaction created a backup.'
        Assert-ProtectionNoStages $f.Root
    }
    Case-Protection 'Existing outputs and recovery sidecars are preserved and never overwritten' {
        $f=New-ProtectionCase;New-ProtectionSimple $f
        [IO.File]::WriteAllText($f.Backup,'Existing backup sentinel')
        $existingHash=(Get-FileHash -LiteralPath $f.Backup -Algorithm SHA256).Hash
        $s=Open-TaskPilotStore -DatabasePath $f.Source @providerArgs
        try{
            Reject-Protection {New-TaskPilotDatabaseBackup -Store $s -DestinationPath $f.Backup} 'An existing backup was overwritten.'
            foreach($suffix in @('-journal','-wal','-shm')){
                $target=Join-Path $f.Root ('target'+$suffix.Replace('-','')+'.db');[IO.File]::WriteAllText($target+$suffix,'Recovery sentinel')
                Reject-Protection {New-TaskPilotDatabaseBackup -Store $s -DestinationPath $target} 'An existing destination sidecar was accepted.'
                Check-Protection ([IO.File]::ReadAllText($target+$suffix)-ceq'Recovery sentinel') 'A recovery sidecar was modified.'
            }
        }finally{Close-TaskPilotStore $s}
        Check-Protection ((Get-FileHash -LiteralPath $f.Backup -Algorithm SHA256).Hash-ceq$existingHash) 'Existing backup hash changed.'
        Reject-Protection {Restore-TaskPilotDatabase -BackupPath $f.Source -DatabasePath $f.Backup @providerArgs} 'Restore overwrote an existing destination.'
        foreach($suffix in @('-journal','-wal','-shm')){
            [IO.File]::WriteAllText($f.Source+$suffix,'Source recovery sentinel')
            try{Reject-Protection {Restore-TaskPilotDatabase -BackupPath $f.Source -DatabasePath $f.Restored @providerArgs} 'Restore accepted a source recovery sidecar.';Check-Protection ([IO.File]::ReadAllText($f.Source+$suffix)-ceq'Source recovery sentinel') 'Source recovery sidecar was modified.'}
            finally{[IO.File]::Delete($f.Source+$suffix)}
        }
        Assert-ProtectionNoStages $f.Root
    }
    Case-Protection 'Bad app headers, unsupported schemas and corrupt snapshots fail without source changes' {
        foreach($mode in @('bad-header','wrong-app','future-schema','truncated')){
            $f=New-ProtectionCase;New-ProtectionSimple $f
            switch($mode){
                'bad-header'{[IO.File]::WriteAllText($f.Source,'This is not SQLite')}
                'wrong-app'{$s=Open-TaskPilotStore -DatabasePath $f.Source @providerArgs;try{$null=Invoke-ProtectionSql $s 'PRAGMA application_id=42'}finally{Close-TaskPilotStore $s}}
                'future-schema'{$s=Open-TaskPilotStore -DatabasePath $f.Source @providerArgs;try{$null=Invoke-ProtectionSql $s 'PRAGMA user_version=49999'}finally{Close-TaskPilotStore $s}}
                'truncated'{$stream=[IO.File]::Open($f.Source,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.SetLength(128)}finally{$stream.Dispose()}}
            }
            $hash=(Get-FileHash -LiteralPath $f.Source -Algorithm SHA256).Hash
            Reject-Protection {Restore-TaskPilotDatabase -BackupPath $f.Source -DatabasePath $f.Restored @providerArgs} ('Invalid backup was accepted: '+$mode)
            Check-Protection (-not[IO.File]::Exists($f.Restored)) 'Invalid backup published a database.'
            Check-Protection ((Get-FileHash -LiteralPath $f.Source -Algorithm SHA256).Hash-ceq$hash) 'Rejected backup bytes changed.'
            Assert-ProtectionNoStages $f.Root
        }
    }
    Case-Protection 'Online snapshot includes data committed in a nonempty WAL' {
        $f=New-ProtectionCase;New-ProtectionSimple $f;$writer=Open-TaskPilotStore -DatabasePath $f.Source @providerArgs
        try{
            $null=Invoke-ProtectionSql $writer 'PRAGMA journal_mode=WAL';$null=Invoke-ProtectionSql $writer 'PRAGMA wal_autocheckpoint=0'
            $null=Add-TaskPilotTask -Store $writer -Title 'WALに確定したタスク' -RegisteredOn '2026-11-16'
            Check-Protection ([IO.File]::Exists($f.Source+'-wal') -and ([IO.FileInfo]($f.Source+'-wal')).Length-gt0) 'WAL fixture did not retain committed pages.'
            $null=New-TaskPilotDatabaseBackup -Store $writer -DestinationPath $f.Backup
        }finally{Close-TaskPilotStore $writer}
        Check-Protection ([IO.File]::Exists($f.Backup)) 'WAL backup was not published.'
        $reader=Open-TaskPilotStore -DatabasePath $f.Backup -ReadOnly @providerArgs
        try{$tasks=@(Get-TaskPilotTask -Store $reader);Check-Protection ($tasks.Count-eq2 -and @($tasks|Where-Object {$_.title-ceq'WALに確定したタスク'}).Count-eq1) 'Committed WAL task is missing from the standalone snapshot.'}finally{Close-TaskPilotStore $reader}
        Assert-ProtectionNoStages $f.Root
    }
    Case-Protection 'A reader snapshot excludes another connection uncommitted task' {
        $f=New-ProtectionCase;New-ProtectionSimple $f;$writer=$null;$reader=$null
        try{
            $writer=Open-TaskPilotStore -DatabasePath $f.Source @providerArgs
            $reader=Open-TaskPilotStore -DatabasePath $f.Source -ReadOnly @providerArgs
            Reject-Protection {Invoke-TaskPilotTransaction -Store $writer -Action {
                $null=Add-TaskPilotTask -Store $writer -Title '未確定タスク' -RegisteredOn '2026-11-16'
                $null=New-TaskPilotDatabaseBackup -Store $reader -DestinationPath $f.Backup
                throw 'Rollback synthetic writer transaction'
            }} 'Writer fixture did not roll back.' 'Rollback synthetic writer transaction'
        }finally{if($null-ne$reader){Close-TaskPilotStore $reader};if($null-ne$writer){Close-TaskPilotStore $writer}}
        Check-Protection ([IO.File]::Exists($f.Backup)) 'Reader snapshot was not published.'
        $reader=Open-TaskPilotStore -DatabasePath $f.Backup -ReadOnly @providerArgs
        try{$tasks=@(Get-TaskPilotTask -Store $reader);Check-Protection ($tasks.Count-eq1 -and @($tasks|Where-Object {$_.title-ceq'未確定タスク'}).Count-eq0) 'An uncommitted task leaked into a backup.'}finally{Close-TaskPilotStore $reader}
        Assert-ProtectionNoStages $f.Root
    }
    Write-Output ('Result: {0} protection cases passed, {1} failed; {2} assertions.'-f$script:protectionPassed,$script:protectionFailed,$script:protectionAssertions)
    if($script:protectionFailed-gt0){throw 'Database protection tests failed.'}
}finally{Remove-Item -LiteralPath $protectionRoot -Recurse -Force -ErrorAction SilentlyContinue}
