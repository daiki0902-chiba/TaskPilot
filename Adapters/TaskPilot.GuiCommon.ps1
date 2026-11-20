#requires -Version 5.1
# Shared adapters run in the GUI script scope. They never read legacy files.
function Initialize-TPGuiContext {
    param([Parameter(Mandatory=$true)]$Store,[string]$ModulePath=(Join-Path $PSScriptRoot '../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'))
    $script:TPStorageModule=Import-Module -Name $ModulePath -PassThru
    $script:TPGuiStore=$Store
    $script:TPGuiReportsPending=$false
}
function Invoke-TPGuiSql {
    param([Parameter(Mandatory=$true)][string]$Sql,[hashtable]$Parameters=@{},[ValidateSet('Rows','Scalar','NonQuery')][string]$Mode='Rows')
    if($null-eq$script:TPGuiStore -or $script:TPGuiStore.Closed){throw 'TaskPilot SQLite store is not open.'}
    if($Mode-eq'NonQuery' -and ($script:TPGuiStore.ReadOnly -or $script:TPGuiStore.TransactionReadOnly)){throw '読み取り専用のスナップショット中は保存できません。'}
    & $script:TPStorageModule {
        param($contextStore,$text,$values,$resultMode)
        Invoke-TPSql -Store $contextStore -Sql $text -Parameters $values -Mode $resultMode
    } $script:TPGuiStore $Sql $Parameters $Mode
}
function Invoke-TPGuiTransaction {
    param([Parameter(Mandatory=$true)][scriptblock]$Action)
    Invoke-TaskPilotTransaction -Store $script:TPGuiStore -Action $Action
}
function Get-TPGuiValue {
    param($Object,[string]$Name,$Default=$null)
    if($Object-is[Collections.IDictionary]){if($Object.Contains($Name)){return ,$Object[$Name]};return ,$Default}
    if($null-ne$Object -and $null-ne$Object.PSObject.Properties[$Name]){return ,$Object.$Name}
    return ,$Default
}
function ConvertTo-TPGuiIsoDate {
    param([string]$Value,[switch]$Optional)
    if($Optional -and [string]::IsNullOrWhiteSpace($Value)){return $null}
    $parsed=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($Value,'yyyy/MM/dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw '日付は実在する yyyy/MM/dd 形式で入力してください。'}
    return $parsed.ToString('yyyy-MM-dd',[cultureinfo]::InvariantCulture)
}
function ConvertTo-TPGuiLegacyDate {
    param($Value)
    if($null-eq$Value -or [string]$Value-eq''){return ''}
    $parsed=[datetime]::ParseExact([string]$Value,'yyyy-MM-dd',[cultureinfo]::InvariantCulture)
    return $parsed.ToString('yyyy/MM/dd',[cultureinfo]::InvariantCulture)
}
function Set-TPGuiReportDirty {
    $script:TPGuiReportsPending=$true
    $script:ReportsNeedRefresh=$true
}
