// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit
import PDFKit

// @-mentions: type @ in any text field to link another document (from any FreeOffice app).
// Plain-text fields store a token  @[Title](app:id) ; Writer stores a real link  freeoffice://doc/app/id .
// Hovering a mention shows a live preview of that document; clicking opens it.

struct DocRef: Identifiable, Hashable {
    let app: AppInfo, docId: String, title: String, modified: Date
    var id: String { app.key + ":" + docId }
    var token: String { "@[\(title.replacingOccurrences(of: "]", with: ")"))](\(app.key):\(docId))" }
    var url: URL { URL(string: "freeoffice://doc/\(app.key)/\(docId)")! }
    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: DocRef, b: DocRef) -> Bool { a.id == b.id }
}

enum DocLinks {
    static var dir: URL { Storage.shared?.activeDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FreeOffice") }

    /// Every document across all apps, newest first (not limited to the app you're in).
    static func all() -> [DocRef] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [DocRef] = []
        for f in files where f.lastPathComponent.hasPrefix("office__") && f.pathExtension == "json" {
            let p = f.deletingPathExtension().lastPathComponent.components(separatedBy: "__")
            guard p.count == 3, let app = appFor(p[1]), let d = try? Data(contentsOf: f),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let t = (o["title"] as? String) ?? ""
            out.append(DocRef(app: app, docId: p[2], title: t.isEmpty ? "Untitled" : t, modified: Date(timeIntervalSince1970: ((o["modified"] as? Double) ?? 0) / 1000)))
        }
        return out.sorted { $0.modified > $1.modified }
    }
    static func find(app: String, id: String) -> DocRef? { all().first { $0.app.key == app && $0.docId == id } }
    static func ref(from url: URL) -> DocRef? {
        guard url.scheme == "freeoffice", url.host == "doc" else { return nil }
        let p = url.pathComponents.filter { $0 != "/" }; guard p.count == 2 else { return nil }
        return find(app: p[0], id: p[1])
    }

    // Opening: inside the launcher (or the same app) it becomes a tab; from a single app it hands over to the launcher.
    static func open(_ r: DocRef) {
        if let m = Model.shared, m.appKey.isEmpty || m.appKey == r.app.key { m.open(r.app, doc: r.docId); return }
        NSWorkspace.shared.open(r.url)
    }
    static func open(url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == "pdf" { Model.shared?.openPDF(url); return }
        if let r = ref(from: url) { open(r) }
    }

    // MARK: tokens in plain text
    enum Seg: Identifiable { case text(Int, String), ref(Int, title: String, app: String, id: String)
        var id: Int { switch self { case .text(let i, _), .ref(let i, _, _, _): return i } } }
    static let pattern = try! NSRegularExpression(pattern: "@\\[([^\\]]*)\\]\\((writer|sheets|slides|poster|data):([A-Za-z0-9_-]+)\\)")
    static func segments(_ s: String) -> [Seg] {
        let ns = s as NSString; var out: [Seg] = [], last = 0, n = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(.text(n, ns.substring(with: NSRange(location: last, length: m.range.location - last)))); n += 1 }
            out.append(.ref(n, title: ns.substring(with: m.range(at: 1)), app: ns.substring(with: m.range(at: 2)), id: ns.substring(with: m.range(at: 3)))); n += 1
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(n, ns.substring(from: last))) }
        return out
    }
    static func refs(in s: String) -> [(title: String, app: String, id: String)] { segments(s).compactMap { if case .ref(_, let t, let a, let i) = $0 { return (t, a, i) }; return nil } }
    static func hasRefs(_ s: String) -> Bool { s.contains("@[") && !refs(in: s).isEmpty }
    /// For SQL: each mention becomes a quoted string, so a query can still run.
    static func sqlText(_ s: String) -> String {
        segments(s).map { if case .text(_, let t) = $0 { return t }; if case .ref(_, let t, _, _) = $0 { return "'" + t.replacingOccurrences(of: "'", with: "''") + "'" }; return "" }.joined()
    }
    /// Plain wording for places that can't show chips (SQL, exports): @[Budget](sheets:x) → Budget
    static func plain(_ s: String) -> String { segments(s).map { if case .text(_, let t) = $0 { return t }; if case .ref(_, let t, _, _) = $0 { return t }; return "" }.joined() }
}

