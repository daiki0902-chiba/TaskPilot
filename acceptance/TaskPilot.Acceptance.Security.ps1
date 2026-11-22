#requires -Version 5.1
# Acceptance-only authority. This file is authenticated by the native launcher
# before evaluation. It never resolves a profile, opens TaskPilot data, changes a
# policy/ACL/origin stream, installs a certificate, or uploads anything.
function Stop-TPAcceptanceAuthority([string]$Code) { throw $Code }
function Get-TPAcceptanceRequiredProperty($Object,[string]$Name) {
    if($null-eq$Object-or$null-eq$Object.PSObject.Properties[$Name]){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    return $Object.PSObject.Properties[$Name].Value
}
function Assert-TPAcceptanceExactProperties($Object,[string[]]$Names) {
    if($null-eq$Object-or@($Object.PSObject.Properties).Count-ne$Names.Count){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    foreach($name in $Names){$null=Get-TPAcceptanceRequiredProperty $Object $name}
}
function Assert-TPAcceptanceGrantShape($Grant,[datetime]$NowUtc) {
    Assert-TPAcceptanceExactProperties $Grant @('FormatVersion','Purpose','Version','SyntheticOnly','GeneralReleaseStopped','EnvironmentId','IssuedUtc','ExpiresUtc','PayloadManifestSha256')
    if(($Grant.FormatVersion-isnot[int]-and$Grant.FormatVersion-isnot[long])-or$Grant.FormatVersion-ne1-or$Grant.Purpose-isnot[string]-or$Grant.Purpose-cne'DesktopAcceptanceSyntheticOnly'-or$Grant.Version-isnot[string]-or$Grant.Version-cne'0.4.0.2'-or
       $Grant.SyntheticOnly-isnot[bool]-or-not$Grant.SyntheticOnly-or$Grant.GeneralReleaseStopped-isnot[bool]-or-not$Grant.GeneralReleaseStopped-or
       $Grant.EnvironmentId-isnot[string]-or$Grant.EnvironmentId-cnotmatch'^[a-f0-9]{32}$'-or$Grant.PayloadManifestSha256-isnot[string]-or$Grant.PayloadManifestSha256-cnotmatch'^[a-f0-9]{64}$'){
        Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
    }
    # Fixed UTC lexical format prevents implicit local-time interpretation.
    $issued=[datetime]::MinValue;$expires=[datetime]::MinValue
    $style=[Globalization.DateTimeStyles]::AssumeUniversal-bor[Globalization.DateTimeStyles]::AdjustToUniversal
    if($Grant.IssuedUtc-isnot[string]-or$Grant.ExpiresUtc-isnot[string]-or
       -not[datetime]::TryParseExact($Grant.IssuedUtc,"yyyy-MM-dd'T'HH:mm:ss'Z'",[cultureinfo]::InvariantCulture,$style,[ref]$issued)-or
       -not[datetime]::TryParseExact($Grant.ExpiresUtc,"yyyy-MM-dd'T'HH:mm:ss'Z'",[cultureinfo]::InvariantCulture,$style,[ref]$expires)-or
       $issued-gt$NowUtc-or$expires-le$NowUtc-or$expires-le$issued-or($expires-$issued).TotalDays-gt7){
        Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
    }
}
function Assert-TPAcceptancePayloadShape($Manifest) {
    Assert-TPAcceptanceExactProperties $Manifest @('FormatVersion','Purpose','Version','Files')
    if(($Manifest.FormatVersion-isnot[int]-and$Manifest.FormatVersion-isnot[long])-or$Manifest.FormatVersion-ne1-or$Manifest.Purpose-isnot[string]-or$Manifest.Purpose-cne'DesktopAcceptanceSyntheticOnly'-or$Manifest.Version-isnot[string]-or$Manifest.Version-cne'0.4.0.2'-or
       $Manifest.Files-isnot[Array]-or$Manifest.Files.Count-lt1-or$Manifest.Files.Count-gt2048){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    $paths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $Manifest.Files){
        Assert-TPAcceptanceExactProperties $file @('Path','Sha256')
        if($file.Path-isnot[string]-or$file.Path-cnotmatch'^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$'-or
           @($file.Path.Split('/')|Where-Object {$_-in@('.','..')}).Count-ne0-or$file.Path-in@('AcceptancePayload.json','AcceptanceAuthorization.json','AcceptanceAuthorization.p7s')-or
           $file.Sha256-isnot[string]-or$file.Sha256-cnotmatch'^[a-f0-9]{64}$'-or-not$paths.Add($file.Path)){
            Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
        }
    }
    foreach($required in @('TaskPilot.Acceptance.exe','acceptance/trusted-publishers.json','acceptance/vendor-code-lock.json','acceptance/TaskPilot.Acceptance.Security.ps1','acceptance/TaskPilot.Acceptance.Runtime.ps1','acceptance/TaskPilot.Acceptance.ps1')){
        if(-not$paths.Contains($required)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    }
    # An acceptance package can never contain the ordinary launch executable or
    # source entry, including a renamed copy at a different directory depth.
    foreach($path in $paths){if(($path.Split('/')[-1])-in@('TaskPilot.exe','TaskPilot.ps1')){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}}
}
function Assert-TPAcceptanceVendorCodeLock($Lock) {
    Assert-TPAcceptanceExactProperties $Lock @('FormatVersion','Purpose','Files')
    if(($Lock.FormatVersion-isnot[int]-and$Lock.FormatVersion-isnot[long])-or$Lock.FormatVersion-ne1-or$Lock.Purpose-isnot[string]-or$Lock.Purpose-cne'DesktopAcceptanceSyntheticOnly'-or
       $Lock.Files-isnot[Array]-or$Lock.Files.Count-lt1-or$Lock.Files.Count-gt1024){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    $paths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $Lock.Files){
        Assert-TPAcceptanceExactProperties $file @('Path','Sha256')
        $allowed=$false
        if($file.Path-is[string]){
            $allowed=$file.Path-ceq'Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll'-or
                     $file.Path-ceq'Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll'-or
                     $file.Path-ceq'Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll'-or
                     $file.Path-cmatch'^Modules/ImportExcel/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:dll|ps1|psm1|psd1)$'
        }
        if(-not$allowed-or@($file.Path.Split('/')|Where-Object {$_-in@('.','..')}).Count-ne0-or
           $file.Sha256-isnot[string]-or$file.Sha256-cnotmatch'^[a-f0-9]{64}$'-or-not$paths.Add($file.Path)){
            Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
        }
    }
    foreach($required in @('Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll')){
        if(-not$paths.Contains($required)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
    }
}
function Assert-TPAcceptanceCodeSignature($Lease,[string]$Relative,[string[]]$Pins) {
    $Lease.AssertPinned($Relative)
    if($Lease.HasInternetZone($Relative)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-ORIGIN-BLOCKED'}
    $before=$Lease.Sha256($Relative)
    $signature=Get-AuthenticodeSignature -LiteralPath $Lease.FullPath($Relative) -ErrorAction Stop
    if($signature.Status-ne[Management.Automation.SignatureStatus]::Valid-or$null-eq$signature.SignerCertificate-or
       $Pins-cnotcontains$signature.SignerCertificate.Thumbprint.ToUpperInvariant()-or$before-cne$Lease.Sha256($Relative)){
        Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-SIGNATURE-BLOCKED'
    }
}
function Open-TPAcceptanceAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PackageRoot)
    $lease=$null
    try{
        $launcher='TaskPilot.Acceptance.Launcher'-as[type]
        if($null-eq$launcher-or-not$launcher::IsDedicatedLauncher){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-LAUNCHER-REQUIRED'}
        $pins=@($launcher::TrustedPublisherThumbprints)
        if($pins.Count-eq0){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-PUBLISHER-NOT-CONFIGURED'}
        foreach($pin in $pins){if($pin-isnot[string]-or$pin-cnotmatch'^[A-F0-9]{40}$'){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}}
        if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or-not[Environment]::Is64BitProcess-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-WINDOWS-X64-REQUIRED'}
        if(-not[string]::Equals($PackageRoot,$launcher::PackageRoot,[StringComparison]::OrdinalIgnoreCase)-or
           -not[string]::Equals($launcher.Assembly.Location,(Join-Path $launcher::PackageRoot 'TaskPilot.Acceptance.exe'),[StringComparison]::OrdinalIgnoreCase)){
            Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-LAUNCHER-REQUIRED'
        }
        $guard='TaskPilot.Acceptance.PackageLease'-as[type]
        if($null-eq$guard-or$guard.Assembly-ne$launcher.Assembly){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-LAUNCHER-REQUIRED'}
        # Native guard is part of the already-running signed EXE; no external
        # helper assembly is read to establish the first filesystem boundary.
        $lease=$guard::Open($launcher::PackageRoot)
        if($lease.Sha256('acceptance/trusted-publishers.json')-cne$launcher::TrustConfigurationSha256){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        $policy=$lease.ReadText('acceptance/trusted-publishers.json',65536)|ConvertFrom-Json -ErrorAction Stop
        Assert-TPAcceptanceExactProperties $policy @('FormatVersion','Purpose','AllowedPublisherThumbprints')
        if(($policy.FormatVersion-isnot[int]-and$policy.FormatVersion-isnot[long])-or$policy.FormatVersion-ne1-or$policy.Purpose-isnot[string]-or$policy.Purpose-cne'DesktopAcceptanceSyntheticOnly'-or$policy.AllowedPublisherThumbprints-isnot[Array]-or$policy.AllowedPublisherThumbprints.Count-ne$pins.Count){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        foreach($pin in $pins){if(@($policy.AllowedPublisherThumbprints|Where-Object {$_-ceq$pin}).Count-ne1){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}}
        $grantBytes=$lease.ReadBytes('AcceptanceAuthorization.json',65536)
        $cmsBytes=$lease.ReadBytes('AcceptanceAuthorization.p7s',131072)
        Add-Type -AssemblyName System.Security
        $content=New-Object Security.Cryptography.Pkcs.ContentInfo -ArgumentList (,$grantBytes)
        $cms=New-Object Security.Cryptography.Pkcs.SignedCms -ArgumentList $content,$true
        $cms.Decode($cmsBytes)
        if($cms.SignerInfos.Count-ne1){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        $cms.CheckSignature($false)
        $certificate=$cms.SignerInfos[0].Certificate
        if($null-eq$certificate-or$pins-cnotcontains$certificate.Thumbprint.ToUpperInvariant()){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        $chain=New-Object Security.Cryptography.X509Certificates.X509Chain
        try{
            $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Online
            $chain.ChainPolicy.RevocationFlag=[Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
            $chain.ChainPolicy.VerificationFlags=[Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
            $null=$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
            if(-not$chain.Build($certificate)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        }finally{$chain.Dispose()}
        $grant=$lease.ReadText('AcceptanceAuthorization.json',65536)|ConvertFrom-Json -ErrorAction Stop
        Assert-TPAcceptanceGrantShape $grant ([datetime]::UtcNow)
        if($lease.Sha256('AcceptancePayload.json')-cne$grant.PayloadManifestSha256){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        $payload=$lease.ReadText('AcceptancePayload.json',2097152)|ConvertFrom-Json -ErrorAction Stop
        Assert-TPAcceptancePayloadShape $payload
        $vendorLockEntry=@($payload.Files|Where-Object {$_.Path-ceq'acceptance/vendor-code-lock.json'})
        if($vendorLockEntry.Count-ne1-or$lease.Sha256('acceptance/vendor-code-lock.json')-cne$vendorLockEntry[0].Sha256){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
        $vendorLock=$lease.ReadText('acceptance/vendor-code-lock.json',2097152)|ConvertFrom-Json -ErrorAction Stop
        Assert-TPAcceptanceVendorCodeLock $vendorLock
        $vendorHashes=@{}
        foreach($vendor in $vendorLock.Files){$vendorHashes[$vendor.Path]=$vendor.Sha256}
        $expected=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($file in $payload.Files){
            $null=$expected.Add($file.Path)
            if($lease.Sha256($file.Path)-cne$file.Sha256){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
            if($lease.HasInternetZone($file.Path)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-ORIGIN-BLOCKED'}
            if([IO.Path]::GetExtension($file.Path)-in@('.exe','.dll','.ps1','.psm1','.psd1')){
                if($vendorHashes.ContainsKey($file.Path)){
                    # Original vendor bytes stay unchanged. The reviewed vendor
                    # lock and each digest are bound by this purpose-signed grant;
                    # project code cannot claim this exception by arbitrary path.
                    if($vendorHashes[$file.Path]-cne$file.Sha256){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}
                }else{Assert-TPAcceptanceCodeSignature $lease $file.Path $pins}
            }
        }
        foreach($vendor in $vendorLock.Files){if(-not$expected.Contains($vendor.Path)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'}}
        foreach($special in @('AcceptancePayload.json','AcceptanceAuthorization.json','AcceptanceAuthorization.p7s')){$null=$expected.Add($special)}
        # Include metadata, detached authorization, vendor lock and original
        # third-party bytes in the final origin gate as well as executable code.
        foreach($relative in $expected){if($lease.HasInternetZone($relative)){Stop-TPAcceptanceAuthority 'TP-ACCEPTANCE-ORIGIN-BLOCKED'}}
        $lease.AssertInventory([string[]]@($expected))
        $result=[pscustomobject]@{Status='AUTHORIZED_FOR_DESKTOP_ACCEPTANCE';Purpose=$grant.Purpose;Version=$grant.Version;EnvironmentId=$grant.EnvironmentId;ExpiresUtc=$grant.ExpiresUtc;PayloadSha256=$grant.PayloadManifestSha256;PackageLease=$lease}
        $result|Add-Member -MemberType ScriptMethod -Name Dispose -Value {if($null-ne$this.PackageLease){$this.PackageLease.Dispose()}}
        $lease=$null
        return $result
    }catch{
        if($null-ne$lease){$lease.Dispose()}
        # Never disclose paths, subjects, exception messages, certificate issuer
        # details or JSON/task contents through the launcher diagnostics channel.
        $message=$_.Exception.Message
        if($message-cmatch'^TP-ACCEPTANCE-[A-Z0-9-]+$'){throw $message}
        throw 'TP-ACCEPTANCE-AUTHORITY-BLOCKED'
    }
}
