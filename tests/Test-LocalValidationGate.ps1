#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot,[string]$LocalExecutable)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer report directory is required.'}
$fixture=Join-Path $output ('LocalGate_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$sentinel=Join-Path $fixture 'SyntheticNormalData.txt';[IO.File]::WriteAllText($sentinel,'SYNTHETIC PRIVATE INPUT MUST NOT BE OPENED')
$before=Get-TPBuildSha $sentinel;$checks=0
function Assert-LocalGate([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
$handle=[IO.File]::Open($sentinel,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    foreach($requested in @($sentinel,'%LOCALAPPDATA%\TaskPilot4','\\server\share','SYNTHETIC-NOT-A-PACKAGE')){
        $result=& (Join-Path $repo 'tools/Test-TaskPilotLocalValidation.ps1') -PackageRoot $requested
        Assert-LocalGate ($result.Status-ceq'NOT_READY'-and-not$result.CanLaunch-and-not$result.ProfileAccessed-and-not$result.UserDataAccessed-and-not$result.SyntheticAreaCreated) 'Missing local admission must not select any state path.'
        Assert-LocalGate (($result|ConvertTo-Json -Depth 8)-notmatch'PRIVATE INPUT|server\\share|TaskPilot4') 'Gate output may contain fixed codes only.'
    }
}finally{$handle.Dispose()}
Assert-LocalGate ((Get-TPBuildSha $sentinel)-ceq$before) 'The synthetic ordinary sentinel changed.'
$native=$false
if($LocalExecutable){
    if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw 'Native local executable checks require Windows.'}
    $exe=Get-TPBuildFullPath $LocalExecutable;Assert-TPBuildNoLinks $exe
    foreach($argument in @('--preflight','--collect-logs','--test-mode','--force')){
        $p=New-Object Diagnostics.Process;$p.StartInfo.FileName=$exe;$p.StartInfo.Arguments=$argument;$p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
        try{if(-not$p.Start()-or-not$p.WaitForExit(15000)){try{$p.Kill()}catch{};throw 'Local gate process did not complete.'};Assert-LocalGate ($p.ExitCode-eq2) 'The local executable must refuse every unqualified entry.'}finally{$p.Dispose()}
    }
    $native=$true
}
$report=[pscustomobject]@{Stage='Local developer validation refusal';Passed=$true;Checks=$checks;NativeExecutableTested=$native;CanLaunch=$false;ProductionProfileAccessed=$false;ApplicationLaunched=$false;PolicyChanged=$false;TrustStoreChanged=$false;Windows10And11Verified=$false}
Write-TPBuildNewText (Join-Path $output ('LocalValidationGate_'+[guid]::NewGuid().ToString('N')+'.json')) ($report|ConvertTo-Json -Depth 8)
$report
