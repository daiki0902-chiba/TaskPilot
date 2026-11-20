# DLLブロック問題と購入者向け配布方式の検討

確認日: 2026-11-20。対象はPR #1のSQLite対応開発候補版。**配布方式の設計・比較であり、署名済みインストーラーを完成・実機検証した記録ではない。** 今回のテスト用ZIPは未署名の開発候補であり、そのまま購入者へ販売する判定はしない。

## 現在の停止条件

`Modules/TaskPilot.Storage/TaskPilot.Storage.psm1` の `Assert-TPProviderOrigin` は、同梱providerのmanifestに載るDLLの `Zone.Identifier` を確認する。Internet / Restrictedに当たる `ZoneId=3/4` があれば、SQLite接続を始める前に明示的に停止する。DLLのハッシュ一致と、この出自の確認は別である。管理DLLはその後 `.NET Framework` の `Assembly.LoadFrom` でロードする。

Windows/.NETのロード拒否 `0x80131515` には複数の原因があり、必ずMOTWだけが原因とは扱わない。現在のエラーには限定的な `Unblock-File` の案内があるが、**購入者が手動解除しなくても使えるという要件は、現行ZIPでは未達**である。ZIPの取得方法、ブラウザー、Windowsの版、展開ツールによって出自情報の扱いが異なるため、開発PCやGitHub runnerで展開できたことだけでは解決としない。

次の操作は配布方式の解決策として採用しない。

- アプリ起動時にDLL・ZIP・フォルダー全体のADSを自動削除する、または一括 `Unblock-File` を実行する。
- Defender / SmartScreen / Attachment Managerの無効化、除外登録、実行ポリシー・レジストリーの一律変更。
- `loadFromRemoteSources` の有効化や、ロード経路の変更だけで出自確認を迂回する。
- 本人確認のない自己署名証明書を購入者の信頼済みルートへ入れるよう要求する。

## 比較

| 方式 | 期待する動作と利点 | TaskPilotで残る検証・制約 | 現時点の位置付け |
| --- | --- | --- | --- |
| 未署名のポータブルZIP | 開発候補と既存ディレクトリー構成をそのまま運べる。 | 出自情報がDLLへ継承された場合に現在のローダーが停止する。発行者の本人確認もない。 | 開発・受入準備用。購入者向け解決策とはしない。 |
| EXEにAuthenticode署名しZIPで配布 | 発行者とEXEの改変を確認できる。 | EXEへの署名はZIP内の全DLLの出自情報を消さず、現ローダーのZone判定も変更しない。ZIPそのものに対する汎用的なAuthenticode署名・検証を購入者へ要求する方式は採らない。別紙のハッシュだけでは発行者の本人確認にならない。 | EXE署名は必要な配布整備の一部だが、単独では解決にならない。 |
| 信頼された発行者で署名したMSI、必要なら署名したsetup.exe | インストーラーが検証対象の一つの成果物として、同梱ペイロードをローカルの製品用ディレクトリーへ配置する。利用者のDLL解除を起動手順に含めない構成を目指せる。既存の非パッケージWin32構成・保存先と相性がよい。 | 署名済みインストーラーから配置したprovider DLLが現ローダーを通り、実際にロードされることをWindows 10/11で確認する。署名だけでSmartScreenの警告が消えるとは保証しない。更新・修復・アンインストール時のデータ保護も要実装。 | **最初の実証候補として推奨。未実装・未検証。** |
| 署名済みMSIXを直接配布、またはMicrosoft Store経由でMSIXを配布 | パッケージ全体の署名・整合性と、OS管理による導入・更新が利用できる。StoreでのMSIXは審査・公開過程でStoreが署名する。 | 信頼される署名と正しいPublisher/Identityが必要。アプリデータの仮想化、旧版とのロック、モジュール・動的C#ロード、EPPlus差し替え、更新・削除時のデータ保持を検証する。 | 第二候補。既存アプリを単に包むだけで採用しない。 |

MOTW、Authenticode、SmartScreenは異なる仕組みである。Authenticodeは署名対象の発行者・改変検知に使う。SmartScreenは評判なども使うため、新しい正規署名のアプリでも警告され得る。MSI / EXEをStoreに掲載する場合と、MSIXをStoreが再署名する場合も同じ扱いにしない。

## 推奨する最初の実証: 署名したユーザー単位MSI

既存のPowerShell 5.1 / WinForms / SQLite構成を保ち、まず次の構成で最小の配布実証を行う。

