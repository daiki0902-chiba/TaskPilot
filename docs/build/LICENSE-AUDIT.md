# 固定依存のライセンス・由来監査

対象はこの商用版 builder が配布する実物です。2026-11-18 にローカルの元パッケージ、展開物、固定ソース、ライセンスを確認しました。旧 `docs/04-build-findings.md` は依存取得前の調査記録として残し、現状の依存有無は本書と lock を参照します。TaskPilot の GitHub remote はこの確認の根拠にしていません。

## 固定した実物

| 対象 | 取得元・版 | SHA-256 / 判定 |
| --- | --- | --- |
| ps2exe package | PowerShell Gallery CDN、1.0.17 | `d50b02f136d277a617aef270ed1ecaa6505e3d899ef3cd19cdc2c456dd1cf17b` |
| ImportExcel package | PowerShell Gallery API、7.8.10 | `d8a1d79dc8cf10c0eea30b68b70459b3fb4cac0042fb756fcb23890671857e4c` |
| EPPlus.dll | 上記 ImportExcel に含まれる AssemblyVersion 4.5.3.2 | `c32cefbd1ea051ed3af06e7fb9dd558598a612f042164140cd8be722a351bc63` |
| EPPlus source | JanKallman/EPPlus、commit `4dacf27661b24d92e8ba3d03d51dd5468845e6c1` | `2e4d9e97016ac4f58368b5eee99f42bc70b35468c383f4111701fd445fcdda24` |
| ps2exe LICENSE | MScholtes/PS2EXE、commit `d32d5ce21c458696e860a7533943b1466d925be9` | 原文 `31cbb7c4a4ec3d46302bac50dcc509fd5fc12aec8fc47325c2739e79c5c8d3f5` |
| System.Data.SQLite.Core | 1.0.119.0 / net46、リポジトリーの Windows provider | `provider/provider-manifest.json` と `provider-files.sha256.json` の全ファイル hash を検査 |

正確な URL と第三者表示ごとの hash は `build/dependencies.lock.json` に固定しています。準備処理は ZIP 内の各モジュールファイルと展開後の全ファイルを照合し、別版・追加ファイル・欠落・改変を拒否します。バージョン表示だけから同一物と判断しません。NuGet/Gallery のパッケージ署名の信頼性検証や、ソースから再ビルドした EPPlus DLL の再現可能性検証は実施していません。

## 個別の判断と配布条件

**ps2exe 1.0.17**: 上流 root LICENSE の表題は Microsoft Limited Public License version 1.1 です。MS-PL と同一視しません。ソースの旧ヘッダーは Microsoft Public License を参照しているため、その表示・作者も保持し、本配布では root LICENSE の Windows / Microsoft ランタイム条件に従います。上記 commit の `ps2exe.ps1` と元 package 内の同名ファイルは、SHA-256 `faea495151af69d2ae78783d0071186f98dc568d7b7478f639da0e74ecf01763` が一致します。生成 C# ホストには Ingo Karstein、Markus Scholtes の由来があるため、単なるビルドツールとして表示を省略しません。原文には Windows-1252 の引用符があるので原バイトと UTF-8 変換版を両方同梱し、変換後の hash も固定しています。開発用コンパイラそのものは顧客 runtime に含めません。

**ImportExcel 7.8.10**: 元 package の `LICENSE.txt` は Apache License 2.0、末尾に Copyright 2014 Doug Finke の表示があります。これを第三者表示としてそのまま同梱し、全 runtime ファイルは改変せずにコピーします。元 package には追加の独立した NOTICE ファイルがありません。Examples と NuGet container metadata は runtime から除外します。ImportExcel の Apache 条件を EPPlus に適用しません。

**EPPlus 4.5.3.2**: 同梱 DLL の hash と assembly version を固定しました。対応ソース ZIP の `EPPlus/EPPlus.MultiTarget.csproj` は Version / AssemblyVersion / FileVersion 4.5.3.2、PackageLicenseUrl `LGPL-3.0-or-later` と、Framework 用 net35 / net40 を含むターゲットを定義します。`EPPlus/readme.txt` も 4.5.3.2 を記載します。旧ソースヘッダーには LGPL 2.1 またはそれ以降とあり、後の版を選択できる条件です。本配布では LGPL 3 を採用し、LGPL 3 と参照される GPL 3 の全文を同梱します。EPPlus 5 以降の非商用/商用条件をこの4系へ誤適用しません。

対応ソースは exact commit の完全な ZIP として顧客に同梱します。DLL は元 ImportExcel package から無改変でコピーします。これは上流版・由来・対応ソースを照合した状態であり、同じ hash の DLL を再生成したという主張ではありません。個別 DLL として .NET Framework の通常のロード機構で読まれ、TaskPilot.exe に埋め込まず、起動時に元 DLL の hash を強制しません。利用者が互換性のある変更版へ差し替えられる構造を保持します。顧客向け表示には利用事実、ライセンス、対応ソース位置、変更版の差し替え、デバッグのためのリバースエンジニアリングを認めることを明記しました。将来の EULA でもこの権利を制限しないことが必要です。

**EPPlus 内包部分**: `EPPlus/Packaging/DotNetZip/ZipFile.cs` の Copyright (c) 2006–2010 Dino Chiesa / MS-PL と、`Zlib/Deflate.cs` の Copyright (c) 2009 Dino Chiesa and Microsoft Corporation、JCraft の BSD 形式条件、元 zlib の表示を確認しました。対応ソースを丸ごと同梱するほか、上記ファイルの先頭ヘッダーを由来情報付きで抽出し、読みやすい別紙として同梱します。抽出対象・変換・hash は lock に固定し、MS-PL 全文も添付します。

**SQLite / System.Data.SQLite**: provider は Core 管理 DLL と x86/x64 native interop のみです。上流の public-domain 宣言と zlib 1.3.1 の表示を保持します。System.Data.SQLite の Linq / EF6 用 MS-PL 部分は今回の配布に含まれません。native 内の zlib と managed EPPlus 内の zlib 派生部分は別々の表示を保持します。provider 元 manifest の `windows_execution_verified=false`、`nuget_signature_validation_performed=false` は改変せず、Windows 検証済みという説明には用いません。

## builder が強制すること

ライセンス原文、抽出表示、EPPlus 対応ソースが一つでも欠けるか hash が異なれば、`ValidateOnly` も製品 build も停止します。完成 ZIP は `ThirdPartyNotices`、`ThirdPartySources`、全 runtime を含み、ファイルごとの hash と dependency lock を SBOM に記録します。第三者表示にビルド PC の個人パスは記録しません。

本監査は上記の特定バージョン・ローカル実物に限定します。依存を更新する際は版・DLL・ソース・全表示・差し替え可能性を再確認し、lock と本書を同時に更新してください。Windows EXE 生成・コード署名・Windows 10/11 受入試験はこの Linux 環境では未実施です。
