#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer report directory is required.'}
$checks=0
function Assert-HostPolicy([bool]$Condition,[string]$Code){$script:checks++;if(-not$Condition){throw $Code}}
$nativeExecuted=$false;$policy=$null;$managerName=$null;$managerExposed=$false;$probeAllowed=$null;$scopeResults=@()
$native=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT-and$PSVersionTable.PSEdition-eq'Desktop'-and
    $PSVersionTable.PSVersion.Major-eq5-and$PSVersionTable.PSVersion.Minor-eq1-and[Environment]::Is64BitProcess
if($native){
    $fixture=Join-Path $output ('HostPolicy_'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($fixture)
    $probe=Join-Path $fixture 'SyntheticPolicyProbe.ps1'
    # This harmless local file does not invoke TaskPilot or access any profile.
    # It is deliberately unsigned. No execution policy is changed to run it.
    [IO.File]::WriteAllText($probe,"'TP_HOST_SYNTHETIC_OK'`r`n",[Text.UTF8Encoding]::new($false))
    $before=Get-TPBuildSha $probe
    $oldModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Process')
    $oldModuleCache=[Environment]::GetEnvironmentVariable('PSModuleAnalysisCachePath','Process')
    $runspace=$null
    try{
        # Mirror the dedicated launcher's standard-module-only bootstrap without
        # inspecting inherited module paths or writing the per-user module cache.
        [Environment]::SetEnvironmentVariable('PSModulePath',(Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/Modules'),'Process')
        [Environment]::SetEnvironmentVariable('PSModuleAnalysisCachePath','NUL','Process')
        $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        # A legacy Windows PowerShell runspace may not expose an ISS instance.
        # Do not infer that authorization is disabled from missing introspection.
        if($null-ne$runspace.InitialSessionState-and$null-ne$runspace.InitialSessionState.AuthorizationManager){
            $managerName=$runspace.InitialSessionState.AuthorizationManager.GetType().FullName
            $managerExposed=$true
            Assert-HostPolicy ($managerName-ceq'Microsoft.PowerShell.PSAuthorizationManager') 'TP-HOST-DEFAULT-AUTHORIZATION-MANAGER'
        }
        $shell=[Management.Automation.PowerShell]::Create()
        try{
            $shell.Runspace=$runspace
            $null=$shell.AddCommand('Microsoft.PowerShell.Security\Get-ExecutionPolicy')
            $effective=@($shell.Invoke())
            Assert-HostPolicy (-not$shell.HadErrors-and$effective.Count-eq1) 'TP-HOST-EFFECTIVE-POLICY-READ'
            # PowerShell unwraps PSObject results returned by the SDK pipeline.
            $policy=[string]$effective[0]
        }finally{$shell.Dispose()}
        Assert-HostPolicy ($policy-cin@('Restricted','AllSigned','RemoteSigned','Unrestricted','Bypass')) 'TP-HOST-UNKNOWN-POLICY'
        $shell=[Management.Automation.PowerShell]::Create()
        try{
            $shell.Runspace=$runspace
            $null=$shell.AddCommand('Microsoft.PowerShell.Security\Get-ExecutionPolicy').AddParameter('List')
            $scopes=@($shell.Invoke())
            Assert-HostPolicy (-not$shell.HadErrors-and$scopes.Count-eq5) 'TP-HOST-POLICY-SCOPES-READ'
            foreach($scope in $scopes){
                $scopeName=[string]$scope.Scope;$value=[string]$scope.ExecutionPolicy
                Assert-HostPolicy ($scopeName-cin@('MachinePolicy','UserPolicy','Process','CurrentUser','LocalMachine')-and
                    $value-cin@('Undefined','Restricted','AllSigned','RemoteSigned','Unrestricted','Bypass','Default')) 'TP-HOST-POLICY-SCOPE-SCHEMA'
                $scopeResults+=[pscustomobject]@{Scope=$scopeName;Policy=$value}
            }
        }finally{$shell.Dispose()}
        $shell=[Management.Automation.PowerShell]::Create()
        try{
            $shell.Runspace=$runspace
            $null=$shell.AddCommand($probe)
            $items=@();$thrown=$false
            try{$items=@($shell.Invoke())}catch{$thrown=$true}
            $probeAllowed=-not$thrown-and-not$shell.HadErrors-and$items.Count-eq1-and[string]$items[0]-ceq'TP_HOST_SYNTHETIC_OK'
            if($policy-cin@('Restricted','AllSigned')){
                Assert-HostPolicy (-not$probeAllowed) 'TP-HOST-UNSIGNED-PROBE-MUST-BLOCK'
                Assert-HostPolicy ($thrown-or$shell.HadErrors) 'TP-HOST-REJECTION-MUST-BE-REPORTED'
            }else{
                # This only observes this runner's effective policy. It cannot
                # establish that a Windows client using another policy will run.
                Assert-HostPolicy $probeAllowed 'TP-HOST-LOCAL-PROBE-UNEXPECTEDLY-BLOCKED'
            }
        }finally{$shell.Dispose()}
        Assert-HostPolicy ((Get-TPBuildSha $probe)-ceq$before) 'TP-HOST-SYNTHETIC-PROBE-CHANGED'
        $nativeExecuted=$true
    }finally{
        if($null-ne$runspace){$runspace.Dispose()}
        [Environment]::SetEnvironmentVariable('PSModulePath',$oldModulePath,'Process')
        [Environment]::SetEnvironmentVariable('PSModuleAnalysisCachePath',$oldModuleCache,'Process')
    }
}
$result=[pscustomobject][ordered]@{
    Stage='Default PowerShell SDK host policy observation';Passed=$true;Checks=$checks
    Status=$(if($nativeExecuted){'OBSERVED_CURRENT_HOST_POLICY'}else{'NATIVE_NOT_EXECUTED'})
    NativeExecuted=$nativeExecuted;AuthorizationManagerIntrospectionAvailable=$managerExposed;AuthorizationManagerType=$managerName;EffectivePolicy=$policy
    PolicyScopes=$scopeResults;LocalUnsignedProbeAllowed=$probeAllowed
    PolicyChanged=$false;AuthorizationManagerChanged=$false;CertificateInstalled=$false
    OtherExecutionPoliciesVerified=$false;Windows10And11HostVerified=$false
    ProductionProfileAccessed=$false;ApplicationLaunched=$false;CanAuthorizeAcceptance=$false
}
Write-TPBuildNewText (Join-Path $output ('DesktopAcceptanceHostPolicy_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $result -Depth 7)
return $result
