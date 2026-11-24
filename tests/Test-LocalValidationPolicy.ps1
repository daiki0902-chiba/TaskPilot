#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer-only results directory is required.'}
$source=Join-Path $repo 'local-validation/TaskPilot.LocalValidation.Policy.cs'
Assert-TPBuildNoLinks $source;$sourceHash=Get-TPBuildSha $source
$fixture=Join-Path $output ('LocalPolicy_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
# All signing is ephemeral and in memory. No certificate is created, imported,
# trusted, persisted, uploaded, or used to authorize a real application launch.
if($PSVersionTable.PSEdition-eq'Desktop'){
    $compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
    $parameters=New-Object CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable=$false;$parameters.GenerateInMemory=$false
    $parameters.OutputAssembly=Join-Path $fixture 'Synthetic.LocalPolicy.dll'
    $parameters.CompilerOptions='/target:library /platform:x64 /optimize+'
    $parameters.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($fixture,$false)
    foreach($reference in @('mscorlib.dll','System.dll','System.Core.dll','System.Xml.dll')){$null=$parameters.ReferencedAssemblies.Add($reference)}
    try{
        $compiled=$compiler.CompileAssemblyFromSource($parameters,[string[]]@([IO.File]::ReadAllText($source)))
        if($compiled.Errors.HasErrors){throw (($compiled.Errors|ForEach-Object {$_.ToString()})-join[Environment]::NewLine)}
    }finally{$compiler.Dispose()}
    $assembly=[Reflection.Assembly]::LoadFrom($parameters.OutputAssembly)
    $policyType=$assembly.GetType('TaskPilot.LocalValidation.Policy',$true)
    $hostType=$assembly.GetType('TaskPilot.LocalValidation.HostFacts',$true)
    $payloadType=$assembly.GetType('TaskPilot.LocalValidation.PayloadFile',$true)
}else{
    # Linux only exercises the pure verifier. It does not stand in for Windows
    # compilation, VM collection, pre-Main protection, or GUI execution.
    $types=Add-Type -Path $source -PassThru
    $policyType=@($types|Where-Object {$_.FullName-ceq'TaskPilot.LocalValidation.Policy'})[0]
    $hostType=@($types|Where-Object {$_.FullName-ceq'TaskPilot.LocalValidation.HostFacts'})[0]
    $payloadType=@($types|Where-Object {$_.FullName-ceq'TaskPilot.LocalValidation.PayloadFile'})[0]
}
$checks=0;$cases=New-Object 'Collections.Generic.List[object]'
function Assert-LocalPolicy([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Case-LocalPolicy([string]$CaseId,[scriptblock]$Operation){try{&$Operation;$cases.Add([pscustomobject]@{Id=$CaseId;Passed=$true});Write-Host ('PASS: '+$CaseId)}catch{throw ($CaseId+': '+$_.Exception.GetBaseException().Message)}}
function Hash-LocalPolicy([byte[]]$Bytes){$hash=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}}
function New-LocalPolicyEphemeralKey {
    if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
        $parameters=[Security.Cryptography.CspParameters]::new(24)
        $parameters.Flags=[Security.Cryptography.CspProviderFlags]::CreateEphemeralKey
        $key=[Security.Cryptography.RSACryptoServiceProvider]::new(2048,$parameters)
        $key.PersistKeyInCsp=$false
        return $key
    }
    $key=[Security.Cryptography.RSA]::Create();$key.KeySize=2048;return $key
}
function New-LocalPolicyFacts([hashtable]$Changes){
    $fields=@{Platform='Win32NT';WindowsFamily='Windows11';Build=26100;ProductType=1;Is64Bit=$true;Edition='Desktop';Major=5;Minor=1;Manufacturer='Microsoft Corporation';Model='Virtual Machine';EffectivePolicy='RemoteSigned';Machine=('a'*64);User=('b'*64);Clean=$true;NoShares=$true;NoDrives=$true;NoNetwork=$true;Lease=$true;Session=$true;LocalSource=$true}
    foreach($key in $Changes.Keys){$fields[$key]=$Changes[$key]}
    return $hostType::new($fields.Platform,$fields.WindowsFamily,[int]$fields.Build,[int]$fields.ProductType,[bool]$fields.Is64Bit,$fields.Edition,[int]$fields.Major,[int]$fields.Minor,$fields.Manufacturer,$fields.Model,$fields.EffectivePolicy,$fields.Machine,$fields.User,$fields.Clean,$fields.NoShares,$fields.NoDrives,$fields.NoNetwork,$fields.Lease,$fields.Session,$fields.LocalSource)
}
function New-LocalPolicyManifest([string[]]$Names){
    $lines=New-Object 'Collections.Generic.List[string]';$lines.Add('TASKPILOT-LOCAL-MANIFEST-1');$lines.Add('Purpose=LocalDeveloperValidationSyntheticOnly');$lines.Add('Version=0.4.0.2')
    $sorted=[string[]]$Names.Clone();[Array]::Sort($sorted,[StringComparer]::Ordinal)
    foreach($name in $sorted){$lines.Add(('File='+('c'*64)+' '+$name))}
    return [Text.Encoding]::ASCII.GetBytes(([string]::Join("`n",$lines.ToArray())+"`n"))
}
function New-LocalPolicyPayload([string[]]$Names,[hashtable]$Changes){
    $array=[Array]::CreateInstance($payloadType,$Names.Count)
    for($index=0;$index-lt$Names.Count;$index++){
        $fileHash='c'*64;$lease=$true;$origin=$true
        if($index-eq0){if($Changes.ContainsKey('Hash')){$fileHash=$Changes.Hash};if($Changes.ContainsKey('Lease')){$lease=$Changes.Lease};if($Changes.ContainsKey('Origin')){$origin=$Changes.Origin}}
        $array.SetValue($payloadType::new([string]$Names[$index],[string]$fileHash,$lease,$origin),$index)
    }
    return ,$array
}
function New-LocalPolicyReceipt([byte[]]$Manifest,[hashtable]$Changes){
    $fields=[ordered]@{Purpose='LocalDeveloperValidationSyntheticOnly';Version='0.4.0.2';SourceCommit=('d'*40);EnvironmentId=('e'*32);MachineVmBindingSha256=('a'*64);UserBindingSha256=('b'*64);IssuedUtc='2026-11-23T10:00:00Z';ExpiresUtc='2026-11-24T10:00:00Z';PayloadManifestSha256=(Hash-LocalPolicy $Manifest)}
    foreach($key in $Changes.Keys){$fields[$key]=$Changes[$key]}
    $lines=New-Object 'Collections.Generic.List[string]';$lines.Add('TASKPILOT-LOCAL-RECEIPT-1');foreach($entry in $fields.GetEnumerator()){$lines.Add(($entry.Key+'='+$entry.Value))}
    return [Text.Encoding]::ASCII.GetBytes(([string]::Join("`n",$lines.ToArray())+"`n"))
}
function Verify-LocalPolicy([byte[]]$Receipt,[byte[]]$Manifest,$Facts,$Observed,[byte[]]$Signature,[string]$PublicXml){
    if(-not$Signature){$Signature=$rsa.SignData($Receipt,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)}
    if(-not$PublicXml){$PublicXml=$publicKey}
    return $policyType::Verify($Receipt,$Signature,$Manifest,$PublicXml,('d'*40),$Facts,$Observed,$now)
}
function Reject-LocalPolicy($Result){
    Assert-LocalPolicy (-not$Result.CoreVerified-and-not$Result.CanLaunch-and$Result.Status-ceq'BLOCKED'-and$Result.Code-cmatch'^TP-LOCAL-[A-Z0-9-]+$') ('Invalid synthetic input was not safely rejected: '+$Result.Code)
}
$names=[string[]]@('TaskPilot.LocalValidation.exe','local-validation/TaskPilot.LocalValidation.ps1','local-validation/TaskPilot.LocalValidation.Runtime.ps1','Runtime/TaskPilot.TestSandbox.dll','Codec/TaskPilotMigrationCodec.dll','Modules/TaskPilot.Storage/TaskPilot.Storage.psm1','Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Modules/ImportExcel/ImportExcel.psm1','Modules/ImportExcel/EPPlus.dll','schema/001_initial.sql')
$now=[datetime]::Parse('2026-11-23T12:00:00Z',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal-bor[Globalization.DateTimeStyles]::AssumeUniversal)
$rsa=New-LocalPolicyEphemeralKey;$otherKey=$null
try{
    $publicKey=$rsa.ToXmlString($false);$manifest=New-LocalPolicyManifest $names;$receipt=New-LocalPolicyReceipt $manifest @{};$facts=New-LocalPolicyFacts @{};$observed=New-LocalPolicyPayload $names @{}
    Case-LocalPolicy 'LP01' {
        $result=Verify-LocalPolicy $receipt $manifest $facts $observed
        Assert-LocalPolicy ($result.CoreVerified-and$result.Status-ceq'CORE_VERIFIED_NOT_READY'-and-not$result.CanLaunch-and-not$result.ProductionAdmissionImplemented-and-not$result.OsTrustChanged) 'Pure valid evidence must remain NOT_READY for production.'
        $readiness=$policyType::ProductionAdmission();Reject-LocalPolicy $readiness
        Assert-LocalPolicy ($readiness.Code-ceq'TP-LOCAL-PROVISIONING-AND-PARENT-HOST-REQUIRED') 'Caller facts must never be a production admission override.'
    }
    Case-LocalPolicy 'LP02' {
        $signature=$rsa.SignData($receipt,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $tampered=[byte[]]$receipt.Clone();$tampered[45]=$tampered[45]-bxor1
        Reject-LocalPolicy (Verify-LocalPolicy $tampered $manifest $facts $observed $signature)
        $signature[0]=$signature[0]-bxor1;Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts $observed $signature)
        $script:otherKey=New-LocalPolicyEphemeralKey
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts $observed $null ($script:otherKey.ToXmlString($false)))
    }
    Case-LocalPolicy 'LP03' {
        foreach($change in @(@{Purpose='DesktopAcceptanceSyntheticOnly'},@{Purpose='GeneralRelease'},@{Version='0.4.0.1'},@{SourceCommit=('f'*40)},@{EnvironmentId='..'},@{EnvironmentId=('E'*32)},@{MachineVmBindingSha256=('A'*64)},@{UserBindingSha256='private-user'},@{PayloadManifestSha256='bad'})){
            Reject-LocalPolicy (Verify-LocalPolicy (New-LocalPolicyReceipt $manifest $change) $manifest $facts $observed)
        }
    }
    Case-LocalPolicy 'LP04' {
        foreach($change in @(@{IssuedUtc='2026-11-23T13:00:00Z'},@{ExpiresUtc='2026-11-23T11:00:00Z'},@{ExpiresUtc='2026-11-25T10:00:00Z'},@{ExpiresUtc='2026-11-23T10:00:00Z'},@{ExpiresUtc='2026-11-24T10:00:00'},@{IssuedUtc='2026-11-23T10:00:00+00:00'})){
            Reject-LocalPolicy (Verify-LocalPolicy (New-LocalPolicyReceipt $manifest $change) $manifest $facts $observed)
        }
    }
    Case-LocalPolicy 'LP05' {
        foreach($change in @(@{ProductType=3},@{Platform='Unix'},@{Is64Bit=$false},@{Edition='Core'},@{Major=7},@{Minor=0},@{Manufacturer='Physical developer machine'},@{Model='Host with Hyper-V enabled'},@{WindowsFamily='WindowsServer'},@{Build=7601})){
            Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest (New-LocalPolicyFacts $change) $observed)
        }
        $allowed=Verify-LocalPolicy $receipt $manifest (New-LocalPolicyFacts @{WindowsFamily='Windows10';Build=19045;EffectivePolicy='Unrestricted'}) $observed
        Assert-LocalPolicy ($allowed.CoreVerified-and-not$allowed.CanLaunch) 'Other supported client evidence must still be core-only.'
    }
    Case-LocalPolicy 'LP06' {
        foreach($policy in @('Restricted','AllSigned','Bypass','Unknown','RemoteSigned ','')){
            Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest (New-LocalPolicyFacts @{EffectivePolicy=$policy}) $observed)
        }
    }
    Case-LocalPolicy 'LP07' {
        foreach($name in @('Clean','NoShares','NoDrives','NoNetwork','Lease','Session','LocalSource')){
            foreach($value in @($false,$null)){$change=@{};$change[$name]=$value;Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest (New-LocalPolicyFacts $change) $observed)}
        }
    }
    Case-LocalPolicy 'LP08' {
        foreach($change in @(@{Machine=('f'*64)},@{User=('f'*64)},@{Machine=''},@{User=''})){
            Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest (New-LocalPolicyFacts $change) $observed)
        }
    }
    Case-LocalPolicy 'LP09' {
        $different=[byte[]]$manifest.Clone();$different[$different.Length-2]=[byte][char]'X'
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $different $facts $observed)
        $partial=New-LocalPolicyManifest ([string[]]($names|Where-Object {$_-cne'TaskPilot.LocalValidation.exe'}))
        Reject-LocalPolicy (Verify-LocalPolicy (New-LocalPolicyReceipt $partial @{}) $partial $facts $observed)
        foreach($bad in @('../Settings.json','C:/TaskPilot4.db','//server/share/file','safe/%LOCALAPPDATA%.json','safe/CON.txt','safe/a.','other/TaskPilot.exe','other/TaskPilot.ps1','other/TaskPilot.Acceptance.exe','Data/task.json','logs/output.txt','safe/database.db','safe/local.db-wal')){
            $badManifest=New-LocalPolicyManifest ([string[]]($names+@($bad)))
            Reject-LocalPolicy (Verify-LocalPolicy (New-LocalPolicyReceipt $badManifest @{}) $badManifest $facts $observed)
        }
        $duplicate=New-LocalPolicyManifest ([string[]]($names+@($names[0])))
        Reject-LocalPolicy (Verify-LocalPolicy (New-LocalPolicyReceipt $duplicate @{}) $duplicate $facts $observed)
        $alias=New-LocalPolicyManifest ([string[]]($names+@('SCHEMA/001_INITIAL.SQL')))
        Reject-LocalPolicy (Verify-LocalPolicy (New-LocalPolicyReceipt $alias @{}) $alias $facts $observed)
    }
    Case-LocalPolicy 'LP10' {
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts (New-LocalPolicyPayload ([string[]]$names[0..($names.Count-2)]) @{}))
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts (New-LocalPolicyPayload ([string[]]($names+@('unexpected.dll'))) @{}))
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts (New-LocalPolicyPayload $names @{Hash=('f'*64)}))
        foreach($change in @(@{Lease=$false},@{Lease=$null},@{Origin=$false},@{Origin=$null})){
            Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts (New-LocalPolicyPayload $names $change))
        }
    }
    Case-LocalPolicy 'LP11' {
        $receiptText=[Text.Encoding]::ASCII.GetString($receipt)
        $noncanonicalTexts=@(
            $receiptText.Replace("`n","`r`n")
            $receiptText.TrimEnd("`n")
            ($receiptText+"Approved=true`n")
        )
        foreach($text in $noncanonicalTexts){
            $noncanonical=[Text.Encoding]::UTF8.GetBytes($text);Reject-LocalPolicy (Verify-LocalPolicy $noncanonical $manifest $facts $observed)
        }
        $privateXml=$rsa.ToXmlString($true)
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts $observed $null $privateXml)
        Reject-LocalPolicy (Verify-LocalPolicy $receipt $manifest $facts $observed $null '<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///must-not-read">]><RSAKeyValue>&secret;</RSAKeyValue>')
    }
    Case-LocalPolicy 'LP12' {
        $summary=Verify-LocalPolicy $receipt $manifest $facts $observed
        $json=$summary|ConvertTo-Json -Depth 5
        Assert-LocalPolicy ($json-notmatch('a'*64)-and$json-notmatch('b'*64)-and$json-notmatch'private-user|MachineVmBinding|UserBinding|RSAKeyValue') 'Result must not export host identifiers, input data or key material.'
        Assert-LocalPolicy ((Get-TPBuildSha $source)-ceq$sourceHash) 'Verifier source changed during verification.'
        Assert-LocalPolicy (-not$summary.CanLaunch-and-not$summary.OsTrustChanged) 'Pure core verification cannot change OS trust or authorize production.'
    }
}finally{if($null-ne$otherKey){$otherKey.Dispose()};$rsa.Dispose()}
$result=[pscustomobject][ordered]@{Stage='Local validation pure receipt and host policy core';Passed=$true;Cases=$cases.ToArray();Checks=$checks;SourceSha256=$sourceHash;NativeWindowsRuntimeCompiled=($PSVersionTable.PSEdition-eq'Desktop');RealHostFactsCollected=$false;ActualCleanVmVerified=$false;ProductionAdmissionImplemented=$false;ApplicationLaunched=$false;CanLaunch=$false;CertificateStoreChanged=$false;PrivateKeyPersisted=$false;ProductionProfileAccessed=$false;Windows10And11Verified=$false}
Write-TPBuildNewText (Join-Path $output ('LocalValidationPolicy_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $result -Depth 8)
return $result
