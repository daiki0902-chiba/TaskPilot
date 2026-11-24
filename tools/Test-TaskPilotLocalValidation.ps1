#requires -Version 5.1
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
# No profile, registry user state, output root, ordinary application location,
# log directory or package content is resolved by this refusal-only preflight.
$hostType='TaskPilot.LocalValidation.Host'-as[type]
$code='TP-LOCAL-DEDICATED-HOST-REQUIRED'
if($null-ne$hostType){
    if(-not$hostType::IsLocalValidationHost-or-not$hostType::HasProtectedParent){
        $code='TP-LOCAL-PROTECTED-PARENT-PROTOCOL-REQUIRED'
    }else{
        # Even a future attested host needs a reviewed provisioning + live
        # parent protocol and target-client qualification. No READY path exists
        # in this revision; no caller supplied object can turn it on.
        $code='TP-LOCAL-CLEAN-VM-QUALIFICATION-REQUIRED'
    }
}
[pscustomobject][ordered]@{
    FormatVersion=1;Purpose='LocalDeveloperValidationSyntheticOnly';Version='0.4.0.2'
    Status='NOT_READY';CanLaunch=$false;Code=$code
    Checks=@(
        [pscustomobject]@{Name='TrustedLocalBuildAndProtectedParent';Passed=$false;Code=$code}
        [pscustomobject]@{Name='HostProvisionedCleanVM';Passed=$false;Code='TP-LOCAL-CLEAN-VM-PROVISIONING-REQUIRED'}
        [pscustomobject]@{Name='UnchangedClientHostCompatibility';Passed=$false;Code='TP-LOCAL-CLIENT-HOST-QUALIFICATION-REQUIRED'}
    )
    ProfileAccessed=$false;UserDataAccessed=$false;SyntheticAreaCreated=$false
    ApplicationLaunched=$false;CertificateStoreChanged=$false;PolicyChanged=$false
    GeneralReleaseAuthorized=$false;IndependentModeReleaseAuthorized=$false;AcceptanceReleaseAuthorized=$false
}
