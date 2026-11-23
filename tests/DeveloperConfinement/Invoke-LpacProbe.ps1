#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputRoot,[ValidateSet('None','RegistryRead')][string]$CapabilityProfile='None')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or$PSVersionTable.PSVersion.Major-ne5-or$PSVersionTable.PSVersion.Minor-ne1-or-not[Environment]::Is64BitProcess){throw 'This experiment requires Windows PowerShell Desktop 5.1 x64.'}
if($env:GITHUB_ACTIONS-cne'true'-or$env:RUNNER_OS-cne'Windows'-or-not$env:RUNNER_TEMP){throw 'This synthetic feasibility experiment is restricted to the disposable Windows CI runner.'}
$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
if([int]$os.ProductType-eq1){throw 'Client Windows and personal PCs are not authorized for this experimental probe.'}
$root=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot))
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
if(-not$root.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase)-or$root-eq$temp){throw 'OutputRoot must be a new directory below CI RUNNER_TEMP.'}
if([IO.File]::Exists($root)-or[IO.Directory]::Exists($root)){throw 'OutputRoot already exists; no existing directory is used.'}
$cursor=$root
while($cursor){
    try{$attributes=[IO.File]::GetAttributes($cursor);if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Links and junctions are not accepted for probe output.'}}
    catch [IO.FileNotFoundException]{} catch [IO.DirectoryNotFoundException]{}
    $parent=[IO.Path]::GetDirectoryName($cursor);if($parent-eq$cursor){break};$cursor=$parent
}
$null=[IO.Directory]::CreateDirectory($root)
$policyBefore=@(Get-ExecutionPolicy -List|ForEach-Object {[pscustomobject]@{Scope=[string]$_.Scope;Policy=[string]$_.ExecutionPolicy}})
$source=Join-Path $PSScriptRoot 'LpacProbe.cs'
$compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$automation=[System.Management.Automation.PSObject].Assembly.Location
$exe=Join-Path $root 'LpacProbe.exe'
$compileOutput=@(& $compiler /nologo /noconfig /target:exe /platform:x64 /langversion:5 /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll ('/r:'+$automation) ('/out:'+$exe) $source 2>&1)
if($LASTEXITCODE-ne0){throw ('Probe compilation failed: '+($compileOutput-join[Environment]::NewLine))}
$null=@(& $exe --child $root 2>&1)
if($LASTEXITCODE-eq0){throw 'Direct child entry under an ordinary token did not refuse.'}
$entries=@([IO.Directory]::GetFileSystemEntries($root))
if($entries.Count-ne1-or$entries[0]-ine$exe){throw 'Rejected raw child entry performed scratch I/O.'}
$invalid=Join-Path $root ('InvalidEntry_'+[guid]::NewGuid().ToString('N'))
$null=@(& $exe $invalid 2>&1)
if($LASTEXITCODE-eq0-or[IO.File]::Exists($invalid)-or[IO.Directory]::Exists($invalid)){throw 'Direct parent entry did not refuse its invalid root without I/O.'}
$entries=@([IO.Directory]::GetFileSystemEntries($root))
if($entries.Count-ne1-or$entries[0]-ine$exe){throw 'Rejected raw parent entry performed scratch I/O.'}
if($CapabilityProfile-eq'RegistryRead'){& $exe --registry-read $root}else{& $exe $root}
$exit=$LASTEXITCODE
$raw=Join-Path $root 'ParentSummary.json'
if(-not[IO.File]::Exists($raw)){throw 'The experiment did not produce its required evidence.'}
$report=Get-Content -LiteralPath $raw -Raw -Encoding UTF8|ConvertFrom-Json
$report|Add-Member -NotePropertyName CapabilityProfile -NotePropertyValue $CapabilityProfile -Force
$report|Add-Member -NotePropertyName DirectEntryRejectionChecks -NotePropertyValue 2 -Force
$report|Add-Member -NotePropertyName DirectEntryRejectionChecksPassed -NotePropertyValue $true -Force
$policyAfter=@(Get-ExecutionPolicy -List|ForEach-Object {[pscustomobject]@{Scope=[string]$_.Scope;Policy=[string]$_.ExecutionPolicy}})
$policyUnchanged=($policyBefore|ConvertTo-Json -Compress)-ceq($policyAfter|ConvertTo-Json -Compress)
$report|Add-Member -NotePropertyName ObservedPolicyBefore -NotePropertyValue $policyBefore -Force
$report|Add-Member -NotePropertyName ObservedPolicyAfter -NotePropertyValue $policyAfter -Force
$report|Add-Member -NotePropertyName ObservedPoliciesUnchanged -NotePropertyValue $policyUnchanged -Force
$report|Add-Member -NotePropertyName SourceCommit -NotePropertyValue $env:GITHUB_SHA -Force
$report|Add-Member -NotePropertyName PowerShell -NotePropertyValue $PSVersionTable.PSVersion.ToString() -Force
$report|Add-Member -NotePropertyName RunnerOs -NotePropertyValue 'Windows Server CI; not Windows 10/11 acceptance' -Force
$reportDirectory=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'TestResults'
$null=[IO.Directory]::CreateDirectory($reportDirectory)
$reportPath=Join-Path $reportDirectory ('ConfinementProbe_'+[guid]::NewGuid().ToString('N')+'.json')
[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
Write-Host ('Probe evidence saved; status='+$report.Status+'; no GUI authorization; report='+$reportPath)
if($exit-ne0-or$report.HarnessError-or$report.UnexpectedOutsideAccess-or-not$report.ProfileCleanupSucceeded-or-not$policyUnchanged){throw 'LPAC experiment failed safely; inspect its bounded report. No application launch is authorized.'}
$report
