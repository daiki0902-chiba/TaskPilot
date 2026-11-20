# 商用TaskPilot：ビルド・配布の現物確認

今回の範囲はローカルにあるビルドPS1/BAT、配布物、依存DLLと表示文書の読み取り確認。既存リリースは変更していない。Python、依存の追加インストール、Windows用DLLの実行、外部への公開は行っていない。

## 現物の有無

- 添付元ビルド：`attachments/04bbc521-6099-49bd-9fba-070774c3c40c/Build_TaskPilot_STEP3_6F_4.ps1`。
- 修正版ビルド：`output/TaskPilot_reviewed/Build_TaskPilot_STEP3_6F_4.ps1`。
- 修正版GUI：`output/TaskPilot_reviewed/TaskPilot_STEP3_6F_4.ps1`、バージョン表記0.9.20.5。これはCSV/JSONを使う旧GUI。
- STEP4C：`work/step4c/` と既存のrelease/extractedディレクトリー。保存API・検査移行・providerは存在するが、READMEの通りUI切替用ではない。
- **ローカルにTaskPilot.exeは存在しない。** `rg --files /workspace --glob '*.exe' --glob '*.EXE'` は該当なし。
- **ローカルにps2exe、ImportExcel、EPPlusの実配布モジュール/DLLはない。** PowerShellの `Get-Module -ListAvailable -Name ps2exe,ImportExcel` も該当なし。
- System.Data.SQLiteの管理DLL、x86/x64のnative DLL、元NuGetパッケージ、hash manifest、第三者表示は存在する。

修正版BATは実際のCRLFで保存され、`set BuildResult=%ERRORLEVEL%` → `exit /b %BuildResult%` で終了コードを保持している。表示上の `\r\n` を実ファイルの文字列化不具合と誤認しないこと。元BATは終了コード保持がなく、その点は修正版で改善済み。

## 具体的なビルド上の問題

| 優先 | 問題と根拠 | 修正方針 |
|---|---|---|
| 高 | 修正版ビルド3行目は旧GUI `TaskPilot_STEP3_6F_4.ps1` を固定入力にする。25行目で同梱するのはImportExcelのみ。新しいSQLite GUI/Storage/Codec/schemaは含まれない。現状のビルドを実行しても商用SQLite製品にはならない。 | 新しい製品エントリーポイントを明示し、必要なmodule/schema/codec/assetsのみを配布allowlistへ登録。DBを正本として動くGUI自体の統合と受入確認が別途必要。 |
| 高 | 修正版19行目で固定stageを再帰削除し、67行目で従来ZIPを削除する。ビルドや圧縮が後で失敗すると前の配布物を失う。 | 新しいバージョン/ビルドID専用ディレクトリーで作成・検証後に新規出力として公開。既存リリース/ZIPは上書きしない。 |
| 高 | 13行目はps2exeをバージョン未指定でImport、14行目はマシン上で最大バージョンのImportExcelを採用。ビルドPCの状態で成果物とライセンス対象が変わる。 | 検証済みのビルド依存バージョン、配布DLLのhash、取得元をlock/manifestに固定。自動でInstall-ModuleやPATH変更はしない。 |
| 高 | 49行目のLICENSE/NOTICE名による探索は、ImportExcel配下のファイルだけ。ps2exe由来の配布部分と各依存DLLの条件を確認できない。対象にlicenseファイルがなければ空のまま成功する。 | 配布する実バージョンの全依存を棚卸しし、必要な表示が欠けたらrelease生成を停止。単なる「確認してください」文書を確認完了の代替にしない。 |
| 中 | 22行目はEXEが存在することだけを検査し、0バイト・PE/製品メタデータ・起動・実処理を検査しない。 | サイズ、PE、製品名/Version、依存ファイル/hashを静的検査。Windowsではクリーン環境で起動・セルフテスト・主要ユーザーフローを確認。 |
| 中 | コード署名・証明書検証・署名後の最終hash/ZIP作成の手順がない。 | 署名オプションと証明書/タイムスタンプ指定、署名検証、署名後のmanifestとZIP生成を実装。利用者の正規証明書なしに「信頼された署名済み」としない。 |
| 中 | EXE metadataのversionは0.9.20.5だが、同梱READMEはSTEP3.6F portable beta、出力名も3.6F_4固定。 | 製品名・SemVer・ファイル名・DB schema版・README・manifestを一つのrelease metadataから生成。過去のprovenanceは改変しない。 |
| 中 | `Get-FileHash | Format-List | Out-String` のZIP照合ファイルはローカライズされた表示とビルドPCのパスを含む。配布先での自動照合に不向き。 | `SHA256  ZIPファイル名` 等の機械可読な書式とJSON manifestを生成。ファイル一覧はordinal順で安定化し、manifest自身は自己hash対象外と明記。 |
| 中 | 旧GUI1866〜1871行目は同梱ImportExcelがない場合にマシン側モジュールへfallbackする。購入者環境によって異なる版が動く。 | 製品モードでは同梱依存を必須として明確な診断。開発用fallbackは明示した開発モードのみにする。 |
| 中 | `-STA -noConsole` はあるが、最終EXEのCPU target、対応OS/.NET、native DLLのprocess architectureの確認が定義されていない。 | 例えばx64製品として固定するか、x86/x64双方を各々実機検証。64-bitをARM64と同一視しない。 |

