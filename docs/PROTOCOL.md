# HealthBridge 送信 protocol v2

このフォークの現行仕様です。上流の「任意の 2xx で成功」とは互換性がありません。旧仕様は [UPSTREAM_PROTOCOL_V1.md](UPSTREAM_PROTOCOL_V1.md) に記録として残しています。JSON の既存キーは上流のイタリア語を維持します。

## HTTP と認証

| 項目 | 値 |
|---|---|
| メソッド | 設定した最終 URL への `POST` |
| URL | `https://` のみ。ユーザー名・パスワード・query・fragment は不可 |
| Content-Type | `application/json; charset=utf-8` |
| Authorization | 必須の `Bearer <token>`。Token は URL と分離 |
| Content-Encoding | gzip 設定時は `gzip`、通常は非圧縮 |
| Cache-Control | `no-store` |
| リダイレクト | 同一ホストを含め、すべて拒否 |

Cookie・キャッシュ・共有認証情報を使わない ephemeral URLSession を使用します。標準の TLS 証明書検証を使用し、検証を無効にする独自実装はありません。Token の前後空白は正規化し、内部改行・空 Token は拒否します。

## 保存確認 ACK

成功応答は **HTTP 200、Content-Type: application/json** で、次の全条件が一致する必要があります。ACK は 8 KiB 以下です。

```json
{
  "ok": true,
  "protocol_version": 2,
  "batch_id": "11111111-1111-4111-8111-111111111111",
  "body_sha256": "<非圧縮の受信JSON本文そのもののSHA-256、lowercase hex 64文字>",
  "committed": true,
  "kind": "health"
}
```

- `batch_id` は送信本文と同じ UUID。
- hash は parse 後に再整形した JSON ではなく、**gzip 解凍後の元バイト列**で計算します。
- `kind` は通常データ・checkpoint が `health`、接続テストが `probe`、診断が `diagnostic`。
- `committed: true` は受信側で検証と永続保存を終えた後だけ返します。メモリ上の queue へ置いた時点で返しません。
- 200 HTML、201/202/204、hash・batch ID・kind の不一致、過大 ACK は成功にしません。
- 非成功時に元本文や測定値、認証情報を応答へ写しません。送信アプリもサーバーのエラー本文をログに入れません。

通信エラー・408・429・5xx は最大 4 回、2 秒・6 秒・18 秒の待機で再試行します。その他の拒否・不正 ACK は即時再試行せず、同期は未完了になります。同じ `send` の再試行では JSON バイト列と batch ID を変えません。後の同期でページを再構築すると batch ID は新しくなるため、受信側は sample UUID の冪等性も実装します。

## 共通 envelope

```json
{
  "app": "salute-libera",
  "versione": 2,
  "batch_id": "11111111-1111-4111-8111-111111111111",
  "installation_id": "22222222-2222-4222-8222-222222222222",
  "destination_id": "33333333-3333-4333-8333-333333333333",
  "dispositivo": "iPhone-model",
  "inviato": "2026-10-24T00:00:00.123456789Z",
  "campioni": [],
  "categorie": [],
  "allenamenti": [],
  "ecg": [],
  "audiogrammi": [],
  "stati_d_animo": [],
  "correlazioni": [],
  "eliminati": [],
  "caratteristiche": {}
}
```

空の配列セクションは通常省略します。`caratteristiche: {}` は属性スナップショットを空へ更新する意味を持ちます。`app` は既存識別子を維持しており、画面の製品名は HealthBridge です。

`installation_id` と `destination_id` は UUID です。宛先に結び付いたカーソルを別宛先へ流用しません。`dispositivo` はモデル名であり、端末固有 ID として使いません。

日時は UTC の ISO 8601 文字列で、Date の小数秒を 9 桁で表します。受信側の検索インデックスに日時精度の制約があっても、元文字列と raw レコードを保持します。測定時の元タイムゾーンがメタデータにあれば維持し、送信時の端末タイムゾーンで置き換えません。

## サイズとカーソル

通常 POST はサンプルと削除 UUID の合計最大 500 件、非圧縮 JSON 最大 8 MiB。GPS 付きワークアウトは 1 件ずつ、ECG は最大 5 件をまとめます。バイト上限が先に効く場合はそこで区切ります。単独サンプルの大きなJSONは `frammenti` を使って分割します。各断片は元recordのUUID・section・SHA256・0始まりindex・total・data_base64を持ち、元JSONは最大256MiB、raw断片は最大2MiBです。各ACKは断片の永続保存を表し、最後の断片ではSHA256/JSON検証とsample確定も同じtransactionで行います。全断片ACK後にのみanchorを進めます。

