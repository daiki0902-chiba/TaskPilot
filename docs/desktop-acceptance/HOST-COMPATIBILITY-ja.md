# PowerShellホストと実行ポリシーの互換性

**判定：未解決。署名証明書の購入だけで、既定設定のWindows 10/11に対応できるとは判断しない。** 一般版・受入版の起動と公開の停止を維持する。以下は2026-11-22に確認した静的な互換性調査であり、Windows 10/11の実測結果ではない。

## 現在の入口で確認できたこと

`acceptance/TaskPilot.Acceptance.Launcher.cs`は標準の`RunspaceFactory.CreateRunspace()`を使用し、外部の`.ps1`を`PowerShell.AddCommand(path)`で実行する。独自の署名・ハッシュ・CMS許可検査は、その後にPowerShellエンジンが行う実行可否判定を置き換えない。

MicrosoftのAPI資料は、標準の認証マネージャーがコマンド実行前に実行ポリシーを検査すると明記している。現在のPowerShell公開ソースの標準セッション初期化も`PSAuthorizationManager`を設定している。ただし、この公開ソースは現在のPowerShellの参考実装であり、Windows PowerShell 5.1そのもののソースを確認したという意味ではない。

| 対象PCの有効ポリシー | Microsoftが文書化する動作 | TaskPilotへの影響 |
| --- | --- | --- |
| `Restricted` | Windowsクライアントの既定。スクリプトファイルを実行しない。`.ps1`・`.psm1`などを含む | ファイルの署名が有効でも、現在の外部スクリプト入口が動作するとはいえない |
| `AllSigned` | ローカル作成分を含め、スクリプトと構成に信頼済み発行元の署名を要求。未分類の発行元は確認対象 | 元のImportExcelスクリプトを独自の署名済みハッシュで確認しても、PowerShellのファイル署名要求を満たすとは限らない。発行元確認UIを備えていない現ホストにも課題がある |
| `RemoteSigned`など | 取得元や署名に応じて判定。Serverの既定は`RemoteSigned` | Serverの合成ローカルファイルが実行できても、クライアントの既定設定の証明にならない |

有効なポリシーはGroup PolicyやProcessなどの優先順位を含めて決まり、`LocalMachine`の値だけでは判定しない。

既存の690検査で確認した受入EXEは、発行者が空のため、Runspaceを作成する前に停止する。この拒否結果は有効だが、正式な署名を持つ入口の実行、標準設定のWindows 10/11での起動、未署名ベンダースクリプトの読み込みを検証していない。

## A・B・Cの切り分け

- **A：ホスト設計の互換性検査と改修。** 標準の認証マネージャーを保ったまま、外部スクリプト・モジュールの扱い、署名と原本ハッシュの関係、対話を要求する場合の安全停止を設計する。`tests/Test-DesktopAcceptanceHostPolicy.ps1`は新規の無害な合成スクリプトだけで、現在のホストがどのポリシーを実際に適用するかを観測する。ポリシーは変更しない。
- **B：対象環境と配布方式の決定。** 「既定設定のWindows利用者がEXEをダブルクリックするだけ」という要件を維持するなら、現状の外部スクリプト入口に対する解決設計を先に選ぶ。署名サービスやストア登録を先に購入・契約しても、この問題が自動で解消するわけではない。
- **C：Windows 10/11での正例と拒否例。** 対応する配布方式ができてから、そのPCの既存ポリシー、取得元、署名、モジュール読み込み、初回起動を確認する。試験のためにポリシーや証明書ストアを変更して合格へ変えない。

署名済みMSIXの導入やランチャー自身のAuthenticode署名と、PowerShellのスクリプト実行可否は別の確認事項である。アプリロジックを署名済み.NETバイナリーへ移す案など、入口設計を変更する場合は、既存のPowerShell/WinForms機能を維持できるか、変更量・保守性・回帰範囲を独立して評価する必要がある。大規模な移植を完了したとは報告しない。

実行ポリシーの変更、認証マネージャーの無効化、取得元情報の削除、スクリプトを別経路へ渡して検査を避ける方法、証明書ストアの自動変更を回避策として実装していない。Microsoftは実行ポリシーを強固なセキュリティ境界とは位置付けていないが、それを理由に今回の「保護や検査を無効化しない」という条件を外さない。

## 一次資料

2026-11-22確認。

1. [about_Execution_Policies（Windows PowerShell 5.1）](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)：WindowsクライアントとServerの既定、Restricted/AllSigned、優先順位。
2. [InitialSessionState.AuthorizationManager](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.initialsessionstate.authorizationmanager?view=powershellsdk-1.1.0)：標準認証マネージャーによる実行ポリシー検査。
3. [PowerShell公開ソース：InitialSessionState](https://github.com/PowerShell/PowerShell/blob/master/src/System.Management.Automation/engine/InitialSessionState.cs)：現行公開実装の標準認証マネージャー。5.1実測の代用にはしない。
4. [PowerShell公開ソース：SecurityManager](https://github.com/PowerShell/PowerShell/blob/master/src/System.Management.Automation/security/SecurityManager.cs)：署名・信頼済み発行元・Restrictedの判定を行う現行参考実装。
