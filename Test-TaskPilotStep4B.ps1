#requires -Version 5.1
[CmdletBinding()]
param([string]$TestProviderAssembly,[switch]$KeepTestArtifacts)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1') -Force
$script:providerArgs=@{}
if($TestProviderAssembly){$script:providerArgs['TestProviderAssembly']=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestProviderAssembly)}
$sandbox=Join-Path $PSScriptRoot 'DeveloperSandbox'
if(-not(Test-Path -LiteralPath $sandbox)){New-Item -ItemType Directory -Path $sandbox -ErrorAction Stop|Out-Null}
$script:testRoot=Join-Path $sandbox ('Test4B_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:testRoot -ErrorAction Stop|Out-Null
$script:outcomes=New-Object 'System.Collections.Generic.List[object]'
$script:caseIndex=0
$script:s=$null
$script:runtimeInfo=$null
$script:skips=New-Object 'System.Collections.Generic.List[string]'
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Must-Fail([scriptblock]$Action,[string]$Pattern=''){
    $failed=$false
    try{& $Action|Out-Null}catch{$failed=$true;if($Pattern-and $_.Exception.Message-notmatch$Pattern){throw "Unexpected failure: $($_.Exception.Message)"}}
    if(-not$failed){throw 'Expected the operation to fail.'}
}
function Test-Case([string]$Name,[scriptblock]$Action){
    $script:caseIndex++;$script:dbPath=Join-Path $script:testRoot ('case_'+$script:caseIndex+'.db');$script:s=$null
    try{
        $null=New-TaskPilotDatabase -DatabasePath $script:dbPath @script:providerArgs
        $script:s=Open-TaskPilotStore -DatabasePath $script:dbPath @script:providerArgs
        if($null-eq$script:runtimeInfo){$script:runtimeInfo=Get-TaskPilotStoreInfo $script:s}
        & $Action
        $script:outcomes.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=$null})
        Write-Host ('PASS: '+$Name) -ForegroundColor Green
    }catch{
        $script:outcomes.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})
        Write-Host ('FAIL: '+$Name+' : '+$_.Exception.Message) -ForegroundColor Red
    }finally{
        if($null-ne$script:s -and -not$script:s.Closed){Close-TaskPilotStore $script:s}
    }
}
try{
    $providerReady=$false;$providerStartup=$null
    try{
        $providerStartup=Get-TaskPilotProviderInfo @script:providerArgs
        $providerReady=$true
        Write-Host ('Provider ready: '+$providerStartup.Provider+' / SQLite '+$providerStartup.SQLiteVersion)
    }catch{
        $script:outcomes.Add([pscustomobject]@{Name='SQLite provider startup';Passed=$false;Error=$_.Exception.Message})
        Write-Host ('FAIL: SQLite provider startup : '+$_.Exception.Message) -ForegroundColor Red
    }
    if($providerReady){
    . (Join-Path $PSScriptRoot 'tests/Test-StorageCore.ps1')
    foreach($suite in @('Test-Domain.ps1','Test-CoreReview.ps1')){
        try{
            $suiteOutput=@(& (Join-Path $PSScriptRoot ('tests/'+$suite)) @script:providerArgs)
            foreach($line in $suiteOutput){Write-Host ([string]$line);if([string]$line -like 'SKIP:*'){$script:skips.Add([string]$line)}}
            $script:outcomes.Add([pscustomobject]@{Name=$suite;Passed=$true;Error=$null})
        }catch{
            $script:outcomes.Add([pscustomobject]@{Name=$suite;Passed=$false;Error=$_.Exception.Message})
            Write-Host ('FAIL: '+$suite+' : '+$_.Exception.Message) -ForegroundColor Red
        }
    }
    }
    $failed=@($script:outcomes|Where-Object{-not$_.Passed}).Count
    $report=[pscustomobject]@{Stage='4.0B';PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();ProcessBits=([IntPtr]::Size*8);TestAdapter=[bool]$TestProviderAssembly;ProviderStartup=$providerStartup;Runtime=$script:runtimeInfo;Skipped=@($script:skips.ToArray());Passed=($script:outcomes.Count-$failed);Failed=$failed;Cases=@($script:outcomes.ToArray())}
    $reportPath=Join-Path $sandbox ('STEP4B_TestResult_'+[guid]::NewGuid().ToString('N')+'.json')
    $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host ("Result: {0} passed, {1} failed. Report: {2}"-f $report.Passed,$failed,$reportPath)
    if($failed-gt0){exit 1}
}finally{
    if(-not$KeepTestArtifacts -and (Test-Path -LiteralPath $script:testRoot)){Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
