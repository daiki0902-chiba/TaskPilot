# SQLite設計・GUI統合方針

スキーマ40001を維持する。タスク、予定、子タスク、日別作業、完了申告、カレンダー・曜日・祝日・休業日・日別変更、定期ルール・生成履歴、月次確定の版と監査、通知、移行証跡を独立したSTRICTテーブルで保持する。既存の外部キー、一意制約、索引、削除制限、月次確定の追記制限を利用する。時間は0.01時間単位の整数で格納する。

旧GUIの表示・計算・Excel生成が受け取るオブジェクトの形を維持する互換層を設ける。Read/Save関数を正規化済みSQLiteの読み書きに接続する。CSV/JSONへの二重書き込みや、JSONのみをDBへ移す方式は採用しない。ID・row_versionを保持し、ダイアログを開いた後の古い編集を拒否する。

タスクの本体・予定日・開始日・予定工数は同じトランザクションで保存する。完了申告は日別作業記録と区別する。定期生成はルールと発生日の一意制約を使って重複を防ぐ。月次確定は元の集計値を変更せず、修正時だけ新しい版と理由を追加する。DBの確定後にExcelや画面を更新し、Excel失敗で確定済み業務データを取り消さない。

新しい保存先は `%LOCALAPPDATA%/TaskPilot4/TaskPilot.db`、旧データは `%LOCALAPPDATA%/TaskPilot` のまま残す。初回起動時は検査結果とコピー移行の案内を表示し、承諾後に完全バックアップを作成して新しいDBへ移行する。エラー時は旧データを残し、空の代替DBで隠さない。実行中の旧アプリとは既存ロックで競合を防ぐ。

バックアップはSQLiteが提供する整合したスナップショットを新しいファイルに作り、header/integrity/foreign_key/schemaを検証する。復元はバックアップを新しいDB名へ検証して復元し、既存DBを削除・上書きしない。起動DBの切替は接続を閉じた境界で行う。未知のスキーマを自動で書き換えず、明示的なバージョン移行と事前バックアップを要求する。

Pythonは開発・テスト・実行のいずれにも使用しない。Windows用System.Data.SQLiteとx86/x64ネイティブDLLを同梱し、購入者の追加モジュールインストールを不要にする。Excel出力依存物とEXEビルド依存物は開発時に固定して検証する。

## テーブルと関係

列の完全な定義・CHECK・インデックス・トリガーは `schema/001_initial.sql` が正本である。次の26テーブルを使用する。

| テーブル | 主な識別子・関係と役割 |
| --- | --- |
| schema_migrations | versionを主キーとする適用記録。現在40001のみ |
| tasks | task_id主キー・自動採番、calendar_id外部キー、row_version。アーカイブ所属・完了状態・論理削除を区別 |
| task_plans | task_id主キー兼外部キー。実施予定日・開始日・予定工数 |
| subtasks | subtask_id主キー、parent_task_id外部キー、完了フラグ・表示順 |
| work_logs | entry_id主キー、task_id外部キー。作業日・時間・メモ・表示順 |
| completion_actuals | task_id主キー兼外部キー。完了日・申告時間・当時のタスク名 |
| capacity_calendars | calendar_id主キー、holiday_set_id外部キー。日標準時間と休日稼働方針 |
| calendar_weekdays | calendar_id・weekday複合主キー。0(日)～6(土) |
| company_closures | calendar_id・closure_date複合主キー |
| capacity_overrides | calendar_id・work_date複合主キー。0時間や休日出勤を含む日別上書き |
| holiday_sets | holiday_set_id主キー、取得元・期間・取得時刻・source_file_id外部キー |
| public_holidays | holiday_set_id・holiday_date複合主キー、祝日名 |
| recurring_rules | rule_id主キー、calendar_id外部キー。6種類の規則、順序、有効・削除状態 |
| recurring_occurrences | rule_id・occurrence_date複合主キー、task_id一意外部キー。生成時刻または旧マーカーの証跡 |
| monthly_snapshots | calendar_id・month_key複合主キー。現行revisionへの遅延外部キー |
| monthly_snapshot_revisions | calendar_id・month_key・revision複合主キー。確定数値・理由・確定時刻・取得元。追記専用 |
| monthly_revision_events | 上記版への外部キーと変更前の版。数値確定と同じトランザクションで生成される履歴 |
| legacy_monthly_audit | audit_id主キー、source_file_id・source_ordinal一意。旧Before/Afterと理由・時刻の証跡 |
| app_settings | singleton_id=1。起動時通知・通知日数・日次通知時刻 |
| notification_state | alert_key主キー。確認・スヌーズ状態 |
| notification_history | event_id主キー、task_idはNULL可能外部キー。元のID文字列・名称・現地時刻・判明するUTC時刻を区別 |
| report_state | singleton_id=1。Excelの更新待ち・成功時刻・エラー |
| import_batches | batch_id主キー。採取・確定時刻、元データ全体のmanifestハッシュ、状態 |
| import_source_files | source_file_id主キー、batch_id・relative_path一意。元バイト列・サイズ・SHA256・元の時刻 |
| import_issues | source_file_id外部キー。警告・位置・コード・内容 |
| legacy_unresolved_records | source_file_id・record_locator一意。関連先が不明な記録を原文付きで保持 |

親タスクの削除にCASCADEを使わず、通常の削除はtasksの論理削除で行う。月次確定値・移行原文・生成履歴には更新・削除・置換の制限がある。作業日やタスク別検索、子の順序、通知順序、移行記録の検索にインデックスを設ける。

日付だけの値は `yyyy-MM-dd`、月は `yyyy-MM`、判明する瞬間はUTCのISO表記で保存する。旧ログのタイムゾーンが不明な場合にUTCを作らない。旧GUIへ返す日付の見た目は従来の `yyyy/MM/dd` を維持する。各種時間・稼働率はx100の整数とし、実在しない日付・丸めが必要な数値を拒否する。

## 保存・出力の境界

タスクの追加・編集はGUIの3つの追加経路と共通編集経路から同じ集約保存へ入る。ダイアログで取得した版を使い、後続のレポート読込で古い版が置き換わらないよう、一覧・子一覧の読込トークンも保持する。通知保存の失敗時はDBから状態を読み直す。

Excelは業務データの確定後、3ブックを同じ読み取りスナップショットから生成する。出力失敗でも業務データは維持し、更新待ちを表示する。読み取り終了直後に外部の接続が更新した場合も、data_versionを照合して再出力待ちを維持する。

起動DBの切替指定は `TaskPilot4/active-store.json` に最小限の版と同フォルダー内のファイル名だけを保持する。これは業務データのJSON保存ではない。壊れた指定・未知の版・消失したDB・リンク経由の指定を拒否し、既存データがある状態で空DBを作成しない。移行の検査ログは `TaskPilot4Logs`、完全バックアップは `TaskPilot4LegacyBackups` に分け、中止後の再試行を妨げないようにする。
