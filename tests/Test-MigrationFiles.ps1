#requires -Version 5.1
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.MigrationFiles.ps1')
function Assert-MigrationTest([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function Reject-MigrationTest([scriptblock]$Action,[string]$Message){$failed=$false;try{$null=&$Action}catch{$failed=$true};Assert-MigrationTest $failed $Message}
$root=Join-Path ([IO.Path]::GetTempPath()) ('TP_migration_files_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$source=Join-Path $root 'legacy';$null=New-Item -ItemType Directory -Path (Join-Path $source 'Data/empty') -Force
$null=New-Item -ItemType Directory -Path (Join-Path $source 'Backup/empty') -Force
[IO.File]::WriteAllBytes((Join-Path $source 'Data/one.csv'),[Text.Encoding]::UTF8.GetBytes('ID,Task'+"`r`n"+'1,日本語'))
[IO.File]::WriteAllBytes((Join-Path $source 'Settings.json'),[Text.Encoding]::UTF8.GetBytes('{}'))
[IO.File]::WriteAllBytes((Join-Path $source 'Backup/old.bin'),(New-Object byte[] 80))
$lock=$null;$link=Join-Path $source 'linked';$linked=$false
try{
 $snapshot=Get-TPMigrationSourceSnapshot -SourceRoot $source
 Assert-MigrationTest ($snapshot.Files.Count-eq2 -and $snapshot.Tree.Count-eq3) 'Selected cache vs full tree'
 Assert-MigrationTest ($snapshot.Directories -contains 'Backup/empty') 'Empty directories included'
 Assert-MigrationTest ($snapshot.Files[0].Bytes -is [byte[]]) 'Selected file retains raw byte[]'
 Assert-MigrationTest (Test-TPMigrationSourceUnchanged $snapshot) 'Unchanged snapshot'
 $firstOriginal=[byte[]]$snapshot.Files[0].Bytes.Clone()
 $snapshot.Files[0].Bytes[0]=$snapshot.Files[0].Bytes[0] -bxor 1
 Reject-MigrationTest {Test-TPMigrationSourceUnchanged $snapshot} 'Mutated cached raw evidence rejected'
 $snapshot.Files[0].Bytes=$firstOriginal
 Assert-MigrationTest (Test-TPMigrationSourceUnchanged $snapshot) 'Original evidence cache restored'
 $again=Get-TPMigrationSourceSnapshot -SourceRoot $source
 Assert-MigrationTest ($snapshot.ManifestSha256-ceq$again.ManifestSha256) 'Deterministic manifest'
 Reject-MigrationTest {Get-TPMigrationSourceSnapshot -SourceRoot $source -MaxFileBytes 1} 'Selected file byte limit'
 $lock=Enter-TPMigrationSourceLock -SourceRoot $source
 Assert-MigrationTest ($lock.Length-eq0) 'New storage lock is empty'
 Reject-MigrationTest {Enter-TPMigrationSourceLock -SourceRoot $source} 'Active app/source lock must prevent second acquisition'
 $dest=Join-Path $root 'verified'
 $copy=Copy-TPMigrationBackup -Snapshot $snapshot -DestinationRoot $dest
 Assert-MigrationTest ($copy.Verified -and $copy.ManifestSha256-ceq$snapshot.ManifestSha256) 'Verified backup hash'
 Assert-MigrationTest ([IO.Directory]::Exists((Join-Path $dest 'Data/empty'))) 'Backup empty directory'
 Assert-MigrationTest ([IO.File]::ReadAllBytes((Join-Path $dest 'Backup/old.bin')).Length-eq80) 'Nonselected file copied'
 Reject-MigrationTest {Copy-TPMigrationBackup -Snapshot $snapshot -DestinationRoot $dest} 'Existing backup refused'
 Reject-MigrationTest {Copy-TPMigrationBackup -Snapshot $snapshot -DestinationRoot (Join-Path $source 'nested')} 'Child backup refused'
 Reject-MigrationTest {Copy-TPMigrationBackup -Snapshot $snapshot -DestinationRoot $root} 'Ancestor backup refused'
 $partial=Join-Path $root 'partial-preserved'
 $originalEvidence=(Get-Command Get-TPMigrationFileEvidence).ScriptBlock
 try {
  function Get-TPMigrationFileEvidence {
   param([string]$Path,[string]$RelativePath,[bool]$CaptureBytes,[long]$MaxFileBytes)
   if($Path.StartsWith($partial,[StringComparison]::Ordinal)){throw 'Synthetic destination verification failure'}
   & $originalEvidence -Path $Path -RelativePath $RelativePath -CaptureBytes $CaptureBytes -MaxFileBytes $MaxFileBytes
  }
  Reject-MigrationTest {Copy-TPMigrationBackup -Snapshot $snapshot -DestinationRoot $partial} 'Injected backup failure'
 } finally {Set-Item -Path Function:Get-TPMigrationFileEvidence -Value $originalEvidence}
 Assert-MigrationTest ([IO.Directory]::Exists($partial)) 'Partial backup must not be deleted'
 Assert-MigrationTest (@(Get-ChildItem -LiteralPath $partial -Recurse -File).Count -gt 0) 'Partial copied evidence retained'
 Assert-MigrationTest (Test-TPMigrationSourceUnchanged $snapshot) 'Backup failure leaves source unchanged'
 [IO.File]::AppendAllText((Join-Path $source 'Backup/old.bin'),'changed')
 Reject-MigrationTest {Test-TPMigrationSourceUnchanged $snapshot} 'Change in nonselected file detected'
 [IO.File]::WriteAllBytes((Join-Path $source 'Backup/old.bin'),(New-Object byte[] 80))
 $fresh=Get-TPMigrationSourceSnapshot -SourceRoot $source
 $newEmpty=Join-Path $source 'another_empty';$null=New-Item -ItemType Directory -Path $newEmpty
 Reject-MigrationTest {Test-TPMigrationSourceUnchanged $fresh} 'New empty directory detected'
 Remove-Item -LiteralPath $newEmpty
 [IO.File]::WriteAllText((Join-Path $source 'Data/unsafe..json'),'{}')
 Reject-MigrationTest {Get-TPMigrationSourceSnapshot -SourceRoot $source} 'Unsafe metadata path refused'
 Remove-Item -LiteralPath (Join-Path $source 'Data/unsafe..json')
 try{$null=New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $source 'Data') -ErrorAction Stop;$linked=$true}catch{}
 if($linked){
  Reject-MigrationTest {Get-TPMigrationSourceSnapshot -SourceRoot $source} 'Tree link refused'
  # Delete only the known directory link, without recursion or PS5.1 prompts.
  [IO.Directory]::Delete($link,$false);$linked=$false
  Assert-MigrationTest ([IO.File]::Exists((Join-Path $source 'Data/one.csv'))) 'Link cleanup preserves target files'
 }
 'PASS: selected/raw vs full tree; deterministic hash; size limit; exclusive source lock; verified copy incl emptydirs; no overwrite/nesting; nonselected mutation and emptydir detection; unsafe paths/links refused.'
}finally{
 if($null-ne$lock){$lock.Dispose()}
 # If an assertion failed, remove the still-owned link before recursive cleanup.
 # A link deletion failure retains the fixture instead of traversing its target.
 if($linked){[IO.Directory]::Delete($link,$false);$linked=$false}
 Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
