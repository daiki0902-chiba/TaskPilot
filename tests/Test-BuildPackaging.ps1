#requires -Version 5.1
[CmdletBinding()]
param([string]$DependencyRoot,[string]$TestRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/TaskPilot.BuildSupport.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(-not$TestRoot){$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('TaskPilotBuildTests_'+[guid]::NewGuid().ToString('N'))}
$root=Get-TPBuildFullPath $TestRoot
Assert-TPBuildNoLinks $root
if(Test-TPBuildPathExists $root){throw 'TestRoot must be a new directory. Existing test artifacts are never overwritten.'}
$null=[IO.Directory]::CreateDirectory($root)
$checks=0
function Assert-BuildTest([bool]$Condition,[string]$Message){
    if(-not$Condition){throw ('Packaging regression: '+$Message)}
    $script:checks++
}
function Assert-BuildFailure([scriptblock]$Operation,[string]$Pattern,[string]$Message){
    $failure=$null
    try{$null=& $Operation}catch{$failure=$_.Exception.Message}
    Assert-BuildTest ($null-ne$failure-and$failure-match$Pattern) ($Message+'; actual: '+$failure)
}
function Copy-BuildFixtureFile([string]$Relative){
    $from=Join-Path $repo $Relative
    Copy-TPBuildNewFile $from (Join-Path $fixture $Relative) (Get-TPBuildSha $from)
}

$build=Join-Path $repo 'tools/Build-TaskPilot.ps1'
$newDeps=Join-Path $root 'existing-dependency-destination'
$null=[IO.Directory]::CreateDirectory($newDeps)
$depSentinel=Join-Path $newDeps 'keep.txt'
Write-TPBuildNewText $depSentinel 'existing developer files'
$depHash=Get-TPBuildSha $depSentinel
Assert-BuildFailure {& (Join-Path $repo 'tools/Get-TaskPilotBuildDependencies.ps1') -DestinationRoot $newDeps -Offline} 'destination already exists' 'Dependency preparation must not overwrite an existing directory.'
Assert-BuildTest ((Get-TPBuildSha $depSentinel)-ceq$depHash) 'Dependency preparation changed existing content.'
foreach($unsafe in @('../outside','/absolute','folder/../../outside','C:/absolute','folder\outside')){Assert-BuildFailure {Assert-TPBuildRelative $unsafe} 'Unsafe relative build path' ('Unsafe archive path accepted: '+$unsafe)}
$notExe=Join-Path $root 'invalid-executable.bin'
Write-TPBuildNewText $notExe 'not an executable'
Assert-BuildFailure {Assert-TPBuildWindowsX64GuiExe $notExe} 'MZ executable header' 'A text output must not pass EXE verification.'
Assert-BuildFailure {Assert-TPBuildWindowsX64GuiExe (Join-Path $repo 'Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll')} 'is a DLL' 'An x64 native DLL must not pass as a product executable.'
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){Assert-BuildFailure {& $build -Version 1.2.3.4 -DependencyRoot (Join-Path $root 'unused-dependencies') -OutputRoot (Join-Path $root 'unused-output')} 'requires 64-bit Windows PowerShell' 'A Linux run must not claim EXE compilation.'}
if(-not$DependencyRoot){
    Write-Host 'SKIP: Dependency payload tests require -DependencyRoot. Independent packaging safety checks passed.'
    return [pscustomobject]@{Passed=$true;Checks=$checks;TestRoot=$root;SkippedDependencyPayload=$true;ExecutableGenerated=$false;WindowsExecutionVerified=$false}
}
$output=Join-Path $root 'never-created-output'
$validated=& $build -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot $output -ValidateOnly
Assert-BuildTest ($validated.Validated-and-not$validated.ExecutableGenerated-and-not$validated.WindowsExecutionVerified) 'Static validation must not claim an executable or Windows execution.'
Assert-BuildTest (-not(Test-TPBuildPathExists $output)-and-not$validated.OutputCreated) 'ValidateOnly must create no output directory.'
Assert-BuildTest ($validated.PayloadFiles-eq$validated.PayloadManifest.Count) 'Planned payload count differs from its manifest.'
$names=@($validated.PayloadManifest|ForEach-Object{$_.Path})
foreach($required in @('Adapters/TaskPilot.GuiStartup.ps1','Adapters/TaskPilot.GuiTasks.ps1','Adapters/TaskPilot.GuiDomains.ps1','Adapters/TaskPilot.GuiOperations.ps1','Modules/TaskPilot.Storage/TaskPilot.Storage.psm1','Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll','Modules/TaskPilot.Storage/provider/x86/SQLite.Interop.dll','Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll','Codec/Import-TaskPilotMigrationCodec.ps1','Codec/TaskPilotMigrationCodec.cs','schema/001_initial.sql','Modules/ImportExcel/ImportExcel.psd1','Modules/ImportExcel/EPPlus.dll','README.md','ThirdPartyNotices/README.md','ThirdPartyNotices/LGPL-3.0.txt','ThirdPartyNotices/GPL-3.0.txt','ThirdPartyNotices/MS-PL.txt','ThirdPartyNotices/ImportExcel-7.8.10-Apache-2.0.txt','ThirdPartyNotices/PS2EXE-1.0.17-LICENSE.original','ThirdPartyNotices/EPPlus-DotNetZip-Notice.txt','ThirdPartyNotices/EPPlus-ManagedZlib-JCraft-Notice.txt','ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip')){
    Assert-BuildTest ($names-contains$required) ('Required customer file missing: '+$required)
}
Assert-BuildTest (@($names|Where-Object{$_-match'(?i)(^|/)(tools|tests?|DeveloperSandbox|Data|Backup|Export|Logs|reference|linux-test|\.git|ps2exe|Examples)(/|$)|\.(db|sqlite|sqlite3|log|bak|tmp|nupkg)$|^TaskPilot\.ps1$'}).Count-eq0) 'Customer payload includes developer tools, test data or user data.'
$nameSet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($name in $names){Assert-BuildTest ($nameSet.Add($name)) ('Duplicate/case-colliding customer path: '+$name)}

