# 独立テストモードの実装と安全性判定：BLOCKED

**完了していない。既存データがあるWindowsユーザーでの起動は案内しない。** Draft PR #1の開発ブランチに実装と回帰試験を保存したが、Windowsの合成試験で保存先のすり替え防止が成立しないことを確認した。通常版・main・実業務データは操作していない。Pythonは使用していない。

## 調査した保存経路と実装

通常版は `%LOCALAPPDATA%\TaskPilot4`、ログはTaskPilot4Logs、旧版はTaskPilot、旧データの完全バックアップはTaskPilot4LegacyBackupsを使用する。従来のFirstUseはこれらの存在でBLOCKEDとなる。旧データを持つ同じユーザーの試験のために、次を実装した。

| 対象 | 独立モードの実装 |
| --- | --- |
| 起動 | PowerShell/ps2exeの名前付き引数TestModeと32桁のTestEnvironmentId。設定ファイルや任意ルートでは選ばない |
| 保存領域 | WindowsのLocalApplicationData APIからTaskPilotTest/IDを算出し、DB、Data、Export、Backup、Logs、Temp、Input、識別マーカー、起動DB指定とロックを分離 |
| 移行・起動ロック | 旧データの存在確認・検査・自動移行を通らず、通常版の2つのロックも取得しない |
| 保存基盤 | 固定ルート検査、NOFOLLOWハンドル、hardlink数、実ハンドルパス、ファイルと親の保持、トランザクション、TRUNCATE journal、memory temp |
| DB識別 | schema_migrationsの40001行にテストIDを記録。通常DB・別IDのコピーを採用せず、通常モードもテストDBを拒否 |
| GUI | [TEST MODE]のタイトル、画面内の環境IDと注意表示。通常版への内部切替なし |
| Excel | 既存の集計・シート・グラフ処理を維持し、EPPlusはファイル名を受け取らずメモリーで生成。最終バイト列だけ保存ブローカーへ渡す |
| バックアップ | 同じIDのBackupだけを使用。TRUNCATEを明示した別接続へのSQLite Backup APIで整合したコピーを作り、検査後に公開 |
| 入力・自動処理 | Input/Backupの専用選択画面、専用Tempへの祝日取得、テストDBの通知・定期処理。外部Excelを自動起動しない |
| 配布 | ガード・コーデックをビルド時にDLL化し、購入者の起動時にはコンパイル・依存取得を行わない |

新規テストディレクトリには属性変更とownerの権限変更を拒否するDACLを設定し、許可ACEが拒否ACEに先行する既存ACLは書き換えず停止する。ただし、**これらの実装だけでは下記のリンク変更を防げず、安全性の根拠としては不足する。**

## 確認された設計上の問題

Windows Server 2022 / x64 / Windows PowerShell Desktop 5.1で、合成領域だけを使い、特権の有効化やOS保護の変更をせずに再現した。

1. **I25：保持中の空ディレクトリをjunctionへ変更できる。** GenericWriteはDACLで拒否できたが、WriteDataを指定したハンドルでreparse設定が成功した。属性の拒否と削除共有の拒否だけでは十分でない。
2. **I28：保持中のゼロバイトファイルをsymbolic reparse pointへ変更できる。** GenericWrite、WriteData、WriteAttributesの各指定で成功した。broker自身はNOFOLLOWで検査できても、SQLiteなどが後から同じ名前を独自に開く時点まで安全とは保証できない。
3. 非空の親ディレクトリはNTFSからERROR_DIR_NOT_EMPTY(145)で拒否された。保護なしの正例も成立せず、ガードの追加効果を確認した成功としては扱っていない。
4. 配布検査・診断のファイルハッシュ処理にも、hardlinkを内容読み取り前に拒否してハンドルを保持する追加検討が必要である。独立モードの公開入口はこの処理より前に停止させた。

ここで再現したのは**保護をすり抜けるパスの変更**である。実業務データにアクセスして破壊を実証したものではない。合成の通常データ・設定・バックアップのハッシュとディレクトリ構成は不変だったが、それを「本番で安全」とは読み替えない。

## 現在の停止措置

