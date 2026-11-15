import SwiftUI
import WidgetKit
import AppIntents

private let coral = Color(red: 1.0, green: 0.36, blue: 0.36)
private let magenta = Color(red: 0.86, green: 0.16, blue: 0.47)

struct RecordEntry: TimelineEntry {
    let date: Date
}

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) { completion(RecordEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        completion(Timeline(entries: [RecordEntry(date: .now)], policy: .never))
    }
}

/// Widget "Registra" per Home e schermata di blocco: un tocco e parte la registrazione.
struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecordWidget", provider: RecordProvider()) { _ in
            RecordWidgetView()
                .widgetURL(AppLinks.record)
        }
        .configurationDisplayName("Registra")
        .description("Avvia una nuova registrazione con un tocco.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct RecordWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title2.weight(.semibold))
            }
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.circle.fill").font(.title)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Registra").font(.headline)
                    Text("Registratore AI").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        default:
            VStack(alignment: .leading) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Registra").font(.headline).foregroundStyle(.white)
                        Text("Tocca per iniziare").font(.caption2).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(magenta)
                        .frame(width: 44, height: 44)
                        .background(.white, in: Circle())
                }
            }
            .containerBackground(for: .widget) {
                LinearGradient(colors: [coral, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

/// Pulsante per il Centro di Controllo e la schermata di blocco.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "it.registratoreai.record-control") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Registra", systemImage: "mic.fill")
            }
        }
        .displayName("Nuova registrazione")
        .description("Avvia una registrazione con Registratore AI.")
    }
}
