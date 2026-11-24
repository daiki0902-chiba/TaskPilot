#requires -Version 5.1
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$IdentityName,
    [string]$PublisherSubject,
    [string]$OutputRoot,
    [switch]$ValidateOnly,
    [switch]$WritePlan
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
if($ValidateOnly-and$WritePlan){throw 'TP-MSIX-PLAN-CONFLICTING-MODE'}
$hasName=-not[string]::IsNullOrWhiteSpace($IdentityName)
$hasPublisher=-not[string]::IsNullOrWhiteSpace($PublisherSubject)
if($PSBoundParameters.ContainsKey('IdentityName')-and-not$hasName){throw 'TP-MSIX-PLAN-IDENTITY-INVALID'}
if($PSBoundParameters.ContainsKey('PublisherSubject')-and-not$hasPublisher){throw 'TP-MSIX-PLAN-PUBLISHER-INVALID'}
if($hasName-ne$hasPublisher){throw 'TP-MSIX-PLAN-IDENTITY-PAIR-REQUIRED'}
if($hasName){
    if($IdentityName-cnotmatch'^[A-Za-z0-9][A-Za-z0-9.-]{1,48}[A-Za-z0-9]$'-or$IdentityName.Contains('..')-or$IdentityName-match'^(Microsoft|Windows)(\.|$)'-or$IdentityName-match'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'){
        throw 'TP-MSIX-PLAN-IDENTITY-INVALID'
    }
    if($PublisherSubject.Length-gt1024-or$PublisherSubject-match'[\x00-\x1f\x7f]' -or $PublisherSubject-cnotmatch'^CN='){
        throw 'TP-MSIX-PLAN-PUBLISHER-INVALID'
    }
    try{
        $subject=[Security.Cryptography.X509Certificates.X500DistinguishedName]::new($PublisherSubject)
        if($subject.RawData.Length-lt3){throw 'Invalid subject'}
    }catch{throw 'TP-MSIX-PLAN-PUBLISHER-INVALID'}
}
if($WritePlan-and-not$hasName){throw 'TP-MSIX-PLAN-IDENTITY-PAIR-REQUIRED'}

# This is a build-time design artifact, not an installation, signing request,
# permission to launch, or proof that MSIX will work with this runtime. In
# particular WindowsApps ACLs cannot be substituted for the existing explicit
# package ACL policy without a separately implemented and tested verifier.
$result=[ordered]@{
    FormatVersion=1;Kind='PLAN_ONLY';Purpose='DesktopAcceptanceSyntheticOnly'
    Status='NOT_READY';CanBuildOrLaunch=$false;CanInstall=$false;Distributable=$false
    GeneralDistributionBlocked=$true;AcceptanceDistributionBlocked=$true
    IdentityProvided=$hasName;IdentityName=$(if($hasName){$IdentityName}else{$null})
    PublisherSubject=$(if($hasPublisher){$PublisherSubject}else{$null})
    Version='0.4.0.2';Architecture='x64';Executable='TaskPilot.Acceptance.exe'
    EntryPoint='Windows.FullTrustApplication';MinimumWindowsVersion='10.0.19041.0'
    SupportedClientFamilies=@('Windows.Desktop');Language='ja-JP'
    UserDataIsolationProvidedByMsix=$false;BrokerIsolationStillRequired=$true
    PackageGuardPolicyCompatible=$false;PreMainImmutableInstallationVerified=$false
    PackageIntegrityDeclarationIncluded=$true;PackageIntegrityEnforcementVerified=$false
    PowerShellExecutionPolicyCompatibilityVerified=$false
    TrustConfigurationChanged=$false;CertificatesInstalled=$false;SigningPerformed=$false
    PackagingPerformed=$false;InstallationPerformed=$false;ApplicationLaunched=$false
    ProductionProfileAccessed=$false;OutputCreated=$false
    MissingConditions=@(
        'Developer chooses legal publisher identity, signing provider and private delivery channel'
        'Issued signing subject must exactly match the chosen package Publisher value'
        'A reviewed verifier for OS-protected package installation, including pre-Main configuration and dependency files'
        'Existing explicit PackageGuard ACL policy is incompatible with ordinary WindowsApps policy'
        'PackageIntegrity declaration targets Windows 10 version 2004 or newer, but enforcement has not been verified'
        'Windows SDK MakeAppx schema validation and actual signed package creation'
        'Real acceptance logo assets and approved package identity'
        'Windows 10/11 compatibility: full-trust WinForms, PowerShell 5.1 runspace, GAC and original vendor DLL loading'
        'Default Restricted or enterprise AllSigned PowerShell policies can block external scripts; signing the installer does not resolve host-policy compatibility'
        'Trusted signed acceptance authorization and native client qualification'
    )
}
if(-not$WritePlan){return [pscustomobject]$result}
if([string]::IsNullOrWhiteSpace($OutputRoot)){throw 'TP-MSIX-PLAN-NEW-OUTPUT-REQUIRED'}
if($OutputRoot-match'[\x00-\x1f%]' -or $OutputRoot.StartsWith('\\') -or $OutputRoot.StartsWith('//')){throw 'TP-MSIX-PLAN-OUTPUT-INVALID'}
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $output
if(Test-TPBuildPathExists $output){throw 'TP-MSIX-PLAN-OUTPUT-EXISTS'}
$repo=Get-TPBuildFullPath (Split-Path -Parent $PSScriptRoot)
if((Test-TPBuildBelow $repo $output)-or((Test-TPBuildBelow $output $repo)-and-not(Test-TPBuildBelow $output (Join-Path $repo 'artifacts')))){
    throw 'TP-MSIX-PLAN-OUTPUT-INVALID'
}