修正版で追加済みの良い点は、Windows PowerShell 5.1の確認、PS構文解析、source/module versionのBuildInfo、配布ファイルのhash記録、BATの失敗コード保持。これらは実行ファイルの動作合格・ライセンス確認・商用品質を証明するものではない。

## 依存と第三者表示の根拠

| 依存 | ローカルで確認できた根拠 | 配布時の扱い |
|---|---|---|
| System.Data.SQLite.Core 1.0.119.0 / net46 | `work/step4c/Modules/TaskPilot.Storage/provider/provider-manifest.json`。NuGet公式flat-container URL、package SHA-256、管理/native各DLLのSHA-256が記録されている。管理DLLとx86/x64 nativeが実在。SQLite 3.46.1を同梱する版。 | 管理DLLの隣にx86/x64を維持。`.altconfig` は上流の注意に従って同梱しない。prodはWindows PowerShell5.1/.NET Framework、Linuxテストadapterは製品ZIPから除外。 |
| SQLite / System.Data.SQLite Coreのpublic-domain宣言 | `provider/ThirdPartyNotices/SQLite-Copyright.txt`、`System.Data.SQLite-Copyright.txt` に上流URLと取得日。provider上流の例外は別のLinq/EF6に含まれるMS-PL対象コードで、今回のCore配布には両assemblyなし。 | 実際に同梱するCoreとnativeの根拠を保存。「全DLLの全コードが一律public domain」とは記載しない。これは法的保証書ではない。 |
| zlib 1.3.1 | native内のversion/copyright文字列を以前の調査で確認。`provider/ThirdPartyNotices/zlib-1.3.1-License.txt` に正確なv1.3.1 `zlib.h` の表示と取得元。 | permissiveなzlib表示を保持。SQLite本体の宣言だけで置換しない。 |
| ps2exe | **実バージョンのmodule、生成runtime/source、LICENSEはローカル未提供**。現在のビルドは単に `Import-Module ps2exe`。 | toolであることだけを理由に表示不要と断定しない。選定版の生成物に含まれるコードと再配布条件を確認し、記録・表示する。 |
| ImportExcel / EPPlus | **実module、EPPlus.dll、LICENSEはローカル未提供**。旧GUIとビルドにはImportExcelへの依存がある。 | 実際のmodule版・EPPlus版を確定して条件を確認。ImportExcel本体とEPPlusのライセンスを混同しない。EPPlusの世代で商用条件は異なるため、名前から商用可否を断定しない。 |
| Windows PowerShell / .NET Framework | 対象プラットフォームとして依存。Linux調査用pwshは `work/pwsh` にある。 | Linux用pwsh、Mono.Data.Sqlite、DebianパッケージをWindows顧客ZIPに混入させない。対象Windows/.NET要件を明示。 |

