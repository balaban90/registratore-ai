import SwiftUI

enum Theme {
    static let accent = Color(red: 0.851, green: 0.227, blue: 0.282)        // #D93A48
    static let accentText = Color(red: 0.784, green: 0.196, blue: 0.247)    // #C8323F (testo piccolo)
    static let accentSoft = Color(red: 0.992, green: 0.894, blue: 0.902)    // #FDE4E6
    static let accentDeep = Color(red: 0.620, green: 0.145, blue: 0.196)    // #9E2532
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.29)             // #FF6B4A
    static let magenta = Color(red: 0.761, green: 0.094, blue: 0.357)       // #C2185B
    static let highlight = Color(red: 1.0, green: 0.624, blue: 0.039)       // #FF9F0A
    static let recordGradient = LinearGradient(colors: [coral, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)

    struct Tile {
        let background: Color
        let foreground: Color
    }

    /// Colori della tessera in base al modello di riassunto.
    static func tile(for templateID: String?) -> Tile {
        switch templateID ?? "" {
        case "riunione", "verbale":
            return Tile(background: Color(red: 1.0, green: 0.894, blue: 0.878), foreground: Color(red: 0.706, green: 0.137, blue: 0.184))
        case "lezione":
            return Tile(background: Color(red: 0.89, green: 0.941, blue: 1.0), foreground: Color(red: 0.043, green: 0.31, blue: 0.69))
        case "telefonata", "colloquio":
            return Tile(background: Color(red: 0.886, green: 0.965, blue: 0.914), foreground: Color(red: 0.078, green: 0.424, blue: 0.22))
        case "brainstorming":
            return Tile(background: Color(red: 1.0, green: 0.957, blue: 0.839), foreground: Color(red: 0.478, green: 0.337, blue: 0.0))
        case "intervista":
            return Tile(background: Color(red: 0.953, green: 0.91, blue: 1.0), foreground: Color(red: 0.42, green: 0.129, blue: 0.659))
        default:
            return Tile(background: Color(.tertiarySystemFill), foreground: Color(.label))
        }
    }

    static func icon(for templateID: String?) -> String {
        guard let templateID, !templateID.isEmpty, templateID != "domanda" else { return "waveform" }
        return SummaryTemplate.all.first { $0.id == templateID }?.icon ?? "star"
    }
}

/// Pillola di stato (Riassunto, Trascritto, Da trascrivere).
struct StatusPill: View {
    let text: String
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }
}

/// Sfondo "vetro" per pulsanti e barre fluttuanti.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 26) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }

    func card(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}
