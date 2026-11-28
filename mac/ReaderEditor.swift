// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// Reader: open, mark up, fill in, sign and tidy PDFs. The PDF lives beside the document file (office__reader__<id>.pdf),
// so marking up never touches your original, and it syncs with FreeOffice Cloud like everything else.

enum ReaderTool { case select, note, text, ink, sign }

struct AnnItem: Identifiable {
    let id = UUID()
    let page: Int, kind: String, excerpt: String
    let annotation: PDFAnnotation
}

let readerHighlightColors: [(String, NSColor)] = [("Yellow", NSColor(red: 1, green: 0.92, blue: 0.3, alpha: 1)), ("Green", NSColor(red: 0.55, green: 0.9, blue: 0.5, alpha: 1)), ("Blue", NSColor(red: 0.5, green: 0.75, blue: 1, alpha: 1)),
                                                  ("Pink", NSColor(red: 1, green: 0.6, blue: 0.8, alpha: 1)), ("Orange", NSColor(red: 1, green: 0.7, blue: 0.35, alpha: 1))]

/// A signature is a few strokes, saved once for every FreeOffice app and placed on pages as vector ink.
struct SignatureStore {
    static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FreeOffice/.signature.json") }
    static func load() -> (strokes: [[CGPoint]], aspect: Double)? {
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = o["strokes"] as? [[[Double]]], let a = o["aspect"] as? Double else { return nil }
        let strokes = s.map { $0.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        return strokes.isEmpty ? nil : (strokes, a)
    }
    static func save(_ strokes: [[CGPoint]], aspect: Double) {
        let o: [String: Any] = ["strokes": strokes.map { $0.map { [$0.x, $0.y] } }, "aspect": aspect]
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: url, options: .atomic) }
    }
}

final class ReaderPDFView: PDFView {
    var tool: ReaderTool = .select
    var onPlace: ((PDFPage, CGPoint) -> Void)?
    var onInk: ((PDFPage, NSBezierPath) -> Void)?
    var inkColor = NSColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
    private var inkPage: PDFPage?
    private var inkPath: NSBezierPath?
    private var live: PDFAnnotation?

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .note, .text, .sign: if let pg = page(for: p, nearest: true) { onPlace?(pg, convert(p, to: pg)) }
        case .ink:
            guard let pg = page(for: p, nearest: true) else { return }
            inkPage = pg; inkPath = NSBezierPath(); inkPath!.lineCapStyle = .round; inkPath!.lineJoinStyle = .round; inkPath!.move(to: convert(p, to: pg))
        default: super.mouseDown(with: e)
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard tool == .ink, let pg = inkPage, let path = inkPath else { super.mouseDragged(with: e); return }
        path.line(to: convert(convert(e.locationInWindow, from: nil), to: pg))
        if let l = live { pg.removeAnnotation(l) }
        live = ReaderPDFView.inkAnnotation(path, color: inkColor); pg.addAnnotation(live!)
    }
    override func mouseUp(with e: NSEvent) {
        guard tool == .ink, let pg = inkPage, let path = inkPath else { super.mouseUp(with: e); return }
        if let l = live { pg.removeAnnotation(l) }
        live = nil; inkPage = nil; inkPath = nil
        if path.elementCount > 1 { onInk?(pg, path) }
    }
    static func inkAnnotation(_ path: NSBezierPath, color: NSColor, width: CGFloat = 2.2) -> PDFAnnotation {
        let b = path.bounds.insetBy(dx: -width * 2, dy: -width * 2)
        let a = PDFAnnotation(bounds: b, forType: .ink, withProperties: nil)
        a.color = color; let border = PDFBorder(); border.lineWidth = width; a.border = border
        let p = path.copy() as! NSBezierPath; p.transform(using: AffineTransform(translationByX: -b.minX, byY: -b.minY)); a.add(p)
        return a
    }
}

