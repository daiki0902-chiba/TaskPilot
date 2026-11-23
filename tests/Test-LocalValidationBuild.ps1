#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DependencyRoot,[string]$OutputRoot,[string]$TestRoot,[string]$InternalPackageRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
if(-not$TestRoot){$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotLocalBuildTests_'+[guid]::NewGuid().ToString('N'))}
$fixture=Get-TPBuildFullPath $TestRoot;Assert-TPBuildNoLinks $fixture
if(Test-TPBuildPathExists $fixture){throw 'Local build verification requires a new synthetic TestRoot.'}
$null=[IO.Directory]::CreateDirectory($fixture)
if($OutputRoot){$reportRoot=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $reportRoot;if(-not[IO.Directory]::Exists($reportRoot)){throw 'OutputRoot must be an existing developer report directory.'}}
$checks=0
function Assert-LocalBuild([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw ('Local validation packaging regression: '+$Detail)}}
function Reject-LocalBuild([scriptblock]$Operation,[string]$Pattern){$failure=$null;try{$null=&$Operation}catch{$failure=$_.Exception.Message};Assert-LocalBuild ($null-ne$failure-and$failure-match$Pattern) ('Expected refusal was missing: '+$Pattern)}
function Assert-LocalArchiveBoundary([string]$InternalRoot,[string]$PackageRoot,[string]$OriginalSourceSha){
    $allowed=Get-TPBuildFullPath (Join-Path $PackageRoot 'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip')
    foreach($archive in @(Get-TPBuildFiles $InternalRoot|Where-Object {$_.Extension-ieq'.zip'})){
        if(-not$archive.FullName.Equals($allowed,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $archive.FullName)-cne$OriginalSourceSha){throw 'An unpinned source or application distribution ZIP was created.'}
    }
}
function Assert-LocalInventory([string]$PackageRoot,[object[]]$Files){
    $expected=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($file in $Files){Assert-TPBuildRelative $file.Path;if(-not$expected.Add([string]$file.Path)){throw 'Local inventory mismatch: duplicate path.'}}
    if(-not$expected.Add('LocalValidationPayload.json')){throw 'Local inventory mismatch: self entry.'}
    foreach($file in @(Get-TPBuildFiles $PackageRoot)){
        $relative=$file.FullName.Substring($PackageRoot.Length+1).Replace('\','/')
        if(-not$expected.Remove($relative)){throw 'Local inventory mismatch: undeclared output.'}
    }
    if($expected.Count-ne0){throw 'Local inventory mismatch: missing output.'}
}
$publicSources=@('TaskPilot.ps1','Runtime/TaskPilot.Runtime.ps1','tools/Build-TaskPilotDesktopAcceptance.ps1','tools/Test-TaskPilotDesktopAcceptance.ps1','tools/Test-TaskPilotAcceptancePackage.ps1','acceptance/TaskPilot.Acceptance.Security.ps1')
$before=@{};foreach($name in $publicSources){$before[$name]=Get-TPBuildSha (Join-Path $repo $name)}
$tool=Join-Path $repo 'tools/Build-TaskPilotLocalValidation.ps1';$neverCreated=Join-Path $fixture 'never-created'
$plan=&$tool -DependencyRoot $DependencyRoot -OutputRoot $neverCreated -ValidateOnly
Assert-LocalBuild ($plan.Status-ceq'BLOCKED'-and$plan.Readiness-ceq'NOT_READY'-and-not$plan.Distributable-and-not$plan.ExecutionAuthorized-and$null-eq$plan.Zip) 'Read-only plan must never authorize execution or distribution.'
Assert-LocalBuild ($plan.IsLocalValidationOnly-and$plan.PrivateRepositoryDeliveryOnly-and-not$plan.PaidCertificateRequired) 'The local developer purpose must be separate from a public release or paid-certificate requirement.'
Assert-LocalBuild ($plan.GeneralDistributionBlocked-and$plan.IndependentModeDistributionBlocked-and$plan.FormalAcceptanceDistributionBlocked) 'All existing publication gates must remain stopped.'
Assert-LocalBuild (-not$plan.OutputCreated-and-not$plan.ExecutableGenerated-and-not(Test-TPBuildPathExists $neverCreated)) 'ValidateOnly must not create or compile output.'
Assert-LocalBuild (-not$plan.CertificateGenerated-and-not$plan.SigningKeyGenerated-and-not$plan.AuthorizationGenerated-and-not$plan.OSProtectionSettingsChanged-and-not$plan.ApplicationLaunched-and-not$plan.ProductionProfileAccessed) 'A build plan cannot create trust material or touch runtime/user state.'
Assert-LocalBuild (-not$plan.OriginMetadataRemoved) 'Local preparation must never remove origin metadata.'
$names=@($plan.PayloadManifest|ForEach-Object {[string]$_.Path})
foreach($name in @('local-validation/TaskPilot.LocalValidation.ps1','local-validation/TaskPilot.LocalValidation.Runtime.ps1','local-validation/TaskPilot.LocalValidation.Gui.ps1','local-validation/TaskPilot.LocalValidation.Diagnostics.ps1','tools/Test-TaskPilotLocalValidation.ps1','Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/ImportExcel/EPPlus.dll','README.md','ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip')){Assert-LocalBuild ($names-ccontains$name) ('Missing required local runtime: '+$name)}
Assert-LocalBuild (@($names|Where-Object {$_-match'(^|/)(TaskPilot\.exe|TaskPilot\.ps1|TaskPilot\.Acceptance\.exe|TaskPilot\.Acceptance\.ps1)$|^acceptance/|(^|/)(Data|Backup|Export|Logs|DeveloperSandbox|tests)(/|$)|\.(db|sqlite|bak|log|tmp|pfx|p12|key)$'}).Count-eq0) 'An ordinary/formal entry, source data or trust secret was included.'
Assert-LocalBuild ($plan.ExpectedGeneratedPaths-ccontains'TaskPilot.LocalValidation.exe'-and$plan.ExpectedGeneratedPaths-cnotcontains'TaskPilot.exe'-and$plan.ExpectedGeneratedPaths-cnotcontains'TaskPilot.Acceptance.exe') 'The native entry must have a dedicated local-only name.'
$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($file in @($plan.PayloadManifest)){Assert-LocalBuild ($seen.Add($file.Path)-and$file.Sha256-cmatch'^[a-f0-9]{64}$') 'Every payload path must be unique and hash-bound.'}
Reject-LocalBuild {&$tool -DependencyRoot $DependencyRoot -OutputRoot $neverCreated -ValidateOnly -InternalCompile} 'Choose ValidateOnly or InternalCompile'
Reject-LocalBuild {&$tool -DependencyRoot $DependencyRoot -OutputRoot (Join-Path $repo 'docs') -ValidateOnly} 'OutputRoot must be'
Reject-LocalBuild {&$tool -DependencyRoot $DependencyRoot -OutputRoot (Join-Path $DependencyRoot 'invalid-output') -ValidateOnly} 'must be disjoint'
$existing=Join-Path $fixture 'previous-build';$null=[IO.Directory]::CreateDirectory($existing)
$sentinel=Join-Path $existing 'synthetic-old-build.txt';Write-TPBuildNewText $sentinel 'SYNTHETIC PREVIOUS BUILD - KEEP';$sentinelHash=Get-TPBuildSha $sentinel
$default=&$tool -DependencyRoot $DependencyRoot -OutputRoot $existing
Assert-LocalBuild ($default.Status-ceq'BLOCKED'-and-not$default.OutputCreated-and-not$default.ExecutableGenerated-and(Get-TPBuildSha $sentinel)-ceq$sentinelHash-and@(Get-TPBuildFiles $existing).Count-eq1) 'Default invocation modified existing outputs or silently compiled.'
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){Reject-LocalBuild {&$tool -DependencyRoot $DependencyRoot -OutputRoot $neverCreated -InternalCompile} 'requires x64 Windows PowerShell Desktop 5.1'}
else{
    Assert-LocalBuild $plan.InputOriginChecked 'Native build preparation must inspect input origin metadata.'
    # Exercise the actual checker against a new synthetic file, not a source or
    # business document. Extract its reviewed definition without invoking build.
    $tokens=$null;$errors=$null;$builderAst=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors)
    $originDefinition=@($builderAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Assert-TPLocalBuildInputOrigin'},$true))
    Assert-LocalBuild ($originDefinition.Count-eq1) 'One explicit origin checker is required.'
    . ([scriptblock]::Create($originDefinition[0].Extent.Text))
    $originFile=Join-Path $fixture 'synthetic-origin.txt';Write-TPBuildNewText $originFile 'SYNTHETIC SOURCE WITH ORIGIN'
    Assert-TPLocalBuildInputOrigin $originFile;$checks++
    $originText="[ZoneTransfer]`r`nZoneId=3`r`n"
    # .NET Framework File.WriteAllText rejects the colon in an ADS path.
    # Use the Windows provider on this new synthetic file; never clear origin.
    Set-Content -LiteralPath $originFile -Stream Zone.Identifier -Value $originText -NoNewline -Encoding ASCII -ErrorAction Stop
    $originBefore=Get-TPBuildSha $originFile
    Reject-LocalBuild {Assert-TPLocalBuildInputOrigin $originFile} 'download-origin metadata'
    Assert-LocalBuild ((Get-TPBuildSha $originFile)-ceq$originBefore-and(Get-Content -LiteralPath $originFile -Stream Zone.Identifier -Raw -ErrorAction Stop)-ceq$originText) 'Origin refusal must preserve source bytes and the ADS.'
}
# Licensed upstream source is the only archive exception. The internal app may
# not be packed into a ZIP even if it is called a local developer build.
$archiveRoot=Join-Path $fixture 'archive-fixture';$archivePackage=Join-Path $archiveRoot 'TaskPilot.LocalValidation'
$licensedSource=Join-Path $archivePackage 'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip';Write-TPBuildNewText $licensedSource 'SYNTHETIC REQUIRED SOURCE ARCHIVE'
Write-TPBuildNewText (Join-Path $archivePackage 'LocalValidationPayload.json') '{}'
$licensedSha=Get-TPBuildSha $licensedSource;$archiveManifest=@([pscustomobject]@{Path='ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip';Sha256=$licensedSha})
Assert-LocalArchiveBoundary $archiveRoot $archivePackage $licensedSha;$checks++
Assert-LocalInventory $archivePackage $archiveManifest;$checks++
$forbiddenZip=Join-Path $archiveRoot 'TaskPilot.LocalValidation.zip';Write-TPBuildNewText $forbiddenZip 'SYNTHETIC FORBIDDEN DISTRIBUTION'
Reject-LocalBuild {Assert-LocalArchiveBoundary $archiveRoot $archivePackage $licensedSha} 'distribution ZIP'
[IO.File]::Delete($forbiddenZip)
$unknown=Join-Path $archivePackage 'undeclared.txt';Write-TPBuildNewText $unknown 'SYNTHETIC UNDECLARED FILE'
Reject-LocalBuild {Assert-LocalInventory $archivePackage $archiveManifest} 'Local inventory mismatch: undeclared'
[IO.File]::Delete($unknown);[IO.File]::AppendAllText($licensedSource,'TAMPER')
Reject-LocalBuild {Assert-LocalArchiveBoundary $archiveRoot $archivePackage $licensedSha} 'distribution ZIP'
[IO.File]::Delete($licensedSource)
Reject-LocalBuild {Assert-LocalInventory $archivePackage $archiveManifest} 'Local inventory mismatch: missing'
if($InternalPackageRoot){
    $package=Get-TPBuildFullPath $InternalPackageRoot;Assert-TPBuildNoLinks $package
    $info=Get-Content -LiteralPath (Join-Path $package 'LocalValidationBuildInfo.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-LocalBuild ($info.Status-ceq'BLOCKED'-and$info.Readiness-ceq'NOT_READY'-and$info.ExecutableGenerated-and$info.IsLocalValidationOnly-and-not$info.ExecutionAuthorized-and-not$info.Distributable-and$null-eq$info.Zip) 'Native metadata must still refuse execution and distribution.'
    Assert-LocalBuild (-not$info.AuthorizationGenerated-and-not$info.SigningKeyGenerated-and-not$info.CertificateGenerated-and-not$info.OSProtectionSettingsChanged) 'The internal compiler generated authorization or changed protection.'
    $exe=Join-Path $package 'TaskPilot.LocalValidation.exe';Assert-TPBuildWindowsX64GuiExe $exe;$checks++
    Assert-LocalBuild ((Get-TPBuildSha $exe)-ceq$info.ExecutableSha256) 'The actual native executable differs from build metadata.'
    foreach($name in @('TaskPilot.exe','TaskPilot.ps1','TaskPilot.Acceptance.exe','TaskPilot.Acceptance.ps1')){Assert-LocalBuild (-not[IO.File]::Exists((Join-Path $package $name))) ('Forbidden public/formal entry: '+$name)}
    $manifest=Get-Content -LiteralPath (Join-Path $package 'LocalValidationPayload.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-LocalBuild ($manifest.Purpose-ceq'LocalDeveloperValidationSyntheticOnly'-and$manifest.Kind-ceq'BlockedInternalInventoryOnly') 'The generated inventory must not pose as signed launch permission.'
    Assert-LocalInventory $package @($manifest.Files);$checks++
    foreach($file in @($manifest.Files)){Assert-LocalBuild ((Get-TPBuildSha (Join-Path $package $file.Path))-ceq$file.Sha256) 'Native local package content changed.'}
    Assert-LocalBuild ((Get-TPBuildSha (Join-Path $package 'Runtime/TaskPilot.TestSandbox.dll'))-ceq$info.RuntimeGuardSha256) 'The packaged runtime DLL differs from the compiled local metadata.'
    Assert-LocalBuild (@(Get-TPBuildFiles $package|Where-Object {$_.Extension-in@('.pfx','.p12','.key')-or$_.Name-match'(?i)(Authorization|Receipt|PrivateKey)' }).Count-eq0) 'A launch receipt or private key was fabricated into the internal package.'
    $sourceArchive=@($plan.PayloadManifest|Where-Object {$_.Path-ceq'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip'})
    Assert-LocalBuild ($sourceArchive.Count-eq1) 'The corresponding-source archive must have one reviewed hash.'
    Assert-LocalArchiveBoundary ([IO.Path]::GetDirectoryName($package)) $package $sourceArchive[0].Sha256;$checks++
}
foreach($name in $publicSources){Assert-LocalBuild ((Get-TPBuildSha (Join-Path $repo $name))-ceq$before[$name]) 'Local preparation changed an existing public or formal entry/gate.'}
$report=[pscustomobject]@{Stage='Blocked developer-local build preparation';Passed=$true;Checks=$checks;Status='BLOCKED';Readiness='NOT_READY';Purpose='LocalDeveloperValidationSyntheticOnly';IsLocalValidationOnly=$true;Distributable=$false;ExecutionAuthorized=$false;CertificateGenerated=$false;SigningKeyGenerated=$false;AuthorizationGenerated=$false;OSProtectionSettingsChanged=$false;ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11Verified=$false;InternalCompileChecked=[bool]$InternalPackageRoot}
if($OutputRoot){Write-TPBuildNewText (Join-Path $reportRoot ('LocalValidationBuild_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 6)}
return $report
