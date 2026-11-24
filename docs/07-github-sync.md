# GitHub反映結果（2026-11-18）

公開設定の変更後、リポジトリの読み取りは成功した。続く403は、連携アプリの一時停止を利用者が解除した後に解消した。以下は実際の取得結果と反映方針である。

| 項目 | 確認結果 |
| --- | --- |
| 対象 | daiki0902-chiba/TaskPilot、public |
| main | a761e76fbe4c4335a1847dbfc4417516d205316f |
| mainの全ファイル | README.md、.gitattributes |
| 既存アプリ・テスト・CI | mainには未登録 |
| GitHub連携の書き込み | 停止解除後、APIで開発ブランチ作成が成功 |
| 実行環境のCLI認証 | 再接続後はdaiki0902-chiba、対象repoのpush権限true |
| アプリの対象・許可 | TaskPilotが選択済み、contents/writeとpull_requests/writeを確認 |
| アプリの稼働状態 | 停止解除済み。API上のsuspended_atはnull |
| 反映先 | development/sqlite-commercial-20261116。mainへ直接反映しない |
| 最初のソース反映 | 8abcc9e6367c54a9ea36e5983b805c0ec6cbbcfbへ通常のpushが成功 |
| ドラフトPR | [#1 SQLite保存・安全なデータ移行を既存WinFormsへ統合](https://github.com/daiki0902-chiba/TaskPilot/pull/1)、未マージ |
| ソース反映後の照合 | GitHubから新規cloneし、80/80ファイルのSHA256一致、44 PowerShellファイルのBOM・構文を確認 |

反映後照合の対象コミットは上記8abcc9eである。詳細は [github-readback.json](verification/github-readback.json) に記録した。この記録追加以降の文書コミットと、当該コミットで実施した照合は区別する。実行コードは前回自動テストを通した候補版から変更していない。

## 準備したローカル履歴

候補版の8コミットをmainの上に適用し、mainを祖先とする `publish/sqlite-commercial-20261118` をローカルに作成した。反映先のリモートブランチ名は `development/sqlite-commercial-20261116` である。

READMEのadd/add競合は候補版の説明に統合した。元のmainのREADMEはmainの履歴にそのまま残る。現在のmainにアプリ本体はないため、既存アプリを上書きする競合はなかった。元の候補版とアプリ・保存モジュール・ビルド・テストの内容が同じことを比較した。差分はGitHub状況の文書と、固定ハッシュが改行変換で変わらないための.gitattributesの例外指定である。

公開前の確認では、実ユーザーデータ・DB・Excel実績・資格情報・実行ログ・SDKキャッシュは追跡ファイルに含まれていない。合成テスト、固定したSQLite DLL、必要な第三者表示は含む。Windows実機、TaskPilot.exe生成、実際のExcel生成は未検証のままである。

## レビューと次の工程

再接続によってCLIのアカウント・対象repoへのpush権限が回復し、利用者による停止解除も確認できた。停止解除や公開設定・アクセス権の変更をこの作業が代行した事実はない。

専用ブランチへ通常のpushを行い、ドラフトPRでレビューする。mainへ直接pushしたり、force pushで既存履歴を置き換えたりしない。コード・設計・検証結果をレビューした後、Windows 10/11の実機受入とEXEビルドを進める。GitHubへの反映成功と商用販売の合格は別であり、Windows実機・実際のExcel生成・コード署名・配布経路の条件は未検証のままである。

## 2026-11-19の追加検証

新たに提供された `Test-Storage.ps1` を原本のまま `reference/` に保存し、旧本体の保存処理に対する回帰試験として追加した。既存アプリ本体・旧ビルド3ファイルは既に保存した参照版とバイト一致した。

Windows Server 2022 / Windows PowerShell 5.1のCIを専用開発ブランチに追加した。初回のテスト用リンク削除の失敗を修正したコミット `9c7ad91674f7c47784b51305c080405f7c534d80` で、[実行 #44640521434](https://github.com/daiki0902-chiba/TaskPilot/actions/runs/44640521434)が成功した。旧保存処理の回帰、native SQLiteの8テスト群、未署名の0.4.0.1 EXE/候補ZIP生成を確認した。結果は[検証記録](verification/README.md)に保存した。

この追加差分は提供テスト・テスト片付け・CI・文書であり、前回候補のアプリ保存処理を変更していない。mainは引き続き `a761e76fbe4c4335a1847dbfc4417516d205316f` で、PRはドラフト・未マージのままである。Windows 10/11の実機操作、生成EXEの起動、実Excel出力、署名・ダウンロード後の配布経路は未検証である。
