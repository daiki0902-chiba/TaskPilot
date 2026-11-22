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
    $currentLength=if($context.Sandbox.Exists($path)){$context.Sandbox.GetLength($path)}else{0}
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
    $counts=[ordered]@{ACTION=0;OPERATION_FAILED=0;SESSION_STARTED=0;SESSION_ENDED=0;BOUNDARY_STOPPED=0}
    $path=Join-Path ([string]$context.Sandbox.Logs) 'acceptance-events.jsonl'
    if($context.Sandbox.Exists($path)){
        if($context.Sandbox.GetLength($path)-gt65536){throw 'TP-ACCEPTANCE-DIAGNOSTIC-SIZE'}
        $content=$context.Sandbox.ReadText($path)
        foreach($line in @($content-split'\r?\n')){
            if($line-eq''){continue}
            # Exact grammar rejects injected fields, paths and multiline content.
            if($line-cnotmatch'^\{"FormatVersion":1,"Code":"(ACTION|OPERATION_FAILED|SESSION_STARTED|SESSION_ENDED|BOUNDARY_STOPPED)"\}$'){throw 'TP-ACCEPTANCE-DIAGNOSTIC-FORMAT'}
            $counts[$Matches[1]]++
        }
    }
    return [pscustomobject][ordered]@{FormatVersion=1;Purpose='DesktopAcceptanceSyntheticOnly';Version='0.4.0.2';EventCounts=[pscustomobject]$counts;RawLogsIncluded=$false;UserDataIncluded=$false;Uploaded=$false}
}
# These overrides are loaded LAST, after all original GUI adapters. Parameters
# are intentionally ignored; no detail from callers can reach persistent logs.
function Write-ActionLog([string]$action,[string]$detail){Write-TPAcceptanceEvent -Code ACTION}
function Write-ErrorLog($record){Write-TPAcceptanceEvent -Code OPERATION_FAILED}
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
