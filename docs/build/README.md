# TaskPilot 開発者向けビルド手順

2026-11-23更新：現在は[通常版中心の開発計画](../development/NORMAL-DEVELOPMENT-ja.md)を優先します。このページはビルダーの仕様書であり、実機起動や配布の許可ではありません。内部ビルドのみとし、EXE・配布ZIPの一般公開は停止中です。有料署名証明書は必須にしません。実機はクリーンVMでの事前条件が未確認のためNOT_READYです。

この手順は新しい SQLite GUI `TaskPilot.ps1` から Windows x64 の顧客配布物を作るためのものです。旧 `Build_TaskPilot_STEP3_6F_4.ps1/.bat` と過去の配布物は保存し、この新しい手順には使用しません。購入者の起動処理は依存取得・インストールを行いません。

Linuxで依存の実物・SHA-256・ライセンス・配布予定一覧・構文を検証した後、GitHub ActionsのWindows Server 2022 / Windows PowerShell 5.1でnative SQLiteの自動試験と未署名EXE・配布候補ZIPの生成が成功しました。[証跡](../verification/windows-native-verification.json)を参照してください。生成EXEの起動、Windows 10/11の実機受入、WinForms、実際のExcel出力、コード署名は **未検証** です。`-ValidateOnly` やコンパイル成功は製品の動作合格を意味しません。

## 開発者側の前提

- EXE 生成には Windows 10 / 11 x64、64-bit Windows PowerShell 5.1 Desktop、.NET Framework 4.6 以上が必要です。.NET Framework 4.8 を推奨します。PowerShell 7、Linux、ARM64 を Windows x64 での検証の代用にはしません。
- 製品ソース一式と、製品の `Modules` とは別の新規依存フォルダーを用意します。管理者権限、`Install-Module`、システム PATH や実行ポリシーの変更は不要です。
- 固定する版と取得 URL、SHA-256 は `build/dependencies.lock.json` にあります。ps2exe 1.0.17、ImportExcel 7.8.10、EPPlus 4.5.3.2 を使用します。SQLite 1.0.119.0 はリポジトリー内の検証済み provider をそのまま使用します。
- 日本語を含む PowerShell ソースは Windows PowerShell 5.1 が読める UTF-8 BOM 付きにします。builder が検査します。

## 依存を準備する

リポジトリー直下の Windows PowerShell 5.1 で実行します。例の `C:\TaskPilotBuild` は開発者の任意の場所に置き換えます。親フォルダーは先に作成し、`deps-1` 自体は存在しない新しい名前にします。

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\Get-TaskPilotBuildDependencies.ps1 `
  -DestinationRoot C:\TaskPilotBuild\deps-1
```

既に取得した元ファイルをキャッシュしている場合は、ネットワークなしで同じ内容を準備できます。キャッシュには lock の `Downloads[].FileName` と一致する全ファイルが必要です。

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\Get-TaskPilotBuildDependencies.ps1 `
  -DestinationRoot C:\TaskPilotBuild\deps-offline-1 `
  -PackageCache C:\TaskPilotBuild\package-cache -Offline
```

指定先にコピー・展開して hash を確認します。ダウンロードしたスクリプトや DLL は準備中に実行しません。既存の指定先、改変ファイル、不完全なキャッシュ、hash 不一致は停止します。失敗時の新しい途中フォルダーは調査用に残し、次は別の新規名を指定します。プロセス内の TLS 設定は終了時に復元します。`dependency-receipt.json` が準備結果を記録します。

## 配布予定を検証する

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\Build-TaskPilot.ps1 `
  -Version 1.0.0.0 -DependencyRoot C:\TaskPilotBuild\deps-1 `
  -OutputRoot C:\TaskPilotBuild\releases -ValidateOnly
```

`ValidateOnly` は出力フォルダーも EXE も作りません。依存の全展開ファイル、版、EPPlus の assembly identity、第三者表示、SQLite provider の固定 hash、製品ソースの構文・BOM、顧客 README と runtime allowlist を検査します。返される `PayloadManifest` は実際にコピーするパス・コンポーネント・SHA-256 の一覧です。Linux の PowerShell でも同じ静的検証ができます。

配布対象の製品ファイルは `build/runtime-files.json` に明示します。Adapters / Storage に追加された未承認ファイルは自動同梱せず停止するため、追加時は内容を審査して allowlist も更新します。Codec のテスト、Linux adapter、開発 tools、アプリの実データはこの一覧に含めません。

## EXE と ZIP を作る

