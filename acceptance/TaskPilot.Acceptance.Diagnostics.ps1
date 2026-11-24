#requires -Version 5.1
# Deliberately content-free. Never serialize ErrorRecord, paths, settings, task
# names, notes, SQL, workbooks, databases or arbitrary application log strings.
function Write-TPAcceptanceEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('ACTION','OPERATION_FAILED','SESSION_STARTED','SESSION_ENDED','BOUNDARY_STOPPED')][string]$Code)
    $variable=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$variable-or$null-eq$variable.Value-or-not$variable.Value.IsAcceptance-or-not$variable.Value.IsTestMode){throw 'TP-ACCEPTANCE-DIAGNOSTIC-CONTEXT'}
    $context=$variable.Value
    if($null-eq$context.Sandbox-or$context.Sandbox.IsFaulted){throw 'TP-ACCEPTANCE-DIAGNOSTIC-BOUNDARY'}
    $path=Join-Path ([string]$context.Sandbox.Logs) 'acceptance-events.jsonl'
    # Bound total log size without reading existing application text. Overflow
    # stops further collection; it does not delete or rotate any other file.
    $line='{"FormatVersion":1,"Code":"'+$Code+'"}'+[Environment]::NewLine
    $currentLength=if($context.Sandbox.Exists($path)){$context.Sandbox.GetFileLength($path)}else{0}
    if($currentLength+[Text.Encoding]::UTF8.GetByteCount($line)-gt65536){return}
    $context.Sandbox.AppendText($path,$line)
}
function Get-TPAcceptanceDiagnosticSummary {
    [CmdletBinding()]
    param()
    $variable=Get-Variable TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
    if($null-eq$variable-or$null-eq$variable.Value-or-not$variable.Value.IsAcceptance-or-not$variable.Value.IsTestMode){throw 'TP-ACCEPTANCE-DIAGNOSTIC-CONTEXT'}
    $context=$variable.Value
    if($null-eq$context.Sandbox-or$context.Sandbox.IsFaulted){throw 'TP-ACCEPTANCE-DIAGNOSTIC-BOUNDARY'}
    return Read-TPAcceptanceDiagnosticSummaryFromBroker -Sandbox $context.Sandbox
}
function ConvertFrom-TPAcceptanceDiagnosticContent {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory=$true)][string]$Content)
    if([Text.Encoding]::UTF8.GetByteCount($Content)-gt65536){throw 'TP-ACCEPTANCE-DIAGNOSTIC-SIZE'}
    $counts=[ordered]@{ACTION=0;OPERATION_FAILED=0;SESSION_STARTED=0;SESSION_ENDED=0;BOUNDARY_STOPPED=0}
    foreach($line in @($Content-split'\r?\n')){
            if($line-eq''){continue}
            # Exact grammar rejects injected fields, paths and multiline content.
            if($line-cnotmatch'^\{"FormatVersion":1,"Code":"(ACTION|OPERATION_FAILED|SESSION_STARTED|SESSION_ENDED|BOUNDARY_STOPPED)"\}$'){throw 'TP-ACCEPTANCE-DIAGNOSTIC-FORMAT'}
            $counts[$Matches[1]]++
    }
    return [pscustomobject][ordered]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2';EventCounts=[pscustomobject]$counts;RawLogsIncluded=$false;UserDataIncluded=$false;Uploaded=$false}
}
function Read-TPAcceptanceDiagnosticSummaryFromBroker {
    # Internal live-session reader. Its sole path is obtained from the selected
    # broker; neither a caller filename nor a normal log location is accepted.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Sandbox)
    if($Sandbox.IsFaulted){throw 'TP-ACCEPTANCE-DIAGNOSTIC-BOUNDARY'}
    $path=Join-Path ([string]$Sandbox.Logs) 'acceptance-events.jsonl'
    if(-not$Sandbox.Exists($path)){return ConvertFrom-TPAcceptanceDiagnosticContent -Content ''}
    if($Sandbox.GetFileLength($path)-gt65536){throw 'TP-ACCEPTANCE-DIAGNOSTIC-SIZE'}
    # The bounded native reader checks length before allocation and excludes
    # data writers through the same held handle. The parser checks again.
    return ConvertFrom-TPAcceptanceDiagnosticContent -Content ($Sandbox.ReadAllTextLimited($path,65536))
}
function Get-TPAcceptanceDiagnosticSummaryFromSandbox {
    # Post-exit reading requires the native read-only acceptance opener. This
    # helper cannot initialize an environment or use an independent-mode root.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Sandbox)
    if($null-eq$Sandbox-or$Sandbox.GetType().FullName-cne'TaskPilot.Runtime.Sandbox'-or
       -not$Sandbox.IsReadOnly-or$Sandbox.IsDisposed-or$Sandbox.IsFaulted-or-not$Sandbox.HasAcceptanceDiagnosticLock){throw 'TP-ACCEPTANCE-DIAGNOSTIC-READONLY-REQUIRED'}
    if([IO.Path]::GetFileName([string]$Sandbox.MarkerPath)-cne'.taskpilot-acceptance-environment'-or
       $Sandbox.EnvironmentId-cnotmatch'^[a-f0-9]{32}$'-or
       -not[string]::Equals([string]$Sandbox.Root,(Join-Path (Join-Path ([string]$Sandbox.ProfileRoot) 'TaskPilotAcceptance') ([string]$Sandbox.EnvironmentId)),[StringComparison]::OrdinalIgnoreCase)){
        throw 'TP-ACCEPTANCE-DIAGNOSTIC-PURPOSE'
    }
    return Read-TPAcceptanceDiagnosticSummaryFromBroker -Sandbox $Sandbox
}
# These overrides are loaded LAST, after all original GUI adapters. Parameters
# are intentionally ignored; no detail from callers can reach persistent logs.
function Write-ActionLog([string]$action,[string]$detail){Write-TPAcceptanceEvent -Code ACTION}
function Write-ErrorLog($record){Write-TPAcceptanceEvent -Code OPERATION_FAILED}
function Show-TPAcceptanceStartupFailure {
    # Unique startup handler: do not route through Show-Failure/Write-ErrorLog,
    # which an earlier GUI adapter might have replaced before a load failure.
    # No ErrorRecord or arbitrary message is accepted or persisted here.
    param()
    try{Write-TPAcceptanceEvent -Code OPERATION_FAILED}catch{}
    [System.Windows.Forms.MessageBox]::Show('受入専用環境の処理を停止しました。起動前検査と診断結果を確認してください。','TaskPilot [ACCEPTANCE ONLY]','OK','Error')|Out-Null
}
function Show-Failure($record){
    $fatal=$true
    try{Write-TPAcceptanceEvent -Code OPERATION_FAILED;$fatal=[bool]$script:TPRuntimeContext.Sandbox.IsFaulted}catch{}
    [System.Windows.Forms.MessageBox]::Show('受入テストの処理に失敗しました。診断には内容を含まないエラー件数だけを記録します。','TaskPilot [ACCEPTANCE ONLY]','OK','Error')|Out-Null
    if($fatal){
        $timer=Get-Variable NotificationTimer -Scope Script -ErrorAction SilentlyContinue
        if($null-ne$timer-and$null-ne$timer.Value){try{$timer.Value.Stop()}catch{}}
        $window=Get-Variable form -Scope Script -ErrorAction SilentlyContinue
        if($null-ne$window-and$null-ne$window.Value){$window.Value.Close()}
    }
}
