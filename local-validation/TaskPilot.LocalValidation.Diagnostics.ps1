#requires -Version 5.1
# Fixed event codes only. Never forward arbitrary action text or ErrorRecords.
function Write-TPLocalValidationEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('ACTION','OPERATION_FAILED','SESSION_STARTED','SESSION_ENDED','BOUNDARY_STOPPED')][string]$Code)
    $selected=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$selected-or$null-eq$selected.Value-or-not$selected.Value.IsLocalValidation-or
       -not$selected.Value.IsTestMode-or$selected.Value.IsAcceptance){throw 'TP-LOCAL-DIAGNOSTIC-CONTEXT'}
    $sandbox=$selected.Value.Sandbox
    if($null-eq$sandbox-or$sandbox.IsFaulted-or-not$sandbox.IsLocalValidation){throw 'TP-LOCAL-DIAGNOSTIC-BOUNDARY'}
    $path=Join-Path ([string]$sandbox.Logs) 'local-validation-events.jsonl'
    $line='{"FormatVersion":1,"Code":"'+$Code+'"}'+[Environment]::NewLine
    $length=if($sandbox.Exists($path)){$sandbox.GetFileLength($path)}else{0}
    if($length+[Text.Encoding]::UTF8.GetByteCount($line)-gt65536){return}
    $sandbox.AppendText($path,$line)
}
function ConvertFrom-TPLocalValidationDiagnosticContent {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory=$true)][string]$Content)
    if([Text.Encoding]::UTF8.GetByteCount($Content)-gt65536){throw 'TP-LOCAL-DIAGNOSTIC-SIZE'}
    $counts=[ordered]@{ACTION=0;OPERATION_FAILED=0;SESSION_STARTED=0;SESSION_ENDED=0;BOUNDARY_STOPPED=0}
    foreach($line in @($Content-split'\r?\n')){
        if($line-eq''){continue}
        if($line-cnotmatch'^\{"FormatVersion":1,"Code":"(ACTION|OPERATION_FAILED|SESSION_STARTED|SESSION_ENDED|BOUNDARY_STOPPED)"\}$'){throw 'TP-LOCAL-DIAGNOSTIC-FORMAT'}
        $counts[$Matches[1]]++
    }
    return [pscustomobject][ordered]@{FormatVersion=1;Purpose='LocalDeveloperValidationSyntheticOnly';Version='0.4.0.2';EventCounts=[pscustomobject]$counts;RawLogsIncluded=$false;UserDataIncluded=$false;Uploaded=$false}
}
function Get-TPLocalValidationDiagnosticSummary {
    [CmdletBinding()]
    param()
    $selected=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$selected-or$null-eq$selected.Value-or-not$selected.Value.IsLocalValidation-or
       -not$selected.Value.IsTestMode-or$selected.Value.IsAcceptance){throw 'TP-LOCAL-DIAGNOSTIC-CONTEXT'}
    $sandbox=$selected.Value.Sandbox
    if($null-eq$sandbox-or$sandbox.IsFaulted-or-not$sandbox.IsLocalValidation){throw 'TP-LOCAL-DIAGNOSTIC-BOUNDARY'}
    $path=Join-Path ([string]$sandbox.Logs) 'local-validation-events.jsonl'
    if(-not$sandbox.Exists($path)){return ConvertFrom-TPLocalValidationDiagnosticContent -Content ''}
    return ConvertFrom-TPLocalValidationDiagnosticContent -Content ($sandbox.ReadAllTextLimited($path,65536))
}
function Get-TPLocalValidationDiagnosticSummaryFromSandbox {
    # The caller must open exactly its admitted local environment read-only and
    # hold the existing local diagnostic lease. This cannot initialize a scope.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Sandbox)
    if($null-eq$Sandbox-or$Sandbox.GetType().FullName-cne'TaskPilot.Runtime.Sandbox'-or
       -not$Sandbox.IsReadOnly-or-not$Sandbox.IsLocalValidation-or$Sandbox.IsDisposed-or
       $Sandbox.IsFaulted-or-not$Sandbox.HasLocalValidationDiagnosticLock){throw 'TP-LOCAL-DIAGNOSTIC-READONLY-REQUIRED'}
    if($Sandbox.EnvironmentId-cnotmatch'^[a-f0-9]{32}$'-or
       [IO.Path]::GetFileName([string]$Sandbox.MarkerPath)-cne'.taskpilot-local-validation-environment'-or
       -not[string]::Equals([string]$Sandbox.Root,(Join-Path (Join-Path ([string]$Sandbox.ProfileRoot) 'TaskPilotLocalValidation') ([string]$Sandbox.EnvironmentId)),[StringComparison]::OrdinalIgnoreCase)){
        throw 'TP-LOCAL-DIAGNOSTIC-PURPOSE'
    }
    $path=Join-Path ([string]$Sandbox.Logs) 'local-validation-events.jsonl'
    if(-not$Sandbox.Exists($path)){return ConvertFrom-TPLocalValidationDiagnosticContent -Content ''}
    return ConvertFrom-TPLocalValidationDiagnosticContent -Content ($Sandbox.ReadAllTextLimited($path,65536))
}
function Write-ActionLog([string]$action,[string]$detail){Write-TPLocalValidationEvent -Code ACTION}
function Write-ErrorLog($record){Write-TPLocalValidationEvent -Code OPERATION_FAILED}
function Show-TPLocalValidationStartupFailure {
    param()
    try{Write-TPLocalValidationEvent -Code OPERATION_FAILED}catch{}
    [System.Windows.Forms.MessageBox]::Show('ローカル検証の処理を停止しました。固定エラーコードと検証結果を確認してください。','TaskPilot [LOCAL VALIDATION ONLY]','OK','Error')|Out-Null
}
function Show-Failure($record){
    $fatal=$true
    try{Write-TPLocalValidationEvent -Code OPERATION_FAILED;$fatal=[bool]$script:TPRuntimeContext.Sandbox.IsFaulted}catch{}
    [System.Windows.Forms.MessageBox]::Show('ローカル検証の処理に失敗しました。診断には内容を含まない件数だけを記録します。','TaskPilot [LOCAL VALIDATION ONLY]','OK','Error')|Out-Null
    if($fatal){
        $timer=Get-Variable NotificationTimer -Scope Script -ErrorAction SilentlyContinue
        if($null-ne$timer-and$null-ne$timer.Value){try{$timer.Value.Stop()}catch{}}
        $window=Get-Variable form -Scope Script -ErrorAction SilentlyContinue
        if($null-ne$window-and$null-ne$window.Value){$window.Value.Close()}
    }
}
