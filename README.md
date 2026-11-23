# TaskPilot SQLite統合・開発候補版

PowerShell 5.1とWindows Formsを維持し、既存GUIの保存処理をSQLiteへ接続した開発用ソースです。Pythonは使いません。Windows Server 2022上でnative SQLiteの自動試験と未署名EXE生成が成功しました。Windows 10/11での実機受入・購入者向け配布は未完了のため、現時点で販売可能と判定した製品ではありません。

依頼全体の達成状況は[要件の達成状況](docs/08-requirements-status.md)を参照してください。成果物の作成と、Windows 10/11での受入・販売判定を区別して記録します。

**2026-11-23更新：通常版を唯一の製品本体として開発します。** データを購入者のPC内に保存し、クラウド同期・サーバー保存・共有機能は追加しません。個人開発、有料証明書は現段階で購入しない、将来の限定配布先はGitHub privateという方針です。

[最小構成への移行計画・テスト選定](docs/development/NORMAL-DEVELOPMENT-ja.md)に従い、独立・受入・ローカル専用版の追加開発を停止します。CIは通常版を1回だけビルドし、共通コードの保護検査を1回実行します。専用入口の起動拒否、一般配布の停止、DB用途の検査は維持し、EXE・配布ZIPは公開しません。

[通常版CI 45184776656](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/45184776656)は成功しました。通常8群、追加保存8件、共通コード27件、公開停止12項目が合格し、通常群内のテスト専用プロバイダー向け1項目はSKIPとして記録しています。[差分と検証結果](docs/verification/normal-development-20261123.json)を参照してください。

Windows 10/11の実機開始は**NOT_READY**です。[通常EXEのホスト・保存先の調査](docs/development/NORMAL-HOST-COMPATIBILITY-ja.md)と、クリーンVMでの事前確認が残ります。既存データのあるユーザーでの起動は案内しません。OSの保護設定や実行ポリシーを変更して起動させません。

[独立モードの修正記録](docs/11-isolation-safety-fix.md)、[受入専用の実装](docs/12-desktop-acceptance-build.md)、[受入残課題](docs/desktop-acceptance/REMAINING-WORK-ja.md)、[ローカル専用版の実装](docs/local-validation/IMPLEMENTATION-ja.md)は過去の設計・検証資料です。専用版を完成させることを、通常版のローカル検証の前提にしません。過去のZIPや起動引数で代用しないでください。

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
powershell.exe -NoProfile -File .\Test-TaskPilotCommercial.ps1
```

PowerShell上で`.\Test-TaskPilotCommercial.ps1 -ListSuites`と実行すれば、テストを起動せず一覧を確認できます。軽微な変更では`.\Test-TaskPilotCommercial.ps1 -Suite GuiTasks,GuiIntegration`のように必要な群だけ選べます。省略時は従来どおり全8群です。ビルド用依存物を準備済みの場合は `-DependencyRoot C:\TaskPilotBuild\deps-1` を加えます。指定しない場合の依存物を使う配布検査は明示的にSKIPされます。未選択・SKIPを合格とは扱いません。テスト結果は `TestResults` に保存します。実ユーザーデータは読み書きしません。ポリシーが実行を拒否したら停止してください。Linux上のテスト用アダプターは購入者向け配布には含めません。

依存取得・Windowsビルド・署名・配布予定の検証は [ビルド手順](docs/build/README.md) に従ってください。購入者の起動時に依存のダウンロードやモジュールのインストールは行いません。

## データの引き継ぎと保護

新しいGUIは `%LOCALAPPDATA%\TaskPilot4` にSQLiteを保存し、旧 `%LOCALAPPDATA%\TaskPilot` のCSV・JSONは残します。初回は検査結果と案内を表示し、承諾後に完全バックアップと新DBへの移行を行います。エラーのある旧データを自動破棄したり、空DBで隠したりしません。

DBのバックアップは `TaskPilot4\Backup`、Excelは `TaskPilot4\Export`、操作・エラー・移行のログは `%LOCALAPPDATA%\TaskPilot4Logs`、移行時の完全バックアップは `%LOCALAPPDATA%\TaskPilot4LegacyBackups` に保存します。初期化を中止してもログやバックアップが次の試行を妨げないよう、移行の証跡は新DBの初期化判定と分けています。

復元は新しいDB名へ行い、元DBを残します。`active-store.json` の切替後に再起動して使用します。手作業でDBや回復ファイルを削除しないでください。未知のスキーマは自動更新せず停止します。

`reference/` は過去の確認済みソース・旧ビルド・旧STEP4Cの資料です。現行アプリの起動・製品ビルドの入力ではありません。`reference/Test-Storage.ps1` は旧保存処理の回帰試験として別途実行します。実データ、ビルド依存のキャッシュ、購入者向けEXEはこの開発ソースに含めません。
