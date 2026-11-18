# 自動テスト実行結果

2026-11-18、LinuxのPowerShell 7.4.6 / SQLite 3.46.1に対する明示的な.NETテストアダプターで実行した。Pythonは使用していない。実ユーザーデータを使っていない。

```text
Result: 8 test groups passed, 0 failed.
```

| 群 | 実施結果 |
| --- | --- |
| STEP4C回帰 | 6スイート成功。移行12ケース/127項目、正規化44項目、全ドメイン109項目、コーデック59項目、ファイル保全、既存STEP4Bの27項目（ドメインAPI31項目を含む） |
| バックアップ・復元 | 6ケース/56項目 |
| GUIタスク用アダプター | 14ケース/52項目 |
| GUIドメイン用アダプター | 44項目 |
| 保存とExcel更新の順序 | 5ケース/38項目。エクスポーターを模した処理を使う検証 |
| 起動DBの選択・保護 | 9ケース/88項目 |
| 生成GUIの保存経路・既存画面構成・計算 | 8ケース/415項目。実際の計算関数をSQLiteデータで実行。WinForms描画・xlsx生成は行わない |
| ビルド配布検査 | 178項目。固定依存を指定し、131ファイルの配布予定と混入防止・既存出力保全を検証 |

詳細な標準出力・OS・実行時刻・パラメーター種別は [results.json](results.json) に記録した。配布予定の検証結果は [build-validation.json](build-validation.json)。件数は各スイート内の確認数であり、Windowsで合格した画面数や全機能網羅率を表さない。

GitHubへの初回ソース反映コミット8abcc9eを新規cloneして行ったバイト照合・BOM・構文検査の結果は [github-readback.json](github-readback.json) に記録した。これもWindows実行の結果ではない。

Windows 10/11、Windows PowerShell 5.1、同梱Windows DLL、実際のEXE・GUI・通知・Excel・署名の検証は実施していない。Windows受入表と販売判定は別に管理し、今回の自動テスト成功を販売合格とはしない。

開発者は次の形式で再実行できる。Windowsではテスト専用アダプターを指定せず、同梱Windows用プロバイダーを使う。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-TaskPilotCommercial.ps1 `
  -DependencyRoot C:\TaskPilotBuild\deps-1
```

実行ごとに `TestResults/Commercial_（識別子）.json` を作成する。既存DB・旧CSV/JSONの置き場所をテスト先に指定する引数はない。
