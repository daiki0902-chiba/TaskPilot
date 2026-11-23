# 開発者が用意するもの（B）

**2026-11-23更新：このページは凍結した受入専用版の履歴です。** 販売者は個人、将来の取得先はGitHub private、有料証明書は現段階で購入しないと決定済み。現在は[通常版中心の開発](../development/NORMAL-DEVELOPMENT-ja.md)へ移行します。以下の購入・契約・専用ホストの完成を、通常版ローカル検証の前提にはしません。既存の停止措置は維持します。

以下は方針変更前の正式配布向け検討です。現在、購入・契約や実機起動を促すものではありません。一般版・受入版の公開停止は継続します。

この資料は2026-11-22に下記の公式資料を確認して作成した。料金、対象国、審査条件、画面の名称は変更され得る。申込み画面の表示と提供元の回答を優先する。この作業でアカウント作成、契約、購入、本人確認、秘密鍵の登録は行っていない。

## 最初に決める順番

1. **誰の名義で販売するか**を「個人・個人事業主・法人」のいずれかで決める。まだ署名証明書を買わない。
2. **受入ビルドを誰に渡すか**を決め、招待制の取得先を選ぶ。既存のpublicなTaskPilotリポジトリの公開設定は変更しない。
3. **署名方式と導入方式の対応確認**が終わってから見積りを取る。署名だけでは、Windowsの既定設定で起動できることは保証されない。
4. 対応方式、対象資格、維持費を確認できた後にだけ、選んだ提供元の正式画面で申込み・本人確認へ進む。
5. Aの必須修正と正規署名ビルドが完了した後、Windows 10/11それぞれの実機でCの手順を行う。

今、チャットで伝える情報は、販売者の**区分**と希望する**配布方法**だけで足りる。氏名、住所、身分証、カード番号、招待相手のメール、秘密鍵を貼り付けない。

## 準備・費用・依存関係

| ID | 開発者が決める・用意すること | 費用 | 今行うこと／待つこと |
| --- | --- | --- | --- |
| B01 | 販売者区分と購入者に表示する発行者名の方針 | 方針を決めるだけなら無料 | 個人名義か事業名義かを決める。証明書やStoreの審査で認められる名称と合わせる |
| B02 | 署名提供元の対象資格、証明書・鍵の保管方法 | CA証明書・トークン・クラウド署名は通常有料。発行、更新、保管、利用量等を見積る | **購入保留**。下記の適格性とTaskPilotの技術対応を先に確認 |
| B03 | 招待制の受入ビルド取得先と試験担当者 | GitHub Freeのprivateリポジトリ等は無料で準備可能。容量・CI・組織機能の超過や追加契約は条件次第 | 配布先だけ準備可能。まだEXE・配布ZIPを置かない |
| B04 | 試験に使うWindows 10/11とExcel | 既にライセンスのある端末・Excelが使えれば追加購入は不要。未保有なら条件に応じて費用あり | 使えるOSとExcelの有無を整理。実機のアプリ起動は開始許可後 |
| B05 | 署名担当者のWindows開発環境と鍵を扱う権限 | Windows SDK等のツール取得は無料。CAのミドルウェア・機器やサービスは契約次第 | 配布方式が確定してから必要なツールだけ導入。購入者へ導入を求めない |

具体的な年額・円換算額はここでは確定していない。契約期間、税、為替、鍵保管、端末数、署名回数で異なるため、料金表・見積書に基づいて決める。Azureの公開価格ページも実際の請求額を保証する見積書ではない。

## B01：販売者と表示名

1. 自分だけの非公開メモに「個人／個人事業主／法人」の区分を記録する。
2. 購入者に表示したい名前を決める。ブランド名「TaskPilot」と、本人確認で認められる法的な発行者名は別になり得る。
3. 事業名義の場合は、提供元が求める事業の登録・連絡先・代表者確認を満たせるか、公式窓口で確認する。個人事業主が各サービスでどの区分に該当するかを推測しない。
4. チャットには区分と希望方式だけを伝える。本人確認書類は選んだ提供元の正式な申込み画面へ提出する。

証明書のSubject、MSIXのPublisher、Storeの発行者情報は、後で正規の登録内容と一致させる。現段階で仮名や架空の証明書情報を本番設定に入れない。

## B02：署名方式の選択肢

署名の提供元、梱包形式、取得先は別の選択である。例えばCAは署名、MSIXは梱包、GitHub/Dropboxは取得先で、組合せて使う。Store登録だけで自社EXEの署名やTaskPilotの起動許可が完成するわけではない。次の表を単純な代替品の一覧とは考えず、TaskPilotの技術対応が成立する組合せを確認する。

