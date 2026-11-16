# 現状分析・実装範囲（2026-11-16、初回調査）

対象リポジトリとして接続一覧に `daiki0902-chiba/TaskPilot`（private、default branch main）が表示された。ただしリポジトリ詳細・contents・branchesはGitHub連携とCLIの双方で404だった。リポジトリのコミット、最新版、mainの内容、既存CI、実データは未確認。表示されたsize=0だけを根拠に空リポジトリとは断定しない。

このため、今回のローカル作業は以前の会話で確認済みのSTEP3本体とSTEP4C配布物を基準にする。GitHub版との同一性は未確認。GitHubのmainや他ブランチには書き込まない。ローカルの専用ブランチ `development/sqlite-commercial-20261116` に基準点を保存した。リモートの内容が読めるようになった後、差分の照合が必要である。

基準アプリ `reference/TaskPilot_STEP3_6F_4.ps1` のSHA256は `ab0c5e2dbc31128563298d70adf51c59d3e081643899575aaba1d0183d47188d`。PowerShell 5.1/Windows Forms、約3,200行の単体GUI。タスクは2つのCSV、ID予約はNextId.txt、メタデータはJSONに分散する。複数ファイルにまたがる追加・編集・定期生成・月次確定・通知の保存に一括ロールバックがない。

STEP4CにはSQLiteスキーマ40001（26テーブル）、.NET経由の保存API、厳密なCSV/JSON検査、新規DBへの移行、完全バックアップ・照合、合成データのテストがある。既存GUIとはまだ結合されていない。以前の実行結果はLinuxの明示的テストアダプターで6スイート成功、WindowsのSTEP4Cは未検証である。

既存ビルドは古いGUIファイルをEXE化し、ImportExcelだけを配布に含める構成で、SQLite用依存物の同梱に対応しない。ps2exe/ImportExcel/EPPlusの実体とEXEは現時点の手元にない。ビルド時のバージョン固定、配布内容の照合、ライセンスの実体確認、Windows実機試験が必要である。

安全に進める範囲は、保存APIを使うGUI互換層、SQLiteバックアップと新しい場所への復元、安全な起動・移行導線、既存GUIの保存呼び出しの統合、合成データの自動テスト、ビルド・配布構成と実機受入条件の整備とする。実データや既存配布物は変更しない。Windows 10/11のGUI、通知、Excel、EXE、コード署名は本環境では成功と報告しない。