- 本体のTestModeは、実プロファイルを解決する前に `TP-ISOLATION-BLOCKED` で停止する。
- 独立モードの起動前検査はBLOCKEDとなり、packageの内容・DLL・専用領域を開かない。空IDも含めFirstUseへフォールバックしない。結果はメモリー内で返し、OutputRootの検査・ファイル出力も停止する。
- 独立モードのログ採取入口も、アプリ内容・保存先・ログを開く前に停止する。
- BuildInfoはImplemented=true / Supported=false / ReleaseBlocked=true。実装があることと利用可能であることを区別する。
- CIは必須27ケースの一意なID、全成功、SKIPなし、本番未アクセス、通常fixture不変、実Excel生成、ガードDLL一致、ファイル境界の完了を要求する。失敗時はEXE・受入ZIPをArtifactsへ公開せず、失敗報告だけを保存する。
- 通常のFirstUse検査・通常起動の保存処理は維持する。既存データを改名・削除して検査を通す方法、新しいWindowsユーザー/VMを今回の問題の解決として要求する方法、OS保護の解除は案内しない。

## 試験結果と限界

[最終Windows CI 44974780921](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44974780921)、ソース `25211b4df0b2f55ee577b700141a3a752e3e11ec`：

| 試験 | 結果 |
| --- | --- |
| 通常版native回帰8群、提供された旧保存処理回帰 | PASS |
| 独立モード合成試験 | **25成功・2失敗 / 27ケース、132検証** |
| タスク・子・作業記録・完了実績・稼働条件・通知状態・定期重複防止・月次確定 | Server自動試験PASS |
| 実xlsx 3冊とシート・グラフXML、バックアップ・復元・再起動・別ID | Server自動試験PASS |
| 通常fixtureの全ファイルハッシュ・構造 | 変更なし |
| 公開入口の停止試験 | Serverの12項目PASS。本体・検査・診断が保存先へ進まないことを確認 |
| I25 / I28 | **FAIL、配布停止** |
| Windows 10/11のEXE起動・対話GUI・通知表示・外部Excel表示 | **未検証** |
| 未署名EXE/DLL、MOTW、正規署名付き配布経路 | **未解決** |

生の証跡は `docs/verification/isolated-mode-20261122-*.json` と通常fixtureの前後比較テキストに保存した。[CIと証跡のハッシュ](verification/isolated-mode-20261122-ci.json)から辿れる。通常8群のうちprovider専用のトランザクション内改変フックはnativeでSKIPされた記録を残しており、全項目をWindowsで実施したとは扱わない。Linux PowerShell 7.4.6の通常8群もPASSで、Windows向けガードの構文とコンパイル、公開入口を停止する12項目の試験は確認した。LinuxやServerの成功をWindows 10/11の受入合格としない。

改訂した受入ZIP生成・補助ツールのWindows一連試験は、安全性ゲートが先に失敗したため未実施。必須ID欠落・重複・本番アクセス成功の偽装・未完了の境界証跡などを拒否する契約テストは追加したが、この版のキット生成成功とは報告しない。

## 次の修正方針

単なるパス再検査やACL項目の追加で合格扱いにしない。SQLiteがDB・journalを通常のファイル名で再オープンする経路をなくす設計が必要である。候補は、検査済みNOFOLLOWハンドルだけでDBとsidecarの全I/Oを行うSQLite VFS/保存サービス、または通常のユーザーデータへのアクセスがOSによって拒否されるプロセス境界である。いずれもPowerShell 5.1/WinFormsとの互換性、再起動・バックアップ・障害回復、配布とライセンスを独立した変更として実証してから採用する。名前の確認と実際の利用の間の競合を残したまま、検査を弱めて配布しない。

## Windowsで現在実行できる開発者向け検査

リポジトリ直下のWindows PowerShell 5.1で、公開入口が停止することだけを合成ファイルで確認する。アプリは起動しない。

```powershell
New-Item -ItemType Directory -Path .\TestResults -Force | Out-Null
.\tests\Test-IsolatedReleaseGate.ps1 -OutputRoot "$PWD\TestResults"
```

Windows 10/11での本体起動コマンドは現在使用不可。旧0.4.0.1 ZIPもTestModeに対応しない。将来の必須14項目と利用計画は[テストモード手順書](acceptance/TEST-MODE-ja.md)を参照する。
