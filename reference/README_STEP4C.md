# TaskPilot STEP 4.0C — 既存CSV/JSONの検査とSQLiteへのコピー移行

このキットは、既存の保存データを検査し、別の新規SQLiteファイルへコピーする開発・移行確認用です。旧TaskPilotの実行ファイル・ソース・CSV/JSON・設定は書き換えません。アプリの保存先をSQLiteへ切り替える処理もありません。移行後に旧アプリで変更した内容は、作成済みSQLiteへ自動反映されません。

Python・SQLiteコマンド・追加PowerShellモジュールのインストールは不要です。Windows用System.Data.SQLite 1.0.119.0、対応するx86/x64ネイティブDLL、ライセンス表示を同梱します。製品実装の最終形や、販売可能との認証ではありません。

## 対象環境と確認範囲

Windows PowerShell 5.1の `powershell.exe`、.NET Framework 4.6以降、Windowsのx86またはx64プロセスが対象です。Windows 10/11と.NET Framework 4.8での確認を推奨します。PowerShell 7の `pwsh` とWindows ARM64ネイティブプロセスは製品用プロバイダーの対象としていません。

STEP 4.0Cについて、この作業環境で実行できた検証はLinux上のPowerShell 7と明示的な試験用.NET SQLiteアダプターです。これは構文・ランタイム・保存処理の確認で、WindowsネイティブDLLの読み込み検証ではありません。Windows PowerShell 5.1と今回の配布一式を組み合わせたWindows実機検証は、まだ完了していません。Linux試験用アダプターはWindows配布物に含めません。

## ファイルの役割

| ファイル | 役割 |
|---|---|
| `Inspect-TaskPilotLegacyData.ps1` | 検査のみ。省略時は現在のユーザーの `%LOCALAPPDATA%\TaskPilot` を対象にします。 |
| `Import-TaskPilotLegacyData.ps1` | 明示した `-Apply`、入力元、未作成DB、未作成バックアップ先、検査時のSHA-256を用いてコピー移行します。 |
| `Test-TaskPilotStep4C.ps1` | 人工データを使う移行・厳格テキストcodec・同梱STEP4Bの試験を、個別のPowerShellプロセスで実行します。 |
| `Migration-CliSupport.ps1` | レポートを入力元の外に新規作成するためのCLI用ヘルパーです。 |
| `Modules/TaskPilot.Storage/` | STEP4B保存APIとSTEP4C検査・移行処理。`provider/` のDLL配置を維持してください。 |
| `Codec/` | CSV/JSONを厳格に読み、生の数値表記や未知情報を失わず検査する.NET実装です。 |
| `schema/001_initial.sql` | SQLiteスキーマ40001。既存DBへの自動適用・上書きは行いません。 |
| `tests/` | 実データを使わない回帰試験です。 |
| `Modules/TaskPilot.Storage/TaskPilot.Storage.psd1` | モジュールの説明・対象PowerShellバージョン等のmanifestです。 |
| `検証結果.md` | 実行した検証と残る確認範囲を記録します。 |
| `reference/` | 変更していない元アプリの参照用コピーと、来歴・SHA-256の記録です。 |

## 最初に自己テスト

ZIPをすべて展開し、このREADMEがあるフォルダーをWindows PowerShellで開いて実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-TaskPilotStep4C.ps1
```

`-ExecutionPolicy Bypass` はその子プロセスの実行指定です。システム・ユーザーの実行ポリシーを保存変更するコマンドは実行しません。組織の実行方針がある場合は従ってください。

自己テストは一時的な人工データのみを扱います。既存アプリを起動せず、現在のCSV/JSONを移行しません。同梱STEP4B試験の結果ファイルは `DeveloperSandbox` に作成される場合があります。失敗した場合は検査・移行へ進まず、最初のエラーメッセージを確認してください。

## 1. 旧アプリを閉じ、検査する

旧アプリをすべて終了し、入力元を他のエディター等でも変更しない状態で進めてください。検査と移行は旧アプリと同じ `TaskPilot.storage.lock` を、入力元の親ディレクトリーで排他的に開きます。これは入力元の中を書き換える操作ではありません。ロックファイルがなければ親に空ファイルが作成され、処理後も残ります。ファイルの内容を書いたり切り詰めたりはしません。

レポート等の置き場所を、入力元の外に先に用意します。以下の `C:\TaskPilotMigration` は例です。存在しない場合は利用者が新規作成してください。共有・クラウド同期中の場所ではなく、ローカルの空き容量に余裕がある場所から確認することを勧めます。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Inspect-TaskPilotLegacyData.ps1 `
  -ReportPath 'C:\TaskPilotMigration\inspection.json'