final class ReaderModel: ObservableObject {
    @Published var doc: PDFDocument?
    @Published var title: String { didSet { if ready { meta.touch() } } }
    @Published var page = 0
    @Published var tool = ReaderTool.select { didSet { pdfView?.tool = tool; NSCursor.arrow.set() } }
    @Published var query = ""
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0
    @Published var sidebar = "thumbs"          // none · thumbs · outline · notes
    @Published var items: [AnnItem] = []
    @Published var selected: PDFAnnotation?
    @Published var hasSelection = false
    @Published var color = readerHighlightColors[0].1
    @Published var status: String?
    @Published var savedAt: Date?
    let id: String, dir: URL
    let meta: AutoSaver
    var pdfURL: URL { dir.appendingPathComponent("office__reader__\(id).pdf") }
    weak var pdfView: ReaderPDFView?
    private var ready = false, dirty = false
    private var work: DispatchWorkItem?
    private var bag: [NSObjectProtocol] = []

    init(id: String, dir: URL) {
        self.id = id; self.dir = dir
        meta = AutoSaver(url: docURL(dir, "reader", id))
        title = ""
        if let d = try? Data(contentsOf: meta.url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { title = (o["title"] as? String) ?? ""; page = (o["page"] as? Int) ?? 0 }
        if FileManager.default.fileExists(atPath: pdfURL.path) { doc = PDFDocument(url: pdfURL) }
        ready = true
        meta.make = { [weak self] in guard let m = self else { return nil }
            return try? JSONSerialization.data(withJSONObject: ["title": m.title, "file": "office__reader__\(m.id).pdf", "page": m.page, "pages": m.doc?.pageCount ?? 0, "modified": nowMillis()] as [String: Any]) }
        refreshItems()
        let nc = NotificationCenter.default
        bag.append(nc.addObserver(forName: .PDFViewAnnotationHit, object: nil, queue: .main) { [weak self] n in
            guard let s = self, (n.object as? PDFView) === s.pdfView else { return }
            s.selected = n.userInfo?["PDFAnnotationHit"] as? PDFAnnotation; s.changed(refresh: false) })
        for name in [NSText.didChangeNotification, NSText.didEndEditingNotification] {
            bag.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in if self?.pdfView?.window?.firstResponder is NSView { self?.changed(refresh: false) } })
        }
    }
    deinit { bag.forEach(NotificationCenter.default.removeObserver) }

    // MARK: opening
    @discardableResult func load(_ url: URL) -> Bool {
        guard let d = PDFDocument(url: url) else { status = "That doesn't look like a PDF."; return false }
        guard (try? FileManager.default.removeItem(at: pdfURL)) != nil || !FileManager.default.fileExists(atPath: pdfURL.path) else { return false }
        try? FileManager.default.copyItem(at: url, to: pdfURL)
        doc = PDFDocument(url: pdfURL) ?? d
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        page = 0; refreshItems(); meta.touch(); return true
    }
    func openPanel() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.pdf]
        if p.runModal() == .OK, let u = p.url { load(u) }
    }
    static func importPDF(_ url: URL, into dir: URL) -> String? {
        let id = Model.newId(); let m = ReaderModel(id: id, dir: dir)
        guard m.load(url) else { return nil }
        m.meta.flush(); return id
    }

    // MARK: saving the marked-up PDF
    func changed(refresh: Bool = true) {
        dirty = true; work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }; work = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        if refresh { refreshItems() }
        objectWillChange.send()
    }
    func flush() {
        work?.cancel(); meta.flush()
        if dirty, let d = doc { if d.write(to: pdfURL) { savedAt = Date() }; dirty = false }
    }
    func currentPageChanged() { if let v = pdfView, let p = v.currentPage, let d = doc { page = d.index(for: p); meta.touch() } }

    // MARK: markup
    func markup(_ kind: PDFAnnotationSubtype) {
        guard let v = pdfView, let sel = v.currentSelection else { status = "Select some text first."; return }
        for line in sel.selectionsByLine() {
            for pg in line.pages {
                let b = line.bounds(for: pg); guard b.width > 0 else { continue }
                let a = PDFAnnotation(bounds: b, forType: kind, withProperties: nil)
                a.markupType = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
                a.color = kind == .highlight ? color.withAlphaComponent(0.55) : (kind == .underline ? NSColor.systemBlue : NSColor.systemRed)
                a.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: b.height)), NSValue(point: CGPoint(x: b.width, y: b.height)), NSValue(point: .zero), NSValue(point: CGPoint(x: b.width, y: 0))]
                pg.addAnnotation(a)
            }
        }
        v.clearSelection(); hasSelection = false; changed()
    }
    func addNote(on pg: PDFPage, at p: CGPoint) {
        guard let text = ask("Add a note", "Type the note to pin here."), !text.isEmpty else { return }
        let a = PDFAnnotation(bounds: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24), forType: .text, withProperties: nil)
        a.contents = text; a.iconType = .comment; a.color = NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 1); pg.addAnnotation(a); changed()
    }
    func addText(on pg: PDFPage, at p: CGPoint) {
        guard let text = ask("Add text", "Type what should appear on the page."), !text.isEmpty else { return }
        let font = NSFont(name: "Helvetica Neue", size: 14) ?? .systemFont(ofSize: 14)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let a = PDFAnnotation(bounds: CGRect(x: p.x, y: p.y - size.height, width: max(size.width + 12, 40), height: size.height + 8), forType: .freeText, withProperties: nil)
        a.font = font; a.fontColor = .black; a.color = .clear; a.contents = text; a.alignment = .left
        let border = PDFBorder(); border.lineWidth = 0; a.border = border
        pg.addAnnotation(a); changed()
    }
    func addInk(on pg: PDFPage, _ path: NSBezierPath) { pg.addAnnotation(ReaderPDFView.inkAnnotation(path, color: pdfView?.inkColor ?? .blue)); changed() }
    func place(on pg: PDFPage, at p: CGPoint) {
        switch tool {
        case .note: addNote(on: pg, at: p)
        case .text: addText(on: pg, at: p)
        case .sign: placeSignature(on: pg, at: p)
        default: break
        }
        if tool != .ink { tool = .select }
    }
    func placeSignature(on pg: PDFPage, at p: CGPoint) {
        guard let sig = SignatureStore.load() else { status = "Draw your signature first (Sign ▸ Create signature)."; return }
        let w = 170.0, h = w * sig.aspect, ox = p.x - w / 2, oy = p.y - h / 2
        let path = NSBezierPath(); path.lineCapStyle = .round; path.lineJoinStyle = .round
        for s in sig.strokes where s.count > 1 { path.move(to: CGPoint(x: ox + s[0].x * w, y: oy + (1 - s[0].y) * h)); for q in s.dropFirst() { path.line(to: CGPoint(x: ox + q.x * w, y: oy + (1 - q.y) * h)) } }
        let a = ReaderPDFView.inkAnnotation(path, color: NSColor(white: 0.1, alpha: 1), width: 1.8); a.userName = "signature"; pg.addAnnotation(a); changed()
    }
    func deleteSelected() {
        guard let a = selected, let pg = a.page else { return }
        pg.removeAnnotation(a); selected = nil; changed()
    }
    func ask(_ title: String, _ info: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = info; alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); alert.accessoryView = f; alert.window.initialFirstResponder = f
        return alert.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    // MARK: annotation list
    func refreshItems() {
        guard let d = doc else { items = []; return }
        var out: [AnnItem] = []
        for i in 0..<d.pageCount { guard let pg = d.page(at: i) else { continue }
            for a in pg.annotations {
                guard let t = a.type else { continue }
                let kind = ["Highlight": "Highlight", "Underline": "Underline", "StrikeOut": "Strike", "Text": "Note", "FreeText": "Text", "Ink": a.userName == "signature" ? "Signature" : "Drawing"][t]
                guard let k = kind else { continue }
                var ex = a.contents ?? ""
                if ["Highlight", "Underline", "StrikeOut"].contains(t), let s = pg.selection(for: a.bounds)?.string { ex = s.trimmingCharacters(in: .whitespacesAndNewlines) + (ex.isEmpty ? "" : "  — " + ex) }
                out.append(AnnItem(page: i, kind: k, excerpt: ex, annotation: a))
            }
        }
        items = out
    }
    func go(_ a: PDFAnnotation) { if let pg = a.page { pdfView?.go(to: CGRect(x: a.bounds.minX, y: a.bounds.maxY, width: 1, height: 1), on: pg); selected = a } }
    func copyHighlights() {
        let text = items.filter { ["Highlight", "Underline", "Note"].contains($0.kind) }.map { "- (p. \($0.page + 1)) \($0.excerpt)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status = "Copied \(items.count) marks as a list"
    }

    // MARK: search
    func runSearch() {
        guard let d = doc, !query.isEmpty else { results = []; pdfView?.highlightedSelections = nil; return }
        results = d.findString(query, withOptions: .caseInsensitive)
        for r in results { r.color = NSColor.systemYellow.withAlphaComponent(0.6) }
        pdfView?.highlightedSelections = results; resultIndex = 0; showResult()
    }
    func showResult() { guard results.indices.contains(resultIndex), let v = pdfView else { return }; let r = results[resultIndex]; v.setCurrentSelection(r, animate: true); v.go(to: r) }
    func nextResult(_ d: Int) { guard !results.isEmpty else { return }; resultIndex = (resultIndex + d + results.count) % results.count; showResult() }

    // MARK: pages
    func rotate(_ deg: Int) { guard let pg = pdfView?.currentPage else { return }; pg.rotation = (pg.rotation + deg + 360) % 360; changed() }
    func deletePage() {
        guard let d = doc, d.pageCount > 1, let pg = pdfView?.currentPage else { return }
        d.removePage(at: d.index(for: pg)); pdfView?.layoutDocumentView(); changed()
    }
    func insertBlank() {
        guard let d = doc, let pg = pdfView?.currentPage else { return }
        let size = pg.bounds(for: .mediaBox), blank = PDFPage(); blank.setBounds(size, for: .mediaBox)
        d.insert(blank, at: d.index(for: pg) + 1); pdfView?.layoutDocumentView(); changed()
    }
    func moveCurrent(_ delta: Int) {
        guard let d = doc, let pg = pdfView?.currentPage else { return }
        let i = d.index(for: pg), j = i + delta; guard j >= 0, j < d.pageCount else { return }
        d.exchangePage(at: i, withPageAt: j); pdfView?.layoutDocumentView(); pdfView?.go(to: d.page(at: j)!); changed()
    }
    func merge() {
        guard let d = doc else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.pdf]; guard p.runModal() == .OK, let u = p.url, let other = PDFDocument(url: u) else { return }
        for i in 0..<other.pageCount { if let pg = other.page(at: i)?.copy() as? PDFPage { d.insert(pg, at: d.pageCount) } }
        pdfView?.layoutDocumentView(); changed(); status = "Added \(other.pageCount) pages"
    }

    // MARK: export
    func saveCopy() { flush(); guard let u = savePanel((title.isEmpty ? "document" : title) + ".pdf") else { return }; if doc?.write(to: u) == true { status = "Saved \(u.lastPathComponent)" } }
    /// Burns marks into the page so any viewer shows them (forms and comments are no longer editable).
    func exportFlattened() {
        guard let d = doc, let u = savePanel((title.isEmpty ? "document" : title) + " (flattened).pdf") else { return }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { return }
        for i in 0..<d.pageCount {
            guard let pg = d.page(at: i) else { continue }
            var mb = pg.bounds(for: .mediaBox); ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mb, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            pg.draw(with: .mediaBox, to: ctx)
            for a in pg.annotations where a.type != "Widget" || true { a.draw(with: .mediaBox, in: ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF(); status = "Exported \(u.lastPathComponent)"
    }
}

// MARK: - SwiftUI wrappers

struct ReaderPDF: NSViewRepresentable {
    @ObservedObject var m: ReaderModel
    func makeNSView(context: Context) -> ReaderPDFView {
        let v = ReaderPDFView()
        v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical; v.displaysPageBreaks = true
        v.backgroundColor = NSColor(white: 0.5, alpha: 0.25); v.document = m.doc
        v.onPlace = { [weak m] pg, p in m?.place(on: pg, at: p) }; v.onInk = { [weak m] pg, path in m?.addInk(on: pg, path) }
        m.pdfView = v
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak m] _ in m?.currentPageChanged() }
        NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: v, queue: .main) { [weak m, weak v] _ in m?.hasSelection = (v?.currentSelection?.string?.isEmpty == false) }
        if m.page > 0, let pg = m.doc?.page(at: m.page) { DispatchQueue.main.async { v.go(to: pg) } }
        return v
    }
    func updateNSView(_ v: ReaderPDFView, context: Context) { if v.document !== m.doc { v.document = m.doc }; v.tool = m.tool }
}

