#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RuntimeAssembly,
    [Parameter(Mandatory=$true)][string]$DependencyRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'This suite requires native x64 Windows PowerShell Desktop 5.1. No Windows result was produced.'}
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'OutputRoot must be an existing developer results directory.'}
$suiteRoot=Join-Path $output ('IsolatedMode_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($suiteRoot)
$profile=Join-Path $suiteRoot 'SyntheticLocalAppData'
$null=[IO.Directory]::CreateDirectory($profile)
$modulePath=Join-Path $project 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
$assembly=Get-TPBuildFullPath $RuntimeAssembly
Assert-TPBuildNoLinks $assembly
$null=[Reflection.Assembly]::LoadFrom($assembly)
if($null-eq('TaskPilot.Runtime.Sandbox'-as[type])){throw 'The supplied assembly does not contain the isolated runtime.'}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:isoChecks=0
$script:isoCases=New-Object 'Collections.Generic.List[object]'
$script:isoSkipped=New-Object 'Collections.Generic.List[string]'
$script:isoReparseAttempts=New-Object 'Collections.Generic.List[object]'
$script:isoSandbox=$null
$script:isoActualExcel=$false
$script:isoNormalUnchanged=$false
$script:isoActiveId=$null
$script:isoPrimaryId=[guid]::NewGuid().ToString('N')
$script:isoSavedTaskId=0
$script:isoBackup=$null
$script:isoNormalChild=$null
$script:isoEnv=@{}
foreach($name in @('TEMP','TMP','SQLITE_TMPDIR','PSModuleAnalysisCachePath')){$script:isoEnv[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
function Assert-Isolated([bool]$Condition,[string]$Message){$script:isoChecks++;if(-not$Condition){throw $Message}}
function Reject-Isolated([scriptblock]$Action,[string]$Message){
    $caught=$null;try{$null=&$Action}catch{$caught=$_}
    Assert-Isolated ($null-ne$caught) $Message
    return $caught
}
function Case-Isolated([string]$Id,[string]$Name,[scriptblock]$Action){
    try{&$Action;$script:isoCases.Add([pscustomobject]@{Id=$Id;Name=$Name;Passed=$true;Error=$null});Write-Host ('PASS: '+$Id+' '+$Name)}
    catch{$script:isoCases.Add([pscustomobject]@{Id=$Id;Name=$Name;Passed=$false;Error=$_.Exception.Message;ErrorDetail=$_.Exception.ToString();Stack=$_.ScriptStackTrace});Write-Host ('FAIL: '+$Id+' '+$Name+' : '+$_.Exception.Message)}
}
function Get-IsolatedHash([string]$Path){
    $read=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($read))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$read.Dispose()}
}
function Get-IsolatedNormalSnapshot {
    # Only explicitly-created synthetic normal paths are inspected by this
    # harness. The app/runtime under test never receives read permission by API.
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs','TaskPilot4LegacyBackups','TaskPilot.storage.lock','TaskPilot4.storage.lock')){
        $path=Join-Path $profile $leaf
        if([IO.File]::Exists($path)){$lines.Add('F '+$leaf+' '+(Get-IsolatedHash $path));continue}
        if(-not[IO.Directory]::Exists($path)){throw ('Synthetic normal fixture disappeared: '+$leaf)}
        $pending=New-Object 'Collections.Generic.Stack[IO.DirectoryInfo]';$pending.Push([IO.DirectoryInfo]$path)
        while($pending.Count){
            $directory=$pending.Pop();$relative=$directory.FullName.Substring($profile.Length+1)
            $lines.Add('D '+$relative)
            foreach($entry in $directory.GetFileSystemInfos()){
                if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Normal synthetic fixture unexpectedly contains a reparse point.'}
                if(($entry.Attributes-band[IO.FileAttributes]::Directory)-ne0){$pending.Push([IO.DirectoryInfo]$entry)}else{$lines.Add('F '+$entry.FullName.Substring($profile.Length+1)+' '+(Get-IsolatedHash $entry.FullName))}
            }
        }
    }
    $array=$lines.ToArray();[Array]::Sort($array,[StringComparer]::Ordinal)
    return $array-join"`n"
}
function Close-IsolatedContext {
    try{if(Get-Command Close-TPGuiApplication -ErrorAction SilentlyContinue){Close-TPGuiApplication}}catch{Write-Host ('Fixture close detail: '+$_.Exception.Message)}
    if($null-ne$script:isoSandbox){$script:isoSandbox.Dispose();$script:isoSandbox=$null}
    $script:TPRuntimeContext=$null;$script:TPRuntimeSandbox=$null
    $script:TPGuiStore=$null;$script:TPStorageModule=$null;$script:TPAppLock=$null;$script:TPLegacyLock=$null
    Remove-Module TaskPilot.Storage -Force -ErrorAction SilentlyContinue
}
function Set-IsolatedContext([string]$Id,[switch]$NoStartup){
    Close-IsolatedContext
    $script:isoSandbox=[TaskPilot.Runtime.Sandbox]::Create($profile,$Id)
    $script:isoActiveId=$Id
    $script:TPRuntimeSandbox=$script:isoSandbox
    $script:TPRuntimeContext=[pscustomobject]@{IsTestMode=$true;TestMode=$true;EnvironmentId=$Id;ProfileRoot=$profile;Root=$script:isoSandbox.Root;DataDir=$script:isoSandbox.Data;ExportDir=$script:isoSandbox.Export;BackupDir=$script:isoSandbox.Backup;LogDir=$script:isoSandbox.Logs;TempDir=$script:isoSandbox.Temp;InputDir=$script:isoSandbox.Input;LockPath=$script:isoSandbox.LockPath;Sandbox=$script:isoSandbox}
    $script:InstallRoot=$project;$script:LocalAppData=$profile;$script:LegacyRoot=Join-Path $profile 'TaskPilot'
    $script:Root=$script:isoSandbox.Root;$script:DataDir=$script:isoSandbox.Data
    $script:ExportDir=$script:isoSandbox.Export;$script:BackupDir=$script:isoSandbox.Backup;$script:LogDir=$script:isoSandbox.Logs
    $script:TaskFile=Join-Path $script:DataDir 'TaskList.csv';$script:ArchiveFile=Join-Path $script:DataDir 'CompletedTask.csv'
    $script:SettingsFile=Join-Path $script:Root 'Settings.json';$script:HolidayFile=Join-Path $script:DataDir 'JapaneseHolidays.json'
    $script:AutoReportsReady=$false;$script:ReportsNeedRefresh=$true;$script:ReportError=''
    $env:TEMP=$script:isoSandbox.Temp;$env:TMP=$script:isoSandbox.Temp;$env:SQLITE_TMPDIR=$script:isoSandbox.Temp
    $env:PSModuleAnalysisCachePath=Join-Path $script:isoSandbox.Temp 'PowerShellModuleAnalysisCache'
    if(-not('TaskPilot.Migration.Codec'-as[type])){
        $applicationDirectory=Split-Path -Parent (Split-Path -Parent $assembly)
        $codecAssembly=Join-Path $applicationDirectory 'Codec/TaskPilotMigrationCodec.dll'
        $loadedCodec=[Reflection.Assembly]::LoadFrom($codecAssembly)
        $null=$loadedCodec.GetType('TaskPilot.Migration.Codec',$true)
    }
    if(-not$NoStartup){Initialize-TPGuiApplication}
}
function New-IsolatedTask([string]$Title,[string]$Status='対応中',[decimal]$Hours=5.01){
    $day=(Get-Date).ToString('yyyy/MM/dd',[cultureinfo]::InvariantCulture)
    return Save-TPGuiTaskAggregate $null ([pscustomobject]@{Task=$Title;Priority='高';Status=$Status;DueDate=$day;Memo='=1+1';WorkStartDate=$day;EstimatedHours=$Hours;PlannedDate=$day})
}
function Load-IsolatedAlgorithms {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'TaskPilot.ps1'),[ref]$tokens,[ref]$errors)
    Assert-Isolated ($errors.Count-eq0) 'Generated entry point must parse before extracting real algorithms.'
    $names=@('Get-ValidDueDate','Get-LatestRecurringDate','Get-BusinessOccurrence','Get-NextRecurringDate','Get-PlannedDate','Get-WorkPlan','Get-LoggedHours','Get-MonthLoggedHours','Get-DayCapacity','Get-MonthCapacity','Get-TaskMonthAllocation','Get-RemainingMonthCapacity','Get-MonthPlanTotal','ConvertTo-SafeExcelRows','Get-TaskExcelRows','Add-ExtendedExcelSheets','Get-MonthlySnapshotData','Add-AnalyticsExcelSheets','Write-CompletedReport','Write-ExcelReport')
    foreach($name in $names){
        $nodes=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true))
        Assert-Isolated ($nodes.Count-eq1) ('Expected actual application function: '+$name)
        # Install only definitions. The entry point and Application.Run are never invoked.
        $definition=$nodes[0]
        $body=$definition.Body.Extent.Text
        $body=$body.Substring(1,$body.Length-2)
        if($null-ne$definition.Parameters-and$definition.Parameters.Count-gt0){$body='param('+((@($definition.Parameters|ForEach-Object {$_.Extent.Text}))-join',')+")`n"+$body}
        Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body))
    }
}
function Test-IsolatedWorkbook([string]$Path,[int]$MinimumCharts,[string[]]$RequiredSheets){
    Assert-Isolated ($Path.StartsWith($script:isoSandbox.Export+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Workbook must stay inside the current test Export directory.'
    $bytes=$script:isoSandbox.ReadAllBytes($Path)
    Assert-Isolated ($bytes.Length-gt1000) 'An Excel report must contain a real workbook, not DTO output.'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$false)
    try{
        $workbook=$zip.GetEntry('xl/workbook.xml');Assert-Isolated ($null-ne$workbook) 'Workbook XML is absent.'
        $reader=[IO.StreamReader]::new($workbook.Open());try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
        $manager=New-Object Xml.XmlNamespaceManager $xml.NameTable;$manager.AddNamespace('s','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        $sheets=@($xml.SelectNodes('//s:sheets/s:sheet',$manager)|ForEach-Object {$_.GetAttribute('name')})
        foreach($sheet in $RequiredSheets){Assert-Isolated ($sheets-ccontains$sheet) ('Required worksheet missing: '+$sheet)}
        $charts=@($zip.Entries|Where-Object {$_.FullName-match'^xl/charts/chart[0-9]+\.xml$'})
        Assert-Isolated ($charts.Count-ge$MinimumCharts) ('Too few actual chart XML entries in '+[IO.Path]::GetFileName($Path))
        foreach($chart in $charts){
            $reader=[IO.StreamReader]::new($chart.Open());try{[xml]$chartXml=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $chartManager=New-Object Xml.XmlNamespaceManager $chartXml.NameTable;$chartManager.AddNamespace('c','http://schemas.openxmlformats.org/drawingml/2006/chart')
            Assert-Isolated ($chartXml.SelectNodes('//c:ser',$chartManager).Count-ge1) 'A chart must contain an actual series.'
        }
    }finally{$zip.Dispose();$stream.Dispose()}
}
function Initialize-IsolatedReparseProbe {
    if($null-ne('TaskPilot.IsolationTests.ReparseAttack'-as[type])){return}
    # Compilation belongs to the developer harness, not the protected app.
    # Give the test-only compiler its own new synthetic TEMP because the app's
    # directory attribute policy intentionally rejects compiler directory I/O.
    $probeCompilerDirectory=Join-Path $suiteRoot ('ProbeCompiler_'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($probeCompilerDirectory)
    $probeCompilerEnvironment=@{}
    foreach($probeVariable in @('TEMP','TMP')){$probeCompilerEnvironment[$probeVariable]=[Environment]::GetEnvironmentVariable($probeVariable,'Process')}
    try{
    $env:TEMP=$probeCompilerDirectory;$env:TMP=$probeCompilerDirectory
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace TaskPilot.IsolationTests {
    public sealed class JunctionAttempt {
        public bool HandleOpened, ReparseSet;
        public int Win32Error;
    }
    public static class ReparseAttack {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
        public static JunctionAttempt AttemptSetJunction(string fixtureRoot, string existingEmptyDirectory, string targetDirectory, uint access) {
            if(Environment.OSVersion.Platform!=PlatformID.Win32NT) throw new PlatformNotSupportedException("Native Windows is required.");
            string root=Path.GetFullPath(fixtureRoot).TrimEnd('\\')+"\\";
            string source=Path.GetFullPath(existingEmptyDirectory).TrimEnd('\\');
            string target=Path.GetFullPath(targetDirectory).TrimEnd('\\');
            if(!source.StartsWith(root,StringComparison.OrdinalIgnoreCase)||!target.StartsWith(root,StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Attack paths must stay inside the newly created synthetic fixture.");
            if(!Directory.Exists(source)||!Directory.Exists(target)) throw new DirectoryNotFoundException();
            if(new DirectoryInfo(source).GetFileSystemInfos().Length!=0) throw new IOException("Attack source must be empty.");
            JunctionAttempt result=new JunctionAttempt();
            using(SafeFileHandle handle=CreateFileW(source,access,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                if(handle.IsInvalid) { result.Win32Error=Marshal.GetLastWin32Error(); return result; }
                result.HandleOpened=true;
                byte[] substitute=Encoding.Unicode.GetBytes("\\??\\"+target), print=Encoding.Unicode.GetBytes(target);
                byte[] buffer=new byte[16+substitute.Length+2+print.Length+2];
                Array.Copy(BitConverter.GetBytes(0xA0000003u),0,buffer,0,4);
                Array.Copy(BitConverter.GetBytes((ushort)(buffer.Length-8)),0,buffer,4,2);
                Array.Copy(BitConverter.GetBytes((ushort)substitute.Length),0,buffer,10,2);
                Array.Copy(BitConverter.GetBytes((ushort)(substitute.Length+2)),0,buffer,12,2);
                Array.Copy(BitConverter.GetBytes((ushort)print.Length),0,buffer,14,2);
                Array.Copy(substitute,0,buffer,16,substitute.Length);
                Array.Copy(print,0,buffer,16+substitute.Length+2,print.Length);
                uint returned;
                result.ReparseSet=DeviceIoControl(handle,0x000900A4,buffer,(uint)buffer.Length,IntPtr.Zero,0,out returned,IntPtr.Zero);
                result.Win32Error=result.ReparseSet?0:Marshal.GetLastWin32Error();
                return result;
            }
        }
    }
}
'@ -ErrorAction Stop
    }finally{
        foreach($probeVariable in $probeCompilerEnvironment.Keys){[Environment]::SetEnvironmentVariable($probeVariable,$probeCompilerEnvironment[$probeVariable],'Process')}
    }
}

$normalSnapshot=$null
$normalDb=Join-Path $profile 'TaskPilot4/TaskPilot.db'
$holderStop=Join-Path $suiteRoot 'normal-holder.stop'
try{
    # These are newly-created sentinels, not the current Windows user's data.
    foreach($relative in @('TaskPilot/Data','TaskPilot/Backup/empty','TaskPilot4/Backup/empty','TaskPilot4/Export','TaskPilot4Logs','TaskPilot4LegacyBackups/LegacyBackup_synthetic/empty')){$null=[IO.Directory]::CreateDirectory((Join-Path $profile $relative))}
    foreach($entry in @(@('TaskPilot/Data/TaskList.csv','ID,Date,Task,Priority,DueDate,Status,Memo'+"`r`n"+'1,2026/11/01,NORMAL-LEGACY-DO-NOT-IMPORT,高,,未着手,sentinel'),@('TaskPilot/Settings.json','{"NotifyDays":29,"Marker":"NORMAL-LEGACY"}'),@('TaskPilot/Backup/original.bin','NORMAL BACKUP'),@('TaskPilot4/Backup/original.bin','NORMAL SQLITE BACKUP'),@('TaskPilot4/Export/normal.xlsx','NORMAL EXPORT SENTINEL'),@('TaskPilot4Logs/actions.log','NORMAL LOG'),@('TaskPilot4LegacyBackups/LegacyBackup_synthetic/retained.bin','NORMAL COMPLETE BACKUP'),@('TaskPilot.storage.lock',''),@('TaskPilot4.storage.lock',''))){[IO.File]::WriteAllText((Join-Path $profile $entry[0]),$entry[1],[Text.UTF8Encoding]::new($true))}
    $normalModule=Import-Module $modulePath -Force -PassThru
    $null=New-TaskPilotDatabase -DatabasePath $normalDb
    $normalStore=Open-TaskPilotStore -DatabasePath $normalDb
    try{$null=Add-TaskPilotTask -Store $normalStore -Title 'NORMAL-SQLITE-DO-NOT-IMPORT' -RegisteredOn '2026-11-01'}finally{Close-TaskPilotStore $normalStore}
    Remove-Module TaskPilot.Storage -Force
    $normalSnapshot=Get-IsolatedNormalSnapshot
    Write-TPBuildNewText (Join-Path $suiteRoot 'NormalFixtureBefore.txt') $normalSnapshot

    # A second process holds the ordinary DB and both ordinary cooperative locks
    # throughout independent-mode operations. It receives only fixture paths.
    $holder=Join-Path $suiteRoot 'Hold-SyntheticNormal.ps1'
    $holderText=@'
param([string]$ModulePath,[string]$DatabasePath,[string]$ProfilePath,[string]$ReadyPath,[string]$StopPath)
$ErrorActionPreference='Stop'
$null=Import-Module $ModulePath -Force
$store=$null;$first=$null;$second=$null
try{
 $first=[IO.File]::Open((Join-Path $ProfilePath 'TaskPilot.storage.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $second=[IO.File]::Open((Join-Path $ProfilePath 'TaskPilot4.storage.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $store=Open-TaskPilotStore -DatabasePath $DatabasePath
 if(@(Get-TaskPilotTask -Store $store)[0].title-cne'NORMAL-SQLITE-DO-NOT-IMPORT'){throw 'Synthetic normal fixture changed before the concurrency test.'}
 [IO.File]::WriteAllText($ReadyPath,'ready')
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while(-not[IO.File]::Exists($StopPath)-and$watch.Elapsed.TotalSeconds-lt600){Start-Sleep -Milliseconds 100}
}finally{if($null-ne$store){Close-TaskPilotStore $store};if($null-ne$second){$second.Dispose()};if($null-ne$first){$first.Dispose()}}
'@
    Write-TPBuildNewText $holder $holderText $true
    $ready=Join-Path $suiteRoot 'normal-holder.ready'
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardError=$true;$start.RedirectStandardOutput=$true
    $holderArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$holder,'-ModulePath',$modulePath,'-DatabasePath',$normalDb,'-ProfilePath',$profile,'-ReadyPath',$ready,'-StopPath',$holderStop)
    $start.Arguments=(@($holderArgs|ForEach-Object {'"'+([string]$_).Replace('"','\"')+'"'})-join' ')
    $script:isoNormalChild=[Diagnostics.Process]::Start($start)
    $wait=[Diagnostics.Stopwatch]::StartNew()
    while(-not[IO.File]::Exists($ready)-and-not$script:isoNormalChild.HasExited-and$wait.Elapsed.TotalSeconds-lt30){Start-Sleep -Milliseconds 100}
    if(-not[IO.File]::Exists($ready)){if($script:isoNormalChild.HasExited){throw ('Normal fixture holder failed: '+$script:isoNormalChild.StandardError.ReadToEnd())};throw 'Normal fixture holder did not signal readiness.'}

    . (Join-Path $project 'Runtime/TaskPilot.Runtime.ps1')
    foreach($name in @('Common','Tasks','Domains','Operations','Startup','Isolation')){. (Join-Path $project ('Adapters/TaskPilot.Gui'+$name+'.ps1'))}
    Load-IsolatedAlgorithms

    Case-Isolated 'I01' 'Existing normal data and locks do not prevent independent startup' {
        Set-IsolatedContext $script:isoPrimaryId
        Assert-Isolated (-not$script:isoNormalChild.HasExited) 'Normal fixture must remain running concurrently.'
        Assert-Isolated ($script:TPGuiStore.Path-ceq(Join-Path $script:isoSandbox.Root 'TaskPilot.db')) 'SQLite must use this test environment only.'
        Assert-Isolated (@(Read-Tasks $TaskFile).Count-eq0) 'Normal tasks or legacy data leaked into the new test database.'
        Assert-Isolated ($null-eq$script:TPLegacyLock) 'Independent startup must not acquire the normal legacy lock.'
        Assert-Isolated ([IO.File]::Exists($script:isoSandbox.LockPath)) 'The test environment needs its own lock.'
        Assert-Isolated ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM import_batches' -Mode Scalar)-eq0) 'Independent startup must not import legacy data.'
        $description=[string](Invoke-TPGuiSql 'SELECT description FROM schema_migrations WHERE version=40001' -Mode Scalar)
        Assert-Isolated ($description-ceq('TaskPilot independent test environment:'+$script:isoPrimaryId)) 'The database must carry the immutable environment scope.'
    }
    Case-Isolated 'I02' 'Actual controls mark the mode without running the application loop' {
        $window=New-Object System.Windows.Forms.Form
        try{$window.Text='TaskPilot';Set-TPGuiTestModeVisuals $window
            Assert-Isolated ($window.Text.StartsWith('[TEST MODE]',[StringComparison]::Ordinal)) 'The title must show TEST MODE.'
            $strip=$window.Controls['TaskPilotTestModeStatus']
            Assert-Isolated ($null-ne$strip-and$strip.Items.Count-eq1) 'The test status strip must exist.'
            Assert-Isolated ($strip.Items[0].Text.Contains('テスト環境')-and$strip.Items[0].Text.Contains($script:isoPrimaryId)) 'The visible test label must identify the environment.'
        }finally{$window.Dispose()}
    }
    Case-Isolated 'I03' 'Task addition editing status and soft deletion stay in the test database' {
        $id=New-IsolatedTask 'UAT-TEST-日本語 ''quoted''';$script:isoSavedTaskId=$id
        $task=@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$id})[0]
        Assert-Isolated ($task.Task-cne'NORMAL-SQLITE-DO-NOT-IMPORT') 'The test row must not reuse a normal task.'
        $value=[pscustomobject]@{Task='UAT-TEST-編集済み';Priority='中';Status='対応中';DueDate=$task.DueDate;Memo='=1+1';PlannedDate=$task.DueDate;WorkStartDate=$task.DueDate;EstimatedHours=[decimal]'5.01'}
        $null=Save-TPGuiTaskAggregate $task $value
        $fresh=@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$id})[0]
        Assert-Isolated ($fresh.Task-ceq'UAT-TEST-編集済み'-and(Read-WorkPlans)[[string]$id].EstimatedHours-eq[decimal]'5.01') 'Task title and exact hours must survive an edit.'
        $delete=New-IsolatedTask 'UAT-TEST-delete' '未着手' 0
        $target=@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$delete})[0]
        $null=Remove-TaskPilotTask -Store $script:TPGuiStore -TaskId $delete -ExpectedVersion $target.TPRowVersion
        Assert-Isolated (@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$delete}).Count-eq0) 'Deleted test task remains visible.'
    }
    Case-Isolated 'I04' 'Subtasks progress work logs and completion actual remain separate' {
        $id=$script:isoSavedTaskId
        $null=@(Read-Subtasks)
        Save-Subtasks @([pscustomobject]@{Id='test-child-one';ParentId=[string]$id;Title='UAT 調査';Done=$true};[pscustomobject]@{Id='test-child-two';ParentId=[string]$id;Title='UAT 作成';Done=$false}) -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'subtasks')
        $children=@(Read-Subtasks);Assert-Isolated ($children.Count-eq2-and@($children|Where-Object {$_.Done}).Count-eq1) 'Subtask progress must be one of two.'
        $null=@(Read-WorkLogs);$day=(Get-Date).ToString('yyyy/MM/dd')
        Save-WorkLogs @([pscustomobject]@{EntryId='test-log-a';TaskId=[string]$id;WorkDate=$day;Hours=[decimal]'0.75';Memo='UAT first'};[pscustomobject]@{EntryId='test-log-b';TaskId=[string]$id;WorkDate=$day;Hours=[decimal]'0.26';Memo='UAT second'}) -ExpectedSnapshotToken (Get-TPGuiLastChildSnapshotToken 'work_logs')
        Assert-Isolated ((Get-LoggedHours ([string]$id))-eq[decimal]'1.01') 'Daily progress must preserve hundredths of an hour.'
        $completed=New-IsolatedTask 'UAT-TEST-completed' '完了' 2
        $row=@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$completed})[0]
        Save-ActualHours ([string]$completed) (Get-Date).Date ([decimal]'1.25') $row.Task -ExpectedVersion $row.TPRowVersion
        Assert-Isolated ((Read-ActualHours)[[string]$completed].ActualHours-eq[decimal]'1.25') 'Completion actual must remain separate from work logs.'
        Assert-Isolated (@(Read-WorkLogs).Count-eq2) 'Completion entry must not create duplicate daily progress.'
    }
    Case-Isolated 'I05' 'Settings notifications calendars recurrence and monthly values use only test state' {
        Load-AppSettings
        Assert-Isolated ($script:AppSettings.NotifyDays-ne29) 'Normal legacy settings leaked into test mode.'
        $script:AppSettings.NotifyOnStartup=$false;$script:AppSettings.NotifyDays=7;Save-AppSettings
        Load-NotificationData;$script:NotificationSeen['test-only-alert']=$true;Save-NotificationData
        Assert-Isolated ($script:NotificationSeen.ContainsKey('test-only-alert')) 'Test notification state did not persist.'
        $cfg=Read-CapacitySettings;$cfg.Weekdays=@(0,1,2,3,4,5,6);$cfg.DailyHours=[decimal]'8.01';$cfg.WorkOnHolidays=$true;Save-CapacitySettings $cfg
        Assert-Isolated ((Read-CapacitySettings).DailyHours-eq[decimal]'8.01') 'Calendar exact hours did not persist.'
        $rules=@(Read-RecurringRules)
        $rule=[pscustomobject]@{Id='test-daily';Name='UAT-TEST-daily';Type='毎日';Weekday='月';Day=1;Nth=1;StartDate=(Get-Date).ToString('yyyy-MM-dd');Enabled=$true;Note='test only'}
        Save-RecurringRules @($rules+@($rule)) -OriginalRules $rules
        Assert-Isolated ((Invoke-RecurringGeneration)-eq1-and(Invoke-RecurringGeneration)-eq0) 'Recurring generation must create exactly one occurrence, not duplicate it.'
        $month=(Get-Date -Day 1).Date.AddMonths(-1).ToString('yyyy/MM');$map=Read-MonthlySnapshots
        $map[$month]=[pscustomobject]@{Month=$month;CapacityHours=[decimal]160;Workdays=[long]20;PlannedHours=[decimal]8;PlannedRate=[decimal]5;LoggedHours=[decimal]'1.01';CompletedActualHours=[decimal]'1.25';CompletedCount=[long]1;DifferenceHours=[decimal]'-6.75';FinalizedAt=[datetime]::UtcNow.ToString('o');Source='UAT fixture';Revision=[long]1}
        Write-MonthlySnapshots $map -ChangedMonth $month -ExpectedRevision 0 -Reason 'UAT initial snapshot'
        $task=@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$script:isoSavedTaskId})[0]
        $null=Set-TaskPilotTask -Store $script:TPGuiStore -TaskId $task.ID -ExpectedVersion $task.TPRowVersion -Memo 'UAT after monthly finalization'
        Assert-Isolated ((Read-MonthlySnapshots)[$month].PlannedHours-eq8-and(Read-MonthlySnapshots)[$month].Revision-eq1) 'Current task edits changed the saved monthly snapshot.'
    }
    Case-Isolated 'I06' 'Real Excel files and chart XML are produced inside test Export' {
        $excelModule=Join-Path (Get-TPBuildFullPath $DependencyRoot) 'ImportExcel/7.8.10/ImportExcel.psd1'
        Assert-Isolated ([IO.File]::Exists($excelModule)) 'Pinned ImportExcel is missing.'
        Import-Module $excelModule -ErrorAction Stop
        Publish-ExcelReport 'TaskList.xlsx' {param($path) Write-ExcelReport $false $path}
        Publish-ExcelReport 'CompletedTask.xlsx' {param($path) Write-CompletedReport $path}
        Publish-ExcelReport 'Dashboard.xlsx' {param($path) Write-ExcelReport $true $path}
        Test-IsolatedWorkbook (Join-Path $ExportDir 'TaskList.xlsx') 3 @('TaskList','作業記録','サブタスク','月間稼働','月別分析','タスク工数比較')
        Test-IsolatedWorkbook (Join-Path $ExportDir 'CompletedTask.xlsx') 0 @('CompletedTask')
        Test-IsolatedWorkbook (Join-Path $ExportDir 'Dashboard.xlsx') 2 @('Dashboard','TaskList')
        $script:isoActualExcel=$true
    }
    Case-Isolated 'I07' 'Backup restore and restart preserve only this test environment' {
        $backup=Join-Path $BackupDir 'verified_test_backup.db'
        $saved=New-TaskPilotDatabaseBackup -Store $script:TPGuiStore -DestinationPath $backup
        Assert-Isolated $saved.Verified 'A test backup must be fully verified.'
        $script:isoBackup=$backup
        $restored=Join-Path $Root 'TaskPilot_restored_uat.db'
        $result=Restore-TaskPilotDatabase -BackupPath $backup -DatabasePath $restored
        Assert-Isolated $result.Verified 'A test restore must create a new verified database.'
        Set-TPGuiActiveDatabasePath -StoreRoot $Root -DatabasePath $restored
        $before=@(Read-Tasks $TaskFile).Count
        Set-IsolatedContext $script:isoPrimaryId
        Assert-Isolated ($script:TPGuiStore.Path-ceq$restored-and@(Read-Tasks $TaskFile).Count-eq$before) 'Restart did not select the restored test state.'
        Load-AppSettings;Load-NotificationData
        Assert-Isolated ($script:AppSettings.NotifyDays-eq7-and$script:NotificationSeen.ContainsKey('test-only-alert')) 'Settings or notifications were lost on restart.'
        Assert-Isolated ([IO.File]::Exists($backup)-and[IO.File]::Exists((Join-Path $Root 'TaskPilot.db'))) 'Restore removed the previous test database or backup.'
    }
    Case-Isolated 'I08' 'Another environment ID starts empty while prior test state remains' {
        $newId=[guid]::NewGuid().ToString('N');Set-IsolatedContext $newId
        Assert-Isolated (@(Read-Tasks $TaskFile).Count-eq0) 'Another test environment inherited task state.'
        Set-IsolatedContext $script:isoPrimaryId
        Assert-Isolated (@(Read-Tasks $TaskFile|Where-Object {$_.ID-eq$script:isoSavedTaskId}).Count-eq1) 'Prior environment state was lost after switching processes/contexts in the harness.'
    }
    Case-Isolated 'I09' 'Legacy APIs are disabled without inspecting normal sources' {
        $null=Reject-Isolated {Test-TaskPilotLegacyData -SourceRoot (Join-Path $profile 'TaskPilot')} 'Test mode allowed legacy inspection.'
        $null=Reject-Isolated {Import-TaskPilotLegacyData -SourceRoot (Join-Path $profile 'TaskPilot') -DatabasePath (Join-Path $Root 'forbidden.db') -BackupRoot (Join-Path $Root 'forbidden-backup') -Apply} 'Test mode allowed legacy migration.'
        Assert-Isolated ([long](Invoke-TPGuiSql 'SELECT COUNT(*) FROM import_batches' -Mode Scalar)-eq0) 'A disabled migration created an import record.'
    }

    # Every unsafe path test receives a new context. A boundary violation poisons
    # its context intentionally, so it must not be reused by subsequent cases.
    foreach($unsafeSpec in @(@('I10','absolute normal DB',$normalDb),@('I11','relative traversal','..\TaskPilot4\TaskPilot.db'),@('I12','UNC share','\\localhost\C$\TaskPilot.db'),@('I13','environment-variable path','%LOCALAPPDATA%\TaskPilot4\TaskPilot.db'))){
        $caseId=$unsafeSpec[0];$label=$unsafeSpec[1];$unsafePath=$unsafeSpec[2]
        Case-Isolated $caseId ('Unsafe '+$label+' is rejected and stops further writes') {
            Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
            $null=Reject-Isolated {$script:isoSandbox.ReadAllBytes($unsafePath)} ('Unsafe path was read: '+$label)
            Assert-Isolated $script:isoSandbox.IsFaulted 'A boundary escape must poison the test context.'
            $null=Reject-Isolated {$script:isoSandbox.AppendText((Join-Path $script:isoSandbox.Logs 'after-fault.log'),'must not write')} 'A poisoned test context continued writing.'
        }
    }
    Case-Isolated 'I14' 'Directory handles prevent root and Export path replacement' {
        Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
        $null=Reject-Isolated {[IO.Directory]::Move($script:isoSandbox.Root,$script:isoSandbox.Root+'_swapped')} 'An active test root could be renamed.'
        $null=Reject-Isolated {[IO.Directory]::Move($script:isoSandbox.Export,$script:isoSandbox.Export+'_swapped')} 'An active Export directory could be replaced.'
        Assert-Isolated ([IO.Directory]::Exists($script:isoSandbox.Root)-and[IO.Directory]::Exists($script:isoSandbox.Export)) 'Pinned directories disappeared.'
    }
    Case-Isolated 'I26' 'A file pin prevents replacement before any SQLite connection opens' {
        Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
        $pinnedFile=Join-Path $script:isoSandbox.Input 'pin-control.csv'
        $movedFile=Join-Path $script:isoSandbox.Input 'pin-control-moved.csv'
        $script:isoSandbox.WriteNew($pinnedFile,[Text.Encoding]::UTF8.GetBytes('synthetic pin control'))
        $script:isoSandbox.PinExistingFile($pinnedFile)
        $null=Reject-Isolated {[IO.File]::Move($pinnedFile,$movedFile)} 'A pinned file could be renamed before native SQLite opened it.'
        Assert-Isolated ($script:isoSandbox.ReadAllText($pinnedFile)-ceq'synthetic pin control') 'The pinned file content changed.'
        $script:isoSandbox.ReleaseFile($pinnedFile)
        [IO.File]::Move($pinnedFile,$movedFile)
        Assert-Isolated ($script:isoSandbox.ReadAllText($movedFile)-ceq'synthetic pin control') 'The unpinned positive control could not be renamed.'
    }
    Case-Isolated 'I25' 'Pinned empty directories reject in-place reparse mutation for every access variant' {
        Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
        Initialize-IsolatedReparseProbe
        $target=Join-Path $suiteRoot ('FSCTLTarget_'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($target)
        $pinned=[string]$script:isoSandbox.Export
        try{
            foreach($access in @(@('GenericWrite',[uint32]1073741824),@('WriteData',[uint32]2),@('WriteAttributes',[uint32]256),@('ReadAttributes',[uint32]128),@('Zero',[uint32]0))){
                # A fresh unpinned control for each access distinguishes native
                # access checks from the runtime's sharing restriction.
                $control=Join-Path $suiteRoot ('FSCTLControl_'+[guid]::NewGuid().ToString('N'))
                $null=[IO.Directory]::CreateDirectory($control)
                try{
                    $attempt=[TaskPilot.IsolationTests.ReparseAttack]::AttemptSetJunction($suiteRoot,$control,$target,$access[1])
                    $script:isoReparseAttempts.Add([pscustomobject]@{Pinned=$false;Access=$access[0];HandleOpened=$attempt.HandleOpened;ReparseSet=$attempt.ReparseSet;Win32Error=$attempt.Win32Error})
                    if($access[0]-ceq'GenericWrite'){Assert-Isolated $attempt.ReparseSet 'The native junction positive control failed; directory protection is unverified.'}
                }finally{if([IO.Directory]::Exists($control)){[IO.Directory]::Delete($control,$false)}}
                $attempt=[TaskPilot.IsolationTests.ReparseAttack]::AttemptSetJunction($suiteRoot,$pinned,$target,$access[1])
                $script:isoReparseAttempts.Add([pscustomobject]@{Pinned=$true;Access=$access[0];HandleOpened=$attempt.HandleOpened;ReparseSet=$attempt.ReparseSet;Win32Error=$attempt.Win32Error})
                Assert-Isolated (-not$attempt.ReparseSet) ('A pinned empty directory became a junction using '+$access[0]+'. Do not publish this runtime.')
                if($access[0]-in@('GenericWrite','WriteAttributes')){Assert-Isolated (-not$attempt.HandleOpened-and$attempt.Win32Error-in@(5,32)) 'The protected directory did not reject a writable attribute handle.'}
            }
            $script:isoSandbox.ValidateTree()
            $child=Join-Path $pinned 'ordinary-child.csv'
            $script:isoSandbox.WriteNew($child,[Text.Encoding]::UTF8.GetBytes('ordinary child creation still works'))
            Assert-Isolated ($script:isoSandbox.ReadAllText($child)-ceq'ordinary child creation still works') 'Restrictive directory pins prevented ordinary child-file I/O.'
            $script:isoSandbox.DeleteFile($child)
            $childDirectory=$script:isoSandbox.EnsureDirectory((Join-Path $pinned 'ordinary-child-directory'))
            Assert-Isolated ([IO.Directory]::Exists($childDirectory)) 'Restrictive directory pins prevented ordinary child-directory creation.'
            Assert-Isolated (-not$script:isoNormalChild.HasExited) 'The synthetic ordinary-data process stopped while restrictive parent pins were active.'
        }finally{
            # On a failed protection test, remove only the synthetic junction
            # object after releasing runtime handles. Never recurse into it.
            Close-IsolatedContext
            if([IO.Directory]::Exists($pinned)-and([IO.File]::GetAttributes($pinned)-band[IO.FileAttributes]::ReparsePoint)-ne0){[IO.Directory]::Delete($pinned,$false)}
        }
    }
    foreach($linkType in @('Junction','SymbolicLink')){
        Case-Isolated $(if($linkType-eq'Junction'){'I15'}else{'I16'}) ($linkType+' to normal state is refused without traversal') {
            Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
            $link=Join-Path $script:isoSandbox.Input ('unsafe_'+$linkType)
            $stagedLink=Join-Path $suiteRoot ('Staged_'+$linkType+'_'+[guid]::NewGuid().ToString('N'))
            $normalSentinel=Join-Path $profile 'TaskPilot4/Backup/original.bin'
            $normalSentinelHash=Get-IsolatedHash $normalSentinel
            try{
                # Build the attack fixture outside the app's inherited deny
                # policy, then rename the link itself into the guarded tree.
                # Direct junction creation inside Input is correctly prevented
                # before validation and would not exercise link detection.
                $null=New-Item -ItemType $linkType -Path $stagedLink -Target (Join-Path $profile 'TaskPilot4') -ErrorAction Stop
                [IO.Directory]::Move($stagedLink,$link)
                $null=Reject-Isolated {$script:isoSandbox.ValidateTree()} ('An unsafe '+$linkType+' was accepted.')
                Assert-Isolated $script:isoSandbox.IsFaulted 'A reparse point must invalidate the context.'
                Assert-Isolated ((Get-IsolatedHash $normalSentinel)-ceq$normalSentinelHash) 'Link detection changed the synthetic normal target.'
            }finally{
                Close-IsolatedContext
                foreach($fixtureLink in @($link,$stagedLink)){if([IO.Directory]::Exists($fixtureLink)){[IO.Directory]::Delete($fixtureLink,$false)}}
            }
        }
    }
    Case-Isolated 'I17' 'Hardlinked normal file is refused before content access' {
        Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
        $target=Join-Path $profile 'TaskPilot4Logs/actions.log';$link=Join-Path $script:isoSandbox.Input 'hardlink.log';$before=Get-IsolatedHash $target
        try{
            $null=New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop
            $null=Reject-Isolated {$script:isoSandbox.AppendText($link,'must not append')} 'Hardlinked normal file was writable.'
            Assert-Isolated $script:isoSandbox.IsFaulted 'Hardlink escape must invalidate the context.'
        }finally{Close-IsolatedContext;if([IO.File]::Exists($link)){[IO.File]::Delete($link)}}
        Assert-Isolated ((Get-IsolatedHash $target)-ceq$before) 'Hardlink handling changed the synthetic normal log.'
    }
    Case-Isolated 'I18' 'Existing test-root junction cannot redirect startup into normal data' {
        Close-IsolatedContext
        $badProfile=Join-Path $suiteRoot 'ProfileWithJunction';$null=[IO.Directory]::CreateDirectory($badProfile)
        $link=Join-Path $badProfile 'TaskPilotTest'
        try{
            $null=New-Item -ItemType Junction -Path $link -Target (Join-Path $profile 'TaskPilot4') -ErrorAction Stop
            $null=Reject-Isolated {[TaskPilot.Runtime.Sandbox]::Create($badProfile,[guid]::NewGuid().ToString('N'))} 'A junction root redirected startup.'
        }finally{if([IO.Directory]::Exists($link)){[IO.Directory]::Delete($link,$false)}}
    }
    Case-Isolated 'I19' 'Hot journals and WAL state fail closed and remain available for diagnosis' {
        Set-IsolatedContext ([guid]::NewGuid().ToString('N')) -NoStartup
        $db=Join-Path $script:isoSandbox.Root 'hot.db';$script:isoSandbox.WriteNew($db,[byte[]]@())
        $script:isoSandbox.WriteNew(($db+'-journal'),[Text.Encoding]::UTF8.GetBytes('synthetic hot journal'))
        $hash=Get-IsolatedHash ($db+'-journal')
        $null=Reject-Isolated {$script:isoSandbox.PrepareDatabase($db,$false)} 'A nonempty recovery journal was adopted.'
        Assert-Isolated ((Get-IsolatedHash ($db+'-journal'))-ceq$hash) 'Rejected journal was deleted or changed.'
    }
    Case-Isolated 'I20' 'A normal DB copy and another environment backup are never retagged' {
        Set-IsolatedContext ([guid]::NewGuid().ToString('N'))
        $normalCopy=Join-Path $BackupDir 'copied_normal.db';[IO.File]::Copy($normalDb,$normalCopy,$false)
        $hash=Get-IsolatedHash $normalCopy
        $null=Reject-Isolated {Restore-TaskPilotDatabase -BackupPath $normalCopy -DatabasePath (Join-Path $Root 'TaskPilot_badnormal.db')} 'A normal backup was accepted in test mode.'
        Assert-Isolated ((Get-IsolatedHash $normalCopy)-ceq$hash) 'Rejected normal copy was retagged or changed.'
        $otherCopy=Join-Path $BackupDir 'copied_other_test.db';[IO.File]::Copy($script:isoBackup,$otherCopy,$false)
        $null=Reject-Isolated {Restore-TaskPilotDatabase -BackupPath $otherCopy -DatabasePath (Join-Path $Root 'TaskPilot_badid.db')} 'Another test environment backup was accepted.'
    }
    Case-Isolated 'I21' 'Invalid IDs prior unmarked data and inaccessible roots stop safely' {
        Close-IsolatedContext
        foreach($id in @('','../TaskPilot4','%LOCALAPPDATA%','AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA','short')){$null=Reject-Isolated {[TaskPilot.Runtime.Sandbox]::Create($profile,$id)} 'An invalid environment identifier was accepted.'}
        $id=[guid]::NewGuid().ToString('N');$unmarked=Join-Path $profile ('TaskPilotTest/'+$id);$null=[IO.Directory]::CreateDirectory($unmarked)
        [IO.File]::WriteAllText((Join-Path $unmarked 'existing.txt'),'preserve unknown state')
        $null=Reject-Isolated {[TaskPilot.Runtime.Sandbox]::Create($profile,$id)} 'Unmarked prior state was adopted.'
        Assert-Isolated ([IO.File]::ReadAllText((Join-Path $unmarked 'existing.txt'))-ceq'preserve unknown state') 'Unknown prior state changed.'
        $denied=Join-Path $suiteRoot 'DeniedProfile';$null=[IO.Directory]::CreateDirectory($denied)
        $originalAcl=Get-Acl -LiteralPath $denied
        $changed=Get-Acl -LiteralPath $denied
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $rights=[Security.AccessControl.FileSystemRights]::ReadAttributes-bor[Security.AccessControl.FileSystemRights]::ListDirectory-bor[Security.AccessControl.FileSystemRights]::CreateDirectories
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,$rights,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
        $changed.AddAccessRule($rule)
        try{Set-Acl -LiteralPath $denied -AclObject $changed;$null=Reject-Isolated {[TaskPilot.Runtime.Sandbox]::Create($denied,[guid]::NewGuid().ToString('N'))} 'An inaccessible root was accepted.'}
        finally{Set-Acl -LiteralPath $denied -AclObject $originalAcl}
    }
    Case-Isolated 'I27' 'Existing grants cannot precede the required directory protection' {
        Close-IsolatedContext
        $unsafeProfile=Join-Path $suiteRoot ('NoncanonicalPolicy_'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($unsafeProfile)
        $anchor=Join-Path $unsafeProfile 'TaskPilotTest'
        $ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # All objects are newly-created fixtures. The early FullControl grant
        # must actually permit attributes despite the later matching denials.
        $unsafeAcl=New-Object Security.AccessControl.DirectorySecurity
        $unsafeAcl.SetSecurityDescriptorSddlForm(('O:'+ $ownerSid +'D:P(A;OICI;FA;;;'+$ownerSid+')(D;CI;0x100;;;S-1-1-0)(D;CI;0xc0000;;;S-1-3-4)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'))
        $null=[IO.Directory]::CreateDirectory($anchor,$unsafeAcl)
        [IO.File]::SetAttributes($anchor,([IO.FileAttributes]::Directory-bor[IO.FileAttributes]::Hidden))
        Assert-Isolated (([IO.File]::GetAttributes($anchor)-band[IO.FileAttributes]::Hidden)-ne0) 'The permissive-policy positive control did not permit attribute changes.'
        $beforePolicy=(Get-Acl -LiteralPath $anchor).Sddl
        $id=[guid]::NewGuid().ToString('N')
        $null=Reject-Isolated {[TaskPilot.Runtime.Sandbox]::Create($unsafeProfile,$id)} 'An early grant bypassed directory protection validation.'
        Assert-Isolated ((Get-Acl -LiteralPath $anchor).Sddl-ceq$beforePolicy) 'The unsafe existing policy was rewritten instead of rejected.'
        Assert-Isolated (-not[IO.Directory]::Exists((Join-Path $anchor $id))) 'A test child was created under an unsafe parent policy.'
    }
    Case-Isolated 'I22' 'Test scope cannot be opened by the ordinary storage process' {
        Close-IsolatedContext
        $probe=Join-Path $suiteRoot 'normal-open-probe.db';[IO.File]::Copy($script:isoBackup,$probe,$false)
        $null=Import-Module $modulePath -Force
        $null=Reject-Isolated {Open-TaskPilotStore -DatabasePath $probe} 'Ordinary mode accepted an independent test database.'
        Remove-Module TaskPilot.Storage -Force
    }
}finally{
    Close-IsolatedContext
    if($null-ne$script:isoNormalChild){
        if(-not$script:isoNormalChild.HasExited){[IO.File]::WriteAllText($holderStop,'stop');if(-not$script:isoNormalChild.WaitForExit(15000)){$script:isoNormalChild.Kill();$script:isoNormalChild.WaitForExit()}}
        if($script:isoNormalChild.ExitCode-ne0){$script:isoCases.Add([pscustomobject]@{Id='I23';Name='Synthetic normal holder exits cleanly';Passed=$false;Error=$script:isoNormalChild.StandardError.ReadToEnd()})}
        $script:isoNormalChild.Dispose()
    }
    foreach($name in $script:isoEnv.Keys){[Environment]::SetEnvironmentVariable($name,$script:isoEnv[$name],'Process')}
    if($null-ne$normalSnapshot){
        try{
            $after=Get-IsolatedNormalSnapshot
            Write-TPBuildNewText (Join-Path $suiteRoot 'NormalFixtureAfter.txt') $after
            $script:isoNormalUnchanged=$after-ceq$normalSnapshot
            Assert-Isolated $script:isoNormalUnchanged 'The normal synthetic data/settings/backups/directory structure changed.'
            $script:isoCases.Add([pscustomobject]@{Id='I24';Name='All synthetic normal file hashes and directory structure unchanged';Passed=$true;Error=$null})
        }catch{$script:isoNormalUnchanged=$false;$script:isoCases.Add([pscustomobject]@{Id='I24';Name='All synthetic normal file hashes and directory structure unchanged';Passed=$false;Error=$_.Exception.Message})}
    }
}
$failures=@($script:isoCases|Where-Object {-not$_.Passed})
$report=[pscustomobject][ordered]@{
    Stage='Native Windows independent-test-mode synthetic verification'
    CapturedAtUtc=[datetime]::UtcNow.ToString('o')
    PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();ProcessBits=[IntPtr]::Size*8
    Passed=($failures.Count-eq0-and$script:isoActualExcel-and$script:isoNormalUnchanged-and$script:isoSkipped.Count-eq0)
    Checks=$script:isoChecks;Cases=$script:isoCases.ToArray();FailedCases=$failures.Count;SkippedDetails=$script:isoSkipped.ToArray();DirectoryReparseAttempts=$script:isoReparseAttempts.ToArray()
    TestRoot=$suiteRoot;RuntimeAssemblySha256=(Get-IsolatedHash $assembly)
    WindowsClientGUIVerified=$false;NormalFixtureUnchanged=$script:isoNormalUnchanged;ActualExcelFilesGenerated=$script:isoActualExcel;ApplicationRunCalled=$false
    ProductionProfileAccessed=$false;SyntheticNormalProcessAndLocksHeld=$true
    Limits=@('Application algorithms and constructed controls were exercised without Application.Run.','Windows 10/11 interactive GUI and external Excel viewing remain unverified.','All ordinary-data sentinels and filesystem attacks were confined to the new synthetic fixture.')
}
Write-TPBuildNewText (Join-Path $suiteRoot 'IsolatedTestModeResult.json') (ConvertTo-Json -InputObject $report -Depth 14)
return $report
