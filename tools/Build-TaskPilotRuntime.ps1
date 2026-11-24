#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[ValidateSet('Sandbox','Codec')][string]$Component='Sandbox')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT-or$PSVersionTable.PSEdition-ne'Desktop'-or-not[Environment]::Is64BitProcess){throw 'Runtime DLL compilation requires x64 Windows PowerShell 5.1.'}
. (Join-Path $PSScriptRoot 'TaskPilot.BuildSupport.ps1')
$destination=Get-TPBuildFullPath $OutputDirectory
Assert-TPBuildNoLinks $destination
if(Test-TPBuildPathExists $destination){throw 'The runtime compiler requires a new output directory.'}
$sourceRelative=if($Component-eq'Sandbox'){'Runtime/TaskPilot.TestSandbox.cs'}else{'Codec/TaskPilotMigrationCodec.cs'}
$source=Join-Path (Split-Path -Parent $PSScriptRoot) $sourceRelative
Assert-TPBuildNoLinks $source
$sourceHash=Get-TPBuildSha $source
$text=[IO.File]::ReadAllText($source)
$null=[IO.Directory]::CreateDirectory($destination)
$assembly=Join-Path $destination $(if($Component-eq'Sandbox'){'TaskPilot.TestSandbox.dll'}else{'TaskPilotMigrationCodec.dll'})
$compiler=New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters=New-Object CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable=$false;$parameters.GenerateInMemory=$false
$parameters.OutputAssembly=$assembly;$parameters.IncludeDebugInformation=$false
$parameters.CompilerOptions='/target:library /platform:x64 /optimize+'
$parameters.TempFiles=New-Object CodeDom.Compiler.TempFileCollection($destination,$false)
foreach($reference in @('mscorlib.dll','System.dll','System.Core.dll')){$null=$parameters.ReferencedAssemblies.Add($reference)}
try{
    $result=$compiler.CompileAssemblyFromSource($parameters,[string[]]@($text))
    if($result.Errors.HasErrors){throw ('Runtime guard compilation failed: '+(($result.Errors|ForEach-Object {$_.ToString()})-join[Environment]::NewLine))}
    if(-not[IO.File]::Exists($assembly)-or(Get-TPBuildSha $source)-cne$sourceHash){throw 'Runtime compilation output is missing or its input changed.'}
    [pscustomobject]@{AssemblyPath=$assembly;SourceSha256=$sourceHash;Sha256=(Get-TPBuildSha $assembly);Compiled=$true;RuntimeInvocationPerformed=$false;Target='Windows x64 / .NET Framework'}
}finally{$compiler.Dispose()}
