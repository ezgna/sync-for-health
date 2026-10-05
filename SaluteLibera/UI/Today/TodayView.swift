import SwiftUI

struct TodayView: View {
    @Environment(TodayModel.self) private var model
    @Environment(SyncCenter.self) private var center
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, -6)
                        .padding(.leading, 4)

                    if settings.demoMode {
                        Label("Modalità dimostrativa: dati di esempio inventati. Spegnila in Impostazioni.",
                              systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.brand[1])
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular.tint(Palette.brand[1].opacity(0.08)), in: .rect(cornerRadius: 16))
                    }

                    SyncHero()

                    Text("In evidenza")
                        .font(.title3.weight(.bold))
                        .padding(.top, 14)
                        .padding(.leading, 4)

                    highlights
                    privacyFooter
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(AppEnvironment.scrollToBottom ? .bottom : .top)
            .background(AmbientBackground())
            .navigationTitle("Oggi")
            .refreshable {
                center.syncNow()
                await model.refresh()
            }
            .task { await model.refresh() }
        }
    }

    @ViewBuilder private var highlights: some View {
        let s = model.snapshot
        if model.loaded && s.isEmpty {
            EmptyHighlights()
        } else {
            if let steps = s.steps {
                StepsCard(steps: steps, average: s.stepsAverage, week: s.stepsWeek)
            }
            if let night = s.sleep {
                SleepCard(night: night)
            }
            if s.restingHR != nil || s.hrv != nil {
                HeartCard(resting: s.restingHR, restingSeries: s.restingSeries, hrv: s.hrv, hrvSeries: s.hrvSeries)
            }
            if let ecg = s.ecg {
                ECGCard(ecg: ecg)
            }
            HStack(alignment: .top, spacing: 14) {
                if let kcal = s.activeEnergy {
                    EnergyCard(kcal: kcal, goal: s.energyGoal)
                }
                if let stand = s.standHours {
                    StandCard(hours: stand, goal: s.standGoal ?? 12)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if s.respiratoryRate != nil || s.oxygen != nil {
                BreathCard(rate: s.respiratoryRate, oxygen: s.oxygen)
            }
        }
    }

    private var privacyFooter: some View {
        Label {
            Text("Questi numeri sono letti sul tuo iPhone e non lasciano il telefono se non verso il server che hai scelto.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .padding(.horizontal, 6)
    }
}
