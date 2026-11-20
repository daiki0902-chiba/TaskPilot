#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateZipPath,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedCandidateSha256='e977b31a8f6eb25c66b8d6d0658b421db13b2db1849b00c33a3234d5d1b70795',
    [ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceCommit='9c7ad91674f7c47784b51305c080405f7c534d80',
    [string]$WindowsVerificationPath=(Join-Path $PSScriptRoot '../docs/verification/windows-native-verification.json'),
    [string]$WindowsTestReportPath=(Join-Path $PSScriptRoot '../docs/verification/windows-native-results.json'),
    [ValidatePattern('^[0-9a-f]{40}$')][string]$BasePullRequestHead='c683d4ee80dcd9e66656e3feca04e96072910517',
    [ValidatePattern('^https://github[.]com/daiki0902-chiba/TaskPilot/actions/runs/[0-9]+$')][string]$ServerEvidenceRunUrl='https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44640521434'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-TPAcceptanceRelative([string]$Name){
    Assert-TPBuildRelative $Name
    if($Name.Length-gt1024-or$Name-match'[<>"|?*]'){throw 'Unsafe acceptance archive path.'}
    foreach($part in $Name.Split('/')){
        if(-not$part-or$part.EndsWith('.')-or$part.EndsWith(' ')-or$part-match'^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){
            throw 'Unsafe acceptance archive path segment.'
        }
    }
}
function Expand-TPAcceptanceCandidate([string]$Archive,[string]$Target,[string]$ExpectedSha256){
    if(Test-TPBuildPathExists $Target){throw 'Acceptance extraction target already exists.'}
    Assert-TPBuildNoLinks $Archive;Assert-TPBuildNoLinks $Target
    $archiveStream=[IO.File]::Open($Archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $zip=$null
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $entries=New-Object 'Collections.Generic.List[object]'
    [long]$total=0
    try{
        if($ExpectedSha256){
            if((Get-TPBuildStreamSha $archiveStream)-cne$ExpectedSha256){throw 'Candidate ZIP changed before extraction.'}
            $archiveStream.Position=0
        }
        $zip=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        foreach($entry in $zip.Entries){
            $name=$entry.FullName.Replace('\','/')
            $directory=$name.EndsWith('/')
            if($directory){$name=$name.Substring(0,$name.Length-1)}
            Assert-TPAcceptanceRelative $name
            if($name-cne'TaskPilot'-and-not$name.StartsWith('TaskPilot/',[StringComparison]::Ordinal)){throw 'Candidate archive must contain only TaskPilot/.'}
            if(-not$directory-and$name-ceq'TaskPilot'){throw 'TaskPilot/ must be a directory.'}
            if(-not$seen.Add($name)){throw 'Duplicate/case-colliding acceptance archive entry.'}
            $kind=($entry.ExternalAttributes-shr16)-band0xf000
            if(($entry.ExternalAttributes-band0x400)-ne0-or($kind-ne0-and$kind-ne0x8000-and-not($directory-and$kind-eq0x4000))){throw 'Links and special archive entries are refused.'}
            if($entry.Length-lt0-or$entry.Length-gt67108864){throw 'Acceptance archive entry is too large.'}
            $total+=$entry.Length
            if($total-gt268435456-or$seen.Count-gt512){throw 'Acceptance archive exceeds size or entry limits.'}
            $entries.Add([pscustomobject]@{Entry=$entry;Name=$name;Directory=$directory})
        }
        $null=[IO.Directory]::CreateDirectory($Target)
        foreach($item in $entries){
            $to=Join-Path $Target ($item.Name.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
            if($item.Directory){$null=[IO.Directory]::CreateDirectory($to);continue}
            $parent=[IO.Path]::GetDirectoryName($to)
            $null=[IO.Directory]::CreateDirectory($parent)
            $inputStream=$item.Entry.Open();$outputStream=$null
            try{
                $outputStream=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=New-Object byte[] 65536;[long]$copied=0
                while(($read=$inputStream.Read($buffer,0,$buffer.Length))-gt0){
                    $copied+=$read
                    if($copied-gt67108864-or$copied-gt$item.Entry.Length){throw 'Acceptance archive expanded beyond declared limits.'}
                    $outputStream.Write($buffer,0,$read)
                }
                if($copied-ne$item.Entry.Length){throw 'Acceptance archive entry length differs from its declaration.'}
                $outputStream.Flush($true)
            }finally{if($null-ne$outputStream){$outputStream.Dispose()};$inputStream.Dispose()}
        }
    }finally{if($null-ne$zip){$zip.Dispose()};$archiveStream.Dispose()}
}
function Get-TPAcceptancePurpose([string]$Path){
    if($Path-ceq'TaskPilot.exe'){return @('実行本体','受入対象の未署名Windows x64 EXE。実機起動は未検証。')}
    if($Path-ceq'TaskPilot.exe.config'){return @('実行設定','.NET実行設定。EXEと同じフォルダーに保持。')}
    if($Path-ceq'Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll'){return @('SQLite管理DLL','.NET用SQLiteプロバイダー。必須。')}
    if($Path-ceq'Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll'){return @('SQLite native DLL','x64 SQLite本体。今回のEXEの実行に必須。')}
    if($Path-ceq'Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll'){return @('SQLite native DLL','既存プロバイダー一式に含まれるx86版。x64 EXEの実行対象ではないが候補を改変せず保持。')}
    if($Path-ceq'Modules/ImportExcel/EPPlus.dll'){return @('Excel DLL','Excel出力用EPPlus。対応ソース・ライセンスとともに保持。')}
    if($Path.StartsWith('ThirdPartyNotices/')){return @('第三者表示','再配布に必要なライセンス・著作権表示。')}
    if($Path.StartsWith('ThirdPartySources/')){return @('対応ソース','EPPlusの固定版に対応するソース。再配布物から除外しない。')}
    if($Path.StartsWith('Adapters/')){return @('GUI保存アダプター','既存GUIとSQLiteの保存・読込・起動・出力を接続する実行時スクリプト。')}
    if($Path.StartsWith('Modules/TaskPilot.Storage/')){return @('保存モジュール','SQLite保存・移行・保護とプロバイダーの関連ファイル。')}
    if($Path.StartsWith('Modules/ImportExcel/')){return @('Excelモジュール','固定したImportExcelの実行時ファイル一式。')}
    if($Path.StartsWith('Codec/')){return @('移行コーデック','旧CSV・JSONを検査して読み取る同梱.NETソースとローダー。')}
    if($Path.StartsWith('schema/')){return @('DBスキーマ','schema 40001の初期テーブル・制約・履歴保護。')}
    if($Path-in@('BuildInfo.json','FileHashes.json','SoftwareBillOfMaterials.json')){return @('ビルド記録','元のWindowsビルドが生成した版・ハッシュ・依存情報。')}
    return @('利用ガイド','元の候補に含まれる利用説明。今回の試験ではパッケージ最上位のREADME-ja.mdを先に読む。')
}

$repo=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
$candidate=Get-TPBuildFullPath $CandidateZipPath
$output=Get-TPBuildFullPath $OutputRoot
$expectedSha=$ExpectedCandidateSha256
$binaryCommit=$ExpectedSourceCommit
Assert-TPBuildNoLinks $candidate;Assert-TPBuildNoLinks $output
if(-not[IO.File]::Exists($candidate)){throw 'The verified native Windows candidate ZIP is required.'}
if((Get-TPBuildSha $candidate)-cne$expectedSha){throw 'Candidate ZIP SHA-256 does not match the verified native build. No output was created.'}
if(Test-TPBuildPathExists $output){throw 'OutputRoot already exists; choose a NEW directory.'}
if((Test-TPBuildBelow $output $repo)-or(Test-TPBuildBelow $repo $output)-or(Test-TPBuildBelow $candidate $output)-or(Test-TPBuildBelow $output $candidate)){
    throw 'OutputRoot must be disjoint from repository and candidate ZIP.'
}
$sources=New-Object 'Collections.Generic.List[object]'
foreach($name in @('README-ja.md','TEST-CASES-ja.md','RESULT-TEMPLATE-ja.md','LOGS-ja.md','DISTRIBUTION-OPTIONS-ja.md')){
    $sources.Add([pscustomobject]@{Source=(Join-Path $repo ('docs/acceptance/'+$name));Path=$name;Group='受入手順';Purpose='Windows 10/11向けの手順・記録。未実施項目を含む。'})
}
foreach($name in @('Test-TaskPilotAcceptancePackage.ps1','Collect-TaskPilotAcceptanceLogs.ps1')){
    $source=Join-Path $PSScriptRoot $name
    Assert-TPBuildPowerShell $source
    $sources.Add([pscustomobject]@{Source=$source;Path=('Tools/'+$name);Group='試験補助';Purpose='受入用の読取検査・診断採取。アプリの起動には不要。'})
}
$sources.Add([pscustomobject]@{Source=(Get-TPBuildFullPath $WindowsTestReportPath);Path='Evidence/windows-native-results.json';Group='Server試験証跡';Purpose='Windows Server 2022のnative自動試験。Windows 10/11の合格ではない。'})
$sources.Add([pscustomobject]@{Source=(Get-TPBuildFullPath $WindowsVerificationPath);Path='Evidence/windows-native-verification.json';Group='Server試験証跡';Purpose='Windows Server 2022の未署名ビルド確認。Windows 10/11の合格ではない。'})
foreach($source in $sources){Assert-TPBuildNoLinks $source.Source;$source|Add-Member NoteProperty Sha256 (Get-TPBuildSha $source.Source)}
$proof=Get-Content -LiteralPath $WindowsVerificationPath -Raw -Encoding UTF8|ConvertFrom-Json
$test=Get-Content -LiteralPath $WindowsTestReportPath -Raw -Encoding UTF8|ConvertFrom-Json
if($proof.Commit-cne$binaryCommit-or$proof.CandidateSha256-cne$expectedSha-or$proof.NativeWindowsAutomatedGroupsPassed-ne8-or-not$proof.ExecutableGenerated-or$proof.SignatureStatus-cne'NotSigned'-or$proof.Windows10And11AcceptanceVerified-or$proof.InteractiveWinFormsVerified){throw 'Native build evidence does not match this acceptance candidate.'}
if($test.Passed-ne8-or$test.Failed-ne0-or$test.TestOnlyProvider-or$test.PowerShell-notlike'5.1.*'-or$test.ProcessBits-ne64){throw 'Native test evidence is incompatible.'}
if($PSBoundParameters.ContainsKey('WindowsTestReportPath')-and$proof.TestReport-cne[IO.Path]::GetFileName($WindowsTestReportPath)){throw 'Native verification refers to a different test report.'}

# Everything below is confined to the new developer output. Failures retain
# partial output for inspection; no pre-existing release or user data is removed.
$null=[IO.Directory]::CreateDirectory($output)
$package=Join-Path $output 'TaskPilot_Acceptance_0.4.0.1'
$application=Join-Path $package 'Application'
$null=[IO.Directory]::CreateDirectory($package)
Expand-TPAcceptanceCandidate $candidate $application $expectedSha
$appRoot=Join-Path $application 'TaskPilot'
$appFiles=@(Get-TPBuildFiles $appRoot)
if($appFiles.Count-ne136){throw 'The unchanged native candidate must contain exactly 136 files.'}
$fileHashes=Get-Content -LiteralPath (Join-Path $appRoot 'FileHashes.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($fileHashes.FormatVersion-ne1-or-not$fileHashes.SelfExcluded-or@($fileHashes.Files).Count-ne135){throw 'Unexpected native file-hash manifest.'}
$expectedFiles=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$null=$expectedFiles.Add('FileHashes.json')
foreach($entry in $fileHashes.Files){
    Assert-TPAcceptanceRelative $entry.Path
    if(-not$expectedFiles.Add($entry.Path)){throw 'Duplicate native file-hash entry.'}
    $path=Join-Path $appRoot ($entry.Path.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
    if(-not[IO.File]::Exists($path)-or([IO.FileInfo]$path).Length-ne$entry.Bytes-or(Get-TPBuildSha $path)-cne$entry.Sha256){throw ('Native candidate file verification failed: '+$entry.Path)}
}
foreach($file in $appFiles){$relative=$file.FullName.Substring($appRoot.Length+1).Replace('\','/');if(-not$expectedFiles.Contains($relative)){throw 'Unexpected file in the native candidate.'}}
$build=Get-Content -LiteralPath (Join-Path $appRoot 'BuildInfo.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($build.Version-cne'0.4.0.1'-or$build.Architecture-cne'x64'-or$build.SignatureStatus-cne'NotSigned'-or$build.StartupDownloads-or$build.SourceSha256-cne(Get-TPBuildSha (Join-Path $repo 'TaskPilot.ps1'))){throw 'Native build metadata or source hash is incompatible.'}
$sources.Add([pscustomobject]@{Source=(Join-Path $appRoot 'BuildInfo.json');Path='Evidence/windows-build-info.json';Group='Server試験証跡';Purpose='元のWindowsビルドのメタデータ。';Sha256=(Get-TPBuildSha (Join-Path $appRoot 'BuildInfo.json'))})
Assert-TPBuildWindowsX64GuiExe (Join-Path $appRoot 'TaskPilot.exe')

$inventory=New-Object 'Collections.Generic.List[object]'
foreach($file in $appFiles){
    $relative=$file.FullName.Substring($appRoot.Length+1).Replace('\','/')
    $purpose=Get-TPAcceptancePurpose $relative
    $inventory.Add([pscustomobject]@{Path=('Application/TaskPilot/'+$relative);Bytes=$file.Length;Sha256=(Get-TPBuildSha $file.FullName);Group=$purpose[0];Purpose=$purpose[1]})
}
$rows=New-Object 'Collections.Generic.List[string]'
$rows.Add("Path`tBytes`tSHA256`tGroup`tPurpose")
foreach($entry in $inventory){$rows.Add(($entry.Path+"`t"+$entry.Bytes+"`t"+$entry.Sha256+"`t"+$entry.Group+"`t"+$entry.Purpose))}
Write-TPBuildNewText (Join-Path $package 'FILE-LIST.tsv') (($rows.ToArray()-join"`r`n")+"`r`n") $true
foreach($source in $sources){
    Copy-TPBuildNewFile $source.Source (Join-Path $package ($source.Path.Replace('/',[string][IO.Path]::DirectorySeparatorChar))) $source.Sha256
}
$files=New-Object 'Collections.Generic.List[object]'
foreach($file in @(Get-TPBuildFiles $package)){
    $relative=$file.FullName.Substring($package.Length+1).Replace('\','/')
    if($relative.StartsWith('Application/')){$info=@($inventory|Where-Object {$_.Path-ceq$relative})[0];$group=$info.Group;$purpose=$info.Purpose}
    elseif($relative-ceq'FILE-LIST.tsv'){$group='ファイル一覧';$purpose='アプリ全136ファイルの役割・サイズ・SHA-256。'}
    else{$info=@($sources|Where-Object {$_.Path-ceq$relative})[0];$group=$info.Group;$purpose=$info.Purpose}
    $files.Add([pscustomobject]@{Path=$relative;Bytes=$file.Length;Sha256=(Get-TPBuildSha $file.FullName);Group=$group;Purpose=$purpose})
}
$manifest=[ordered]@{
    FormatVersion=1;Stage='Windows 10/11 acceptance candidate - NOT FOR SALE';BinaryVersion='0.4.0.1'
    CandidateZipSha256=$expectedSha;CandidateSourceCommit=$binaryCommit
    BasePullRequestURL='https://github.com/daiki0902-chiba/TaskPilot/pull/1'
    BasePullRequestHead=$BasePullRequestHead
    ServerEvidenceRunUrl=$ServerEvidenceRunUrl
    Windows10Verified=$false;Windows11Verified=$false;InteractiveGuiVerified=$false
    SelfExcluded=$true;ApplicationFiles=$appFiles.Count;Files=$files.ToArray()
}
Write-TPBuildNewText (Join-Path $package 'PACKAGE-MANIFEST.json') (ConvertTo-Json -InputObject $manifest -Depth 8) $true
$zipPath=Join-Path $output 'TaskPilot_Windows_Acceptance_0.4.0.1.zip'
$zipStream=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
$zipWriter=$null
try{
    $zipWriter=[IO.Compression.ZipArchive]::new($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true)
    foreach($file in @(Get-TPBuildFiles $package)){
        $relative=$file.FullName.Substring($package.Length+1).Replace('\','/')
        $entry=$zipWriter.CreateEntry(('TaskPilot_Acceptance_0.4.0.1/'+$relative),[IO.Compression.CompressionLevel]::Optimal)
        $inputStream=[IO.File]::OpenRead($file.FullName);$entryStream=$entry.Open()
        try{$inputStream.CopyTo($entryStream)}finally{$entryStream.Dispose();$inputStream.Dispose()}
    }
}finally{try{if($null-ne$zipWriter){$zipWriter.Dispose()};$zipStream.Flush($true)}finally{$zipStream.Dispose()}}
$zipHash=Get-TPBuildSha $zipPath
Write-TPBuildNewText ($zipPath+'.sha256') ($zipHash+'  '+[IO.Path]::GetFileName($zipPath)+"`n")
return [pscustomobject]@{PackageRoot=$package;Zip=$zipPath;Sha256=$zipHash;ApplicationFiles=$appFiles.Count;FileCount=$files.Count+1;Windows10Verified=$false;Windows11Verified=$false}
