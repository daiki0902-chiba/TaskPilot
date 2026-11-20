# TaskPilot 第三者ソフトウェアの表示

この配布物は次のソフトウェアを使用します。各権利者の著作権表示、免責、利用条件は同じフォルダー内の原文を参照してください。TaskPilot の利用規約が同梱されている場合も、これらのライセンスに基づく権利を制限しません。

| ソフトウェア | バージョン・表示 | 同梱条件 |
| --- | --- | --- |
| ps2exe が生成する PowerShell ホスト | ps2exe 1.0.17。Written by Ingo Karstein (http://blog.karstein-consulting.com); Reworked and GUI support by Markus Scholtes。パッケージ表示: (c) Markus Scholtes 2025 | `PS2EXE-1.0.17-LICENSE.original` と読みやすい UTF-8 版。上流の Microsoft Limited Public License version 1.1 に従い、Windows / Microsoft ランタイム用に配布 |
| ImportExcel | 7.8.10、Copyright 2014 Doug Finke | `ImportExcel-7.8.10-Apache-2.0.txt`。モジュール本体は変更せず同梱 |
| EPPlus | 4.5.3.2、Copyright (C) 2011 Jan Källman。原ソースの著作権表示も保持 | LGPL。本配布では LGPL version 3 の条件を採用。`LGPL-3.0.txt` と `GPL-3.0.txt`、下記の対応ソースを同梱 |
| EPPlus 内の DotNetZip | Copyright (c) 2006–2010 Dino Chiesa | `MS-PL.txt`、`EPPlus-DotNetZip-Notice.txt` |
| EPPlus 内の managed zlib / JCraft jzlib 派生部分 | Copyright (c) 2009 Dino Chiesa and Microsoft Corporation; JCraft、Jean-loup Gailly、Mark Adler の表示 | `EPPlus-ManagedZlib-JCraft-Notice.txt`。MS-PL と元コードの表示・条件・免責を保持 |
| System.Data.SQLite Core | 1.0.119.0、SQLite 3.46.1 を含む | `SQLite` サブフォルダーの上流 public-domain 宣言。Linq / EF6 アセンブリは含まない |
| SQLite native 側の zlib | 1.3.1 | `SQLite/zlib-1.3.1-License.txt` |

## EPPlus の対応ソースと差し替え

TaskPilot は Excel ファイルの読み書きに EPPlus を使用します。EPPlus はフリーソフトウェアです。EPPlus の利用・複製・変更・再配布について、同梱の LGPL / GPL の条件に基づく権利があります。TaskPilot のライセンスは、変更した EPPlus を組み合わせることや、その変更のデバッグに必要なリバースエンジニアリングを禁止しません。

対応ソースは、配布フォルダー内の `ThirdPartySources/EPPlus-4.5.3.2-source-4dacf276.zip` に含まれます。追加のダウンロードや販売者への請求なしに、そのまま取得できます。TaskPilot では同梱 EPPlus DLL を改変していません。

- 上流: https://github.com/JanKallman/EPPlus
- ソースコミット: `4dacf27661b24d92e8ba3d03d51dd5468845e6c1`
- ソース ZIP SHA-256: `2e4d9e97016ac4f58368b5eee99f42bc70b35468c383f4111701fd445fcdda24`
- 同梱 DLL: `Modules/ImportExcel/EPPlus.dll`、AssemblyVersion `4.5.3.2`
- 同梱 DLL SHA-256: `c32cefbd1ea051ed3af06e7fb9dd558598a612f042164140cd8be722a351bc63`

変更する場合はアプリを終了し、配布フォルダーを別名でコピーして保管してください。ZIP 内の `EPPlus/EPPlus.MultiTarget.csproj` はバージョン 4.5.3.2 と `net35` / `net40` 等のターゲットを定義しています。上流ソースに含まれるプロジェクト、鍵、設定、説明を使い、Windows PowerShell 5.1 / .NET Framework と互換性がある EPPlus DLL を作成します。ビルドに用いる SDK / .NET Framework の開発用パックは開発者側に用意してください。

コピー側の `Modules/ImportExcel/EPPlus.dll` を互換性のある変更版 DLL に置き換えると、TaskPilot の再コンパイルなしに読み込みます。上流の DLL は独立したファイルであり、TaskPilot.exe に埋め込んだり暗号化したりしていません。製品のファイル一覧に元 DLL の SHA-256 を記録しますが、起動時にその値を強制して差し替えを拒否する仕組みはありません。変更後は Excel 出力を確認してください。互換性がない DLL では出力に失敗することがあります。

EPPlus 4 系の条件を説明しており、後の EPPlus 5 以降のライセンスや版への交換を案内するものではありません。ソース内には LGPL 2.1 またはそれ以降という旧ヘッダーもあり、対象プロジェクトの NuGet メタデータは `LGPL-3.0-or-later` を指定しています。本配布では LGPL 3 の全文と GPL 3 の全文を提供します。