1. ビルド済みx64 EXE、設定、Adapters、Storage、Codec、schema、ImportExcel、第三者表示・対応ソースを、固定された同じペイロードからMSIへ含める。必要なファイルを初回起動時にWebから取得しない。開発用SDK・テスト・DBは含めない。
2. 原則は標準ユーザーで導入できるユーザー単位インストールとし、例えば `%LOCALAPPDATA%\Programs\TaskPilot` にアプリファイルを置く。インストール先は現在の業務データ保存先と重ねない。起動ショートカットを作り、EXEだけを別の場所へ移動させない。
3. MSIへペイロードを内包し、外部の未署名CABや未検証ダウンロードへ依存しない。別のsetup.exeが必要な場合はそれにも正規の署名とタイムスタンプを付ける。MSIと自社EXEの署名、信頼チェーン、署名対象のハッシュをリリース工程で確認する。第三者DLLを無断で書き換えて署名し直さず、由来とライセンスを保つ。
4. 署名済み配布物をHTTPSの確定した販売者の配布元へ置く。発行者名・製品版・インストール内容を表示する。失効・改変・署名不一致の場合に導入を進めない。
5. インストーラーはファイル配置・ショートカット・必要な製品登録に限定する。業務DBを初期化・変換しない。アプリの旧データ移行は、既存の検査・承諾・バックアップ・新DB作成経路を使う。
6. 更新時はアプリの終了を確認し、整った新しいペイロードだけを配置する。Windows Installerの更新・失敗時ロールバックを試験する。ファイル配置のロールバックと、DBスキーマ更新・業務データのロールバックを同一視しない。将来版のDB更新機構は別の未完了項目である。

このMSI方式で「インストールしたDLLにInternet ZoneのADSが付かない」「付かなくても他の.NET制約がない」を保証済みとはしない。**現ローダーを残したまま、実際のブラウザーダウンロードからインストール・起動まで合格すること**が採用条件である。DLLのADS削除カスタムアクションを足して見かけ上通す方針ではない。

全ユーザー向けにProgram Filesへ導入する別構成を選ぶ場合は、管理者によるインストールが必要になることを明示する。アプリは通常権限で動作し、Program FilesにDB・ログ・Excelや生成キャッシュを書き込まないことを試験する。通常権限での動作と、インストーラーの導入権限を区別する。

### 元データの保護

MSIのFile / RemoveFile / Registryや更新・アンインストールのカスタムアクションに、次のデータ保存先を削除・初期化する処理を含めない。

- `%LOCALAPPDATA%\TaskPilot`（旧CSV / JSON）
- `%LOCALAPPDATA%\TaskPilot4`（DB、使用中DB指定、SQLiteバックアップ、Excel）
- `%LOCALAPPDATA%\TaskPilot4Logs`（診断・移行記録）
- `%LOCALAPPDATA%\TaskPilot4LegacyBackups`（旧データの完全バックアップ）

アプリ本体の導入先を変えても、既存データ保存先は販売版の版番号で作り直さない。旧版を消したり、同じユーザーの本番データを受入試験用へ流用したりしない。

### LGPLとファイル配置

EPPlus 4.5.3.2は、同梱しているLGPL条件、対応ソース、変更版の差し替え・デバッグ権利を維持する。MSIにしても、`Modules/ImportExcel/EPPlus.dll` を自社EXEへ埋め込まず、対応する第三者表示とソースZIPを残す。利用者が保管した別コピーで、互換の変更版DLLへ差し替えて実行できる構造を維持し、EULAもこれを妨げない。

MSIの修復・更新が元DLLを戻す条件も明示する。元DLLへの置換で差し替えが失われるため、更新前に変更版の保存を案内し、変更版が入っているという理由だけでアプリ全体を実行拒否する恒久的なハッシュ強制をEPPlusへ加えない。配布物の改変検査と、利用者が許されるライブラリ変更を区別する。

## MSIXを採用する場合の追加設計

Microsoftの仕様では、MSIXのインストール場所は通常WindowsApps配下の保護された読み取り専用領域となる。デスクトップアプリにもAppDataなどの仮想化が関係し、OSの版やパッケージ宣言によって挙動が異なる。このため、次を設計・実証する前に「MSIXで解決」としない。

- 正規のPublisherとパッケージIdentity、署名証明書のSubjectを整合させる。直接配布時は対象端末で信頼される証明書を使う。購入者への自己署名ルート証明書の手動導入を前提にしない。
- 既存 `%LOCALAPPDATA%\TaskPilot` を確実に検出でき、元CSV / JSONへ書き込まないこと。新DB・診断・完全バックアップの実際の物理保存先、パッケージ外の旧版と共有する排他ロックを確認する。
- リセット・修復・アンインストールによって、仮想化されたDB・完全バックアップまで消える構成を避ける。データの永続先と別途保管・復元経路を明確にする。
- ps2exeの起動フォルダー解決、PowerShellモジュールの読み込み、SQLite native DLL、Codecの `Add-Type`、Excel出力が、標準ユーザー・読み取り専用インストール場所で動くこと。
- パッケージ内EPPlusが読み取り専用になる点に対応し、互換の変更版を使える実効的な方法を用意する。将来MSIXを選ぶ場合は、承諾した外部ライブラリ場所を選択する等の実装と試験、または同じ版の差し替え可能な非パッケージ配布物の提供を含めてライセンス条件を確認する。WindowsAppsのACL変更や保護解除を利用者へ要求しない。

