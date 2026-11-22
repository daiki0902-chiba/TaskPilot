# 受入残課題の分類とAの追加実装

**実機開始はNOT_READY。一般版・独立モード・受入版の公開停止を維持する。** mainと実ユーザーデータは変更していない。

残課題の一覧と優先順位は[A・B・C分類](desktop-acceptance/REMAINING-WORK-ja.md)、開発者の準備・費用・操作は[Bの手順](desktop-acceptance/DEVELOPER-PREPARATION-ja.md)、将来の実機操作は[Cの手順](desktop-acceptance/AFTER-READY-ja.md)に分けた。

## Aで追加・修正した内容

1. 新しいPackageGuard用に15ケース、96回のネイティブ試行、固定ファイル変更拒否6項目を追加した。正例が権限不足で成立しない場合も不合格とし、SKIPや保護設定の変更で通さない。
2. 診断が実ブローカーに存在しない`GetLength`・`ReadText`を使っていた不具合を修正した。従来の代替オブジェクトによる試験が実APIの不一致を見逃していた。64KiB以内を同じ共有制限付きハンドルで読み、固定した既存ロックを読取専用で取得するAPIを追加した。
3. 終了後の診断は`OpenExistingAcceptance`で開き、既存のロック・用途マーカー・専用保存領域を要求する。欠損した領域やロックは作成しない。採取はイベント件数だけで、rawログ・パス・DB・業務内容・アップロードを含めない。公開入口の認証・事前検査は引き続き成立しないため、実ユーザーの保存先へは進まない。
4. GUI前のバックエンド検査コアを追加した。新しい合成一時領域内でSQLiteスキーマ、タスク・子・作業記録、ロールバック、排他・読取専用、再オープン、整合性、外部SQL I/O拒否を確認する。成功しても`BACKEND_PROBE_PASSED_GUI_BLOCKED`であり、GUI開始許可ではない。
5. MSIXの計画ツールを追加した。出力は候補XMLと設計情報だけで、署名・パッケージ生成・インストール・配布を行わない。現行のPackageGuardとWindowsAppsのACLは整合しておらず、導入方式の実装完了とは扱わない。
6. 標準Runspaceの現在のポリシーを変更せず、無害な新規スクリプトだけで許可・拒否を観測する試験を追加した。[ホスト互換性](desktop-acceptance/HOST-COMPATIBILITY-ja.md)に設計上の課題を記録した。

## 検証結果

基準となる[前回の690検査](12-desktop-acceptance-build.md)は履歴として保存している。今回の追加分と、Windows 10/11のGUI検証の成功を意味しない。

Linuxでは診断13、バックエンド開始条件8、MSIX計画44、専用入口30、同梱構成318検査が合格した。PowerShell構文とC#の構文コンパイルも確認した。ネイティブWindows専用の試験はLinuxでは実施していない。

[Windows Server CI 45082243912・試行2](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/45082243912/attempts/2)が成功した。対象コードは`b15e153d385cb81fb3b089861ee266131454d5b4`で、状態は`A_FOLLOWUP_AUTOMATED_TESTS_PASSED_DESKTOP_BLOCKED`。EXE・配布ZIPのアップロードはスキップされ、報告だけを保存した。

| 検査 | 実測結果 |
| --- | --- |
| 基本の受入専用6群 | 693検査合格。旧690から、診断と同梱構成の追加分が増えた |
| 新しいPackageGuard | 15ケース・96ネイティブ試行・182検査合格。固定変更拒否6項目、必須正例成立、SKIPなし、突破なし |
| 限定診断 | ネイティブ11ケースを含む42検査合格。読取専用・64KiB上限・既存ロック・競合拒否・合成通常領域不変 |
| バックエンド検査 | 6ケース・内部28検査と外側25検査が合格。合成通常領域と旧独立領域の内容・構成・所有者/DACLが不変 |
| MSIX計画 | 44検査合格。計画出力のみで、パッケージ生成・署名・インストールはしていない |
| 標準ホスト観測 | 10検査合格。Serverの既存有効ポリシーは`Unrestricted`。変更なし。他ポリシーやWindowsクライアントの合格ではない |
| 通常版の回帰 | 既存8群合格。テスト用プロバイダー限定の改変フック1項目は明示的SKIP |
| 受入実物DLLの回帰 | 実際に同梱した同一DLLのハッシュを要求し、独立27件・追加保存8件を再実行して合格。両方SKIPなし |

検査群で同じ準備・検証が重複するため、表の数値を単純合計して一意な試験件数とはしない。受入DLLのSHA-256は`c70ea2897a5e3a313caf7da685dd70b7dc9491f1da9dc0ab35a41df387fcd288`。

[CI情報・ハッシュ一覧](verification/acceptance-followup-ci-20261122.json)、[追加群の生レポート](verification/acceptance-followup-server-20261122.json)、[受入DLLの独立検査](verification/acceptance-followup-isolation-actual-20261122.json)、[保存検査](verification/acceptance-followup-memory-actual-20261122.json)を固定した。合成通常領域の[事前](verification/acceptance-followup-normal-before-20261122.txt)・[事後](verification/acceptance-followup-normal-after-20261122.txt)記録はバイト一致する。Artifact IDは`14778027283`（報告のみ、期限2026-12-06）。

途中の失敗も隠さず、[部分不合格の記録](verification/acceptance-followup-partial-failure-20261122.json)と履歴に残した。主因は試験側のReflection引数、保護前後のfixture作成順、予約変数、ケース間の変数スコープ、ソース内への計画出力、結果ファイルの選択であり、試験・集約処理を修正した。検査項目や製品の保護は緩めていない。最終コードの初回は固定依存取得先への接続失敗で中断したため、同じコード・URL・ハッシュのまま再実行して成功した。

Windows 10/11のGUI、通知、実Excel、正式署名、ブラウザー取得から導入・DLLロードまでの確認は未検証である。

## 今回分かった追加の開始阻害要因

- 現行の標準Runspace＋外部PowerShellファイルという方式では、Windowsクライアントの既定Restrictedや組織のAllSignedとの互換性を証明していない。独自の署名検査、CMS許可、MSIX署名だけではエンジン側の判定を置き換えない。実行ポリシーを変更する対処は採用しない。
- Azure Artifact Signingは短命証明書が日次更新されるため、現在の証明書thumbprint固定と署名許可方式へそのまま代入できない。選択した提供元に対応する実装が必要である。
- 現行ガードの明示的な変更拒否ACLとMSIXインストール領域の保護方式は別物である。OSの改変防止を検証する実装を作り、署名済み導入物で確認する必要がある。

## まだ残るAと、B・Cへの依存

ホスト互換性の解決、OSで保護される導入とガードの統合、選択した署名提供元との連携、対象PCでの事前検査から起動許可までの全プロトコルは未完成である。これは署名証明書の購入だけで解消する状態ではない。

開発者が今決めるのは販売者区分と限定取得先の希望でよい。対象資格と技術対応を確認してから見積り・契約へ進む。正式なキットを用意し、保護を変更せず開始条件を満たしてからCの操作を行う。
