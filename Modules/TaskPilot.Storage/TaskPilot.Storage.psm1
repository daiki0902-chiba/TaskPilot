#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:TPProvider = $null
$script:TPModuleRoot = $PSScriptRoot
$script:TPApplicationId = 1414547788
$script:TPSchemaVersion = 40001

function Assert-TPProviderOrigin {
    param([string[]]$Files)
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){return}
    foreach($providerFile in $Files){
        $zone=(Get-Content -LiteralPath $providerFile -Stream Zone.Identifier -ErrorAction SilentlyContinue) -join "`n"
        if($zone -match '(?m)^\s*ZoneId\s*=\s*[34]\s*$'){
            throw "Windows download-origin block detected on $providerFile. In the kit folder run: Get-ChildItem -LiteralPath '.\Modules\TaskPilot.Storage\provider' -Filter '*.dll' -Recurse -File | Unblock-File . Then restart Windows PowerShell and retry. No block was removed automatically."
        }
    }
}
function Get-TPProviderLoadMessage($Exception,[string]$ManagedPath){
    $cause=$Exception
    while($null-ne$cause){
        if($cause.HResult -eq -2146233067){return "Windows/.NET blocked loading $ManagedPath (0x80131515). A download-origin block is a common cause. Unblock only the bundled provider DLLs with Unblock-File, restart Windows PowerShell, then retry. No system policy was changed."}
        $cause=$cause.InnerException
    }
    return "SQLite provider load failed: $($Exception.Message)"
}
function Import-TPProvider {
    param([string]$TestProviderAssembly)
    if ($null -ne $script:TPProvider) {
        if ([bool]$TestProviderAssembly -ne [bool]$script:TPProvider.TestOnly) { throw 'Test and production providers cannot be mixed. Start a fresh PowerShell process.' }
        if ($TestProviderAssembly) {
            $requested = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestProviderAssembly)
            if ($requested -cne $script:TPProvider.AssemblyPath) { throw 'A different test adapter was requested. Start a fresh PowerShell process.' }
        }
        return $script:TPProvider
    }
    if ($TestProviderAssembly) {
        $assemblyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestProviderAssembly)
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) { throw 'Test adapter assembly not found.' }
        $adapterAssembly = [Reflection.Assembly]::LoadFrom($assemblyPath)
        $type = $adapterAssembly.GetType('Mono.Data.Sqlite.SqliteConnection',$true)
        $script:TPProvider = [pscustomobject]@{Name='Mono.Data.Sqlite'; Type=$type; TestOnly=$true; AssemblyPath=$assemblyPath}
        return $script:TPProvider
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Production provider requires Windows PowerShell 5.1 (powershell.exe). Linux adapter is test-only.'
    }
    $providerRoot = Join-Path $script:TPModuleRoot 'provider'
    $manifestPath = Join-Path $providerRoot 'provider-files.sha256.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Bundled SQLite provider manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $manifest.PSObject.Properties) {
        $file = Join-Path $providerRoot $entry.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine [string]$entry.Value) { throw "SQLite provider integrity check failed: $($entry.Name)" }
    }
    Assert-TPProviderOrigin -Files @($manifest.PSObject.Properties | ForEach-Object { Join-Path $providerRoot $_.Name })
    $managed = Join-Path $providerRoot 'System.Data.SQLite.dll'
    $loaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Data.SQLite' })
    if ($loaded.Count -gt 0 -and ($loaded[0].GetName().Version -ne [version]'1.0.119.0' -or $loaded[0].Location -ine $managed)) {
        throw 'Another System.Data.SQLite assembly is already loaded. Start a fresh Windows PowerShell process.'
    }
    if ($loaded.Count -eq 0) { try { $providerAssembly = [Reflection.Assembly]::LoadFrom($managed) } catch { throw (Get-TPProviderLoadMessage -Exception $_.Exception -ManagedPath $managed) } } else { $providerAssembly = $loaded[0] }
    $type = $providerAssembly.GetType('System.Data.SQLite.SQLiteConnection',$true)
    $script:TPProvider = [pscustomobject]@{Name='System.Data.SQLite'; Type=$type; TestOnly=$false}
    return $script:TPProvider
}
function Get-TPResolvedPath([string]$Path) {
    $provider=$null; $drive=$null
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'A filesystem database path is required.' }
    # Conservatively reject links/junctions instead of resolving into a protected store.
    $inspect = $full
    while ($inspect) {
        if (Test-Path -LiteralPath $inspect) {
            $pathItem = Get-Item -LiteralPath $inspect -Force -ErrorAction Stop
            if (($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Database paths through symbolic links or junctions are not allowed in STEP4B.' }
        }
        $nextParent = Split-Path -Parent $inspect
        if ($nextParent -eq $inspect) { break }
        $inspect = $nextParent
    }
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ($local) {
        $old = [IO.Path]::GetFullPath((Join-Path $local 'TaskPilot')).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($full.Equals($old,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($old+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'STEP4B does not open or write the legacy TaskPilot data directory.' }
    }
    return $full
}
function New-TPConnection {
    param([string]$Path,$Provider,[bool]$ReadOnly=$false)
    $builder = New-Object System.Data.Common.DbConnectionStringBuilder
    $builder['Data Source']=$Path
    $builder['Version']=3
    $builder['FailIfMissing']=$true
    $builder['Pooling']=$false
    $builder['Read Only']=$ReadOnly
    $builder['Default Timeout']=5
    $conn = [Activator]::CreateInstance($Provider.Type)
    $conn.ConnectionString=$builder.ConnectionString
    try {
        $conn.Open()
        $cmd=$conn.CreateCommand()
        try {
            $cmd.CommandText='PRAGMA foreign_keys=ON; PRAGMA recursive_triggers=ON; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;'
            $null=$cmd.ExecuteNonQuery()
            foreach($item in @(@('foreign_keys',1),@('recursive_triggers',1))) {
                $cmd.CommandText='PRAGMA '+$item[0]
                if ([int]$cmd.ExecuteScalar() -ne [int]$item[1]) { throw 'SQLite connection safety pragma was not enabled.' }
            }
            $cmd.CommandText='SELECT sqlite_version()'
            if ([version]$cmd.ExecuteScalar() -lt [version]'3.38.0') { throw 'SQLite 3.38.0 or newer is required.' }
        } finally { $cmd.Dispose() }
        return ,$conn
    } catch { $conn.Dispose(); throw }
}
function Assert-TPStore {
    param($Store,[switch]$Write)
    if ($null -eq $Store -or $Store.PSTypeNames -notcontains 'TaskPilot.Store' -or $Store.Closed -or $Store.Connection.State -ne [Data.ConnectionState]::Open) { throw 'TaskPilot store is not open.' }
    if ($Write -and ($Store.ReadOnly -or $Store.TransactionReadOnly)) { throw 'Store or active snapshot is read-only.' }
}
function Invoke-TPSql {
    param($Store,[string]$Sql,[hashtable]$Parameters=@{},[ValidateSet('Rows','Scalar','NonQuery')][string]$Mode='Rows')
    Assert-TPStore $Store
    $cmd=$Store.Connection.CreateCommand()
    try {
        $cmd.CommandText=$Sql
        $cmd.CommandTimeout=5
        if ($null -ne $Store.Transaction) { $cmd.Transaction=$Store.Transaction }
        foreach($key in $Parameters.Keys) {
            $parameter=$cmd.CreateParameter()
            $parameter.ParameterName=if($key.StartsWith('@')){$key}else{'@'+$key}
            $value=$Parameters[$key]
            if ($null -eq $value) { $parameter.Value=[DBNull]::Value }
            elseif ($value -is [byte[]]) { $parameter.DbType=[Data.DbType]::Binary; $parameter.Value=$value }
            elseif ($value -is [bool]) { $parameter.DbType=[Data.DbType]::Int64; $parameter.Value=[long]$value }
            elseif ($value -is [sbyte] -or $value -is [byte] -or $value -is [int16] -or $value -is [int32] -or $value -is [long]) { $parameter.DbType=[Data.DbType]::Int64; $parameter.Value=[long]$value }
            elseif ($value -is [string]) { $parameter.DbType=[Data.DbType]::String; $parameter.Value=$value }
            else { throw "Unsupported SQL parameter type for $key. Convert values to explicit text, Int64, bool, blob or null." }
            $null=$cmd.Parameters.Add($parameter)
        }
        switch($Mode) {
            'NonQuery' { return $cmd.ExecuteNonQuery() }
            'Scalar' { $scalar=$cmd.ExecuteScalar(); if($scalar -is [DBNull]){return $null}; return $scalar }
            'Rows' {
                $reader=$cmd.ExecuteReader()
                try {
                    while($reader.Read()) {
                        $row=[ordered]@{}
                        for($i=0;$i -lt $reader.FieldCount;$i++) {
                            # Direct assignment preserves BLOB byte[] including empty arrays;
                            # an if-expression pipeline would enumerate their individual bytes.
                            if($reader.IsDBNull($i)){$row[$reader.GetName($i)]=$null}
                            else{$row[$reader.GetName($i)]=$reader.GetValue($i)}
                        }
                        [pscustomobject]$row
                    }
                } finally { $reader.Dispose() }
            }
        }
    } catch { if($null -ne $Store.Transaction){$Store.TransactionFailed=$true}; throw }
    finally { $cmd.Dispose() }
}
function Invoke-TPUnitOfWork {
    param($Store,[scriptblock]$Block)
    Assert-TPStore $Store -Write
    if ($null -ne $Store.Transaction) {
        try { & $Block $Store } catch { $Store.TransactionFailed=$true; throw }
        return
    }
    $Store.Transaction=$Store.Connection.BeginTransaction([Data.IsolationLevel]::Serializable)
    $Store.TransactionFailed=$false
    try {
        $tpUnitResult=@(& $Block $Store)
        if($Store.TransactionFailed) { throw 'Transaction was marked rollback-only by a failed nested operation.' }
        $Store.Transaction.Commit()
        return $tpUnitResult
    } catch {
        try{$Store.Transaction.Rollback()}catch{}
        throw
    } finally { $Store.Transaction.Dispose(); $Store.Transaction=$null; $Store.TransactionFailed=$false }
}
function Invoke-TaskPilotTransaction {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][scriptblock]$Action)
    Invoke-TPUnitOfWork -Store $Store -Block $Action
}
function Get-TPUtcNow { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[cultureinfo]::InvariantCulture) }
function Assert-TPDate([string]$Value) {
    $parsed=[datetime]::MinValue
    if(-not [datetime]::TryParseExact($Value,'yyyy-MM-dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw "Invalid ISO date: $Value"}
}
function ConvertTo-TPOptionalDate([string]$Value) { if([string]::IsNullOrWhiteSpace($Value)){return $null}; Assert-TPDate $Value; return $Value }
function ConvertTo-TPHours {
    param([decimal]$Value,[long]$Maximum=[long]::MaxValue)
    $scaled=$Value*100
    if($Value -lt 0 -or $scaled -ne [decimal]::Truncate($scaled) -or $scaled -gt $Maximum){throw 'Hours must be nonnegative with at most two decimal places and within the supported range.'}
    return [long]$scaled
}
function Get-TPToken {
    param($Value)
    $json=ConvertTo-Json -InputObject $Value -Depth 40 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() }
    finally{$sha.Dispose()}
}
function Assert-TPExpectedToken([string]$Expected,[string]$Actual){if([string]::IsNullOrWhiteSpace($Expected)-or $Expected -cne $Actual){throw 'Concurrency conflict: reload the current record before saving.'}}
function Assert-TPDatabaseHeader([string]$Path) {
    # Read only the SQLite header before allowing any provider-driven recovery/write.
    $header=New-Object byte[] 100
    $inputFile=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
        $offset=0
        while($offset-lt100){$count=$inputFile.Read($header,$offset,100-$offset);if($count-eq0){break};$offset+=$count}
        if($offset-ne100 -or [Text.Encoding]::ASCII.GetString($header,0,16)-cne "SQLite format 3`0"){throw 'Database header is not a supported SQLite file.'}
        $app=[long]$header[68]*16777216+[long]$header[69]*65536+[long]$header[70]*256+[long]$header[71]
        $version=[long]$header[60]*16777216+[long]$header[61]*65536+[long]$header[62]*256+[long]$header[63]
        if($app-ne$script:TPApplicationId -or $version-ne$script:TPSchemaVersion){throw 'Database belongs to a different app or schema version; it will not be opened for writing.'}
    }finally{$inputFile.Dispose()}
}
function Open-TaskPilotStore {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$DatabasePath,[switch]$ReadOnly,[string]$TestProviderAssembly)
    $full=Get-TPResolvedPath $DatabasePath
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw 'Database does not exist; opening never creates one.'}
    Assert-TPDatabaseHeader $full
    $provider=Import-TPProvider -TestProviderAssembly $TestProviderAssembly
    $conn=New-TPConnection -Path $full -Provider $provider -ReadOnly ([bool]$ReadOnly)
    $store=[pscustomobject]@{Connection=$conn;Path=$full;Provider=$provider.Name;TestOnly=$provider.TestOnly;ReadOnly=[bool]$ReadOnly;Closed=$false;Transaction=$null;TransactionFailed=$false;TransactionReadOnly=$false}
    $store.PSTypeNames.Insert(0,'TaskPilot.Store')
    try {
        if([long](Invoke-TPSql $store 'PRAGMA application_id' -Mode Scalar) -ne $script:TPApplicationId -or [long](Invoke-TPSql $store 'PRAGMA user_version' -Mode Scalar) -ne $script:TPSchemaVersion){throw 'Database belongs to a different app or schema version; no automatic upgrade is performed.'}
        if(@(Invoke-TPSql $store 'PRAGMA foreign_key_check').Count -ne 0){throw 'Database has broken foreign-key references.'}
        return $store
    } catch{$conn.Dispose();$store.Closed=$true;throw}
}
function Close-TaskPilotStore {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store)
    if($Store.Closed){return}
    if($null -ne $Store.Transaction){throw 'Cannot close a store during a transaction.'}
    $Store.Connection.Dispose();$Store.Closed=$true
}
function New-TaskPilotDatabase {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$DatabasePath,[string]$TestProviderAssembly)
    $full=Get-TPResolvedPath $DatabasePath
    if([IO.Path]::GetExtension($full) -notin @('.db','.sqlite','.sqlite3')){throw 'Choose a new .db, .sqlite or .sqlite3 filename.'}
    $parent=Split-Path -Parent $full
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Destination parent must already exist.'}
    if(Test-Path -LiteralPath $full){throw 'Destination already exists and will not be overwritten.'}
    foreach($suffix in @('-journal','-wal','-shm')){if(Test-Path -LiteralPath ($full+$suffix)){throw 'Existing SQLite sidecar found; choose a new name without deleting recovery files.'}}
    $provider=Import-TPProvider -TestProviderAssembly $TestProviderAssembly
    $stage=Join-Path $parent ('.taskpilot4b_'+[guid]::NewGuid().ToString('N')+'.db')
    $conn=$null;$validationStore=$null
    try {
        $file=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$file.Dispose()
        $conn=New-TPConnection -Path $stage -Provider $provider
        $cmd=$conn.CreateCommand()
        try{$cmd.CommandText=Get-Content -LiteralPath (Join-Path $script:TPModuleRoot '../../schema/001_initial.sql') -Raw -Encoding UTF8;$null=$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}
        $conn.Dispose();$conn=$null
        $validationStore=Open-TaskPilotStore -DatabasePath $stage -TestProviderAssembly $TestProviderAssembly
        if([string](Invoke-TPSql $validationStore 'PRAGMA integrity_check' -Mode Scalar) -ne 'ok'){throw 'New database integrity check failed.'}
        Close-TaskPilotStore $validationStore;$validationStore=$null
        foreach($suffix in @('-journal','-wal','-shm')){if(Test-Path -LiteralPath ($full+$suffix)){throw 'A destination recovery sidecar appeared; database publication stopped.'}}
        [IO.File]::Move($stage,$full)
        return [pscustomobject]@{DatabasePath=$full;SchemaVersion=$script:TPSchemaVersion;Provider=$provider.Name;TestOnly=$provider.TestOnly;LegacyDataImported=$false}
    } finally {
        if($null -ne $validationStore -and -not $validationStore.Closed){Close-TaskPilotStore $validationStore}
        if($null -ne $conn){$conn.Dispose()}
        foreach($item in @($stage,($stage+'-journal'),($stage+'-wal'),($stage+'-shm'))){if(Test-Path -LiteralPath $item){Remove-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue}}
    }
}
function Get-TaskPilotProviderInfo {
    [CmdletBinding()]param([string]$TestProviderAssembly)
    $provider=Import-TPProvider -TestProviderAssembly $TestProviderAssembly
    $conn=New-TPConnection -Path ':memory:' -Provider $provider
    try{
        $cmd=$conn.CreateCommand()
        try{
            $cmd.CommandText='SELECT sqlite_version()';$version=[string]$cmd.ExecuteScalar()
            $cmd.CommandText="SELECT json_valid('{}')";if([int]$cmd.ExecuteScalar()-ne1){throw 'SQLite JSON support is missing.'}
            $cmd.CommandText='CREATE TABLE provider_probe(value INTEGER) STRICT;';$null=$cmd.ExecuteNonQuery()
            return [pscustomobject]@{Provider=$provider.Name;SQLiteVersion=$version;TestOnly=$provider.TestOnly;MemoryProbePassed=$true}
        }finally{$cmd.Dispose()}
    }finally{$conn.Dispose()}
}
function Get-TaskPilotStoreInfo {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store)
    Assert-TPStore $Store
    [pscustomobject]@{DatabasePath=$Store.Path;Provider=$Store.Provider;TestOnly=$Store.TestOnly;ReadOnly=$Store.ReadOnly;SQLiteVersion=[string](Invoke-TPSql $Store 'SELECT sqlite_version()' -Mode Scalar);SchemaVersion=[long](Invoke-TPSql $Store 'PRAGMA user_version' -Mode Scalar);Tables=[long](Invoke-TPSql $Store "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'" -Mode Scalar);ReportsDirty=[bool](Invoke-TPSql $Store 'SELECT is_dirty FROM report_state WHERE singleton_id=1' -Mode Scalar)}
}
function Get-TaskPilotTask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[long]$TaskId,[switch]$IncludeDeleted,[switch]$IncludeArchived)
    $clauses=New-Object 'System.Collections.Generic.List[string]';$parameters=@{}
    if($PSBoundParameters.ContainsKey('TaskId')){$clauses.Add('t.task_id=@id');$parameters['id']=$TaskId}
    if(-not $IncludeDeleted){$clauses.Add('t.is_deleted=0')}
    if(-not $IncludeArchived){$clauses.Add('t.is_archived=0')}
    $where=if($clauses.Count){' WHERE '+($clauses -join ' AND ')}else{''}
    $rows=@(Invoke-TPSql $Store ('SELECT t.*,p.planned_on,p.work_start_on,COALESCE(p.estimated_hours_x100,0) AS estimated_hours_x100 FROM tasks t LEFT JOIN task_plans p ON p.task_id=t.task_id'+$where+' ORDER BY t.task_id') -Parameters $parameters)
    foreach($row in $rows){$row|Add-Member -NotePropertyName estimated_hours -NotePropertyValue ([decimal]$row.estimated_hours_x100/100);$row}
}
function Get-TPTaskRequired($Store,[long]$TaskId,[switch]$AllowDeleted){
    $rows=@(Get-TaskPilotTask -Store $Store -TaskId $TaskId -IncludeArchived -IncludeDeleted)
    if($rows.Count -ne 1){throw 'Task does not exist.'}
    if(-not $AllowDeleted -and $rows[0].is_deleted){throw 'Task is deleted.'}
    return $rows[0]
}
function Touch-TPTask($Store,[long]$TaskId,[long]$ExpectedVersion,[switch]$AllowDeleted){
    $existing=Get-TPTaskRequired $Store $TaskId -AllowDeleted:$AllowDeleted
    if($existing.row_version -ne $ExpectedVersion){throw 'Concurrency conflict: reload the task before saving.'}
    $n=Invoke-TPSql $Store 'UPDATE tasks SET row_version=row_version+1,updated_at_utc=@now WHERE task_id=@id AND row_version=@version' -Parameters @{now=Get-TPUtcNow;id=$TaskId;version=$ExpectedVersion} -Mode NonQuery
    if($n -ne 1){throw 'Concurrency conflict: task changed while saving.'}
}
function Add-TaskPilotTask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Title,[ValidateSet('高','中','低')][string]$Priority='中',[ValidateSet('未着手','対応中','完了')][string]$Status='未着手',[string]$RegisteredOn=(Get-Date).ToString('yyyy-MM-dd'),[string]$DueOn,[string]$Memo='',[string]$PlannedOn,[string]$WorkStartOn,[decimal]$EstimatedHours=0,[long]$CalendarId=1)
    Invoke-TPUnitOfWork $Store {
        if([string]::IsNullOrWhiteSpace($Title)){throw 'Task title is required.'};Assert-TPDate $RegisteredOn
        $due=ConvertTo-TPOptionalDate $DueOn;$planned=ConvertTo-TPOptionalDate $PlannedOn;$start=ConvertTo-TPOptionalDate $WorkStartOn;$hours=ConvertTo-TPHours $EstimatedHours -Maximum 10000000
        $null=Invoke-TPSql $Store 'INSERT INTO tasks(registered_on,title,priority,status,due_on,memo,calendar_id) VALUES(@registered,@title,@priority,@status,@due,@memo,@calendar)' -Parameters @{registered=$RegisteredOn;title=$Title;priority=$Priority;status=$Status;due=$due;memo=$Memo;calendar=$CalendarId} -Mode NonQuery
        $newId=[long](Invoke-TPSql $Store 'SELECT last_insert_rowid()' -Mode Scalar)
        $null=Invoke-TPSql $Store 'INSERT INTO task_plans(task_id,planned_on,work_start_on,estimated_hours_x100) VALUES(@id,@planned,@start,@hours)' -Parameters @{id=$newId;planned=$planned;start=$start;hours=$hours} -Mode NonQuery
        Get-TPTaskRequired $Store $newId
    }
}
function Set-TaskPilotTask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion,[string]$Title,[ValidateSet('高','中','低')][string]$Priority,[ValidateSet('未着手','対応中','完了')][string]$Status,[AllowEmptyString()][string]$DueOn,[AllowEmptyString()][string]$Memo,[AllowEmptyString()][string]$PlannedOn,[AllowEmptyString()][string]$WorkStartOn,[decimal]$EstimatedHours,[object]$Archived,[long]$CalendarId)
    $taskChanges=@{};foreach($key in $PSBoundParameters.Keys){$taskChanges[$key]=$PSBoundParameters[$key]}
    Invoke-TPUnitOfWork $Store {
        if($taskChanges.ContainsKey('Archived') -and $Archived -isnot [bool]){throw 'Archived must be a Boolean.'}
        $currentTask=Get-TPTaskRequired $Store $TaskId
        Touch-TPTask $Store $TaskId $ExpectedVersion
        $assignments=New-Object 'System.Collections.Generic.List[string]';$values=@{id=$TaskId}
        $map=@{Title='title';Priority='priority';Status='status';Memo='memo';Archived='is_archived';CalendarId='calendar_id'}
        foreach($field in $map.Keys){if($taskChanges.ContainsKey($field)){if($field-eq'Title' -and [string]::IsNullOrWhiteSpace($Title)){throw 'Title is required.'};$assignments.Add($map[$field]+'=@'+$field);$values[$field]=$taskChanges[$field]}}
        if($taskChanges.ContainsKey('DueOn')){$assignments.Add('due_on=@due');$values['due']=ConvertTo-TPOptionalDate $DueOn}
        if($assignments.Count){$null=Invoke-TPSql $Store ('UPDATE tasks SET '+($assignments -join ',')+' WHERE task_id=@id') -Parameters $values -Mode NonQuery}
        $planChanged=$false
        $plan=@{id=$TaskId;planned=$currentTask.planned_on;start=$currentTask.work_start_on;hours=[long]$currentTask.estimated_hours_x100}
        if($taskChanges.ContainsKey('PlannedOn')){$plan.planned=ConvertTo-TPOptionalDate $PlannedOn;$planChanged=$true}
        if($taskChanges.ContainsKey('WorkStartOn')){$plan.start=ConvertTo-TPOptionalDate $WorkStartOn;$planChanged=$true}
        if($taskChanges.ContainsKey('EstimatedHours')){$plan.hours=ConvertTo-TPHours $EstimatedHours -Maximum 10000000;$planChanged=$true}
        if($planChanged){$null=Invoke-TPSql $Store 'INSERT INTO task_plans(task_id,planned_on,work_start_on,estimated_hours_x100) VALUES(@id,@planned,@start,@hours) ON CONFLICT(task_id) DO UPDATE SET planned_on=excluded.planned_on,work_start_on=excluded.work_start_on,estimated_hours_x100=excluded.estimated_hours_x100' -Parameters $plan -Mode NonQuery}
        Get-TPTaskRequired $Store $TaskId
    }
}
function Remove-TaskPilotTask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion)
    Invoke-TPUnitOfWork $Store {Touch-TPTask $Store $TaskId $ExpectedVersion;$null=Invoke-TPSql $Store 'UPDATE tasks SET is_deleted=1,deleted_at_utc=@now WHERE task_id=@id' -Parameters @{now=Get-TPUtcNow;id=$TaskId} -Mode NonQuery;Get-TPTaskRequired $Store $TaskId -AllowDeleted}
}
function Restore-TaskPilotTask {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Store,[Parameter(Mandatory=$true)][long]$TaskId,[Parameter(Mandatory=$true)][long]$ExpectedVersion)
    Invoke-TPUnitOfWork $Store {Touch-TPTask $Store $TaskId $ExpectedVersion -AllowDeleted;$null=Invoke-TPSql $Store 'UPDATE tasks SET is_deleted=0,deleted_at_utc=NULL WHERE task_id=@id' -Parameters @{id=$TaskId} -Mode NonQuery;Get-TPTaskRequired $Store $TaskId}
}

