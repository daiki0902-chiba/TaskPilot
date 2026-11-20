#requires -Version 5.1
# Loads only a strict text codec; never opens the app or any data file.
$ErrorActionPreference = 'Stop'
if (-not ('TaskPilot.Migration.Codec' -as [type])) {
    $migrationCodecSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'TaskPilotMigrationCodec.cs') -Raw -Encoding UTF8
    Add-Type -TypeDefinition $migrationCodecSource -ErrorAction Stop
}
