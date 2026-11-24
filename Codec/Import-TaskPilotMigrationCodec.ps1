#requires -Version 5.1
# Loads only a strict text codec; never opens the app or any data file.
$ErrorActionPreference = 'Stop'
if (-not ('TaskPilot.Migration.Codec' -as [type])) {
    $codecAssembly=Join-Path $PSScriptRoot 'TaskPilotMigrationCodec.dll'
    if([IO.File]::Exists($codecAssembly)){
        $codecLoaded=[Reflection.Assembly]::LoadFrom($codecAssembly)
        $null=$codecLoaded.GetType('TaskPilot.Migration.Codec',$true)
    }else{
        $codecContext=Get-Variable -Name TPRuntimeContext -Scope Script -ErrorAction SilentlyContinue
        $codecBoundary=Get-Variable -Name TPTestSandbox -Scope Script -ErrorAction SilentlyContinue
        if(($null-ne$codecContext-and$null-ne$codecContext.Value-and$codecContext.Value.IsTestMode)-or($null-ne$codecBoundary-and$null-ne$codecBoundary.Value)){
            throw 'Independent test mode requires the bundled precompiled codec DLL. Runtime C# compilation is not allowed.'
        }
        $migrationCodecSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'TaskPilotMigrationCodec.cs') -Raw -Encoding UTF8
        Add-Type -TypeDefinition $migrationCodecSource -ErrorAction Stop
    }
}