// MARK: - Preview card (renders the real document with the real model, read-only)

struct DocPreviewCard: View {
    let ref: DocRef
    @State private var content: AnyView?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: ref.app.symbol).foregroundStyle(.white).frame(width: 26, height: 26).background(ref.app.tint.gradient, in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 0) {
                    Text(ref.title).font(.fo(.headline)).lineLimit(1)
                    Text("\(ref.app.name) · edited \(ref.modified.formatted(.relative(presentation: .named)))").font(.fo(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Group { if let c = content { c } else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) } }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Text("Click the mention to open").font(.fo(.caption)).foregroundStyle(.tertiary)
        }
        .padding(14).frame(width: 340, alignment: .topLeading)
        .task(id: ref.id) { content = Self.render(ref) }
    }

    @MainActor static func render(_ r: DocRef) -> AnyView {
        let dir = DocLinks.dir
        switch r.app.key {
        case "writer":
            let s = WriterDoc(id: r.docId, dir: dir).initial.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return AnyView(Text(s.isEmpty ? "Empty document" : String(s.prefix(700))).font(.fo(.callout)).lineLimit(12).padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.white, in: .rect(cornerRadius: 8)).foregroundStyle(.black).environment(\.colorScheme, .light))
        case "sheets":
            let m = SheetModel(id: r.docId, dir: dir)
            let b = m.usedBounds() ?? (2, 4), cols = min(b.c + 1, 5), rows = min(b.r + 1, 8)
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) { ForEach(0..<cols, id: \.self) { c in
                        let d = m.display(cellAddress(c, row))
                        Text(d.text).font(.fo(.caption).weight(row == 0 ? .semibold : .regular)).lineLimit(1).padding(.horizontal, 6).frame(width: 62, height: 22, alignment: d.number ? .trailing : .leading)
                            .overlay(Rectangle().stroke(Color.gray.opacity(0.25), lineWidth: 0.5)) } }
                }
                if b.c + 1 > cols || b.r + 1 > rows { Text("… \(b.r + 1) rows × \(b.c + 1) columns").font(.fo(.caption)).foregroundStyle(.secondary).padding(.top, 4) }
            }.background(Color.white).foregroundStyle(.black).environment(\.colorScheme, .light))
        case "slides":
            let m = SlidesModel(id: r.docId, dir: dir)
            guard let s = m.slides.first else { return AnyView(Text("Empty deck").foregroundStyle(.secondary)) }
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                SlideThumb(slide: s, deck: m.deck, number: 1, images: m.images, width: 312).clipShape(.rect(cornerRadius: 8)).shadow(radius: 2)
                Text("\(m.slides.count) slide\(m.slides.count == 1 ? "" : "s")").font(.fo(.caption)).foregroundStyle(.secondary)
            })
        case "poster":
            let m = PosterModel(id: r.docId, dir: dir), p = m.page, w: CGFloat = 200, k = w / p.w
            return AnyView(CanvasPage(m: m, interactive: false).scaleEffect(k, anchor: .topLeading).frame(width: w, height: p.h * k, alignment: .topLeading).clipped().shadow(radius: 2).frame(maxWidth: .infinity))
        case "math":
            let m = MathModel(id: r.docId, dir: dir)
            let calc = m.cells.first { $0.kind == "calc" }, tex = m.cells.first { $0.kind == "tex" }
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                if let t = tex, let img = TeX.image(t.text, size: 22, color: .black) { Image(nsImage: img).padding(8).frame(maxWidth: .infinity).background(Color.white, in: .rect(cornerRadius: 8)) }
                if let c = calc { let res = m.results[c.id] ?? []
                    VStack(alignment: .leading, spacing: 2) { ForEach(Array(zip(m.lines(c), res).filter { $0.1 != .empty }.prefix(6).enumerated()), id: \.offset) { _, p in
                        HStack { Text(p.0).font(.system(size: 12, design: .monospaced)).lineLimit(1); Spacer(); Text(p.1.text).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(p.1.isError ? Color.red : Color.accentColor) } } } }
                Text("\(m.cells.count) cell\(m.cells.count == 1 ? "" : "s")").font(.fo(.caption)).foregroundStyle(.secondary)
            })
        case "diagrams":
            let m = DiagramModel(id: r.docId, dir: dir), b = DSVG.bounds(m.nodes, m.edges).insetBy(dx: -30, dy: -30), k = min(312 / b.width, 220 / b.height, 1.2)
            return AnyView(DiagramExportView(nodes: m.nodes, edges: m.edges).frame(width: b.width, height: b.height).scaleEffect(k).frame(width: b.width * k, height: b.height * k).clipShape(.rect(cornerRadius: 8)).frame(maxWidth: .infinity))
        case "planner":
            let m = PlannerModel(id: r.docId, dir: dir), now = Date(), occ = Array(m.occurrences(from: now, to: now.addingTimeInterval(86400 * 30)).prefix(5)), open = m.tasks.filter { !$0.done }
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(occ) { o in HStack(spacing: 8) { Circle().fill(Color(hex: o.event.color)).frame(width: 9, height: 9); Text(o.start.formatted(.dateTime.day().month(.abbreviated))).font(.fo(.caption)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading); Text(o.event.title).font(.fo(.callout)).lineLimit(1) } }
                if occ.isEmpty { Text("Nothing coming up").foregroundStyle(.secondary).font(.fo(.callout)) }
                Divider(); Label("\(open.count) open task\(open.count == 1 ? "" : "s") · \(m.tasks.filter { $0.done }.count) done", systemImage: "checklist").font(.fo(.caption)).foregroundStyle(.secondary)
            })
        case "reader":
            let d = PDFDocument(url: dir.appendingPathComponent("office__reader__\(r.docId).pdf"))
            guard let pg = d?.page(at: 0) else { return AnyView(Text("No PDF opened yet").foregroundStyle(.secondary)) }
            return AnyView(VStack(spacing: 4) { Image(nsImage: pg.thumbnail(of: CGSize(width: 200, height: 260), for: .mediaBox)).shadow(radius: 2); Text("\(d!.pageCount) page\(d!.pageCount == 1 ? "" : "s")").font(.fo(.caption)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity))
        default:
            let m = DataDocModel(id: r.docId, dir: dir)
            guard let t = m.doc.tables.first else { return AnyView(Text("Empty database").foregroundStyle(.secondary)) }
            let fields = Array(t.fields.filter { !($0.hidden ?? false) }.prefix(4))
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                Text("\(t.name) · \(t.rows.count) rows\(m.doc.tables.count > 1 ? " · \(m.doc.tables.count) tables" : "")").font(.fo(.caption)).foregroundStyle(.secondary).padding(.bottom, 4)
                HStack(spacing: 0) { ForEach(fields) { Text($0.name).font(.fo(.caption).weight(.semibold)).lineLimit(1).padding(.horizontal, 6).frame(width: 76, alignment: .leading) } }.frame(height: 22).background(Color.primary.opacity(0.08))
                ForEach(Array(t.rows.prefix(6))) { row in
                    HStack(spacing: 0) { ForEach(fields) { Text(m.display(row, $0, in: t)).font(.fo(.caption)).lineLimit(1).padding(.horizontal, 6).frame(width: 76, alignment: .leading) } }.frame(height: 22)
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                }
            })
        }
    }
}

