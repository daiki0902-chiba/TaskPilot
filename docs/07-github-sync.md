# GitHub反映の準備状況（2026-11-18）

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

## 準備したローカル履歴

候補版の8コミットをmainの上に適用し、mainを祖先とする `publish/sqlite-commercial-20261118` をローカルに作成した。反映先のリモートブランチ名は `development/sqlite-commercial-20261116` である。

READMEのadd/add競合は候補版の説明に統合した。元のmainのREADMEはmainの履歴にそのまま残る。現在のmainにアプリ本体はないため、既存アプリを上書きする競合はなかった。元の候補版とアプリ・保存モジュール・ビルド・テストの内容が同じことを比較した。差分はGitHub状況の文書と、固定ハッシュが改行変換で変わらないための.gitattributesの例外指定である。

公開前の確認では、実ユーザーデータ・DB・Excel実績・資格情報・実行ログ・SDKキャッシュは追跡ファイルに含まれていない。合成テスト、固定したSQLite DLL、必要な第三者表示は含む。Windows実機、TaskPilot.exe生成、実際のExcel生成は未検証のままである。

## レビューと次の工程

再接続によってCLIのアカウント・対象repoへのpush権限が回復し、利用者による停止解除も確認できた。停止解除や公開設定・アクセス権の変更をこの作業が代行した事実はない。

専用ブランチへ通常のpushを行い、ドラフトPRでレビューする。mainへ直接pushしたり、force pushで既存履歴を置き換えたりしない。コード・設計・検証結果をレビューした後、Windows 10/11の実機受入とEXEビルドを進める。GitHubへの反映成功と商用販売の合格は別であり、Windows実機・実際のExcel生成・コード署名・配布経路の条件は未検証のままである。
