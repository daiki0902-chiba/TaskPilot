$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $here 'TaskPilot_STEP3_6F_4.ps1'
$release = Join-Path $here 'Release_TaskPilot_STEP3_6F_4'
$stage = Join-Path $release 'TaskPilot'
$exe = Join-Path $stage 'TaskPilot.exe'
$zip = Join-Path $release 'TaskPilot_3.6F_4_Windows_Portable.zip'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source not found: $source" }
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Windows PowerShell 5.1 でビルドしてください。' }
$tokens = $null; $parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
Import-Module ps2exe -ErrorAction Stop
$module = Get-Module -ListAvailable ImportExcel | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $module) { throw 'ImportExcel is not installed on the BUILD computer. Install-Module ImportExcel -Scope CurrentUser' }
$moduleRoot = Split-Path -Parent $module.Path
$manifest = Join-Path $moduleRoot 'ImportExcel.psd1'
if (-not (Test-Path -LiteralPath $manifest)) { throw "ImportExcel manifest missing: $manifest" }
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Invoke-ps2exe -inputFile $source -outputFile $exe -noConsole -STA -title 'TaskPilot' -product 'TaskPilot' -version '0.9.20.5'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'EXE was not generated.' }
$modulesDir = Join-Path $stage 'Modules'
New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
Copy-Item -LiteralPath $moduleRoot -Destination (Join-Path $modulesDir 'ImportExcel') -Recurse -Force -ErrorAction Stop
if (-not (Test-Path -LiteralPath (Join-Path $modulesDir 'ImportExcel\ImportExcel.psd1'))) { throw 'Module packaging failed.' }
@'
TaskPilot STEP 3.6F - Windows portable beta

使い方:
1. ZIPファイルを右クリックして「すべて展開」してください。
2. 展開した TaskPilot フォルダ内の TaskPilot.exe をダブルクリックしてください。
3. Modules フォルダは TaskPilot.exe と同じフォルダに置いたままにしてください。

購入者によるPowerShell操作・PS2EXE導入・ImportExcelモジュール導入は不要な構成です。
ただしWindows PowerShell 5.1と.NET FrameworkなどWindows標準環境に依存します。
Excelレポートを表示する場合、.xlsxを開けるアプリが必要です。
データ保存先: %LOCALAPPDATA%\TaskPilot
削除する場合: 配布フォルダを削除。個人データは自動削除されません。

重要:
これはテスト用ポータブル版であり、インストーラーではありません。
初回実行時にWindows SmartScreen等の警告が出る可能性があります。
警告を回避するためにセキュリティ設定を無効にしないでください。
商用配布前にライセンス確認・コード署名・別PCでのテストが必要です。
'@ | Set-Content -LiteralPath (Join-Path $stage 'はじめに.txt') -Encoding UTF8
$licenses = Join-Path $stage 'ThirdPartyNotices'
New-Item -ItemType Directory -Path $licenses -Force | Out-Null
$licenseFiles = @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -File -ErrorAction Stop | Where-Object { $_.Name -match '^(LICENSE|LICENCE|NOTICE|COPYING)(\.|$)' })
foreach ($file in $licenseFiles) {
    $rel = $file.FullName.Substring($moduleRoot.Length).TrimStart('\')
    $target = Join-Path $licenses $rel
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
}
@'
Bundled component: ImportExcel PowerShell module and its dependencies.
Review the module's license and included third-party components before commercial redistribution.
Do not remove any licenses included inside Modules\ImportExcel.
'@ | Set-Content -LiteralPath (Join-Path $licenses 'README.txt') -Encoding UTF8
$ps2exeModule = Get-Module ps2exe | Select-Object -First 1
@{ AppVersion='0.9.20.5'; BuiltAt=(Get-Date).ToUniversalTime().ToString('o'); PowerShell=$PSVersionTable.PSVersion.ToString(); ImportExcel=$module.Version.ToString(); Ps2Exe=$ps2exeModule.Version.ToString(); SourceSHA256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'BuildInfo.json') -Encoding UTF8
Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
    [pscustomobject]@{ Path=$_.FullName.Substring($stage.Length+1); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'FileHashes.json') -Encoding UTF8
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
Get-FileHash -LiteralPath $zip -Algorithm SHA256 | Format-List | Out-String | Set-Content -LiteralPath ($zip + '.sha256.txt') -Encoding UTF8
Write-Host "Customer ZIP created: $zip" -ForegroundColor Green
Write-Host 'IMPORTANT: Not tested on a clean Windows PC. Verify licensing, SmartScreen and all Excel features.' -ForegroundColor Yellow
Write-Host 'Back up %LOCALAPPDATA%\TaskPilot before testing with existing data.' -ForegroundColor Yellow
