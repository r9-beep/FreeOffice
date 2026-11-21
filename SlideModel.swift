import SwiftUI
import AppKit

let slideW = 960.0, slideH = 540.0

// MARK: themes (colours and fonts that restyle the whole deck)

struct SlideTheme: Identifiable, Equatable {
    let id: String, name: String
    let bg: String, fg: String, accent: String, muted: String
    let heading: String, body: String
}
let slideThemes: [SlideTheme] = [
    SlideTheme(id: "light", name: "Light", bg: "#ffffff", fg: "#111111", accent: "#3b6cf6", muted: "#6b7280", heading: "Helvetica Neue", body: "Helvetica Neue"),
    SlideTheme(id: "dark", name: "Midnight", bg: "#14213d", fg: "#ffffff", accent: "#6b8cff", muted: "#aab4d4", heading: "Helvetica Neue", body: "Helvetica Neue"),
    SlideTheme(id: "accent", name: "Bold blue", bg: "#3b6cf6", fg: "#ffffff", accent: "#ffd166", muted: "#dbe4ff", heading: "Helvetica Neue", body: "Helvetica Neue"),
    SlideTheme(id: "sunset", name: "Sunset", bg: "#2b1b3d", fg: "#fff1e6", accent: "#ff8a5b", muted: "#cdb8e0", heading: "Futura", body: "Helvetica Neue"),
    SlideTheme(id: "forest", name: "Forest", bg: "#10291f", fg: "#e6f4ea", accent: "#52b788", muted: "#a3c9b4", heading: "Georgia", body: "Helvetica Neue"),
    SlideTheme(id: "paper", name: "Paper", bg: "#f6f1e7", fg: "#2b2b2b", accent: "#b5532a", muted: "#7a7266", heading: "Georgia", body: "Georgia"),
    SlideTheme(id: "mono", name: "Mono", bg: "#ffffff", fg: "#000000", accent: "#000000", muted: "#6b6b6b", heading: "Courier New", body: "Courier New"),
    SlideTheme(id: "neon", name: "Neon", bg: "#0b0b12", fg: "#ecebff", accent: "#00f5d4", muted: "#9a98c9", heading: "Futura", body: "Helvetica Neue"),
]
func themeFor(_ id: String) -> SlideTheme { slideThemes.first { $0.id == id } ?? slideThemes[0] }

/// Colour tokens used inside slides: "fg", "accent", "muted", "bg" follow the theme; anything else is a hex colour.
func slideHex(_ c: String, _ t: SlideTheme) -> String {
    switch c { case "fg": return t.fg; case "accent": return t.accent; case "muted": return t.muted; case "bg": return t.bg; default: return c }
}
func slideColor(_ c: String, _ t: SlideTheme) -> Color { c.isEmpty ? .clear : Color(hex: slideHex(c, t)) }
func slideFont(_ f: String, _ t: SlideTheme) -> String { f == "@heading" ? t.heading : f == "@body" || f.isEmpty ? t.body : f }

// MARK: model types

struct Slide: Identifiable, Equatable {
    var id = UUID()
    var els: [PEl] = []
    var bg = ""                // "" = theme background, otherwise a hex colour
    var notes = ""
    var transition = ""        // "" = deck default
}
struct DeckSettings: Equatable { var theme = "light"; var footer = ""; var numbers = false; var transition = "fade" }
struct DeckState: Equatable { var slides: [Slide]; var deck: DeckSettings }

// MARK: layouts

enum SlideLayout: String, CaseIterable, Identifiable {
    case title, content, section, two, image, statement, quote, blank
    var id: String { rawValue }
    var name: String {
        switch self { case .title: return "Title"; case .content: return "Title & bullets"; case .section: return "Section"; case .two: return "Two columns"
        case .image: return "Text & image"; case .statement: return "Big statement"; case .quote: return "Quote"; case .blank: return "Blank" }
    }
    var symbol: String {
        switch self { case .title: return "textformat.size.larger"; case .content: return "list.bullet.rectangle"; case .section: return "rectangle.lefthalf.filled"; case .two: return "rectangle.split.2x1"
        case .image: return "photo.on.rectangle"; case .statement: return "text.quote"; case .quote: return "quote.opening"; case .blank: return "rectangle" }
    }
}

