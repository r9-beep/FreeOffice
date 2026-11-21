import SwiftUI
import AppKit

/// Every font family installed on this Mac (system, user and Adobe/third-party fonts included).
enum FontLibrary {
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

/// A button that shows the current font (in that font) and opens a searchable list of all installed families.
struct FontPickerButton: View {
    @Binding var selection: String
    var allowDefault = false
    var width: CGFloat? = nil
    var footer: AnyView? = nil
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? "Default font" : selection).font(.custom(selection.isEmpty ? "Helvetica Neue" : selection, size: 13)).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.fo(.caption2)).foregroundStyle(.secondary)
            }
            .frame(width: width)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FontList(selection: $selection, allowDefault: allowDefault, footer: footer) { open = false }
        }
        .help("Font")
    }
}

struct FontList: View {
    @Binding var selection: String
    var allowDefault: Bool
    var footer: AnyView?
    var done: () -> Void
    @State private var search = ""

    var filtered: [String] { search.isEmpty ? FontLibrary.families : FontLibrary.families.filter { $0.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(FontLibrary.families.count) fonts", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            ScrollViewReader { proxy in
                List {
                    if allowDefault && search.isEmpty {
                        row("", label: "Default font")
                    }
                    ForEach(filtered, id: \.self) { f in row(f, label: f).id(f) }
                }
                .listStyle(.plain)
                .onAppear { if !selection.isEmpty { proxy.scrollTo(selection, anchor: .center) } }
            }
            if let footer { Divider(); footer.padding(10) }
        }
        .frame(width: 320, height: 420)
    }

    func row(_ family: String, label: String) -> some View {
        Button { selection = family; done() } label: {
            HStack {
                Text(label).font(family.isEmpty ? .fo(.body) : .custom(family, size: 17)).lineLimit(1)
                Spacer()
                if selection == family { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// FreeOffice's house typeface: Helvetica Neue (installed on every Mac; referenced, never bundled or modified).
extension Font {
    static func fo(size: CGFloat, weight: Font.Weight = .regular) -> Font { .custom("Helvetica Neue", size: size).weight(weight) }
    static func fo(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: return fo(size: 26)
        case .title: return fo(size: 22)
        case .title2: return fo(size: 17)
        case .title3: return fo(size: 15)
        case .headline: return fo(size: 13, weight: .semibold)
        case .subheadline: return fo(size: 11)
        case .body: return fo(size: 13)
        case .callout: return fo(size: 12)
        case .footnote: return fo(size: 10)
        case .caption, .caption2: return fo(size: 10)
        @unknown default: return fo(size: 13)
        }
    }
}
