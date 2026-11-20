#requires -Version 5.1
# Filesystem-only legacy migration evidence. Never changes files under SourceRoot.
# Enter-TPMigrationSourceLock is the sole exception outside a new backup directory:
# it opens/creates parent\TaskPilot.storage.lock, writes no bytes, and never truncates.
# The caller MUST dispose the returned stream after snapshot/migration verification.

function Get-TPMigrationFullPath {
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Path)
    $migrationProvider=$null;$migrationDrive=$null
    $full=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$migrationProvider,[ref]$migrationDrive)
    if($migrationProvider.Name -ne 'FileSystem'){throw 'Migration paths must use the FileSystem provider.'}
    $full=[IO.Path]::GetFullPath($full)
    $root=[IO.Path]::GetPathRoot($full)
    while($full.Length -gt $root.Length -and ($full.EndsWith([string][IO.Path]::DirectorySeparatorChar) -or $full.EndsWith([string][IO.Path]::AltDirectorySeparatorChar))){$full=$full.Substring(0,$full.Length-1)}
    return $full
}
function Test-TPMigrationPathExists {
    param([Parameter(Mandatory=$true)][string]$Path)
    try{$null=[IO.File]::GetAttributes($Path);return $true}
    catch [IO.FileNotFoundException]{return $false}
    catch [IO.DirectoryNotFoundException]{return $false}
}
function Assert-TPMigrationNoLinks {
    param([Parameter(Mandatory=$true)][string]$Path)
    $inspect=Get-TPMigrationFullPath $Path
    while($inspect){
        if(Test-TPMigrationPathExists $inspect){
            $attributes=[IO.File]::GetAttributes($inspect)
            if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Migration rejects symbolic links/junctions: $inspect"}
        }
        $parent=[IO.Path]::GetDirectoryName($inspect)
        if($parent -eq $inspect){break};$inspect=$parent
    }
}
function Get-TPMigrationValidatedSource {
    param([Parameter(Mandatory=$true)][string]$SourceRoot)
    $full=Get-TPMigrationFullPath $SourceRoot
    Assert-TPMigrationNoLinks $full
    if(-not [IO.Directory]::Exists($full)){throw "Migration source must be an existing directory: $full"}
    $dataDirs=@(([IO.DirectoryInfo]$full).GetDirectories() | Where-Object {[string]::Equals($_.Name,'Data',[StringComparison]::OrdinalIgnoreCase)})
    if($dataDirs.Count -ne 1){throw 'Migration source must contain exactly one real Data directory (case-insensitive).'}
    if(($dataDirs[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Migration source Data directory must not be a link/junction.'}
    return $full
}
function Assert-TPMigrationRelativePath {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    # The SQLite evidence schema forbids '..' anywhere, not only as a path segment.
    if([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.StartsWith('/') -or
       $RelativePath.IndexOf('..',[StringComparison]::Ordinal) -ge 0 -or $RelativePath.Contains('\') -or
       $RelativePath.Contains(':') -or [IO.Path]::IsPathRooted($RelativePath) -or
       $RelativePath -match '[\x00-\x1f\x7f]' -or $RelativePath -match '(^|/)\.(/|$)' -or $RelativePath.Contains('//')){
        throw "Unsafe migration relative path: $RelativePath"
    }
}
function Get-TPMigrationSortedPaths {
    param([object[]]$Paths)
    [string[]]$sorted=@($Paths | ForEach-Object {[string]$_})
    [Array]::Sort($sorted,[StringComparer]::Ordinal)
    return ,$sorted
}
function Get-TPMigrationManifestHash {
    param([object[]]$Tree)
    $lookup=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($entry in @($Tree)){
        Assert-TPMigrationRelativePath ([string]$entry.RelativePath)
        if($lookup.ContainsKey([string]$entry.RelativePath)){throw 'Duplicate migration manifest path.'}
        if([long]$entry.Size -lt 0 -or [string]$entry.Sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid migration manifest metadata.'}
        $lookup.Add([string]$entry.RelativePath,$entry)
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        foreach($name in (Get-TPMigrationSortedPaths @($lookup.Keys))){
            $entry=$lookup[$name]
            $pathLength=[Text.Encoding]::UTF8.GetByteCount($name).ToString([cultureinfo]::InvariantCulture)
            $size=([long]$entry.Size).ToString([cultureinfo]::InvariantCulture)
            $record=$pathLength+':'+$name+'|'+$size+'|'+[string]$entry.Sha256+"`n"
            $buffer=[Text.Encoding]::UTF8.GetBytes($record)
            $null=$sha.TransformBlock($buffer,0,$buffer.Length,$buffer,0)
        }
        $empty=New-Object byte[] 0;$null=$sha.TransformFinalBlock($empty,0,0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
    } finally{$sha.Dispose()}
}
function Get-TPMigrationFileEvidence {
    param([string]$Path,[string]$RelativePath,[bool]$CaptureBytes,[long]$MaxFileBytes)
    Assert-TPMigrationNoLinks $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $size=$stream.Length
        if($CaptureBytes -and ($size -gt $MaxFileBytes -or $size -gt [int]::MaxValue)){throw "Selected migration file exceeds MaxFileBytes: $RelativePath"}
        $hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
        if($stream.Length -ne $size){throw "Source file changed while hashing: $RelativePath"}
        $bytes=$null
        if($CaptureBytes){
            $null=$stream.Seek(0,[IO.SeekOrigin]::Begin)
            $bytes=New-Object byte[] ([int]$size)
            $offset=0
            while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){throw "Source file shortened while capturing: $RelativePath"};$offset+=$read}
            if($stream.Length -ne $size){throw "Source file changed while capturing: $RelativePath"}
            $capturedHash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
            if($capturedHash -cne $hash){throw "Source file changed between hash and capture: $RelativePath"}
        }
        $modified=[IO.File]::GetLastWriteTimeUtc($Path).ToString('o',[cultureinfo]::InvariantCulture)
        return [pscustomobject]@{RelativePath=$RelativePath;Bytes=$bytes;Size=[long]$size;Sha256=$hash;ModifiedAtUtc=$modified}
    } finally{$sha.Dispose();$stream.Dispose()}
}
function Get-TPMigrationTreeEvidence {
    param([string]$SourceRoot,[bool]$CaptureSelected=$false,[long]$MaxFileBytes=67108864)
    if($MaxFileBytes -lt 0){throw 'MaxFileBytes must be nonnegative.'}
    $full=Get-TPMigrationValidatedSource $SourceRoot
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $fileMap=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $selectedMap=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $directoryNames=New-Object 'System.Collections.Generic.List[string]'
    $pending=New-Object 'System.Collections.Generic.Stack[object]'
    $pending.Push([pscustomobject]@{Directory=[IO.DirectoryInfo]$full;Prefix=''})
    while($pending.Count -gt 0){
        $node=$pending.Pop()
        foreach($entry in $node.Directory.GetFileSystemInfos()){
            $relative=if($node.Prefix){$node.Prefix+'/'+$entry.Name}else{$entry.Name}
            Assert-TPMigrationRelativePath $relative
            if(-not $seen.Add($relative)){throw "Duplicate case-insensitive source path: $relative"}
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Source tree contains a link/junction: $relative"}
            if(($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0){
                $directoryNames.Add($relative)
                $pending.Push([pscustomobject]@{Directory=[IO.DirectoryInfo]$entry.FullName;Prefix=$relative})
            } else {
                $selected=$CaptureSelected -and ($relative.StartsWith('Data/',[StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($relative,'Settings.json',[StringComparison]::OrdinalIgnoreCase))
                $evidence=Get-TPMigrationFileEvidence -Path $entry.FullName -RelativePath $relative -CaptureBytes $selected -MaxFileBytes $MaxFileBytes
                $fileMap.Add($relative,[pscustomobject]@{RelativePath=$relative;Size=$evidence.Size;Sha256=$evidence.Sha256;ModifiedAtUtc=$evidence.ModifiedAtUtc})
                if($selected){$selectedMap.Add($relative,$evidence)}
            }
        }
    }
    $tree=@(foreach($name in (Get-TPMigrationSortedPaths @($fileMap.Keys))){$fileMap[$name]})
    $files=@(foreach($name in (Get-TPMigrationSortedPaths @($selectedMap.Keys))){$selectedMap[$name]})
    $directories=Get-TPMigrationSortedPaths @($directoryNames)
    return [pscustomobject]@{SourceRoot=$full;Files=$files;Tree=$tree;Directories=$directories;ManifestSha256=Get-TPMigrationManifestHash $tree}
}
function Get-TPMigrationSourceSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SourceRoot,[long]$MaxFileBytes=67108864)
    return Get-TPMigrationTreeEvidence -SourceRoot $SourceRoot -CaptureSelected $true -MaxFileBytes $MaxFileBytes
}
function Assert-TPMigrationSameTree {
    param($Expected,$Actual,[bool]$CompareTimes=$true)
    if(@($Expected.Tree).Count -ne @($Actual.Tree).Count -or @($Expected.Directories).Count -ne @($Actual.Directories).Count){throw 'Migration source tree membership changed.'}
    for($i=0;$i -lt @($Expected.Tree).Count;$i++){
        $before=$Expected.Tree[$i];$after=$Actual.Tree[$i]
        if([string]$before.RelativePath -cne [string]$after.RelativePath -or [long]$before.Size -ne [long]$after.Size -or
           [string]$before.Sha256 -cne [string]$after.Sha256 -or ($CompareTimes -and [string]$before.ModifiedAtUtc -cne [string]$after.ModifiedAtUtc)){
            throw "Migration source file changed: $($before.RelativePath)"
        }
    }
    for($i=0;$i -lt @($Expected.Directories).Count;$i++){if([string]$Expected.Directories[$i] -cne [string]$Actual.Directories[$i]){throw 'Migration source directories changed.'}}
    if([string]$Expected.ManifestSha256 -cne [string]$Actual.ManifestSha256){throw 'Migration manifest changed.'}
}
function Test-TPMigrationSourceUnchanged {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Snapshot)
    if([string]$Snapshot.ManifestSha256 -cne (Get-TPMigrationManifestHash @($Snapshot.Tree))){throw 'Snapshot manifest does not match its metadata.'}
    # Cached evidence is later inserted as a BLOB; never trust mutable byte arrays
    # merely because the original source files still match the tree manifest.
    $selectedExpected=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($entry in @($Snapshot.Tree)){
        $name=[string]$entry.RelativePath
        if($name.StartsWith('Data/',[StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($name,'Settings.json',[StringComparison]::OrdinalIgnoreCase)){$selectedExpected.Add($name,$entry)}
    }
    if(@($Snapshot.Files).Count -ne $selectedExpected.Count){throw 'Selected snapshot evidence is incomplete.'}
    $selectedSeen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $cacheSha=[Security.Cryptography.SHA256]::Create()
    try{
        foreach($cached in @($Snapshot.Files)){
            $name=[string]$cached.RelativePath
            if(-not $selectedSeen.Add($name) -or -not $selectedExpected.ContainsKey($name)){throw 'Selected snapshot evidence has duplicate or unexpected paths.'}
            $expected=$selectedExpected[$name]
            if($cached.Bytes -isnot [byte[]] -or $cached.Bytes.LongLength -ne [long]$expected.Size -or [long]$cached.Size -ne [long]$expected.Size -or
               [string]$cached.Sha256 -cne [string]$expected.Sha256 -or [string]$cached.ModifiedAtUtc -cne [string]$expected.ModifiedAtUtc){throw "Selected snapshot evidence metadata changed: $name"}
            $cachedHash=([BitConverter]::ToString($cacheSha.ComputeHash([byte[]]$cached.Bytes))).Replace('-','').ToLowerInvariant()
            if($cachedHash -cne [string]$expected.Sha256){throw "Selected snapshot evidence bytes changed: $name"}
        }
    } finally{$cacheSha.Dispose()}
    $current=Get-TPMigrationTreeEvidence -SourceRoot $Snapshot.SourceRoot
    Assert-TPMigrationSameTree -Expected $Snapshot -Actual $current
    return $true
}
function Test-TPMigrationEqualOrBelow {
    param([string]$Path,[string]$Parent)
    if([string]::Equals($Path,$Parent,[StringComparison]::OrdinalIgnoreCase)){return $true}
    $prefix=$Parent
    if(-not $prefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)){$prefix+=[IO.Path]::DirectorySeparatorChar}
    return $Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}
function Copy-TPMigrationBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][string]$DestinationRoot)
    $source=Get-TPMigrationValidatedSource $Snapshot.SourceRoot
    $destination=Get-TPMigrationFullPath $DestinationRoot
    Assert-TPMigrationNoLinks $destination
    if((Test-TPMigrationEqualOrBelow $destination $source) -or (Test-TPMigrationEqualOrBelow $source $destination)){throw 'Backup destination must be disjoint from the source (not equal, parent or child).'}
    if(Test-TPMigrationPathExists $destination){throw 'Backup destination already exists; choose a new directory.'}
    $parent=[IO.Path]::GetDirectoryName($destination)
    if(-not [IO.Directory]::Exists($parent)){throw 'Backup destination parent must already exist.'}
    $null=Test-TPMigrationSourceUnchanged $Snapshot
    $created=$false
    try{
        # Never use -Force or copy into a pre-existing destination directory.
        $null=New-Item -ItemType Directory -Path $destination -ErrorAction Stop
        $created=$true
        foreach($relative in @($Snapshot.Directories)){
            Assert-TPMigrationRelativePath ([string]$relative)
            $path=Join-Path $destination ($relative.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
            Assert-TPMigrationNoLinks $path
            if(Test-TPMigrationPathExists $path){throw "Backup directory unexpectedly exists: $relative"}
            $null=New-Item -ItemType Directory -Path $path -ErrorAction Stop
        }
        foreach($entry in @($Snapshot.Tree)){
            $relative=[string]$entry.RelativePath;Assert-TPMigrationRelativePath $relative
            $relativeNative=$relative.Replace('/',[string][IO.Path]::DirectorySeparatorChar)
            $from=Join-Path $source $relativeNative;$to=Join-Path $destination $relativeNative
            Assert-TPMigrationNoLinks $from;Assert-TPMigrationNoLinks $to
            $inputStream=$null;$outputStream=$null
            try{
                $inputStream=[IO.File]::Open($from,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $outputStream=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $inputStream.CopyTo($outputStream);$outputStream.Flush($true)
            } finally{if($null-ne$outputStream){$outputStream.Dispose()};if($null-ne$inputStream){$inputStream.Dispose()}}
            $check=Get-TPMigrationFileEvidence -Path $to -RelativePath $relative -CaptureBytes $false -MaxFileBytes 0
            if($check.Size -ne [long]$entry.Size -or $check.Sha256 -cne [string]$entry.Sha256){throw "Backup verification failed: $relative"}
            [IO.File]::SetLastWriteTimeUtc($to,[datetime]::Parse([string]$entry.ModifiedAtUtc,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind))
        }
        $copied=Get-TPMigrationTreeEvidence -SourceRoot $destination
        Assert-TPMigrationSameTree -Expected $Snapshot -Actual $copied -CompareTimes $false
        $null=Test-TPMigrationSourceUnchanged $Snapshot
        return [pscustomobject]@{Root=$destination;Verified=$true;ManifestSha256=$Snapshot.ManifestSha256}
    } catch {
        if($created){throw [IO.IOException]::new("Backup failed; partial backup is retained at '$destination'. $($_.Exception.Message)",$_.Exception)}
        throw
    }
}
function Enter-TPMigrationSourceLock {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SourceRoot)
    $source=Get-TPMigrationValidatedSource $SourceRoot
    $parent=[IO.Path]::GetDirectoryName($source)
    if(-not $parent){throw 'Source must have a parent directory for the existing TaskPilot storage lock.'}
    $lockPath=Join-Path $parent 'TaskPilot.storage.lock'
    Assert-TPMigrationNoLinks $lockPath
    if([IO.Directory]::Exists($lockPath)){throw 'TaskPilot storage lock path is a directory.'}
    try{$stream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw [IO.IOException]::new("Cannot acquire TaskPilot source lock. Close the legacy app and check permissions: $lockPath",$_.Exception)}
    try{$null=Get-TPMigrationValidatedSource $source;return ,$stream}catch{$stream.Dispose();throw}
}
