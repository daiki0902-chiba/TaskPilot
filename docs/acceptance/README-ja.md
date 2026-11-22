# TaskPilot Windows 10 / 11 受入テスト用ガイド

このパッケージは、PR #1のSQLite対応版を確認するための開発候補です。販売用ではありません。アプリは0.4.0.2・x64・未署名です。Windows 10/11でのEXE起動・画面操作・通知・実Excel閲覧は、対応する実施証跡がある場合だけ合格とします。

**通常の初回試験と独立テストモードを区別してください。** 引数なしの通常起動は、新しい専用の標準ユーザーまたは業務データのないVMだけで試します。既存業務ユーザーでの独立モードは [TEST-MODE-ja.md](TEST-MODE-ja.md) に従い、対象ビルドの自動試験・レビュー・実機起動確認が揃うまで実行してよいと案内しません。以下の通常初回用コマンドを既存業務ユーザーで使いません。既存データの削除、移動、名前変更、初期化、上書きは行いません。

| モード | 検査と起動 |
| --- | --- |
| 通常の初回試験 | 従来の `-FirstUse`。旧新版のデータ・ログ・バックアップ・ロックがあればBLOCKED。空の専用ユーザー/VMでのみ引数なしEXEを使う。 |
| 独立テストモード | 検査とEXEの両方に `-TestMode -TestEnvironmentId <32桁の小文字16進GUID>`。専用領域だけを検査し、正常なら `READY_FOR_ISOLATED_TEST`。`-FirstUse` と併用しない。 |

単に `-FirstUse` を外す方法ではありません。`PACKAGE_CHECK_ONLY` は起動許可ではありません。展開先を変えるだけで、同じユーザーの通常保存先から分離したことにもなりません。

## 確認済みの範囲

| 対象 | 状態 |
| --- | --- |
| Windows Server 2022 x64 / Windows PowerShell 5.1 / 同梱SQLite | 旧保存回帰試験と自動テスト8群が成功。一部のテスト専用故障注入ケースはSKIP。 |
| 同Serverでのビルド | 未署名EXE・候補ZIP生成、x64 GUI PE形式・版情報・配布ファイル検査が成功。 |
| Windows 10 x64 / Windows 11 x64 | この受入テストの対象。操作・起動の合格記録はまだない。 |
| 実際のWinForms、通知、カレンダー、実Excel閲覧 | 実機の対話操作は未検証。独立スイートの実ブック・グラフXML生成の成否は当該Evidenceで確認し、外部Excelでの表示合格と分ける。 |
| ダウンロード後のDLLブロック、署名・インストーラー | 未解決の配布条件。安全な配布方式は検討段階。 |

上記の従来Server成功は0.4.0.1の記録です。0.4.0.2の独立モードの成功へ転記しません。`PACKAGE-MANIFEST.json` の `CandidateSourceCommit` と `ServerEvidenceRunUrl`、`Evidence/windows-native-results.json`、`windows-native-verification.json`、`windows-build-info.json`、`windows-isolated-mode-results.json` を確認してください。独立スイートは合成通常領域の不変性などを検証します。Serverの自動試験とWindows 10/11の対話GUIの結果は分けて保管します。

## 同梱物と必要なファイル

| 場所 | 用途 |
| --- | --- |
| `Application\TaskPilot\TaskPilot.exe` | ダブルクリックして起動するアプリ。EXE単体で移動しない。 |
| `Application\TaskPilot\TaskPilot.exe.config` | .NETの起動構成。EXEと同じ場所に保管する。 |
| `Application\TaskPilot\Runtime\TaskPilot.Runtime.ps1`、`TaskPilot.TestSandbox.dll` | モード・保存先の選択とWindowsのファイル境界。DLLを同梱し、起動時のC#コンパイルを行わない。 |
| `Application\TaskPilot\Modules\TaskPilot.Storage\provider\System.Data.SQLite.dll` | .NET用SQLite接続ライブラリ。 |
| 同provider内の `x64\SQLite.Interop.dll` | x64アプリで使うnative SQLite。 |
| 同provider内の `x86\SQLite.Interop.dll` | 元の検証済みprovider一式として保持。今回のEXEはx64。 |
| `Application\TaskPilot\Modules\ImportExcel\EPPlus.dll` | Excelファイル生成。ImportExcelのスクリプト一式も必要。 |
| `Application\TaskPilot\Adapters`、`Modules`、`Codec`、`schema` | 画面とSQLiteの接続、保存・移行・復元、Excel、データ形式。全ファイルをそのまま保管する。 |
| `Application\TaskPilot\ThirdPartyNotices`、`ThirdPartySources` | 第三者ライセンス、EPPlusの対応ソース。削除・省略しない。 |
| `FILE-LIST.tsv` | アプリ全ファイルの相対パス、サイズ、SHA-256、用途。 |
| `PACKAGE-MANIFEST.json` | テストキットのファイル検証用一覧、バイナリの版・出典、検証範囲。マニフェスト自身は一覧から除外。 |
| `Tools` | 起動前の読み取り検査、任意の診断採取。アプリを自動起動しない。 |
| `Evidence` | Serverでの自動試験・生成の証跡。Windows 10/11の合格記録ではない。 |