// MARK: - Picker (type to search, ↑↓ to choose, ↩ to insert; the right side previews the highlighted document)

struct DocPicker: View {
    var onPick: (DocRef) -> Void
    var onCancel: () -> Void
    @State private var docs: [DocRef] = []
    @State private var q = ""
    @State private var sel = 0
    @FocusState private var focus: Bool
    var shown: [DocRef] { q.isEmpty ? docs : docs.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.app.name.localizedCaseInsensitiveContains(q) } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack { Image(systemName: "at").foregroundStyle(.secondary); TextField("Link a document…", text: $q).textFieldStyle(.plain).focused($focus).onSubmit { pick() } }
                    .padding(8).background(.thinMaterial, in: .rect(cornerRadius: 10))
                ScrollViewReader { sp in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                                HStack(spacing: 8) {
                                    Image(systemName: d.app.symbol).foregroundStyle(d.app.tint).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 0) { Text(d.title).lineLimit(1); Text(d.app.name).font(.fo(.caption)).foregroundStyle(.secondary) }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5).background(i == sel ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 8)).contentShape(.rect)
                                .onTapGesture { sel = i; pick() }.id(d.id)
                            }
                            if shown.isEmpty { Text(docs.isEmpty ? "No documents yet" : "Nothing matches").foregroundStyle(.secondary).padding(20) }
                        }
                    }.onChange(of: sel) { _, i in if shown.indices.contains(i) { sp.scrollTo(shown[i].id) } }
                }
            }.padding(10).frame(width: 260)
            Divider()
            Group { if shown.indices.contains(sel) { DocPreviewCard(ref: shown[sel]) } else { Color.clear.frame(width: 340) } }.frame(width: 340, alignment: .topLeading)
        }
        .frame(height: 360)
        .onAppear { docs = DocLinks.all(); focus = true }
        .onChange(of: q) { _, _ in sel = 0 }
        .onKeyPress(.downArrow) { sel = min(sel + 1, max(shown.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { sel = max(sel - 1, 0); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }
    func pick() { if shown.indices.contains(sel) { onPick(shown[sel]) } }
}

// MARK: - Mention chips for plain-text fields

struct DocChip: View {
    let title: String, app: String, id: String
    @State private var hover = false
    @State private var show = false
    @State private var work: DispatchWorkItem?
    var live: DocRef? { DocLinks.find(app: app, id: id) }
    var info: AppInfo { appFor(app) ?? allApps[0] }
    var body: some View {
        Button { if let r = live { DocLinks.open(r) } } label: {
            HStack(spacing: 4) {
                Image(systemName: info.symbol).font(.caption2)
                Text(live?.title ?? title).lineLimit(1).font(.fo(.callout).weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 2).foregroundStyle(live == nil ? Color.secondary : info.tint).background((live == nil ? Color.gray : info.tint).opacity(hover ? 0.28 : 0.16), in: .capsule)
        }
        .buttonStyle(.plain)
        .onHover { h in
            hover = h; work?.cancel()
            if h, live != nil { let w = DispatchWorkItem { show = true }; work = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w) } else { show = false }
        }
        .popover(isPresented: $show, arrowEdge: .bottom) { if let r = live { DocPreviewCard(ref: r) } }
        .help(live == nil ? "This document is no longer available" : "Open \(title)")
    }
}

/// Text with its @mentions drawn as chips.
struct LinkedText: View {
    let text: String
    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(DocLinks.segments(text)) { s in
                switch s {
                case .text(_, let t): Text(t).lineLimit(1)
                case .ref(_, let t, let a, let i): DocChip(title: t, app: a, id: i)
                }
            }
        }
    }
}

