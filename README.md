# HealthBridge for iPhone

[Sync for Health](https://github.com/vcnngr/sync-for-health) を元に、**自分の iPhone から自分の Mac へ、Apple ヘルスケアの許可済みデータを保管する**ためのフォークです。上流 App Store 版とは別アプリとして使います。

```text
Apple ヘルスケア
  → HealthBridge（この iPhone アプリ）
  → Tailscale Serve のプライベート HTTPS
  → Mac の受信 API（127.0.0.1:8765）
  → Mac 内 SQLite
  → Codex / Claude が読取専用 CLI で参照
```

Mac が停止・スリープ中は受信できません。復帰後の同期機会に未送信分を受信します。Tailscale **Funnel は OFF** にし、一般のインターネットへ受信口を公開しません。Workers や D1 はこの構成に含みません。

## 自分の iPhone への導入

**App Store で公開・配信する必要はありません。** Mac の Xcode で署名して、自分の iPhone へ直接導入します。

1. Xcode 26.2 以降で `SaluteLibera.xcodeproj` を開きます。ソースフォルダと scheme 名は上流の `SaluteLibera` を維持しています。
2. Target `SaluteLibera` → Signing & Capabilities で、自分の Apple Account の Team を選びます。上流開発者の Team は削除済みです。
3. Bundle ID の初期値は `app.ezgna.healthbridge`、アプリ製品名は `HealthBridge` です。自分の Team で署名できる ID を使います。
4. iPhone を接続して実行先に選びます。端末側で必要な信頼設定・Developer Mode を有効にし、Xcode の Run で導入します。
5. iPhone と Mac を同じ Tailscale の tailnet に接続します。Mac 側受信 API と Serve を用意してから、アプリに HTTPS URL と書込 Token を設定します。
6. デモを OFF にし、必要なグループの読取権限を許可します。接続設定を保存し「同期を有効にする」を ON にします。接続テスト後、初回履歴同期を開始します。

Apple の[対応機能一覧](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)では、HealthKit は無料 Apple Developer でも利用可能とされています。ただし無料 Personal Team ではプロビジョニングに **7 日の期限**があり、継続利用に再署名・再導入が必要です。放置運用の前に、自分の Team で HealthKit と background delivery の署名が通るか実機確認します。既存の有料 Apple Developer Program を使う場合も、証明書・プロファイルの更新管理は必要です。[Apple のアカウント説明](https://developer.apple.com/help/account/basics/about-your-developer-account/)

端末の署名設定、Apple Account の登録、App Store Connect の作成は、このリポジトリのソース修正だけでは完了しません。

## 上流からの主な変更

- 保存済みの本文を確認する **protocol v2 ACK** を採用。単なる HTTP 200 や HTML ページを同期成功にしません。
- HTTPS と別欄の Bearer Token を使用。リダイレクト・URL 内の秘密情報を拒否し、接続先変更時の認証情報と同期位置を分離します。
- 宛先ごとの同期位置をディスクへ確実に保存し、送信失敗・保存失敗時にサンプルを飛ばしません。
- POST を件数・バイト数で制限。GPS はワークアウト 1 件ずつ送り、ルートの追加・削除・後付けを別カーソルで検知して再照合します。
- UTC の小数秒、元アプリ・機器情報、数量 series、血圧の正規 correlation UUID、ECG の値と実時刻 offset を保持します。
- 診断にサーバー本文・Token・任意のエラー説明を入れません。診断の送信は任意で、初期状態は OFF です。
- デモはローカル表示用の合成データだけに限定します。

送信形式と ACK の仕様は [docs/PROTOCOL.md](docs/PROTOCOL.md)、接続・確認手順と制限は [docs/HEALTHBRIDGE.md](docs/HEALTHBRIDGE.md) を参照してください。

## 読み取りの範囲

数量、カテゴリ、ワークアウト、ECG、聴力検査、心の状態、身体的属性、血圧 correlation を扱います。GPS は任意です。グループは初期状態で選ばれておらず、実際に送られるのはユーザーが HealthKit で許可したデータです。ヘルスケアへの書き込みは要求しません。

**Apple ヘルスケア全体の完全なバックアップではありません。** RR / heartbeat series、臨床記録、薬の全履歴、視力処方など、現在の catalog にない型は対象外です。アクティビティリング概要はアプリ画面の表示用に読みますが、同期 payload には含みません。Apple 純正のソース優先順位や重複調整を再現しないため、歩数などの生値を単純合計してもヘルスケア画面と一致するとは限りません。

iOS の背景実行、ロック中の HealthKit 読取制限、Tailscale の接続状態に左右されるため、即時・一定間隔・常時同期は保証しません。送信完了 checkpoint も、読取権限がすべて許可された証明にはなりません。

## 開発と検証

追跡済み `.xcodeproj` があるため、通常のビルドに XcodeGen の実行は不要です。`project.yml` から再生成する場合は、変更後の Bundle ID・製品名・自分の署名設定を維持してください。署名なしのコンパイル確認例です。

```sh
xcodebuild -project SaluteLibera.xcodeproj -scheme SaluteLibera \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/healthbridge-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

合成オブジェクトによる serialization 試験は、HealthKit の store・権限・実データ・ネットワークを使わず実行できます。

```sh
python3 tests/settings/run.py
python3 tests/sync_engine_contract.py
sh tests/transport/run.sh
sh tests/serialization/run.sh
```

実行した検証と未確認範囲は [検証記録](docs/VALIDATION.md) にまとめています。

自動試験と署名なしビルドは、実機での署名・接続・ロック中の挙動・大量履歴・ネットワーク復旧の確認とは別です。共有するソースに自分の URL・Token・測定値・Apple Team ID を書き込まないでください。

## 上流とライセンス

- 原作者: Vincenzo Ingrosso。
- 上流: [vcnngr/sync-for-health](https://github.com/vcnngr/sync-for-health)、基準コミット `7f24c56bf6f70b9df6069abf42e3e1d4d1b25599`。
- フォーク: [ezgna/sync-for-health](https://github.com/ezgna/sync-for-health)。
- [MIT LICENSE](LICENSE) の原文と著作権表示を保持しています。
- 変更前の説明は [UPSTREAM_README.md](UPSTREAM_README.md)、旧 protocol は [docs/UPSTREAM_PROTOCOL_V1.md](docs/UPSTREAM_PROTOCOL_V1.md) に保存しています。これらは上流時点の資料で、このフォークの現行仕様とは異なります。

上流同梱の `tools/ricevitore_prova.py` は旧 protocol のテスト受信器です。このフォークの v2 保存確認や実用 DB の代わりには使いません。上流のサポート先・公開サイト・App Store の説明は、このフォークの動作や保管方針を保証するものではありません。
