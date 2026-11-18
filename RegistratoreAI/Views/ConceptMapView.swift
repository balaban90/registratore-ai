import SwiftUI

/// Mappa dei concetti letta dal testo dell'elaborazione "Mappa dei concetti":
/// `# tema`, `## ramo`, `- idea`, e in fondo `## Collegamenti` con righe "A → B: perché".
struct ConceptMap: Equatable {
    struct Branch: Equatable, Identifiable {
        let id: Int
        var title: String
        var ideas: [String]
    }

    struct Link: Equatable, Identifiable {
        let id: Int
        var from: String
        var to: String
        var why: String
    }

    var center: String
    var branches: [Branch]
    var links: [Link]

    /// nil se il testo non ha la forma di una mappa (es. elaborazione vecchia o scritta male):
    /// in quel caso si mostra il testo normale.
    static func parse(_ text: String) -> ConceptMap? {
        var center = ""
        var branches: [Branch] = []
        var links: [Link] = []
        var inLinks = false

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let title = clean(String(line.drop(while: { $0 == "#" })))
                guard !title.isEmpty else { continue }
                if level == 1 && center.isEmpty {
                    center = title
                    continue
                }
                if title.lowercased().hasPrefix("collegament") {
                    inLinks = true
                    continue
                }
                inLinks = false
                branches.append(Branch(id: branches.count, title: title, ideas: []))
                continue
            }
            var body = line
            for marker in ["- ", "* ", "• ", "– "] where body.hasPrefix(marker) {
                body = String(body.dropFirst(marker.count))
                break
            }
            if let dot = body.firstIndex(of: "."), !body[..<dot].isEmpty, body[..<dot].allSatisfy(\.isNumber) {
                body = String(body[body.index(after: dot)...])
            }
            body = clean(body)
            guard !body.isEmpty else { continue }
            if inLinks {
                if let link = parseLink(body, id: links.count) { links.append(link) }
                continue
            }
            if branches.isEmpty {
                // Testo prima del primo ramo: se manca il tema, lo usa come tema.
                if center.isEmpty { center = body }
                continue
            }
            branches[branches.count - 1].ideas.append(body)
        }
        branches.removeAll { $0.title.isEmpty }
        guard branches.count >= 2 else { return nil }
        if center.isEmpty { center = "Mappa dei concetti" }
        return ConceptMap(center: center, branches: branches, links: links)
    }

    private static func parseLink(_ text: String, id: Int) -> Link? {
        let arrows = ["→", "->", "⇒", "=>"]
        guard let arrow = arrows.first(where: { text.contains($0) }),
              let range = text.range(of: arrow) else { return nil }
        let from = clean(String(text[..<range.lowerBound]))
        var rest = String(text[range.upperBound...])
        var why = ""
        if let colon = rest.firstIndex(of: ":") {
            why = clean(String(rest[rest.index(after: colon)...]))
            rest = String(rest[..<colon])
        }
        let to = clean(rest)
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return Link(id: id, from: from, to: to, why: why)
    }

    /// Toglie i simboli del Markdown (grassetto, corsivo, codice).
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_")))
    }
}

/// Colori dei rami: ognuno ha il suo, come nelle mappe di Plaud.
enum ConceptMapPalette {
    static let colors: [Color] = [
        Color(red: 0.0, green: 0.478, blue: 1.0),     // blu
        Color(red: 0.204, green: 0.78, blue: 0.349),  // verde
        Color(red: 1.0, green: 0.584, blue: 0.0),     // arancio
        Color(red: 0.686, green: 0.322, blue: 0.871), // viola
        Color(red: 0.188, green: 0.69, blue: 0.78),   // azzurro
        Color(red: 1.0, green: 0.176, blue: 0.333),   // rosa
        Color(red: 0.635, green: 0.518, blue: 0.369)  // marrone
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

private struct NodeAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Il disegno della mappa: tema a sinistra, rami al centro, idee a destra, uniti da linee curve.
/// Toccando un ramo si chiudono o si riaprono le sue idee.
struct ConceptMapCanvas: View {
    let map: ConceptMap
    @Binding var collapsed: Set<Int>
    var compact: Bool = false

    private var ideaWidth: CGFloat { compact ? 190 : 240 }
    private var branchWidth: CGFloat { compact ? 140 : 170 }
    private var centerWidth: CGFloat { compact ? 120 : 150 }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 28 : 40) {
            Text(map.center)
                .font((compact ? Font.subheadline : .headline).weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: centerWidth)
                .background(Theme.recordGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .anchorPreference(key: NodeAnchorKey.self, value: .bounds) { ["c": $0] }
                .accessibilityLabel("Tema: \(map.center)")

            VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                ForEach(map.branches) { branch in
                    branchRow(branch)
                }
            }
        }
        .padding(compact ? 12 : 24)
        .backgroundPreferenceValue(NodeAnchorKey.self) { anchors in
            GeometryReader { proxy in
                connectors(anchors, in: proxy)
            }
        }
    }

