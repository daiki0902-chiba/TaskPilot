# TaskPilot 製品版: SQLiteバックアップ・復元・スキーマ更新の実装案

作成日: 2026-11-16。対象は `work/step4c` の保存モジュールと schema 40001。
この調査では既存コード・既存データを変更していない。Pythonは使用していない。

## 現在の実装と制約

- `TaskPilot.Storage.psm1` は application_id `1414547788`、user_version `40001` を接続前のファイルヘッダーと接続後のPRAGMAで検査する。通常のOpenでは別アプリ・旧版・将来版を拒否し、自動更新しない。
- 接続はPooling無効、foreign_keys/recursive_triggers有効、synchronous FULL。新規作成と旧データ取り込みは一時DBを検証後、同一ボリューム内のMoveで新規パスへ公開する。
- CSV/JSON移行は元ファイルを変更せず、完全バックアップと原文BLOBを保持する。SQLite版UIへの切替は未実装。
- 月次確定値と修正イベント、旧月次監査、取り込み原文には更新・削除・置換を防ぐトリガーがある。月次修正は新revisionの追加によって行う。バックアップ・復元・更新でもこの履歴を保持する。
- `Get-TPResolvedPath` は `%LOCALAPPDATA%\TaskPilot` 以下のDBを拒否する。これは旧アプリの保存先保護として有効なので、製品版の配置のためだけに解除しない。
- 現在のスキーマ更新履歴はversion・時刻・descriptionのみで、移行SQLのチェックサム列はない。

## 推奨する保存先とアプリ起動

製品版は旧アプリと分離した `%LOCALAPPDATA%\TaskPilot4` を標準保存先にする。製品の表示バージョンごとに保存先を変えない。Program FilesやZIP展開先にユーザーデータを置かず、通常ユーザー権限で動作させる。

```text
TaskPilot4/
  app.storage.lock
  active-store.json
  databases/taskpilot_<identity>.db
  backups/TaskPilotBackup_<UTC>_<identity>.zip
  logs/
```

`active-store.json` は設定形式版と、databases以下の単一ファイル名だけを保持する。絶対パス・相対パスの上位移動・任意URLを許可しない。既存ファイルの更新は同じディレクトリーに新規作成した一時ファイルをFlush(true)し、File.Replaceで行い、前のポインターを残す。初回だけMoveで作成する。

起動から終了まで製品用の排他ロックを保持し、同じDBを旧UI・別プロセス・別バックグラウンド処理が勝手に開かない構造にする。旧データ移行時は旧アプリと共通の親ディレクトリーの `TaskPilot.storage.lock` も取得する。製品用と旧版用のロックを混同しない。

起動時はポインターとDBヘッダーを検査してから通常のOpenへ進む。保存先が見つからない・DBが壊れている場合に、空DBを自動作成して元のタスクが消えたように見せない。新規利用・移行・復元のいずれかを明示的に実行する。

## バックアップ方式

開いているDBの本体だけをCopy-Itemする方法は採用しない。WALに確定済みデータが残る場合や、コピー中に更新される場合に不完全になる。

### 共通の確定手順

1. UIで保存中の処理を完了させ、製品側の書き込みを短時間停止する。既存の書き込みトランザクション中には開始しない。
2. 新規の一時ディレクトリーと一時DBファイル名を予約する。既存バックアップ・復元元・稼働DBと同じパスを拒否する。
3. SQLite自身のスナップショット機能で一時DBへ複製する。失敗や取消時のファイルを成功品として公開しない。
4. 複製先の接続を閉じ、FileStream.Flush(true)でファイルをフラッシュする。新しい読取専用接続でヘッダー、application_id、user_version、integrity_check、foreign_key_check、必要なテーブル・トリガーを検査する。
5. 複製先の月次確定・修正履歴・原文BLOB・sqlite_sequenceを含む内容を検証し、DBのSHA256、サイズ、作成UTC、製品版、スキーマ版、application_idをmanifestへ記録する。レコード件数・論理ダイジェストは複製先から生成する。
6. 固定名 `TaskPilot.db` と `manifest.json` だけをZIPへ格納し、閉じたZIPを再検証してから新規ファイル名へ原子的にMoveする。元データ・既存バックアップを上書きしない。