# Write XML through XmlWriter. Publisher text is data, never interpolated as XML
# markup, shell code, certificate store selectors, or a signing command.
$builder=New-Object Text.StringBuilder
$settings=New-Object Xml.XmlWriterSettings
$settings.Indent=$true;$settings.OmitXmlDeclaration=$true
$writer=[Xml.XmlWriter]::Create($builder,$settings)
$foundation='http://schemas.microsoft.com/appx/manifest/foundation/windows10'
$uap='http://schemas.microsoft.com/appx/manifest/uap/windows10'
$uap10='http://schemas.microsoft.com/appx/manifest/uap/windows10/10'
$restricted='http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities'
try{
    $writer.WriteStartElement('Package',$foundation)
    $writer.WriteAttributeString('xmlns','uap',$null,$uap)
    $writer.WriteAttributeString('xmlns','uap10',$null,$uap10)
    $writer.WriteAttributeString('xmlns','rescap',$null,$restricted)
    $writer.WriteAttributeString('IgnorableNamespaces','uap uap10 rescap')
    $writer.WriteStartElement('Identity',$foundation)
    foreach($attribute in @(@('Name',$IdentityName),@('Publisher',$PublisherSubject),@('Version','0.4.0.2'),@('ProcessorArchitecture','x64'))){$writer.WriteAttributeString($attribute[0],$attribute[1])}
    $writer.WriteEndElement()
    $writer.WriteStartElement('Properties',$foundation)
    foreach($property in @(@('DisplayName','TaskPilot Acceptance'),@('PublisherDisplayName','Publisher must be confirmed before signing'),@('Description','Synthetic-only acceptance candidate. NOT READY.'),@('Logo','Assets\AcceptanceStoreLogo.png'))){$writer.WriteElementString($property[0],$foundation,$property[1])}
    # Explicitly declare runtime content integrity for the candidate. This is
    # not proof that deployment, the WindowsApps verifier or client DLL loading
    # works. Those checks remain NOT_READY and must run on the selected clients.
    $writer.WriteStartElement('uap10','PackageIntegrity',$uap10)
    $writer.WriteStartElement('uap10','Content',$uap10)
    $writer.WriteAttributeString('Enforcement','on')
    $writer.WriteEndElement();$writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteStartElement('Dependencies',$foundation)
    $writer.WriteStartElement('TargetDeviceFamily',$foundation)
    foreach($attribute in @(@('Name','Windows.Desktop'),@('MinVersion','10.0.19041.0'),@('MaxVersionTested','10.0.19041.0'))){$writer.WriteAttributeString($attribute[0],$attribute[1])}
    $writer.WriteEndElement();$writer.WriteEndElement()
    $writer.WriteStartElement('Resources',$foundation);$writer.WriteStartElement('Resource',$foundation)
    $writer.WriteAttributeString('Language','ja-JP');$writer.WriteEndElement();$writer.WriteEndElement()
    $writer.WriteStartElement('Applications',$foundation);$writer.WriteStartElement('Application',$foundation)
    foreach($attribute in @(@('Id','TaskPilotAcceptance'),@('Executable','TaskPilot.Acceptance.exe'),@('EntryPoint','Windows.FullTrustApplication'))){$writer.WriteAttributeString($attribute[0],$attribute[1])}
    $writer.WriteStartElement('uap','VisualElements',$uap)
    foreach($attribute in @(@('DisplayName','TaskPilot Acceptance'),@('Description','Synthetic-only acceptance candidate. NOT READY.'),@('Square150x150Logo','Assets\Acceptance150.png'),@('Square44x44Logo','Assets\Acceptance44.png'),@('BackgroundColor','transparent'))){$writer.WriteAttributeString($attribute[0],$attribute[1])}
    $writer.WriteEndElement();$writer.WriteEndElement();$writer.WriteEndElement()
    $writer.WriteStartElement('Capabilities',$foundation);$writer.WriteStartElement('rescap','Capability',$restricted)
    $writer.WriteAttributeString('Name','runFullTrust');$writer.WriteEndElement();$writer.WriteEndElement()
    $writer.WriteEndElement();$writer.Flush()
}finally{$writer.Dispose()}
$xml=$builder.ToString()
$parsed=New-Object Xml.XmlDocument;$parsed.XmlResolver=$null;$parsed.LoadXml($xml)
if($parsed.DocumentElement.LocalName-cne'Package'){throw 'TP-MSIX-PLAN-XML-INVALID'}
$null=[IO.Directory]::CreateDirectory($output)
Write-TPBuildNewText (Join-Path $output 'AppxManifest.candidate.xml') $xml
$result.OutputCreated=$true
Write-TPBuildNewText (Join-Path $output 'AcceptanceMsixPlan.json') (ConvertTo-Json -InputObject $result -Depth 8)
Write-TPBuildNewText (Join-Path $output 'PLAN_ONLY_DO_NOT_INSTALL.txt') 'NOT_READY. Design candidate only. No MSIX was built or signed. Do not install, change Windows protections or package ACLs, or launch this application. Assets, identity, package verifier, client qualification and real-device tests remain incomplete.'
return [pscustomobject]$result
