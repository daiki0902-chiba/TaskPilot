# TaskPilot SQLite統合・開発候補版

PowerShell 5.1とWindows Formsを維持し、既存GUIの保存処理をSQLiteへ接続した開発用ソースです。Pythonは使いません。Windows Server 2022上でnative SQLiteの自動試験と未署名EXE生成が成功しました。Windows 10/11での実機受入・購入者向け配布は未完了のため、現時点で販売可能と判定した製品ではありません。

依頼全体の達成状況は[要件の達成状況](docs/08-requirements-status.md)を参照してください。成果物の作成と、Windows 10/11での受入・販売判定を区別して記録します。

Windows 10/11で試す場合は、[受入テスト用の日本語README](docs/acceptance/README-ja.md)を使用してください。専用の標準ユーザーまたはクリーンなVMを前提とし、アプリ136ファイルを保持したキットに全ファイル一覧、起動前検査、33項目の手順・記録用紙、限定した診断採取、DLLブロックの配布方式検討をまとめます。普段の業務用アカウントでテスト起動しません。

[準備結果とZIPの取得先](docs/09-windows-acceptance-preparation.md)に、Serverでのパッケージ636項目・補助ツール34項目の成功と、Windows 10/11の未実施項目を記録しています。

**GitHubへの反映先は開発ブランチ `development/sqlite-commercial-20261116` です。** main `a761e76fbe4c4335a1847dbfc4417516d205316f` の全ツリーにはREADMEと.gitattributesの2ファイルだけがあり、アプリ本体・テストが未登録だったため、以前確認したSTEP3本体とSTEP4Cを基準に候補版を作成しました。mainを親とする履歴を用い、mainへ直接反映しません。GitHub連携アプリの一時停止は解除され、開発ブランチの作成も成功しました。詳細は [GitHub反映状況](docs/07-github-sync.md) を参照してください。

## 成果物

| 成果物 | ファイル |
| --- | --- |
| 現状分析 | [docs/01-current-state.md](docs/01-current-state.md)、[GUI保存経路](docs/03-gui-persistence-map.md) |
| SQLite設計 | [docs/02-sqlite-design.md](docs/02-sqlite-design.md)、[schema/001_initial.sql](schema/001_initial.sql) |
| 検査・移行 | `Inspect-TaskPilotLegacyData.ps1`、`Import-TaskPilotLegacyData.ps1`、`Modules/TaskPilot.Storage/TaskPilot.Migration*.ps1` |
| SQLite対応GUI | `TaskPilot.ps1`、`Adapters/`、`Modules/TaskPilot.Storage/` |
| 自動テスト | `Test-TaskPilotCommercial.ps1`、`tests/`、`Codec/Test-Codec.ps1`、[実行結果](docs/verification/results.json) |
| EXE・配布物の作成 | [docs/build/README.md](docs/build/README.md)、`tools/Build-TaskPilot.ps1` |
| Windows実機の受入項目 | [docs/build/WINDOWS-ACCEPTANCE.md](docs/build/WINDOWS-ACCEPTANCE.md) |
| 残課題・販売判定 | [docs/06-release-status.md](docs/06-release-status.md) |

## 開発者の確認手順

Windows PowerShell 5.1でリポジトリ直下を開き、合成データだけを使うテストを実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-TaskPilotCommercial.ps1
```

ビルド用依存物を準備済みの場合は `-DependencyRoot C:\TaskPilotBuild\deps-1` を加えます。指定しない場合の依存物を使う配布検査は明示的にSKIPされます。テスト結果は `TestResults` に保存します。実ユーザーデータは読み書きしません。Linux上のテスト用アダプターは購入者向け配布には含めません。

依存取得・Windowsビルド・署名・配布予定の検証は [ビルド手順](docs/build/README.md) に従ってください。購入者の起動時に依存のダウンロードやモジュールのインストールは行いません。

## データの引き継ぎと保護

新しいGUIは `%LOCALAPPDATA%\TaskPilot4` にSQLiteを保存し、旧 `%LOCALAPPDATA%\TaskPilot` のCSV・JSONは残します。初回は検査結果と案内を表示し、承諾後に完全バックアップと新DBへの移行を行います。エラーのある旧データを自動破棄したり、空DBで隠したりしません。

DBのバックアップは `TaskPilot4\Backup`、Excelは `TaskPilot4\Export`、操作・エラー・移行のログは `%LOCALAPPDATA%\TaskPilot4Logs`、移行時の完全バックアップは `%LOCALAPPDATA%\TaskPilot4LegacyBackups` に保存します。初期化を中止してもログやバックアップが次の試行を妨げないよう、移行の証跡は新DBの初期化判定と分けています。

復元は新しいDB名へ行い、元DBを残します。`active-store.json` の切替後に再起動して使用します。手作業でDBや回復ファイルを削除しないでください。未知のスキーマは自動更新せず停止します。

`reference/` は過去の確認済みソース・旧ビルド・旧STEP4Cの資料です。現行アプリの起動・製品ビルドの入力ではありません。`reference/Test-Storage.ps1` は旧保存処理の回帰試験として別途実行します。実データ、ビルド依存のキャッシュ、購入者向けEXEはこの開発ソースに含めません。
