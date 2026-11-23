# 通常版のローカル実機検証と起動ホスト

2026-11-23調査。通常版だけを製品として開発する。追加の専用EXE・専用保存モードは作らない。一般公開停止と既存モードの起動拒否は維持する。

## 通常EXEと正式受入EXEの違い

| 対象 | 確認した実装 | 判定できる範囲 |
| --- | --- | --- |
| 通常版 | `tools/Build-TaskPilot.ps1:121-126`が固定ps2exe 1.0.17で`TaskPilot.ps1`をx64/STA/WinExeへ変換 | ビルドは既存の署名証明書を必須にしていない。未署名でも安全に実行可能という証明ではない |
| 固定ps2exe | `ps2exe.ps1:2548`で独自PSHostを渡してRunspaceを作成、`:2644-2661`で埋込リソースを読み`AddScript(script)` | 外部mainを`AddCommand(path)`する正式受入ホストとは入口が異なる |
| 正式受入版 | `acceptance/TaskPilot.Acceptance.Launcher.cs:49,103`の標準Runspaceと外部スクリプト実行 | 既存のこのホストの試験結果を、そのまま通常EXEの結果に転用しない |

調査対象は`build/dependencies.lock.json`の固定ps2exeアーカイブ（SHA256 `d50b02f136d277a617aef270ed1ecaa6505e3d899ef3cd19cdc2c456dd1cf17b`）。展開済み`ps2exe/1.0.17/ps2exe.ps1`を確認した。実行ポリシー、認証マネージャーを変更する処理は確認していない。

ただし、通常版も外部スクリプトを必要とする。`TaskPilot.ps1:19`がRuntimeを、`:125-130`がGUIアダプターを読み込む。`Adapters/TaskPilot.GuiStartup.ps1:170`がStorageモジュールを、`GuiOperations.ps1:30`がImportExcelを読み込む。Storage自身も複数の`.ps1`を読み込む。

したがって「mainがEXE内にあるので、すべてのPowerShellファイルの許可検査が不要」とは判断しない。固定ps2exeで生成した無害な小型プログラムと外部の合成スクリプト・モジュールを使う実測が必要。実TaskPilotを起動して試す前に行い、GUIも実データも開かない。

| 対象環境の有効ポリシー | ローカル検証の扱い |
| --- | --- |
| `Restricted` | 外部スクリプトの起動を前提に許可しない。NOT_READY。有効な署名の購入だけでは解消しない |
| `AllSigned` | 配布元の未署名モジュールを含め、実際の署名・発行元確認が成立するまでNOT_READY |
| `RemoteSigned` / `Unrestricted` | 既にこの設定で管理される開発環境に限り、取得元・依存ファイル・無害なホスト試験を確認する。設定値だけで起動許可しない |
| `Bypass` / 不明 | 今回の安全条件を満たす検証環境として採用しない |

Windows 10/11の既定設定、WDAC/AppLocker/SmartScreen/Defender、取得元によるDLLロードは未検証。Serverの成功をクライアントOSの成功とは報告しない。正式受入ホストの既存観測はServerの`Unrestricted`であり、通常EXEの全ポリシー動作を証明しない。

実行ポリシー変更、認証マネージャー置換、ファイル取得元情報の削除、証明書ストアへの登録、外部スクリプトを文字列化して検査を避ける実装は解決策にしない。自己署名を作成しても、信頼設定を変えずに発行元の信頼問題が解消するとは扱わない。

## 保存先と最小の実機環境

通常版は`Runtime/TaskPilot.Runtime.ps1:49,83-88`でWindowsのKnownFolderを取得する。保存先はそのユーザーの`%LOCALAPPDATA%\TaskPilot4`、ログは`TaskPilot4Logs`、移行バックアップは`TaskPilot4LegacyBackups`。旧データ候補`TaskPilot`と旧版・新版のロックにもアクセスする。任意のテスト保存先引数は提供していない。

`$env:LOCALAPPDATA`だけを書き換えたり、EXEを別フォルダーにコピーしたりしても保存先の分離は保証できない。通常版は専用sandboxではなく、そのWindowsユーザーがアクセスできるファイルを選択して復元・出力できる。

優先する環境は、開発者管理のクリーンなWindows 10/11仮想マシン。旧TaskPilotデータ・実業務データを持ち込まず、ホストのフォルダー共有・追加ディスク・ファイル転送連携を接続しない。依存ファイルを含むソースと検証用ファイルだけを用意し、ネットワーク切断後に架空データで試す。Windowsの保護設定は維持する。

専用の標準Windowsユーザーも候補だが、他ユーザー領域・共有・追加ディスクへの既存ACLを含む環境確認が必要。他ユーザーのデータへのアクセスをアプリが全面禁止する設計ではないため、同じPCでアカウントを切り替えるだけで完全分離したとは扱わない。クリーンVMを優先する。

旧`tools/Test-TaskPilotAcceptancePackage.ps1:273`のFirstUse検査は、実KnownFolder配下の6つの既知のデータ・ログ・バックアップ・ロック名の存在を調べる。旧データの内容は読まない。ただし旧受入パッケージ構造・証跡と`IndependentTestModeSupported=true`を要求するため、現在の通常版へそのまま使えない。新しい通常ローカル検証の完成した入口として案内しない。調査中に実ユーザーの領域へこの検査を実行していない。

## 起動前に残る条件

1. 対象ソースと一致した通常版ビルド、必要な回帰試験結果、固定依存ファイルの整合性を確認する。一般公開や別製品モードの許可を付けない。
2. 開発者のクリーンVMと合成データだけであることを確認する。旧データがあれば削除や名前変更で検査を通さず、その環境を使用しない。
3. 対象VMの既存ポリシーを変更せず確認し、通常EXEと同じ固定コンパイラーによる無害なホスト試験で外部スクリプト・モジュールの動作を確認する。取得元による拒否やOSの警告があれば停止する。
4. 条件を満たしてから通常版を引数なしで起動し、Windows 10/11のGUI・通知・Excel・保存・復元を確認する。現時点でこの実機検証は未実施であり、起動許可を出していない。

参考: [Windows PowerShell 5.1の実行ポリシー](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)、[標準認証マネージャーのAPI](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.initialsessionstate.authorizationmanager?view=powershellsdk-1.1.0)。
