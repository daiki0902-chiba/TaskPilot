#requires -Version 5.1
[CmdletBinding()]
param([string]$TestProviderAssembly,[string]$DependencyRoot)
$ErrorActionPreference='Stop'
$suites=@('Test-TaskPilotStep4C.ps1','tests/Test-Protection.ps1','tests/Test-GuiTasks.ps1','tests/Test-GuiDomainAdapters.ps1','tests/Test-GuiOperations.ps1','tests/Test-GuiStartup.ps1','tests/Test-GuiIntegration.ps1','tests/Test-BuildPackaging.ps1')
$hostName=if($PSVersionTable.PSEdition-eq'Desktop'){'powershell.exe'}elseif([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){'pwsh.exe'}else{'pwsh'}
$executable=Join-Path $PSHOME $hostName
$results=New-Object 'Collections.Generic.List[object]'
$skips=New-Object 'Collections.Generic.List[string]'
foreach($relative in $suites){
    $file=Join-Path $PSScriptRoot $relative
    if(-not[IO.File]::Exists($file)){$results.Add([pscustomobject]@{Suite=$relative;Passed=$false;ExitCode=-1;Output=@('Required test file is missing.')});continue}
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if($errors.Count){$results.Add([pscustomobject]@{Suite=$relative;Passed=$false;ExitCode=-1;Output=@(($errors|Out-String))});continue}
    $parameters=@();if($null-ne$ast.ParamBlock){$parameters=@($ast.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})}
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$file)
    if($TestProviderAssembly -and $parameters-contains'TestProviderAssembly'){$arguments+=@('-TestProviderAssembly',$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestProviderAssembly))}
    if($DependencyRoot -and $parameters-contains'DependencyRoot'){$arguments+=@('-DependencyRoot',$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DependencyRoot))}
    Write-Host ('Running '+$relative)
    $oldPreference=$ErrorActionPreference
    $native=Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $hadNative=$null-ne$native;if($hadNative){$oldNative=$native.Value}
    try{
        $ErrorActionPreference='Continue'
        if($hadNative){$PSNativeCommandUseErrorActionPreference=$false}
        $output=@(& $executable @arguments 2>&1|ForEach-Object {[string]$_})
        $status=$LASTEXITCODE
    }finally{$ErrorActionPreference=$oldPreference;if($hadNative){$PSNativeCommandUseErrorActionPreference=$oldNative}}
    foreach($line in $output){Write-Host $line;if($line-match'^SKIP:'){$skips.Add($relative+': '+$line)}}
    $results.Add([pscustomobject]@{Suite=$relative;Passed=($status-eq0);ExitCode=$status;Output=$output})
}
$failed=@($results|Where-Object {-not$_.Passed}).Count
$report=[pscustomobject]@{Stage='SQLite GUI integration candidate';CapturedAtUtc=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();ProcessBits=[IntPtr]::Size*8;TestOnlyProvider=[bool]$TestProviderAssembly;PinnedBuildDependenciesSupplied=[bool]$DependencyRoot;WindowsGUIVerified=$false;Windows10And11Verified=$false;ExecutableGenerated=$false;Passed=$results.Count-$failed;Failed=$failed;SkippedDetails=$skips.ToArray();Suites=$results.ToArray()}
$reportDirectory=Join-Path $PSScriptRoot 'TestResults'
$null=[IO.Directory]::CreateDirectory($reportDirectory)
$reportPath=Join-Path $reportDirectory ('Commercial_'+[guid]::NewGuid().ToString('N')+'.json')
[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
Write-Host ('Result: '+$report.Passed+' test groups passed, '+$failed+' failed. Report: '+$reportPath)
if($failed-gt0){exit 1}
