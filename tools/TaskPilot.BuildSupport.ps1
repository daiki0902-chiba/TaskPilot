#requires -Version 5.1
# Build/developer filesystem helpers. Never loaded by customer startup.
function Get-TPBuildFullPath([string]$Path){
    $provider=$null;$drive=$null
    $full=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive)
    if($provider.Name-ne'FileSystem'){throw 'A filesystem path is required.'}
    return [IO.Path]::GetFullPath($full)
}
function Test-TPBuildPathExists([string]$Path){
    try{$null=[IO.File]::GetAttributes($Path);return $true}
    catch [IO.FileNotFoundException]{return $false}catch [IO.DirectoryNotFoundException]{return $false}
}
function Assert-TPBuildNoLinks([string]$Path){
    $cursor=Get-TPBuildFullPath $Path
    while($cursor){
        if(Test-TPBuildPathExists $cursor){if(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Links/junctions are not accepted by this build tool: $cursor"}}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent-eq$cursor){break};$cursor=$parent
    }
}
function Assert-TPBuildRelative([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or $Path.StartsWith('/')-or $Path.Contains('\')-or $Path.Contains(':')-or $Path-match'(^|/)\.\.?(/|$)'-or $Path-match'[\x00-\x1f]'){throw "Unsafe relative build path: $Path"}
}
function Test-TPBuildBelow([string]$Path,[string]$Parent){
    $base=$Parent.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    return $Path.Equals($base,[StringComparison]::OrdinalIgnoreCase)-or $Path.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Get-TPBuildSha([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
function Get-TPBuildStreamSha($Stream){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Assert-TPBuildWindowsX64GuiExe([string]$Path){
    $stream=[IO.File]::OpenRead($Path);$reader=[IO.BinaryReader]::new($stream)
    try{
        if($stream.Length-lt256-or$reader.ReadUInt16()-ne0x5a4d){throw 'Output lacks an MZ executable header.'}
        $stream.Position=0x3c;$peOffset=$reader.ReadInt32()
        if($peOffset-lt64-or$peOffset-gt($stream.Length-264)){throw 'Output has an invalid PE offset.'}
        $stream.Position=$peOffset
        if($reader.ReadUInt32()-ne0x00004550){throw 'Output lacks a PE signature.'}
        if($reader.ReadUInt16()-ne0x8664){throw 'Output is not an x64 executable.'}
        if($reader.ReadUInt16()-lt1){throw 'Output has no PE sections.'}
        $stream.Position=$peOffset+20
        if($reader.ReadUInt16()-lt240){throw 'Output has an incomplete PE32+ optional header.'}
        $characteristics=$reader.ReadUInt16()
        if(($characteristics-band2)-eq0-or($characteristics-band0x2000)-ne0){throw 'Output is not an executable image or is a DLL.'}
        $stream.Position=$peOffset+24
        if($reader.ReadUInt16()-ne0x020b){throw 'Output lacks a PE32+ optional header.'}
        $stream.Position=$peOffset+24+68
        if($reader.ReadUInt16()-ne2){throw 'Output is not a Windows GUI executable (noConsole required).'}
    }finally{$reader.Dispose()}
}
function Write-TPBuildNewBytes([string]$Path,[byte[]]$Bytes){
    Assert-TPBuildNoLinks $Path
    $parent=[IO.Path]::GetDirectoryName($Path)
    if(-not[IO.Directory]::Exists($parent)){$null=[IO.Directory]::CreateDirectory($parent)}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Write-TPBuildNewText([string]$Path,[string]$Text,[bool]$Bom=$false){
    $encoder=[Text.UTF8Encoding]::new($Bom)
    $bytes=$encoder.GetPreamble()+$encoder.GetBytes($Text)
    Write-TPBuildNewBytes $Path ([byte[]]$bytes)
}
function Copy-TPBuildNewFile([string]$Source,[string]$Destination,[string]$ExpectedSha){
    Assert-TPBuildNoLinks $Source;Assert-TPBuildNoLinks $Destination
    $before=Get-TPBuildSha $Source
    if($ExpectedSha-and$before-cne$ExpectedSha){throw "Source hash changed: $Source"}
    $parent=[IO.Path]::GetDirectoryName($Destination)
    if(-not[IO.Directory]::Exists($parent)){$null=[IO.Directory]::CreateDirectory($parent)}
    $read=$null;$write=$null
    try{
        $read=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $write=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $read.CopyTo($write);$write.Flush($true)
    }finally{if($null-ne$write){$write.Dispose()};if($null-ne$read){$read.Dispose()}}
    if((Get-TPBuildSha $Destination)-cne$before-or(Get-TPBuildSha $Source)-cne$before){throw "Copy verification failed: $Source"}
}
function Get-TPBuildFiles([string]$Root){
    Assert-TPBuildNoLinks $Root
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($Root)
    $result=New-Object 'Collections.Generic.List[object]'
    while($pending.Count){foreach($entry in ([IO.DirectoryInfo]$pending.Pop()).GetFileSystemInfos()){
        if(($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Build input contains a link: $($entry.FullName)"}
        if(($entry.Attributes-band[IO.FileAttributes]::Directory)-ne0){$pending.Push($entry.FullName)}else{$result.Add($entry)}
    }}
    $names=[string[]]@($result|ForEach-Object{$_.FullName});[Array]::Sort($names,[StringComparer]::Ordinal)
    foreach($name in $names){[IO.FileInfo]$name}
}
function Assert-TPBuildPowerShell([string]$Path){
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('PowerShell parse failed: '+$Path+[Environment]::NewLine+($errors|Out-String))}
    $bytes=[IO.File]::ReadAllBytes($Path)
    $isUtf8Bom=$bytes.Length-ge3-and$bytes[0]-eq239-and$bytes[1]-eq187-and$bytes[2]-eq191
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if(-not$isUtf8Bom-and$text-match'[^\x00-\x7f]'){throw "Non-ASCII PowerShell source needs UTF8 BOM for Windows5.1: $Path"}
}
function Get-TPBuildLock([string]$Path){
    Assert-TPBuildNoLinks $Path
    $lock=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if($lock.FormatVersion-ne1){throw 'Unsupported build dependency lock format.'}
    return $lock
}
function Expand-TPBuildPackage([string]$Archive,[string]$Target){
    if(Test-TPBuildPathExists $Target){throw "Package extraction target already exists: $Target"}
    $null=[IO.Directory]::CreateDirectory($Target)
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try{foreach($entry in $zip.Entries){
        $name=$entry.FullName.Replace('\','/').TrimEnd('/')
        if(-not$name){continue};Assert-TPBuildRelative $name
        if(-not$seen.Add($name)){throw 'Duplicate/case-colliding archive entry.'}
        $to=Join-Path $Target ($name.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
        if($entry.FullName.EndsWith('/')){$null=[IO.Directory]::CreateDirectory($to);continue}
        $parent=[IO.Path]::GetDirectoryName($to);if(-not[IO.Directory]::Exists($parent)){$null=[IO.Directory]::CreateDirectory($parent)}
        $inputStream=$entry.Open();$outputStream=$null
        try{$outputStream=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$inputStream.CopyTo($outputStream)}finally{if($null-ne$outputStream){$outputStream.Dispose()};$inputStream.Dispose()}
    }}finally{$zip.Dispose()}
}
function Assert-TPBuildDependencyTree([string]$Root,$Lock){
    Assert-TPBuildNoLinks $Root
    foreach($item in @($Lock.Downloads)){
        Assert-TPBuildRelative $item.Target
        $path=Join-Path $Root ($item.Target.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
        if(-not[IO.File]::Exists($path)-or(Get-TPBuildSha $path)-cne$item.Sha256){throw "Missing/changed pinned dependency: $($item.Target). Run Get-TaskPilotBuildDependencies.ps1 into a NEW developer folder."}
    }
    foreach($module in @($Lock.Modules)){
        $archive=Join-Path $Root $module.ArchiveTarget;$folder=Join-Path $Root $module.ExtractTarget
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        $expected=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        try{foreach($entry in $zip.Entries){
            if($entry.FullName.EndsWith('/')){continue};$name=$entry.FullName.Replace('\','/');Assert-TPBuildRelative $name
            if(-not$expected.Add($name)){throw 'Pinned package has duplicate file paths.'}
            $path=Join-Path $folder ($name.Replace('/',[string][IO.Path]::DirectorySeparatorChar))
            Assert-TPBuildNoLinks $path
            if(-not[IO.File]::Exists($path)){throw "Incomplete developer module payload: $($module.Id)/$name"}
            $stream=$entry.Open();try{$packageSha=Get-TPBuildStreamSha $stream}finally{$stream.Dispose()}
            if((Get-TPBuildSha $path)-cne$packageSha){throw "Modified developer module payload: $($module.Id)/$name"}
        }}finally{$zip.Dispose()}
        foreach($file in @(Get-TPBuildFiles $folder)){
            $relative=$file.FullName.Substring($folder.TrimEnd([IO.Path]::DirectorySeparatorChar).Length+1).Replace('\','/')
            if(-not$expected.Contains($relative)){throw "Unexpected file in developer module: $relative"}
        }
        $data=Import-PowerShellDataFile -LiteralPath (Join-Path $folder $module.Manifest) -ErrorAction Stop
        if([string]$data.ModuleVersion-cne$module.Version){throw "Wrong module version: $($module.Id)"}
    }
    foreach($notice in @($Lock.Notices)){
        $path=Join-Path $Root $notice.Target
        if(-not[IO.File]::Exists($path)-or(Get-TPBuildSha $path)-cne$notice.Sha256){throw "Missing/changed third-party notice: $($notice.Target)"}
    }
    $epplus=Join-Path $Root 'ImportExcel/7.8.10/EPPlus.dll'
    if((Get-TPBuildSha $epplus)-cne$Lock.EPPlus.BinarySha256-or[Reflection.AssemblyName]::GetAssemblyName($epplus).Version-ne[version]$Lock.EPPlus.Version){throw 'EPPlus binary identity does not match the licensed pinned source.'}
}
