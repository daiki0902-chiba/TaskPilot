# Verified SQLite snapshots. Existing databases, backups and recovery sidecars
# are never overwritten or deleted. The caller owns UI pause / active DB choice.
function Test-TPProtectionPathExists([string]$Path){
    try{$null=[IO.File]::GetAttributes($Path);return $true}
    catch [IO.FileNotFoundException]{return $false}
    catch [IO.DirectoryNotFoundException]{return $false}
}
function Assert-TPProtectionNoLinks([string]$Path){
    $inspect=$Path
    while($inspect){
        if(Test-TPProtectionPathExists $inspect){
            if(([IO.File]::GetAttributes($inspect)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Database protection paths must not traverse links or junctions.'}
        }
        $parent=[IO.Path]::GetDirectoryName($inspect);if($parent-eq$inspect){break};$inspect=$parent
    }
}
function Assert-TPProtectionNoSidecars([string]$Path){
    foreach($suffix in @('-journal','-wal','-shm')){
        if(Test-TPProtectionPathExists ($Path+$suffix)){throw 'A SQLite recovery sidecar exists. Preserve it; choose a complete standalone snapshot or a new destination.'}
    }
}
function Assert-TPProtectionNewDestination([string]$Path){
    $full=Get-TPResolvedPath $Path
    Assert-TPProtectionNoLinks $full
    if([IO.Path]::GetExtension($full)-notin@('.db','.sqlite','.sqlite3')){throw 'Choose a new .db, .sqlite or .sqlite3 filename.'}
    if(-not[IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))){throw 'Destination parent directory must already exist.'}
    if(Test-TPProtectionPathExists $full){throw 'Destination already exists and will not be overwritten.'}
    Assert-TPProtectionNoSidecars $full
    return $full
}
function Get-TPProtectionFileHash([string]$Path){
    $stream=$null;$sha=[Security.Cryptography.SHA256]::Create()
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    }finally{if($null-ne$stream){$stream.Dispose()};$sha.Dispose()}
}
function Assert-TPProtectionStoreIntegrity($Store){
    Assert-TPStore $Store
    if([long](Invoke-TPSql $Store 'PRAGMA application_id' -Mode Scalar)-ne$script:TPApplicationId -or
       [long](Invoke-TPSql $Store 'PRAGMA user_version' -Mode Scalar)-ne$script:TPSchemaVersion){throw 'Snapshot app or schema identity does not match this TaskPilot version.'}
    $integrity=@(Invoke-TPSql $Store 'PRAGMA integrity_check')
    if($integrity.Count-ne1 -or [string]$integrity[0].integrity_check-cne'ok'){throw 'SQLite integrity verification failed.'}
    if(@(Invoke-TPSql $Store 'PRAGMA foreign_key_check').Count-ne0){throw 'SQLite foreign-key verification failed.'}
    # A supported version header alone must not make an unrelated empty DB valid.
    $required=@('schema_migrations','import_batches','import_source_files','import_issues','legacy_unresolved_records','holiday_sets','public_holidays','capacity_calendars','calendar_weekdays','company_closures','capacity_overrides','tasks','task_plans','subtasks','work_logs','completion_actuals','recurring_rules','recurring_occurrences','app_settings','notification_state','notification_history','monthly_snapshots','monthly_snapshot_revisions','monthly_revision_events','legacy_monthly_audit','report_state')
    $tables=@(Invoke-TPSql $Store "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    if($tables.Count-ne$required.Count){throw 'Snapshot table structure does not match the supported schema.'}
    foreach($name in $required){if(@($tables|Where-Object {$_.name-ceq$name}).Count-ne1){throw 'Snapshot is missing a required TaskPilot table.'}}
    $triggers=@('monthly_revision_no_update','monthly_revision_no_delete','monthly_event_no_update','monthly_event_no_delete','legacy_audit_no_update','legacy_audit_no_delete','import_source_no_update','import_source_no_delete','recurring_occurrences_no_update','recurring_occurrences_no_delete','monthly_revision_recorded')
    foreach($name in $triggers){if([long](Invoke-TPSql $Store "SELECT COUNT(*) FROM sqlite_schema WHERE type='trigger' AND name=@name" -Parameters @{name=$name} -Mode Scalar)-ne1){throw 'Snapshot is missing a required history-protection trigger.'}}
    if([long](Invoke-TPSql $Store 'SELECT COUNT(*) FROM schema_migrations WHERE version=@version' -Parameters @{version=$script:TPSchemaVersion} -Mode Scalar)-ne1){throw 'Snapshot schema ledger is inconsistent.'}
}
function Test-TPProtectionStage([string]$Path,[hashtable]$ProviderArguments){
    $verification=$null
    try{
        $verification=Open-TaskPilotStore -DatabasePath $Path -ReadOnly @ProviderArguments
        Assert-TPProtectionStoreIntegrity $verification
    }finally{if($null-ne$verification -and -not$verification.Closed){Close-TaskPilotStore $verification}}
    Assert-TPProtectionNoSidecars $Path
}
function Remove-TPProtectionOwnedStage([string]$Path){
    # Only an internally generated, successfully reserved stage is passed here.
    foreach($suffix in @('','-journal','-wal','-shm')){
        if([IO.File]::Exists($Path+$suffix)){Remove-Item -LiteralPath ($Path+$suffix) -Force -ErrorAction SilentlyContinue}
    }
}
function New-TaskPilotDatabaseBackup {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][string]$DestinationPath)
    Assert-TPStore $Store
    if($null-ne$Store.Transaction -or $Store.TransactionReadOnly){throw 'Finish the active transaction or read snapshot before creating a database backup.'}
    $destination=Assert-TPProtectionNewDestination $DestinationPath
    $providerArguments=@{}
    if($Store.TestOnly){
        if($null-eq$script:TPProvider -or -not$script:TPProvider.TestOnly){throw 'The source store test provider is not available.'}
        $providerArguments.TestProviderAssembly=$script:TPProvider.AssemblyPath
    }
    Assert-TPProtectionStoreIntegrity $Store
    $stage=Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.taskpilot-backup_'+[guid]::NewGuid().ToString('N')+'.db')
    $owned=$false;$reserved=$null
    try{
        $reserved=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$owned=$true
        $reserved.Dispose();$reserved=$null
        # SQLite performs a consistent snapshot, including committed WAL content.
        # VACUUM INTO accepts a new or zero-byte file and refuses a nonempty one.
        $null=Invoke-TPSql $Store 'VACUUM main INTO @destination' -Parameters @{destination=$stage} -Mode NonQuery
        $flush=[IO.File]::Open($stage,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$flush.Flush($true)}finally{$flush.Dispose()}
        Test-TPProtectionStage $stage $providerArguments
        $hash=Get-TPProtectionFileHash $stage;$size=([IO.FileInfo]$stage).Length
        $null=Assert-TPProtectionNewDestination $destination
        [IO.File]::Move($stage,$destination);$owned=$false
        return [pscustomobject]@{BackupPath=$destination;DestinationPath=$destination;DatabasePath=$Store.Path;Sha256=$hash;ByteCount=[long]$size;ApplicationId=$script:TPApplicationId;SchemaVersion=$script:TPSchemaVersion;CreatedAtUtc=(Get-TPUtcNow);Verified=$true;TestOnly=[bool]$Store.TestOnly}
    }finally{
        if($null-ne$reserved){$reserved.Dispose()}
        if($owned){Remove-TPProtectionOwnedStage $stage}
    }
}
function Restore-TaskPilotDatabase {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$BackupPath,[Parameter(Mandatory=$true)][string]$DatabasePath,[string]$TestProviderAssembly)
    $source=Get-TPResolvedPath $BackupPath;Assert-TPProtectionNoLinks $source
    if(-not[IO.File]::Exists($source)){throw 'Backup must be an existing standalone SQLite file.'}
    Assert-TPProtectionNoSidecars $source
    # Reject unsupported headers before allowing provider recovery or creating output.
    Assert-TPDatabaseHeader $source
    $destination=Assert-TPProtectionNewDestination $DatabasePath
    $providerArguments=@{};if($TestProviderAssembly){$providerArguments.TestProviderAssembly=$TestProviderAssembly}
    $stage=Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.taskpilot-restore_'+[guid]::NewGuid().ToString('N')+'.db')
    $inputStream=$null;$outputStream=$null;$sha=[Security.Cryptography.SHA256]::Create();$owned=$false
    try{
        # No provider ever opens the original backup. Read sharing denies normal
        # Windows writers while hashing and copying; only our stage is inspected.
        $inputStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceHash=([BitConverter]::ToString($sha.ComputeHash($inputStream))).Replace('-','').ToLowerInvariant()
        $null=$inputStream.Seek(0,[IO.SeekOrigin]::Begin)
        $outputStream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$owned=$true
        $inputStream.CopyTo($outputStream);$outputStream.Flush($true);$outputStream.Dispose();$outputStream=$null
        $null=$inputStream.Seek(0,[IO.SeekOrigin]::Begin)
        $afterHash=([BitConverter]::ToString($sha.ComputeHash($inputStream))).Replace('-','').ToLowerInvariant()
        if($afterHash-cne$sourceHash -or (Get-TPProtectionFileHash $stage)-cne$sourceHash){throw 'Backup changed while being copied; no restored database was published.'}
        Assert-TPProtectionNoSidecars $source
        $inputStream.Dispose();$inputStream=$null
        Test-TPProtectionStage $stage $providerArguments
        if((Get-TPProtectionFileHash $stage)-cne$sourceHash){throw 'Restored snapshot bytes changed during validation.'}
        $size=([IO.FileInfo]$stage).Length
        $null=Assert-TPProtectionNewDestination $destination
        [IO.File]::Move($stage,$destination);$owned=$false
        return [pscustomobject]@{DatabasePath=$destination;BackupPath=$source;Sha256=$sourceHash;ByteCount=[long]$size;ApplicationId=$script:TPApplicationId;SchemaVersion=$script:TPSchemaVersion;Verified=$true;ExistingDatabaseModified=$false;AppSwitched=$false;TestOnly=[bool]$TestProviderAssembly}
    }finally{
        if($null-ne$outputStream){$outputStream.Dispose()}
        if($null-ne$inputStream){$inputStream.Dispose()}
        $sha.Dispose()
        if($owned){Remove-TPProtectionOwnedStage $stage}
    }
}