HealthKit から読んだ 1 ページを分割した場合は、全 POST の ACK を確認してからそのページの anchor を保存します。途中失敗やディスク保存失敗の後は同じページを再送できます。受信側は UUID upsert と削除 tombstone により、二重登録や古い再送による復活を防ぎます。

## レコード

すべての sample レコードは `uuid` を持ちます。通常の測定には `inizio`（開始）、`fine`（終了）、`fonte`（ソース表示名）があり、次を追加できます。

```json
{
  "metadati": {"HKTimeZone": "Asia/Tokyo"},
  "provenienza": {
    "bundle_id": "example.synthetic.health",
    "source_version": "1.0",
    "source_product_type": "synthetic-model",
    "source_os_version": "26.0.0",
    "device": {
      "name": "synthetic-device",
      "manufacturer": "example",
      "model": "synthetic-model",
      "hardware_version": "1",
      "firmware_version": "1",
      "software_version": "1",
      "local_identifier": "synthetic-local-id",
      "udi_device_identifier": "synthetic-udi"
    }
  }
}
```

値がない optional 項目は省略します。`metadati` は文字列マップで、任意の HealthKit オブジェクトを型ごと完全復元するアーカイブではありません。機器の識別情報も測定値と同じく私的データとして扱い、診断へ入れません。

| セクション | 固有項目 |
|---|---|
| `campioni` | `tipo`（HK identifier）、`valore`（Double）、`unita`、`numero_quantita`、series の場合 `serie` |
| `categorie` | `tipo`、`valore`（整数 raw enum）、既知なら `etichetta` |
| `allenamenti` | `attivita`、`durata_s`、任意の `energia_kcal`・`distanza_m`・`statistiche`・`percorso` |
| `ecg` | `classificazione`、`bpm_medio`、`sintomi`、`numero_misure`、`frequenza_hz`、`unita_tracciato`、`tracciato`、`tempi_tracciato_s` |
| `audiogrammi` | `punti`（frequency と左右 summary、元の各 test） |
| `stati_d_animo` | `tipo`・`valenza`・`classificazione`・`etichette`・`associazioni`と対応する raw enum 値 |
| `correlazioni` | `tipo`、`membri: [{uuid,tipo}]` |

### 数量と series

数量の単位は [HealthCatalog.swift](../SaluteLibera/Health/HealthCatalog.swift) の型ごとの固定単位です。`unita: "%"` は割合値であり、`0.18` が 18%、`0.97` が 97% です。生値と表示値を分離します。

HealthKit の `HKQuantitySample.count > 1` の場合は、summary の `valore` だけではなく次の `serie` を送ります。各点の単位は親の `unita` と同じです。全点を取得できなければ失敗にし、その sample を完了扱いしません。summary と各点を二重集計しないでください。

```json
{
  "numero_quantita": 2,
  "serie": [
    {"valore": 70.123456, "inizio": "2026-10-24T00:00:00.000100000Z", "fine": "2026-10-24T00:00:00.000100000Z"},
    {"valore": 71.654321, "inizio": "2026-10-24T00:00:00.000200000Z", "fine": "2026-10-24T00:00:00.000200000Z"}
  ]
}
```

### 血圧 correlation

現在の correlation catalog は `HKCorrelationTypeIdentifierBloodPressure` です。`membri` は HealthKit の `HKCorrelation.objects` から取得した本来の UUID 関係であり、時刻による推測ではありません。上下値自体は `campioni` の該当 UUID を参照します。