. (Join-Path $PSScriptRoot 'TaskPilot.Children.ps1')
. (Join-Path $PSScriptRoot 'TaskPilot.Domain.ps1')
. (Join-Path $PSScriptRoot 'TaskPilot.MigrationFiles.ps1')
. (Join-Path $PSScriptRoot 'TaskPilot.MigrationNormalize.ps1')
. (Join-Path $PSScriptRoot 'TaskPilot.MigrationDomains.ps1')
. (Join-Path $PSScriptRoot 'TaskPilot.Migration.ps1')
Export-ModuleMember -Function @('Test-TaskPilotLegacyData','Import-TaskPilotLegacyData')
Export-ModuleMember -Function @('New-TaskPilotDatabase','Open-TaskPilotStore','Close-TaskPilotStore','Get-TaskPilotStoreInfo','Get-TaskPilotProviderInfo','Invoke-TaskPilotTransaction','Add-TaskPilotTask','Get-TaskPilotTask','Set-TaskPilotTask','Remove-TaskPilotTask','Restore-TaskPilotTask','*-TaskPilotSubtask','*-TaskPilotWorkLog','*-TaskPilotCompletionActual','Complete-TaskPilotTask','*-TaskPilotCalendar','*-TaskPilotHolidaySet','*-TaskPilotRecurringRule','Get-TaskPilotRecurringRules','Invoke-TaskPilotRecurringOccurrence','*-TaskPilotMonthlySnapshot','*-TaskPilotSettings','*-TaskPilotNotifications','Get-TaskPilotReadSnapshot')