/// A row of chips for the documents mentioned in `text` (used under editors).
struct MentionStrip: View {
    let text: String
    var body: some View {
        let r = DocLinks.refs(in: text)
        if !r.isEmpty {
            WrapLayout(spacing: 6) { ForEach(Array(r.enumerated()), id: \.offset) { _, x in DocChip(title: x.title, app: x.app, id: x.id) } }
        }
    }
}

/// Typing @ at the start of a word in any SwiftUI text field opens the picker and inserts a mention token.
struct DocMentionModifier: ViewModifier {
    @Binding var text: String
    @State private var open = false
    func body(content: Content) -> some View {
        content
            .onChange(of: text) { old, new in
                guard new.count == old.count + 1, new.hasSuffix("@") else { return }
                let before = new.dropLast().last
                if before == nil || before == " " || before == "\n" || before == "(" || before == "," { open = true }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                DocPicker(onPick: { r in if text.hasSuffix("@") { text.removeLast() }; text += r.token + " "; open = false }, onCancel: { open = false })
            }
    }
}
extension View { func docMentions(_ text: Binding<String>) -> some View { modifier(DocMentionModifier(text: text)) } }

// MARK: - Writer (NSTextView): picker at the caret + hover previews

enum DocMentionAppKit {
    static func caretRect(_ tv: NSTextView, _ loc: Int) -> NSRect {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return .zero }
        let g = lm.glyphRange(forCharacterRange: NSRange(location: min(loc, max(tv.string.utf16.count - 1, 0)), length: 1), actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: g, in: tc); r.origin.x += tv.textContainerOrigin.x; r.origin.y += tv.textContainerOrigin.y; return r
    }
    /// Called right after an "@" was typed at `loc`.
    static func present(in tv: NSTextView, at loc: Int) {
        let pop = NSPopover(); pop.behavior = .transient
        let host = NSHostingController(rootView: DocPicker(onPick: { r in
            pop.close()
            guard (tv.string as NSString).length > loc, (tv.string as NSString).substring(with: NSRange(location: loc, length: 1)) == "@" else { return }
            var attrs = tv.typingAttributes; attrs[.link] = r.url; attrs[.foregroundColor] = NSColor(r.app.tint); attrs[.underlineStyle] = 0
            attrs[.backgroundColor] = NSColor(r.app.tint).withAlphaComponent(0.14)
            let chip = NSAttributedString(string: "@" + r.title, attributes: attrs)
            tv.window?.makeFirstResponder(tv)
            if tv.shouldChangeText(in: NSRange(location: loc, length: 1), replacementString: chip.string) {
                tv.textStorage?.replaceCharacters(in: NSRange(location: loc, length: 1), with: chip)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: loc + chip.length, length: 0))
                var plain = tv.typingAttributes; for k: NSAttributedString.Key in [.link, .backgroundColor, .underlineStyle] { plain.removeValue(forKey: k) }
                plain[.foregroundColor] = NSColor.black; tv.typingAttributes = plain
                tv.insertText(" ", replacementRange: tv.selectedRange())
            }
        }, onCancel: { pop.close() }))
        pop.contentViewController = host; pop.contentSize = NSSize(width: 600, height: 360)
        pop.show(relativeTo: caretRect(tv, loc), of: tv, preferredEdge: .maxY)
    }
}

