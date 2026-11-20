#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DestinationRoot,[string]$PackageCache,[switch]$Offline)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo=Split-Path -Parent $PSScriptRoot
$lockPath=Join-Path $repo 'build/dependencies.lock.json';$lock=Get-TPBuildLock $lockPath
$destination=Get-TPBuildFullPath $DestinationRoot;Assert-TPBuildNoLinks $destination
if(Test-TPBuildPathExists $destination){throw 'Dependency destination already exists. Choose a NEW developer directory; no module or system setting is installed/overwritten.'}
if(-not[IO.Directory]::Exists([IO.Path]::GetDirectoryName($destination))){throw 'Dependency destination parent must already exist.'}
if(Test-TPBuildBelow $destination (Join-Path $repo 'Modules')){throw 'Developer build dependencies must not be placed in product Modules.'}
$cache=if($PackageCache){Get-TPBuildFullPath $PackageCache}else{$null}
if($cache){Assert-TPBuildNoLinks $cache;if(-not[IO.Directory]::Exists($cache)){throw 'PackageCache is not a directory.'}}
$oldTls=[Net.ServicePointManager]::SecurityProtocol
try{
    # This setting affects this developer process only, and is restored below.
    [Net.ServicePointManager]::SecurityProtocol=$oldTls-bor[Net.SecurityProtocolType]::Tls12
    $null=New-Item -ItemType Directory -Path $destination -ErrorAction Stop
    foreach($item in @($lock.Downloads)){
        Assert-TPBuildRelative $item.Target
        $target=Join-Path $destination $item.Target
        $cached=if($cache){Join-Path $cache $item.FileName}else{$null}
        if($cached-and[IO.File]::Exists($cached)){
            Copy-TPBuildNewFile $cached $target $item.Sha256
        }else{
            if($Offline){throw "Offline cache lacks $($item.FileName). Partial dependency folder is retained: $destination"}
            $parent=[IO.Path]::GetDirectoryName($target);if(-not[IO.Directory]::Exists($parent)){$null=[IO.Directory]::CreateDirectory($parent)}
            if(Test-TPBuildPathExists $target){throw 'Unexpected existing dependency download target.'}
            Invoke-WebRequest -Uri $item.Url -UseBasicParsing -OutFile $target -ErrorAction Stop
            if((Get-TPBuildSha $target)-cne$item.Sha256){throw "Downloaded dependency hash does not match pinned lock: $($item.FileName). Nothing was executed."}
        }
    }
    foreach($module in @($lock.Modules)){Expand-TPBuildPackage (Join-Path $destination $module.ArchiveTarget) (Join-Path $destination $module.ExtractTarget)}
    foreach($notice in @($lock.Notices)){
        $target=Join-Path $destination $notice.Target
        switch($notice.Kind){
            'Download' {}
            'Windows1252ToUtf8' {
                $original=Join-Path $destination $notice.Source
                $text=[Text.Encoding]::GetEncoding(1252).GetString([IO.File]::ReadAllBytes($original))
                Write-TPBuildNewText $target $text
            }
            'ArchiveCopy' {
                $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $destination $notice.Archive))
                try{$entry=$zip.GetEntry($notice.Entry);if($null-eq$entry){throw 'Pinned license entry is missing.'};$stream=$entry.Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);Write-TPBuildNewBytes $target $memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()}}finally{$zip.Dispose()}
            }
            'SourceHeader' {
                $archive=Join-Path $destination $notice.Archive;$zip=[IO.Compression.ZipFile]::OpenRead($archive)
                try{
                    $entry=$zip.GetEntry($notice.Entry);if($null-eq$entry){throw 'Pinned source notice entry is missing.'}
                    $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8,$true)
                    try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
                    $header=($text-split'(?m)^using System;',2)[0]
                    $document=$notice.Title+"`n"+'Source commit: '+$notice.SourceCommit+"`n"+'Source archive: '+$notice.SourceUrl+"`n"+'Source archive SHA256: '+(Get-TPBuildSha $archive)+"`n"+'Source archive entry: '+$notice.Entry+"`n`n"+$header
                    Write-TPBuildNewText $target $document
                }finally{$zip.Dispose()}
            }
            default{throw 'Unknown locked notice transformation.'}
        }
        if((Get-TPBuildSha $target)-cne$notice.Sha256){throw "Pinned notice verification failed: $($notice.Target)"}
    }
    Assert-TPBuildDependencyTree $destination $lock
    $receipt=[ordered]@{FormatVersion=1;PreparedAtUtc=[datetime]::UtcNow.ToString('o');DependencyLockSha256=Get-TPBuildSha $lockPath;InstalledToSystem=$false;ExecutedDownloadedCode=$false;Files=@(Get-TPBuildFiles $destination|ForEach-Object{[pscustomobject]@{Path=$_.FullName.Substring($destination.Length+1).Replace('\','/');Sha256=Get-TPBuildSha $_.FullName}})}
    Write-TPBuildNewText (Join-Path $destination 'dependency-receipt.json') (ConvertTo-Json -InputObject $receipt -Depth 8)
    [pscustomobject]@{DependencyRoot=$destination;Verified=$true;Modules=@($lock.Modules|Select-Object Id,Version);SystemModulesInstalled=$false;ExecutableGenerated=$false}
}catch{throw "Developer dependency preparation failed; original packages/system settings were not modified and partial output is retained at '$destination'. $($_.Exception.Message)"}
finally{[Net.ServicePointManager]::SecurityProtocol=$oldTls}
