#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot
Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer results directory is required.'}
$fixture=Join-Path $output ('DesktopAcceptancePreflight_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$package=Join-Path $fixture 'SyntheticPackage'
$null=[IO.Directory]::CreateDirectory($package)
$sentinel=Join-Path $package 'AcceptanceAuthorization.json'
[IO.File]::WriteAllText($sentinel,'SYNTHETIC PRIVATE TEXT: do not read before launcher attestation.')
$before=Get-TPBuildSha $sentinel
$checks=0
function Assert-DesktopPreflight([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
$checker=Join-Path $repo 'tools/Test-TaskPilotDesktopAcceptance.ps1'
$lease=[IO.File]::Open($sentinel,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    foreach($requested in @($package,'NOT-A-PACKAGE-WITH-PRIVATE-TEXT','%LOCALAPPDATA%\TaskPilot4')){
        $result=& $checker -PackageRoot $requested
        Assert-DesktopPreflight ($result.Status-ceq'BLOCKED'-and$result.CanLaunch-is[bool]-and-not$result.CanLaunch) 'An unattested checker invocation must block.'
        $denials=@($result.Checks|Where-Object {$_.Name-ceq'AcceptanceAuthorization'-and-not$_.Passed})
        Assert-DesktopPreflight ($denials.Count-eq1-and$denials[0].Code-in@('TP-ACCEPTANCE-LAUNCHER-REQUIRED','TP-ACCEPTANCE-PUBLISHER-NOT-CONFIGURED')) 'The checker must report a fixed launcher or publisher denial before package contents.'
        Assert-DesktopPreflight (-not$result.ProfileAccessed-and-not$result.SyntheticAreaPrepared-and-not$result.ApplicationLaunched) 'A denied check must not resolve a profile, prepare state, or launch the application.'
        Assert-DesktopPreflight (-not$result.GeneralReleaseAuthorized-and-not$result.IndependentModeReleaseAuthorized) 'Dedicated checks must never authorize either public channel.'
        Assert-DesktopPreflight (-not$result.ClientNativeQualificationVerified) 'No client qualification runner is present; do not report it passed.'
        $serialized=ConvertTo-Json -InputObject $result -Depth 6 -Compress
        Assert-DesktopPreflight ($serialized-notmatch'PRIVATE-TEXT|LOCALAPPDATA|TaskPilot4|SyntheticPackage|SYNTHETIC PRIVATE TEXT') 'The structured report must not include paths, private input or raw exception text.'
        Assert-DesktopPreflight (@($result.Checks|Where-Object {$_.Code-cnotmatch'^TP-ACCEPTANCE-[A-Z0-9-]+$'}).Count-eq0) 'Only fixed safe check codes may be returned.'
    }
}finally{$lease.Dispose()}
Assert-DesktopPreflight ((Get-TPBuildSha $sentinel)-ceq$before-and@([IO.Directory]::GetFileSystemEntries($package)).Count-eq1) 'Synthetic package contents and layout must remain unchanged.'
$command=Get-Command $checker
foreach($forbidden in @('OutputRoot','TestMode','FirstUse','TestEnvironmentId','ProfileRoot','DataRoot','SkipChecks','Approved')){
    Assert-DesktopPreflight (-not$command.Parameters.ContainsKey($forbidden)) 'The dedicated checker must not expose normal mode, data roots, or approval bypass parameters.'
}
$report=[pscustomobject]@{Stage='Dedicated desktop acceptance preflight denial';Passed=$true;Checks=$checks;Windows10And11Verified=$false;ProductionProfileAccessed=$false;ApplicationLaunched=$false;ClientNativeQualificationImplemented=$false}
Write-TPBuildNewText (Join-Path $output ('DesktopAcceptancePreflight_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 6)
return $report
