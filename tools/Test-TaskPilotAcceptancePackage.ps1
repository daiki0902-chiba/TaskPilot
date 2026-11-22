#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [string]$OutputRoot,
    [switch]$FirstUse,
    [switch]$TestMode,
    [string]$TestEnvironmentId
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# Standalone checker. It never launches the EXE, loads the SQLite provider,
# removes origin metadata, or opens user databases. Explicit TestMode can load
# the verified boundary DLL and prepare ONLY its marker/empty test directories.
function Get-TPACFullPath([string]$Path){
    $provider=$null;$drive=$null
    $full=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive)
    if($provider.Name-ne'FileSystem'){throw 'A filesystem path is required.'}
    return [IO.Path]::GetFullPath($full)
}
function Test-TPACExists([string]$Path){
    try{$null=[IO.File]::GetAttributes($Path);return $true}
    catch [IO.FileNotFoundException]{return $false}
    catch [IO.DirectoryNotFoundException]{return $false}
}
function Assert-TPACNoLinks([string]$Path){
    $cursor=Get-TPACFullPath $Path
    while($cursor){
        if((Test-TPACExists $cursor)-and(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw ('Link/junction is not accepted: '+$cursor)}
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if($parent-eq$cursor){break};$cursor=$parent
    }
}
function Test-TPACBelow([string]$Path,[string]$Parent){
    $base=$Parent.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    return $Path.Equals($base,[StringComparison]::OrdinalIgnoreCase)-or$Path.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Assert-TPACNoNormalStatePath([string]$Path){
    # Lexical rejection is deliberately before attributes/exists/content I/O.
    # Independent mode must not inspect normal TaskPilot state to allow launch.
    if(-not$script:TPACIndependentIntent-or[string]::IsNullOrWhiteSpace($localAppData)){return}
    foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs','TaskPilot4LegacyBackups','TaskPilot.storage.lock','TaskPilot4.storage.lock')){
        if(Test-TPACBelow $Path (Join-Path $localAppData $leaf)){throw 'Independent test inspection must not access normal TaskPilot state.'}
    }
}
function Assert-TPACLocalDrive([string]$Path){
    if(-not$tpacIsWindows){return}
    $driveRoot=[IO.Path]::GetPathRoot($Path)
    if($driveRoot.StartsWith('\\')-or([IO.DriveInfo]::new($driveRoot)).DriveType-eq[IO.DriveType]::Network){
        throw 'Use a normal local drive, not a UNC path or mapped network drive.'
    }
}
function Assert-TPACRelative([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or$Path.StartsWith('/')-or$Path.Contains('\')-or$Path-match'[<>:"|?*\x00-\x1f]'){throw ('Unsafe package path: '+$Path)}
    foreach($part in $Path.Split('/')){
        if(-not$part-or$part-eq'.'-or$part-eq'..'-or$part.EndsWith('.')-or$part.EndsWith(' ')-or$part-match'^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw ('Unsafe package path: '+$Path)}
    }
}
function Get-TPACProperty($Object,[string]$Name){
    $property=$Object.PSObject.Properties[$Name]
    if($null-eq$property){throw ('Required manifest field is absent: '+$Name)}
    return $property.Value
}
function Get-TPACJson([string]$Path){
    Assert-TPACNoLinks $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length-gt2097152){throw ('Required JSON file exceeds 2 MiB: '+$Path)}
        $bytes=New-Object byte[] ([int]$stream.Length);$offset=0
        while($offset-lt$bytes.Length){
            $read=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if($read-eq0){throw ('JSON file changed during inspection: '+$Path)}
            $offset+=$read
        }
        if($stream.ReadByte()-ne-1){throw ('JSON file changed during inspection: '+$Path)}
    }finally{$stream.Dispose()}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if($text.Length-gt0-and$text[0]-eq[char]0xfeff){$text=$text.Substring(1)}
    return ConvertFrom-Json -InputObject $text -ErrorAction Stop
}
function Assert-TPACBoolean($Object,[string]$Name,[bool]$Expected){
    $value=Get-TPACProperty $Object $Name
    if($value-isnot[bool]-or$value-ne$Expected){throw ('Unexpected Boolean evidence field: '+$Name)}
}
function Add-TPACCheck([string]$Name,[bool]$Passed,[string]$Detail){
    $script:TPACChecks.Add([pscustomobject]@{Name=$Name;Passed=$Passed;Detail=$Detail})
}
function Get-TPACFiles([string]$Root){
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($Root)
    $files=New-Object 'Collections.Generic.List[object]'
    $nodes=0
    while($pending.Count-gt0){
        foreach($entry in ([IO.DirectoryInfo]$pending.Pop()).GetFileSystemInfos()){
            $nodes++;if($nodes-gt1000){throw 'Package contains too many filesystem entries.'}
            if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw ('Package contains a link/junction: '+$entry.FullName)}
            if(($entry.Attributes-band[IO.FileAttributes]::Directory)-ne0){$pending.Push($entry.FullName)}else{$files.Add($entry)}
            if($files.Count-gt301){throw 'Package contains too many files.'}
        }
    }
    return $files.ToArray()
}
function Get-TPACOrigin([string]$Path,[string]$Relative){
    # Enumerating streams distinguishes a missing ADS from an unreadable ADS.
    $streams=@(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)
    $zoneStreams=@($streams|Where-Object {$_.Stream-ieq'Zone.Identifier'})
    if($zoneStreams.Count-eq0){return [pscustomobject]@{Path=$Relative;State='NO_ZONE_STREAM';ZoneIds=@();Blocked=$false}}
    if($zoneStreams.Count-ne1-or$zoneStreams[0].Length-gt65536){throw ('Origin metadata is ambiguous or too large: '+$Relative)}
    $content=Get-Content -LiteralPath $Path -Stream Zone.Identifier -Raw -ErrorAction Stop
    $matches=[regex]::Matches([string]$content,'(?m)^\s*ZoneId\s*=\s*([0-9]+)\s*$')
    if($matches.Count-eq0){throw ('Origin metadata has no readable ZoneId: '+$Relative)}
    $zones=@($matches|ForEach-Object {[int]::Parse($_.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)})
    if(@($zones|Where-Object {$_-lt0-or$_-gt4}).Count-gt0){throw ('Origin metadata has an unsupported ZoneId: '+$Relative)}
    $blocked=@($zones|Where-Object {$_-eq3-or$_-eq4}).Count-gt0
    return [pscustomobject]@{Path=$Relative;State='ZONE_STREAM';ZoneIds=$zones;Blocked=$blocked}
}

$script:TPACChecks=New-Object 'Collections.Generic.List[object]'
$originEvidence=New-Object 'Collections.Generic.List[object]'
$signatureEvidence=New-Object 'Collections.Generic.List[object]'
$tpacIsWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
$localAppData=[Environment]::GetFolderPath('LocalApplicationData')
$roamingAppData=[Environment]::GetFolderPath('ApplicationData')
$modeValid=$true;$expectedTestRoot=$null;$testAreaPrepared=$false
$script:TPACIndependentIntent=$PSBoundParameters.ContainsKey('TestMode')-or$PSBoundParameters.ContainsKey('TestEnvironmentId')
$requestedMode=if($TestMode){'INDEPENDENT_TEST'}elseif($FirstUse){'NORMAL_FIRST_USE'}else{'PACKAGE_ONLY'}
try{
    if($PSBoundParameters.ContainsKey('TestMode')-and-not$TestMode){throw 'Explicit TestMode:false is invalid; no normal inspection fallback is permitted.'}
    if($TestMode){
        if($FirstUse){throw 'TestMode and FirstUse are separate checks and cannot be combined.'}
        if($TestEnvironmentId-cnotmatch'^[a-f0-9]{32}$'){throw 'TestMode requires a lowercase 32-digit GUID TestEnvironmentId.'}
        if([string]::IsNullOrWhiteSpace($localAppData)){throw 'The actual Windows LocalApplicationData folder is unavailable.'}
        $expectedTestRoot=Join-Path (Join-Path $localAppData 'TaskPilotTest') $TestEnvironmentId
    }elseif(-not[string]::IsNullOrEmpty($TestEnvironmentId)){throw 'TestEnvironmentId is allowed only with explicit TestMode.'}
    Add-TPACCheck 'ModeArguments' $true ('Mode='+$requestedMode)
}catch{$modeValid=$false;Add-TPACCheck 'ModeArguments' $false $_.Exception.Message}
if($script:TPACIndependentIntent){Add-TPACCheck 'TestModeReleaseAuthorization' $false 'TP-ISOLATION-BLOCKED: native synthetic I25/I28 permit in-place reparse mutation. Independent mode is disabled; package contents and profile test areas will not be opened.'}
$userSid=$null;$frameworkRelease=$null;$os=$null;$osError=$null
if($tpacIsWindows){
    try{$userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}catch{$userSid='UNAVAILABLE'}
    try{$os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop}catch{$osError=$_.Exception.Message}
    try{$frameworkRelease=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release}catch{}
}
$caption=if($null-ne$os){[string]$os.Caption}else{[Environment]::OSVersion.ToString()}
$productType=if($null-ne$os){[int]$os.ProductType}else{$null}
$cimVersion=if($null-ne$os){[string]$os.Version}else{$null}
$cimBuild=if($null-ne$os){[string]$os.BuildNumber}else{$null}
$edition=if($null-ne$PSVersionTable.PSObject.Properties['PSEdition']){$PSVersionTable.PSEdition}elseif($PSVersionTable.ContainsKey('PSEdition')){$PSVersionTable['PSEdition']}else{'Desktop'}
$clientSupported=$tpacIsWindows-and$null-ne$os-and$productType-eq1-and$cimVersion-like'10.0.*'-and$cimBuild-match'^[0-9]+$'-and[long]$cimBuild-ge10240-and$caption-match'Windows (10|11)(\s|$)'
$hostSupported=$clientSupported-and$edition-eq'Desktop'-and$PSVersionTable.PSVersion.Major-eq5-and$PSVersionTable.PSVersion.Minor-eq1-and[Environment]::Is64BitProcess
Add-TPACCheck 'Windows10Or11Desktop51x64' $hostSupported ('OS='+$caption+'; ProductType='+$productType+'; Version='+$cimVersion+'; Build='+$cimBuild+'; PowerShell='+$PSVersionTable.PSVersion+'; Edition='+$edition+'; ProcessBits='+([IntPtr]::Size*8)+'; CIM error='+$osError)
Add-TPACCheck 'DotNetFramework' ($tpacIsWindows-and$null-ne$frameworkRelease-and[long]$frameworkRelease-ge393295) ('CLR='+[Environment]::Version+'; .NET Framework Release='+$frameworkRelease)

$root=$null;$manifest=$null;$manifestSha=$null;$validatedFiles=@();$packageValid=$false;$candidateCommit=$null;$candidateSha=$null
try{
    # Resolve the requested package name lexically for report placement, then
    # stop independent requests before any manifest/hash/DLL content read.
    $root=Get-TPACFullPath $PackageRoot
    Assert-TPACNoNormalStatePath $root
    if($script:TPACIndependentIntent){throw 'TP-ISOLATION-BLOCKED: independent-mode release is disabled before package content inspection.'}
    if(-not$modeValid){throw 'Mode arguments are invalid; package and profile contents were not inspected.'}
    $root=Get-TPACFullPath $PackageRoot
    Assert-TPACNoNormalStatePath $root
    Assert-TPACNoLinks $root
    if(-not[IO.Directory]::Exists($root)){throw 'PackageRoot must be the extracted acceptance-kit directory.'}
    Assert-TPACLocalDrive $root
    $manifestPath=Join-Path $root 'PACKAGE-MANIFEST.json'
    Assert-TPACNoLinks $manifestPath
    $manifest=Get-TPACJson $manifestPath
    $format=Get-TPACProperty $manifest 'FormatVersion'
    if(($format-isnot[int]-and$format-isnot[long])-or$format-ne1){throw 'Unsupported acceptance-manifest format.'}
    $candidateCommit=Get-TPACProperty $manifest 'CandidateSourceCommit';$candidateSha=Get-TPACProperty $manifest 'CandidateZipSha256'
    if((Get-TPACProperty $manifest 'BinaryVersion')-cne'0.4.0.2'-or$candidateSha-isnot[string]-or$candidateSha-cnotmatch'^[a-f0-9]{64}$'-or$candidateCommit-isnot[string]-or$candidateCommit-cnotmatch'^[a-f0-9]{40}$'){throw 'Manifest does not describe the independent-test-mode PR #1 binary with complete source/ZIP hashes.'}
    foreach($field in @('Windows10Verified','Windows11Verified','InteractiveGuiVerified')){
        Assert-TPACBoolean $manifest $field $false
    }
    $entries=@(Get-TPACProperty $manifest 'Files')
    if($entries.Count-lt1-or$entries.Count-gt300){throw 'Manifest file count is outside the accepted limit.'}
    $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $allFiles=New-Object 'Collections.Generic.List[object]';$totalBytes=[long]0
    foreach($entry in $entries){
        $relative=Get-TPACProperty $entry 'Path'
        if($relative-isnot[string]){throw 'Manifest Path must be a string.'};Assert-TPACRelative $relative
        if($relative-ieq'PACKAGE-MANIFEST.json'-or-not$names.Add($relative)){throw ('Manifest has a duplicate or self-referencing file: '+$relative)}
        $length=Get-TPACProperty $entry 'Bytes';$hash=Get-TPACProperty $entry 'Sha256'
        if(($length-isnot[int]-and$length-isnot[long])-or$length-lt0-or$length-gt104857600-or$hash-isnot[string]-or$hash-cnotmatch'^[a-f0-9]{64}$'){throw ('Invalid manifest length/hash: '+$relative)}
        $totalBytes+=[long]$length;if($totalBytes-gt524288000){throw 'Package exceeds the 500 MiB inspection limit.'}
        $file=Join-Path $root ($relative.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
        Assert-TPACNoLinks $file
        if(-not(Test-TPACBelow $file $root)-or-not[IO.File]::Exists($file)){throw ('Required package file is missing: '+$relative)}
        if(([IO.FileInfo]$file).Length-ne$length-or(Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()-cne$hash){throw ('Package size/hash mismatch: '+$relative)}
        $allFiles.Add([pscustomobject]@{Path=$relative;FullName=$file})
    }
    foreach($required in @('Application/TaskPilot/TaskPilot.exe','Application/TaskPilot/TaskPilot.exe.config','Application/TaskPilot/Modules/TaskPilot.Storage/TaskPilot.Storage.psm1','Application/TaskPilot/Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Application/TaskPilot/Modules/ImportExcel/EPPlus.dll','Application/TaskPilot/Modules/ImportExcel/ImportExcel.psd1','Application/TaskPilot/Adapters/TaskPilot.GuiStartup.ps1','Application/TaskPilot/Adapters/TaskPilot.GuiIsolation.ps1','Application/TaskPilot/Runtime/TaskPilot.Runtime.ps1','Application/TaskPilot/Runtime/TaskPilot.TestSandbox.dll','Application/TaskPilot/Codec/TaskPilotMigrationCodec.cs','Application/TaskPilot/Codec/TaskPilotMigrationCodec.dll','Application/TaskPilot/schema/001_initial.sql','README-ja.md','TEST-MODE-ja.md','TEST-CASES-ja.md','RESULT-TEMPLATE-ja.md','LOGS-ja.md','DISTRIBUTION-OPTIONS-ja.md','FILE-LIST.tsv','Tools/Test-TaskPilotAcceptancePackage.ps1','Tools/Collect-TaskPilotAcceptanceLogs.ps1','Evidence/windows-native-results.json','Evidence/windows-native-verification.json','Evidence/windows-build-info.json','Evidence/windows-isolated-mode-results.json')){
        if(-not$names.Contains($required)){throw ('Required acceptance file is absent from the manifest: '+$required)}
    }
    $actual=@(Get-TPACFiles $root)
    if($actual.Count-ne$names.Count+1){throw 'Package contains extra or missing files. Keep results outside the package.'}
    foreach($file in $actual){
        $relative=$file.FullName.Substring($root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Length+1).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        if($relative-ine'PACKAGE-MANIFEST.json'-and-not$names.Contains($relative)){throw ('Unexpected package file: '+$relative)}
    }
    $native=Get-TPACJson (Join-Path $root 'Evidence/windows-native-verification.json')
    if((Get-TPACProperty $native 'Commit')-cne$candidateCommit-or(Get-TPACProperty $native 'CandidateSha256')-cne$candidateSha-or(Get-TPACProperty $native 'NativeWindowsAutomatedGroupsPassed')-ne8){throw 'Native build evidence does not match the candidate source/ZIP or eight passing groups.'}
    Assert-TPACBoolean $native 'ExecutableGenerated' $true
    foreach($field in @('Windows10And11AcceptanceVerified','InteractiveWinFormsVerified','NotificationDeliveryVerified')){Assert-TPACBoolean $native $field $false}
    $nativeResult=Get-TPACJson (Join-Path $root 'Evidence/windows-native-results.json')
    Assert-TPACBoolean $nativeResult 'TestOnlyProvider' $false
    Assert-TPACBoolean $nativeResult 'PinnedBuildDependenciesSupplied' $true
    Assert-TPACBoolean $nativeResult 'WindowsGUIVerified' $false
    Assert-TPACBoolean $nativeResult 'Windows10And11Verified' $false
    if((Get-TPACProperty $nativeResult 'Passed')-ne8-or(Get-TPACProperty $nativeResult 'Failed')-ne0-or(Get-TPACProperty $nativeResult 'ProcessBits')-ne64-or(Get-TPACProperty $nativeResult 'PowerShell')-notlike'5.1.*'){throw 'Native test evidence must show eight successful groups using 64-bit Windows PowerShell 5.1.'}
    $built=Get-TPACJson (Join-Path $root 'Application/TaskPilot/BuildInfo.json')
    $builtEvidence=Get-TPACJson (Join-Path $root 'Evidence/windows-build-info.json')
    foreach($field in @('Product','Version','Architecture','SourceSha256','RuntimeGuardSourceSha256','RuntimeGuardSha256','CodecSourceSha256','CodecRuntimeSha256','DependencyLockSha256','RuntimeAllowlistSha256','BuildId','SignatureStatus')){
        if((Get-TPACProperty $built $field)-cne(Get-TPACProperty $builtEvidence $field)){throw ('Packaged BuildInfo does not match the native build evidence: '+$field)}
    }
    if((Get-TPACProperty $built 'Product')-cne'TaskPilot'-or(Get-TPACProperty $built 'Version')-cne'0.4.0.2'-or(Get-TPACProperty $built 'Architecture')-cne'x64'){throw 'Unexpected application product/version/architecture.'}
    Assert-TPACBoolean $built 'StartupDownloads' $false
    Assert-TPACBoolean $built 'IndependentTestModeSupported' $true
    if((Get-TPACProperty $built 'RuntimeGuardSha256')-cne(Get-FileHash -LiteralPath (Join-Path $root 'Application/TaskPilot/Runtime/TaskPilot.TestSandbox.dll') -Algorithm SHA256).Hash.ToLowerInvariant()-or(Get-TPACProperty $built 'CodecRuntimeSha256')-cne(Get-FileHash -LiteralPath (Join-Path $root 'Application/TaskPilot/Codec/TaskPilotMigrationCodec.dll') -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'The packaged runtime/codec DLL does not match the native build identity.'}
    $isolatedEvidence=Get-TPACJson (Join-Path $root 'Evidence/windows-isolated-mode-results.json')
    foreach($field in @('Passed','NormalFixtureUnchanged','ActualExcelFilesGenerated')){Assert-TPACBoolean $isolatedEvidence $field $true}
    foreach($field in @('WindowsClientGUIVerified','ApplicationRunCalled','ProductionProfileAccessed')){Assert-TPACBoolean $isolatedEvidence $field $false}
    if((Get-TPACProperty $isolatedEvidence 'SourceCommit')-cne$candidateCommit){throw 'Independent mode test evidence belongs to a different source commit.'}
    if(@(Get-TPACProperty $isolatedEvidence 'SkippedDetails').Count-ne0){throw 'Required independent mode boundary cases must not be skipped.'}
    $requiredIsolatedIds=@('I01','I02','I03','I04','I05','I06','I07','I08','I09','I10','I11','I12','I13','I14','I15','I16','I17','I18','I19','I20','I21','I22','I24','I25','I26','I27','I28')
    $seenIsolatedIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($case in @(Get-TPACProperty $isolatedEvidence 'Cases')){
        $caseId=Get-TPACProperty $case 'Id'
        if($caseId-isnot[string]-or$requiredIsolatedIds-cnotcontains$caseId-or-not$seenIsolatedIds.Add($caseId)){throw 'Independent mode evidence must contain the required unique native cases, all passed.'}
        Assert-TPACBoolean $case 'Passed' $true
    }
    $isolatedFailures=Get-TPACProperty $isolatedEvidence 'FailedCases'
    if($seenIsolatedIds.Count-ne$requiredIsolatedIds.Count-or($isolatedFailures-isnot[int]-and$isolatedFailures-isnot[long])-or$isolatedFailures-ne0){throw 'Independent mode evidence must contain the required unique native cases, all passed.'}
    $fileBoundary=Get-TPACProperty $isolatedEvidence 'FileAndAncestorBoundary'
    foreach($field in @('Passed','CompleteNativeCoverage','NormalFixtureUnchanged')){Assert-TPACBoolean $fileBoundary $field $true}
    Assert-TPACBoolean $fileBoundary 'UnsafeVectorConfirmed' $false
    if((Get-TPACProperty $isolatedEvidence 'RuntimeAssemblySha256')-cne(Get-TPACProperty $built 'RuntimeGuardSha256')){throw 'The tested runtime does not match the packaged guard.'}
    $manifestSha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $validatedFiles=$allFiles.ToArray();$packageValid=$true
    Add-TPACCheck 'PackageIntegrity' $true ($validatedFiles.Count.ToString()+' listed files match; no extra files or links. These hashes are QA evidence, not publisher authentication.')
}catch{Add-TPACCheck 'PackageIntegrity' $false $_.Exception.Message}

$originOK=$false
if($packageValid-and$tpacIsWindows){
    $originOK=$true
    foreach($entry in $validatedFiles){
        if([IO.Path]::GetExtension($entry.Path)-notmatch'^(?i:\.exe|\.dll|\.ps1|\.psm1|\.psd1|\.cs|\.config)$'){continue}
        try{$origin=Get-TPACOrigin $entry.FullName $entry.Path;$originEvidence.Add($origin);if($origin.Blocked){$originOK=$false}}
        catch{$originOK=$false;$originEvidence.Add([pscustomobject]@{Path=$entry.Path;State='UNREADABLE';ZoneIds=@();Blocked=$true;Error=$_.Exception.Message})}
    }
    Add-TPACCheck 'DownloadOrigin' $originOK 'Read-only stream inspection. ZoneId 3/4 or unreadable origin metadata blocks the test; nothing is unblocked automatically.'
    foreach($relative in @('Application/TaskPilot/TaskPilot.exe','Application/TaskPilot/Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Application/TaskPilot/Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Application/TaskPilot/Modules/ImportExcel/EPPlus.dll','Application/TaskPilot/Runtime/TaskPilot.TestSandbox.dll','Application/TaskPilot/Codec/TaskPilotMigrationCodec.dll')){
        try{
            $signaturePath=Join-Path $root ($relative.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
            $signatureCommand=Get-Command -Name 'Microsoft.PowerShell.Security\Get-AuthenticodeSignature' -CommandType Cmdlet -ErrorAction Stop
            $signatureArguments=@{ErrorAction='Stop'}
            if($signatureCommand.Parameters.ContainsKey('LiteralPath')){$signatureArguments.LiteralPath=$signaturePath}
            else{$signatureArguments.FilePath=[WildcardPattern]::Escape($signaturePath)}
            $signature=& $signatureCommand @signatureArguments
            $signer=if($null-ne$signature.SignerCertificate){$signature.SignerCertificate.Subject}else{$null}
            $signatureEvidence.Add([pscustomobject]@{Path=$relative;Status=[string]$signature.Status;Signer=$signer})
        }catch{$signatureEvidence.Add([pscustomobject]@{Path=$relative;Status='UNAVAILABLE';Signer=$null;Error=$_.Exception.Message})}
    }
}else{Add-TPACCheck 'DownloadOrigin' $false 'Not verified: requires an intact package and Windows stream inspection.'}

$isolation='NOT_CHECKED'
if($FirstUse-and-not$TestMode-and$modeValid){
    try{
        if(-not$tpacIsWindows-or[string]::IsNullOrWhiteSpace($localAppData)){throw 'First-use isolation requires the actual Windows LocalApplicationData folder.'}
        Assert-TPACNoLinks $localAppData
        $existing=New-Object 'Collections.Generic.List[string]'
        foreach($leaf in @('TaskPilot','TaskPilot4','TaskPilot4Logs','TaskPilot4LegacyBackups','TaskPilot.storage.lock','TaskPilot4.storage.lock')){
            $candidate=Join-Path $localAppData $leaf
            if(Test-TPACExists $candidate){$existing.Add($candidate)}
        }
        if($existing.Count-gt0){throw ('Existing TaskPilot state found. Use a separate new standard Windows test user or clean VM; do not rename/delete it: '+($existing-join'; '))}
        $isolation='NO_EXISTING_TASKPILOT_STATE_FOUND'
        Add-TPACCheck 'FirstUseIsolation' $true 'No known TaskPilot data, logs, backups or lock paths exist in this Windows profile. A dedicated test user/VM remains required.'
    }catch{$isolation='BLOCKED';Add-TPACCheck 'FirstUseIsolation' $false $_.Exception.Message}
}
if($TestMode){
    $testScope=$null
    try{
        throw 'TP-ISOLATION-BLOCKED: I25/I28 failed. No test area or boundary DLL was opened.'
        if(-not$modeValid){throw 'Independent mode arguments are invalid; no test area was opened.'}
        if(-not$hostSupported){throw 'Independent test readiness requires Windows 10/11 x64 with Desktop PowerShell 5.1; no profile area was opened on this host.'}
        if(-not$packageValid-or-not$originOK){throw 'Verified package bytes and readable, unblocked origin metadata are required before loading the boundary DLL.'}
        $guard=Join-Path $root 'Application/TaskPilot/Runtime/TaskPilot.TestSandbox.dll'
        Assert-TPACNoLinks $guard
        $assembly=[Reflection.Assembly]::LoadFrom($guard)
        if((Get-TPACFullPath $assembly.Location)-ine(Get-TPACFullPath $guard)){throw 'A different boundary DLL is already loaded. Start a fresh Windows PowerShell process.'}
        $type=$assembly.GetType('TaskPilot.Runtime.Sandbox',$true)
        $factory=$type.GetMethod('Create',[Reflection.BindingFlags]'Public,Static',$null,[Type[]]@([string],[string]),$null)
        if($null-eq$factory){throw 'The packaged boundary does not expose the reviewed factory.'}
        # Only the actual Windows profile API and strict GUID feed the fixed
        # namespace. No normal TaskPilot path is probed in this branch.
        $testScope=$factory.Invoke($null,[object[]]@($localAppData,$TestEnvironmentId))
        if([string]$testScope.Root-cne$expectedTestRoot){throw 'The boundary returned a different test root.'}
        $testScope.ValidateTree()
        $testAreaPrepared=$true;$isolation='INDEPENDENT_TEST_AREA_VALIDATED'
        Add-TPACCheck 'TestModeIsolation' $true ('Validated only '+$expectedTestRoot+'. Marker/empty test directories may be prepared; normal data was not inspected.')
    }catch{$isolation='BLOCKED';Add-TPACCheck 'TestModeIsolation' $false $_.Exception.Message}
    finally{if($null-ne$testScope){$testScope.Dispose()}}
}

$reportPath=$null;$reportDirectory=$null
if($OutputRoot){
    try{
        $output=Get-TPACFullPath $OutputRoot;Assert-TPACNoNormalStatePath $output;Assert-TPACNoLinks $output;Assert-TPACLocalDrive $output
        if(-not[IO.Directory]::Exists($output)){throw 'OutputRoot must be an existing tester-owned results directory.'}
        if($null-eq$root-or(Test-TPACBelow $output $root)){throw 'Results must be outside the acceptance package.'}
        foreach($profilePath in @($localAppData,$roamingAppData)){
            if([string]::IsNullOrWhiteSpace($profilePath)){continue}
            $profileFull=Get-TPACFullPath $profilePath
            $appDataParent=[IO.Path]::GetDirectoryName($profileFull)
            if((Test-TPACBelow $output $profileFull)-or($tpacIsWindows-and-not[string]::IsNullOrWhiteSpace($appDataParent)-and(Test-TPACBelow $output $appDataParent))){throw 'Results must be outside AppData and application data/log folders.'}
        }
        $reportDirectory=Join-Path $output ('Preflight_'+[guid]::NewGuid().ToString('N'))
        if(Test-TPACExists $reportDirectory){throw 'A new report directory is required.'}
        Add-TPACCheck 'ReportDestination' $true 'Only a new unique report directory will be created.'
    }catch{Add-TPACCheck 'ReportDestination' $false $_.Exception.Message;$reportDirectory=$null}
}
$failed=@($script:TPACChecks|Where-Object {-not$_.Passed}).Count
$status=if($failed-gt0){'BLOCKED'}elseif($TestMode){'READY_FOR_ISOLATED_TEST'}elseif(-not$FirstUse){'PACKAGE_CHECK_ONLY'}else{'READY_FOR_MANUAL_TEST'}
$report=[pscustomobject][ordered]@{
    Stage='Windows 10/11 acceptance preparation - NOT FOR SALE'
    CapturedAtUtc=[datetime]::UtcNow.ToString('o')
    Status=$status
    Mode=$requestedMode
    TestEnvironmentId=$TestEnvironmentId
    ExpectedTestRoot=$expectedTestRoot
    TestAreaPrepared=$testAreaPrepared
    PackageRoot=$root
    PackageManifestSha256=$manifestSha
    CandidateSourceCommit=$candidateCommit
    CandidateZipSha256=$candidateSha
    Environment=[pscustomobject]@{OS=$caption;ProductType=$productType;OSVersion=[Environment]::OSVersion.ToString();CimVersion=$cimVersion;CimBuildNumber=$cimBuild;PowerShell=$PSVersionTable.PSVersion.ToString();PowerShellEdition=$edition;ProcessBits=([IntPtr]::Size*8);Clr=[Environment]::Version.ToString();FrameworkRelease=$frameworkRelease;User=[Environment]::UserName;UserSid=$userSid;LocalApplicationData=$localAppData}
    FirstUseRequested=[bool]$FirstUse
    Isolation=$isolation
    Checks=$script:TPACChecks.ToArray()
    Signatures=$signatureEvidence.ToArray()
    DownloadOrigin=$originEvidence.ToArray()
    ReportPath=$null
    Boundaries=@('No application entry point or SQLite provider was executed. Explicit TestMode can load the verified boundary DLL and prepare only its test marker/directories.','No normal user database or legacy data content was read or changed.','No origin metadata, execution policy or OS security setting was changed.','Unsigned development candidate; QA hashes do not authenticate its publisher.','Windows 10/11 interactive UI, notifications and Excel output remain unverified by this checker.','Normal FirstUse and explicit TestMode are separate checks. PACKAGE_CHECK_ONLY never approves launch.')
}
if($null-ne$reportDirectory){
    try{
        $null=New-Item -ItemType Directory -Path $reportDirectory -ErrorAction Stop
        Assert-TPACNoLinks $reportDirectory
        $reportPath=Join-Path $reportDirectory 'Preflight.json';$report.ReportPath=$reportPath
        $encoding=[Text.UTF8Encoding]::new($true)
        $bytes=$encoding.GetPreamble()+$encoding.GetBytes(($report|ConvertTo-Json -Depth 12))
        $stream=[IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    }catch{Add-TPACCheck 'ReportWrite' $false $_.Exception.Message;$report.Checks=$script:TPACChecks.ToArray();$report.Status='BLOCKED';$report.ReportPath=$null}
}
return $report