private func T(_ id: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ text: String, _ size: Double, bold: Bool = false, font: String = "@body", color: String = "fg",
               align: String = "left", valign: String = "top", bullets: Bool = false, italic: Bool = false) -> PEl {
    var e = PEl(id: id, type: "text", x: x, y: y, w: w, h: h); e.text = text; e.size = size; e.bold = bold; e.font = font; e.color = color; e.align = align; e.valign = valign; e.bullets = bullets; e.italic = italic; return e
}
private func R(_ id: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: String = "accent", rad: Double = 0) -> PEl {
    var e = PEl(id: id, type: "rect", x: x, y: y, w: w, h: h); e.fill = fill; e.rad = rad; return e
}

func layoutElements(_ l: SlideLayout) -> [PEl] {
    switch l {
    case .title: return [R(1, 80, 168, 90, 8), T(2, 80, 190, 800, 130, "Presentation title", 58, bold: true, font: "@heading", valign: "bottom"), T(3, 80, 334, 800, 70, "Subtitle or speaker name", 26, color: "muted")]
    case .content: return [T(1, 64, 44, 832, 80, "Slide title", 40, bold: true, font: "@heading", valign: "middle"), R(2, 64, 128, 64, 5), T(3, 64, 156, 832, 320, "First point\nSecond point\nThird point", 28, bullets: true)]
    case .section: return [R(1, 0, 0, 22, 540), T(2, 80, 190, 800, 160, "Section title", 64, bold: true, font: "@heading", valign: "middle"), T(3, 80, 360, 800, 50, "A short line to introduce it", 24, color: "muted")]
    case .two: return [T(1, 64, 44, 832, 80, "Slide title", 40, bold: true, font: "@heading", valign: "middle"), R(2, 64, 128, 64, 5),
                       T(3, 64, 156, 400, 320, "Left column\nPoint one\nPoint two", 24, bullets: true), T(4, 496, 156, 400, 320, "Right column\nPoint one\nPoint two", 24, bullets: true)]
    case .image: var img = PEl(id: 4, type: "image", x: 520, y: 156, w: 376, h: 320); img.src = ""
        return [T(1, 64, 44, 832, 80, "Slide title", 40, bold: true, font: "@heading", valign: "middle"), R(2, 64, 128, 64, 5), T(3, 64, 156, 420, 320, "Describe the image\nKey point\nAnother point", 26, bullets: true), img]
    case .statement: return [T(1, 100, 130, 760, 280, "One big idea, said simply.", 58, bold: true, font: "@heading", align: "center", valign: "middle")]
    case .quote: return [T(1, 100, 120, 760, 240, "“A quote worth putting on a slide.”", 44, font: "@heading", align: "center", valign: "middle", italic: true), T(2, 100, 380, 760, 50, "— Someone memorable", 24, color: "accent", align: "center")]
    case .blank: return []
    }
}

/// A slide dictionary for templates: a layout with its text elements filled in order.
func templateSlide(_ l: SlideLayout, _ texts: [String], notes: String = "", bg: String = "") -> [String: Any] {
    var els = layoutElements(l); var k = 0
    for i in els.indices where els[i].type == "text" { if k < texts.count { els[i].text = texts[k] }; k += 1 }
    return ["els": els.map(\.dict), "bg": bg, "notes": notes, "transition": ""]
}

// MARK: the editing model

