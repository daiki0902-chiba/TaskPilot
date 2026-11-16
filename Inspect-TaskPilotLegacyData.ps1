#requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot,[long]$MaxFileBytes=67108864,[string]$ReportPath)
$ErrorActionPreference='Stop'
try{
    if([string]::IsNullOrWhiteSpace($SourceRoot)){
        $local=[Environment]::GetFolderPath('LocalApplicationData')
        if([string]::IsNullOrWhiteSpace($local)){throw 'LocalApplicationData could not be determined. Specify SourceRoot explicitly.'}
        $SourceRoot=Join-Path $local 'TaskPilot'
    }
    if($MaxFileBytes-lt0){throw 'MaxFileBytes must be nonnegative.'}
    . (Join-Path $PSScriptRoot 'Migration-CliSupport.ps1')
    $resolvedReport=Get-TPMigrationCLIReportPath -ReportPath $ReportPath -SourceRoot $SourceRoot
    Import-Module (Join-Path $PSScriptRoot 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force
    $result=Test-TaskPilotLegacyData -SourceRoot $SourceRoot -MaxFileBytes $MaxFileBytes
    Write-TPMigrationCLIReport -ReportPath $resolvedReport -Result $result -SourceRoot $SourceRoot
    if($resolvedReport){Write-Host ('Inspection report: '+$resolvedReport)}
    Write-Output $result
}catch{Write-Error -ErrorAction Continue $_;exit 1}