独立モードの起動・保存先・必須14項目は [TEST-MODE-ja.md](TEST-MODE-ja.md)、従来33ケースは [TEST-CASES-ja.md](TEST-CASES-ja.md)、記録用紙は [RESULT-TEMPLATE-ja.md](RESULT-TEMPLATE-ja.md)、ログ採取は [LOGS-ja.md](LOGS-ja.md) にあります。アプリフォルダー内の一般利用ガイドにある業務用旧データの引き継ぎは行いません。

## 1. 通常の初回試験の環境を用意する

1. Windows 10 x64とWindows 11 x64で別々に実施します。専用の標準ユーザーを作成してサインインするか、業務データのない専用VMを用意します。ユーザー作成が必要な場合は、そのPCの管理者に依頼してください。アプリの実行には管理者権限を使いません。
2. このユーザーで旧TaskPilotもSQLite版も使ったことがないことを確認します。既存の `TaskPilot`、`TaskPilot4`、ログ・バックアップ・ロックが見つかった場合は、そのユーザーでの試験を中止し、別の新しいテスト環境を用意します。検査を通すためにファイルを削除しません。
3. 業務用の共有フォルダー、他ユーザーのプロファイル、実データを含むVM共有フォルダーは試験に使用しません。登録する情報はすべて `UAT-` で始まる架空の内容にします。
4. Windows PowerShell 5.1 Desktop・64ビットと.NET Framework 4.6以上を使用します。.NET Framework 4.8を推奨します。Python、SQLite、PowerShellモジュールの追加インストールは不要です。クリーンなPCで追加依存が不要かは、この試験で確認します。
5. Excelファイルの作成自体にExcel本体は不要です。表示・グラフの確認には、実際のExcelまたは対象の `.xlsx` 閲覧アプリを使い、製品名・版を記録します。

環境変数 `LOCALAPPDATA` の差し替えによる隔離は行いません。本体は.NETのWindowsユーザーフォルダー取得APIを使用します。

## 2. 入手・展開・通常初回の起動前検査

この節の `-FirstUse` は空の専用ユーザー/VMだけで使います。独立モードは [専用ガイド](TEST-MODE-ja.md) の検査コマンドへ進んでください。

1. 開発者から指定されたZIPのSHA-256を、信頼できる別の経路の値と照合します。`Get-FileHash -LiteralPath 'ZIPの実際のパス' -Algorithm SHA256` で確認できます。ZIPと一緒のハッシュファイルやマニフェストだけでは、発行元の認証にはなりません。
2. ZIPを専用ユーザーの通常のローカルフォルダーへ**全て展開**します。ZIP内から実行しません。クラウド同期先・共有先・ネットワークドライブは避けます。GitHub Actionsのartifactから取得した場合は、外側のartifact ZIPに入っている受入テスト用ZIPも展開します。
3. `README-ja.md` と `PACKAGE-MANIFEST.json` があるフォルダーで、64ビットのWindows PowerShell 5.1を開きます。次を実行します。

```powershell
$tpKit = (Get-Location).Path
$tpResults = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('TaskPilotAcceptanceResults_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tpResults -ErrorAction Stop | Out-Null
$tpCheck = & (Join-Path $tpKit 'Tools\Test-TaskPilotAcceptancePackage.ps1') -PackageRoot $tpKit -OutputRoot $tpResults -FirstUse
$tpCheck | Format-List Status, ReportPath
$tpCheck.Checks | Format-Table -AutoSize
```

検査はアプリを起動せず、業務データを書き換えません。ファイルの有無・ハッシュ・リンク、OSとPowerShell、コードの取得元ブロック、既存保存先の有無を読み取り、指定した新しい結果フォルダー内にだけ報告を作成します。ハッシュの一致は、Windowsでの動作合格や安全性の認証を意味しません。

**`READY_FOR_MANUAL_TEST` の場合だけ、次へ進みます。** `BLOCKED`、`PACKAGE_CHECK_ONLY`、検査エラーの場合は、表示・結果ファイルを保存して止めます。検査スクリプト自身が実行ポリシーで拒否された場合も、メッセージを記録して担当者へ連絡してください。実行ポリシー、OS保護、レジストリ、DLLブロックを変更する手順はこのキットにありません。

