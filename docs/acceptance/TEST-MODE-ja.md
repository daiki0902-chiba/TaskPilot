# 独立テストモードの利用・受入手順

対象はSQLite対応PR #1の **0.4.0.2以降の独立テストモード対応候補**です。0.4.0.1には本機能がありません。これは実装と受入の手順書であり、既存の業務データがあるWindowsユーザーで今すぐ起動してよいという案内ではありません。対象ビルドの自動試験・コードレビュー結果を確認し、Windows 10/11実機での起動・操作確認を終えるまで、同一業務ユーザーでの安全な利用を完了したとは判定しません。

以下のコマンドは、受入担当者が対象ビルドと試験条件を確認した後に使用する手順です。未検証項目は「未実施」のまま記録します。OSの保護やDLLのブロックを解除する手順は含めません。

## 通常の初回試験との違い

| 起動・検査 | 用途と停止条件 |
| --- | --- |
| 起動前検査の `-FirstUse` | 従来の通常版初回試験。通常版・旧版のデータ、ログ、バックアップ、ロックがある場合は `FirstUseIsolation` でBLOCKED。専用の空プロファイルが必要。 |
| 起動前検査の `-TestMode -TestEnvironmentId ID` | 独立テスト用の保存境界を検査する。通常版の保存先を存在検査・読み込みせず、指定IDのテスト領域だけを扱う。`-FirstUse` と同時指定しない。 |
| EXEの `-TestMode -TestEnvironmentId ID` | 検証済みの独立テストモードで起動する。通常版の保存先、旧データの検査・自動移行、通常版の2つのロックは使用しない。 |
| 引数なしのEXE起動 | 通常起動。独立テストのためには使用しない。 |

単に `-FirstUse` を外す方法ではありません。`PACKAGE_CHECK_ONLY` は起動許可ではありません。独立モードでは、全検査が成功した `READY_FOR_ISOLATED_TEST` だけを次工程の前提として使用します。検査成功も実際のGUI操作の合格を意味しません。

## 保存先と識別

IDは小文字16進数32桁のGUID形式に限定します。任意の保存先パス、相対パス、共有パス、環境変数、設定ファイルからテストルートを指定する機能はありません。本体はWindowsのLocalApplicationData取得APIを使います。`LOCALAPPDATA` の環境変数だけを書き換えて隔離したことにはしません。

```text
%LOCALAPPDATA%\TaskPilotTest\<ID>\
  .taskpilot-test-environment  テスト領域の形式・IDを識別するマーカー
  test.storage.lock           このIDだけの起動ロック
  TaskPilot.db                初回DB。復元時は同じ領域に別名DBを追加
  active-store.json           使用するDBの指定。任意の外部パスは保持しない
  Data\                      互換識別用の領域
  Export\                    TaskList.xlsx / CompletedTask.xlsx / Dashboard.xlsx
  Backup\                    このIDのSQLiteバックアップ
  Logs\                      操作・エラーログ
  Temp\                      一時CSV、処理用一時ファイル・プロセス内キャッシュ
  Input\                     試験用の祝日CSVを置く専用入力領域
```

タスク、サブタスク、日別記録、予定・完了工数、設定、通知、稼働カレンダー、定期ルール、月次確定と履歴は、このテスト領域のSQLiteに保存します。プロセス内のTEMP/TMP、SQLite一時領域、PowerShellモジュール解析キャッシュも、境界を確認してからテスト用Tempへ向けます。ユーザー・マシンの永続環境変数やOS設定は変更しません。

同じIDで再起動すると同じテストデータを使います。新しいIDは別の空のテスト環境です。IDを忘れて新しく生成すると以前のデータが消えたように見えるため、IDと保存先を結果記録へ控えます。以前の領域を削除しません。

起動中はタイトルに `[TEST MODE]`、画面下に「テスト環境」とIDを表示します。通常版へ切り替えるメニューはありません。識別表示がない場合、旧データ引き継ぎ画面が出る場合、想定外の保存先を示す場合は操作せず停止します。

## 起動前検査と実機コマンド

対象はWindows 10/11 x64、64ビットのWindows PowerShell 5.1 Desktop、.NET Framework 4.6以上です。.NET Framework 4.8を推奨します。テスト用保存先はローカルのNTFSが必要です。ネットワーク共有、割り当てたネットワークドライブ、別名ドライブやリンクによる保存先は使いません。追加のPython、SQLite、PowerShellモジュールのインストールは不要です。

1. 指定されたキットZIPのハッシュと出典を確認し、ローカルの通常フォルダーへ全て展開します。GitHub artifactの外側ZIPに入っている内側ZIPも展開し、`PACKAGE-MANIFEST.json` と本書があるフォルダーを開きます。
2. アプリを実行せず、まず同梱の署名・ファイル・取得元チェックを行います。新しい結果フォルダーを作ります。

