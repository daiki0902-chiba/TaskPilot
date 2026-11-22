#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$checks=0
function Assert-Diagnostic($Condition,[string]$Name){if(-not$Condition){throw ('Diagnostic assertion failed: '+$Name)};$script:checks++}
# Synthetic in-memory broker; no profile path or real logs are touched.
$broker=[pscustomobject]@{Logs='synthetic-logs';IsFaulted=$false;Content='';LengthOverride=$null}
$broker|Add-Member ScriptMethod Exists {param($p)return $this.Content.Length-gt0}
$broker|Add-Member ScriptMethod GetLength {param($p)if($null-ne$this.LengthOverride){return [long]$this.LengthOverride};return [long][Text.Encoding]::UTF8.GetByteCount($this.Content)}
$broker|Add-Member ScriptMethod AppendText {param($p,$text)$this.Content+=$text}
$broker|Add-Member ScriptMethod ReadText {param($p)return $this.Content}
$script:TPRuntimeContext=[pscustomobject]@{IsAcceptance=$true;IsTestMode=$true;Sandbox=$broker}
. (Join-Path $repo 'acceptance/TaskPilot.Acceptance.Diagnostics.ps1')
Write-ActionLog 'PRIVATE-CUSTOMER' 'C:\Users\Private\Business.db sensitive memo'
Write-ErrorLog ([pscustomobject]@{Exception=[Exception]::new('private SQL and task name');ScriptStackTrace='private-path'})
Write-TPAcceptanceEvent SESSION_STARTED
$summary=Get-TPAcceptanceDiagnosticSummary
Assert-Diagnostic ($summary.EventCounts.ACTION-eq1-and$summary.EventCounts.OPERATION_FAILED-eq1-and$summary.EventCounts.SESSION_STARTED-eq1) 'Only fixed event counters persist'
Assert-Diagnostic ($broker.Content-notmatch'PRIVATE|sensitive|Users|Business|SQL|private') 'Raw details discarded'
Assert-Diagnostic (-not$summary.RawLogsIncluded-and-not$summary.UserDataIncluded-and-not$summary.Uploaded) 'No raw data or upload'
Assert-Diagnostic (($summary|ConvertTo-Json -Depth 5)-notmatch'Users|private|Business') 'Summary has no paths or task details'
$broker.Content='{"FormatVersion":1,"Code":"ACTION","Memo":"business"}'
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Injected JSON fields rejected'
$broker.Content='{"FormatVersion":1,"Code":"SECRET"}'
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Unknown event code rejected'
$broker.LengthOverride=65537
$failed=$false;try{$null=Get-TPAcceptanceDiagnosticSummary}catch{$failed=$true}
Assert-Diagnostic $failed 'Oversize reads refused'
$before=$broker.Content;Write-ActionLog 'anything' 'anything'
Assert-Diagnostic ($broker.Content-ceq$before) 'Bounded persistent log'
$broker.LengthOverride=65535;Write-ActionLog 'anything' 'anything'
Assert-Diagnostic ($broker.Content-ceq$before) 'Last append cannot exceed the byte budget'
$broker.LengthOverride=$null;$broker.IsFaulted=$true
$failed=$false;try{Write-ActionLog 'anything' 'anything'}catch{$failed=$true}
Assert-Diagnostic $failed 'Faulted broker refuses logging'
$script:TPRuntimeContext.IsAcceptance=$false;$broker.IsFaulted=$false
$failed=$false;try{Write-ActionLog 'anything' 'anything'}catch{$failed=$true}
Assert-Diagnostic $failed 'No normal-mode diagnostic fallback'
$report=& (Join-Path $repo 'tools/Collect-TaskPilotDesktopAcceptanceLogs.ps1') -PackageRoot $repo
Assert-Diagnostic ($report.Status-ceq'BLOCKED'-and-not$report.ProfileAccessed-and-not$report.UserDataIncluded-and-not$report.Uploaded) 'Standalone collector blocked without profile access'
$result=[pscustomobject]@{Suite='DesktopAcceptanceDiagnostics';Passed=$true;Checks=$checks;ProductionProfileAccessed=$false;GuiExecuted=$false}
if($OutputRoot){$null=[IO.Directory]::CreateDirectory($OutputRoot);[IO.File]::WriteAllText((Join-Path $OutputRoot ('DesktopAcceptanceDiagnostics_'+[guid]::NewGuid().ToString('N')+'.json')),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
$result