struct ReaderThumbs: NSViewRepresentable {
    @ObservedObject var m: ReaderModel
    func makeNSView(context: Context) -> PDFThumbnailView { let t = PDFThumbnailView(); t.thumbnailSize = CGSize(width: 110, height: 150); t.pdfView = m.pdfView; t.backgroundColor = .clear; return t }
    func updateNSView(_ t: PDFThumbnailView, context: Context) { if t.pdfView !== m.pdfView { t.pdfView = m.pdfView } }
}

struct SignaturePad: View {
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    var onSave: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("Draw your signature").font(.fo(.title2))
            Canvas { ctx, size in
                var base = Path(); base.move(to: CGPoint(x: 20, y: size.height - 40)); base.addLine(to: CGPoint(x: size.width - 20, y: size.height - 40)); ctx.stroke(base, with: .color(.gray.opacity(0.4)), lineWidth: 1)
                for s in strokes where s.count > 1 { var p = Path(); p.addLines(s); ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)) }
            }
            .frame(width: 420, height: 170).background(.white, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.2)))
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in if v.translation == .zero { strokes.append([v.location]) } else { strokes[strokes.count - 1].append(v.location) } })
            HStack {
                Button("Clear") { strokes = [] }.buttonStyle(.glass)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass)
                Button("Save") {
                    let pts = strokes.flatMap { $0 }; guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max(), maxX > minX else { return }
                    let w = maxX - minX, h = max(maxY - minY, 1)
                    SignatureStore.save(strokes.map { $0.map { CGPoint(x: ($0.x - minX) / w, y: ($0.y - minY) / h) } }, aspect: h / w); onSave(); dismiss()
                }.buttonStyle(.glassProminent).disabled(strokes.isEmpty)
            }
        }.padding(22)
    }
}