```

別のコピーを検査する場合は `-SourceRoot 'C:\Copies\TaskPilot'` を明示します。SourceRootは `Data` ディレクトリーを含む保存フォルダー全体です。`Data` そのものや配布プログラムのフォルダーを指定しないでください。

検査結果の主な項目:

- `CanImport`: エラーがなければtrue。falseなら移行を停止します。
- `Issues`: ファイル、レコード位置、コード、説明。エラー・警告の両方を確認します。
- `RequiresWarningAcknowledgement`: trueの場合、警告内容を確認してから移行時に `-AcknowledgeWarnings` を明示します。
- `ManifestSha256`: 入力元全体のパス・サイズ・SHA-256から作る照合値。次の手順で同じ値を指定します。
- `Counts`: 正規化対象の件数と未解決参照の件数です。元のタスク名やメモ、生バイトは検査サマリーに表示しません。

`-ReportPath` は省略できます。指定時は親フォルダーが既に存在し、レポートファイルが未作成で、SourceRootの外にある必要があります。既存レポートは上書きしません。元のタスク本文・メモ・生バイトをサマリーへ列挙する設計ではありませんが、`Issues` には任意のJSONキー名、旧ID、ファイルパス等が含まれ得ます。匿名化・機密除去が完了したレポートとは扱わず、共有前に内容を確認してください。

各選択ファイルの上限は既定64MiBです。必要な場合だけ `-MaxFileBytes 134217728` などを、検査と移行の両方に同じ値で指定します。ファイルを途中まで読む・切り捨てることはしません。入力元全体のハッシュ照合と完全バックアップには、既存Backup/Export/Logs等も含まれるため、データ量に応じた時間と容量が必要です。

## 2. 確認後、新しい別ファイルへコピー移行する

検査レポートを読み、エラーがないことを確認します。検査から移行までに入力元が変わった場合は、もう一度検査してください。SHA-256不一致を無視する指定はありません。

```powershell
$inspection = Get-Content -LiteralPath 'C:\TaskPilotMigration\inspection.json' -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $inspection.CanImport) { throw '検査エラーを解決してから再検査してください。' }

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Import-TaskPilotLegacyData.ps1 `
  -SourceRoot "$env:LOCALAPPDATA\TaskPilot" `
  -DatabasePath 'C:\TaskPilotMigration\TaskPilot_migrated.db' `
  -BackupRoot 'C:\TaskPilotMigration\LegacyBackup_001' `
  -ExpectedManifestSha256 $inspection.ManifestSha256 `
  -ReportPath 'C:\TaskPilotMigration\migration-result.json' `
  -Apply
