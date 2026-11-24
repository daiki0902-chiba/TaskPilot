#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DependencyRoot,[string]$TestRoot,[string]$InternalPackageRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
if(-not$TestRoot){$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotAcceptanceBuildTests_'+[guid]::NewGuid().ToString('N'))}
$root=Get-TPBuildFullPath $TestRoot;Assert-TPBuildNoLinks $root
if(Test-TPBuildPathExists $root){throw 'TestRoot must be new; existing data will not be changed.'}
$null=[IO.Directory]::CreateDirectory($root)
$checks=0
function Assert-AcceptanceBuild([bool]$Condition,[string]$Message){if(-not$Condition){throw ('Acceptance packaging regression: '+$Message)};$script:checks++}
function Expect-AcceptanceBuildFailure([scriptblock]$Operation,[string]$Pattern){
    $failure=$null;try{$null=& $Operation}catch{$failure=$_.Exception.Message}
    Assert-AcceptanceBuild ($null-ne$failure-and$failure-match$Pattern) ('Required stop was absent or wrong: '+$failure)
}
function Assert-AcceptanceArchiveBoundary([string]$InternalRoot,[string]$PackageRoot,[string]$SourceArchiveSha256){
    # LGPL corresponding source is a required upstream archive, not an app ZIP.
    # Permit exactly that reviewed byte image inside the package; every other
    # archive, including any sibling/outside-package ZIP, remains forbidden.
    $source=Get-TPBuildFullPath (Join-Path $PackageRoot 'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip')
    foreach($archive in @(Get-TPBuildFiles $InternalRoot|Where-Object {$_.Extension-ieq'.zip'})){
        if(-not$archive.FullName.Equals($source,[StringComparison]::OrdinalIgnoreCase)-or(Get-TPBuildSha $archive.FullName)-cne$SourceArchiveSha256){throw 'Unexpected TaskPilot or unpinned source archive in internal output.'}
    }
}
function Assert-AcceptanceExactInventory([string]$PackageRoot,[object[]]$ManifestFiles){
    $expected=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($file in $ManifestFiles){Assert-TPBuildRelative $file.Path;if(-not$expected.Add($file.Path)){throw 'Package inventory mismatch: duplicate manifest entry.'}}
    if(-not$expected.Add('AcceptancePayload.json')){throw 'Package inventory mismatch: the manifest must exclude itself.'}
    foreach($file in @(Get-TPBuildFiles $PackageRoot)){
        $relative=$file.FullName.Substring($PackageRoot.Length+1).Replace('\','/')
        if(-not$expected.Remove($relative)){throw 'Package inventory mismatch: undeclared output file.'}
    }
    if($expected.Count-ne0){throw 'Package inventory mismatch: declared output file is missing.'}
}
$tool=Join-Path $repo 'tools/Build-TaskPilotDesktopAcceptance.ps1'
$neverCreated=Join-Path $root 'no-output'
$plan=& $tool -DependencyRoot $DependencyRoot -OutputRoot $neverCreated -ValidateOnly
Assert-AcceptanceBuild ($plan.Status-ceq'BLOCKED'-and-not$plan.Distributable-and$null-eq$plan.Zip) 'Read-only validation must remain BLOCKED with no distributable ZIP.'
Assert-AcceptanceBuild (-not$plan.ExecutableGenerated-and-not$plan.OutputCreated-and-not(Test-TPBuildPathExists $neverCreated)) 'Read-only validation created output or claimed an executable.'
Assert-AcceptanceBuild ($plan.GeneralDistributionBlocked-and$plan.IndependentTestModeDistributionBlocked) 'General and independent-mode distribution stops must remain set.'
Assert-AcceptanceBuild (-not$plan.ProductionProfileAccessed-and-not$plan.WindowsDesktopExecutionVerified) 'Build validation must not claim a real-profile or Windows GUI test.'
$names=@($plan.PayloadManifest|ForEach-Object {[string]$_.Path})
foreach($required in @('acceptance/TaskPilot.Acceptance.ps1','acceptance/TaskPilot.Acceptance.Runtime.ps1','acceptance/TaskPilot.Acceptance.Gui.ps1','acceptance/TaskPilot.Acceptance.Security.ps1','acceptance/TaskPilot.Acceptance.Diagnostics.ps1','acceptance/trusted-publishers.json','tools/Test-TaskPilotDesktopAcceptance.ps1','tools/Collect-TaskPilotDesktopAcceptanceLogs.ps1','Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/ImportExcel/EPPlus.dll','README.md')){
    Assert-AcceptanceBuild ($names-ccontains$required) ('Required acceptance runtime is missing: '+$required)
}
Assert-AcceptanceBuild (@($names|Where-Object {$_-match'(^|/)(TaskPilot\.exe|TaskPilot\.ps1)$|(^|/)(Data|Backup|Export|Logs|DeveloperSandbox|tests)(/|$)|\.(db|sqlite|bak|log|tmp)$'}).Count-eq0) 'Ordinary entry, test fixtures or user data entered the acceptance package.'
Assert-AcceptanceBuild ($plan.ExpectedGeneratedPaths-ccontains'TaskPilot.Acceptance.exe'-and$plan.ExpectedGeneratedPaths-cnotcontains'TaskPilot.exe') 'Acceptance and ordinary executable names must be distinct.'
Assert-AcceptanceBuild ($plan.ExpectedGeneratedPaths-ccontains'acceptance/vendor-code-lock.json'-and@($plan.OriginalVendorCode).Count-gt3) 'The original vendor-byte lock must be generated separately from signed project code.'
$vendorSeen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach($vendor in @($plan.OriginalVendorCode)){
    $allowed=$vendor.Path-cin@('Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll')-or($vendor.Path.StartsWith('Modules/ImportExcel/',[StringComparison]::Ordinal)-and[IO.Path]::GetExtension($vendor.Path)-cin@('.dll','.ps1','.psm1','.psd1'))
    Assert-AcceptanceBuild ($allowed-and$vendorSeen.Add($vendor.Path)-and$vendor.Sha256-cmatch'^[a-f0-9]{64}$') 'Project code or an invalid/duplicate entry received a vendor signing exemption.'
    $planned=@($plan.PayloadManifest|Where-Object {$_.Path-ceq$vendor.Path})
    Assert-AcceptanceBuild ($planned.Count-eq1-and$planned[0].Sha256-ceq$vendor.Sha256) 'A vendor-code hash differs from its pinned original payload hash.'
}
$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($name in $names){Assert-AcceptanceBuild ($seen.Add($name)) ('Duplicate acceptance payload: '+$name)}
Expect-AcceptanceBuildFailure {& $tool -DependencyRoot $DependencyRoot -OutputRoot (Join-Path $repo 'docs') -ValidateOnly} 'OutputRoot must be'
Expect-AcceptanceBuildFailure {& $tool -DependencyRoot $DependencyRoot -OutputRoot (Join-Path $DependencyRoot 'forbidden-output') -ValidateOnly} 'must be disjoint'
Expect-AcceptanceBuildFailure {& $tool -DependencyRoot $DependencyRoot -OutputRoot $neverCreated -ValidateOnly -InternalCompile} 'Choose ValidateOnly or InternalCompile'
$existing=Join-Path $root 'existing-output';$null=[IO.Directory]::CreateDirectory($existing)
$sentinel=Join-Path $existing 'previous-build.txt';Write-TPBuildNewText $sentinel 'synthetic previous output must remain unchanged'
$before=Get-TPBuildSha $sentinel
$default=& $tool -DependencyRoot $DependencyRoot -OutputRoot $existing
Assert-AcceptanceBuild ($default.Status-ceq'BLOCKED'-and-not$default.OutputCreated-and(Get-TPBuildSha $sentinel)-ceq$before-and@(Get-TPBuildFiles $existing).Count-eq1) 'Default mode changed existing build outputs or compiled without an explicit internal request.'
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){Expect-AcceptanceBuildFailure {& $tool -DependencyRoot $DependencyRoot -OutputRoot $neverCreated -InternalCompile} 'requires x64 Windows PowerShell Desktop 5.1'}
# Synthetic fixtures prove the archive exception is confined to the one pinned
# source file and cannot admit a TaskPilot ZIP or undeclared package content.
$archiveFixture=Join-Path $root 'archive-policy-fixture';$fixturePackage=Join-Path $archiveFixture 'TaskPilot.Acceptance'
$fixtureSource=Join-Path $fixturePackage 'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip'
Write-TPBuildNewText $fixtureSource 'synthetic corresponding source archive image'
Write-TPBuildNewText (Join-Path $fixturePackage 'AcceptancePayload.json') '{}'
$fixtureHash=Get-TPBuildSha $fixtureSource
$fixtureManifest=@([pscustomobject]@{Path='ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip';Sha256=$fixtureHash})
Assert-AcceptanceArchiveBoundary $archiveFixture $fixturePackage $fixtureHash;$checks++
Assert-AcceptanceExactInventory $fixturePackage $fixtureManifest;$checks++
$outsideZip=Join-Path $archiveFixture 'TaskPilot.Acceptance.zip';Write-TPBuildNewText $outsideZip 'forbidden app distribution archive'
Expect-AcceptanceBuildFailure {Assert-AcceptanceArchiveBoundary $archiveFixture $fixturePackage $fixtureHash} 'Unexpected TaskPilot or unpinned source archive'
[IO.File]::Delete($outsideZip)
$insideZip=Join-Path $fixturePackage 'ThirdPartySources/extra.zip';Write-TPBuildNewText $insideZip 'unreviewed archive'
Expect-AcceptanceBuildFailure {Assert-AcceptanceArchiveBoundary $archiveFixture $fixturePackage $fixtureHash} 'Unexpected TaskPilot or unpinned source archive'
Expect-AcceptanceBuildFailure {Assert-AcceptanceExactInventory $fixturePackage $fixtureManifest} 'Package inventory mismatch: undeclared'
[IO.File]::Delete($insideZip)
[IO.File]::AppendAllText($fixtureSource,'changed original image')
Expect-AcceptanceBuildFailure {Assert-AcceptanceArchiveBoundary $archiveFixture $fixturePackage $fixtureHash} 'Unexpected TaskPilot or unpinned source archive'
[IO.File]::Delete($fixtureSource)
Expect-AcceptanceBuildFailure {Assert-AcceptanceExactInventory $fixturePackage $fixtureManifest} 'Package inventory mismatch: declared'
if($InternalPackageRoot){
    $package=Get-TPBuildFullPath $InternalPackageRoot;Assert-TPBuildNoLinks $package
    $info=Get-Content -LiteralPath (Join-Path $package 'AcceptanceBuildInfo.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-AcceptanceBuild ($info.Status-ceq'BLOCKED'-and-not$info.Distributable-and$null-eq$info.Zip-and$info.ExecutableGenerated) 'Compiled internal metadata must remain explicitly non-distributable.'
    $exe=Join-Path $package 'TaskPilot.Acceptance.exe'
    Assert-TPBuildWindowsX64GuiExe $exe;$checks++
    Assert-AcceptanceBuild (-not[IO.File]::Exists((Join-Path $package 'TaskPilot.exe'))-and-not[IO.File]::Exists((Join-Path $package 'TaskPilot.ps1'))) 'A normal executable/entry was generated in the acceptance package.'
    Assert-AcceptanceBuild ((Get-TPBuildSha $exe)-ceq$info.ExecutableSha256) 'Native launcher hash differs from build metadata.'
    $manifest=Get-Content -LiteralPath (Join-Path $package 'AcceptancePayload.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-AcceptanceBuild ($manifest.Purpose-ceq'DesktopAcceptanceSyntheticOnly'-and$manifest.Version-ceq'0.4.0.2') 'Compiled manifest purpose/version changed.'
    Assert-AcceptanceExactInventory $package @($manifest.Files);$checks++
    foreach($file in @($manifest.Files)){Assert-AcceptanceBuild ((Get-TPBuildSha (Join-Path $package $file.Path))-ceq$file.Sha256) ('Compiled package hash mismatch: '+$file.Path)}
    $vendorLock=Get-Content -LiteralPath (Join-Path $package 'acceptance/vendor-code-lock.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-AcceptanceBuild ($vendorLock.FormatVersion-eq1-and$vendorLock.Purpose-ceq'DesktopAcceptanceSyntheticOnly'-and@($vendorLock.Files).Count-eq@($plan.OriginalVendorCode).Count) 'Compiled original vendor lock has an incompatible contract.'
    foreach($file in @($vendorLock.Files)){
        $original=@($plan.OriginalVendorCode|Where-Object {$_.Path-ceq$file.Path})
        Assert-AcceptanceBuild ($original.Count-eq1-and$original[0].Sha256-ceq$file.Sha256-and(Get-TPBuildSha (Join-Path $package $file.Path))-ceq$file.Sha256) 'Compiled vendor bytes differ from the reviewed baseline.'
    }
    Assert-AcceptanceBuild (-not[IO.File]::Exists((Join-Path $package 'AcceptanceAuthorization.json'))-and-not[IO.File]::Exists((Join-Path $package 'AcceptanceAuthorization.p7s'))) 'Internal compiler must never fabricate an acceptance authority.'
    $sourceArchive=@($plan.PayloadManifest|Where-Object {$_.Path-ceq'ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip'})
    Assert-AcceptanceBuild ($sourceArchive.Count-eq1) 'The required pinned EPPlus corresponding source archive is missing from the build plan.'
    Assert-AcceptanceArchiveBoundary ([IO.Path]::GetDirectoryName($package)) $package $sourceArchive[0].Sha256;$checks++
}
[pscustomobject]@{Passed=$true;Checks=$checks;Purpose='DesktopAcceptanceSyntheticOnly';Status='BLOCKED';GeneralDistributionBlocked=$true;IndependentTestModeDistributionBlocked=$true;Distributable=$false;ProductionProfileAccessed=$false;WindowsDesktopExecutionVerified=$false;InternalCompileChecked=[bool]$InternalPackageRoot}