MSIXを直接配布する場合も、単にファイルを署名しただけで全端末のSmartScreen警告がなくなるとは案内しない。Storeを選ぶ場合も、TaskPilotの互換性試験・審査・ライセンスとデータ保持の確認は残る。

## Windows 10/11での配布実証の合格条件

各試験は専用の標準ユーザーまたは復元可能なVMで行い、本番ユーザーデータを使わない。Windows Server CIの8群成功・EXE生成は、この表の合格証跡に置き換えない。

| ID | 実施内容と合格条件 | Win10 | Win11 |
| --- | --- | --- | --- |
| P-D01 | 既存製品・Python・SQLite・追加PowerShellモジュールを手動導入していない環境で、対象OS版・ビルド・.NET Framework・権限・セキュリティ設定の既定値を記録する。 | 未実施 | 未実施 |
| P-D02 | 確定したHTTPS配布元からEdge等で署名済みMSI / setupを取得する。ブラウザー名・版・URL・ファイル名・SHA-256・Zone情報・署名の発行者/状態/タイムスタンプを記録する。 | 未実施 | 未実施 |
| P-D03 | 既定のDefender / SmartScreenを有効のまま導入する。通常の同意や警告はそのまま記録し、警告がないと偽らない。署名不一致・改変試料は停止し、個別DLLの解除・OS設定変更を要求しない。 | 未実施 | 未実施 |
| P-D04 | インストール先の全provider DLLのハッシュ・ADS・実際のロード元を読み取りで確認する。起動ショートカットからTaskPilotを開き、Zoneブロック・0x80131515・native依存欠落がない。解除コマンドを使って通した試験は不合格。 | 未実施 | 未実施 |
| P-D05 | タスク1件、サブタスク、0.75hと0.26hの作業記録を保存し、合計1.01hが再起動後も一致する。3つのExcelを生成・閲覧し、インストール先への書込みが不要である。GUIの作業記録の最小入力は0.25hなので、0.01hを1件で入力する手順にはしない。 | 未実施 | 未実施 |
| P-D06 | 合成旧データのコピーで、検査・取消・承諾・新DB移行・旧版排他を試す。元データの全ハッシュが不変で、別ユーザーのデータへアクセスしない。 | 未実施 | 未実施 |
| P-D07 | 合成データを保持したまま上書き更新、途中失敗、再導入、修復を試す。失敗時も既存DB・旧指定・完全バックアップを残し、整った旧版または新版のいずれかを再起動できる。 | 未実施 | 未実施 |
| P-D08 | アンインストール後にデータ4保存先が保持され、再導入で内容を読み戻せる。MSIXでは実物理パス・リセット/削除の挙動も記録する。 | 未実施 | 未実施 |
| P-D09 | バックアップした別コピーで互換EPPlus変更版を利用できること、対応ソースとライセンスが同梱されることを確認する。更新・修復の影響を記録する。 | 未実施 | 未実施 |

署名には、販売者の正式名称・本人確認済みのコード署名手段・秘密鍵管理・タイムスタンプ・配布元が必要である。現在これらは未確定で、証明書や発行者を仮定した署名済み成果物は作成していない。MSI/セットアップの実装、MSIXの変換、Windows 10/11上の上記試験はいずれも今後の工程である。

## 参照した一次資料

以下はMicrosoft Learn。仕様の根拠と、TaskPilot固有の実機で確認すべき推論を分けている。参照日: 2026-11-20。

- [.NET Framework: loadFromRemoteSources](https://learn.microsoft.com/en-us/dotnet/framework/configure-apps/file-schema/runtime/loadfromremotesources-element) — リモート由来アセンブリとロード拒否の説明。要素を有効にする提案ではない。
- [SmartScreen reputation for Windows app developers](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation) — 署名と評判の違い。正規署名でも警告があり得る。
- [Windows Installer: Installation Context](https://learn.microsoft.com/en-us/windows/win32/msi/installation-context) — ユーザー単位 / マシン単位のインストール。
- [Code signing options for Windows app developers](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options) — StoreのMSIX署名とMSI/EXE配布の違い。
- [Sign an MSIX package](https://learn.microsoft.com/windows/msix/package/signing-package-overview) — MSIX署名方式と信頼。
- [Understanding how packaged desktop apps run on Windows](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes) — 配置、データ分離、仮想化と削除の扱い。
- [MSIX containerization overview](https://learn.microsoft.com/en-us/windows/msix/msix-containerization-overview) — 読み取り専用のインストール場所と仮想化。

ライセンスの詳細は[既存の監査](https://github.com/daiki0902-chiba/TaskPilot/blob/development/sqlite-commercial-20261116/docs/build/LICENSE-AUDIT.md)と[第三者表示](https://github.com/daiki0902-chiba/TaskPilot/blob/development/sqlite-commercial-20261116/docs/build/THIRD-PARTY-NOTICES.md)を参照する。対応するライセンス本文とソースはキットのApplication/TaskPilot配下にも同梱する。配布形態を変更する際も再確認する。