struct ReaderEditorView: View {
    @StateObject private var m: ReaderModel
    @State private var showSign = false
    @State private var dropping = false
    let docTab: Tab
    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? ReaderModel) ?? { let x = ReaderModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        VStack(spacing: 8) {
            if m.doc != nil { topBar.padding(.horizontal, 14).padding(.top, 10) }
            if m.doc == nil { emptyState }
            else {
                HStack(spacing: 10) {
                    if m.sidebar != "none" { sidebarView.frame(width: 230).transition(.move(edge: .leading)) }
                    ReaderPDF(m: m).clipShape(.rect(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .background { Backdrop().opacity(0.6) }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled PDF", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 220, maxWidth: 320) }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled PDF" : t }
        .onChange(of: m.status) { _, s in if s != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { m.status = nil } } }
        .onAppear { docTab.onUndo = {}; docTab.onRedo = {} }
        .onDisappear { m.flush() }
        .onKeyPress(.delete) { if m.selected != nil { m.deleteSelected(); return .handled }; return .ignored }
        .sheet(isPresented: $showSign) { SignaturePad { m.tool = .sign } }
        .dropDestination(for: URL.self) { urls, _ in if let u = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) { return m.load(u) }; return false } isTargeted: { dropping = $0 }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(10).allowsHitTesting(false) } }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Open a PDF").font(.fo(.title2))
            Text("Drop a PDF here, or choose one. FreeOffice keeps its own copy, so your original is never changed.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { m.openPanel() } label: { Label("Choose PDF…", systemImage: "folder") }.buttonStyle(.glassProminent).controlSize(.large)
            if let s = m.status { Text(s).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
    }
    func toolButton(_ t: ReaderTool, _ symbol: String, _ help: String) -> some View {
        Button { m.tool = (m.tool == t ? .select : t) } label: { Image(systemName: symbol).padding(5).background(m.tool == t ? Color.accentColor.opacity(0.3) : .clear, in: .rect(cornerRadius: 7)) }.help(help)
    }
    var topBar: some View {
        GlassEffectContainer(spacing: 8) {
            WrapLayout(spacing: 8) {
                group {
                    Menu {
                        Button("Open another PDF…") { m.openPanel() }; Button("Add pages from a PDF…") { m.merge() }
                        Divider(); Button("Save a copy…") { m.saveCopy() }; Button("Export flattened…") { m.exportFlattened() }
                        Divider(); Button("Copy highlights and notes") { m.copyHighlights() }
                    } label: { Label("File", systemImage: "doc") }.menuStyle(.borderlessButton).fixedSize()
                    Picker("", selection: $m.sidebar) { Image(systemName: "sidebar.left").tag("none"); Image(systemName: "square.grid.2x2").tag("thumbs"); Image(systemName: "list.bullet.indent").tag("outline"); Image(systemName: "highlighter").tag("notes") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                group {
                    Button { m.markup(.highlight) } label: { Image(systemName: "highlighter") }.help("Highlight the selected text").disabled(!m.hasSelection)
                    Menu { ForEach(readerHighlightColors, id: \.0) { n, c in Button { m.color = c } label: { Label(n, systemImage: "circle.fill").foregroundStyle(Color(nsColor: c)) } } } label: { Circle().fill(Color(nsColor: m.color)).frame(width: 14, height: 14) }.menuStyle(.borderlessButton).fixedSize()
                    Button { m.markup(.underline) } label: { Image(systemName: "underline") }.help("Underline").disabled(!m.hasSelection)
                    Button { m.markup(.strikeOut) } label: { Image(systemName: "strikethrough") }.help("Strike through").disabled(!m.hasSelection)
                    Divider().frame(height: 16)
                    toolButton(.note, "note.text", "Pin a note — click on the page")
                    toolButton(.text, "textformat", "Add text anywhere on the page")
                    toolButton(.ink, "pencil.tip", "Draw")
                    Menu {
                        Button("Place my signature") { if SignatureStore.load() == nil { showSign = true } else { m.tool = .sign } }
                        Button("Create signature…") { showSign = true }
                    } label: { Image(systemName: "signature").padding(5).background(m.tool == .sign ? Color.accentColor.opacity(0.3) : .clear, in: .rect(cornerRadius: 7)) }.menuStyle(.borderlessButton).fixedSize()
                    if m.selected != nil { Button(role: .destructive) { m.deleteSelected() } label: { Image(systemName: "trash") }.help("Delete the selected mark") }
                }
                group {
                    Button { m.pdfView?.goToPreviousPage(nil) } label: { Image(systemName: "chevron.up") }
                    Text("\(m.page + 1) / \(m.doc?.pageCount ?? 0)").font(.fo(.callout)).monospacedDigit().frame(minWidth: 56)
                    Button { m.pdfView?.goToNextPage(nil) } label: { Image(systemName: "chevron.down") }
                    Divider().frame(height: 16)
                    Button { m.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { m.pdfView?.autoScales = true } label: { Image(systemName: "arrow.left.and.right.square") }.help("Fit width")
                    Button { m.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }
                }
                group {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in PDF", text: $m.query).textFieldStyle(.plain).frame(width: 130).onSubmit { m.runSearch() }
                    if !m.results.isEmpty { Text("\(m.resultIndex + 1)/\(m.results.count)").font(.fo(.caption)).monospacedDigit(); Button { m.nextResult(-1) } label: { Image(systemName: "chevron.up") }; Button { m.nextResult(1) } label: { Image(systemName: "chevron.down") } }
                    else if !m.query.isEmpty { Text("No matches").font(.fo(.caption)).foregroundStyle(.secondary) }
                }
                group {
                    Menu {
                        Button("Rotate left") { m.rotate(-90) }; Button("Rotate right") { m.rotate(90) }
                        Divider(); Button("Move page up") { m.moveCurrent(-1) }; Button("Move page down") { m.moveCurrent(1) }
                        Divider(); Button("Insert blank page after") { m.insertBlank() }; Button("Delete this page", role: .destructive) { m.deletePage() }
                    } label: { Label("Pages", systemImage: "square.on.square") }.menuStyle(.borderlessButton).fixedSize()
                }
                if let s = m.status { group { Text(s).font(.fo(.caption)) } }
                else if m.tool != .select { group { Text(m.tool == .ink ? "Draw on the page" : m.tool == .sign ? "Click where your signature goes" : "Click on the page to place it").font(.fo(.caption)) } }
            }.buttonStyle(.plain)
        }
    }

    // MARK: sidebar
    @ViewBuilder var sidebarView: some View {
        switch m.sidebar {
        case "outline": outline
        case "notes": notes
        default: ReaderThumbs(m: m).padding(6).background(.regularMaterial, in: .rect(cornerRadius: 14))
        }
    }
    struct OutlineRow: Identifiable { let id = UUID(); let label: String; let depth: Int; let dest: PDFDestination? }
    var outlineRows: [OutlineRow] {
        var out: [OutlineRow] = []
        func walk(_ o: PDFOutline, _ depth: Int) { for i in 0..<o.numberOfChildren { if let c = o.child(at: i) { out.append(OutlineRow(label: c.label ?? "", depth: depth, dest: c.destination)); walk(c, depth + 1) } } }
        if let root = m.doc?.outlineRoot { walk(root, 0) }
        return out
    }
    var outline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                let rows = outlineRows
                if rows.isEmpty { Text("This PDF has no outline.").foregroundStyle(.secondary).padding(12) }
                ForEach(rows) { r in
                    Button { if let d = r.dest { m.pdfView?.go(to: d) } } label: { Text(r.label).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(r.depth) * 12).padding(.vertical, 4).contentShape(.rect) }.buttonStyle(.plain)
                }
            }.padding(8)
        }.background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
    var notes: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if m.items.isEmpty { Text("Highlights, notes and drawings you add show up here.").foregroundStyle(.secondary).padding(12) }
                ForEach(m.items) { it in
                    Button { m.go(it.annotation) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(it.kind).font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text("p. \(it.page + 1)").font(.fo(.caption)).foregroundStyle(.secondary) }
                            if !it.excerpt.isEmpty { Text(it.excerpt).font(.fo(.callout)).lineLimit(4).multilineTextAlignment(.leading) }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: .rect(cornerRadius: 10)).contentShape(.rect)
                    }.buttonStyle(.plain)
                    .contextMenu { Button("Delete", role: .destructive) { it.annotation.page?.removeAnnotation(it.annotation); m.changed() } }
                }
            }.padding(8)
        }.background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
}
