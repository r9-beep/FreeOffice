import SwiftUI
import AppKit

let posterSizes: [(name: String, w: Double, h: Double)] = [
    ("A4 portrait", 794, 1123), ("A4 landscape", 1123, 794), ("A3 portrait", 1123, 1587), ("US Letter", 816, 1056),
    ("Square 1080", 1080, 1080), ("Banner 1500×500", 1500, 500), ("Wide 1920×1080", 1920, 1080),
]

struct PosterState { var els: [PEl]; var bg: String; var sizeName: String }

final class PosterModel: ObservableObject, CanvasHost {
    let history = UndoHistory<PosterState>()
    @Published var title: String { didSet { if ready { saver.touch() } } }
    @Published var sizeName: String { didSet { if ready { history.record(PosterState(els: els, bg: bg, sizeName: oldValue)); saver.touch() } } }
    @Published var bg: String { didSet { if ready { history.record(PosterState(els: els, bg: oldValue, sizeName: sizeName)); saver.touch() } } }
    @Published var els: [PEl] { didSet { if ready { history.record(PosterState(els: oldValue, bg: bg, sizeName: sizeName)); saver.touch() } } }
    @Published var sel: Int?
    @Published var editing: Int?
    @Published var zoom: Double = 0          // 0 = fit
    @Published var savedAt: Date?
    let images = ImageCache()
    let saver: AutoSaver
    private var ready = false

    init(id: String, dir: URL) {
        saver = AutoSaver(url: docURL(dir, "poster", id))
        var t = "", sz = "A4 portrait", b = "#ffffff", e: [PEl] = []
        var loaded = false
        if let d = try? Data(contentsOf: saver.url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            loaded = true
            t = (o["title"] as? String) ?? ""; sz = (o["size"] as? String) ?? sz; b = (o["bg"] as? String) ?? b
            e = ((o["els"] as? [[String: Any]]) ?? []).compactMap(PEl.init)
        }
        if !loaded {
            var r = PEl(id: 1, type: "rect", x: 0, y: 0, w: 794, h: 380); r.fill = "#111111"
            var h = PEl(id: 2, type: "text", x: 60, y: 120, w: 674, h: 160); h.text = "Your poster title"; h.size = 84; h.bold = true; h.color = "#ffffff"
            var p = PEl(id: 3, type: "text", x: 60, y: 440, w: 674, h: 200); p.text = "Select any item to edit it in the panel on the right.\nDouble-click text to type on the poster."; p.size = 28; p.font = "Georgia"
            e = [r, h, p]
        }
        title = t; sizeName = sz; bg = b; els = e
        if let s = ProcessInfo.processInfo.environment["FO_SEL"], let i = Int(s) { sel = i }
        ready = true
        saver.make = { [weak self] in
            guard let m = self else { return nil }
            let o: [String: Any] = ["title": m.title, "size": m.sizeName, "bg": m.bg, "els": m.els.map(\.dict), "modified": nowMillis()]
            return try? JSONSerialization.data(withJSONObject: o)
        }
        saver.onSaved = { [weak self] in self?.savedAt = Date() }
    }

    var bgColor: String { bg }
    var page: (w: Double, h: Double) { let s = posterSizes.first { $0.name == sizeName } ?? posterSizes[0]; return (s.w, s.h) }
    func undo() { if let s = history.undo(current: PosterState(els: els, bg: bg, sizeName: sizeName)) { apply(s) } }
    func redo() { if let s = history.redo(current: PosterState(els: els, bg: bg, sizeName: sizeName)) { apply(s) } }
    private func apply(_ s: PosterState) { history.applying = true; els = s.els; bg = s.bg; sizeName = s.sizeName; history.applying = false; if !els.contains(where: { $0.id == sel }) { sel = nil } }

