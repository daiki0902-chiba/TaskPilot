# TaskPilot SQLite統合・開発候補版

PowerShell 5.1とWindows Formsを維持し、既存GUIの保存処理をSQLiteへ接続した開発用ソースです。Pythonは使いません。WindowsでのEXE生成・実機受入は未実施のため、現時点で販売可能と判定した製品ではありません。

**GitHub版との照合は未完了です。** `daiki0902-chiba/TaskPilot` は接続一覧に表示されますが、リポジトリ詳細・ファイル・ブランチ取得が404になる状態です。この作業は以前確認したSTEP3本体とSTEP4Cを基準に、ローカル専用ブランチ `development/sqlite-commercial-20261116` で行っています。リモートのmainは変更していません。GitHubへの反映前に、リモートの最新版を取得して差分を照合してください。

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

`reference/` は過去の確認済みソース・旧ビルド・旧STEP4Cの資料です。今回の実行・ビルドには使いません。実データ、ビルド依存のキャッシュ、購入者向けEXEはこの開発ソースに含めません。