```

警告のある検査結果について、その内容を確認し、保管・正規化の扱いを受け入れる場合のみ `-AcknowledgeWarnings` を追加します。エラーをこの指定で回避することはできません。検査が失敗したデータを、このキットが自動修正して元ファイルへ書き戻すこともありません。

適用には4つの値すべてと `-Apply` が必要です。入力元・DB・バックアップの場所は推測しません。DBは未作成の `.db` / `.sqlite` / `.sqlite3` ファイル、バックアップは未作成のディレクトリーを指定し、それぞれの親を先に用意してください。入力元の内側、入力元の親そのもの、DBとバックアップが重なる指定、リンク/ジャンクション経由、既存出力、既存SQLite回復用sidecarは拒否します。

レポートファイルはDBファイル名・バックアップディレクトリー名とは別にしてください。移行に成功した後でレポート保存だけが失敗する場合もあります。その場合はエラーに示されたDBとバックアップを保管し、同じ場所へ繰り返し適用しないでください。

## 何を保管・検証するか

入力元全体の通常ファイルと空ディレクトリーを外部の新規バックアップへコピーし、内容のSHA-256を照合します。既存バックアップ、Excel出力、ログもこの完全コピーに含まれます。コピー失敗時は部分バックアップを削除せず残します。移行処理が元ファイルを削除することはありません。

DBには `Data` 配下の全ファイルとルート `Settings.json` の元のバイト列・ハッシュ等を保管し、既知のデータを正規化します。未知のファイルやフィールドは捨てず元データを保持します。欠損した親を指す関連情報は、架空の通常タスクに結び付けず、未解決レコードとして保持して警告します。

不正なJSON/CSV、重複ID、実在しない日付、型違い、無断の丸めが必要な時間値等は検査エラーです。時間は0.01時間単位の整数へ正確に変換できるものだけを扱います。タスクIDの高水位、完了一覧への所属、日別実績と完了申告実績の区別、確定月の値、監査履歴、通知・休日情報を区別して保持します。

新規DBの移行はトランザクション内で行い、件数・各フィールド・元BLOBの長さ/ハッシュ・外部キー・integrityを検証します。DBは一時ファイルで作業し、検証・入力元の再照合が済んでから新規出力として公開します。エラーで既存DBを上書きすることはありません。

通常の例外では未公開の作業DBを片付けますが、プロセス強制終了・停電では `.taskpilot4c*.db` やSQLiteの `-journal` / `-wal` / `-shm` が残り得ます。最終DBの公開前に中断した場合、その作業ファイルを完成済み移行DBと判断しないでください。回復用ファイルや検証済みバックアップを勝手に削除せず保管し、状況を確認してください。次の試行では、既存出力を上書きするのではなく新しい出力先を指定します。

処理中は協調ロックを保持し、入力元を繰り返し再照合します。このロックを使わない別のソフトによる同時編集を許可する仕組みではありません。処理中に元フォルダーを移動・変更しないでください。停電・端末故障に対する別ドライブ等への保管も、同じディスク上のコピーとは別に必要です。

DBとバックアップは暗号化していません。元データと同じ業務情報・個人情報を含みます。問い合わせのためにフォルダー全体を送る場合も、含まれる内容を先に確認してください。

## ダウンロード由来のDLLブロックが出た場合

Windows/.NETの `0x80131515` は、ダウンロード由来のブロックが原因となる場合があります。配布元を確認し、まず同梱manifestのハッシュと3つのDLLが一致することを確認してください。

```powershell
$providerRoot = Join-Path $PWD 'Modules\TaskPilot.Storage\provider'
$manifest = Get-Content -LiteralPath (Join-Path $providerRoot 'provider-files.sha256.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$relativeFiles = @('System.Data.SQLite.dll', 'x86/SQLite.Interop.dll', 'x64/SQLite.Interop.dll')
foreach ($relative in $relativeFiles) {
  $file = Join-Path $providerRoot $relative
  if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $manifest.PSObject.Properties[$relative].Value) {
    throw "配布DLLの照合に失敗しました: $relative"
  }
}
foreach ($relative in $relativeFiles) { Unblock-File -LiteralPath (Join-Path $providerRoot $relative) }
```

対象は同梱するこの3 DLLだけです。Downloads全体のブロック解除、セキュリティ機能の無効化、GAC登録、レジストリ/PATH変更、`powershell.exe.config` の編集は行いません。新しいWindows PowerShellを開き直して自己テストを再実行してください。ブロック以外のエラーを同じ手順で解決済みと扱わないでください。

## 配布物の範囲

予定ZIP名は `TaskPilot_STEP4_0C_既存データ移行_20261115.zip`。初期検査と人工データの自己テストを済ませた配布キットとして扱い、実データを含めません。元のアプリは変更せず、`reference/` に参照用コピーと来歴・SHA-256を同梱します。その参照用コピーが新しいSQLiteを使って起動するという意味ではありません。詳細な同梱/除外リストは `PACKAGE_CONTENTS_STEP4C.md` を参照してください。外部ストレージへの新しいファイル名での保存は、完成した具体的な配布物と保存先を確認してから行います。
