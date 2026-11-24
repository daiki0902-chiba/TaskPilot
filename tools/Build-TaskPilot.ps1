#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
    [Parameter(Mandatory=$true)][string]$DependencyRoot,
    [string]$OutputRoot,
    [string]$CustomerReadmePath,
    [string]$EulaPath,
    [string]$CompanyName='TaskPilot',
    [string]$CopyrightText,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer,
    [switch]$RequireSignature,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
$stageRoot=$null;$releaseRoot=$null;$zipStage=$null;$zipFinal=$null
try{
    $parsedVersion=[version]$Version
    foreach($part in @($parsedVersion.Major,$parsedVersion.Minor,$parsedVersion.Build,$parsedVersion.Revision)){if($part-gt65535){throw 'Each Windows version component must be <=65535.'}}
    if(-not$ValidateOnly){
        if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or[Environment]::Is64BitProcess-ne$true){throw 'EXE build requires 64-bit Windows PowerShell5.1 on Windows. No EXE was generated. Use -ValidateOnly for static checks on another platform.'}
        $framework=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
        if([long]$framework.Release-lt393295){throw '.NET Framework4.6 or newer is required;4.8 is recommended.'}
    }
    $dependency=Get-TPBuildFullPath $DependencyRoot
    $lockPath=Join-Path $repo 'build/dependencies.lock.json';$lock=Get-TPBuildLock $lockPath
    Assert-TPBuildDependencyTree $dependency $lock
    if(-not$OutputRoot){$OutputRoot=Join-Path $repo 'artifacts'}
    $output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
    if((Test-TPBuildBelow $repo $output)-or((Test-TPBuildBelow $output $repo)-and-not(Test-TPBuildBelow $output (Join-Path $repo 'artifacts')))){throw 'OutputRoot must be repo/artifacts (or below) or a separate external directory, never a source directory/ancestor.'}
    if((Test-TPBuildBelow $output $dependency)-or(Test-TPBuildBelow $dependency $output)){throw 'Build output and developer dependency directories must be disjoint.'}
    if(-not$CustomerReadmePath){$CustomerReadmePath=Join-Path $repo 'docs/user/README.md'}
    $customerReadme=Get-TPBuildFullPath $CustomerReadmePath
    if(-not[IO.File]::Exists($customerReadme)){throw 'Customer README is missing. Set -CustomerReadmePath to the final purchaser-facing document.'}
    $eula=$null;if($EulaPath){$eula=Get-TPBuildFullPath $EulaPath;if(-not[IO.File]::Exists($eula)){throw 'EulaPath is missing.'}}
    $source=Join-Path $repo 'TaskPilot.ps1';Assert-TPBuildNoLinks $source;Assert-TPBuildPowerShell $source
    $sourceHash=Get-TPBuildSha $source
    $payload=New-Object 'Collections.Generic.List[object]'
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    function Add-Payload([string]$From,[string]$To,[string]$Component){
        Assert-TPBuildRelative $To;Assert-TPBuildNoLinks $From
        if(-not[IO.File]::Exists($From)){throw "Required payload file is missing: $From"}
        if(-not$seen.Add($To)){throw "Duplicate product payload path: $To"}
        $payload.Add([pscustomobject]@{Source=$From;Path=$To;Component=$Component;Sha256=Get-TPBuildSha $From})
    }
    $runtimeLockPath=Join-Path $repo 'build/runtime-files.json'
    Assert-TPBuildNoLinks $runtimeLockPath
    $runtimeLock=Get-Content -LiteralPath $runtimeLockPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($runtimeLock.FormatVersion-ne1){throw 'Unsupported runtime allowlist format.'}
    $runtimeFiles=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in @($runtimeLock.Files)){
        Assert-TPBuildRelative $relative
        if(-not$runtimeFiles.Add($relative)){throw "Duplicate runtime allowlist path: $relative"}
        if($relative-notmatch'^(Adapters/|Modules/TaskPilot\.Storage/|Codec/|schema/|Runtime/)'){throw 'Runtime allowlist contains a path outside the product runtime directories.'}
        Add-Payload (Join-Path $repo $relative) $relative 'TaskPilot'
        if([IO.Path]::GetExtension($relative)-in@('.ps1','.psm1','.psd1')){Assert-TPBuildPowerShell (Join-Path $repo $relative)}
    }
    foreach($required in @('Adapters/TaskPilot.GuiStartup.ps1','Adapters/TaskPilot.GuiIsolation.ps1','Runtime/TaskPilot.Runtime.ps1','Modules/TaskPilot.Storage/TaskPilot.Storage.psd1','Modules/TaskPilot.Storage/TaskPilot.Storage.psm1','Codec/Import-TaskPilotMigrationCodec.ps1','Codec/TaskPilotMigrationCodec.cs','schema/001_initial.sql')){if(-not$runtimeFiles.Contains($required)){throw "Required runtime path absent from allowlist: $required"}}
    foreach($folder in @('Adapters','Modules/TaskPilot.Storage')){
        $from=Join-Path $repo $folder
        if(-not[IO.Directory]::Exists($from)){throw "Required product runtime directory is missing: $folder"}
        $count=0
        foreach($file in @(Get-TPBuildFiles $from)){
            $relative=$file.FullName.Substring($from.Length+1).Replace('\','/')
            if(-not$runtimeFiles.Contains($folder+'/'+$relative)){throw "Unexpected/developer-only file in runtime directory: $folder/$relative. Review the runtime allowlist explicitly."}
            $count++
        }
        if($count-eq0){throw "Runtime directory is empty: $folder"}
    }
    Add-Payload $customerReadme 'README.md' 'TaskPilot'
    Add-Payload (Join-Path $repo 'docs/build/THIRD-PARTY-NOTICES.md') 'ThirdPartyNotices/README.md' 'Dependency notices'
    if($eula){Add-Payload $eula 'EULA.md' 'TaskPilot'}
    if([IO.Directory]::Exists((Join-Path $repo 'Assets'))){foreach($file in @(Get-TPBuildFiles (Join-Path $repo 'Assets'))){if($file.Extension-notin@('.png','.jpg','.jpeg','.ico','.svg','.json','.txt')){throw 'Unexpected product asset extension.'};Add-Payload $file.FullName ('Assets/'+$file.FullName.Substring((Join-Path $repo 'Assets').Length+1).Replace('\','/')) 'TaskPilot'}}
    $importRoot=Join-Path $dependency 'ImportExcel/7.8.10'
    foreach($file in @(Get-TPBuildFiles $importRoot)){
        $relative=$file.FullName.Substring($importRoot.Length+1).Replace('\','/')
        # Preserve every runtime module file/resource; upstream example data and
        # NuGet container metadata are provided in the complete original archive.
        if($relative-match'(?i)^(Examples/|_rels/|package/)' -or $relative-in@('ImportExcel.nuspec','[Content_Types].xml','.signature.p7s')){continue}
        Add-Payload $file.FullName ('Modules/ImportExcel/'+$relative) 'ImportExcel'
    }
    foreach($notice in @($lock.Notices)){Add-Payload (Join-Path $dependency $notice.Target) ('ThirdPartyNotices/'+[IO.Path]::GetFileName($notice.Target)) 'Dependency notices'}
    Add-Payload (Join-Path $dependency 'Source/EPPlus-4.5.3.2-source-4dacf276.zip') 'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip' 'EPPlus corresponding source'
    $providerRoot=Join-Path $repo 'Modules/TaskPilot.Storage/provider'
    $providerPins=Get-Content -LiteralPath (Join-Path $providerRoot 'provider-files.sha256.json') -Raw -Encoding UTF8|ConvertFrom-Json
    foreach($entry in $providerPins.PSObject.Properties){Assert-TPBuildRelative $entry.Name;if((Get-TPBuildSha (Join-Path $providerRoot $entry.Name))-ine[string]$entry.Value){throw "Bundled SQLite provider hash failed: $($entry.Name)"}}
    foreach($required in @('System.Data.SQLite.dll','x86/SQLite.Interop.dll','x64/SQLite.Interop.dll')){if($null-eq$providerPins.PSObject.Properties[$required]){throw 'SQLite provider manifest lacks a required architecture.'}}
    foreach($file in @(Get-TPBuildFiles (Join-Path $providerRoot 'ThirdPartyNotices'))){Add-Payload $file.FullName ('ThirdPartyNotices/SQLite/'+$file.Name) 'SQLite notices'}
    if($RequireSignature-and-not$SigningCertificateThumbprint){throw 'RequireSignature needs an existing developer code-signing certificate thumbprint; no certificate will be fabricated.'}
    $runtimeSource=Join-Path $repo 'Runtime/TaskPilot.TestSandbox.cs';Assert-TPBuildNoLinks $runtimeSource
    $runtimeSourceHash=Get-TPBuildSha $runtimeSource
    $codecSourceHash=Get-TPBuildSha (Join-Path $repo 'Codec/TaskPilotMigrationCodec.cs')
    if($ValidateOnly){return [pscustomobject]@{Validated=$true;Version=$Version;Architecture='x64';PayloadFiles=$payload.Count;PayloadManifest=@($payload.ToArray()|Select-Object Path,Component,Sha256);ExpectedGeneratedPaths=@('TaskPilot.exe','TaskPilot.exe.config','Runtime/TaskPilot.TestSandbox.dll','Codec/TaskPilotMigrationCodec.dll','BuildInfo.json','SoftwareBillOfMaterials.json','FileHashes.json');SourceSha256=$sourceHash;RuntimeGuardSourceSha256=$runtimeSourceHash;DependencyLockSha256=Get-TPBuildSha $lockPath;RuntimeAllowlistSha256=Get-TPBuildSha $runtimeLockPath;ExecutableGenerated=$false;WindowsExecutionVerified=$false;OutputCreated=$false}}
    $certificate=$null
    if($SigningCertificateThumbprint){
        $thumb=$SigningCertificateThumbprint.Replace(' ','')
        $certificate=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$thumb) -ErrorAction Stop
        if(-not$certificate.HasPrivateKey-or[datetime]::Now-lt$certificate.NotBefore-or[datetime]::Now-gt$certificate.NotAfter){throw 'Code-signing certificate lacks a usable private key or is not currently valid.'}
    }
    if(-not[IO.Directory]::Exists($output)){$null=[IO.Directory]::CreateDirectory($output)}
    $buildId=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $base='TaskPilot_'+$Version+'_Windows_x64_'+$buildId
    $stageRoot=Join-Path $output ('.stage_'+$buildId);$releaseRoot=Join-Path $output $base
    $zipStage=Join-Path $output ('.package_'+$buildId+'.tmp');$zipFinal=Join-Path $output ($base+'.zip')
    foreach($new in @($stageRoot,$releaseRoot,$zipStage,$zipFinal,($zipFinal+'.sha256'))){if(Test-TPBuildPathExists $new){throw 'Unique build output unexpectedly exists; no output will be overwritten.'}}
    $stage=Join-Path $stageRoot 'TaskPilot';$null=[IO.Directory]::CreateDirectory($stage)
    foreach($entry in $payload){Copy-TPBuildNewFile $entry.Source (Join-Path $stage $entry.Path) $entry.Sha256}
    # Build the guard once during packaging. Test-mode startup loads the DLL
    # without CodeDom files being created before its isolated TEMP is selected.
    $runtimeCompiled=& (Join-Path $PSScriptRoot 'Build-TaskPilotRuntime.ps1') -OutputDirectory (Join-Path $output ('.runtime_'+$buildId))
    if(-not$runtimeCompiled.Compiled-or$runtimeCompiled.SourceSha256-cne$runtimeSourceHash){throw 'Runtime guard compiler result does not match its reviewed source.'}
    Copy-TPBuildNewFile $runtimeCompiled.AssemblyPath (Join-Path $stage 'Runtime/TaskPilot.TestSandbox.dll') $runtimeCompiled.Sha256
    $codecCompiled=& (Join-Path $PSScriptRoot 'Build-TaskPilotRuntime.ps1') -Component Codec -OutputDirectory (Join-Path $output ('.codec_'+$buildId))
    if(-not$codecCompiled.Compiled-or$codecCompiled.SourceSha256-cne$codecSourceHash){throw 'Precompiled codec does not match its source.'}
    Copy-TPBuildNewFile $codecCompiled.AssemblyPath (Join-Path $stage 'Codec/TaskPilotMigrationCodec.dll') $codecCompiled.Sha256
    # Import only the explicitly provisioned, hash-verified compiler module.
    $compiler=Import-Module -Name (Join-Path $dependency 'ps2exe/1.0.17/ps2exe.psd1') -Force -PassThru -ErrorAction Stop
    if([string]$compiler.Version-ne'1.0.17'){throw 'Unexpected compiler version.'}
    $exe=Join-Path $stage 'TaskPilot.exe'
    $compile=@{inputFile=$source;outputFile=$exe;noConsole=$true;STA=$true;x64=$true;DPIAware=$true;configFile=$true;title='TaskPilot';product='TaskPilot';company=$CompanyName;version=$Version}
    if($CopyrightText){$compile.copyright=$CopyrightText}
    Invoke-ps2exe @compile
    if(-not[IO.File]::Exists($exe)-or([IO.FileInfo]$exe).Length-lt512){throw 'Compiler did not produce a non-empty EXE.'}
    Assert-TPBuildWindowsX64GuiExe $exe
    $versionInfo=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    if([version]$versionInfo.FileVersion-ne$parsedVersion-or$versionInfo.ProductName-ne'TaskPilot'){throw 'Generated EXE metadata does not match requested product/version.'}
    if((Get-TPBuildSha $source)-cne$sourceHash){throw 'Entrypoint changed while compiling. Build retained for investigation, never published.'}
    $signatureStatus='NotSigned'
    if($null-ne$certificate){
        $sign=@{FilePath=$exe;Certificate=$certificate;HashAlgorithm='SHA256';ErrorAction='Stop'}
        if($TimestampServer){$sign.TimestampServer=$TimestampServer}
        $null=Set-AuthenticodeSignature @sign
        $signature=Get-AuthenticodeSignature -FilePath $exe -ErrorAction Stop
        if($signature.Status-ne'Valid'){throw ('EXE signature verification failed: '+$signature.Status)}
        $signatureStatus='Valid'
    }elseif($RequireSignature){throw 'A valid signature was required.'}
    $buildInfo=[ordered]@{Product='TaskPilot';Version=$Version;Architecture='x64';BuiltAtUtc=[datetime]::UtcNow.ToString('o');BuildId=$buildId;PowerShell=$PSVersionTable.PSVersion.ToString();Clr=[Environment]::Version.ToString();SourceSha256=$sourceHash;RuntimeGuardSourceSha256=$runtimeSourceHash;RuntimeGuardSha256=$runtimeCompiled.Sha256;IndependentTestModeImplemented=$true;IndependentTestModeSupported=$false;IndependentTestModeReleaseBlocked=$true;DependencyLockSha256=Get-TPBuildSha $lockPath;RuntimeAllowlistSha256=Get-TPBuildSha $runtimeLockPath;Compiler='ps2exe1.0.17';ImportExcel='7.8.10';EPPlus='4.5.3.2';SQLiteProvider='1.0.119.0';SignatureStatus=$signatureStatus;RuntimeTestsExecutedByBuilder=$false;Windows10And11Acceptance='Not performed by build script';StartupDownloads=$false}
    $buildInfo['CodecSourceSha256']=$codecSourceHash
    $buildInfo['CodecRuntimeSha256']=$codecCompiled.Sha256
    Write-TPBuildNewText (Join-Path $stage 'BuildInfo.json') (ConvertTo-Json -InputObject $buildInfo -Depth 8)
    $componentByPath=@{};foreach($entry in $payload){$componentByPath[$entry.Path]=$entry.Component}
    $componentByPath['TaskPilot.exe']='TaskPilot / ps2exe generated loader'
    $sbomFiles=@(Get-TPBuildFiles $stage|ForEach-Object{
        $relative=$_.FullName.Substring($stage.Length+1).Replace('\','/')
        $component=if($componentByPath.ContainsKey($relative)){$componentByPath[$relative]}else{'Generated runtime configuration/build metadata'}
        [pscustomobject]@{Path=$relative;Component=$component;Sha256=Get-TPBuildSha $_.FullName}
    })
    $licenseFiles=@(Get-TPBuildFiles (Join-Path $stage 'ThirdPartyNotices')|ForEach-Object{$_.FullName.Substring($stage.Length+1).Replace('\','/')})
    $sbom=[ordered]@{Format='TaskPilot software bill of materials v1';SelfAndFileHashesExcluded=$true;Components=@([ordered]@{Name='ps2exe generated loader';Version='1.0.17';License='MS-LPL-1.1'},[ordered]@{Name='ImportExcel';Version='7.8.10';License='Apache-2.0'},[ordered]@{Name='EPPlus';Version='4.5.3.2';License='LGPL-3.0-or-later';SourceCommit=$lock.EPPlus.SourceCommit;ReplaceableAtRuntime=$true},[ordered]@{Name='DotNetZip / managed-zlib / JCraft';License='MS-PL / retained BSD-style notices'},[ordered]@{Name='System.Data.SQLite.Core';Version='1.0.119.0';License='Public-domain declaration'},[ordered]@{Name='SQLite';Version='3.46.1';License='Public-domain declaration'},[ordered]@{Name='SQLite native zlib';Version='1.3.1';License='Zlib'});Files=$sbomFiles;LicenseFiles=$licenseFiles;DependencyLock=$lock;RuntimeAllowlist=$runtimeLock}
    Write-TPBuildNewText (Join-Path $stage 'SoftwareBillOfMaterials.json') (ConvertTo-Json -InputObject $sbom -Depth 16)
    $manifest=@(Get-TPBuildFiles $stage|ForEach-Object{[pscustomobject]@{Path=$_.FullName.Substring($stage.Length+1).Replace('\','/');Bytes=$_.Length;Sha256=Get-TPBuildSha $_.FullName}})
    Write-TPBuildNewText (Join-Path $stage 'FileHashes.json') (ConvertTo-Json -InputObject ([ordered]@{FormatVersion=1;SelfExcluded=$true;Files=$manifest}) -Depth 8)
    [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot,$zipStage,[IO.Compression.CompressionLevel]::Optimal,$false)
    # Verify every archive file against the completed stage, including FileHashes.
    $zip=[IO.Compression.ZipFile]::OpenRead($zipStage);$archived=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try{
        foreach($entry in $zip.Entries){if($entry.FullName.EndsWith('/')){continue};$name=$entry.FullName.Replace('\','/');Assert-TPBuildRelative $name;if(-not$archived.Add($name)){throw 'Duplicate ZIP entry.'};$file=Join-Path $stageRoot $name;if(-not[IO.File]::Exists($file)){throw 'Unexpected ZIP file.'};$reader=$entry.Open();try{$archiveHash=Get-TPBuildStreamSha $reader}finally{$reader.Dispose()};if($archiveHash-cne(Get-TPBuildSha $file)){throw 'ZIP content verification failed.'}}
        if($archived.Count-ne@(Get-TPBuildFiles $stageRoot).Count){throw 'ZIP file count mismatch.'}
    }finally{$zip.Dispose()}
    [IO.Directory]::Move($stageRoot,$releaseRoot)
    [IO.File]::Move($zipStage,$zipFinal)
    $zipSha=Get-TPBuildSha $zipFinal
    Write-TPBuildNewText ($zipFinal+'.sha256') ($zipSha+'  '+[IO.Path]::GetFileName($zipFinal)+"`n")
    [pscustomobject]@{ReleaseRoot=$releaseRoot;Zip=$zipFinal;Sha256=$zipSha;SignatureStatus=$signatureStatus;ExecutableGenerated=$true;RuntimeAcceptance='Not run: complete Windows checklist before sales distribution.'}
}catch{
    throw "Build stopped. Existing releases were not overwritten. New partial output, if any, is retained for review (stage='$stageRoot', release='$releaseRoot', archive='$zipStage'). $($_.Exception.Message)"
}
