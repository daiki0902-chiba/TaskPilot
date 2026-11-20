$ErrorActionPreference='Stop'
$source=(Join-Path $PSScriptRoot 'TaskPilot_STEP3_6F_4.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){ throw ($errors | Out-String) }
$build=(Join-Path $PSScriptRoot 'Build_TaskPilot_STEP3_6F_4.ps1')
$null=[Management.Automation.Language.Parser]::ParseFile($build,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
# Load storage functions only; never initialize the Windows UI or touch real user data.
$functions=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)
foreach($f in $functions){ Invoke-Expression $f.Extent.Text }
$Root=Join-Path ([IO.Path]::GetTempPath()) ('test_'+[guid]::NewGuid().ToString('N'))
$DataDir=Join-Path $Root 'Data';$BackupDir=Join-Path $Root 'Backup';$ExportDir=Join-Path $Root 'Export';$LogDir=Join-Path $Root 'Logs'
$TaskFile=Join-Path $DataDir 'TaskList.csv';$ArchiveFile=Join-Path $DataDir 'CompletedTask.csv';$IdFile=Join-Path $DataDir 'NextId.txt';$SettingsFile=Join-Path $Root 'Settings.json'
$Columns=@('ID','Date','Task','Priority','DueDate','Status','Memo')
$script:AutoReportsReady=$false
function Assert($ok,$message){if(-not $ok){throw $message}}
function MustFail([scriptblock]$action,$message){$failed=$false;try{& $action}catch{$failed=$true};Assert $failed $message}
Initialize-Store
Assert (@(Read-Tasks $TaskFile).Count -eq 0) 'Fresh store'
$id=Reserve-TaskId;Assert ($id -eq 1) 'First ID'
$row=[pscustomobject]@{ID=$id;Date='2026/11/15';Task='日本語,"引用"改行' + "`n" + 'タスク';Priority='高';DueDate='';Status='未着手';Memo='=1+1'}
Save-Tasks $TaskFile @($row)
Assert ((Read-Tasks $TaskFile).Task -ceq $row.Task) 'CSV round trip'
Set-Content -LiteralPath $IdFile -Value '1'
Repair-NextTaskId
Assert ((Get-Content $IdFile).Trim() -eq '2') 'Stale counter repair'
$id=Reserve-TaskId;Assert ($id -eq 2) 'Reserve second'
$id=Reserve-TaskId;Assert ($id -eq 3) 'Failed save cannot reuse ID'
Set-Content -LiteralPath (Join-Path $DataDir 'WorkPlans.json') -Value '{"1":{"EstimatedHours":8}}'
Set-Content -LiteralPath $SettingsFile -Value '{"NotifyDays":3}'
Backup-Data
$latest=Get-ChildItem $BackupDir -Directory | Sort-Object Name | Select-Object -Last 1
Test-BackupFolder $latest.FullName
Assert (Test-Path (Join-Path $latest.FullName 'Data/WorkPlans.json')) 'Metadata included'
Assert (Test-Path (Join-Path $latest.FullName 'Settings.json')) 'Settings included'
$safe=[pscustomobject]@{Text='=HYPERLINK("https://example.com")';Hours=-2.5} | ConvertTo-SafeExcelRows
Assert ($safe.Text.StartsWith("'=")) 'Formula input escaped'
Assert ($safe.Hours -eq -2.5) 'Numeric data preserved'
Set-Content -LiteralPath (Join-Path $DataDir 'WorkPlans.json') -Value '{"1":{"EstimatedHours":99}}'
Set-Content -LiteralPath (Join-Path $DataDir 'NewMetadata.json') -Value '{}'
Invoke-RestoreSnapshot $latest.FullName
Assert ((Get-Content (Join-Path $DataDir 'WorkPlans.json') -Raw).Contains(':8')) 'Full restore metadata'
Assert (-not (Test-Path (Join-Path $DataDir 'NewMetadata.json'))) 'Restore removes metadata absent from snapshot'
Assert ((Get-Content $SettingsFile -Raw).Contains('NotifyDays')) 'Restore settings'
Add-Content -LiteralPath (Join-Path $latest.FullName 'Data/WorkPlans.json') -Value 'bad'
MustFail {Test-BackupFolder $latest.FullName} 'Tamper detection'
Save-Tasks $TaskFile @($row,$row)
MustFail {Read-Tasks $TaskFile} 'Duplicate rejection'
$row.ID='bad';Save-Tasks $TaskFile @($row)
MustFail {Read-Tasks $TaskFile} 'Invalid ID rejection'
Remove-Item $TaskFile
MustFail {Initialize-Store} 'Partial store must not become empty store'
$lockPath=Join-Path $Root 'lock'
$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
try {MustFail {$other=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None');$other.Dispose()} 'Exclusive lock'} finally {$lock.Dispose()}
Remove-Item $Root -Recurse -Force
'PASS: formula escape/numeric preservation; full restore and removal of newer metadata; both parsers; fresh store; CSV Unicode/quotes/newline; stale ID repair; ID reservation; full snapshot; metadata/settings; tamper rejection; duplicate/invalid ID rejection; partial-store rejection; exclusive lock.'