    // MARK: export
    @MainActor func exportPNG() {
        guard let u = savePanel((title.isEmpty ? "poster" : title) + ".png") else { return }
        let r = ImageRenderer(content: CanvasPage(m: self, interactive: false)); r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: u) }
    }
    @MainActor func exportPDF() {
        guard let u = savePanel((title.isEmpty ? "poster" : title) + ".pdf") else { return }
        let r = ImageRenderer(content: CanvasPage(m: self, interactive: false))
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
    }
    func exportHTML() {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let (w, h) = page
        let html = "<!doctype html><meta charset=\"utf-8\"><title>\(esc(title))</title><body style=\"margin:0;background:#888\">" + Self.pageHTML(els, bg: bg, w: w, h: h, resolveColor: { $0 }, resolveFont: { $0 }) + "</body>"
        if let u = savePanel((title.isEmpty ? "poster" : title) + ".html") { try? html.write(to: u, atomically: true, encoding: .utf8) }
    }

    /// One page as absolutely-positioned HTML (used by Poster and Slides exports).
    static func pageHTML(_ els: [PEl], bg: String, w: Double, h: Double, resolveColor: (String) -> String, resolveFont: (String) -> String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let body = els.map { e -> String in
            var css = "position:absolute;box-sizing:border-box;left:\(e.x)px;top:\(e.y)px;width:\(e.w)px;height:\(e.h)px;"
            switch e.type {
            case "text":
                let lines = e.bullets ? e.text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : "•  " + $0 }.joined(separator: "\n") : e.text
                let justify = e.valign == "middle" ? "center" : e.valign == "bottom" ? "flex-end" : "flex-start"
                return "<div style=\"\(css)display:flex;flex-direction:column;justify-content:\(justify);overflow:hidden;font:\(e.italic ? "italic " : "")\(e.bold ? 700 : 400) \(e.size)px/1.2 '\(resolveFont(e.font))',Helvetica,sans-serif;color:\(resolveColor(e.color));text-align:\(e.align);\(e.fill.isEmpty ? "" : "background:\(resolveColor(e.fill));")\"><div style=\"white-space:pre-wrap\">\(esc(lines))</div></div>"
            case "rect", "ellipse":
                css += "background:\(e.fill.isEmpty ? "transparent" : resolveColor(e.fill));border:\(e.sw)px solid \(e.stroke.isEmpty ? "transparent" : resolveColor(e.stroke));border-radius:\(e.type == "ellipse" ? "50%" : "\(e.rad)px");"
                return "<div style=\"\(css)\"></div>"
            case "line": return "<div style=\"\(css)height:0;border-top:\(e.sw)px solid \(resolveColor(e.stroke))\"></div>"
            default: return "<img src=\"\(e.src)\" style=\"\(css)object-fit:cover\">"
            }
        }.joined()
        return "<div style=\"position:relative;width:\(w)px;height:\(h)px;background:\(resolveColor(bg));overflow:hidden\">\(body)</div>"
    }
}

// MARK: - Editor

struct PosterEditorView: View {
    @StateObject private var m: PosterModel
    let docTab: Tab
    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? PosterModel) ?? { let x = PosterModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        HStack(spacing: 0) {
            CanvasSurface(m: m, zoom: m.zoom)
            ElementInspector(m: m) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PAGE").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    ColorPicker("Background", selection: Binding(get: { Color(hex: m.bg) }, set: { m.bg = $0.hexString }))
                    if let s = m.savedAt { Text("Saved \(s, format: .dateTime.hour().minute())").font(.fo(.caption)).foregroundStyle(.secondary) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled poster", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.addDefault("text") } label: { Label("Text", systemImage: "textformat") }
                Button { m.addDefault("rect") } label: { Label("Box", systemImage: "rectangle") }
                Button { m.addDefault("ellipse") } label: { Label("Ellipse", systemImage: "circle") }
                Button { m.addDefault("line") } label: { Label("Line", systemImage: "line.diagonal") }
                Button { m.addImage() } label: { Label("Image", systemImage: "photo") }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                Menu {
                    Picker("Page", selection: $m.sizeName) { ForEach(posterSizes, id: \.name) { Text($0.name).tag($0.name) } }
                    Divider()
                    Picker("Zoom", selection: $m.zoom) { Text("Fit").tag(0.0); Text("50%").tag(0.5); Text("75%").tag(0.75); Text("100%").tag(1.0); Text("150%").tag(1.5) }
                } label: { Label("Page", systemImage: "doc.richtext") }
                Menu {
                    Button("PNG image…") { m.exportPNG() }; Button("PDF…") { m.exportPDF() }; Button("HTML…") { m.exportHTML() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled poster" : t }
        .onAppear { docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() } }
        .onDisappear { m.saver.flush() }
    }
}
