# 自動テスト実行結果

2026-11-22のI25/I28は原因修正後のServer試験で合格した。最新の結果は `isolation-fix-20261122-*` と[修正レポート](../11-isolation-safety-fix.md)、以前の失敗は `isolated-mode-20261122-*` と[初回記録](../10-independent-test-mode.md)に分ける。独立27件・追加保存8件・通常8群・公開停止12項目は成功したが、Windows 10/11実機は未検証のため公開停止を継続する。

2026-11-20に追加したWindows 10/11受入キットと補助ツールの検証は[受入準備結果](../09-windows-acceptance-preparation.md)を参照してください。Serverでのキット生成・検査の成功であり、Windows 10/11のGUI・通知・Excel実出力の合格ではありません。

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

上記はLinuxの記録であり、次のWindows Serverの記録と分けて保持する。Windows 10/11、実際のGUI・通知・Excel・署名の検証は実施していない。Windows受入表と販売判定は別に管理し、自動テスト成功を販売合格とはしない。

## Windows Server 2022でのnative自動試験とビルド

2026-11-19、[GitHub Actions #44640521434](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44640521434)で、コミット `9c7ad91674f7c47784b51305c080405f7c534d80` の旧保存処理回帰試験と8群の自動試験が成功した。Windows PowerShell Desktop 5.1.20348.5773・x64、同梱System.Data.SQLite / SQLite 3.46.1を使用し、テスト専用providerを指定していない。

- [windows-native-results.json](windows-native-results.json): 8群成功・失敗0。nativeではテスト専用のトランザクション内改変フックを使う移行ケースをSKIPし、その記録を残す。全ケース無条件実施とは扱わない。
- [windows-native-first-attempt.json](windows-native-first-attempt.json): 初回はテスト用リンクの片付けが確認入力を求めて1群失敗。既知のテスト用リンクを非再帰で削除するよう修正し、リンク先の保持を検証して上記へ再試験した。
- [windows-native-verification.json](windows-native-verification.json)、[windows-build-info.json](windows-build-info.json): 未署名の0.4.0.1 x64 EXEと候補ZIPの生成成功。ビルダーはPE形式・版情報・配布許可リスト・ZIPを検証した。EXEを起動した結果ではない。

候補ZIPのSHA-256は `e977b31a8f6eb25c66b8d6d0658b421db13b2db1849b00c33a3234d5d1b70795`。GitHub artifactは保存期限がある。候補は開発用・未署名・販売用ではない。Windows Serverでの合格によってWindows 10/11の受入表を合格へ変更しない。

開発者は次の形式で再実行できる。Windowsではテスト専用アダプターを指定せず、同梱Windows用プロバイダーを使う。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-TaskPilotCommercial.ps1 `
  -DependencyRoot C:\TaskPilotBuild\deps-1
```

実行ごとに `TestResults/Commercial_（識別子）.json` を作成する。既存DB・旧CSV/JSONの置き場所をテスト先に指定する引数はない。
