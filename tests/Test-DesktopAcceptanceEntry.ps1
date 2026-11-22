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
$fixture=Join-Path $output ('AcceptanceEntry_'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$checks=0
function Assert-Entry([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
function Expect-EntryDenied([scriptblock]$Action,[string]$Code){
    $caught=$null;try{$null=&$Action}catch{$caught=$_}
    Assert-Entry ($null-ne$caught-and$caught.Exception.Message-like('*'+$Code+'*')) ('Expected fail-closed code '+$Code)
}
$normal=Join-Path $repo 'TaskPilot.ps1'
$normalHash=Get-TPBuildSha $normal
$publicRuntime=Join-Path $repo 'Runtime/TaskPilot.Runtime.ps1'
$publicRuntimeHash=Get-TPBuildSha $publicRuntime
$entry=Join-Path $repo 'acceptance/TaskPilot.Acceptance.ps1'
$runtime=Join-Path $repo 'acceptance/TaskPilot.Acceptance.Runtime.ps1'
$generated=Join-Path $fixture 'Generated.ps1'
$result=& (Join-Path $repo 'tools/New-TaskPilotDesktopAcceptanceEntry.ps1') -OutputPath $generated
Assert-Entry ($result.DedicatedAcceptanceEntry-and-not$result.ArgumentsSupported-and-not$result.GeneralRuntimeChanged) 'The generator contract must describe a dedicated entry without normal-mode arguments.'
Assert-Entry ((Get-TPBuildSha $generated)-ceq(Get-TPBuildSha $entry)) 'The committed acceptance GUI must reproduce exactly from the existing TaskPilot GUI.'
foreach($path in @($entry,$runtime,(Join-Path $repo 'tools/New-TaskPilotDesktopAcceptanceEntry.ps1'))){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Entry ($errors.Count-eq0) 'A dedicated acceptance source does not parse.'
}
$tokens=$null;$errors=$null
$entryAst=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
Assert-Entry (@($entryAst.ParamBlock.Parameters).Count-eq0) 'The acceptance GUI must not expose mode, root, ID, or normal fallback arguments.'
$entryText=[IO.File]::ReadAllText($entry)
Assert-Entry ($entryText.Contains('$LegacyRoot = $null # Acceptance never selects, checks, or migrates legacy data.')) 'The acceptance entry must have no legacy root.'
Assert-Entry ($entryText.Contains("acceptance/TaskPilot.Acceptance.Gui.ps1")) 'The dedicated GUI must install code-only diagnostic/visual overrides.'
Assert-Entry ($entryText.IndexOf("acceptance/TaskPilot.Acceptance.Diagnostics.ps1",[StringComparison]::Ordinal)-gt$entryText.IndexOf("Adapters/TaskPilot.GuiStartup.ps1",[StringComparison]::Ordinal)-and$entryText.IndexOf("acceptance/TaskPilot.Acceptance.Diagnostics.ps1",[StringComparison]::Ordinal)-lt$entryText.IndexOf('    Initialize-TPGuiApplication',[StringComparison]::Ordinal)) 'Content-free diagnostics must replace original log handlers before GUI initialization.'
Assert-Entry ($entryText.Contains('finally { Close-TPDesktopAcceptanceRuntime }')) 'Application exit must dispose both the sandbox and package authority.'
Assert-Entry ($entryText.IndexOf('DEDICATED-LAUNCHER-REQUIRED',[StringComparison]::Ordinal)-lt$entryText.IndexOf('$InstallRoot=',[StringComparison]::Ordinal)) 'Standalone execution must stop before selecting a package path.'
Assert-Entry ($entryText.IndexOf('Open-TPAcceptanceAuthorization',[StringComparison]::Ordinal)-lt$entryText.IndexOf("FullPath('Runtime/TaskPilot.Runtime.ps1')",[StringComparison]::Ordinal)) 'General helpers must only load after package authority is established.'
$runtimeText=[IO.File]::ReadAllText($runtime)
Assert-Entry ($runtimeText.IndexOf('Open-TPAcceptanceAuthorization',[StringComparison]::Ordinal)-lt$runtimeText.IndexOf("GetFolderPath('LocalApplicationData')",[StringComparison]::Ordinal)) 'Authority must precede any profile resolution.'
Assert-Entry ($runtimeText.IndexOf('TP-ACCEPTANCE-PREFLIGHT-BLOCKED',[StringComparison]::Ordinal)-lt$runtimeText.IndexOf("GetFolderPath('LocalApplicationData')",[StringComparison]::Ordinal)) 'The native client readiness gate must precede profile resolution.'
Assert-Entry ($runtimeText.Contains("$"+'preflight.Status-cne''READY_FOR_DESKTOP_ACCEPTANCE''')) 'The runtime must independently require the explicit acceptance readiness result.'
Assert-Entry (-not$runtimeText.Contains('Initialize-TPRuntime ')) 'The dedicated runtime must never route through the general runtime initializer.'
Assert-Entry ($runtimeText.Contains('IsTestMode=$true;TestMode=$true;IsAcceptance=$true')) 'All GUI/storage adapters must select their synthetic sandbox branches.'
Assert-Entry ($runtimeText.Contains("$"+'sandboxType.GetMethod(''CreateAcceptance'').Invoke($null,@($profile,$authority.EnvironmentId))')) 'The environment ID must come from signed authority and use the separate acceptance factory.'
# Standalone source invocation is intentionally unsupported, even from a valid
# package location. These tests never select the real user profile or load GUI.
$nativeWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
if($nativeWindows){
    Expect-EntryDenied {& $entry} 'TP-ACCEPTANCE-DEDICATED-LAUNCHER-REQUIRED'
    Expect-EntryDenied {& $entry -TestMode} 'parameter cannot be found'
}else{
    # Binding the original WinForms body on Linux can initialize unsupported
    # System.Drawing metadata before execution. Exercise its exact generated
    # bootstrap here; the complete source invocation remains a Windows test.
    $bootstrap=[scriptblock]::Create($entryText.Substring(0,$entryText.IndexOf('$LocalAppData = $script:TPRuntimeContext.ProfileRoot',[StringComparison]::Ordinal)))
    Expect-EntryDenied {& $bootstrap} 'TP-ACCEPTANCE-DEDICATED-LAUNCHER-REQUIRED'
    Expect-EntryDenied {& $bootstrap -TestMode} 'parameter cannot be found'
}
. $runtime
Expect-EntryDenied {Initialize-TPDesktopAcceptanceRuntime -InstallRoot (Join-Path $fixture 'MustNotBeInspected')} 'TP-ACCEPTANCE-DEDICATED-LAUNCHER-REQUIRED'
$selected=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
Assert-Entry ($null-eq$selected-or$null-eq$selected.Value) 'Denied acceptance startup must not select any runtime context.'
. $publicRuntime
Expect-EntryDenied {Initialize-TPRuntime -TestMode -TestEnvironmentId '1234567890abcdef1234567890abcdef'} 'TP-ISOLATION-BLOCKED'
Assert-Entry ((Get-TPBuildSha $normal)-ceq$normalHash-and(Get-TPBuildSha $publicRuntime)-ceq$publicRuntimeHash) 'Neither generation nor acceptance tests may change normal application or public runtime sources.'
$report=[pscustomobject]@{Stage='Dedicated desktop acceptance entry';Passed=$true;Checks=$checks;ProfileAccessed=$false;ApplicationLaunched=$false;CompleteEntryNegativeInvoked=$nativeWindows;PublicTestModeStillBlocked=$true;Windows10And11GuiVerified=$false;ProductionDataAccessed=$false}
Write-TPBuildNewText (Join-Path $output ('AcceptanceEntry_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 6)
return $report
