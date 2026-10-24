import SwiftUI

/// Separate selectors are required by HealthKit for medications and vision.
/// Successful dismissal means the request ended, not that access was granted.
struct HealthAccessControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SyncCenter.self) private var center
    @State private var busy = false
    @State private var message: String?
    @AppStorage("bridge.captureReview.v3") private var reviewed = false
    @AppStorage("bridge.medicationReview.v3") private var medicationsReviewed = false
    @AppStorage("bridge.visionReview.v3") private var visionReviewed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("取得項目の読み取り許可")
                .font(.headline)
            Text("心拍間隔・質問票・日別リングなどを追加しました。服薬と視力処方は、下のボタンで読み取る対象を選択します。元の測定データは変更しません。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("追加項目の読み取り許可を確認") { run(.ordinary) }
            if settings.enabledGroups.contains(.glicemia) {
                Button("服薬の読み取り対象を選択") { run(.medications) }
            }
            if settings.enabledGroups.contains(.corpo) {
                Button("視力処方の読み取り対象を選択") { run(.vision) }
            }
            if let message { Text(message).font(.footnote) }
            Text("許可画面に履歴の範囲が表示される場合は「すべての記録済みデータと今後のデータ」を選択してください。読み取り拒否と元の記録なしは、アプリから区別できません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(busy || settings.demoMode)
    }

    private enum Request { case ordinary, medications, vision }
    private func run(_ request: Request) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                switch request {
                case .ordinary:
                    try await Health.requestAuthorization(groups: settings.enabledGroups,
                                                          includeRoutes: settings.includeRoutes)
                    reviewed = true
                case .medications:
                    try await ExtendedHealth.requestMedicationSelection(store: Health.store)
                    medicationsReviewed = true
                case .vision:
                    try await ExtendedHealth.requestVisionPrescriptionSelection(store: Health.store)
                    visionReviewed = true
                }
                try settings.requestHistoryReplay()
                if settings.syncEnabled { center.syncNow(.manuale) }
                message = "確認が終わりました。許可された範囲を過去分から再同期します。"
            } catch {
                message = "許可の確認を完了できませんでした。iPhoneをロック解除して再試行してください。"
            }
        }
    }
}
