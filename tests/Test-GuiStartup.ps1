#requires -Version 5.1
[CmdletBinding()]param([string]$TestProviderAssembly)
# Headless: this test never calls Initialize-TPGuiApplication, any dialog or WinForms.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:TPStorageModule=Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force -PassThru
. (Join-Path $PSScriptRoot '../Adapters/TaskPilot.GuiStartup.ps1')
$providerArgs=@{};if($TestProviderAssembly){$providerArgs.TestProviderAssembly=$TestProviderAssembly}
$startupTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotStartup_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $startupTestRoot
$script:startupPassed=0;$script:startupFailed=0;$script:startupChecks=0;$script:startupSkips=0
function Check-Startup($Condition,[string]$Message){$script:startupChecks++;if(-not$Condition){throw $Message}}
function Reject-Startup([scriptblock]$Action,[string]$Message){$rejected=$false;try{$null=&$Action}catch{$rejected=$true};Check-Startup $rejected $Message}
function Case-Startup([string]$Name,[scriptblock]$Action){try{&$Action;$script:startupPassed++;Write-Output ('PASS: '+$Name)}catch{$script:startupFailed++;Write-Output ('FAIL: '+$Name+' : '+$_.Exception.Message);Write-Output $_.ScriptStackTrace}}
function New-StartupCase([switch]$Empty){
    $root=Join-Path $startupTestRoot ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $root
    $f=[pscustomobject]@{Root=$root;Database=(Join-Path $root 'TaskPilot.db');Pointer=(Join-Path $root 'active-store.json')}
    if(-not$Empty){
        $null=New-TaskPilotDatabase -DatabasePath $f.Database @providerArgs
        $s=Open-TaskPilotStore -DatabasePath $f.Database @providerArgs
        try{$null=Add-TaskPilotTask -Store $s -Title '消してはいけない既存タスク' -RegisteredOn '2026-11-16'}finally{Close-TaskPilotStore $s}
    }
    return $f
}
function Write-StartupPointer([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Check-StartupNoStages([string]$Root){Check-Startup (@(Get-ChildItem -LiteralPath $Root -Filter 'active-store.json.*.tmp' -Force).Count-eq0) 'A pointer stage was left behind.'}
function Try-StartupLink([string]$Path,[string]$Target){
    try{$null=New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop;return $true}
    catch{$script:startupSkips++;Write-Host 'SKIP: creating a symbolic link requires unavailable platform privileges.';return $false}
}
try{
    Case-Startup 'A missing pointer never creates or guesses an empty database' {
        $f=New-StartupCase -Empty
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root} 'An empty root was silently treated as an existing active store.'
        Check-Startup (-not[IO.File]::Exists($f.Database)) 'Reading a missing pointer created a database.'
        $new=Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized
        Check-Startup ($new-ceq$f.Database -and -not[IO.File]::Exists($new)) 'Explicit first-run discovery must only return a new path.'
        $null=New-Item -ItemType Directory -Path (Join-Path $f.Root 'EmptySubdirectory')
        Check-Startup ((Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized)-ceq$f.Database) 'Empty directories should not prevent first-run discovery.'
        [IO.File]::WriteAllText((Join-Path $f.Root 'prior-user-state.txt'),'Keep this state')
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized} 'A root with previous state was silently reinitialized.'
        Check-Startup (-not[IO.File]::Exists($f.Database)) 'Prior state was replaced by an empty database.'
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot (Join-Path $f.Root 'MissingRoot') -AllowUninitialized} 'Missing store root was silently created.'
    }
    Case-Startup 'Atomic pointer replacement retains both databases and the prior pointer' {
        $f=New-StartupCase;$oldHash=(Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash
        Check-Startup ((Get-TPGuiActiveDatabasePath -StoreRoot $f.Root)-ceq$f.Database) 'Single fixed-name pre-pointer DB must remain compatible.'
        Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $f.Database @providerArgs
        Check-Startup ((Get-TPGuiActiveDatabasePath -StoreRoot $f.Root)-ceq$f.Database) 'Initial pointer was not readable.'
        $oldPointerHash=(Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash
        $next=Join-Path $f.Root ('TaskPilot_restored_'+[guid]::NewGuid().ToString('N')+'.db')
        $null=Restore-TaskPilotDatabase -BackupPath $f.Database -DatabasePath $next @providerArgs
        $newHash=(Get-FileHash -LiteralPath $next -Algorithm SHA256).Hash
        Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $next @providerArgs
        Check-Startup ((Get-TPGuiActiveDatabasePath -StoreRoot $f.Root)-ceq$next) 'Pointer did not select the new verified database.'
        $previous=@(Get-ChildItem -LiteralPath $f.Root -Filter 'active-store.json.previous.*' -File)
        Check-Startup ($previous.Count-eq1 -and (Get-FileHash -LiteralPath $previous[0].FullName -Algorithm SHA256).Hash-ceq$oldPointerHash) 'Previous pointer was not retained exactly.'
        Check-Startup ((Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash-ceq$oldHash) 'Pointer switch changed the old database.'
        Check-Startup ((Get-FileHash -LiteralPath $next -Algorithm SHA256).Hash-ceq$newHash) 'Pointer switch changed the new database.'
        [IO.File]::Delete($f.Pointer)
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized} 'Deleted pointer guessed an older default DB despite restored candidates.'
        Check-Startup ([IO.File]::Exists($f.Database)-and[IO.File]::Exists($next)) 'Missing-pointer failure deleted a database.'
        Check-StartupNoStages $f.Root
    }
    Case-Startup 'Malformed UTF8, duplicate JSON fields and unsupported pointer formats fail closed' {
        $f=New-StartupCase;$hash=(Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash
        $invalid=@(
            '', 'null', '[]', '42', '{',
            '{"format":1,"file":"TaskPilot.db","file":"TaskPilot_missing.db"}',
            '{"format":1,"file":"TaskPilot.db","\u0066ile":"TaskPilot_missing.db"}',
            '{"format":"1","file":"TaskPilot.db"}',
            '{"format":1.0,"file":"TaskPilot.db"}',
            '{"format":2,"file":"TaskPilot.db"}',
            '{"format":1,"File":"TaskPilot.db"}',
            '{"format":1,"file":"TaskPilot.db","unexpected":true}'
        )
        foreach($text in $invalid){
            Write-StartupPointer $f.Pointer $text
            $pointerHash=(Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash
            Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized} 'Malformed pointer was accepted or fell back to the default.'
            Check-Startup ((Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash-ceq$pointerHash) 'Inspection changed malformed pointer bytes.'
        }
        [IO.File]::WriteAllBytes($f.Pointer,[byte[]]@(0x7b,0x22,0xc3,0x28,0x22,0x3a,0x31,0x7d))
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root} 'Invalid UTF8 was replaced silently.'
        [IO.File]::WriteAllBytes($f.Pointer,(New-Object byte[] 4097))
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root} 'An oversized pointer was read as a valid format.'
        Check-Startup ((Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash-ceq$hash) 'Bad pointer validation changed existing data.'
        Check-StartupNoStages $f.Root
    }
    Case-Startup 'Pointer file names reject traversal and missing DBs without fallback' {
        $f=New-StartupCase
        foreach($leaf in @('../TaskPilot.db','sub/TaskPilot.db','TaskPilot.db/../TaskPilot.db','TaskPilot.db:stream','C:\TaskPilot.db','/TaskPilot.db','other.db','TaskPilot_missing.db')){
            $json=[ordered]@{format=1;file=$leaf}|ConvertTo-Json
            Write-StartupPointer $f.Pointer $json
            Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized} ('Invalid or missing active database was accepted: '+$leaf)
        }
        $outside=New-StartupCase
        Reject-Startup {Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $outside.Database @providerArgs} 'A pointer escaped its store root.'
        Check-Startup (@(Get-ChildItem -LiteralPath $f.Root -Filter '*.db' -File).Count-eq1) 'A missing pointer target was silently created.'
    }
    Case-Startup 'Unsupported DB schema cannot replace a valid pointer or fall back to another DB' {
        $f=New-StartupCase
        Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $f.Database @providerArgs
        $pointerHash=(Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash
        $future=Join-Path $f.Root 'TaskPilot_future.db';$null=New-TaskPilotDatabase -DatabasePath $future @providerArgs
        $s=Open-TaskPilotStore -DatabasePath $future @providerArgs
        try{& $script:TPStorageModule {param($store) $null=Invoke-TPSql $store 'PRAGMA user_version=49999' -Mode NonQuery} $s}finally{Close-TaskPilotStore $s}
        $futureHash=(Get-FileHash -LiteralPath $future -Algorithm SHA256).Hash
        Reject-Startup {Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $future @providerArgs} 'Unknown schema became the active pointer.'
        Check-Startup ((Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash-ceq$pointerHash) 'Failed switch changed a valid pointer.'
        Check-Startup ((Get-TPGuiActiveDatabasePath -StoreRoot $f.Root)-ceq$f.Database) 'Failed switch changed the selected database.'
        Write-StartupPointer $f.Pointer '{"format":1,"file":"TaskPilot_future.db"}'
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root} 'Reading an unsupported active DB fell back to the default.'
        Check-Startup ((Get-FileHash -LiteralPath $future -Algorithm SHA256).Hash-ceq$futureHash) 'Unknown-schema inspection changed source bytes.'
        Check-StartupNoStages $f.Root
    }
    Case-Startup 'Store root, active pointer and DB links are rejected before reading or switching' {
        $f=New-StartupCase;$outside=Join-Path $startupTestRoot ('outside_'+[guid]::NewGuid().ToString('N')+'.json')
        Write-StartupPointer $outside '{"format":1,"file":"TaskPilot.db"}'
        $outsideHash=(Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
        if(Try-StartupLink $f.Pointer $outside){
            Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root} 'A symlink pointer was read.'
            Reject-Startup {Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $f.Database @providerArgs} 'A symlink pointer was replaced.'
            Check-Startup ((Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash-ceq$outsideHash) 'External pointer target was changed.'
            [IO.File]::Delete($f.Pointer)
        }
        $linkedRoot=Join-Path $startupTestRoot ('RootLink_'+[guid]::NewGuid().ToString('N'))
        if(Try-StartupLink $linkedRoot $f.Root){
            Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $linkedRoot} 'A symlink store root was read.'
            Reject-Startup {Set-TPGuiActiveDatabasePath -StoreRoot $linkedRoot -DatabasePath (Join-Path $linkedRoot 'TaskPilot.db') @providerArgs} 'A symlink store root was changed.'
            [IO.Directory]::Delete($linkedRoot)
        }
        $linked=New-StartupCase -Empty
        if(Try-StartupLink $linked.Database $f.Database){
            Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $linked.Root} 'A symlink active DB was selected.'
            Reject-Startup {Set-TPGuiActiveDatabasePath -StoreRoot $linked.Root -DatabasePath $linked.Database @providerArgs} 'A symlink DB became active.'
            [IO.File]::Delete($linked.Database)
        }
        $legacyLocal=[Environment]::GetFolderPath('LocalApplicationData')
        if($legacyLocal){Reject-Startup {Get-TPGuiValidatedStartupPath (Join-Path $legacyLocal 'TaskPilot/TaskPilot.db')} 'The original LocalAppData TaskPilot path guard was bypassed.'}
    }
    Case-Startup 'Existing active stores require schema tables, history guards and the migration ledger' {
        foreach($damage in @('DROP TRIGGER monthly_revision_no_update','DROP TABLE notification_history','DELETE FROM schema_migrations')){
            $f=New-StartupCase
            Set-TPGuiActiveDatabasePath -StoreRoot $f.Root -DatabasePath $f.Database @providerArgs
            $s=Open-TaskPilotStore -DatabasePath $f.Database @providerArgs
            try{
                $script:TPGuiStore=$s
                Assert-TPGuiStoreIntegrity
                & $script:TPStorageModule {param($store,$sql) $null=Invoke-TPSql $store $sql -Mode NonQuery} $s $damage
            }finally{Close-TPGuiApplication}
            $databaseHash=(Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash
            $pointerHash=(Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash
            $script:TPGuiStore=Open-TaskPilotStore -DatabasePath (Get-TPGuiActiveDatabasePath -StoreRoot $f.Root) @providerArgs
            try{
                $sqliteIntegrity=& $script:TPStorageModule {param($store) Invoke-TPSql $store 'PRAGMA integrity_check' -Mode Scalar} $script:TPGuiStore
                Check-Startup ($sqliteIntegrity-ceq'ok') 'Fixture must retain a valid SQLite file despite its incomplete app schema.'
                Reject-Startup {Assert-TPGuiStoreIntegrity} ('An existing active store bypassed required app structure validation: '+$damage)
            }finally{Close-TPGuiApplication}
            Check-Startup ((Get-FileHash -LiteralPath $f.Database -Algorithm SHA256).Hash-ceq$databaseHash) 'Failed startup validation modified existing database bytes.'
            Check-Startup ((Get-FileHash -LiteralPath $f.Pointer -Algorithm SHA256).Hash-ceq$pointerHash) 'Failed startup validation changed the active pointer.'
            Check-StartupNoStages $f.Root
        }
    }
    Case-Startup 'Retained diagnostics and migration backups do not block initialization retry' {
        $f=New-StartupCase -Empty
        $diagnostics=Join-Path $startupTestRoot ('Diagnostics_'+[guid]::NewGuid().ToString('N'))
        $backupParent=Join-Path $startupTestRoot ('LegacyBackups_'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($diagnostics)
        $null=[IO.Directory]::CreateDirectory((Join-Path $backupParent 'LegacyBackup_partial/Data'))
        [IO.File]::WriteAllText((Join-Path $diagnostics 'MigrationInspection_test.json'),'{}')
        [IO.File]::WriteAllText((Join-Path $diagnostics 'errors.log'),'Synthetic cancelled migration')
        [IO.File]::WriteAllText((Join-Path $backupParent 'LegacyBackup_partial/Data/TaskList.csv'),'retained backup bytes')
        $before=(Get-FileHash -LiteralPath (Join-Path $backupParent 'LegacyBackup_partial/Data/TaskList.csv')).Hash
        Check-Startup ((Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized)-ceq$f.Database) 'External migration evidence blocked an otherwise empty new DB root.'
        Check-Startup (-not[IO.File]::Exists($f.Database)) 'Retry discovery created an empty database.'
        Check-Startup ((Get-FileHash -LiteralPath (Join-Path $backupParent 'LegacyBackup_partial/Data/TaskList.csv')).Hash-ceq$before) 'Retry discovery changed the retained backup.'
        [IO.File]::WriteAllText((Join-Path $f.Root 'unknown-data.json'),'preserve')
        Reject-Startup {Get-TPGuiActiveDatabasePath -StoreRoot $f.Root -AllowUninitialized} 'Actual state inside the DB root must still block empty initialization.'
    }
    Case-Startup 'Cleanup is safe before initialization and releases partial stores and locks' {
        foreach($name in @('TPGuiStore','TPAppLock','TPLegacyLock')){Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue}
        Close-TPGuiApplication
        Close-TPGuiApplication
        Check-Startup ($null-eq$script:TPGuiStore -and $null-eq$script:TPAppLock -and $null-eq$script:TPLegacyLock) 'Cleanup did not initialize safe empty globals.'
        $f=New-StartupCase;$s=Open-TaskPilotStore -DatabasePath $f.Database @providerArgs
        $appLock=New-Object IO.MemoryStream;$legacyLock=New-Object IO.MemoryStream
        $script:TPGuiStore=$s;$script:TPAppLock=$appLock;$script:TPLegacyLock=$legacyLock
        Close-TPGuiApplication
        Check-Startup ($s.Closed -and -not$appLock.CanRead -and -not$legacyLock.CanRead) 'Partial initialization resources were not closed.'
        Close-TPGuiApplication
    }
    Write-Output ('Result: {0} GUI startup cases passed, {1} failed; {2} assertions; {3} privilege skips; no WinForms invoked.'-f$script:startupPassed,$script:startupFailed,$script:startupChecks,$script:startupSkips)
    if($script:startupFailed-gt0){throw 'Headless GUI startup tests failed.'}
}finally{
    try{Close-TPGuiApplication}catch{}
    Remove-Item -LiteralPath $startupTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
