# GitHub反映の準備状況（2026-11-18）

公開設定の変更後、リポジトリの読み取りは成功した。以下は実際の取得結果と作業内容であり、push完了を表すものではない。

| 項目 | 確認結果 |
| --- | --- |
| 対象 | daiki0902-chiba/TaskPilot、public |
| main | a761e76fbe4c4335a1847dbfc4417516d205316f |
| mainの全ファイル | README.md、.gitattributes |
| 既存アプリ・テスト・CI | mainには未登録 |
| GitHub連携の書き込み | APIブランチ作成・CLI push dry-runが403 |
| 実行環境のCLI認証 | 再接続後はdaiki0902-chiba、対象repoのpush権限true |
| アプリの対象・許可 | TaskPilotが選択済み、contents/writeとpull_requests/writeを確認 |
| アプリの稼働状態 | GitHub側のinstallation情報が一時停止中（suspended_atが設定済み） |
| リモートへの変更 | なし。main・公開設定・アクセス権を変更していない |

## 準備したローカル履歴

候補版の8コミットをmainの上に適用し、mainを祖先とする `publish/sqlite-commercial-20261118` をローカルに作成した。反映先として試みたリモートブランチ名は `development/sqlite-commercial-20261116` である。

READMEのadd/add競合は候補版の説明に統合した。元のmainのREADMEはmainの履歴にそのまま残る。現在のmainにアプリ本体はないため、既存アプリを上書きする競合はなかった。元の候補版とアプリ・保存モジュール・ビルド・テストの内容が同じことを比較した。差分はGitHub状況の文書と、固定ハッシュが改行変換で変わらないための.gitattributesの例外指定である。

公開前の確認では、実ユーザーデータ・DB・Excel実績・資格情報・実行ログ・SDKキャッシュは追跡ファイルに含まれていない。合成テスト、固定したSQLite DLL、必要な第三者表示は含む。Windows実機、TaskPilot.exe生成、実際のExcel生成は未検証のままである。

## 続行するために必要なこと

再接続によってCLIのアカウント・対象repoへのpush権限は回復した。アプリの選択対象にもTaskPilotがあり、contents/writeの許可もある。しかし、連携アプリがGitHub側で一時停止されているため、書き込みは拒否されている。GitHubのインストール済みアプリ設定で一時停止を解除した後、実際のブランチ作成・pushで再確認する必要がある。停止解除やアクセス権の変更をこの作業が代行した事実はない。

認証が整った後、mainの先端が上記から変わっていないか、対象開発ブランチが他の作業で作られていないかを読み直す。確認後に専用ブランチへ通常のpushを行い、必要に応じてドラフトPRでレビューする。mainへ直接pushしたり、force pushで既存履歴を置き換えたりしない。