correlation 型自体の読取権限を要求せず、内包する systolic / diastolic の権限を要求します。HealthKit は未許可 member を隠す場合があるため、常に両方あると仮定しません。[Apple の説明](https://developer.apple.com/documentation/healthkit/hkcorrelationquery)

### ワークアウトと GPS

`statistiche` は HK identifier → `{unita,somma?,media?,minimo?,massimo?}`。距離が複数種類あるワークアウトでは `distanza_m` を省略し、種類別統計を保持します。辞書の任意の先頭値を総距離として返しません。

GPS 点は `{lat,lon,alt,t}` に加え、利用可能なら `precisione_orizzontale_m`、`precisione_verticale_m`、`velocita_m_s`、`precisione_velocita_m_s`、`direzione_gradi`、`precisione_direzione_gradi` を保持します。Core Location の未有効値を示す負の値も生値のまま保持するため、表示・分析側は妥当性を確認します。

- `percorso` 省略: その POST でルートを取得していない。受信側の既存ルートを消さない。
- `percorso: []`: ルート取得成功・空。受信側の古いルートを空へ更新する。
- ルート取得エラー: 失敗を返し、そのワークアウトの処理を完了にしない。

ルート独立 anchor の変更検出後にワークアウトを再照合するため、同じワークアウト UUID の更新を受信側で許可します。

### ECG・聴力・心の状態

ECG の `tracciato` は `appleWatchSimilarToLeadI` の µV 値を丸めず保存します。`tempi_tracciato_s` は同じ index の測定の sample 開始からの実 offset 秒です。`i / frequenza_hz` だけで時刻を再構築せず、offset があればそちらを使います。

Audiogram の各 point は `frequenza_hz`、任意の `sinistro_dbhl`・`destro_dbhl` に加え、`test` 配列を持ちます。各 test は `tipo_raw`、`lato_raw`、`masked`、`sensibilita_dbhl`、任意の `limite_inferiore_dbhl`・`limite_superiore_dbhl` を保持します。左右 summary は unmasked air test に限定し、元 test 配列を正本にします。

心の状態はラベルに加えて `tipo_raw`、`classificazione_raw`、`etichette_raw`、`associazioni_raw` と metadata を保持します。未知の enum を既知の値へ決めつけません。

### 削除と属性

`eliminati` は sample UUID の配列です。受信側では測定値を削除または非表示にし、UUID の tombstone を残します。古い再送が来ても復活させません。過去のバックアップからの消去は別の保管運用です。

`caratteristiche` は Body グループの現在の属性スナップショットで、同期ごとに再取得します。`data_di_nascita`、`sesso`、`gruppo_sanguigno`、`fototipo`、`sedia_a_rotelle`、`modalita_movimento` が任意で入ります。空 `{}` も明示的な更新です。読取不可を、医学的にその属性が存在しない証明と解釈しません。

## 接続テスト・診断・checkpoint

接続テストは共通 envelope の `app/versione/batch_id/installation_id/destination_id` に `prova: true` を加えたものです。健康データのセクションは含みません。ACK の `kind` は `probe` です。

診断は任意で初期 OFF。同じ共通 envelope に `diagnostica` オブジェクトを加えます。最新ログは最大 300 行で、送信先は同じ URL と Token。ACK の `kind` は `diagnostic` です。サーバー本文、NSError の任意の説明、測定値、Token はログへ転記しません。診断受信を健康データの最新受信と混同しません。

最後に通常 envelope へ次の `checkpoint` を加えた health POST を送ります。

```json
{
  "checkpoint": {
    "status": "scan_complete",
    "scan_id": "44444444-4444-4444-8444-444444444444",
    "completed_at": "2026-10-24T00:05:00.123456789Z",
    "groups": ["corpo", "cuore"],
    "routes": false
  }
}
```

これは選択した範囲でスキャン処理が終わったことを示します。全 HealthKit 項目の許可、すべてのデータの存在、Apple 純正の集計との一致、現在までの即時同期を保証しません。読取可否をアプリから完全に知ることはできず、空の結果を不存在の証拠にしません。


## Capture v3 additions (protocol v2 envelope)

運動は `attivita_raw`, `eventi`, `attivita_dettaglio`, `campioni_associati`, `ambito_campioni_associati`, `relazioni_sforzo` を追加。GPSは新 `percorsi:[{uuid,inizio,fine,fonte,provenienza,metadati,metadati_typed,punti:[RoutePoint]}]` を使い、旧 `percorso` と二重化しません。ルートの省略は未取得、空配列は成功して空を意味します。旧v1/v2形式の受信は維持します。

各recordの `metadati_typed` は型タグ付きの再帰JSON。`metadati` の互換文字列も残ります。数量は `statistiche_discrete` にAppleの元集計値と最終計測区間を保存します。

追加sectionは `heartbeat_series`, `valutazioni`, `prescrizioni_vista`, `dosi_farmaci`, `riepiloghi_attivita`, `farmaci`。前4つは実HKSample UUIDを持つrecord。後2つはHealthBridgeの決定的snapshot UUIDを持つ単一recordで、`identity_kind:healthbridge_snapshot`, `read_completeness:unknown`, `records:[...]` を含みます。日別サマリーは全日、登録薬はアーカイブ済みを含む、現在アクセス可能な全件をquery成功後に原子的upsertします。未送信のsnapshot digestは確定しません。

`scan_partial` は `pending_types` に明示的権限エラーがあった型識別子を載せます。`scan_complete` は従来どおり選択範囲を走査できたことだけを表し、HealthKitは読取拒否とデータ不存在を常に区別させるわけではありません。

フラグメントの`index=0`は送信開始/再開始を表し、同じinstallation/destination/record UUIDについて別SHAの古い未完集合だけを整理します。同SHAの既受信部分、完了manifest、他UUID/namespaceは維持します。同じidentityからは送信を直列化してください。これにより毎回生成時刻が変わるsnapshotでも、中断を繰り返した後に自力再開できます。
