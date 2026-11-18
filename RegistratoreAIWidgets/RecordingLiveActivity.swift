import SwiftUI
import WidgetKit
import ActivityKit

private let coral = Color(red: 1.0, green: 0.36, blue: 0.36)

/// Dynamic Island e schermata di blocco: cronometro durante la registrazione,
/// poi l'avanzamento della lavorazione.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenActivityView(title: context.attributes.title, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AppLinks.open)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: state.phase).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeOrProgress(state: state).font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        Text(state.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if state.phase == .processing { ProcessingBar(state: state) }
                    }
                }
            } compactLeading: {
                PhaseIcon(phase: state.phase)
            } compactTrailing: {
                TimeOrProgress(state: state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                PhaseIcon(phase: state.phase)
            }
            .widgetURL(AppLinks.open)
            .keylineTint(coral)
        }
    }
}

struct PhaseIcon: View {
    let phase: RecordingActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .recording: Image(systemName: "mic.fill").foregroundStyle(coral)
        case .paused: Image(systemName: "pause.fill").foregroundStyle(.orange)
        case .processing: Image(systemName: "waveform").foregroundStyle(coral)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

struct TimeOrProgress: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        case .paused:
            Text(Self.format(state.pausedElapsed))
        case .processing:
            if let window = state.progressWindow {
                // Tempo che manca, stimato: scende da solo secondo per secondo.
                Text(timerInterval: window, countsDown: true)
                    .multilineTextAlignment(.trailing)
            } else if let p = state.progress {
                Text("\(Int(p * 100))%")
            } else {
                Text("…")
            }
        case .done:
            Text("Pronta")
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct LockScreenActivityView: View {
    let title: String
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            PhaseIcon(phase: state.phase)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(state.status).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                if state.phase == .processing { ProcessingBar(state: state) }
            }
            Spacer(minLength: 4)
            TimeOrProgress(state: state)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: 90, alignment: .trailing)
        }
    }
}

/// Barra della lavorazione: con una stima di inizio e fine avanza da sola (la disegna iOS),
/// altrimenti mostra l'ultimo valore ricevuto.
struct ProcessingBar: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if let window = state.progressWindow {
            ProgressView(timerInterval: window, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(coral)
        } else if let p = state.progress {
            ProgressView(value: p).tint(coral)
        }
    }
}
