#requires -Version 5.1
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceCommit,
    [string]$OutputRoot,
    [switch]$ValidateOnly,
    [switch]$WritePlan
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
if($SourceCommit-cnotmatch'^[a-f0-9]{40}$'-or$SourceCommit-ceq('0'*40)){throw 'TP-LOCAL-PLAN-SOURCE-COMMIT-INVALID'}
if($ValidateOnly-and$WritePlan){throw 'TP-LOCAL-PLAN-CONFLICTING-MODE'}

# This plan does not attest cleanliness, collect machine/user identifiers,
# create trust, or issue a receipt. A caller cannot turn a planning value into
# permission to launch. All actual admission checks belong to the local host.
$environmentId=[guid]::NewGuid().ToString('N')
$plan=[ordered]@{
    FormatVersion=1;Kind='LOCAL_VALIDATION_PLAN_ONLY';Purpose='LocalDeveloperValidationSyntheticOnly'
    Version='0.4.0.2';SourceCommit=$SourceCommit;SourceCommitContentVerified=$false
    EnvironmentId=$environmentId;Status='NOT_READY';CanBuild=$false;CanLaunch=$false
    Distributable=$false;SellerCategory='individual';FuturePrivateDelivery='GitHub private repository'
    GeneralDistributionBlocked=$true;IndependentModeDistributionBlocked=$true;AcceptanceDistributionBlocked=$true
    LocalDistributionBlocked=$true;PublicArtifactsAllowed=$false
    CandidateEnvironment='Fresh developer-controlled Hyper-V guest, Windows 10/11 Desktop x64'
    ExistingAllowedPolicies=@('RemoteSigned','Unrestricted')
    BlockedPolicies=@('Restricted','AllSigned','Bypass','Undefined','Unknown')
    RequiredEnvironmentConditions=@(
        'Fresh operating-system installation on a new virtual disk; no reused business image'
        'Dedicated guest user and no real TaskPilot or business data'
        'No host folder/drive mappings, clipboard redirection, enhanced-session redirection or guest file-copy bridge'
        'No network, secondary business disk, cloud drive or production credentials in the guest'
        'Existing effective PowerShell policy permits the actual source and modules without being changed'
        'Source commit, locked dependencies and acquisition-origin evidence are reviewed; downloaded executable trust is not assumed'
        'First parent host is compiled locally from the reviewed source inside the clean guest'
        'Parent pins all package files and directories before child startup and throughout child lifetime'
        'Application-specific receipt binds source, environment, machine/user scope, payload and expiry'
        'All mandatory native safety tests pass on the target Windows client without changing protections'
    )
    PlannedExecutable='TaskPilot.LocalValidation.exe'
    PlannedDataNamespace=('%LOCALAPPDATA%\TaskPilotLocalValidation\'+$environmentId)
    NormalAndOtherTestNamespacesAllowed=$false;LegacyMigrationAllowed=$false
    PaidCodeSigningCertificateRequired=$false;PublicPublisherTrustEstablished=$false
    SelfSignedCertificateInstalled=$false;CertificateStoreChanged=$false
    ApplicationSpecificReceiptIssued=$false;ReceiptPrivateKeyStored=$false
    HyperVOrWindowsFeaturesChanged=$false;VMCreated=$false;OSProtectionChanged=$false
    ExecutionPolicyChanged=$false;FilesUnblocked=$false;PackagesDownloaded=$false
    ExecutableCreated=$false;ZipCreated=$false;ApplicationLaunched=$false
    ProductionProfileAccessed=$false;OutputCreated=$false
    WindowsLicenseCost='Separate from code signing; depends on existing rights and applicable evaluation/licensing terms'
    ReadinessEvidenceMissing=@(
        'Trusted host provisioning and clean-environment provenance; guest VM metadata alone is insufficient'
        'Implemented and verified local parent/child pre-main lease and session protocol'
        'Actual unchanged-policy script/module and DLL compatibility on Windows 10 and Windows 11'
        'Origin-preserving source/dependency acquisition and local build protocol'
        'Target-client GUI, notification, Excel, persistence and failure-recovery verification'
    )
}
if(-not$WritePlan){return [pscustomobject]$plan}
if([string]::IsNullOrWhiteSpace($OutputRoot)){throw 'TP-LOCAL-PLAN-NEW-OUTPUT-REQUIRED'}
if($OutputRoot-match'[\x00-\x1f%]' -or$OutputRoot.StartsWith('\\')-or$OutputRoot.StartsWith('//')){throw 'TP-LOCAL-PLAN-OUTPUT-INVALID'}
$destination=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $destination
if(Test-TPBuildPathExists $destination){throw 'TP-LOCAL-PLAN-OUTPUT-EXISTS'}
$repository=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
if((Test-TPBuildBelow $repository $destination)-or((Test-TPBuildBelow $destination $repository)-and-not(Test-TPBuildBelow $destination (Join-Path $repository 'artifacts')))){throw 'TP-LOCAL-PLAN-OUTPUT-INVALID'}
$null=[IO.Directory]::CreateDirectory($destination)
$plan.OutputCreated=$true
Write-TPBuildNewText (Join-Path $destination 'LocalValidationPlan.json') (ConvertTo-Json -InputObject $plan -Depth 8)
Write-TPBuildNewText (Join-Path $destination 'PLAN_ONLY_DO_NOT_LAUNCH.txt') 'NOT_READY. Planning only. This file is not a receipt, cleanliness attestation, trust configuration, executable or launch permission. No virtual machine, certificate, policy, application or publication setting was changed. Do not launch an old executable, install trust, alter policy, remove origin metadata, or publish a developer build.'
return [pscustomobject]$plan
