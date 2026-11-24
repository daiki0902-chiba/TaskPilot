#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DependencyRoot,
    [string]$OutputRoot,
    [switch]$ValidateOnly,
    [switch]$InternalCompile
)
# Deliberately no release/unblock/skip-signature switch. This tool is an internal
# compiler, not a distribution authority. A missing signing/delivery ceremony
# must never turn into an unsigned ZIP that looks ready for a desktop tester.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
$repo=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
if($ValidateOnly-and$InternalCompile){throw 'Choose ValidateOnly or InternalCompile, not both.'}
if(-not$OutputRoot){$OutputRoot=Join-Path $repo 'artifacts/desktop-acceptance-internal'}
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $output
$dependency=Get-TPBuildFullPath $DependencyRoot
if((Test-TPBuildBelow $repo $output)-or((Test-TPBuildBelow $output $repo)-and-not(Test-TPBuildBelow $output (Join-Path $repo 'artifacts')))){throw 'OutputRoot must be repo/artifacts (or below) or a separate external directory.'}
if((Test-TPBuildBelow $output $dependency)-or(Test-TPBuildBelow $dependency $output)){throw 'Acceptance output and dependencies must be disjoint.'}
$entry=Join-Path $repo 'acceptance/TaskPilot.Acceptance.ps1'
Assert-TPBuildPowerShell $entry
$entryHash=Get-TPBuildSha $entry
$allowlistPath=Join-Path $repo 'build/desktop-acceptance-files.json'
Assert-TPBuildNoLinks $allowlistPath
$allowlist=Get-Content -LiteralPath $allowlistPath -Raw -Encoding UTF8|ConvertFrom-Json
if($allowlist.FormatVersion-ne1){throw 'Unsupported desktop acceptance runtime allowlist.'}
$extra=New-Object 'Collections.Generic.List[object]'
$extraSeen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($relative in @($allowlist.Files)){
    Assert-TPBuildRelative $relative
    if(($relative-cnotmatch'^acceptance/[A-Za-z0-9_.-]+$'-and$relative-cnotin@('tools/Test-TaskPilotDesktopAcceptance.ps1','tools/Collect-TaskPilotDesktopAcceptanceLogs.ps1'))-or-not$extraSeen.Add($relative)){throw 'Invalid/duplicate dedicated acceptance payload entry.'}
    $file=Join-Path $repo $relative
    Assert-TPBuildNoLinks $file
    if(-not[IO.File]::Exists($file)){throw ('Required acceptance payload is missing: '+$relative)}
    if([IO.Path]::GetExtension($file)-eq'.ps1'){Assert-TPBuildPowerShell $file}
    $extra.Add([pscustomobject]@{Source=$file;Path=$relative;Sha256=(Get-TPBuildSha $file);Component='Dedicated acceptance runtime'})
}
foreach($required in @('acceptance/TaskPilot.Acceptance.ps1','acceptance/TaskPilot.Acceptance.Runtime.ps1','acceptance/TaskPilot.Acceptance.Security.ps1','acceptance/trusted-publishers.json')){if(-not$extraSeen.Contains($required)){throw ('Dedicated acceptance allowlist is missing '+$required)}}
# Use the existing *read-only* dependency/payload validation, never the normal
# compiler. No TaskPilot.exe or normal startup source is produced/copied.
$baseline=& (Join-Path $PSScriptRoot 'Build-TaskPilot.ps1') -Version '0.4.0.2' -DependencyRoot $dependency -OutputRoot $output -ValidateOnly
$lock=Get-TPBuildLock (Join-Path $repo 'build/dependencies.lock.json')
$runtimeLock=Get-Content -LiteralPath (Join-Path $repo 'build/runtime-files.json') -Raw -Encoding UTF8|ConvertFrom-Json
$payload=New-Object 'Collections.Generic.List[object]'
$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($planned in @($baseline.PayloadManifest)){
    $relative=[string]$planned.Path;$from=$null
    if($relative-eq'README.md'){$from=Join-Path $repo 'docs/desktop-acceptance/README-ja.md'}
    elseif($runtimeLock.Files-contains$relative-or$relative.StartsWith('Assets/')){$from=Join-Path $repo $relative}
    elseif($relative.StartsWith('Modules/ImportExcel/')){$from=Join-Path $dependency ('ImportExcel/7.8.10/'+$relative.Substring('Modules/ImportExcel/'.Length))}
    elseif($relative-eq'ThirdPartyNotices/README.md'){$from=Join-Path $repo 'docs/build/THIRD-PARTY-NOTICES.md'}
    elseif($relative.StartsWith('ThirdPartyNotices/SQLite/')){$from=Join-Path $repo ('Modules/TaskPilot.Storage/provider/ThirdPartyNotices/'+[IO.Path]::GetFileName($relative))}
    elseif($relative.StartsWith('ThirdPartyNotices/')){
        $notice=@($lock.Notices|Where-Object {[IO.Path]::GetFileName($_.Target)-ceq[IO.Path]::GetFileName($relative)})
        if($notice.Count-ne1){throw 'Acceptance dependency notice has no unique pinned source.'}
        $from=Join-Path $dependency $notice[0].Target
    }elseif($relative.StartsWith('ThirdPartySources/')){$from=Join-Path $dependency ('Source/'+[IO.Path]::GetFileName($relative))}
    else{throw ('Unmapped acceptance payload source: '+$relative)}
    Assert-TPBuildNoLinks $from
    $hash=Get-TPBuildSha $from
    if($relative-ne'README.md'-and$hash-cne$planned.Sha256){throw ('Pinned acceptance payload mismatch: '+$relative)}
    if(-not$seen.Add($relative)){throw 'Duplicate baseline acceptance payload.'}
    $payload.Add([pscustomobject]@{Source=$from;Path=$relative;Sha256=$hash;Component=$planned.Component})
}
foreach($item in $extra){if(-not$seen.Add($item.Path)){throw 'Acceptance payload collides with the ordinary payload.'};$payload.Add($item)}
if(@($payload|Where-Object {$_.Path-match'(^|/)(TaskPilot\.exe|TaskPilot\.ps1)$|(^|/)(Data|Backup|Export|Logs|DeveloperSandbox|tests)(/|$)|\.(db|sqlite|bak|log|tmp)$'}).Count){throw 'A forbidden executable, user-data or developer file entered the acceptance payload.'}
# These originals are already verified against the checked-in provider pins and
# locked upstream dependency archives by the normal read-only validator above.
# Do not re-sign them: that would invalidate their reviewed original byte hashes.
# The generated lock is itself covered by the purpose-bound CMS payload digest.
$vendorCode=@($payload|Where-Object {
    $_.Path-cin@('Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll')-or
    ($_.Path.StartsWith('Modules/ImportExcel/',[StringComparison]::Ordinal)-and[IO.Path]::GetExtension($_.Path)-cin@('.dll','.ps1','.psm1','.psd1'))
}|ForEach-Object {[pscustomobject]@{Path=$_.Path;Sha256=$_.Sha256}})
if($vendorCode.Count-lt4){throw 'Original vendor-code lock is incomplete.'}
$result=[ordered]@{
    Status='BLOCKED';Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2'
    GeneralDistributionBlocked=$true;IndependentTestModeDistributionBlocked=$true
    Distributable=$false;Zip=$null;ExecutableGenerated=$false;OutputCreated=$false
    SourceSha256=$entryHash;PayloadFiles=$payload.Count
    PayloadManifest=@($payload.ToArray()|Select-Object Path,Sha256,Component)
    ExpectedGeneratedPaths=@('TaskPilot.Acceptance.exe','TaskPilot.Acceptance.exe.config','Runtime/TaskPilot.TestSandbox.dll','Codec/TaskPilotMigrationCodec.dll','acceptance/vendor-code-lock.json','AcceptanceBuildInfo.json','AcceptancePayload.json','INTERNAL_ONLY_DO_NOT_DISTRIBUTE.txt')
    OriginalVendorCode=@($vendorCode)
    MissingConditions=@('Trusted publisher certificate and pinned identity','Signed purpose-bound acceptance authorization','Signed payload and safe download-origin qualification','Windows 10/11 desktop preflight and interactive acceptance')
    WindowsDesktopExecutionVerified=$false;ProductionProfileAccessed=$false
}
if(-not$InternalCompile){return [pscustomobject]$result}
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Internal acceptance EXE compilation requires x64 Windows PowerShell Desktop 5.1. No EXE was generated.'}
$framework=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
if([long]$framework.Release-lt393295){throw '.NET Framework4.6 or newer is required.'}
if(-not[IO.Directory]::Exists($output)){$null=[IO.Directory]::CreateDirectory($output)}
$buildId=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N')
$internalRoot=Join-Path $output ('TaskPilot.Acceptance_INTERNAL_'+$buildId)
if(Test-TPBuildPathExists $internalRoot){throw 'Internal acceptance output already exists.'}
$null=[IO.Directory]::CreateDirectory($internalRoot)
$stage=Join-Path $internalRoot 'TaskPilot.Acceptance';$null=[IO.Directory]::CreateDirectory($stage)
Write-TPBuildNewText (Join-Path $internalRoot 'INTERNAL_ONLY_DO_NOT_DISTRIBUTE.txt') 'BLOCKED. Unsigned internal negative-test build. Not an authorized desktop acceptance package. Never upload this directory or create a distributable ZIP.'
foreach($item in $payload){Copy-TPBuildNewFile $item.Source (Join-Path $stage $item.Path) $item.Sha256}
Write-TPBuildNewText (Join-Path $stage 'acceptance/vendor-code-lock.json') (ConvertTo-Json -InputObject ([ordered]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Files=$vendorCode}) -Depth 6)
$runtime=& (Join-Path $PSScriptRoot 'Build-TaskPilotRuntime.ps1') -OutputDirectory (Join-Path $internalRoot '.runtime-compile')
$codec=& (Join-Path $PSScriptRoot 'Build-TaskPilotRuntime.ps1') -Component Codec -OutputDirectory (Join-Path $internalRoot '.codec-compile')
Copy-TPBuildNewFile $runtime.AssemblyPath (Join-Path $stage 'Runtime/TaskPilot.TestSandbox.dll') $runtime.Sha256
Copy-TPBuildNewFile $codec.AssemblyPath (Join-Path $stage 'Codec/TaskPilotMigrationCodec.dll') $codec.Sha256
$exe=Join-Path $stage 'TaskPilot.Acceptance.exe'
$launcherSource=Join-Path $repo 'acceptance/TaskPilot.Acceptance.Launcher.cs'
$guardSource=Join-Path $repo 'acceptance/TaskPilot.Acceptance.PackageGuard.cs'
foreach($compilerSource in @($launcherSource,$guardSource)){Assert-TPBuildNoLinks $compilerSource;if(-not[IO.File]::Exists($compilerSource)){throw 'The native acceptance launcher source is missing.'}}
$launcherHash=Get-TPBuildSha $launcherSource;$guardHash=Get-TPBuildSha $guardSource
$trustHash=Get-TPBuildSha (Join-Path $stage 'acceptance/trusted-publishers.json')
$trust=Get-Content -LiteralPath (Join-Path $stage 'acceptance/trusted-publishers.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($trust.FormatVersion-ne1-or$trust.Purpose-cne'DesktopAcceptanceSyntheticOnly'){throw 'Dedicated launcher trust configuration has an incompatible purpose.'}
$pins=@($trust.AllowedPublisherThumbprints)
if($pins.Count-gt4){throw 'Dedicated launcher publisher allowlist is unexpectedly large.'}
$uniquePins=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach($pin in $pins){if($pin-isnot[string]-or$pin-cnotmatch'^[A-F0-9]{40}$'-or-not$uniquePins.Add($pin)){throw 'Publisher pins must be distinct uppercase 40-character certificate thumbprints.'}}
$launcherText=[IO.File]::ReadAllText($launcherSource).Replace('@@TRUST_SHA256@@',$trustHash).Replace('@@TRUST_THUMBPRINTS@@',($pins-join';'))
if($launcherText.Contains('@@TRUST_')){throw 'Dedicated launcher trust placeholders were not fully substituted.'}
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters=New-Object CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable=$true;$parameters.GenerateInMemory=$false
$parameters.OutputAssembly=$exe;$parameters.IncludeDebugInformation=$false
$parameters.CompilerOptions='/target:winexe /platform:x64 /optimize+'
$parameters.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($internalRoot,$false)
foreach($reference in @('mscorlib.dll','System.dll','System.Core.dll','System.Security.dll','System.Windows.Forms.dll','System.Drawing.dll',([System.Management.Automation.PowerShell].Assembly.Location))){$null=$parameters.ReferencedAssemblies.Add($reference)}
try{
    $metadata='[assembly:System.Reflection.AssemblyVersion("0.4.0.2")][assembly:System.Reflection.AssemblyFileVersion("0.4.0.2")][assembly:System.Reflection.AssemblyTitle("TaskPilot Acceptance")][assembly:System.Reflection.AssemblyProduct("TaskPilot Acceptance")][assembly:System.Reflection.AssemblyCompany("TaskPilot")]'
    $compiled=$compiler.CompileAssemblyFromSource($parameters,[string[]]@($launcherText,[IO.File]::ReadAllText($guardSource),$metadata))
    if($compiled.Errors.HasErrors){throw ('Acceptance launcher compilation failed: '+(($compiled.Errors|ForEach-Object {$_.ToString()})-join[Environment]::NewLine))}
}finally{$compiler.Dispose()}
Assert-TPBuildWindowsX64GuiExe $exe
if((Get-TPBuildSha $entry)-cne$entryHash-or(Get-TPBuildSha $launcherSource)-cne$launcherHash-or(Get-TPBuildSha $guardSource)-cne$guardHash){throw 'Acceptance entry or native launcher source changed during compilation.'}
Write-TPBuildNewText ($exe+'.config') '<?xml version="1.0" encoding="utf-8"?><configuration><startup useLegacyV2RuntimeActivationPolicy="true"><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.6"/></startup><runtime><loadFromRemoteSources enabled="false"/></runtime></configuration>'
if([IO.File]::Exists((Join-Path $stage 'TaskPilot.exe'))){throw 'The ordinary executable must never be emitted in the acceptance package.'}
$result.ExecutableGenerated=$true;$result.OutputCreated=$true
$result['InternalRoot']=$internalRoot;$result['PackageRoot']=$stage;$result['Executable']=$exe
$result['ExecutableSha256']=Get-TPBuildSha $exe;$result['SignatureStatus']=[string](Get-AuthenticodeSignature -FilePath $exe).Status
$result['RuntimeGuardSha256']=$runtime.Sha256;$result['CodecRuntimeSha256']=$codec.Sha256
$result['LauncherSourceSha256']=$launcherHash;$result['PackageGuardSourceSha256']=$guardHash
$result['TrustConfigurationSha256']=$trustHash
# Local bookkeeping intentionally does not grant permission to launch. The
# runtime requires its independently signed authorization and refuses this build.
Write-TPBuildNewText (Join-Path $stage 'AcceptanceBuildInfo.json') (ConvertTo-Json -InputObject $result -Depth 12)
$files=@(Get-TPBuildFiles $stage|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($stage.Length+1).Replace('\','/');Sha256=(Get-TPBuildSha $_.FullName)}})
Write-TPBuildNewText (Join-Path $stage 'AcceptancePayload.json') (ConvertTo-Json -InputObject ([ordered]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2';Files=$files}) -Depth 8)
return [pscustomobject]$result