provider-manifestに `nuget_signature_validation_performed=false`、`windows_execution_verified=false` が記載されている。これはそのmanifest作成時点の調査記録。NuGetの署名ファイルが存在することを署名の信頼確認済みと扱わない。また今回新たに作るGUI/EXEのWindows確認済みという意味にもならない。新releaseの確認状態は、そのrelease専用の検証結果に分けて記録する。

## Windowsなしで実装・確認できる範囲

- ビルドスクリプトのfail-fast、payload allowlist、既存release非破壊、version/architecture/署名パラメーター、依存lockの形式、manifest/hash、ZIPの内容・除外検査。
- GUIのPowerShell/C#ソース、WinFormsレイアウト定義、SQLite API接続、Excel/CSV等の出力コードの実装と構文解析。
- SQLite schema/保存・移行処理の既存Linux .NET adapter回帰。ただしこれはWindows native providerの検証ではない。
- ソース/ZIP/DLLの静的inventory、hash照合、第三者表示の収集・対象整理。
- 署名用手順と検証コード。実際の販売者証明書の発行・署名・外部timestamp確認は未実行として区別。

## Windowsで実行しないと合格とできない範囲

- ps2exeの対象版を使ったWindows EXEの生成、署名、PE metadataとnative依存の実物確認。
- 生成EXEとPowerShell5.1/.NET Framework上のSystem.Data.SQLite読込、32/64-bit選択、blocked-zone診断。
- Windows Formsの起動、DPI/画面サイズ、IME/日本語・キーボード、複数ウィンドウ、通知、終了と再起動。
- 実ファイルのロック、アプリの二重起動、別ユーザー/通常権限、空き容量不足、SQLite回復・バックアップ復元。
- ImportExcel/EPPlusを残す場合、その固定版でのExcel生成とExcel/互換viewerでの表示、Excelで開いたままの再出力。
- Defender/SmartScreen、ZIP展開後のクリーンPC起動、購入者がPowerShell操作や依存導入なしで使えること。

**現時点で「商用版EXE生成済み」「Windowsで全機能合格」と記載してはいけない。** 作成する成果物は `実装済み`、`静的/adapter検証済み`、`Windows未検証`、`未実装/未生成` を区別して提示する。EXE化はソース秘匿・強いコピー防止・利用許諾の仕組みの代替でもない。

## 新ビルドへ引き継ぐ構成

開発用一式と顧客配布用を分離し、顧客側にはEXE、必要なmodule/provider/schema/codec/assets、利用者向け説明、第三者表示だけを入れる。顧客ZIPへ次を入れない：実DB/個人データ、Data/Backup/Export/Logs、DeveloperSandbox、回復用sidecar、stageファイル、Linux adapter、package cache、テスト結果、旧版ソースの混在、開発用修復スクリプト。

旧リリースディレクトリーを再利用しない。既存STEP4A/B/C配布物はそのまま保存し、別の商用版作業ディレクトリー・新しいrelease名で成果を作る。

## 識別用SHA-256

- 添付元ビルドPS1：`c4c66d146b42e86b9831f3379b48a3d55574f68c136a6f067f3eea938fd883c7`
- 修正版ビルドPS1：`19c62b7c3fdd9778d8cb4c7d49fd9609f8ef2669b5b174f9417f8bd5f6650fcc`
- 修正版旧GUI PS1：`ab0c5e2dbc31128563298d70adf51c59d3e081643899575aaba1d0183d47188d`
- System.Data.SQLite.dll：`77dac4e1aa63161d6aff363030a801945d6b8d5b823a6b460b2c2be9ec38d3b7`
- x86 SQLite.Interop.dll：`553693b15bda4bbf7788bee09b8bd325ffe4db151686f432194c58e15b9b4f1e`
- x64 SQLite.Interop.dll：`1111916dc329a13bd627b2cd90c9b2263de9923fd0bb6059c69c52332f360c37`