$existingOutput=Join-Path $root 'existing-output'
$null=[IO.Directory]::CreateDirectory($existingOutput)
$sentinel=Join-Path $existingOutput 'TaskPilot_previous-release.zip'
Write-TPBuildNewText $sentinel 'previous release must survive successful and failed validation'
$sentinelHash=Get-TPBuildSha $sentinel
$null=& $build -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot $existingOutput -ValidateOnly
Assert-BuildFailure {& $build -Version 65536.1.1.1 -DependencyRoot $DependencyRoot -OutputRoot $existingOutput -ValidateOnly} 'component must be <=65535' 'Out-of-range Windows versions must fail.'
Assert-BuildTest ((Get-TPBuildSha $sentinel)-ceq$sentinelHash-and@(Get-TPBuildFiles $existingOutput).Count-eq1) 'Existing release changed or new output appeared during validation.'
Assert-BuildFailure {& $build -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot (Join-Path $repo 'docs') -ValidateOnly} 'OutputRoot must be' 'A source directory must not be used as build output.'
Assert-BuildFailure {& $build -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot (Join-Path $DependencyRoot 'release') -ValidateOnly} 'must be disjoint' 'Dependencies must not contain build output.'
Assert-BuildFailure {& $build -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot $existingOutput -RequireSignature -ValidateOnly} 'RequireSignature needs an existing developer code-signing certificate' 'A required signature must not silently become an unsigned build.'

# Isolated product fixture: negative tests never edit the real source or dependencies.
$fixture=Join-Path $root 'source-fixture'
foreach($file in @('TaskPilot.ps1','tools/Build-TaskPilot.ps1','tools/Build-TaskPilotRuntime.ps1','Runtime/TaskPilot.TestSandbox.cs','tools/Get-TaskPilotBuildDependencies.ps1','tools/TaskPilot.BuildSupport.ps1','build/dependencies.lock.json','build/runtime-files.json','docs/user/README.md','docs/build/THIRD-PARTY-NOTICES.md')){Copy-BuildFixtureFile $file}
$runtime=Get-Content -LiteralPath (Join-Path $repo 'build/runtime-files.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($file in $runtime.Files){Copy-BuildFixtureFile $file}
$fixtureBuild=Join-Path $fixture 'tools/Build-TaskPilot.ps1'
$stray=Join-Path $fixture 'Adapters/developer-helper.ps1'
Write-TPBuildNewText $stray '# a developer file must never be silently shipped'
Assert-BuildFailure {& $fixtureBuild -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot $existingOutput -ValidateOnly} 'Unexpected/developer-only file in runtime directory' 'Unknown adapter files must stop packaging.'
[IO.File]::Delete($stray)
$missing=Join-Path $fixture 'Modules/TaskPilot.Storage/TaskPilot.Storage.psm1'
[IO.File]::Move($missing,($missing+'.retained'))
Assert-BuildFailure {& $fixtureBuild -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot $existingOutput -ValidateOnly} 'Required payload file is missing' 'Missing persistence module must stop packaging.'
[IO.File]::Move(($missing+'.retained'),$missing)
$provider=Join-Path $fixture 'Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll'
[IO.File]::WriteAllText($provider,'corrupted provider fixture')
Assert-BuildFailure {& $fixtureBuild -Version 1.2.3.4 -DependencyRoot $DependencyRoot -OutputRoot $existingOutput -ValidateOnly} 'Bundled SQLite provider hash failed' 'Changed SQLite DLL must stop packaging.'

$tamperedDeps=Join-Path $root 'tampered-dependencies'
foreach($file in @(Get-TPBuildFiles $DependencyRoot)){
    $relative=$file.FullName.Substring((Get-TPBuildFullPath $DependencyRoot).TrimEnd([IO.Path]::DirectorySeparatorChar).Length+1)
    Copy-TPBuildNewFile $file.FullName (Join-Path $tamperedDeps $relative) (Get-TPBuildSha $file.FullName)
}
$notice=Join-Path $tamperedDeps 'Notices/LGPL-3.0.txt'
[IO.File]::AppendAllText($notice,'changed license fixture')
Assert-BuildFailure {& $build -Version 1.2.3.4 -DependencyRoot $tamperedDeps -OutputRoot $existingOutput -ValidateOnly} 'pinned dependency|third-party notice' 'Changed license must stop packaging.'
Assert-BuildTest ((Get-TPBuildSha $sentinel)-ceq$sentinelHash) 'A failed packaging check modified an existing release.'

[pscustomobject]@{Passed=$true;Checks=$checks;TestRoot=$root;PayloadFiles=$validated.PayloadFiles;SkippedDependencyPayload=$false;ExecutableGenerated=$false;WindowsExecutionVerified=$false;ExistingReleasePreserved=$true}