final class SlidesModel: ObservableObject, CanvasHost {
    let history = UndoHistory<DeckState>()
    @Published var title: String { didSet { if ready { saver.touch() } } }
    @Published var slides: [Slide] { didSet { if ready { history.record(DeckState(slides: oldValue, deck: deck)); saver.touch() } } }
    @Published var deck: DeckSettings { didSet { if ready { history.record(DeckState(slides: slides, deck: oldValue)); saver.touch() } } }
    @Published var selected: UUID?
    @Published var sel: Int?
    @Published var editing: Int?
    @Published var savedAt: Date?
    @Published var notesOpen = true
    let images = ImageCache()
    let saver: AutoSaver
    private var ready = false

    init(id: String, dir: URL) {
        saver = AutoSaver(url: docURL(dir, "slides", id))
        var t = "", s: [Slide] = [], d = DeckSettings()
        if let data = try? Data(contentsOf: saver.url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            t = (o["title"] as? String) ?? ""
            d.theme = (o["theme"] as? String) ?? "light"; d.footer = (o["footer"] as? String) ?? ""; d.numbers = (o["numbers"] as? Bool) ?? false; d.transition = (o["transition"] as? String) ?? "fade"
            s = ((o["slides"] as? [[String: Any]]) ?? []).map { SlidesModel.parseSlide($0) }
        }
        if s.isEmpty { s = [Slide(els: layoutElements(.title))] }
        title = t; slides = s; deck = d; selected = s[0].id
        ready = true
        saver.make = { [weak self] in self?.encode() }
        saver.onSaved = { [weak self] in self?.savedAt = Date() }
    }

    /// Reads the current format, and converts older slides ({t, b, theme, font}) into free-form elements.
    static func parseSlide(_ o: [String: Any]) -> Slide {
        if let arr = o["els"] as? [[String: Any]] {
            return Slide(els: arr.compactMap(PEl.init), bg: (o["bg"] as? String) ?? "", notes: (o["notes"] as? String) ?? "", transition: (o["transition"] as? String) ?? "")
        }
        let legacyTheme = (o["theme"] as? String) ?? "", font = (o["font"] as? String) ?? ""
        var s = Slide(els: layoutElements(.content))
        s.els[0].text = (o["t"] as? String) ?? ""; s.els[2].text = (o["b"] as? String) ?? ""; s.els[2].bullets = false
        s.els[2].size = 26
        if legacyTheme == "dark" { s.bg = "#14213d" } else if legacyTheme == "accent" { s.bg = "#3b6cf6" }
        if legacyTheme == "dark" || legacyTheme == "accent" { for i in s.els.indices where s.els[i].type == "text" { s.els[i].color = "#ffffff" } }
        if !font.isEmpty { for i in s.els.indices where s.els[i].type == "text" { s.els[i].font = font } }
        return s
    }
    func encode() -> Data? {
        let texts = { (s: Slide) in s.els.filter { $0.type == "text" }.map(\.text) }
        let arr: [[String: Any]] = slides.map { s in
            let t = texts(s)
            return ["els": s.els.map(\.dict), "bg": s.bg, "notes": s.notes, "transition": s.transition, "t": t.first ?? "", "b": t.count > 1 ? t[1...].joined(separator: "\n") : "", "theme": ""]   // t/b keep older readers working
        }
        let o: [String: Any] = ["title": title, "theme": deck.theme, "footer": deck.footer, "numbers": deck.numbers, "transition": deck.transition, "slides": arr, "modified": nowMillis()]
        return try? JSONSerialization.data(withJSONObject: o)
    }