| 選択肢 | 利用条件と費用 | TaskPilotで先に解決すべきこと |
| --- | --- | --- |
| 公的に信頼されるCAのコード署名証明書 | 個人・個人事業主・法人の扱いはCAごとに確認。通常は発行・更新費用、ハードウェアトークンやクラウド鍵保管等の費用がある | 実際の鍵保管方式でEXE/DLL/PowerShellのAuthenticodeと、用途別のCMS許可情報の両方に署名できること。署名とタイムスタンプを自動検証すること |
| Azure Artifact SigningのPublic Trust | 現行quickstartでは日本の組織は対象。**個人開発者は米国・カナダ所在に限定**されており、日本在住の個人が使えるとは扱わない。有料サービスで、利用条件と請求額の確認が必要 | 短命証明書の更新と現在の発行者固定方式の整合、CMS許可情報の署名連携が未対応。申込みだけで現在のコードを利用可能にはできない |
| Microsoft Store経由の配布 | 新しい登録フローの公式案内ではIndividual・Companyとも登録料なし。ただし本人確認、事業区分、審査・配布方法の条件を確認する | Storeのパッケージ署名は、現行TaskPilotが要求する自社ファイルのAuthenticodeとCMS許可情報を自動で置き換えない。限定受入、フルトラスト構成、発行者確認との統合が必要 |
| 自己署名証明書 | 証明書を作るだけなら費用は不要 | 外部の購入者・試験者へ信頼させる配布方式には採用しない。ルート証明書の手動登録を求めない |

### Azureを選ぶ前の確認

[サービスのquickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)で、自分の所在国と区分がPublic Trustの対象かを確認する。日本リージョンにリソースを作れることと、日本在住の個人がPublic Trustの本人確認を受けられることは別である。Private Trustは一般の購入者が既に信頼する証明書の代わりにはならない。

[証明書管理の公式説明](https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management)では、証明書は毎日更新され、有効期間は72時間である。個別証明書の公開鍵や拇印への固定は永続的な方式にならないと明記されている。現在のTaskPilotは個別証明書の拇印を固定するため、**拇印を1回入力するだけでは対応できない**。Aで発行者の継続的な識別と署名連携を設計・検証するまでは、Azureをこの製品のために契約・購入しない。

採用可能と判断された後の操作順は、Azure portalへサインイン → 対象サブスクリプション・請求先を確認 → 「Artifact Signing」を検索 → 料金・所在国・本人確認区分を再確認 → アカウント・Identity Validation・Certificate Profileを公式quickstartに沿って作成、となる。現時点ではこのリソース作成・課金開始の段階へ進まない。

### CA証明書を選ぶ前の確認

1. CAの公式サイトで「コード署名」を選ぶ。TLS/SSL用のWebサイト証明書を選ばない。
2. 「日本在住のこの区分で申込み可能か」「発行者名はどう表示されるか」を問い合わせる。
3. 発行・更新費用、最短契約期間、トークン送料、クラウド鍵保管・署名回数、必要なソフトと本人確認を含む見積りを依頼する。
4. 見積りと公開仕様から、TaskPilotのAuthenticodeとCMS許可情報を作れる方式かを開発側で確認する。秘密鍵をコピーしてチャット、GitHub、Dropboxへ渡す方法は使わない。
5. Aの導入・ホスト互換性設計が確定した後、選んだ提供元の正規画面で契約・本人確認する。鍵は選んだトークン/HSM等で管理する。

### Storeを選ぶ前の確認

[現行の登録説明](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/account-types-locations-and-fees)では、新登録フローのIndividual・Companyとも登録料なしとなっている。一方でIndividualの対象は事業・職業と無関係な配布、非商用・趣味等と案内されている。商用のTaskPilotについて、Individualを無条件に選ばず、個人事業主を含めどの事業区分で登録できるかをMicrosoftへ確認する。IndividualからCompanyへの変更は非対応と案内されているので、区分の確認を先に行う。

