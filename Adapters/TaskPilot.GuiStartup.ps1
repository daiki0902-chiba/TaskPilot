#requires -Version 5.1
function Test-TPGuiIsolatedMode {
    $runtime=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    return $null-ne$runtime-and$null-ne$runtime.Value-and[bool]$runtime.Value.IsTestMode
}
function Get-TPGuiSandbox {
    if(-not(Test-TPGuiIsolatedMode)){throw '独立テストモードの保存境界がありません。'}
    $variable=Get-Variable -Name TPRuntimeSandbox -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$variable-or$null-eq$variable.Value){throw '独立テストモードの保存境界を初期化できませんでした。'}
    return $variable.Value
}
function Assert-TPGuiStoreIntegrity {
    # The active pointer can outlive a changed or damaged database. SQLite's
    # page/FK checks alone do not detect missing tables or history guards.
    $module=Get-TPGuiStartupModule
    & $module {param($store) Assert-TPProtectionStoreIntegrity $store} $script:TPGuiStore
}
function Get-TPGuiStartupModule {
    $variable=Get-Variable -Name TPStorageModule -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$variable -or $null-eq$variable.Value){
        $script:TPStorageModule=Import-Module (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -PassThru
    }
    return $script:TPStorageModule
}
function Get-TPGuiValidatedStartupPath([string]$Path){
    if(Test-TPGuiIsolatedMode){$Path=(Get-TPGuiSandbox).AssertPath($Path)}
    $module=Get-TPGuiStartupModule
    return & $module {param($p) $full=Get-TPResolvedPath $p;Assert-TPProtectionNoLinks $full;return $full} $Path
}
function Get-TPGuiStoreRootPath([string]$StoreRoot){
    $full=Get-TPGuiValidatedStartupPath $StoreRoot
    $pathRoot=[IO.Path]::GetPathRoot($full)
    while($full.Length-gt$pathRoot.Length -and ($full.EndsWith([string][IO.Path]::DirectorySeparatorChar)-or$full.EndsWith([string][IO.Path]::AltDirectorySeparatorChar))){$full=$full.Substring(0,$full.Length-1)}
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        if(-not$sandbox.Exists($full)){throw 'アプリ保存フォルダーがありません。空DBは自動作成しません。'}
        # The broker enumerates the held directory handle and verifies its
        # type; Directory.Exists would reopen a replaceable pathname.
        $null=$sandbox.ListDirectory($full)
    }elseif(-not[IO.Directory]::Exists($full)){throw 'アプリ保存フォルダーがありません。空DBは自動作成しません。'}
    return $full
}
function Test-TPGuiUninitializedRoot([string]$StoreRoot){
    # Empty directories are harmless. Files or links indicate prior user state;
    # never infer that state can be replaced by an empty database.
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $full=$sandbox.AssertPath($StoreRoot)
        $sandbox.ValidateTree()
        $ignored=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($path in @($sandbox.MarkerPath,$sandbox.LockPath)){$null=$ignored.Add([string]$path)}
        $nonAuthoritative=@([string]$sandbox.Logs,[string]$sandbox.Temp,[string]$sandbox.Input)
        $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($full)
        while($pending.Count-gt0){
            foreach($entry in $sandbox.ListDirectory($pending.Pop())){
                $null=$sandbox.AssertPath($entry.FullName)
                if($ignored.Contains($entry.FullName)){continue}
                if(-not$entry.IsDirectory){return $false}
                if($nonAuthoritative-contains$entry.FullName){continue}
                $pending.Push([string]$entry.FullName)
            }
        }
        return $true
    }
    $pending=New-Object 'Collections.Generic.Stack[IO.DirectoryInfo]'
    $pending.Push([IO.DirectoryInfo]$StoreRoot)
    while($pending.Count-gt0){
        foreach($entry in $pending.Pop().GetFileSystemInfos()){
            if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){return $false}
            if(($entry.Attributes-band[IO.FileAttributes]::Directory)-eq0){return $false}
            $pending.Push([IO.DirectoryInfo]$entry)
        }
    }
    return $true
}
function Get-TPGuiActiveDatabasePath {
    param([Parameter(Mandatory=$true)][string]$StoreRoot,[switch]$AllowUninitialized)
    $rootFull=Get-TPGuiStoreRootPath $StoreRoot
    $pointer=Get-TPGuiValidatedStartupPath (Join-Path $rootFull 'active-store.json')
    $pointerExists=if(Test-TPGuiIsolatedMode){(Get-TPGuiSandbox).Exists($pointer)}else{[IO.File]::Exists($pointer)}
    if(-not$pointerExists){
        if(-not(Test-TPGuiIsolatedMode)-and[IO.Directory]::Exists($pointer)){throw '起動DBの指定ファイルがフォルダーになっています。空DBは作成しません。'}
        $default=Join-Path $rootFull 'TaskPilot.db'
        if(Test-TPGuiIsolatedMode){
            $entries=@((Get-TPGuiSandbox).ListDirectory($rootFull))
            $databases=@($entries|Where-Object {-not$_.IsDirectory-and$_.Name-like'*.db'})
            $previous=@($entries|Where-Object {-not$_.IsDirectory-and$_.Name-like'active-store.json.previous.*'})
        }else{
            $databases=@(([IO.DirectoryInfo]$rootFull).GetFiles('*.db'))
            $previous=@(([IO.DirectoryInfo]$rootFull).GetFiles('active-store.json.previous.*'))
        }
        # Compatibility with the first SQLite build, which only created this
        # fixed filename. Multiple candidates or prior pointers are ambiguous.
        $defaultExists=if(Test-TPGuiIsolatedMode){(Get-TPGuiSandbox).Exists($default)}else{[IO.File]::Exists($default)}
        if($databases.Count-eq1 -and $defaultExists -and $previous.Count-eq0){
            $default=Get-TPGuiValidatedStartupPath $default
            $module=Get-TPGuiStartupModule
            & $module {param($p) Assert-TPDatabaseHeader $p} $default
            return $default
        }
        if($AllowUninitialized -and (Test-TPGuiUninitializedRoot $rootFull)){return $default}
        throw '起動DBの指定ファイルがありません。既存データを確認するため、空DBは自動作成しません。'
    }
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        if($sandbox.GetFileLength($pointer)-gt4096){throw '起動DBの指定ファイルが不正です。自動初期化は行いません。'}
        $bytes=$sandbox.ReadAllBytes($pointer)
    }else{
        $stream=[IO.File]::Open($pointer,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            if($stream.Length-gt4096){throw '起動DBの指定ファイルが不正です。自動初期化は行いません。'}
            $bytes=New-Object byte[] ([int]$stream.Length);$offset=0
            while($offset-lt$bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-eq0){throw '起動DBの指定ファイルが読み取り中に変わりました。'};$offset+=$read}
        }finally{$stream.Dispose()}
    }
    . (Join-Path $PSScriptRoot '../Codec/Import-TaskPilotMigrationCodec.ps1')
    $value=[TaskPilot.Migration.Codec]::ParseJson([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
    if($value-isnot[Collections.IDictionary] -or $value.Count-ne2 -or -not$value.Contains('file') -or -not$value.Contains('format') -or $value['format']-isnot[TaskPilot.Migration.JsonNumber] -or $value['format'].Lexeme-cne'1'){throw '起動DBの指定形式が不正です。'}
    $leaf=$value['file']
    if($leaf-isnot[string] -or $leaf-cnotmatch'^TaskPilot(?:_[a-zA-Z0-9]+)*\.db$'){throw '起動DBにはアプリ保存フォルダー内のTaskPilot DBだけを指定できます。'}
    $candidate=Get-TPGuiValidatedStartupPath (Join-Path $rootFull $leaf)
    $candidateExists=if(Test-TPGuiIsolatedMode){(Get-TPGuiSandbox).Exists($candidate)}else{[IO.File]::Exists($candidate)}
    if(-not$candidateExists){throw '指定された起動DBがありません。空DBは作成しません。'}
    $module=Get-TPGuiStartupModule
    & $module {param($p) Assert-TPDatabaseHeader $p} $candidate
    return $candidate
}
function Set-TPGuiActiveDatabasePath {
    param([Parameter(Mandatory=$true)][string]$StoreRoot,[Parameter(Mandatory=$true)][string]$DatabasePath,[string]$TestProviderAssembly)
    $rootFull=Get-TPGuiStoreRootPath $StoreRoot
    $full=Get-TPGuiValidatedStartupPath $DatabasePath
    if([IO.Path]::GetDirectoryName($full)-ine$rootFull -or [IO.Path]::GetFileName($full)-cnotmatch'^TaskPilot(?:_[a-zA-Z0-9]+)*\.db$'){throw '復元DBはアプリ保存フォルダー内の新しいファイルである必要があります。'}
    $pointer=Get-TPGuiValidatedStartupPath (Join-Path $rootFull 'active-store.json')
    if(-not(Test-TPGuiIsolatedMode)-and[IO.Directory]::Exists($pointer)){throw '起動DBの指定先はフォルダーではなくファイルである必要があります。'}
    $providerArguments=@{};if($TestProviderAssembly){$providerArguments.TestProviderAssembly=$TestProviderAssembly}
    $module=Get-TPGuiStartupModule
    $read=$null
    try{
        $read=Open-TaskPilotStore -DatabasePath $full -ReadOnly @providerArguments
        & $module {param($s) Assert-TPProtectionStoreIntegrity $s} $read
    }finally{if($null-ne$read){Close-TaskPilotStore $read}}
    $stage=$pointer+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $text=[ordered]@{format=1;file=[IO.Path]::GetFileName($full)}|ConvertTo-Json
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $previous=if($sandbox.Exists($pointer)){$pointer+'.previous.'+[guid]::NewGuid().ToString('N')}else{$null}
        $sandbox.AtomicWrite($pointer,[Text.UTF8Encoding]::new($false,$true).GetBytes($text),$previous)
        return
    }
    $owned=$false
    try{
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $owned=$true
        try{$bytes=[Text.UTF8Encoding]::new($true).GetBytes($text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        $null=Get-TPGuiValidatedStartupPath $pointer
        if([IO.File]::Exists($pointer)){
            $previous=$pointer+'.previous.'+[guid]::NewGuid().ToString('N')
            if([IO.File]::Exists($previous)-or[IO.Directory]::Exists($previous)){throw '以前の起動DB指定の保管先が既に存在します。'}
            [IO.File]::Replace($stage,$pointer,$previous)
        }else{[IO.File]::Move($stage,$pointer)}
        $owned=$false
    }finally{if($owned-and[IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}
}
function Initialize-TPGuiApplication {
    foreach($name in @('TPAppLock','TPLegacyLock','TPGuiStore')){
        $existing=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        if($null-ne$existing -and $null-ne$existing.Value){throw 'TaskPilotの起動処理は既に実行されています。'}
    }
    $script:TPAppLock=$null;$script:TPLegacyLock=$null;$script:TPGuiStore=$null
    $script:TPStorageModule=Import-Module (Join-Path $InstallRoot 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -PassThru
    if(Test-TPGuiIsolatedMode){Set-TaskPilotTestSandbox -Sandbox (Get-TPGuiSandbox)}
    # Different root: neither startup nor restore writes inside the old CSV/JSON store.
    $null=Get-TPGuiValidatedStartupPath (Join-Path $Root 'TaskPilot.db')
    try{
    if(Test-TPGuiIsolatedMode){
        $sandbox=Get-TPGuiSandbox
        $sandbox.ValidateTree()
        $script:TPAppLock=$sandbox.AcquireLock([string]$sandbox.LockPath)
        foreach($directory in @($Root,$ExportDir,$BackupDir,$LogDir)){$null=$sandbox.EnsureDirectory($directory)}
    }else{
        $appLockPath=Get-TPGuiValidatedStartupPath (Join-Path $LocalAppData 'TaskPilot4.storage.lock')
        $script:TPAppLock=[IO.File]::Open($appLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        foreach($directory in @($Root,$ExportDir,$BackupDir,$LogDir)){$null=Get-TPGuiValidatedStartupPath $directory;$null=[IO.Directory]::CreateDirectory($directory)}
    }
    $database=Get-TPGuiActiveDatabasePath -StoreRoot $Root -AllowUninitialized
    $databaseExists=if(Test-TPGuiIsolatedMode){(Get-TPGuiSandbox).Exists($database)}else{[IO.File]::Exists($database)}
    if(-not$databaseExists){
        if(-not(Test-TPGuiIsolatedMode)-and[IO.Directory]::Exists($LegacyRoot)){
            $inspection=Test-TaskPilotLegacyData -SourceRoot $LegacyRoot
            $reportPath=Join-Path $LogDir ('MigrationInspection_'+[guid]::NewGuid().ToString('N')+'.json')
            [IO.File]::WriteAllText($reportPath,($inspection|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
            if(-not$inspection.CanImport){throw "旧データの検査で $($inspection.ErrorCount) 件のエラーが見つかりました。元データは変更していません。検査結果: $reportPath"}
            $question="旧TaskPilotのデータをSQLiteへコピーして引き継ぎます。`r`nタスク: $($inspection.Counts.tasks) 件 / 警告: $($inspection.WarningCount) 件`r`n`r`n元データは残し、完全バックアップを作成します。`r`n検査結果: $reportPath`r`n`r`n警告がある場合は検査結果を確認してください。続けますか？"
            $answer=[System.Windows.Forms.MessageBox]::Show($question,'TaskPilot データ引き継ぎ',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if($answer-ne[System.Windows.Forms.DialogResult]::Yes){throw 'データの引き継ぎを中止しました。元データは変更していません。'}
            # Failed/cancelled initialization must leave the new DB root empty.
            # Keep migration evidence outside it so a later retry is possible,
            # while the strict prior-state guard still protects actual DB files.
            $legacyBackupParent=Get-TPGuiValidatedStartupPath (Join-Path $LocalAppData 'TaskPilot4LegacyBackups')
            $null=[IO.Directory]::CreateDirectory($legacyBackupParent)
            $backup=Join-Path $legacyBackupParent ('LegacyBackup_'+[guid]::NewGuid().ToString('N'))
            $result=Import-TaskPilotLegacyData -SourceRoot $LegacyRoot -DatabasePath $database -BackupRoot $backup -ExpectedManifestSha256 $inspection.ManifestSha256 -Apply -AcknowledgeWarnings
            $resultPath=Join-Path $LogDir ('MigrationResult_'+$result.BatchId+'.json')
            [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
            [System.Windows.Forms.MessageBox]::Show("引き継ぎが完了しました。`r`nバックアップ: $backup`r`n結果: $resultPath`r`n元データは残っています。今後はこのSQLite版で作業してください。",'TaskPilot')|Out-Null
        }else{$null=New-TaskPilotDatabase -DatabasePath $database}
    }
    # Hold the original app's cooperative lock for this entire GUI session.
    if(-not(Test-TPGuiIsolatedMode)){
        $legacyLockPath=Get-TPGuiValidatedStartupPath (Join-Path $LocalAppData 'TaskPilot.storage.lock')
        $script:TPLegacyLock=[IO.File]::Open($legacyLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
    $pointerPath=Join-Path $Root 'active-store.json'
    $pointerExists=if(Test-TPGuiIsolatedMode){(Get-TPGuiSandbox).Exists($pointerPath)}else{[IO.File]::Exists($pointerPath)}
    if(-not$pointerExists){Set-TPGuiActiveDatabasePath -StoreRoot $Root -DatabasePath $database}
    $opened=Open-TaskPilotStore -DatabasePath $database
    $script:TPGuiStore=$opened
    Initialize-TPGuiContext -Store $opened -ModulePath (Join-Path $InstallRoot 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1')
    Assert-TPGuiStoreIntegrity
    }catch{
        $startupFailure=$_
        try{Close-TPGuiApplication}catch{}
        throw $startupFailure
    }
}
function Close-TPGuiApplication {
    $failure=$null
    $storeVariable=Get-Variable -Name TPGuiStore -Scope Script -ErrorAction SilentlyContinue
    if($null-ne$storeVariable -and $null-ne$storeVariable.Value -and -not$storeVariable.Value.Closed){
        $store=$storeVariable.Value
        try{Close-TaskPilotStore $store}catch{
            $failure=$_
            # Closing a connection also rolls back an interrupted transaction.
            try{$store.Connection.Dispose();$store.Closed=$true}catch{}
        }
    }
    $script:TPGuiStore=$null
    foreach($name in @('TPLegacyLock','TPAppLock')){
        $variable=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        try{if($null-ne$variable -and $null-ne$variable.Value){$variable.Value.Dispose()}}catch{if($null-eq$failure){$failure=$_}}
        finally{Set-Variable -Name $name -Scope Script -Value $null}
    }
    if($null-ne$failure){throw $failure}
}
function Backup-Data {
    $destination=Join-Path $BackupDir ('TaskPilot_'+(Get-Date -Format 'yyyyMMddHHmmssfff')+'_'+[guid]::NewGuid().ToString('N')+'.db')
    $null=New-TaskPilotDatabaseBackup -Store $script:TPGuiStore -DestinationPath $destination
}
function Restore-GuiBackup {
    if(Test-TPGuiIsolatedMode){
        $selected=Select-TPGuiIsolatedFile -Directory $BackupDir -Extension '.db'
        if([string]::IsNullOrWhiteSpace($selected)){return}
    }else{
        $dialog=New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title='復元するTaskPilot SQLiteバックアップを選択'
        $dialog.Filter='TaskPilot SQLite (*.db)|*.db'
        $dialog.InitialDirectory=$BackupDir
        try{if($dialog.ShowDialog($form)-ne[System.Windows.Forms.DialogResult]::OK){return};$selected=$dialog.FileName}finally{$dialog.Dispose()}
    }
    if(-not(Ask-Confirm 'バックアップから新しいDBへ復元します。現在のDBと復元前バックアップは残します。復元後にアプリを終了します。続けますか？')){return}
    Backup-Data
    $target=Join-Path $Root ('TaskPilot_restored_'+[guid]::NewGuid().ToString('N')+'.db')
    $null=Restore-TaskPilotDatabase -BackupPath $selected -DatabasePath $target
    Set-TPGuiActiveDatabasePath -StoreRoot $Root -DatabasePath $target
    Write-ActionLog '復元' ([IO.Path]::GetFileName($target))
    [System.Windows.Forms.MessageBox]::Show('検証済みの新しいDBへ復元しました。アプリを再起動してください。以前のDBも保管しています。','TaskPilot')|Out-Null
    $form.Close()
}
function Save-TextSafely {throw '旧CSV/JSONへの保存経路はSQLite版では利用できません。'}