    private func branchRow(_ branch: ConceptMap.Branch) -> some View {
        let color = ConceptMapPalette.color(branch.id)
        let isCollapsed = collapsed.contains(branch.id)
        return HStack(alignment: .center, spacing: compact ? 24 : 34) {
            Button {
                withAnimation(.snappy) {
                    if isCollapsed { collapsed.remove(branch.id) } else { collapsed.insert(branch.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(branch.title)
                        .font((compact ? Font.footnote : .subheadline).weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if isCollapsed && !branch.ideas.isEmpty {
                        Text("\(branch.ideas.count)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.25), in: Capsule())
                    }
                }
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: branchWidth, alignment: .leading)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(color.opacity(0.55), lineWidth: 1.2)
                )
            }
            .buttonStyle(.plain)
            .anchorPreference(key: NodeAnchorKey.self, value: .bounds) { ["b\(branch.id)": $0] }
            .accessibilityLabel("Ramo: \(branch.title)")
            .accessibilityHint(isCollapsed ? "Mostra le idee" : "Nasconde le idee")

            if !isCollapsed && !branch.ideas.isEmpty {
                VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    ForEach(Array(branch.ideas.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(compact ? .caption : .footnote)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(width: ideaWidth, alignment: .leading)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
                            )
                            .anchorPreference(key: NodeAnchorKey.self, value: .bounds) { ["i\(branch.id)-\(item.offset)": $0] }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
    }

    private func connectors(_ anchors: [String: Anchor<CGRect>], in proxy: GeometryProxy) -> some View {
        ZStack {
            if let c = anchors["c"].map({ proxy[$0] }) {
                ForEach(map.branches) { branch in
                    if let b = anchors["b\(branch.id)"].map({ proxy[$0] }) {
                        let color = ConceptMapPalette.color(branch.id)
                        curve(from: CGPoint(x: c.maxX, y: c.midY), to: CGPoint(x: b.minX, y: b.midY))
                            .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        if !collapsed.contains(branch.id) {
                            ForEach(branch.ideas.indices, id: \.self) { j in
                                if let i = anchors["i\(branch.id)-\(j)"].map({ proxy[$0] }) {
                                    curve(from: CGPoint(x: b.maxX, y: b.midY), to: CGPoint(x: i.minX, y: i.midY))
                                        .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func curve(from a: CGPoint, to b: CGPoint) -> Path {
        Path { p in
            p.move(to: a)
            let dx = max(12, (b.x - a.x) * 0.55)
            p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        }
    }
}

/// Collegamenti tra i rami, sotto la mappa.
struct ConceptLinksView: View {
    let map: ConceptMap

    private func color(for name: String) -> Color {
        let n = name.lowercased()
        if let b = map.branches.first(where: { $0.title.lowercased() == n || $0.title.lowercased().contains(n) || n.contains($0.title.lowercased()) }) {
            return ConceptMapPalette.color(b.id)
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collegamenti")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(map.links) { link in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(link.from).foregroundStyle(color(for: link.from))
                        Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        Text(link.to).foregroundStyle(color(for: link.to))
                    }
                    .font(.footnote.weight(.semibold))
                    if !link.why.isEmpty {
                        Text(link.why).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Anteprima dentro la scheda dell'elaborazione: si scorre di lato, e si apre a tutto schermo.
struct ConceptMapCard: View {
    let map: ConceptMap
    let title: String
    let onShare: ([Any]) -> Void
    @State private var collapsed: Set<Int> = []
    @State private var fullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                ConceptMapCanvas(map: map, collapsed: $collapsed, compact: true)
            }
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("concept-map")

            Button {
                fullScreen = true
            } label: {
                Label("Apri la mappa", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)

            if !map.links.isEmpty {
                ConceptLinksView(map: map)
            }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            ConceptMapFullScreen(map: map, title: title, onShare: onShare)
        }
    }
}

/// Mappa a tutto schermo: si sposta con il dito e si ingrandisce con due dita.
struct ConceptMapFullScreen: View {
    let map: ConceptMap
    let title: String
    let onShare: ([Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var collapsed: Set<Int> = []
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var contentSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                ConceptMapCanvas(map: map, collapsed: $collapsed)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: max(1, contentSize.width * scale), height: max(1, contentSize.height * scale),
                           alignment: .topLeading)
            }
            .defaultScrollAnchor(.leading)
            .background(Color(.systemGroupedBackground))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(2.5, max(0.4, baseScale * value.magnification)) }
                    .onEnded { _ in baseScale = scale }
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy) {
                            if collapsed.isEmpty { collapsed = Set(map.branches.map(\.id)) } else { collapsed = [] }
                        }
                    } label: {
                        Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    }
                    .accessibilityLabel(collapsed.isEmpty ? "Chiudi tutti i rami" : "Apri tutti i rami")
                    Button {
                        if let url = image() { onShare([url]) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Condividi la mappa come immagine")
                }
            }
        }
    }

    /// La mappa intera come immagine PNG, da condividere o salvare in Foto.
    @MainActor
    private func image() -> URL? {
        let content = ConceptMapCanvas(map: map, collapsed: .constant(collapsed))
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mappa – \(safe.prefix(60)).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