manifestのSHA256は破損検出用であり、第三者による改変を防ぐ電子署名ではない。DBにはタスク・備考などの実データが含まれる。ログや検査レポートに原文を無条件で出力しない。

### 方式A: System.Data.SQLiteのOnline Backup API

バンドル済みの `System.Data.SQLite.xml` に、次の公開メソッドがあることを確認した。

```text
sourceConnection.BackupDatabase(
    destinationConnection, "main", "main", pages,
    SQLiteBackupCallback, retryMilliseconds)
```

`pages` は1回にコピーするページ数。負数は全ページ一括。callbackがfalseを返す、または例外を投げると取消となり、コピー途中の変更はロールバックされる。retryMillisecondsはロック発生時の待機時間であり、総実行時間の上限ではない。

製品では例としてpages=128、retry=50msとし、コールバックに経過時間・取消フラグを持たせる。PowerShellのUIスレッドを長時間塞がず、C#5互換の小さな管理コードヘルパーで取消と進捗を受け持つ方法が実装しやすい。別スレッドからPowerShell scriptblockを直接呼び出す構造は避ける。接続はバックアップ処理自身が所有し、UIの接続をスレッド間で共有しない。

複製先は新規の空DBにする。スキーマを先に作ったDBへコピーすると、取消後に空のTaskPilot DBが残り、簡単なヘッダー検査だけでは成功と誤認し得る。コールバックfalseでAPIが正常復帰する可能性も含め、取消フラグ・完了状態・複製先検証のすべてを確認する。

**検証上の制約:** 現在のLinuxテスト用Mono.Data.Sqlite.SqliteConnectionには、reflectionで確認した限りBackupDatabaseメソッドがない。Linuxの既存テストだけでは、この製品用APIの成功・取消・ロック待ち動作を実行検証できない。Windows PowerShell 5.1と同梱DLLを使ったネイティブ試験が必要。

### 方式B: SQLiteのVACUUM INTOを共通実装にする

SQLite 3.27以降は `VACUUM main INTO @destination` を利用できる。現行アプリは3.38以上を要求しているため、必要なSQLiteの版は満たす。出力先はSQLパラメーターとして渡し、文字列をSQLへ連結しない。既存の非空ファイルへ上書きする動作に依存せず、一時出力名を常に新規にする。

これもSQLiteが一貫したスナップショットを作るため、DB本体の単純コピーとは異なる。アクティブなトランザクション内では実行できない。製品の書き込みを止めた専用接続で実行し、元接続の状態を変えない。VACUUM INTOの生成ファイルはSQLiteの処理だけで電源断耐久まで保証されたと扱わず、閉じてから明示的なFlush(true)を行う。

同じSQL経路を現在のLinuxアダプターでも試験できる利点がある。この調査では合成DBを作り、現在のMonoアダプターの読取専用接続からパラメーター付きVACUUM INTOが成功し、複製後のTaskPilotヘッダー・スキーマ・外部キー検査とタスク1件の読み出しが通ることを確認した。同梱Windows DLLで同じ条件が成功するかは別途検証する。取消・進捗が必要ならSystem.Data.SQLiteの適切な中断APIを別途検証し、未検証のクロススレッド接続操作で代用しない。

初期製品で方式を1つに絞るなら、Linux・Windowsで共通に実行できる方式Bが実装と試験をそろえやすい。方式Aを採用する場合は、Windows試験を出荷条件にする。

## 復元は新しいDBを検証してから切り替える

標準の復元処理は稼働中DBへの上書きを行わず、新しいidentityのDBへ復元してポインターを切り替える。