```powershell
$tpKit = (Get-Location).Path
$tpEnvironmentId = [guid]::NewGuid().ToString('N')
$tpResults = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('TaskPilotTestResults_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tpResults -ErrorAction Stop | Out-Null
Set-Content -LiteralPath (Join-Path $tpResults 'TestEnvironmentId.txt') -Value $tpEnvironmentId -Encoding UTF8 -ErrorAction Stop
$tpCheck = & (Join-Path $tpKit 'Tools\Test-TaskPilotAcceptancePackage.ps1') -PackageRoot $tpKit -OutputRoot $tpResults -TestMode -TestEnvironmentId $tpEnvironmentId
$tpCheck | Format-List Status, Mode, TestEnvironmentId, ExpectedTestRoot, ReportPath
$tpCheck.Checks | Format-Table -AutoSize
```

独立検査は通常版の保存先を調べず、確認した境界DLLを使ってテスト用マーカーと空の専用ディレクトリを準備する場合があります。既存の業務データをコピー・移行しません。Windows ServerはWindows 10/11の実機受入対象ではないため、この検査ではBLOCKEDになります。

**BLOCKED、PACKAGE_CHECK_ONLY、検査の例外、DLL/スクリプトの実行拒否があれば起動しません。** ファイルを削除したり、ブロックを解除したり、実行ポリシーを変更して通しません。表示と報告を保存します。

3. `READY_FOR_ISOLATED_TEST` と対象ビルドの実施条件を確認した受入担当者は、次の形式で起動します。`--test-mode` ではなく、PowerShell/ps2exeが対応する名前付き引数を使用します。

```powershell
& (Join-Path $tpKit 'Application\TaskPilot\TaskPilot.exe') -TestMode -TestEnvironmentId $tpEnvironmentId
```

4. `[TEST MODE]` とIDの表示を確認し、架空の `UAT-` データだけを入力します。再起動時は保存した同じIDを読み、同じ引数で起動します。

```powershell
# 新しいPowerShellを開いた場合は、tpKit/tpResultsを実際のキット・結果フォルダーへ設定する。
$tpEnvironmentId = (Get-Content -LiteralPath (Join-Path $tpResults 'TestEnvironmentId.txt') -Raw -Encoding UTF8).Trim()
& (Join-Path $tpKit 'Application\TaskPilot\TaskPilot.exe') -TestMode -TestEnvironmentId $tpEnvironmentId
```

実装・バイナリが未確認のまま、通常版のEXEと取り違えて実行しません。EXEだけを移動せず、Runtime、Adapters、Modules、Codec、schema、第三者表示・対応ソースを一式で保持します。

## ファイル選択・Excel・復元

- 祝日CSVの手動取り込みは、このIDの `Input` に置いた検証済み合成CSVだけを選ぶ固定一覧です。通常フォルダーをブラウズするOpenFileDialogは使いません。公式CSVを取得する場合の一時ファイルは、このIDの `Temp` に置きます。
- 復元元は、このIDの `Backup` にあるDBだけを選ぶ固定一覧です。通常版のバックアップ、他IDのDB、外部パスを指定しません。同じスキーマでも、DB内のテスト環境IDが一致しないものは取り込みません。
- 復元は同じテスト領域の新しいDBへ行い、元のテストDBを残します。通常版のDB・設定・バックアップは参照しません。
- Excelの3ブックとグラフはこのIDの `Export` に生成します。「開く」ボタンはテスト出力の場所を案内し、関連付けアプリを自動起動しません。試験者が別途Excelで開く操作は、Excel自身の最近使ったファイル・自動回復など、TaskPilotが制御できない外部アプリの動作を伴います。生成の検証と外部閲覧の検証を分けます。

## 既存データを保護する実装上の根拠

次はコードで設けた境界です。成功を確認した試験範囲は、同梱の `Evidence/windows-isolated-mode-results.json` と対応するCI実行を確認します。実装があることだけで実機合格と判断しません。

| 境界 | 内容 |
| --- | --- |
| 初期化の順番 | 引数を最初に検証し、モードを固定してから保存先を設定する。テストモードの失敗時に通常ログや通常起動へfallbackしない。 |
| データ・移行 | 起動時に旧データの存在検査、取り込み、通常版の2つのロックを実行しない。移行APIもテスト境界設定後は拒否する。 |
| パス | 許可ルート外を内容の読み取り前に拒否する。任意のルートを引数・設定・環境変数から受け付けない。 |
| リンクと差し替え | WindowsのNOFOLLOWハンドルとファイル情報でreparse point・hardlink等を検査し、親ディレクトリの削除共有を与えないハンドルを保持する。書き込み・名前変更・削除も境界内のハンドルで扱う。 |
| DB識別 | schema_migrationsの40001の説明にテスト専用IDを記録する。既存DBを後から自動でテスト用と認定せず、異なるID・通常DBを拒否する。通常の保存層もテスト用マーカーのあるDBを通常DBとして開かない。 |
| SQLと一時処理 | テスト接続はjournal_mode=TRUNCATE・temp_store=MEMORYを使う。DBとjournalのハンドルを管理する。既存WAL/SHMや非空の回復journalは、削除や自動回復で隠さず停止する。 |
| 失敗時 | 境界違反でコンテキストを停止し、通知タイマーと画面を終了する。通常版へ切り替えない。ログを安全に書けない場合も通常ログへ逃がさない。 |

