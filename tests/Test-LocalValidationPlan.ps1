#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot,[string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repository=Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'tools/TaskPilot.BuildSupport.ps1')
$reportRoot=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $reportRoot
if(-not[IO.Directory]::Exists($reportRoot)){throw 'An existing developer result directory is required.'}
$fixture=if($TestRoot){Get-TPBuildFullPath $TestRoot}else{Join-Path $reportRoot ('LocalValidationPlan_'+[guid]::NewGuid().ToString('N'))}
Assert-TPBuildNoLinks $fixture
if(Test-TPBuildPathExists $fixture){throw 'The planning fixture must be new.'}
$null=[IO.Directory]::CreateDirectory($fixture)
$tool=Join-Path $repository 'tools/New-TaskPilotLocalValidationPlan.ps1'
$checks=0
function Assert-LocalPlan([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw ('Local planning regression: '+$Message)}}
function Reject-LocalPlan([scriptblock]$Operation,[string]$Code){$caught=$null;try{$null=&$Operation}catch{$caught=$_};Assert-LocalPlan ($null-ne$caught-and$caught.Exception.Message-like('*'+$Code+'*')) ('Expected '+$Code)}
$commit='1234567890abcdef1234567890abcdef12345678'
$untouched=Join-Path $fixture 'not-created'
$baselinePaths=@('TaskPilot.ps1','Runtime/TaskPilot.Runtime.ps1','acceptance/TaskPilot.Acceptance.Launcher.cs','acceptance/trusted-publishers.json','tools/Test-TaskPilotAcceptancePackage.ps1')
$baseline=@{};foreach($relative in $baselinePaths){$baseline[$relative]=Get-TPBuildSha (Join-Path $repository $relative)}
$plan=&$tool -SourceCommit $commit -OutputRoot $untouched
Assert-LocalPlan ($plan.Kind-ceq'LOCAL_VALIDATION_PLAN_ONLY'-and$plan.Purpose-ceq'LocalDeveloperValidationSyntheticOnly'-and$plan.Status-ceq'NOT_READY') 'Planning must be separate and remain not ready.'
Assert-LocalPlan (-not$plan.CanBuild-and-not$plan.CanLaunch-and-not$plan.Distributable-and-not$plan.PublicArtifactsAllowed) 'No build, launch or distribution permission may be inferred.'
Assert-LocalPlan (-not$plan.OutputCreated-and-not(Test-TPBuildPathExists $untouched)) 'Default planning must create no output.'
Assert-LocalPlan ($plan.SourceCommit-ceq$commit-and-not$plan.SourceCommitContentVerified) 'Syntax validation must not claim source provenance.'
Assert-LocalPlan ($plan.EnvironmentId-cmatch'^[a-f0-9]{32}$'-and$plan.PlannedDataNamespace-ceq('%LOCALAPPDATA%\TaskPilotLocalValidation\'+$plan.EnvironmentId)) 'The planned namespace must be fixed and distinct.'
Assert-LocalPlan ($plan.GeneralDistributionBlocked-and$plan.IndependentModeDistributionBlocked-and$plan.AcceptanceDistributionBlocked-and$plan.LocalDistributionBlocked) 'Every distribution stop must remain set.'
Assert-LocalPlan (-not$plan.PaidCodeSigningCertificateRequired-and-not$plan.PublicPublisherTrustEstablished-and-not$plan.CertificateStoreChanged-and-not$plan.SelfSignedCertificateInstalled) 'No paid certificate or installed trust is implied.'
Assert-LocalPlan (-not$plan.NormalAndOtherTestNamespacesAllowed-and-not$plan.LegacyMigrationAllowed-and-not$plan.ProductionProfileAccessed) 'Planning cannot authorize normal-data access.'
foreach($flag in @('VMCreated','HyperVOrWindowsFeaturesChanged','OSProtectionChanged','ExecutionPolicyChanged','FilesUnblocked','PackagesDownloaded','ExecutableCreated','ZipCreated','ApplicationLaunched','ApplicationSpecificReceiptIssued','ReceiptPrivateKeyStored')){Assert-LocalPlan (-not$plan.$flag) ('Unexpected side effect: '+$flag)}
Assert-LocalPlan ($plan.ExistingAllowedPolicies.Count-eq2-and$plan.ExistingAllowedPolicies-ccontains'RemoteSigned'-and$plan.ExistingAllowedPolicies-ccontains'Unrestricted') 'Only already-compatible policies are candidates.'
foreach($policy in @('Restricted','AllSigned','Bypass','Undefined','Unknown')){Assert-LocalPlan ($plan.BlockedPolicies-ccontains$policy) ('Unsupported policy must block: '+$policy)}
Assert-LocalPlan (@($plan.ReadinessEvidenceMissing).Count-ge5-and@($plan.RequiredEnvironmentConditions).Count-ge10) 'The missing trust, host and client conditions must remain explicit.'
$validate=&$tool -SourceCommit $commit -ValidateOnly -OutputRoot $untouched
Assert-LocalPlan (-not$validate.OutputCreated-and-not(Test-TPBuildPathExists $untouched)-and$validate.EnvironmentId-cne$plan.EnvironmentId) 'Validation must not persist or reuse an environment identity.'
foreach($invalid in @('',('0'*40),('A'*40),'../source','1234567890abcdef1234567890abcdef123456789')){Reject-LocalPlan {&$tool -SourceCommit $invalid} 'TP-LOCAL-PLAN-SOURCE-COMMIT-INVALID'}
Reject-LocalPlan {&$tool -SourceCommit $commit -ValidateOnly -WritePlan} 'TP-LOCAL-PLAN-CONFLICTING-MODE'
Reject-LocalPlan {&$tool -SourceCommit $commit -WritePlan} 'TP-LOCAL-PLAN-NEW-OUTPUT-REQUIRED'
foreach($invalidOutput in @('%LOCALAPPDATA%\TaskPilot4','//server/share/local-plan')){Reject-LocalPlan {&$tool -SourceCommit $commit -WritePlan -OutputRoot $invalidOutput} 'TP-LOCAL-PLAN-OUTPUT-INVALID'}
Reject-LocalPlan {&$tool -SourceCommit $commit -WritePlan -OutputRoot (Join-Path $repository 'local-validation/not-created')} 'TP-LOCAL-PLAN-OUTPUT-INVALID'
$existing=Join-Path $fixture 'existing';$null=[IO.Directory]::CreateDirectory($existing)
$sentinel=Join-Path $existing 'synthetic-sentinel.txt';Write-TPBuildNewText $sentinel 'SYNTHETIC EXISTING DEVELOPER OUTPUT'
$before=Get-TPBuildSha $sentinel
Reject-LocalPlan {&$tool -SourceCommit $commit -WritePlan -OutputRoot $existing} 'TP-LOCAL-PLAN-OUTPUT-EXISTS'
Assert-LocalPlan ((Get-TPBuildSha $sentinel)-ceq$before-and@(Get-TPBuildFiles $existing).Count-eq1) 'Existing output may not be modified.'
$written=Join-Path $fixture 'local-plan'
$result=&$tool -SourceCommit $commit -WritePlan -OutputRoot $written
Assert-LocalPlan ($result.OutputCreated-and$result.Status-ceq'NOT_READY'-and-not$result.CanLaunch) 'A written plan must still refuse launch.'
$persisted=Get-Content -LiteralPath (Join-Path $written 'LocalValidationPlan.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-LocalPlan ($persisted.SourceCommit-ceq$commit-and$persisted.EnvironmentId-ceq$result.EnvironmentId-and-not$persisted.ApplicationSpecificReceiptIssued) 'Persisted planning is not a receipt.'
Assert-LocalPlan (@(Get-TPBuildFiles $written).Count-eq2-and@(Get-TPBuildFiles $written|Where-Object {$_.Extension-in@('.exe','.dll','.zip','.pfx','.cer','.msix')}).Count-eq0) 'Only two planning documents may be emitted.'
foreach($relative in $baselinePaths){Assert-LocalPlan ((Get-TPBuildSha (Join-Path $repository $relative))-ceq$baseline[$relative]) ('An existing entry or gate changed: '+$relative)}
$report=[pscustomobject][ordered]@{Stage='Local developer validation planning';Passed=$true;Checks=$checks;Kind='LOCAL_VALIDATION_PLAN_ONLY';Status='NOT_READY';CanLaunch=$false;VMCreated=$false;OSProtectionChanged=$false;CertificateStoreChanged=$false;ExecutionPolicyChanged=$false;ProductionProfileAccessed=$false;ExecutableOrZipCreated=$false;Windows10And11Verified=$false}
Write-TPBuildNewText (Join-Path $reportRoot ('LocalValidationPlan_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 8)
return $report
