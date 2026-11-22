#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeAssembly,[Parameter(Mandatory=$true)][string]$OutputRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tools/TaskPilot.BuildSupport.ps1')
$output=Get-TPBuildFullPath $OutputRoot;Assert-TPBuildNoLinks $output
if(-not[IO.Directory]::Exists($output)){throw 'The developer report directory must already exist.'}
$fixture=Join-Path $output ('HandleSmoke_'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$profile=Join-Path $fixture 'SyntheticLocalAppData';$null=[IO.Directory]::CreateDirectory($profile)
$null=[Reflection.Assembly]::LoadFrom((Get-TPBuildFullPath $RuntimeAssembly))
$sandbox=$null;$failure=$null;$checks=0
function Assert-HandleSmoke([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
try{
    $sandbox=[TaskPilot.Runtime.Sandbox]::Create($profile,[guid]::NewGuid().ToString('N'))
    $path=Join-Path $sandbox.Root 'smoke.txt';$moved=Join-Path $sandbox.Root 'moved.txt'
    $sandbox.WriteNew($path,[Text.Encoding]::UTF8.GetBytes('before'))
    Assert-HandleSmoke ($sandbox.ReadAllText($path)-ceq'before') 'Handle-only create/read failed.'
    $sandbox.AppendText($path,'-append')
    Assert-HandleSmoke ($sandbox.ReadAllText($path)-ceq'before-append') 'Handle-only append failed.'
    $sandbox.AtomicWrite($path,[Text.Encoding]::UTF8.GetBytes('after'),$null)
    Assert-HandleSmoke ($sandbox.ReadAllText($path)-ceq'after') 'Journaled handle-only overwrite failed.'
    Assert-HandleSmoke (@($sandbox.ListDirectory($sandbox.Root)|Where-Object {$_.Name-eq'smoke.txt'}).Count-eq1) 'Native handle enumeration failed.'
    $sandbox.MoveNew($path,$moved)
    Assert-HandleSmoke ($sandbox.ReadAllText($moved)-ceq'after'-and-not$sandbox.Exists($path)) 'Relative-handle publication failed.'
    $lease=$sandbox.AcquireDatabaseWriter($moved)
    try{
        $sandbox.AtomicWrite($moved,[Text.Encoding]::UTF8.GetBytes('leased-write'),$null)
        Assert-HandleSmoke ($sandbox.ReadAllText($moved)-ceq'leased-write') 'A held writer must permit broker I/O through its own handle.'
        $second=$null;try{$second=$sandbox.AcquireDatabaseWriter($moved)}catch{}
        Assert-HandleSmoke ($null-eq$second) 'A second writer lease was accepted.'
    }finally{$lease.Dispose()}
    $sandbox.DeleteFile($moved);Assert-HandleSmoke (-not$sandbox.Exists($moved)) 'Handle-only deletion failed.'
    $sandbox.ValidateTree()
}catch{$failure=$_.Exception.ToString()+[Environment]::NewLine+$_.ScriptStackTrace}
finally{if($null-ne$sandbox){$sandbox.Dispose()}}
$report=[pscustomobject]@{Stage='Native handle-only smoke';Passed=($null-eq$failure);Checks=$checks;Error=$failure;TestRoot=$fixture;ProductionProfileAccessed=$false;ApplicationLaunched=$false}
Write-TPBuildNewText (Join-Path $output ('HandleSmoke_'+[guid]::NewGuid().ToString('N')+'.json')) (ConvertTo-Json -InputObject $report -Depth 8)
return $report
