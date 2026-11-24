# 独立テストモードの保存境界修正と再試験

Draft PR #1の開発ブランチで作業した。mainと実ユーザーデータは変更していない。Pythonは使用していない。**Windows Serverの自動試験で修正を確認しても、Windows 10/11実機受入が未完了のため一般配布・独立モードの公開停止は維持する。**

## 不合格2件の原因

| 検査 | 確認した原因 | 修正 |
| --- | --- | --- |
| I25：保持中のディレクトリのjunction化 | 削除共有の禁止は、その場でreparse属性を設定する操作を禁止しない。属性変更のDACL拒否だけでもWriteDataハンドル経由の設定を防げなかった。 | 各保護ディレクトリに、起動中は削除・改名・書換えできないガードファイルを保持し、空にならないことを保証。正しいネイティブ要求が空の対照ディレクトリでは成功し、ガード付きではNTFSのERROR_DIR_NOT_EMPTY(145)で失敗することを検査する。junctionだけでなくdirectory symbolic linkタグも対象とする。 |
| I28：保持中のファイルのリンク化 | 元のファイルpinは書き込み共有を許可し、ファイルへの属性変更も禁止していなかった。SQLiteが後からファイル名を開き直す経路も残っていた。 | 属性・EA・所有者権限変更を拒否するファイルACLと、書き込み・削除共有を許可しない保持ハンドルを併用。自分の入出力はそのハンドルを再利用する。SQLiteはメモリーDBに限定し、物理パスを渡さない。 |

加えて、従来のOPEN_REPARSE_POINT付き絶対パスopenは最終要素の保護だけで、親の検査とopenの間に競合が残っていた。ボリュームルートの取得を除き、ファイル・ディレクトリのopenを保持済み親ハンドル相対のNtCreateFileとOBJ_DONT_REPARSEへ集約した。列挙はGetFileInformationByHandleExで行い、GUIもその結果を使う。

比較用の以前の不合格証跡は[初回判定](10-independent-test-mode.md)と `verification/isolated-mode-20261122-*` に残す。失敗結果は上書きしない。

## 保存・復旧の設計

独立モードだけ、同梱System.Data.SQLiteのSerialize/Deserialize APIを利用する。SQLiteへ渡すData Sourceは常に `:memory:`。SQL authorizerでATTACH、DETACH、VACUUM INTO、拡張ロード、ファイル一時領域を有効にするPRAGMAを拒否する。実ファイルの読み書きは検証済みハンドルを使うブローカーだけが行う。Excelも従来のメモリー生成を維持し、PowerShell解析キャッシュは独立モード内で無効化する。

更新は、変更前のメモリーイメージを保持し、SQLのコミットで遅延外部キーを含む制約を検証した後に保存する。ブローカーは元のイメージを新規チェックポイントへ書き出してflushし、同じ検証済みファイルハンドルで新イメージを保存する。書き込み失敗時は元に戻し、戻せなければストアを停止してチェックポイントを残す。未完了チェックポイントがある起動は、自動復元や空DBの作成をせず停止する。

同じ論理DBのwriterは1つに制限する。読み取り専用接続は不変のメモリースナップショットであり、通常版のSQLiteによる接続・競合処理は変更しない。

追加試験で、保存失敗後に既存接続へDeserializeすると、禁止中の内部ATTACHと衝突することも判明した。公式1.0.119ソースのSQLite3.csとsqlite3.cを確認すると、Deserialize内部のATTACH準備と、失敗時のFREEONCLOSE／managed側finallyの解放処理を確認できる。このエラー経路を使わず、**新しい空メモリー接続へ復元してからauthorizerを設定し、writer所有権を引き継いで旧接続を閉じる**。既存接続のauthorizerを一時解除する方法は使わない。

調査した公式ソース：
`https://system.data.sqlite.org/downloads/1.0.119.0/sqlite-netFx-source-1.0.119.0.zip`
SHA-256：`258bd0a766fc9dc678398ca366868354b2bbe22bda90a4bd2fd505489d1a5d83`。
同梱DLLを改変したり、新しい依存ライブラリを追加したりしていない。

## 主な変更箇所

| ファイル | 変更した処理 |
| --- | --- |
| [Runtime/TaskPilot.TestSandbox.cs](../Runtime/TaskPilot.TestSandbox.cs) | OpenRelative、AttachDirectoryGuard、EnumerateHandle/ListDirectory、ファイルACLと保持、AcquireDatabaseWriter、AtomicWrite、ハンドル経由の移動・削除 |
| [TaskPilot.Storage.psm1](../Modules/TaskPilot.Storage/TaskPilot.Storage.psm1) | New-TPMemoryConnection、Save/Restore-TPMemoryConnection、Invoke-TPUnitOfWork、初期スキーマの明示保存 |
| [TaskPilot.Protection.ps1](../Modules/TaskPilot.Storage/TaskPilot.Protection.ps1) | 独立バックアップをメモリーから保存し、復元候補をメモリー上で整合性検査。通常版の経路は維持 |
| [GuiStartup](../Adapters/TaskPilot.GuiStartup.ps1)、[GuiIsolation](../Adapters/TaskPilot.GuiIsolation.ps1) | 独立モードの初期状態検査・DB一覧・選択画面をブローカーの列挙／存在検査へ変更 |
| [TaskPilot.Runtime.ps1](../Runtime/TaskPilot.Runtime.ps1) | 独立モードの解析キャッシュ無効化。公開停止を維持 |
| [Test-IsolatedTestMode.ps1](../tests/Test-IsolatedTestMode.ps1)、[Test-IsolatedFileBoundary.ps1](../tests/Test-IsolatedFileBoundary.ps1) | 27ケースを維持。実際のreparse設定要求・正例・ガード変更拒否を強化 |
| [Test-IsolatedMemoryStore.ps1](../tests/Test-IsolatedMemoryStore.ps1) | メモリーDB・永続CRUD・単一writer・読み取り専用・SQLパス拒否・遅延FK・保存失敗復旧・復元・中断状態の8ケース |
| [Test-SandboxHandleSmoke.ps1](../tests/Test-SandboxHandleSmoke.ps1) | ハンドル経由の作成・読出し・更新・移動・削除など8検証 |
| [Windows検証](../tools/Invoke-TaskPilotWindowsVerification.ps1)、[workflow](../.github/workflows/windows-verify.yml) | 全検査と配布許可を分離。停止中は報告だけをArtifactsへ保存し、EXE・受入ZIPを公開しない。Smokeは別プロセスにして、本試験は配布予定DLLそのものを検証 |

