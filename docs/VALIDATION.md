# 検証記録（2026-10-24）

## 確認済み

- Xcode 27.1（27A9275）/ iPhoneOS SDK 27.1 で、アプリ全体の Release 署名なしビルドが成功。
- 設定モデル: 29項目。隔離したUserDefaultsとメモリ内Keychain代替で、保存失敗、宛先変更、設定世代、グループ/GPS再取込み、再起動、初回ロック解除を確認。
- 同期状態機械: 38項目。合成HealthKit/HTTPと一時ファイルで、部分失敗・再送・anchor永続化失敗・キャンセル・ルート再照合・checkpoint・ローカルdemoを確認。
- 通信/診断: 63項目。実製品UploaderをSwift 6 strict concurrencyでコンパイルし、URLProtocolで外部通信を遮断。HTTPS、redirect拒否、ACK/hash、キャンセル、ログ秘匿、診断opt-inを確認。
- シリアライズ: 26項目。HealthKitの合成オブジェクトで、時刻、出所、実correlation、series、GPS、ECG、聴力、心の状態を確認。Health storeの生成・読取なし。
- 対になるMac受信器: 41試験。一時SQLiteでv1互換、v2移行、COMMIT後ACK、再送、削除、空属性、読取CLIとページ分割を確認。
- 実製品SwiftのJSONEncoder → Python受信 → 一時SQLite COMMIT → 実製品Swift UploaderのACK検証を実行。
- Mac受信器をschema 2へ更新し、Tailscale Serveの実HTTPSへ健康データを含まないv2接続テストを実行。batch/hash/COMMIT応答が一致。FunnelはOFF。

同期試験の初回並列実行で合成モックの共有辞書raceが発生した。Thread Sanitizerで箇所とクラッシュを再現し、モックをMainActorへ隔離した。修正後のTSan試験と3本並列再実行は、38項目すべて成功し警告なし。productionの同期処理に起因するクラッシュではなかった。

## 実機への導入（2026-10-24追記）

既存の有料Developer TeamでReleaseビルドを署名し、HealthKit・background delivery・対象端末・プロファイル期限・コード署名の整合性を確認した。実iPhoneへのインストールと起動プロセスの生存を確認。Apple Team IDや端末IDは共有ソースへ保存していない。

iPhoneミラーリングで接続設定を保存し、実端末からのprotocol v2接続テスト、許可された実データのSQLite保存、全14グループのscan_complete通知を確認した。自動同期ON、GPS経路・診断送信・demoはOFF。アプリの完了表示も確認した。実データの値・件数・端末識別情報は共有ソースへ記録しない。

## 実機で未確認

個別測定の表示値・単位の照合、アプリがバックグラウンドにある時の配送、ロック/解除、通信断からの復旧、Macスリープ復帰、長いGPSや大量履歴のメモリ。自動試験と署名なしビルドだけで、これらの完了を主張しない。

送信範囲外の型、読取拒否、単独8MiB超record、旧バックアップ復元時の削除整合性などの制限は、READMEとHEALTHBRIDGE.mdを参照。
