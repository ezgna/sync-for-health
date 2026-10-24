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


## 2026-10-25 / 1.1 build 3

取得範囲を拡張し、運動のイベント・各活動区間・ルート境界、型付きmetadata、心拍間隔、質問票、視力処方、服薬・日別リングsnapshotを追加した。大きな単独recordの分割再送・原子的再構築も追加した。

- 設定29、通信/診断63、同期/背景64、既存serializer47、追加serializer27の契約検証を通過。
- Mac受信器57試験を通過。実製品SwiftのRecordFrames/Uploaderから送信し、受信器再起動・Swift再起動・断片再送の後も、8MiB超・100,000点の合成GPSが全点一致。
- 実HealthKitの監視constructorを、現行の監視対象200型について型別隔離processと一括で確認。HealthStoreの生成・実データ読取はしない。通常履歴queryのconstructorも別に検証。
- Release全体の署名付きビルド・署名検証、実iPhoneへのbuild3導入、起動後の継続動作、更新後の実データ再同期とcheckpointを確認。新しい心拍間隔・日別リングの受信も確認。個人の値・件数・UUID等は共有ソースへ掲載しない。
- 受信schema2から3へ、停止中のSQLite backup APIによるバックアップと整合性検証後に移行。既存sampleを保持して受信サービス再開を確認。

build2では、視力処方をHKObserverQueryへ渡すため起動直後にnative例外で落ちた。実機crash logとconsoleで原因を確認し、build3で読取対象と監視対象を分離した。視力処方の読取・同期は残し、非対応の背景監視から除外。実Apple constructorを使用する回帰試験を追加した。

元のHealthアプリとの全項目・全期間の照合、実在GPSの全点照合、巨大recordの実機メモリ、服薬/視力処方が存在する場合の全項目照合、長期間の背景実行は未確認。`scan_complete`を全読取許可の証明にはしない。残る対象外はCOVERAGE.md参照。