/// Watches the mouse over a text view; hovering a mention for a moment pops up its preview.
final class DocHoverWatcher {
    weak var tv: NSTextView?
    private var monitor: Any?
    private var pop: NSPopover?
    private var shownFor: NSRange?
    private var work: DispatchWorkItem?
    init(_ tv: NSTextView) {
        self.tv = tv
        tv.window?.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.moved(e); return e }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) }; pop?.close() }
    private func link(at e: NSEvent) -> (NSRange, URL)? {
        guard let tv = tv, e.window === tv.window, let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage, ts.length > 0 else { return nil }
        var p = tv.convert(e.locationInWindow, from: nil); p.x -= tv.textContainerOrigin.x; p.y -= tv.textContainerOrigin.y
        let i = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        guard i < ts.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard let u = ts.attribute(.link, at: i, effectiveRange: &range) as? URL, u.scheme == "freeoffice" else { return nil }
        let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
        return r.insetBy(dx: -2, dy: -2).contains(p) ? (range, u) : nil
    }
    private func moved(_ e: NSEvent) {
        if let (range, u) = link(at: e) {
            if shownFor == range { return }
            work?.cancel(); close()
            let w = DispatchWorkItem { [weak self] in self?.show(range, u) }; work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        } else { work?.cancel(); close() }
    }
    private func show(_ range: NSRange, _ u: URL) {
        guard let tv = tv, tv.window != nil, let r = DocLinks.ref(from: u) else { return }
        shownFor = range
        let p = NSPopover(); p.behavior = .semitransient; p.animates = true
        p.contentViewController = NSHostingController(rootView: DocPreviewCard(ref: r))
        var rect = DocMentionAppKit.caretRect(tv, range.location); if let lm = tv.layoutManager, let tc = tv.textContainer {
            rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc); rect.origin.x += tv.textContainerOrigin.x; rect.origin.y += tv.textContainerOrigin.y }
        p.show(relativeTo: rect, of: tv, preferredEdge: .maxY); pop = p
    }
    private func close() { pop?.close(); pop = nil; shownFor = nil }
}
