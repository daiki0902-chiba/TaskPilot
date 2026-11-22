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
    foreach($file in @($manifest.Files)){Assert-AcceptanceBuild ((Get-TPBuildSha (Join-Path $package $file.Path))-ceq$file.Sha256) ('Compiled package hash mismatch: '+$file.Path)}
    $vendorLock=Get-Content -LiteralPath (Join-Path $package 'acceptance/vendor-code-lock.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-AcceptanceBuild ($vendorLock.FormatVersion-eq1-and$vendorLock.Purpose-ceq'DesktopAcceptanceSyntheticOnly'-and@($vendorLock.Files).Count-eq@($plan.OriginalVendorCode).Count) 'Compiled original vendor lock has an incompatible contract.'
    foreach($file in @($vendorLock.Files)){
        $original=@($plan.OriginalVendorCode|Where-Object {$_.Path-ceq$file.Path})
        Assert-AcceptanceBuild ($original.Count-eq1-and$original[0].Sha256-ceq$file.Sha256-and(Get-TPBuildSha (Join-Path $package $file.Path))-ceq$file.Sha256) 'Compiled vendor bytes differ from the reviewed baseline.'
    }
    Assert-AcceptanceBuild (-not[IO.File]::Exists((Join-Path $package 'AcceptanceAuthorization.json'))-and-not[IO.File]::Exists((Join-Path $package 'AcceptanceAuthorization.p7s'))) 'Internal compiler must never fabricate an acceptance authority.'
    Assert-AcceptanceBuild (@(Get-TPBuildFiles ([IO.Path]::GetDirectoryName($package))|Where-Object {$_.Extension-ceq'.zip'}).Count-eq0) 'Internal compiler created a ZIP despite the distribution stop.'
}
[pscustomobject]@{Passed=$true;Checks=$checks;Purpose='DesktopAcceptanceSyntheticOnly';Status='BLOCKED';GeneralDistributionBlocked=$true;IndependentTestModeDistributionBlocked=$true;Distributable=$false;ProductionProfileAccessed=$false;WindowsDesktopExecutionVerified=$false;InternalCompileChecked=[bool]$InternalPackageRoot}
