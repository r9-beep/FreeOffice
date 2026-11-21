import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case colourful, dark, plain, plainDark
    var id: String { rawValue }
    var name: String { switch self { case .colourful: return "Colourful"; case .dark: return "Dark"; case .plain: return "Plain white"; case .plainDark: return "Plain dark" } }
    var scheme: ColorScheme { (self == .dark || self == .plainDark) ? .dark : .light }
    var isPlain: Bool { self == .plain || self == .plainDark }
    var symbol: String { switch self { case .colourful: return "paintpalette.fill"; case .dark: return "moon.fill"; case .plain: return "circle"; case .plainDark: return "circle.fill" } }
    /// How strongly the per-app colour tints glass cards.
    var tint: Double { isPlain ? 0.10 : 1 }
    var swatch: [Color] {
        switch self {
        case .colourful: return [Color(red: 1.0, green: 0.62, blue: 0.80), Color(red: 0.55, green: 0.65, blue: 1.0), Color(red: 0.55, green: 0.95, blue: 0.85)]
        case .dark: return [Color(white: 0.28), Color(red: 0.12, green: 0.12, blue: 0.30), Color(white: 0.05)]
        case .plain: return [.white, Color(white: 0.96), .white]
        case .plainDark: return [Color(white: 0.16), Color(white: 0.10), Color(white: 0.04)]
        }
    }
}

/// Compact theme switcher (sidebar footer): four swatches with the current theme named above.
struct ThemePicker: View {
    @EnvironmentObject var storage: Storage
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Theme · \(storage.theme.name)").font(.fo(.caption).weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(AppTheme.allCases) { t in
                        Button { withAnimation(.smooth(duration: 0.3)) { storage.theme = t } } label: {
                            Circle().fill(LinearGradient(colors: t.swatch, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 0.5))
                                .padding(8).contentShape(.circle)
                        }
                        .buttonStyle(.plain).help(t.name)
                        .glassEffect(storage.theme == t ? .regular.tint(.accentColor.opacity(0.45)).interactive() : .regular.interactive(), in: .circle)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