採用する場合は、公式の[Store開発者サイト](https://storedeveloper.microsoft.com/) → 「Get started for free」 → 確認したアカウント区分を選択 → 正式なMicrosoftアカウントでサインイン → 本人/事業確認 → Partner Center、の順になる。本人確認は公式の画面だけで行う。Store登録が完了しても、今の受入EXEがそのまま安全に起動できるとは判定しない。

登録料が無料という説明は、売上の決済・手数料・税、他社の署名サービス、Windows/Excel等の費用まで無料という意味ではない。販売方法を決める段階で、それぞれの契約条件を確認する。

## B03：限定配布先の準備

**推奨候補は、新しく作るprivateな受入専用GitHubリポジトリ。** 現在のpublicなTaskPilotとDraft PR #1は維持する。GitHubを使わない試験担当者には、個別招待したDropboxフォルダーも候補となる。いずれも作成・招待は開発者が行い、今はアプリのEXE・配布ZIPをアップロードしない。

### GitHubで用意する場合

1. GitHubへ自分のアカウントでサインインする。
2. 右上の「＋」→「New repository」を開く。
3. 所有者を確認し、例として`TaskPilot-acceptance-private`という別のリポジトリ名を付ける。
4. **Private**を選び、「Create repository」で作成する。既存のTaskPilotのSettingsで可視性を変更しない。
5. 新しいリポジトリのSettingsでCollaboratorsまたはアクセス管理を開き、担当者のGitHubユーザー名を指定して招待する。組織管理の場合は、取得に必要な最小限の権限を選ぶ。
6. 担当者が招待を受け入れたことを確認する。URLをログアウト状態で開いて、未招待者が取得できないことも確認する。
7. アプリを置くのは、A・Bの必須条件が完了し、受入開始が許可されてから。アプリ、対象コミット、ハッシュ、署名検証結果、使用期限、手順書を同じ版として渡す。

[GitHub Free](https://docs.github.com/en/get-started/learning-about-github/githubs-plans)でもprivateリポジトリを利用できる。CI実行量、保存容量、組織の管理・承認機能等はプラン依存なので、別途確認する。publicなActions Artifactの名前に「受入専用」と付けても、取得者制限にはならない。

個人所有のprivateリポジトリへcollaboratorとして招待すると、相手は書込み権限も持つ。閲覧だけに限定したい場合は組織リポジトリのRead権限、またはDropboxの閲覧招待を候補にする。招待先を決める際に、この違いも確認する。

### Dropboxで用意する場合

1. Dropboxへサインインし、空の受入専用フォルダーを新規作成する。
2. そのフォルダーの「共有」→「ユーザーを追加」から試験担当者を個別に招待し、可能なら「閲覧可能」を選ぶ。
3. 「アクセスできるユーザー」で、招待した本人だけに限定されていることを確認する。リンクを使う設定でも「招待したユーザーのみ」の範囲を確認する。
4. 「リンクを知っている全員」の共有リンクを作って代用しない。未招待の別アカウントから取得できないことを確認する。
5. 契約プラン・容量・外部共有の制約を確認する。利用中の無料枠で足りる場合は追加費用なしで準備できるが、必要機能がなければ有料契約等の選択を先に決める。
6. 署名済み受入物の開始許可後にだけ、その版のファイルを置く。試験終了後は招待を解除する。取得済みコピーまで消去できるとは考えない。

権限の名称と変更方法は[Dropboxの公式説明](https://help.dropbox.com/share/set-file-folder-permissions)を確認する。実ユーザーのDB、CSV、Excel、バックアップ、業務ログはこの配布フォルダーへ入れない。

## B04・B05：後で使う端末とツール

Windows 10とWindows 11は別々に検証する。使える端末とOS、Excelの有無をメモするだけなら、TaskPilotや既存データを起動・確認する必要はない。Excelのファイル生成をServerで確認できても、実Excelの表示やグラフの受入を終えたことにはならない。

署名担当者のWindows PCに必要なSDK・署名クライアントは、Aで採用した方式に応じて開発者が用意する。購入者にPython、SQLiteやPowerShellモジュールの手動導入を求めない方針を維持する。WindowsやExcelのライセンス購入が必要かは、既存の保有状況に応じて判断する。

## 記録の方法と実機開始までの境界

[決定事項の記録例](DEVELOPER-DECISIONS.example.json)には区分や方式だけを記入できる。これは計画用であり、実行時の信頼設定・署名済み起動許可ではない。項目を変更しても、起動前検査は通らない。

署名があっても、現在の外部PowerShellファイルを使うホストはWindowsの実行ポリシーと互換性を確認する必要がある。Windowsクライアントの既定のRestrictedや、組織のAllSigned等に対し、正規の導入・実行方式をAで設計しCで確かめる。実行ポリシー変更、取得元情報の削除、保護機能の停止、手動の信頼ルート追加を解決策にはしない。

実機検証を始めるのは、[開始条件](READINESS-ja.md)が満たされ、正規の取得・導入・起動手順がそのビルドについて発行された後である。現在はNOT_READYであり、PCを準備したり署名サービスの候補を選んだりしても、TaskPilotを起動してよいことにはならない。

## 参照した公式資料

確認日：2026-11-22。Azureの対象国はサービス自身のquickstartを主に確認した。別製品の導入記事に古い対象国一覧が残る場合があるため、最終申込み前にはサービス提供元に確認する。

- [Azure Artifact Signing quickstart・対象資格](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
- [Artifact Signingの証明書管理・日次更新・拇印固定の制約](https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management)
- [Artifact Signingの価格・見積りに関する説明](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/)
- [Microsoft Storeのアカウント区分・新しい登録フロー](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/account-types-locations-and-fees)
- [MSIX署名とOSによるパッケージ整合性検証](https://learn.microsoft.com/en-us/windows/msix/package/signing-package-overview)
- [Windows PowerShellの実行ポリシー](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)
- [GitHubのプラン](https://docs.github.com/en/get-started/learning-about-github/githubs-plans)
- [GitHubで新しいリポジトリを作る](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository)
- [Dropboxのファイル・フォルダー権限](https://help.dropbox.com/share/set-file-folder-permissions)