1. ZIPから固定の2エントリーだけを読み取る。重複名、余分なエントリー、`../`・絶対パスなどを拒否する。ExtractToDirectoryで任意のエントリーを展開しない。圧縮前サイズの上限と、実際に読み出したバイト数の上限を検査する。
2. DBを新規ステージへ書き出し、manifestのサイズ・SHA256・形式版、DBヘッダー、対応スキーマ、整合性・外部キー・必要な構造を検査する。検査中に復元元を変更しない。
3. 現行DBの検証済みバックアップを必ず作る。既に破損して整合性バックアップを作れない場合は、自動上書きに進まず、現在のファイル・sidecarを残して別DBへの復旧として扱う。
4. 保存・通知・集計・Excel生成など、DBを使用する全処理を停止し、UIの未確定編集の扱いを確認する。新DBへ切り替わった後に古いStoreを使用するクロージャーやジョブを残さない。
5. 新DBを最終の新規パスへMoveし、開けることを確認する。active-store.jsonを原子的に更新し、UIのStore参照を切り替える。エラー時は元ポインターを維持し、旧DBを再度開く。
6. 旧DB・事前バックアップ・旧ポインターは残す。成功後の即時削除・自動世代整理は別機能として扱う。

ポインター更新前に落ちた場合は旧DBが有効で、更新後に落ちた場合は検証済み新DBが次回起動対象になる。DB本体とWAL/SHMを別々に入れ替える必要がなくなる。新DBは閉じてから公開する。

どうしても固定名のDBを置換する場合は、全接続の閉鎖・書き込み停止・SQLiteによるチェックポイントを行い、所有していないjournal/WAL/SHMを削除しないことが必要。一連のファイルをFile.Replaceだけでまとめて原子的に置換できるとは扱わない。初回実装ではポインター方式を推奨する。

## スキーマ更新

通常のOpenは現在どおり厳密な版一致を維持する。更新専用の入口だけが、同じapplication_idかつ既知の旧スキーマ版を許可する。将来版・別アプリ・不明版は更新しない。

1. パッケージに固定した更新カタログを用意する。FromVersion、ToVersion、SQLファイル、SHA256、対応アプリ版を持たせる。更新SQLは入力データから生成・実行しない。
2. 製品の排他ロック下で元DBを検査し、検証済みバックアップと新候補DBを作る。元DBは更新しない。
3. 候補DBだけで、40001から最新まで必要な更新を順番に適用する。各SQLにBEGIN/COMMITを埋めず、コーディネーターがDDL・データ変換・履歴追加・user_version変更を同じトランザクションで管理する。失敗すれば候補を破棄して旧DBを維持する。
4. 既存schema_migrationsの内容とDB構造を照合する。新しい版でSQLチェックサム履歴を追加するなら、新テーブルなどで明示的に設計する。過去のchecksumが記録されていたことにしない。
5. 月次revision・イベント・旧監査・原文BLOBの全フィールド、task_id・子要素ID・soft delete・未解決記録・sqlite_sequenceを、更新前後の論理ダイジェストで比較する。工数は整数の1/100時間のまま扱い、doubleへ変換しない。
6. 変更対象外の履歴を再計算・上書きしない。レポート再生成の必要があればreport_stateだけをdirtyにする。月次確定はdirty状態とは独立に保持する。
7. integrity_check、foreign_key_check、移行後の構造と履歴を確認後、復元と同じポインター切替で有効化する。

テーブル再構成が不要ならALTER TABLEや新テーブル追加を優先する。再構成が必要な場合は候補DB内の1トランザクションに限り、対象が明確な自前トリガーの再作成を含めて設計する。制約や不変履歴のトリガーを全体的に無効化しない。

古いアプリは新スキーマを開かない。旧DBを残すことで切替前の状態へ戻せるが、更新後の新DBへ追加したタスクまで旧版へ自動反映されるわけではない。この限界をロールバック手順に明記する。旧CSV/JSON版は引き続きその保存先を保持する。

## 公開API案