これは同一ユーザー権限の悪意ある別プログラムや管理者に対するOSサンドボックスではありません。検証済みアプリ・ライブラリと通常のWindows権限を前提に、TaskPilotのファイル経路を制限する仕組みです。OS自身の実行履歴・キャッシュや外部閲覧アプリの永続化を、テスト領域だけに閉じ込めたと保証するものではありません。通常版のデータを手作業でテスト領域へコピーする運用も行いません。

## 必須14項目と実機記録

次のTM番号は独立モードの受入項目です。自動試験番号は実装済みスイートの対応先を示します。**結果はEvidenceの実際のケース結果から記録し、ここに書かれた予定番号だけで合格にしません。** 通常版の比較データ・パス攻撃・障害注入には、合成したプロファイルと検証用コピーだけを使用します。実際の業務データをハッシュ採取や破壊試験の対象にしません。

| 手動ID / 依頼番号 | 検証すること | 対応する自動試験と実機で残る確認 |
| --- | --- | --- |
| TM-01 / 1 | 通常データがある条件でも独立モードが起動する | I01は合成通常データ・ロックを置いた起動処理。既存業務ユーザーでの実EXE・GUI起動は別の実機受入。 |
| TM-02 / 2 | 新規タスクを登録する | I03の実保存処理。GUIの追加・再表示を実機で確認。 |
| TM-03 / 3 | 状態変更・編集・削除・サブタスク操作 | I03/I04。ダイアログ、確認キャンセル、進捗表示を実機で確認。 |
| TM-04 / 4 | 日別・進捗・完了申告を区別して保存する | I04。0.75h＋0.26h＝1.01hと完了実績1.25hを別値で確認。 |
| TM-05 / 5 | Excel3冊とグラフを生成する | I06の実ブック・チャートXML生成。Windows 10/11・実Excelでの表示/修復要求は未検証。 |
| TM-06 / 6 | テストデータが通常版へ混ざらない | I22/I24は通常層のテストDB拒否と合成通常領域不変。実通常版の業務データを編集して比較しない。 |
| TM-07 / 7 | 通常データをテスト版へ取り込まない | I09/I20。通常領域の読み取り・移行の拒否、無印/他IDのコピーを自動認定しないことを確認。 |
| TM-08 / 8 | バックアップ・復元をテスト領域で完結する | I07。固定一覧、キャンセル、復元後の再起動を実機で確認。 |
| TM-09 / 9 | 通常版の保存先・ロックと衝突しない | I01は合成通常データを保持する別プロセスとロックを使用。実GUIの同時動作は別途実機確認。 |
| TM-10 / 10 | 同じIDで再起動してデータを保持する | I07/I08。同じIDと新しいIDの画面を実機で区別し、以前の領域を削除しない。 |
| TM-11 / 11 | 不正・アクセス不能な保存先で停止する | I21。障害は合成プロファイルだけで注入し、エラー画面と通常版へのfallbackがないことを確認。 |
| TM-12 / 12 | 通常側のハッシュとディレクトリ構成が不変 | I24の合成通常データ全体の前後比較。業務原本を比較用に読み込まない。 |
| TM-13 / 13 | パス差し替え・junction・symlink・hardlinkを拒否する | I10～I18。実データをリンク先にせず合成通常データだけを使用。ケースSKIPは未検証として残す。 |
| TM-14 / 14 | 通知・自動生成・カレンダー・月次が通常側を参照しない | I05/I09/I24。タイマー待ち、実際の通知・月次画面・定期生成の操作は実機で確認。 |

各IDの結果は [RESULT-TEMPLATE-ja.md](RESULT-TEMPLATE-ja.md)の独立モード欄へ記入します。既存の33項目は [TEST-CASES-ja.md](TEST-CASES-ja.md)を併用し、保存先とファイル選択・Excel閲覧の違いを本書に合わせます。

## エラー・制限・実施判定

エラー時は時刻、ID、対象ビルド、操作、エラー全文を記録し、[LOGS-ja.md](LOGS-ja.md)の `-TestMode -TestEnvironmentId` 付き診断だけを使います。通常の診断コマンドへ切り替えて通常ログを採取しません。DB・WAL/SHM/journal・マーカー・ポインターを手作業で修復・削除せず保存します。

非空journalやWAL/SHMの停止は、テストデータについても自動回復しないという制限です。担当者が診断し、同じIDの検証済みバックアップを使う復旧工程を別途決めます。エラーを消すためにファイルを取り除いて再起動しません。

未署名EXEとDLLのダウンロード元ブロック、Windows 10/11の対話GUI、通知、実Excel閲覧、実機障害・復旧は、対応する実施証跡が揃うまで未検証です。Serverの自動試験成功や、ハッシュ一致をこれらの合格へ置き換えません。
