#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ApplicationDirectory,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidateLength(0,120)][string]$CaseId='',
    [ValidateLength(0,5000)][string]$Reproduction='',
    [string]$LogDirectory,
    [switch]$TestMode,
    [string]$TestEnvironmentId,
    [ValidateRange(1,100)][int]$MaximumLogFiles=50,
    [ValidateRange(1,20)][int]$MaximumLogFileMiB=10,
    [ValidateRange(1,100)][int]$MaximumTotalLogMiB=50
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($PSBoundParameters.ContainsKey('TestMode')-or$PSBoundParameters.ContainsKey('TestEnvironmentId')){throw 'TP-ISOLATION-BLOCKED: 独立モードのログ採取は安全性試験 I25/I28 の不合格により停止しています。保存先・アプリ内容・ログは開いていません。'}

# Diagnostic reader only. Never dot-source or launch the application, change
# AppData, remove blocks, install modules, stop processes, or upload evidence.
function Get-AcceptanceFullPath([string]$Path){
    $provider=$null;$drive=$null
    $resolved=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive)
    if($provider.Name-ne'FileSystem'){throw 'A filesystem path is required.'}
    [IO.Path]::GetFullPath($resolved)
}
function Test-AcceptancePathExists([string]$Path){
    try{$null=[IO.File]::GetAttributes($Path);$true}
    catch [IO.FileNotFoundException]{$false}catch [IO.DirectoryNotFoundException]{$false}
}
function Assert-AcceptanceNoLinks([string]$Path){
    $cursor=$Path
    while($cursor){
        if(Test-AcceptancePathExists $cursor){
            if(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw ('Links/junctions are not accepted: '+$cursor)}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent-eq$cursor){break};$cursor=$parent
    }
}
function Test-AcceptanceBelow([string]$Path,[string]$Parent){
    $base=$Parent.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $Path.Equals($base,[StringComparison]::OrdinalIgnoreCase)-or$Path.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Write-AcceptanceNewText([string]$Path,[string]$Text){
    Assert-AcceptanceNoLinks $Path
    $encoder=[Text.UTF8Encoding]::new($true)
    $bytes=[byte[]]($encoder.GetPreamble()+$encoder.GetBytes($Text))
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Get-AcceptanceSha([string]$Path){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
}
function Assert-AcceptanceNoNormalState([string]$Path){
    if(-not$TestMode-or[string]::IsNullOrWhiteSpace($localAppData)){return}
    foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs','TaskPilot4LegacyBackups','TaskPilot.storage.lock','TaskPilot4.storage.lock')){
        if(Test-AcceptanceBelow $Path (Join-Path $localAppData $leaf)){throw 'Independent diagnostics must not inspect normal TaskPilot state.'}
    }
}
function Open-AcceptanceTestScope([string]$Application,[string]$Profile,[string]$Id){
    $guard=Join-Path $Application 'Runtime/TaskPilot.TestSandbox.dll'
    $hashFile=Join-Path $Application 'FileHashes.json'
    foreach($path in @($guard,$hashFile)){Assert-AcceptanceNoLinks $path}
    if(-not[IO.File]::Exists($guard)-or-not[IO.File]::Exists($hashFile)){throw 'The isolated-mode boundary or product hash manifest is missing; test logs were not read.'}
    if(([IO.FileInfo]$hashFile).Length-gt2097152){throw 'The product hash manifest exceeds the diagnostic limit.'}
    $hashes=Get-Content -LiteralPath $hashFile -Raw -Encoding UTF8|ConvertFrom-Json
    $entry=@($hashes.Files|Where-Object {$_.Path-ceq'Runtime/TaskPilot.TestSandbox.dll'})
    if($entry.Count-ne1-or$entry[0].Sha256-cne(Get-AcceptanceSha $guard)){throw 'The isolated-mode boundary does not match its reviewed package manifest; no test log was read.'}
    # Do not remove origin metadata just to enable diagnostics.
    $streams=@(Get-Item -LiteralPath $guard -Stream * -ErrorAction Stop)
    $zone=@($streams|Where-Object {$_.Stream-ieq'Zone.Identifier'})
    if($zone.Count-gt1-or($zone.Count-eq1-and$zone[0].Length-gt65536)){throw 'The boundary origin metadata is unreadable or ambiguous.'}
    if($zone.Count-eq1){
        $origin=Get-Content -LiteralPath $guard -Stream Zone.Identifier -Raw -ErrorAction Stop
        $matches=[regex]::Matches($origin,'(?m)^\s*ZoneId\s*=\s*([0-9]+)\s*$')
        if($matches.Count-ne1-or$matches[0].Groups[1].Value-notin@('0','1','2')){throw 'The boundary DLL is blocked or has unsupported origin metadata; no test log was read.'}
    }
    $assembly=[Reflection.Assembly]::LoadFrom($guard)
    if((Get-AcceptanceFullPath $assembly.Location)-ine(Get-AcceptanceFullPath $guard)){throw 'A different boundary DLL is already loaded; start a fresh Windows PowerShell process.'}
    $type=$assembly.GetType('TaskPilot.Runtime.Sandbox',$true)
    $open=$type.GetMethod('OpenExisting',[Reflection.BindingFlags]'Public,Static',$null,[Type[]]@([string],[string]),$null)
    if($null-eq$open){throw 'Read-only isolated diagnostics require the reviewed OpenExisting boundary factory.'}
    return $open.Invoke($null,[object[]]@($Profile,$Id))
}

$localAppData=[Environment]::GetFolderPath('LocalApplicationData')
$roamingAppData=[Environment]::GetFolderPath('ApplicationData')
$testRoot=$null;$testScope=$null
if($TestMode){
    if($TestEnvironmentId-cnotmatch'^[a-f0-9]{32}$'){throw 'TestMode requires a lowercase 32-digit GUID TestEnvironmentId.'}
    if($PSBoundParameters.ContainsKey('LogDirectory')){throw 'LogDirectory overrides are forbidden in TestMode. Only that environment Logs directory can be read.'}
    if([string]::IsNullOrWhiteSpace($localAppData)){throw 'The actual LocalApplicationData folder is unavailable.'}
    $testRoot=Join-Path (Join-Path $localAppData 'TaskPilotTest') $TestEnvironmentId
    $LogDirectory=Join-Path $testRoot 'Logs'
}elseif($PSBoundParameters.ContainsKey('TestMode')){throw 'Explicit TestMode:false is invalid; normal log fallback is not permitted.'}
elseif(-not[string]::IsNullOrEmpty($TestEnvironmentId)){throw 'TestEnvironmentId requires explicit TestMode.'}
$application=Get-AcceptanceFullPath $ApplicationDirectory
$output=Get-AcceptanceFullPath $OutputRoot
foreach($path in @($application,$output)){Assert-AcceptanceNoNormalState $path}
if(-not$LogDirectory){
    if([string]::IsNullOrWhiteSpace($localAppData)){throw 'LocalApplicationData is unavailable; supply a test LogDirectory explicitly.'}
    $LogDirectory=Join-Path $localAppData 'TaskPilot4Logs'
}
$logs=Get-AcceptanceFullPath $LogDirectory
foreach($path in @($application,$output)){Assert-AcceptanceNoLinks $path}
if(-not$TestMode){Assert-AcceptanceNoLinks $logs}
if(-not[IO.Directory]::Exists($application)){throw 'ApplicationDirectory must be an existing folder containing the candidate TaskPilot.exe.'}
if(-not[IO.Directory]::Exists($output)){throw 'OutputRoot must be an existing tester-owned folder, for example a folder on the Desktop.'}
if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
    $outputDrive=[IO.Path]::GetPathRoot($output)
    if($outputDrive.StartsWith('\\')-or([IO.DriveInfo]::new($outputDrive)).DriveType-eq[IO.DriveType]::Network){
        throw 'OutputRoot must be on a local drive, not a UNC path or mapped network drive.'
    }
}
if((Test-AcceptanceBelow $output $application)-or(Test-AcceptanceBelow $output $logs)){
    throw 'OutputRoot must be outside the application and log folders.'
}
if($TestMode-and(Test-AcceptanceBelow $output $testRoot)){throw 'Isolated diagnostic output must be outside the environment being inspected.'}
$protected=New-Object 'Collections.Generic.List[string]'
foreach($path in @($localAppData,$roamingAppData)){if(-not[string]::IsNullOrWhiteSpace($path)){$protected.Add((Get-AcceptanceFullPath $path))}}
if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT-and-not[string]::IsNullOrWhiteSpace($localAppData)){
    $protected.Add([IO.Path]::GetDirectoryName($localAppData)) # Includes LocalLow as well as Local/Roaming.
}
foreach($path in $protected){if(Test-AcceptanceBelow $output $path){throw 'OutputRoot must be outside AppData; use a separate tester-owned Desktop folder.'}}
$destination=Join-Path $output ('TaskPilotDiagnostics_'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N'))
if(Test-AcceptancePathExists $destination){throw 'Diagnostic destination already exists; no file was changed.'}
$null=New-Item -ItemType Directory -Path $destination -ErrorAction Stop
$copiedLogs=Join-Path $destination 'Logs';$null=New-Item -ItemType Directory -Path $copiedLogs -ErrorAction Stop
$warnings=New-Object 'Collections.Generic.List[string]'
$logResults=New-Object 'Collections.Generic.List[object]'
$inventory=New-Object 'Collections.Generic.List[object]'
$diagnosticIsWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
$osMetadata=$null;$frameworkRelease=$null
if($diagnosticIsWindows){
    try{
        $os=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osMetadata=[ordered]@{}
        foreach($name in @('ProductName','DisplayVersion','CurrentBuildNumber','UBR','EditionID')){
            $property=$os.PSObject.Properties[$name];if($null-ne$property){$osMetadata[$name]=$property.Value}
        }
    }catch{$warnings.Add('OS registry metadata unavailable: '+$_.Exception.Message)}
    try{$frameworkRelease=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release}catch{$warnings.Add('.NET Framework Release unavailable: '+$_.Exception.Message)}
}
$environment=[ordered]@{
    CapturedAtUtc=[datetime]::UtcNow.ToString('o');CaseId=$CaseId;Reproduction=$Reproduction
    OSVersion=[Environment]::OSVersion.ToString();OSRegistry=$osMetadata
    PowerShellEdition=$PSVersionTable.PSEdition;PowerShellVersion=$PSVersionTable.PSVersion.ToString()
    ProcessBits=[IntPtr]::Size*8;Is64BitOperatingSystem=[Environment]::Is64BitOperatingSystem
    ClrVersion=[Environment]::Version.ToString();DotNetFrameworkRelease=$frameworkRelease
    ApplicationDirectory=$application;LogDirectory=$logs
    TestMode=[bool]$TestMode;TestEnvironmentId=$TestEnvironmentId;ExpectedTestRoot=$testRoot
    RealWindowsAcceptanceEstablished=$false
}

# Fixed file names only. Record identities and ADS/signature metadata, never
# execute these files or copy application/user data into the report.
$relativeFiles=@(
    'TaskPilot.exe','TaskPilot.exe.config','BuildInfo.json','FileHashes.json','SoftwareBillOfMaterials.json',
    'Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll',
    'Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll',
    'Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll',
    'Modules/ImportExcel/EPPlus.dll','Modules/ImportExcel/ImportExcel.psd1',
    'Runtime/TaskPilot.Runtime.ps1','Runtime/TaskPilot.TestSandbox.dll','Codec/TaskPilotMigrationCodec.dll'
)
foreach($relative in $relativeFiles){
    $entry=[ordered]@{Path=$relative;State='Missing';Length=$null;Sha256=$null;FileVersion=$null;SignatureStatus=$null;SignerSubject=$null;SignerThumbprint=$null;ZoneState='NotChecked';ZoneId=$null;Error=$null}
    try{
        $file=Join-Path $application ($relative.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
        Assert-AcceptanceNoLinks $file
        if([IO.File]::Exists($file)){
            $info=[IO.FileInfo]$file;$entry.State='Present';$entry.Length=$info.Length
            if($info.Length-gt32MB){throw 'Candidate metadata input exceeds the 32 MiB diagnostic limit.'}
            $entry.Sha256=Get-AcceptanceSha $file
            if($relative-match'\.(exe|dll)$'){
                $entry.FileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion
                if($diagnosticIsWindows){
                    try{
                        $signatureCommand=Get-Command -Name 'Microsoft.PowerShell.Security\Get-AuthenticodeSignature' -CommandType Cmdlet -ErrorAction Stop
                        $signatureArguments=@{ErrorAction='Stop'}
                        if($signatureCommand.Parameters.ContainsKey('LiteralPath')){$signatureArguments.LiteralPath=$file}
                        else{$signatureArguments.FilePath=[WildcardPattern]::Escape($file)}
                        $signature=& $signatureCommand @signatureArguments
                        $entry.SignatureStatus=[string]$signature.Status
                        if($null-ne$signature.SignerCertificate){$entry.SignerSubject=$signature.SignerCertificate.Subject;$entry.SignerThumbprint=$signature.SignerCertificate.Thumbprint}
                    }catch{$entry.SignatureStatus='Unavailable';$warnings.Add('Signature read failed for '+$relative+': '+$_.Exception.Message)}
                }else{$entry.SignatureStatus='NotApplicableOnThisPlatform'}
            }
            if($diagnosticIsWindows){
                $zoneStream=$null
                try{
                    $zoneStream=[IO.File]::Open($file+':Zone.Identifier',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    if($zoneStream.Length-gt4096){$entry.ZoneState='PresentOversized'}else{
                        $buffer=New-Object byte[] ([int]$zoneStream.Length);$count=$zoneStream.Read($buffer,0,$buffer.Length)
                        $zoneText=[Text.Encoding]::UTF8.GetString($buffer,0,$count);$entry.ZoneState='Present'
                        if($zoneText-match'(?m)^ZoneId=(\d+)\s*$'){$entry.ZoneId=[int]$matches[1]}
                    }
                }catch [IO.FileNotFoundException]{$entry.ZoneState='Absent'}catch [IO.DirectoryNotFoundException]{$entry.ZoneState='Unavailable'}
                catch{$entry.ZoneState='ReadFailed';$warnings.Add('Zone.Identifier read failed for '+$relative+': '+$_.Exception.Message)}
                finally{if($null-ne$zoneStream){$zoneStream.Dispose()}}
            }else{$entry.ZoneState='NotApplicableOnThisPlatform'}
        }
    }catch{$entry.State='ReadFailed';$entry.Error=$_.Exception.Message}
    $inventory.Add([pscustomobject]$entry)
}

$totalBytes=[long]0;$selected=0;$scanned=0
$fileLimit=[long]$MaximumLogFileMiB*1MB;$totalLimit=[long]$MaximumTotalLogMiB*1MB
if($TestMode){
    try{
        if(-not$diagnosticIsWindows-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or-not[Environment]::Is64BitProcess){throw 'Isolated log reading requires native x64 Windows PowerShell 5.1.'}
        $testScope=Open-AcceptanceTestScope $application $localAppData $TestEnvironmentId
        if([string]$testScope.Root-cne$testRoot){throw 'The boundary returned a different test root.'}
        $testScope.ValidateTree()
    }catch{
        $warnings.Add('Isolated test logs were not read: '+$_.Exception.Message)
        if($null-ne$testScope){$testScope.Dispose();$testScope=$null}
    }
}
if($TestMode-and$null-eq$testScope){$warnings.Add('No normal log fallback is allowed in TestMode. Capture the on-screen error if the test environment is absent or unsafe.')}
elseif(($TestMode-and-not$testScope.Exists($logs))-or(-not$TestMode-and-not[IO.Directory]::Exists($logs))){$warnings.Add('The log folder does not exist. Startup may have failed before TaskPilot could create a log; collect the on-screen error manually.')}
else{
    try{
        if($TestMode){$testScope.ValidateTree()}
        foreach($fileInfo in ([IO.DirectoryInfo]$logs).EnumerateFileSystemInfos()){
            $scanned++;if($scanned-gt1000){$warnings.Add('Stopped after scanning 1000 top-level log entries. No subfolder was traversed.');break}
            if($fileInfo.Name-cnotmatch'^(actions\.log|errors\.log|MigrationInspection_[0-9a-fA-F]{32}\.json|MigrationResult_[0-9a-fA-F]{32}\.json)$'){continue}
            if($selected-ge$MaximumLogFiles){$warnings.Add('Maximum selected log file count reached; remaining logs were not collected.');break};$selected++
            $result=[ordered]@{Name=$fileInfo.Name;Status='NotCopied';ObservedLength=$null;CopiedBytes=0;Sha256=$null;Error=$null}
            $read=$null;$write=$null
            try{
                if($TestMode){
                    $null=$testScope.AssertPath($fileInfo.FullName)
                    $length=$testScope.GetFileLength($fileInfo.FullName);$result.ObservedLength=$length
                    if($length-gt$fileLimit){$result.Status='SkippedFileSizeLimit'}
                    elseif($totalBytes+$length-gt$totalLimit){$result.Status='SkippedTotalSizeLimit'}
                    else{
                        $snapshot=$testScope.ReadPrefix($fileInfo.FullName,[int]($fileLimit+1))
                        if($snapshot.Length-gt$fileLimit-or$totalBytes+$snapshot.Length-gt$totalLimit){$result.Status='SkippedChangedSizeLimit'}
                        else{
                            $to=Join-Path $copiedLogs $fileInfo.Name
                            $write=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                            $write.Write($snapshot,0,$snapshot.Length);$write.Flush($true);$write.Dispose();$write=$null
                            $result.CopiedBytes=$snapshot.Length;$totalBytes+=$snapshot.Length
                            $result.Sha256=Get-AcceptanceSha $to;$result.Status='CopiedBestEffortSnapshot'
                        }
                    }
                    $logResults.Add([pscustomobject]$result)
                    continue
                }
                Assert-AcceptanceNoLinks $fileInfo.FullName
                if(($fileInfo.Attributes-band[IO.FileAttributes]::Directory)-ne0){throw 'A log allowlist name is a directory; it was not traversed.'}
                $read=[IO.File]::Open($fileInfo.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                $length=$read.Length;$result.ObservedLength=$length
                if($length-gt$fileLimit){$result.Status='SkippedFileSizeLimit'}
                elseif($totalBytes+$length-gt$totalLimit){$result.Status='SkippedTotalSizeLimit'}
                else{
                    $to=Join-Path $copiedLogs $fileInfo.Name
                    Assert-AcceptanceNoLinks $to
                    $write=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    $buffer=New-Object byte[] 65536;$remaining=$length
                    while($remaining-gt0){$count=$read.Read($buffer,0,[int][Math]::Min([long]$buffer.Length,$remaining));if($count-eq0){break};$write.Write($buffer,0,$count);$remaining-=$count;$result.CopiedBytes+=$count;$totalBytes+=$count}
                    $write.Flush($true);$write.Dispose();$write=$null
                    $result.Sha256=Get-AcceptanceSha $to
                    $result.Status=if($result.CopiedBytes-eq$length){'CopiedBestEffortSnapshot'}else{'CopiedShortRead'}
                }
            }catch{$result.Status='ReadOrCopyFailed';$result.Error=$_.Exception.Message;if($TestMode){$logResults.Add([pscustomobject]$result);throw}}
            finally{if($null-ne$write){$write.Dispose()};if($null-ne$read){$read.Dispose()}}
            $logResults.Add([pscustomobject]$result)
        }
    }catch{$warnings.Add('Log enumeration stopped: '+$_.Exception.Message)}
}
if($null-ne$testScope){$testScope.Dispose();$testScope=$null}
$collection=[ordered]@{
    CapturedAtUtc=[datetime]::UtcNow.ToString('o');SourceDataModified=$false
    LogPolicy='Top-level allowlist only; no database, CSV, Excel, backup, or arbitrary subfolder copied. Open logs are best-effort snapshots.'
    MaximumLogFiles=$MaximumLogFiles;MaximumLogFileMiB=$MaximumLogFileMiB;MaximumTotalLogMiB=$MaximumTotalLogMiB
    CopiedLogBytes=$totalBytes;Logs=$logResults.ToArray();Warnings=$warnings.ToArray()
}
Write-AcceptanceNewText (Join-Path $destination 'Environment.json') (ConvertTo-Json -InputObject $environment -Depth 6)
Write-AcceptanceNewText (Join-Path $destination 'CandidateFiles.json') (ConvertTo-Json -InputObject $inventory.ToArray() -Depth 6)
Write-AcceptanceNewText (Join-Path $destination 'Collection.json') (ConvertTo-Json -InputObject $collection -Depth 6)
Write-AcceptanceNewText (Join-Path $destination 'REVIEW-BEFORE-SHARING.txt') "Logs and paths can contain personal information or task text. Review all files before sharing. No files were uploaded. No user data, blocks, settings, or running processes were changed. A missing log is not proof of success. Windows 10/11 acceptance is not established by collecting diagnostics.`r`n"
Write-Host ('Diagnostics saved locally: '+$destination)
[pscustomobject]@{Directory=$destination;LogsSelected=$logResults.Count;CopiedLogBytes=$totalBytes;Warnings=$warnings.Count;SourceDataModified=$false;Uploaded=$false}
