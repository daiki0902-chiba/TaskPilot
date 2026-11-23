#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DependencyRoot,
    [string]$OutputRoot,
    [switch]$ValidateOnly,
    [switch]$InternalCompile
)
# A blocked internal compiler. No launch, publish, trust-store, policy,
# certificate, signing-key, receipt or distribution-archive operation exists.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
function Assert-TPLocalBuildInputOrigin([string]$Path){
    # The shared copy helper copies the main stream. Refuse an input carrying
    # any origin stream rather than silently dropping it into a new package.
    # This checker never deletes/rewrites ADS and never treats absence as trust.
    if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
        $streams=@(Get-Item -LiteralPath $Path -Stream '*' -ErrorAction Stop)
        if(@($streams|Where-Object {$_.Stream-ieq'Zone.Identifier'}).Count-ne0){throw 'Local build input has download-origin metadata; it is preserved and preparation remains blocked.'}
    }
}
$repo=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
if($ValidateOnly-and$InternalCompile){throw 'Choose ValidateOnly or InternalCompile, not both.'}
if(-not$OutputRoot){$OutputRoot=Join-Path $repo 'artifacts/local-validation-internal'}
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
$dependency=Get-TPBuildFullPath $DependencyRoot
if((Test-TPBuildBelow $repo $output)-or((Test-TPBuildBelow $output $repo)-and-not(Test-TPBuildBelow $output (Join-Path $repo 'artifacts')))){throw 'OutputRoot must be repo/artifacts (or below) or a separate external directory.'}
if((Test-TPBuildBelow $output $dependency)-or(Test-TPBuildBelow $dependency $output)){throw 'Local validation output and dependencies must be disjoint.'}
$entry=Join-Path $repo 'local-validation/TaskPilot.LocalValidation.ps1';Assert-TPBuildNoLinks $entry;Assert-TPBuildPowerShell $entry
Assert-TPLocalBuildInputOrigin $entry
$entryHash=Get-TPBuildSha $entry
$localLockPath=Join-Path $repo 'build/local-validation-files.json';Assert-TPBuildNoLinks $localLockPath
$localLock=Get-Content -LiteralPath $localLockPath -Raw -Encoding UTF8|ConvertFrom-Json
if($localLock.FormatVersion-ne1-or$localLock.Purpose-cne'LocalDeveloperValidationSyntheticOnly'){throw 'Unsupported local validation payload allowlist.'}
$extras=New-Object 'Collections.Generic.List[object]';$extraSeen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($relative in @($localLock.Files)){
    Assert-TPBuildRelative $relative
    if(($relative-cnotmatch'^local-validation/[A-Za-z0-9_.-]+\.ps1$'-and$relative-cne'tools/Test-TaskPilotLocalValidation.ps1')-or-not$extraSeen.Add($relative)){throw 'Invalid or duplicate local validation payload entry.'}
    $file=Join-Path $repo $relative;Assert-TPBuildNoLinks $file
    if(-not[IO.File]::Exists($file)){throw ('Required local validation runtime is missing: '+$relative)}
    Assert-TPLocalBuildInputOrigin $file
    Assert-TPBuildPowerShell $file
    $extras.Add([pscustomobject]@{Source=$file;Path=$relative;Sha256=(Get-TPBuildSha $file);Component='Local validation runtime'})
}
foreach($required in @('local-validation/TaskPilot.LocalValidation.ps1','local-validation/TaskPilot.LocalValidation.Runtime.ps1','local-validation/TaskPilot.LocalValidation.Gui.ps1','local-validation/TaskPilot.LocalValidation.Diagnostics.ps1','tools/Test-TaskPilotLocalValidation.ps1')){if(-not$extraSeen.Contains($required)){throw ('The local validation allowlist is missing '+$required)}}
# The ordinary validator checks reviewed upstream bytes without compiling an
# ordinary executable or creating any output. Reconstruct only its runtime plan.
$baseline=& (Join-Path $PSScriptRoot 'Build-TaskPilot.ps1') -Version '0.4.0.2' -DependencyRoot $dependency -OutputRoot $output -ValidateOnly
$lock=Get-TPBuildLock (Join-Path $repo 'build/dependencies.lock.json')
$runtimeLock=Get-Content -LiteralPath (Join-Path $repo 'build/runtime-files.json') -Raw -Encoding UTF8|ConvertFrom-Json
$payload=New-Object 'Collections.Generic.List[object]';$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($planned in @($baseline.PayloadManifest)){
    $relative=[string]$planned.Path;$from=$null
    if($relative-ceq'README.md'){$from=Join-Path $repo 'docs/local-validation/ENVIRONMENT-ja.md'}
    elseif($runtimeLock.Files-contains$relative-or$relative.StartsWith('Assets/')){$from=Join-Path $repo $relative}
    elseif($relative.StartsWith('Modules/ImportExcel/')){$from=Join-Path $dependency ('ImportExcel/7.8.10/'+$relative.Substring('Modules/ImportExcel/'.Length))}
    elseif($relative-ceq'ThirdPartyNotices/README.md'){$from=Join-Path $repo 'docs/build/THIRD-PARTY-NOTICES.md'}
    elseif($relative.StartsWith('ThirdPartyNotices/SQLite/')){$from=Join-Path $repo ('Modules/TaskPilot.Storage/provider/ThirdPartyNotices/'+[IO.Path]::GetFileName($relative))}
    elseif($relative.StartsWith('ThirdPartyNotices/')){
        $notice=@($lock.Notices|Where-Object {[IO.Path]::GetFileName($_.Target)-ceq[IO.Path]::GetFileName($relative)})
        if($notice.Count-ne1){throw 'Local dependency notice has no unique pinned source.'};$from=Join-Path $dependency $notice[0].Target
    }elseif($relative.StartsWith('ThirdPartySources/')){$from=Join-Path $dependency ('Source/'+[IO.Path]::GetFileName($relative))}
    else{throw ('Unmapped local validation payload source: '+$relative)}
    Assert-TPBuildNoLinks $from
    if(-not[IO.File]::Exists($from)){throw ('Required local validation input is missing: '+$relative)}
    Assert-TPLocalBuildInputOrigin $from
    $hash=Get-TPBuildSha $from
    if($relative-cne'README.md'-and$hash-cne$planned.Sha256){throw ('Pinned local validation payload mismatch: '+$relative)}
    if(-not$seen.Add($relative)){throw 'Duplicate common runtime payload.'}
    $payload.Add([pscustomobject]@{Source=$from;Path=$relative;Sha256=$hash;Component=$planned.Component})
}
foreach($item in $extras){if(-not$seen.Add($item.Path)){throw 'A local payload path collides with the common runtime.'};$payload.Add($item)}
if(@($payload|Where-Object {$_.Path-match'(^|/)(TaskPilot\.exe|TaskPilot\.ps1|TaskPilot\.Acceptance\.exe|TaskPilot\.Acceptance\.ps1)$|^acceptance/|(^|/)(Data|Backup|Export|Logs|DeveloperSandbox|tests)(/|$)|\.(db|sqlite|bak|log|tmp|pfx|p12|key)$'}).Count){throw 'An ordinary/formal entry, user data, test fixture or private key entered the local validation payload.'}
$result=[ordered]@{
    Status='BLOCKED';Readiness='NOT_READY';Purpose='LocalDeveloperValidationSyntheticOnly';Version='0.4.0.2'
    IsLocalValidationOnly=$true;Distributable=$false;ExecutionAuthorized=$false;PrivateRepositoryDeliveryOnly=$true
    GeneralDistributionBlocked=$true;IndependentModeDistributionBlocked=$true;FormalAcceptanceDistributionBlocked=$true
    Zip=$null;ExecutableGenerated=$false;OutputCreated=$false;PaidCertificateRequired=$false
    CertificateGenerated=$false;SigningKeyGenerated=$false;AuthorizationGenerated=$false;OSProtectionSettingsChanged=$false
    InputOriginChecked=([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT);OriginMetadataRemoved=$false
    SourceSha256=$entryHash;PayloadFiles=$payload.Count;PayloadManifest=@($payload.ToArray()|Select-Object Path,Sha256,Component)
    ExpectedGeneratedPaths=@('TaskPilot.LocalValidation.exe','TaskPilot.LocalValidation.exe.config','Runtime/TaskPilot.TestSandbox.dll','Codec/TaskPilotMigrationCodec.dll','LocalValidationBuildInfo.json','LocalValidationPayload.json','LOCAL_ONLY_DO_NOT_DISTRIBUTE.txt')
    MissingConditions=@('Trusted clean-VM provisioning proof','Live protected parent protocol before child CLR startup','Unchanged-policy compatible Windows 10/11 host','Windows client qualification and GUI verification')
    Windows10And11Verified=$false;ApplicationLaunched=$false;ProductionProfileAccessed=$false
}
if(-not$InternalCompile){return [pscustomobject]$result}
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'Internal local validation compilation requires x64 Windows PowerShell Desktop 5.1. No EXE was generated.'}
$framework=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
if([long]$framework.Release-lt393295){throw '.NET Framework4.6 or newer is required.'}
$hostSource=Join-Path $repo 'local-validation/TaskPilot.LocalValidation.Host.cs';$policySource=Join-Path $repo 'local-validation/TaskPilot.LocalValidation.Policy.cs'
foreach($file in @($hostSource,$policySource)){Assert-TPBuildNoLinks $file;if(-not[IO.File]::Exists($file)){throw 'The local validation native host source is missing.'};Assert-TPLocalBuildInputOrigin $file}
if(-not[IO.Directory]::Exists($output)){$null=[IO.Directory]::CreateDirectory($output)}
$internalRoot=Join-Path $output ('TaskPilot.LocalValidation_INTERNAL_'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N'))
if(Test-TPBuildPathExists $internalRoot){throw 'Internal local validation output already exists.'}
$null=[IO.Directory]::CreateDirectory($internalRoot);$stage=Join-Path $internalRoot 'TaskPilot.LocalValidation';$null=[IO.Directory]::CreateDirectory($stage)
Write-TPBuildNewText (Join-Path $internalRoot 'LOCAL_ONLY_DO_NOT_DISTRIBUTE.txt') 'NOT_READY. Blocked local developer preparation only. Never publish or distribute this directory or make a TaskPilot distribution ZIP. It does not authorize GUI execution or establish clean-VM/parent proof.'
foreach($item in $payload){Copy-TPBuildNewFile $item.Source (Join-Path $stage $item.Path) $item.Sha256}
$runtime=& (Join-Path $PSScriptRoot 'Build-TaskPilotRuntime.ps1') -OutputDirectory (Join-Path $internalRoot '.runtime-compile')
$codec=& (Join-Path $PSScriptRoot 'Build-TaskPilotRuntime.ps1') -Component Codec -OutputDirectory (Join-Path $internalRoot '.codec-compile')
Copy-TPBuildNewFile $runtime.AssemblyPath (Join-Path $stage 'Runtime/TaskPilot.TestSandbox.dll') $runtime.Sha256
Copy-TPBuildNewFile $codec.AssemblyPath (Join-Path $stage 'Codec/TaskPilotMigrationCodec.dll') $codec.Sha256
$hostHash=Get-TPBuildSha $hostSource;$policyHash=Get-TPBuildSha $policySource;$exe=Join-Path $stage 'TaskPilot.LocalValidation.exe'
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider;$parameters=New-Object CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable=$true;$parameters.GenerateInMemory=$false;$parameters.OutputAssembly=$exe;$parameters.IncludeDebugInformation=$false
$parameters.CompilerOptions='/target:winexe /platform:x64 /optimize+';$parameters.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($internalRoot,$false)
foreach($reference in @('mscorlib.dll','System.dll','System.Core.dll','System.Security.dll','System.Xml.dll','System.Windows.Forms.dll','System.Drawing.dll')){$null=$parameters.ReferencedAssemblies.Add($reference)}
try{
    $metadata='[assembly:System.Reflection.AssemblyVersion("0.4.0.2")][assembly:System.Reflection.AssemblyFileVersion("0.4.0.2")][assembly:System.Reflection.AssemblyTitle("TaskPilot Local Validation Only")][assembly:System.Reflection.AssemblyProduct("TaskPilot Local Developer Validation")]'
    $compiled=$compiler.CompileAssemblyFromSource($parameters,[string[]]@([IO.File]::ReadAllText($hostSource),[IO.File]::ReadAllText($policySource),$metadata))
    if($compiled.Errors.HasErrors){throw ('Local validation host compilation failed: '+(($compiled.Errors|ForEach-Object {$_.ToString()})-join[Environment]::NewLine))}
}finally{$compiler.Dispose()}
Assert-TPBuildWindowsX64GuiExe $exe
if((Get-TPBuildSha $entry)-cne$entryHash-or(Get-TPBuildSha $hostSource)-cne$hostHash-or(Get-TPBuildSha $policySource)-cne$policyHash){throw 'Local build sources changed during compilation.'}
Write-TPBuildNewText ($exe+'.config') '<?xml version="1.0" encoding="utf-8"?><configuration><startup useLegacyV2RuntimeActivationPolicy="true"><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.6"/></startup><runtime><loadFromRemoteSources enabled="false"/></runtime></configuration>'
foreach($forbidden in @('TaskPilot.exe','TaskPilot.ps1','TaskPilot.Acceptance.exe','TaskPilot.Acceptance.ps1')){if([IO.File]::Exists((Join-Path $stage $forbidden))){throw 'An ordinary or formal acceptance entry entered the local build.'}}
$result.ExecutableGenerated=$true;$result.OutputCreated=$true
$result['InternalRoot']=$internalRoot;$result['PackageRoot']=$stage;$result['Executable']=$exe;$result['ExecutableSha256']=Get-TPBuildSha $exe
$result['SignatureStatus']=[string](Get-AuthenticodeSignature -LiteralPath $exe).Status
$result['RuntimeGuardSha256']=$runtime.Sha256;$result['CodecRuntimeSha256']=$codec.Sha256;$result['HostSourceSha256']=$hostHash;$result['PolicySourceSha256']=$policyHash
Write-TPBuildNewText (Join-Path $stage 'LocalValidationBuildInfo.json') (ConvertTo-Json -InputObject $result -Depth 12)
$files=@(Get-TPBuildFiles $stage|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($stage.Length+1).Replace('\','/');Sha256=(Get-TPBuildSha $_.FullName)}})
# This JSON is bookkeeping only. It is not the signed receipt/manifest format
# consumed by Policy.Verify and cannot be used as authorization.
Write-TPBuildNewText (Join-Path $stage 'LocalValidationPayload.json') (ConvertTo-Json -InputObject ([ordered]@{FormatVersion=1;Purpose='LocalDeveloperValidationSyntheticOnly';Kind='BlockedInternalInventoryOnly';Files=$files}) -Depth 8)
return [pscustomobject]$result
