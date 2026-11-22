# TaskPilot SQLite統合・開発候補版

PowerShell 5.1とWindows Formsを維持し、既存GUIの保存処理をSQLiteへ接続した開発用ソースです。Pythonは使いません。Windows Server 2022上でnative SQLiteの自動試験と未署名EXE生成が成功しました。Windows 10/11での実機受入・購入者向け配布は未完了のため、現時点で販売可能と判定した製品ではありません。

依頼全体の達成状況は[要件の達成状況](docs/08-requirements-status.md)を参照してください。成果物の作成と、Windows 10/11での受入・販売判定を区別して記録します。

**独立テストモードの公開停止は維持しています。** I25/I28の原因を修正し、Windows Serverで独立27件・追加保存8件・通常8群・停止措置12項目が合格しました。Windows 10/11実機と実ディスク障害は未検証のため、本体・検査・診断の入口とEXE・ZIPの公開は停止したままです。[修正内容・証跡・配布判定](docs/11-isolation-safety-fix.md)を参照してください。既存データがあるユーザーで起動してよいとは案内しません。

Windows 10/11の実機確認に向けた[初心者向け準備ガイド](docs/desktop-acceptance/README-ja.md)、[開始条件と未達条件](docs/desktop-acceptance/READINESS-ja.md)、[31件の確認表](docs/desktop-acceptance/CHECKLIST-ja.md)、[OS別結果票](docs/desktop-acceptance/RESULT-TEMPLATE-ja.md)を用意しています。受入専用ビルド・専用検査・署名付き取得経路は未実装で、現在できるのはPC情報と計画の確認までです。本体の起動許可ではありません。

[受入用README](docs/acceptance/README-ja.md)と[テストモード計画](docs/acceptance/TEST-MODE-ja.md)は未検証項目を含む資料です。[以前の準備結果](docs/09-windows-acceptance-preparation.md)は0.4.0.1の履歴で、独立モードには対応しません。旧ZIPへ新しい引数を渡して代用しないでください。

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