Zone.Identifier付きDLLは現在のローダーが拒否します。表示されたエラーに解除コマンドが含まれていても、この受入では実行せず、配布試験を `BLOCKED` と記録します。機能試験を進めるには、担当者が取得元とハッシュを確認できる承認済みのテスト配布経路を用意し、同じ保護設定のまま起動前検査を通ることが必要です。通常のブラウザーダウンロード経路の合格は別途確認します。

## 3. 通常初回用のアプリ起動・操作

1. 専用のテストユーザーであることを再確認し、`Application\TaskPilot\TaskPilot.exe` をダブルクリックします。EXE・DLL・フォルダーは元の配置のまま使います。
2. 旧データを引き継ぐ案内が出た場合は、キャンセルして試験を中止します。空の専用環境という前提を確認し直してください。データの初期化や削除は行いません。
3. 初回の新規DB作成、画面表示、終了・再起動を確認し、[検証ケース](TEST-CASES-ja.md)に従って架空のタスク・実績だけを登録します。ケースごとに期待値と実際の結果を記録します。
4. 同じ専用ユーザーでの2回目以降は、同じ `TaskPilot.exe` を使用します。`-FirstUse` は初回用です。既に作ったテストデータのため初回検査が止まっても、データを削除してやり直しません。別ユーザー・別VMでの初回試験と、同じテスト環境での再起動試験を区別します。
5. 実機の強制終了・容量不足・権限拒否などの障害試験は、通常の機能試験後、復元可能な専用VMのテスト用コピーでのみ行います。業務PCのディスクを満杯にしたり、実データの権限を変えたりしません。

| テスト中の保存物 | 専用ユーザーの保存先 |
| --- | --- |
| DB・使用DBの指定・バックアップ・Excel | `%LOCALAPPDATA%\TaskPilot4` |
| 操作・エラー・移行の記録 | `%LOCALAPPDATA%\TaskPilot4Logs` |
| 旧データ移行時の完全バックアップ | `%LOCALAPPDATA%\TaskPilot4LegacyBackups`。今回の新規データ試験では移行しない。 |

アプリ・旧版の保存先、DB、回復用sidecar、`active-store.json` は手作業で編集・削除しません。今回のキットには実ユーザーデータも移行用の旧データ見本も含めていません。旧データ移行の実機試験は、別途用意して検証した合成旧データを専用環境で使用する工程として記録し、今回の新規登録試験の合格から推定しません。

## 4. 記録とエラーの採取

[RESULT-TEMPLATE-ja.md](RESULT-TEMPLATE-ja.md)を結果フォルダーへコピーし、OS、試験者、取得元、ZIP/EXEのハッシュ、画面の拡大率、ケースID、実際の結果を記載します。Win10とWin11は別の記録にします。`PASS / FAIL / BLOCKED / NOT RUN` を区別し、未実施を合格にしません。

エラー時は操作を止め、発生時刻、操作、期待した結果、実際のエラー全文・画面を記録してください。[LOGS-ja.md](LOGS-ja.md)の診断ツールは限定したログと環境情報だけを、新しいフォルダーへ採取します。DB・タスクCSV・Excel・バックアップは自動収集しません。ログに内容が含まれる可能性があるため、送付前に確認します。外部への自動送信は行いません。

独立モードの診断には同じ `-TestMode -TestEnvironmentId` を必ず指定します。独立モードでログが見つからない場合も、通常ログを採取するコマンドへ切り替えません。

## DLLブロック問題と配布方法

現在のZIPは未署名の開発候補です。署名したEXEだけを配っても、同梱DLLの取得元ブロックやSmartScreenの問題が解決したとはいえません。最初の実証候補は、発行元を確認できる正規署名付きのユーザー単位MSIです。MSIXも候補ですが、旧保存先へのアクセス・排他・更新/アンインストール後のデータ保持・ライブラリの差し替え権を確認する必要があります。

インストーラーはまだ作成・署名・実機検証していません。比較、必要条件、実際のブラウザーダウンロードから試す合格条件は [DISTRIBUTION-OPTIONS-ja.md](DISTRIBUTION-OPTIONS-ja.md) にまとめています。購入者の手動解除が不要な配布が完成したとは案内しません。

## 開発者がキットを再構成する場合

PR #1の開発ブランチで、当該候補ZIPのSHA-256・ソースコミット・通常Server試験と生成証跡・独立モード試験結果を明示して再構成します。独立試験結果を含む必須引数は `tools/New-TaskPilotAcceptancePackage.ps1` のパラメーターを確認してください。旧0.4.0.1のハッシュ・証跡を既定値として流用しません。新しい出力先にだけ生成し、実データやアプリ起動は行いません。GitHub Actionsの対象実行で生成されたキットとEvidenceを一式で取得します。