```powershell
New-TaskPilotBackup -DatabasePath <existing-db> -BackupPath <new-zip>
Test-TaskPilotBackup -BackupPath <zip>
Restore-TaskPilotBackup -BackupPath <zip> -DataRoot <product-root> -Apply
Get-TaskPilotSchemaUpdatePlan -DatabasePath <db> -TargetVersion <version>
Update-TaskPilotDatabase -DatabasePath <db> -DataRoot <product-root> -TargetVersion <version> -Apply
```

バックアップ作成は新規ファイルのみ。Testと更新計画は元DB・バックアップ・有効ポインターを変更しない。Applyのない復元・更新は実行しない。Restore/Updateの戻り値には旧DB、新DB、事前バックアップ、旧ポインター、検証結果、実際の切替有無を含め、エラー後の復旧先を追えるようにする。テスト用プロバイダーは現行と同様に明示的引数に限る。

## 必須の受入試験

| 対象 | 試験と合格条件 |
|---|---|
| SQLite複製 | DELETE journalとWALの両方で、WAL内の確定データを含む。未確定トランザクションの内容は含まない。 |
| 同時更新 | バックアップが一貫した状態になる。製品内の書き込み停止が効き、外部ロック時は明確に失敗または期限付き待機となる。 |
| 取消・容量不足 | 取消、ディスク書き込み失敗、ZIP作成失敗で成功ファイル・有効ポインターを公開しない。稼働DBの内容を変えない。 |
| 無断上書き防止 | 既存バックアップ、既存DB、既存sidecar、復元元と出力先の同一指定を拒否し、元のハッシュを維持する。 |
| 復元内容 | Unicode、引用符、改行、0.01時間、NULL、全タスクID、次ID、archive/soft delete、子要素、未解決記録、原文BLOB、月次revision5以上と全イベントが一致する。 |
| 不変履歴 | 復元・更新後も月次確定・旧監査・取り込み原文へのUPDATE/DELETE/REPLACEが拒否される。 |
| 不正バックアップ | 改変DB、サイズ不一致、壊れたZIP、重複エントリー、パス逸脱、過大展開、別アプリ、未対応将来版を稼働DBへ適用しない。 |
| 復元失敗 | 検証・新DB公開・ポインター更新・接続再開の各段階で故障注入し、旧DBまたは検証済み新DBのどちらが有効かが常に一意になる。 |
| スキーマ更新 | 実在する旧版fixtureを更新し、途中SQL失敗・停止で元DBと有効ポインターを維持する。連続更新と再実行の扱いを確認する。 |
| 互換性 | Windows PowerShell5.1、同梱System.Data.SQLite、x64/x86を対象とする。方式AはLinuxのMono試験で代替しない。 |

## この調査で確認した証拠と未確認事項

- Online Backupの公開シグネチャ・取消仕様: `work/step4c/Modules/TaskPilot.Storage/provider/System.Data.SQLite.xml` のBackupDatabaseとSQLiteBackupCallback説明。
- 既存保護・接続・版検査: `work/step4c/Modules/TaskPilot.Storage/TaskPilot.Storage.psm1`。
- 月次不変制約・履歴・version40001: `work/step4c/schema/001_initial.sql`。
- LinuxアダプターのBackupDatabase非搭載: 実際のMono.Data.Sqlite.SqliteConnectionの公開メソッドをPowerShell reflectionで確認。
- VACUUM INTOの最小実行試験: PowerShell/.NETのみで一時的な合成DBを作成し、読取専用のMono接続からパラメーター付き出力、複製DBの通常Open検証、タスク1件の保持を確認。試験ファイルは終了時に削除した。WAL・同時更新・取消・電源断を網羅した試験ではない。
- この文書は設計案であり、上記の新規バックアップ・復元・更新APIは実装済みとして扱わない。WindowsでのOnline Backup/取消/WAL試験はこの調査では実行していない。
- GitHubリポジトリーの閲覧・作成・push・CI実行はこの調査では行っていない。ローカル調査結果をGitHub連携済み・CI検証済みの根拠にはできない。
