#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'An existing developer report directory is required.'}
$fixture=Join-Path $output ('LocalEntry_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$checks=0
function Assert-LocalEntry([bool]$Condition,[string]$Detail){$script:checks++;if(-not$Condition){throw $Detail}}
function Reject-LocalEntry([scriptblock]$Operation,[string]$Pattern){
    $failure=$null;try{$null=&$Operation}catch{$failure=$_}
    Assert-LocalEntry ($null-ne$failure-and$failure.Exception.Message-match$Pattern) ('Expected local refusal '+$Pattern)
}
$protectedSources=@('TaskPilot.ps1','Runtime/TaskPilot.Runtime.ps1','acceptance/TaskPilot.Acceptance.ps1','acceptance/TaskPilot.Acceptance.Runtime.ps1','tools/Test-TaskPilotDesktopAcceptance.ps1')
$sourceBefore=@{};foreach($relative in $protectedSources){$sourceBefore[$relative]=Get-TPBuildSha (Join-Path $repo $relative)}
$entry=Join-Path $repo 'local-validation/TaskPilot.LocalValidation.ps1'
$runtime=Join-Path $repo 'local-validation/TaskPilot.LocalValidation.Runtime.ps1'
$generated=Join-Path $fixture 'Generated.ps1'
$result=& (Join-Path $repo 'tools/New-TaskPilotLocalValidationEntry.ps1') -OutputPath $generated
Assert-LocalEntry ($result.DedicatedLocalValidationEntry-and-not$result.ArgumentsSupported-and-not$result.GeneralRuntimeChanged) 'The generator must not enable a normal or acceptance entry.'
Assert-LocalEntry ((Get-TPBuildSha $generated)-ceq(Get-TPBuildSha $entry)) 'The committed local GUI must reproduce from the preserved normal GUI.'
foreach($relative in @('local-validation/TaskPilot.LocalValidation.ps1','local-validation/TaskPilot.LocalValidation.Runtime.ps1','local-validation/TaskPilot.LocalValidation.Gui.ps1','local-validation/TaskPilot.LocalValidation.Diagnostics.ps1','tools/New-TaskPilotLocalValidationEntry.ps1')){
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $relative),[ref]$tokens,[ref]$errors)
    Assert-LocalEntry ($errors.Count-eq0) 'A local-only source does not parse.'
}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
Assert-LocalEntry (@($ast.ParamBlock.Parameters).Count-eq0) 'The local GUI must not accept root, ID, mode, force, approval or environment options.'
$entryText=[IO.File]::ReadAllText($entry);$runtimeText=[IO.File]::ReadAllText($runtime)
Assert-LocalEntry ($entryText.IndexOf('DEDICATED-HOST-REQUIRED',[StringComparison]::Ordinal)-lt$entryText.IndexOf('$InstallRoot=',[StringComparison]::Ordinal)) 'Unattested direct invocation must stop before selecting any package path.'
Assert-LocalEntry ($entryText.IndexOf('HasProtectedParent',[StringComparison]::Ordinal)-lt$entryText.IndexOf('$InstallRoot=',[StringComparison]::Ordinal)) 'A real protected parent is mandatory before external paths are assigned.'
Assert-LocalEntry ($entryText.IndexOf('OpenCurrentSession()',[StringComparison]::Ordinal)-lt$entryText.IndexOf("FullPath('Runtime/TaskPilot.Runtime.ps1')",[StringComparison]::Ordinal)) 'A host-verified session must precede loading common helpers.'
Assert-LocalEntry ($entryText.Contains('$LegacyRoot = $null # Local validation never selects, checks, or migrates legacy data.')) 'The local GUI cannot select a legacy root.'
Assert-LocalEntry ($runtimeText.IndexOf('TP-LOCAL-PREFLIGHT-BLOCKED',[StringComparison]::Ordinal)-lt$runtimeText.IndexOf("GetFolderPath('LocalApplicationData')",[StringComparison]::Ordinal)) 'Preflight must block before resolving the actual user profile.'
Assert-LocalEntry ($runtimeText.Contains("'READY_FOR_LOCAL_VALIDATION'")) 'The local runtime must require its own explicit readiness outcome.'
Assert-LocalEntry ($runtimeText.Contains('IsTestMode=$true;TestMode=$true;IsLocalValidation=$true;IsAcceptance=$false')) 'The local runtime must choose only sandbox GUI/storage and its own purpose.'
Assert-LocalEntry ($runtimeText.Contains('::CreateLocalValidation($profileRoot,[string]$session.EnvironmentId)')) 'The data namespace and ID must come from the native session through the fixed factory.'
Assert-LocalEntry (-not$runtimeText.Contains('Initialize-TPRuntime ')-and-not$runtimeText.Contains('Initialize-TPDesktopAcceptanceRuntime ')) 'The local runtime cannot open either stopped initializer.'
$early=$entryText.IndexOf("FullPath('local-validation/TaskPilot.LocalValidation.Diagnostics.ps1')",[StringComparison]::Ordinal)
$late=$entryText.LastIndexOf('. (Join-Path $InstallRoot ''local-validation/TaskPilot.LocalValidation.Diagnostics.ps1'')',[StringComparison]::Ordinal)
Assert-LocalEntry ($early-ge0-and$early-lt$entryText.IndexOf('Adapters/TaskPilot.GuiIsolation.ps1',[StringComparison]::Ordinal)) 'Content-free diagnostics must precede GUI adapter loading.'
Assert-LocalEntry ($late-gt$entryText.IndexOf('Adapters/TaskPilot.GuiStartup.ps1',[StringComparison]::Ordinal)-and$late-lt$entryText.IndexOf('    Initialize-TPGuiApplication',[StringComparison]::Ordinal)) 'Local handlers must be restored after existing adapter declarations.'
$outer=@($ast.EndBlock.Statements|Where-Object {$_-is[Management.Automation.Language.TryStatementAst]})[-1]
$catchText=$outer.CatchClauses[0].Body.Extent.Text
Assert-LocalEntry ($catchText.Contains('Show-TPLocalValidationStartupFailure')-and-not$catchText.Contains('Show-Failure')-and-not$catchText.Contains('Write-ErrorLog')-and-not$catchText.Contains('$_')) 'Startup errors cannot fall back to a raw legacy handler.'
$script:localStartupCalls=0
function Show-Failure{throw 'Legacy failure path was invoked.'}
function Write-ErrorLog{throw 'Legacy raw error logger was invoked.'}
function Show-TPLocalValidationStartupFailure{Assert-LocalEntry ($args.Count-eq0) 'A startup error handler cannot receive private data.';$script:localStartupCalls++}
$catchBody=[scriptblock]::Create($catchText.Substring(1,$catchText.Length-2))
try{throw 'SYNTHETIC PRIVATE USER PATH AND TASK DATA'}catch{&$catchBody}
Assert-LocalEntry ($script:localStartupCalls-eq1) 'The generated startup catch must reach the unique safe helper.'
Assert-LocalEntry ($entryText.Contains('finally { Close-TPLocalValidationRuntime }')) 'Exit must dispose the local sandbox and native session.'
$nativeWindows=[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT
$bootstrap=if($nativeWindows){$null}else{[scriptblock]::Create($entryText.Substring(0,$entryText.IndexOf('$LocalAppData = $script:TPRuntimeContext.ProfileRoot',[StringComparison]::Ordinal)))}
if($nativeWindows){Reject-LocalEntry {&$entry} 'TP-LOCAL-(DEDICATED-HOST|PROTECTED-PARENT)-REQUIRED'}else{Reject-LocalEntry {&$bootstrap} 'TP-LOCAL-(DEDICATED-HOST|PROTECTED-PARENT)-REQUIRED'}
. $runtime
Reject-LocalEntry {Initialize-TPLocalValidationRuntime -InstallRoot (Join-Path $fixture 'NeverOpened')} 'TP-LOCAL-(DEDICATED-HOST|PROTECTED-PARENT)-REQUIRED'
$context=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
Assert-LocalEntry ($null-eq$context-or$null-eq$context.Value) 'A denied local entry must not select any data context.'
# In-memory counter tests deliberately pass sensitive synthetic input. No file
# paths, actual profile, database or normal application logs are accessed.
$broker=[pscustomobject]@{Logs='synthetic-local-logs';IsFaulted=$false;IsLocalValidation=$true;Content='';LengthOverride=$null}
$broker|Add-Member ScriptMethod Exists {param($p)return $this.Content.Length-gt0}
$broker|Add-Member ScriptMethod GetFileLength {param($p)if($null-ne$this.LengthOverride){return [long]$this.LengthOverride};return [long][Text.Encoding]::UTF8.GetByteCount($this.Content)}
$broker|Add-Member ScriptMethod AppendText {param($p,$text)$this.Content+=$text}
$broker|Add-Member ScriptMethod ReadAllTextLimited {param($p,$maximum)return $this.Content}
$script:TPRuntimeContext=[pscustomobject]@{IsLocalValidation=$true;IsTestMode=$true;IsAcceptance=$false;Sandbox=$broker}
. (Join-Path $repo 'local-validation/TaskPilot.LocalValidation.Diagnostics.ps1')
Write-ActionLog 'PRIVATE CUSTOMER' 'C:\Users\Private\Business.db private memo'
Write-ErrorLog ([Exception]::new('SYNTHETIC PRIVATE QUERY'))
$summary=Get-TPLocalValidationDiagnosticSummary
Assert-LocalEntry ($summary.Purpose-ceq'LocalDeveloperValidationSyntheticOnly'-and$summary.EventCounts.ACTION-eq1-and$summary.EventCounts.OPERATION_FAILED-eq1) 'Only local-purpose fixed counters can be emitted.'
Assert-LocalEntry ($broker.Content-notmatch'PRIVATE|Users|Business|private|QUERY') 'Caller action/details and errors must not reach the log.'
Assert-LocalEntry (-not$summary.RawLogsIncluded-and-not$summary.UserDataIncluded-and-not$summary.Uploaded) 'Diagnostics cannot include raw files or upload.'
Reject-LocalEntry {Get-TPLocalValidationDiagnosticSummaryFromSandbox -Sandbox $broker} 'TP-LOCAL-DIAGNOSTIC-READONLY-REQUIRED'
$broker.Content='{"FormatVersion":1,"Code":"ACTION","Path":"SYNTHETIC PRIVATE"}'
Reject-LocalEntry {Get-TPLocalValidationDiagnosticSummary} 'TP-LOCAL-DIAGNOSTIC-FORMAT'
$broker.Content=('x'*65537);$broker.LengthOverride=0
Reject-LocalEntry {Get-TPLocalValidationDiagnosticSummary} 'TP-LOCAL-DIAGNOSTIC-SIZE'
$broker.LengthOverride=65535;$before=$broker.Content;Write-ActionLog 'PRIVATE' 'PRIVATE'
Assert-LocalEntry ($broker.Content-ceq$before) 'A final append cannot exceed the byte budget.'
$broker.IsFaulted=$true
Reject-LocalEntry {Write-ActionLog 'PRIVATE' 'PRIVATE'} 'TP-LOCAL-DIAGNOSTIC-BOUNDARY'
$broker.IsFaulted=$false;$script:TPRuntimeContext.IsAcceptance=$true
Reject-LocalEntry {Write-ActionLog 'PRIVATE' 'PRIVATE'} 'TP-LOCAL-DIAGNOSTIC-CONTEXT'
$script:TPRuntimeContext=$null
. (Join-Path $repo 'Runtime/TaskPilot.Runtime.ps1')
Reject-LocalEntry {Initialize-TPRuntime -TestMode -TestEnvironmentId '1234567890abcdef1234567890abcdef'} 'TP-ISOLATION-BLOCKED'
foreach($relative in $protectedSources){Assert-LocalEntry ((Get-TPBuildSha (Join-Path $repo $relative))-ceq$sourceBefore[$relative]) ('A preserved stopped source changed: '+$relative)}
$report=[pscustomobject][ordered]@{Stage='Local validation GUI scaffold and denial';Passed=$true;Checks=$checks;CompleteEntryNegativeInvoked=$nativeWindows;ProductionProfileAccessed=$false;ApplicationLaunched=$false;Windows10And11GuiVerified=$false;GeneralAndFormalAcceptanceUnchanged=$true;LocalStartAuthorized=$false}
Write-TPBuildNewText (Join-Path $output ('LocalValidationEntry_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 8)
return $report