同じ指定から `-ValidateOnly` を外します。ファイルバージョンは Windows の4要素形式で、各値は 0～65535 です。販売者の社名と著作権表示を指定できます。

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\Build-TaskPilot.ps1 `
  -Version 1.0.0.0 -DependencyRoot C:\TaskPilotBuild\deps-1 `
  -OutputRoot C:\TaskPilotBuild\releases `
  -CompanyName '販売者名' -CopyrightText 'Copyright 2026 販売者名'
```

builder は指定依存内の ps2exe だけを読み込み、`-STA -noConsole -x64 -DPIAware -configFile` でコンパイルします。MZ / PE signature、AMD64、PE32+、Windows GUI subsystem、ファイルバージョンと製品名を検査します。STA の実動作と全操作は別途 Windows で確認します。

正規のコード署名証明書を持つ場合は `-SigningCertificateThumbprint`、`-TimestampServer`、`-RequireSignature` を追加します。証明書は `Cert:\CurrentUser\My` の有効な秘密鍵付き証明書を使い、署名結果が `Valid` の場合だけ続行します。証明書は生成しません。未署名ビルドの `BuildInfo.json` は `NotSigned` です。タイムスタンプ・署名発行元・実機での検証を受入結果に記録してください。

独自の規約を含める場合は、完成したファイルを `-EulaPath C:\TaskPilotBuild\EULA.md` で指定します。既定で規約や権利者の許諾を作り出しません。同梱 LGPL ライブラリーの変更・差し替えと、そのデバッグのためのリバースエンジニアリングを禁止しない条件にしてください。第三者表示にはその権利を明記しています。

## 新規出力と顧客に渡す範囲

出力は `TaskPilot_版_Windows_x64_UTC時刻_識別子` の新規フォルダー、同名 ZIP、`.zip.sha256` です。展開すると最上位の `TaskPilot` フォルダーに次が入ります。

| 内容 | 用途 |
| --- | --- |
| `TaskPilot.exe`、`.exe.config` | 顧客が起動する x64 / WinForms 本体 |
| `Adapters`、`Modules/TaskPilot.Storage`、`Codec`、`schema` | GUI の SQLite 保存、移行、バックアップ、Windows x86/x64 provider |
| `Modules/ImportExcel` | 同梱する固定版 Excel 出力 runtime、独立した EPPlus.dll |
| `README.md`、指定時の `EULA.md` | 購入者向け説明 |
| `ThirdPartyNotices`、`ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip` | ライセンス表示と EPPlus 対応ソース |
| `BuildInfo.json`、`SoftwareBillOfMaterials.json`、`FileHashes.json` | バージョン、未検証状態、依存由来、配布ファイルの最終 hash |

任意の製品 `Assets` がある場合も同梱します。顧客 ZIP に build tools、ps2exe モジュール、依存キャッシュ、テスト、DeveloperSandbox、Linux adapter、既存 DB、Data / Backup / Export / Logs、個人データは入れません。EPPlus 対応ソース ZIP 内の上流テストやビルド資材は、対応ソースを完全に提供するため保持します。

既存の ZIP や release は削除・上書きしません。出力は原則ソース外、またはリポジトリーの `artifacts` 配下に限定し、依存フォルダーと分離します。symlink / junction は拒否します。新しい stage にコピーして全 hash を確認し、EXE 生成後に ZIP 全項目の hash と件数を検証してから新規名へ移動します。途中失敗時の新規 stage は調査用に残します。

`FileHashes.json` は署名後の EXE も含め、manifest 自身を除く全ファイルの SHA-256 を記録します。ZIP の `.sha256` は最終 ZIP そのものを対象にします。実機試験で生成されるユーザーデータは別の場所に保存され、試験後に配布 ZIP を再圧縮しません。

## 試験と販売前確認

```powershell
powershell.exe -NoLogo -NoProfile -File .\tests\Test-BuildPackaging.ps1 `
  -DependencyRoot C:\TaskPilotBuild\deps-1
```

この回帰試験は配布予定一覧、除外、依存改変の検出、既存出力の保存、PE ヘッダーの拒否を確認し、EXE は生成しません。SQLite / GUI 各領域の他の回帰試験も別途実行します。最終 ZIP を新しい Windows 10 と Windows 11 の通常ユーザー環境に展開し、[Windows 受入チェックリスト](WINDOWS-ACCEPTANCE.md) の実測結果を残してください。未実施項目がある状態で「EXE 動作確認済み」「販売準備完了」としません。

ライセンスの根拠と固定対象は [LICENSE-AUDIT.md](LICENSE-AUDIT.md)、顧客へ同梱する表示は [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) です。
