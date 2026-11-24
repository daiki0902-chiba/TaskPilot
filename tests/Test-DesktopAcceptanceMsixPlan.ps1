#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot,[string]$TestRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$root=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $root
if(-not[IO.Directory]::Exists($root)){throw 'An existing developer results directory is required.'}
if($TestRoot){
    $fixture=Get-TPBuildFullPath $TestRoot;Assert-TPBuildNoLinks $fixture
    if(Test-TPBuildPathExists $fixture){throw 'A new synthetic MSIX planning fixture is required.'}
}else{$fixture=Join-Path $root ('AcceptanceMsixPlan_'+[guid]::NewGuid().ToString('N'))}
$null=[IO.Directory]::CreateDirectory($fixture)
$tool=Join-Path $repo 'tools/New-TaskPilotAcceptanceMsixPlan.ps1'
$checks=0
function Assert-MsixPlan([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
function Reject-MsixPlan([scriptblock]$Action,[string]$Code){$failure=$null;try{$null=&$Action}catch{$failure=$_};Assert-MsixPlan ($null-ne$failure-and$failure.Exception.Message-like('*'+$Code+'*')) ('Expected MSIX plan refusal '+$Code)}
$policy=Join-Path $repo 'acceptance/trusted-publishers.json';$policyHash=Get-TPBuildSha $policy
$guard=Join-Path $repo 'acceptance/TaskPilot.Acceptance.PackageGuard.cs';$guardHash=Get-TPBuildSha $guard
$normalRuntime=Join-Path $repo 'Runtime/TaskPilot.Runtime.ps1';$normalRuntimeHash=Get-TPBuildSha $normalRuntime
$noOutput=Join-Path $fixture 'not-created'
$plan=& $tool -OutputRoot $noOutput
Assert-MsixPlan ($plan.Kind-ceq'PLAN_ONLY'-and$plan.Status-ceq'NOT_READY'-and-not$plan.CanBuildOrLaunch-and-not$plan.CanInstall-and-not$plan.Distributable) 'Planning must never authorize build, installation or launch.'
Assert-MsixPlan (-not$plan.OutputCreated-and-not(Test-TPBuildPathExists $noOutput)-and-not$plan.IdentityProvided) 'Default planning must not create files or invent a publisher.'
Assert-MsixPlan ($plan.GeneralDistributionBlocked-and$plan.AcceptanceDistributionBlocked) 'Both public distribution stops must remain active.'
Assert-MsixPlan (-not$plan.PackageGuardPolicyCompatible-and-not$plan.PreMainImmutableInstallationVerified) 'WindowsApps ACL compatibility and bootstrap immutability must not be claimed.'
Assert-MsixPlan (-not$plan.UserDataIsolationProvidedByMsix-and$plan.BrokerIsolationStillRequired) 'Full trust MSIX must not be described as user-data isolation.'
Assert-MsixPlan ($plan.PackageIntegrityDeclarationIncluded-and-not$plan.PackageIntegrityEnforcementVerified-and$plan.MinimumWindowsVersion-ceq'10.0.19041.0') 'The candidate integrity declaration requires Windows 10 version 2004 and must not claim verified enforcement.'
Assert-MsixPlan (-not$plan.PowerShellExecutionPolicyCompatibilityVerified-and@($plan.MissingConditions|Where-Object {$_-like'*Restricted*AllSigned*'}).Count-eq1) 'A signed installer must not be treated as permission to bypass PowerShell policy.'
Assert-MsixPlan (-not$plan.PackagingPerformed-and-not$plan.SigningPerformed-and-not$plan.InstallationPerformed-and-not$plan.ApplicationLaunched-and-not$plan.CertificatesInstalled) 'Planning must not package, sign, install, launch or install trust.'
$validate=& $tool -IdentityName 'TaskPilot.Acceptance' -PublisherSubject 'CN=Synthetic Acceptance Developer' -OutputRoot $noOutput -ValidateOnly
Assert-MsixPlan ($validate.IdentityProvided-and-not(Test-TPBuildPathExists $noOutput)-and$validate.Status-ceq'NOT_READY') 'Provided identity must not make validation write or become ready.'
Reject-MsixPlan {&$tool -WritePlan -ValidateOnly} 'TP-MSIX-PLAN-CONFLICTING-MODE'
Reject-MsixPlan {&$tool -IdentityName 'TaskPilot.Acceptance'} 'TP-MSIX-PLAN-IDENTITY-PAIR-REQUIRED'
Reject-MsixPlan {&$tool -PublisherSubject 'CN=Synthetic'} 'TP-MSIX-PLAN-IDENTITY-PAIR-REQUIRED'
foreach($name in @('', 'ab','../TaskPilot','TaskPilot\Acceptance','TaskPilot Acceptance','TaskPilot.Acceptance.','TaskPilot..Acceptance','Windows.Fake','Microsoft.Fake','CON',('A'*51))){
    Reject-MsixPlan {&$tool -IdentityName $name -PublisherSubject 'CN=Synthetic'} 'TP-MSIX-PLAN-IDENTITY-INVALID'
}
foreach($subject in @('', 'not-a-subject','O=No CN',"CN=Synthetic`nOther=Value",('CN='+('A'*1025)))){
    Reject-MsixPlan {&$tool -IdentityName 'TaskPilot.Acceptance' -PublisherSubject $subject} 'TP-MSIX-PLAN-PUBLISHER-INVALID'
}
Reject-MsixPlan {&$tool -WritePlan -OutputRoot $noOutput} 'TP-MSIX-PLAN-IDENTITY-PAIR-REQUIRED'
Reject-MsixPlan {&$tool -WritePlan -IdentityName 'TaskPilot.Acceptance' -PublisherSubject 'CN=Synthetic'} 'TP-MSIX-PLAN-NEW-OUTPUT-REQUIRED'
Reject-MsixPlan {&$tool -WritePlan -IdentityName 'TaskPilot.Acceptance' -PublisherSubject 'CN=Synthetic' -OutputRoot '//server/share/plan'} 'TP-MSIX-PLAN-OUTPUT-INVALID'
Reject-MsixPlan {&$tool -WritePlan -IdentityName 'TaskPilot.Acceptance' -PublisherSubject 'CN=Synthetic' -OutputRoot '%LOCALAPPDATA%\TaskPilot4'} 'TP-MSIX-PLAN-OUTPUT-INVALID'
Reject-MsixPlan {&$tool -WritePlan -IdentityName 'TaskPilot.Acceptance' -PublisherSubject 'CN=Synthetic' -OutputRoot (Join-Path $repo 'acceptance/not-created')} 'TP-MSIX-PLAN-OUTPUT-INVALID'
$existing=Join-Path $fixture 'existing';$null=[IO.Directory]::CreateDirectory($existing)
$sentinel=Join-Path $existing 'synthetic-sentinel.txt';Write-TPBuildNewText $sentinel 'SYNTHETIC EXISTING DEVELOPER OUTPUT'
$sentinelHash=Get-TPBuildSha $sentinel
Reject-MsixPlan {&$tool -WritePlan -IdentityName 'TaskPilot.Acceptance' -PublisherSubject 'CN=Synthetic' -OutputRoot $existing} 'TP-MSIX-PLAN-OUTPUT-EXISTS'
Assert-MsixPlan ((Get-TPBuildSha $sentinel)-ceq$sentinelHash-and@(Get-TPBuildFiles $existing).Count-eq1) 'Existing output was changed.'
$written=Join-Path $fixture 'candidate-plan'
$publisher='CN="Synthetic & Acceptance"'
$writtenPlan=& $tool -WritePlan -IdentityName 'TaskPilot.Acceptance' -PublisherSubject $publisher -OutputRoot $written
Assert-MsixPlan ($writtenPlan.OutputCreated-and$writtenPlan.Status-ceq'NOT_READY'-and-not$writtenPlan.CanBuildOrLaunch) 'Writing a plan must retain all readiness blocks.'
$manifestPath=Join-Path $written 'AppxManifest.candidate.xml'
$document=New-Object Xml.XmlDocument;$document.XmlResolver=$null;$document.Load($manifestPath)
$namespaces=New-Object Xml.XmlNamespaceManager $document.NameTable
$namespaces.AddNamespace('f','http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$namespaces.AddNamespace('r','http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities')
$namespaces.AddNamespace('u10','http://schemas.microsoft.com/appx/manifest/uap/windows10/10')
$identity=$document.SelectSingleNode('/f:Package/f:Identity',$namespaces)
Assert-MsixPlan ($identity.GetAttribute('Publisher')-ceq$publisher-and$identity.GetAttribute('Name')-ceq'TaskPilot.Acceptance') 'Publisher/identity XML escaping changed input values.'
Assert-MsixPlan ($identity.GetAttribute('ProcessorArchitecture')-ceq'x64'-and$identity.GetAttribute('Version')-ceq'0.4.0.2') 'The plan must use the dedicated x64 version.'
$application=$document.SelectSingleNode('/f:Package/f:Applications/f:Application',$namespaces)
Assert-MsixPlan ($application.GetAttribute('Executable')-ceq'TaskPilot.Acceptance.exe'-and$application.GetAttribute('EntryPoint')-ceq'Windows.FullTrustApplication') 'Manifest must never choose the normal executable.'
Assert-MsixPlan ($document.SelectSingleNode('/f:Package/f:Capabilities/r:Capability',$namespaces).GetAttribute('Name')-ceq'runFullTrust') 'The full-trust capability must be visible, not disguised as OS isolation.'
Assert-MsixPlan ($document.SelectSingleNode('/f:Package/f:Properties/u10:PackageIntegrity/u10:Content',$namespaces).GetAttribute('Enforcement')-ceq'on') 'The candidate must declare content integrity explicitly; an empty PackageIntegrity element has no runtime enforcement.'
Assert-MsixPlan ($document.SelectSingleNode('/f:Package/f:Dependencies/f:TargetDeviceFamily',$namespaces).GetAttribute('MinVersion')-ceq'10.0.19041.0') 'The candidate must not advertise an OS predating its integrity element.'
Assert-MsixPlan (@(Get-TPBuildFiles $written).Count-eq3-and@(Get-TPBuildFiles $written|Where-Object {$_.Extension-in@('.exe','.dll','.zip','.msix','.pfx','.cer')}).Count-eq0) 'Planning must emit only the three design files.'
Assert-MsixPlan ((Get-TPBuildSha $policy)-ceq$policyHash-and(Get-TPBuildSha $guard)-ceq$guardHash-and(Get-TPBuildSha $normalRuntime)-ceq$normalRuntimeHash) 'Trust, guard and public runtime files must remain unchanged.'
$report=[pscustomobject][ordered]@{Stage='Acceptance immutable MSIX planning';Passed=$true;Checks=$checks;Kind='PLAN_ONLY';Status='NOT_READY';ProductionProfileAccessed=$false;PackageCreated=$false;Signed=$false;Installed=$false;Windows10And11Verified=$false}
Write-TPBuildNewText (Join-Path $root ('DesktopAcceptanceMsixPlan_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 6)
return $report