    // MARK: CanvasHost
    var cur: Int { slides.firstIndex { $0.id == selected } ?? 0 }
    var theme: SlideTheme { themeFor(deck.theme) }
    var els: [PEl] { get { slides[cur].els } set { slides[cur].els = newValue } }
    var bgColor: String { slides[cur].bg.isEmpty ? "bg" : slides[cur].bg }
    var page: (w: Double, h: Double) { (slideW, slideH) }
    var defaultTextColor: String { "fg" }
    var defaultFont: String { "@body" }
    var defaultFill: String { "accent" }
    var defaultStroke: String { "accent" }
    func resolveColor(_ c: String) -> Color { slideColor(c, theme) }
    func resolveFont(_ f: String) -> String { slideFont(f, theme) }
    var overlayContent: AnyView { AnyView(SlideChrome(footer: deck.footer, number: deck.numbers ? cur + 1 : nil, color: Color(hex: theme.muted))) }

    // MARK: slide operations
    func addSlide(_ layout: SlideLayout) {
        let s = Slide(els: layoutElements(layout)); slides.insert(s, at: cur + 1); selected = s.id; sel = nil; editing = nil
    }
    func duplicateSlide() { var s = slides[cur]; s.id = UUID(); slides.insert(s, at: cur + 1); selected = s.id; sel = nil }
    func deleteSlide() {
        guard slides.count > 1 else { return }
        let i = cur; slides.remove(at: i); selected = slides[min(i, slides.count - 1)].id; sel = nil; editing = nil
    }
    func setBackground(_ hex: String) { slides[cur].bg = hex }
    func setTransition(_ t: String) { slides[cur].transition = t }
    var notesBinding: Binding<String> { Binding(get: { self.slides[self.cur].notes }, set: { self.slides[self.cur].notes = $0 }) }

    // MARK: undo / redo
    func undo() { if let s = history.undo(current: DeckState(slides: slides, deck: deck)) { apply(s) } }
    func redo() { if let s = history.redo(current: DeckState(slides: slides, deck: deck)) { apply(s) } }
    private func apply(_ s: DeckState) {
        let i = cur; history.applying = true; slides = s.slides; deck = s.deck; history.applying = false
        if !slides.contains(where: { $0.id == selected }) { selected = slides[min(i, slides.count - 1)].id }
        if !els.contains(where: { $0.id == sel }) { sel = nil }; editing = nil
    }
}

/// Footer text and slide number, drawn over every slide.
struct SlideChrome: View {
    let footer: String, number: Int?, color: Color
    var body: some View {
        HStack {
            Text(footer); Spacer(); if let n = number { Text("\(n)") }
        }
        .font(.fo(size: 14)).foregroundStyle(color).padding(.horizontal, 44).padding(.bottom, 16)
        .frame(width: slideW, height: slideH, alignment: .bottom).allowsHitTesting(false)
    }
}

/// A read-only host for thumbnails, the presenter and exports.
final class StaticSlideHost: CanvasHost {
    var els: [PEl]
    var sel: Int?
    var editing: Int?
    let slide: Slide, deck: DeckSettings, number: Int
    let images: ImageCache
    init(slide: Slide, deck: DeckSettings, number: Int, images: ImageCache) { self.slide = slide; self.deck = deck; self.number = number; self.images = images; els = slide.els }
    var theme: SlideTheme { themeFor(deck.theme) }
    var bgColor: String { slide.bg.isEmpty ? "bg" : slide.bg }
    var page: (w: Double, h: Double) { (slideW, slideH) }
    func resolveColor(_ c: String) -> Color { slideColor(c, theme) }
    func resolveFont(_ f: String) -> String { slideFont(f, theme) }
    var overlayContent: AnyView { AnyView(SlideChrome(footer: deck.footer, number: deck.numbers ? number : nil, color: Color(hex: theme.muted))) }
}

/// A slide drawn at any width.
struct SlideThumb: View {
    let slide: Slide, deck: DeckSettings, number: Int, images: ImageCache
    var width: CGFloat
    var body: some View {
        CanvasPage(m: StaticSlideHost(slide: slide, deck: deck, number: number, images: images), interactive: false)
            .scaleEffect(width / slideW, anchor: .topLeading)
            .frame(width: width, height: width * slideH / slideW, alignment: .topLeading)
            .clipped()
    }
}
