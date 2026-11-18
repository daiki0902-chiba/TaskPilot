# STEP4C配布候補の同梱・除外リスト

予定ファイル名：`TaskPilot_STEP4_0C_既存データ移行_20261115.zip`

## 同梱

- `README_STEP4C.md`、`検証結果.md`、このリスト
- `Inspect-TaskPilotLegacyData.ps1`
- `Import-TaskPilotLegacyData.ps1`
- `Test-TaskPilotStep4C.ps1`
- `Migration-CliSupport.ps1`
- 修正済み `Test-TaskPilotStep4B.ps1` と、その実行に必要な人工データ試験スクリプト
- `Modules/TaskPilot.Storage/TaskPilot.Storage.psm1`、`TaskPilot.Storage.psd1`、Children/Domain/Migration系PS1
- `Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll`
- 同provider配下 `x86/SQLite.Interop.dll`、`x64/SQLite.Interop.dll`
- 同provider配下 `provider-files.sha256.json`、`provider-manifest.json`、`ThirdPartyNotices/`
- 同provider配下のXML API資料（任意だが配布内容を記録）
- `Codec/TaskPilotMigrationCodec.cs`、codecローダー、`Codec/Test-Codec.ps1`
- `schema/001_initial.sql`
- `tests/Test-Migration*.ps1` と必要なSTEP4B回帰試験
- 元のアプリの参照用コピーを `reference/` 配下に分け、来歴・変更していないことを確認するSHA-256を付ける（起動先の切替用ではない）

PS1/PSM1の日本語をWindows PowerShell 5.1が正しく読むようUTF-8 BOMを維持します。ネイティブDLLのx86/x64サブディレクトリー配置を維持し、`.altconfig` は追加しません。

## 同梱しない

- 利用者のCSV/JSON、元フォルダーのコピー、実DB、バックアップ、検査・移行レポート
- `.taskpilot4*` 一時DB、SQLite `-journal` / `-wal` / `-shm`
- `DeveloperSandbox/` 内の人工データDBや自己テスト結果、その他の実行残骸
- Linux試験用Mono.Data.Sqlite.dll・libsqlite3リンク・Debianパッケージ
- Pythonスクリプト、Python実行環境、NuGet/Debianダウンロードキャッシュ
- `Smoke-Plan.ps1`、`Add-MigrationExports.ps1` 等の開発中の補助スクリプト
- 旧アプリ本体・旧ビルドスクリプトの置換版

## ZIP確定前

同梱ファイルの一覧・ハッシュを記録し、ZIP展開後の構文検査と自己テストを実行します。配布ZIPに上記の除外物が入っていないことを再確認します。Windows実機で今回のSTEP4Cキットを検証済みと、Linux試験だけから表示しないでください。

Dropbox等に新しいファイル名で保存する操作は、この具体的なZIPと保存先の確認後に行います。既存ファイル・元データ・従来の配布物は勝手に上書き・削除しません。
