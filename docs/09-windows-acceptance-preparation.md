# Windows 10/11受入テストの準備結果

2026-11-20、PR #1の `c683d4ee80dcd9e66656e3feca04e96072910517` を基準に受入手順・補助ツール・パッケージ処理を追加した。TaskPilot本体、Adapters、Storage、Codec、schemaは変更していない。mainへのマージ、本番ユーザーデータの読み書き・移行・削除は行っていない。

## テストキットの入手

- [受入キットのGitHub artifact](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44669141894/artifacts/14598983164)
- [起動README](acceptance/README-ja.md)
- [Serverの準備処理実行](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44669141894)

artifactの保持期間は14日。外側のartifact ZIPには、`TaskPilot_Windows_Acceptance_0.4.0.1.zip` と `.sha256` が入っている。受入キットのZIPも展開し、`TaskPilot_Acceptance_0.4.0.1/README-ja.md` から始める。キットZIPのSHA-256は次のとおり。

```text
8b239a37b83882b1f2bff0460335123c7791e74b6c0abfd00f533cd287093ffd
```

これは未署名の開発候補であり、販売用インストーラーではない。ZIPは実際にartifactから取得し、ハッシュ一致を確認した。Windowsへのブラウザーダウンロード・展開後にブロックされないことを確認した記録ではない。

## 依頼項目と成果物

| 依頼項目 | 作成・整理したもの |
| --- | --- |
| 1. Windows 10/11向けパッケージ | アプリ136ファイルを維持した148ファイルのキット。Application/TaskPilot、5つの日本語ガイド、Tools、ServerのEvidenceを分離。新規出力・ハッシュ照合のみを行う[パッケージ作成ツール](../tools/New-TaskPilotAcceptancePackage.ps1)を追加。 |
| 2. EXE・DLL等の一覧 | ZIP内のFILE-LIST.tsvに全アプリファイルのサイズ・SHA-256・用途を収録。同じ記録を[136ファイル一覧](verification/acceptance-runtime-files.tsv)にも保存。PACKAGE-MANIFEST.jsonはキット全体147ファイルと、除外した自身1ファイルの関係を明記。 |
| 3. 日本語の起動手順 | [README](acceptance/README-ja.md)。専用の標準ユーザー/クリーンVM、全展開、起動前検査、正しいEXE配置、再起動を記載。 |
| 4. 既存データを変更しない試験 | 上記READMEと[起動前検査](../tools/Test-TaskPilotAcceptancePackage.ps1)。実際のWindowsユーザー保存先を読み取りで確認し、初回に旧新版のデータ・ログ・バックアップ・ロックがあれば停止。データを削除して検査を通さない。 |
| 5. 機能別の検証項目 | [33ケース](acceptance/TEST-CASES-ja.md)と[結果記録用紙](acceptance/RESULT-TEMPLATE-ja.md)。タスク、子、日別記録と完了申告、6種の定期ルール、月次、3冊のExcel、通知、復元、障害を整理。 |
| 6. エラーとログ | [採取手順](acceptance/LOGS-ja.md)と[採取ツール](../tools/Collect-TaskPilotAcceptanceLogs.ps1)。限定ログ・環境・EXE/DLLの署名/ZoneIdを新しいフォルダーへ記録。DB・CSV・Excel・バックアップを自動収集せず、外部送信しない。 |
| 7. 手動DLL解除が不要な配布 | [方式比較](acceptance/DISTRIBUTION-OPTIONS-ja.md)。正規署名付きユーザー単位MSIを最初の実証候補とし、MSIXの追加課題も記載。インストーラーは未作成・未署名・未検証。 |

起動前検査は、ファイル改変、リンク、過剰ファイル、DLL等の取得元ブロック、Windows 10/11以外・不適切なPowerShell環境を検出して停止する。実行ポリシー・レジストリ・OS保護・ADSを変更しない。チェック成功はアプリ動作の合格ではなく、手動試験へ進むための前提確認である。

## 実際に確認した結果

| 環境 | 結果と限界 |
| --- | --- |
| Linux / PowerShell 7.4.6 | パッケージ検査636項目、補助ツール22項目が成功。Windows ADS・署名の分岐はSKIP。[実行記録](verification/acceptance-preparation-linux.json)。 |
| Windows Server 2022 x64 / Windows PowerShell 5.1.20348.5773 | コミット `f1c8c3a39034b37803f736a63a2542b034d03df3`、実行 #44669141894が成功。既存native自動試験8群と未署名EXE生成に加え、パッケージ636項目、補助ツール34項目が成功。補助ツール試験のSKIPは0。 |
| Windows 10 x64 / Windows 11 x64 | **実機受入は未実施**。生成EXEの起動、実画面、通知、カレンダー、Excelブック・グラフの実生成/閲覧、ブラウザー由来の配布経路は未検証。33項目の結果用紙は未記入のまま。 |

Serverでの[準備結果](verification/acceptance-server-preparation.json)、[パッケージ試験](verification/acceptance-server-packaging.json)、[補助ツール試験](verification/acceptance-server-tools.json)、[起動前検査](verification/acceptance-server-preflight.json)を保存した。Serverの起動前検査は、Windows 10/11クライアントOSではないため、意図どおり **BLOCKED** となる。一方、ファイル・証跡・取得元メタデータ・初回保存先の検査は成功した。このBLOCKEDをクライアントOSの失敗や合格と読み替えない。

補助ツールのWindows試験は、隔離したコピーのDLLにZoneId=3を付けて検知・停止し、その情報が残ることを確認した。既存のDLLからブロックを解除する試験ではない。ログ試験は合成ログ・空のログディレクトリだけを使用し、許可外のCSV・DB・下位フォルダー・リンクをコピーしないことと、元キットの全バイト不変を確認した。

初回のServer準備は `.NET` の `System.IO.Compression.ZipArchive` が未ロードで停止した。[初回記録](verification/acceptance-first-server-preparation.json)を残し、PowerShell 5.1向けに `System.IO.Compression` と `System.IO.Compression.FileSystem` を明示ロードして上記で再試験した。アプリの保存コードは変更していない。

## 実機試験で残る準備・制約

- 専用の標準ユーザー/VMを用意する。Windows 10/11の結果を別々に記録し、日常業務のデータを使用しない。
- DLLブロックやスクリプト実行拒否があれば停止して記録する。手動解除して配布試験を合格にしない。承認済みの試験配布経路と、実際の購入者向けダウンロード経路を区別する。
- C04とR03の祝日・営業日部分には、別途検証した試験CSVが必要。旧データ移行には別途検証した合成旧データが必要であり、今回のキットには含めていない。用意できない部分は未実施に残す。
- 実機の故障試験は復元可能な専用VMの別コピーに限定する。販売前の全条件は[出荷受入表](build/WINDOWS-ACCEPTANCE.md)と[販売判定](06-release-status.md)も参照する。
- 購入者向け配布方式の実装・正規署名・ダウンロードからの検証、将来のDBスキーマ更新など、以前からの商用化残課題は完了していない。
