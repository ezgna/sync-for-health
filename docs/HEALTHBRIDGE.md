# HealthBridge の接続と確認

このフォークは iPhone の送信アプリです。常駐受信 API、SQLite、読取専用 CLI は Mac 側の Health Bridge で用意します。iPhone は DB ファイルを直接書き換えません。

## 接続経路

```text
iPhone: HealthBridge + Tailscale
  → https://MAC_NAME.TAILNET_NAME.ts.net:8443/ingest
  → Mac: Tailscale Serve
  → http://127.0.0.1:8765/ingest
  → SQLite
```

`MAC_NAME` と `TAILNET_NAME` は自分の Tailscale DNS 名です。このドキュメントに実際の端末名や Token を記載しません。ポート番号は Mac 側の設定と合わせます。受信 API は loopback だけで待ち受けます。

- Mac と iPhone の Tailscale を同じ tailnet へ接続します。Exit Node は不要です。
- Tailscale の HTTPS 証明書と Serve を使用し、**Funnel は無効**にします。HTTPS の有効化時には端末の DNS 名が Certificate Transparency の公開ログへ登録される点を確認します。
- 共有 tailnet の場合はアクセス制御で受信 Mac の対象ポートを必要な端末に限定します。
- iPhone の他の VPN と Tailscale が競合する場合があります。
- 接続先は最終的な HTTPS URL を直接指定します。ログイン画面・短縮 URL・リダイレクトする URL は使いません。

参照: [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)、[HTTPS](https://tailscale.com/docs/how-to/set-up-https-certificates)、[他の VPN との併用](https://tailscale.com/docs/reference/faq/other-vpns)。

## 初回設定

1. Mac 側で protocol v2 対応の受信 API を起動し、`/healthz` へアクセスできることを確認します。`/healthz` は稼働確認だけで、保存確認の ACK ではありません。
2. iPhone でデモを OFF にし、固定の HTTPS URL と書込 Token をそれぞれの欄へ入力します。Token に `Bearer ` を付けず、URL の query にも入れません。
3. 接続テストを実行します。v2 の ACK が一致して初めて成功になります。これはネットワーク・認証・保存契約の確認で、測定履歴の同期完了とは別です。
4. 保存したいグループを選び、ヘルスケアの読取権限を許可します。GPS が必要ならワークアウトのルートも明示的に ON にします。
5. 初回同期は iPhone をロック解除し、アプリを前面で開いたまま実行します。大量履歴では充電と安定した通信を用意します。
6. Mac 側 CLI で受信した型・件数・測定日を確認し、iPhone の既知の数件と値・単位・時刻を照合します。
7. 初回同期に加えて、追加・削除、iPhone のロック/解除、通信断/復旧、Mac のスリープ/復帰も確認します。ソース修正・コンパイル成功だけで実機運用完了とはしません。

## 保存・再送の契約

受信側は本文全体を検証し、1 POST をトランザクションで保存してからだけ、対応する `batch_id` と本文 SHA-256 を ACK で返します。サンプルの UUID で upsert し、削除 UUID は tombstone として保持します。応答が失われて同じデータが再送されても、重複や削除済みデータの復活を起こさない設計にします。

送信側は宛先ごとに HealthKit anchor を分けます。1 HealthKit ページを複数 POST に分割した場合は、全 POST の ACK を確認してからそのページの anchor を保存します。途中失敗や anchor 保存失敗ではページを再送できます。anchor が壊れた場合に黙って成功として飛ばしません。

GPS はワークアウト保存後に届く場合があります。ルート型の独立 anchor を読み、変化があればワークアウトを再照合します。再照合位置も永続化するため中断から再開できます。ルート取得が成功して空だった場合は `percorso: []` で受信側の古いルートを消します。GPS OFF で `percorso` が省略された場合とは区別します。

送信先や Token を変える際は、実行中の同期を停止し、新しい接続先として保存・接続テストします。データの送り先が変わる操作を、自動的な認証情報の持ち越しにしません。同期停止後もすでに受信側で保存されたデータは残ります。

## 値を読む際の注意

- `%` の生値は割合です。`0.18` は 18%、`0.97` は 97% です。元値と表示値を区別します。
- 血圧は `correlazioni.membri` の本来の UUID 関係を使用します。同時刻・同じソース名だけで上下を組み合わせません。権限により一方の member が隠れる場合もあります。
- 数量 series は `numero_quantita` と `serie` を持ちます。summary の `valore` と series 各点を二重に合計しません。
- 複合ワークアウトの距離は種類別 `statistiche` を参照します。複数種類がある場合、`distanza_m` を無理に総距離へ変換しません。
- 生の歩数などに重複ソースがある場合、Apple ヘルスケア画面の集計とは一致しない場合があります。
- ECG は Apple Watch に似た第 I 誘導のデータです。`tempi_tracciato_s` と値を対応させます。データ保管の仕組みであり、独自の診断を追加するものではありません。
- 時刻は UTC の小数秒付き。元の `HKMetadataKeyTimeZone` がある場合は `metadati` に残します。測定時のタイムゾーンが記録されていない場合は推測しません。

## 限界と未対応

- Mac がオフ・スリープ・ログアウト中、Tailscale が切断中は受信できません。次の同期機会に追いつきます。
- iOS が背景処理の時刻・頻度を決めます。ロック中は HealthKit が読めない場合があり、同期は即時・常時・定刻を保証しません。
- 全許可・拒否はアプリから完全には識別できません。空の結果が「データが存在しない」証明になるわけではありません。checkpoint は要求した範囲のスキャン完了で、全ヘルスケアの網羅性や現在の鮮度の保証ではありません。
- catalog 対象外の RR / heartbeat series、臨床記録、薬の全履歴、視力処方などは保存しません。
- アクティビティリング概要は Today 画面用に読み取りますが、同期対象外です。
- 1 サンプルだけで 8 MiB を超える場合、現行送信形式では未保存のまま明示的に失敗し、同期位置を進めません。巨大サンプルを黙って省略しません。単独サンプルの分割送信は未実装です。GPS・数量seriesは1サンプル内の全配列を保持するため完全streamingではなく、巨大単独レコードの実機メモリは未確認です。
- メタデータは元の上流仕様に合わせた文字列マップです。任意の HealthKit オブジェクトを完全に復元する型付きアーカイブではありません。
- SQLite 自体は暗号化形式ではありません。Mac のユーザー権限・FileVault とバックアップの管理が必要です。削除同期後も古いバックアップには値が残り得ます。
- SQLite のライブ DB を iCloud Drive などへそのまま同期しません。バックアップ API で整合性のあるコピーを作ります。
- AI に読ませたデータはその AI サービスでも扱われます。「Mac に保存」と「AI へ渡した後」を区別します。

## 検証を分ける

| 段階 | 確認できること |
|---|---|
| オフライン試験 | 合成データでの ACK、重複・削除、serialization、失敗時の振る舞い |
| 署名なしビルド | iOS SDK でソースがコンパイルできること |
| 自分の Team で署名 | HealthKit・背景配送を含め、実機へ導入できること |
| iPhone → Mac の初回受信 | 実際の権限・通信・保存・値の一致 |
| 継続運用 | ロック、スリープ、通信復旧、削除・GPS 後付け、大量履歴 |

上の段階を混同せず、未確認項目は未確認として扱います。
