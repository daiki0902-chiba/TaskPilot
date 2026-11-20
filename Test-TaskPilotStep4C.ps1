#requires -Version 5.1
[CmdletBinding()]
param([string]$TestProviderAssembly)
$ErrorActionPreference='Stop'
try{
    $tests=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'tests') -Filter 'Test-Migration*.ps1' -File | Sort-Object Name)
    if($tests.Count-eq0){throw 'No bundled migration test scripts were found.'}
    $codecTest=Join-Path $PSScriptRoot 'Codec/Test-Codec.ps1'
    if(-not(Test-Path -LiteralPath $codecTest -PathType Leaf)){throw 'The bundled strict codec test suite is missing.'}
    $tests+=Get-Item -LiteralPath $codecTest
    $step4BTest=Join-Path $PSScriptRoot 'Test-TaskPilotStep4B.ps1'
    if(Test-Path -LiteralPath $step4BTest -PathType Leaf){$tests+=Get-Item -LiteralPath $step4BTest}
    $hostName=if($PSVersionTable.PSEdition-eq'Desktop'){'powershell.exe'}elseif([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){'pwsh.exe'}else{'pwsh'}
    $executable=Join-Path $PSHOME $hostName
    if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){throw 'The current PowerShell executable could not be located.'}
    $resolvedAdapter=$null
    if($TestProviderAssembly){$resolvedAdapter=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestProviderAssembly)}
    $results=New-Object 'System.Collections.Generic.List[object]'
    foreach($test in $tests){
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($test.FullName,[ref]$tokens,[ref]$parseErrors)
        if($parseErrors.Count-gt0){$results.Add([pscustomobject]@{Test=$test.Name;Passed=$false;ExitCode=-1;Message=($parseErrors|Out-String)});continue}
        $nativeArguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$test.FullName)
        if($resolvedAdapter-and $null-ne$ast.ParamBlock){
            $parameterNames=@($ast.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath})
            if($parameterNames-contains'TestProviderAssembly'){$nativeArguments+=@('-TestProviderAssembly',$resolvedAdapter)}
        }
        Write-Host ('Running '+$test.Name)
        # PS5.1 treats redirected native stderr as ErrorRecord; capture it without
        # aborting the runner before checking the subprocess exit code.
        $oldPreference=$ErrorActionPreference
        $nativePreference=Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        $hadNativePreference=$null-ne$nativePreference
        if($hadNativePreference){$oldNativePreference=$nativePreference.Value}
        try{
            $ErrorActionPreference='Continue'
            if($hadNativePreference){$PSNativeCommandUseErrorActionPreference=$false}
            $output=@(& $executable @nativeArguments 2>&1)
            $status=$LASTEXITCODE
        }finally{
            $ErrorActionPreference=$oldPreference
            if($hadNativePreference){$PSNativeCommandUseErrorActionPreference=$oldNativePreference}
        }
        foreach($line in $output){Write-Host ([string]$line)}
        $passed=$status-eq0
        $results.Add([pscustomobject]@{Test=$test.Name;Passed=$passed;ExitCode=$status;Message=if($passed){'Passed'}else{($output|Out-String)}})
        if($passed){Write-Host ('PASS: '+$test.Name) -ForegroundColor Green}else{Write-Host ('FAIL: '+$test.Name) -ForegroundColor Red}
    }
    $failed=@($results|Where-Object{-not$_.Passed}).Count
    Write-Output ([pscustomobject]@{Suites=$results.Count;Passed=$results.Count-$failed;Failed=$failed;TestOnlyAdapter=[bool]$resolvedAdapter;Results=$results.ToArray()})
    Write-Host ('Result: '+($results.Count-$failed)+' suites passed, '+$failed+' failed.')
    if($failed-gt0){exit 1}
}catch{Write-Error -ErrorAction Continue $_;exit 1}