## 試験結果

[最終CI #45000222885](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/45000222885) は成功。対象ソースは `16711174fc285b3adcb872a5d5fd4bae1f087c73`。Windows Server 2022 / Windows PowerShell Desktop 5.1 x64で実行し、Windows 10/11の成功へ読み替えない。

| 試験 | 結果 |
| --- | --- |
| 旧保存処理の回帰 | PASS |
| 通常版 | 8群成功・0群失敗 |
| 独立モード | 27ケース・146検証成功、失敗0。I25/I28を含む |
| メモリー保存・復旧 | 8ケース・47検証成功、失敗0 |
| 安全停止 | 12検証成功 |
| ハンドル入出力 | 8検証成功 |
| リンク境界の追加検査 | 80ネイティブ試行、ガード変更拒否40項目成功。独立ケースI28内の検査 |
| 合成通常領域 | 全ハッシュ・構成が前後一致 |
| Windows 10/11実機GUI | **未検証** |
| EXE・受入ZIP公開 | **実施しない。報告Artifactだけを保存** |

[CI・証跡・SHA-256一覧](verification/isolation-fix-20261122-ci.json)から生の結果と前後比較へ辿れる。通常8群のprovider専用トランザクション内改変フックはnativeではSKIPし、その記録を残した。Linuxの明示的テストproviderによる通常8群では成功したが、全ケースをWindowsで実施したとは扱わない。改訂キットの生成・補助ツール一連試験は公開停止のため未実施。

## 通常版への影響

保存・読込・編集・削除・予定・子・実績の更新、CSV/JSON移行、バックアップ／復元は通常8群で再確認する。原本・raw BLOB・関連・全テーブルの照合、失敗時ロールバック、古い画面からの更新拒否、元DBやsidecar非上書き、WALを含む整合したバックアップを含む。GUI統合の413検証ではメニュー・ボタン・表示・既存計算を比較する。実業務データを使った検証は行わない。

独立試験では合成した通常版のDB・旧CSV/JSON・設定・バックアップ・空ディレクトリ・ロックを用意し、別プロセスが通常DBとロックを保持した状態で試験する。その前後の全ファイルSHA-256と構成を比較し、通常データを取り込まないことと通常領域を変更しないことを検査する。

## 残るリスクと配布判定

**一般ユーザー向け配布の再開は不可。** 本体のTestMode、起動前検査、独立ログ採取は公開入口で停止する。BuildInfoのSupported=false／ReleaseBlocked=trueも維持する。

- Windows 10/11のEXE起動、引数伝達、全WinForms画面、日本語IME・DPI・カレンダー、ポップアップ通知、通常版との実GUI同時起動は未検証。
- Excel3冊・グラフXMLはServerで検査するが、実Excelでの閲覧と表示品質は未検証。
- M06はブローカー呼び出し前の明示的な失敗注入である。実ディスク容量不足・部分書き込み・強制終了・電源断を再現した成功とは扱わない。M08は中断状態を合成して停止・保存を検査する。
- 独立モードはDB全体をメモリーへ読み込み、更新時に全体を保存する。上限256 MiB、メモリー消費・大規模データの性能評価は未完了。通常版の保存方式は維持する。
- 旧実験版の弱いACLやv1マーカーのテスト領域は、変更して自動採用せず停止する。新形式への移行は提供していない。旧通常版のデータも自動移行しない。
- チェックポイントの正式な案内・復旧ツールは未実装で、現状は停止と元イメージの保持まで。
- 未署名EXE/DLL、MOTW、署名した配布経路、改訂した受入ZIP生成・補助ツールのWindows一連試験は未完了。OSの保護を解除する手順は追加しない。
- 通常権限のWindows操作と未改変アプリを前提とする。管理者が権限を有効化して行う強制変更、カーネル、デバッガー、改変したアプリを隔離するOSサンドボックスとは扱わない。

Windows実機では、まず実業務データを使わず合成環境で同じ境界・復旧試験を行い、標準権限、再起動後の状態、通知・自動処理、Excel閲覧、実GUI同時起動を確認する。公開ゲートを無断解除して普段の業務ユーザーでアプリを起動しない。

## 現在の確認コマンド

リポジトリ直下のWindows PowerShell 5.1で、アプリを起動せず公開停止を確認する。

```powershell
New-Item -ItemType Directory -Path .\TestResults -Force | Out-Null
.\tests\Test-IsolatedReleaseGate.ps1 -OutputRoot "$PWD\TestResults"
```

起動許可やOS保護の解除を行うコマンドではない。独立モードを使う本体の起動コマンドは現在案内しない。
