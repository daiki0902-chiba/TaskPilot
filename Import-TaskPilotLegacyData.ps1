#requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot,[string]$DatabasePath,[string]$BackupRoot,[string]$ExpectedManifestSha256,[switch]$Apply,[switch]$AcknowledgeWarnings,[long]$MaxFileBytes=67108864,[string]$ReportPath,[string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
try{
    if(-not$Apply){throw 'Nothing was applied. Inspect first; applying requires explicit -Apply and all four SourceRoot/DatabasePath/BackupRoot/ExpectedManifestSha256 values.'}
    foreach($required in @('SourceRoot','DatabasePath','BackupRoot','ExpectedManifestSha256')){
        if([string]::IsNullOrWhiteSpace([string](Get-Variable -Name $required -ValueOnly))){throw ('Apply requires an explicit '+$required+'. No source or destination is inferred.')}
    }
    if($ExpectedManifestSha256-notmatch'^[0-9a-fA-F]{64}$'){throw 'ExpectedManifestSha256 must be the 64-character SHA256 from the latest inspection.'}
    if($MaxFileBytes-lt0){throw 'MaxFileBytes must be nonnegative.'}
    . (Join-Path $PSScriptRoot 'Migration-CliSupport.ps1')
    $resolvedReport=Get-TPMigrationCLIReportPath -ReportPath $ReportPath -SourceRoot $SourceRoot
    if($resolvedReport){
        $databaseFull=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DatabasePath)
        $backupFull=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupRoot)
        if($resolvedReport.Equals($databaseFull,[StringComparison]::OrdinalIgnoreCase)-or $resolvedReport.Equals($backupFull,[StringComparison]::OrdinalIgnoreCase)){
            throw 'ReportPath must differ from the database file and backup directory.'
        }
    }
    Import-Module (Join-Path $PSScriptRoot 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force
    $arguments=@{SourceRoot=$SourceRoot;DatabasePath=$DatabasePath;BackupRoot=$BackupRoot;ExpectedManifestSha256=$ExpectedManifestSha256.ToLowerInvariant();Apply=$true;MaxFileBytes=$MaxFileBytes}
    if($AcknowledgeWarnings){$arguments.AcknowledgeWarnings=$true}
    if($TestProviderAssembly){$arguments.TestProviderAssembly=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestProviderAssembly)}
    $result=Import-TaskPilotLegacyData @arguments
    try{Write-TPMigrationCLIReport -ReportPath $resolvedReport -Result $result -SourceRoot $SourceRoot}
    catch{throw ("Migration completed, but its external report could not be saved. Database: $($result.DatabasePath); backup: $($result.BackupRoot). Do not overwrite or re-import these outputs. Report error: $($_.Exception.Message)")}
    if($resolvedReport){Write-Host ('Migration report: '+$resolvedReport)}
    Write-Output $result
}catch{Write-Error -ErrorAction Continue $_;exit 1}
