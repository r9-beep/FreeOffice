// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

// Native Writer. Documents use the same store file as the web Writer ({title, html}) and additionally keep an
// "rtf" (or "rtfd", when the document has images) copy so formatting round-trips exactly in the native app.

final class WriterDoc: ObservableObject {
    @Published var title: String { didSet { if ready && title != oldValue { dirty = true; scheduleSave() } } }
    @Published var words = 0
    @Published var chars = 0
    @Published var selWords = 0
    @Published var fontName = "Helvetica Neue"
    @Published var savedAt: Date?
    @Published var outline: [OutlineItem] = []
    @Published var zoom = 1.0
    @Published var margin = 1                       // 0 narrow · 1 normal · 2 wide
    let id: String, url: URL
    var initial = NSAttributedString()
    var storage: NSTextStorage?
    weak var tv: NSTextView?
    weak var scroll: NSScrollView?
    let colorTarget = ColorTarget()
    private var ready = false, dirty = false
    private var work: DispatchWorkItem?, outlineWork: DispatchWorkItem?
    static let base = NSFont(name: "Helvetica Neue", size: 16) ?? .systemFont(ofSize: 16)

    init(id: String, dir: URL) {
        self.id = id
        url = dir.appendingPathComponent("office__writer__\(id).json")
        title = "Untitled"
        if let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            if let t = o["title"] as? String, !t.isEmpty { title = t }
            if let b = o["rtfd"] as? String, let data = Data(base64Encoded: b), let a = NSAttributedString(rtfd: data, documentAttributes: nil) {
                initial = a
            } else if let b = o["rtf"] as? String, let data = Data(base64Encoded: b), let a = NSAttributedString(rtf: data, documentAttributes: nil) {
                initial = a
            } else if let h = o["html"] as? String, let data = h.data(using: .utf8),
                      let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
                initial = Self.normalise(a)
            }
        }
        ready = true
    }

    // HTML import comes in as 12pt Times; bring it in line with the Writer look.
    static func normalise(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a), fm = NSFontManager.shared
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { v, r, _ in
            guard let f = v as? NSFont else { return }
            var g = fm.convert(f, toFamily: "Helvetica Neue"); g = fm.convert(g, toSize: f.pointSize * 1.33); m.addAttribute(.font, value: g, range: r)
        }
        // The HTML importer marks lists with NSTextList *and* literal "\t•\t" text, which draws two bullets.
        let ns = m.string as NSString; var paras: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, r, _, _ in paras.append(r) }
        for r in paras.reversed() where r.length > 0 {
            guard let ps = m.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle, !ps.textLists.isEmpty else { continue }
            let np = NSMutableParagraphStyle(); np.headIndent = 24; np.firstLineHeadIndent = 0; np.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
            m.addAttribute(.paragraphStyle, value: np, range: r)
            let s = ns.substring(with: r)
            if s.hasPrefix("\t•\t") { m.deleteCharacters(in: NSRange(location: r.location, length: 1)) }
            else if !s.hasPrefix("•\t") { m.insert(NSAttributedString(string: "•\t", attributes: [.font: base]), at: r.location) }
        }
        return m
    }

    // MARK: saving
    func changed() {
        dirty = true; scheduleSave(); updateStats()
        outlineWork?.cancel(); let w = DispatchWorkItem { [weak self] in self?.computeOutline() }; outlineWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }
    func scheduleSave() { work?.cancel(); let w = DispatchWorkItem { [weak self] in self?.save() }; work = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w) }
    func flush() { work?.cancel(); if dirty { save() } }
    func save() {
        guard let ts = storage else { return }
        let full = NSRange(location: 0, length: ts.length)
        var o: [String: Any] = ["title": title, "html": html(), "modified": Date().timeIntervalSince1970 * 1000]
        if ts.containsAttachments, let d = ts.rtfd(from: full, documentAttributes: [:]) { o["rtfd"] = d.base64EncodedString() }
        else { o["rtf"] = (ts.rtf(from: full, documentAttributes: [:]) ?? Data()).base64EncodedString() }
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: url, options: .atomic); savedAt = Date(); dirty = false }
    }

    // MARK: character formatting
    func edit(_ r: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let tv = tv, let ts = tv.textStorage, tv.shouldChangeText(in: r, replacementString: nil) else { return }
        ts.beginEditing(); body(ts); ts.endEditing(); tv.didChangeText()
    }
    func toggleTrait(_ mask: NSFontTraitMask) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let fm = NSFontManager.shared, r = tv.selectedRange()
        if r.length == 0 {
            var ta = tv.typingAttributes; let f = (ta[.font] as? NSFont) ?? Self.base
            ta[.font] = fm.traits(of: f).contains(mask) ? fm.convert(f, toNotHaveTrait: mask) : fm.convert(f, toHaveTrait: mask)
            tv.typingAttributes = ta; return
        }
        let has = (ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont).map { fm.traits(of: $0).contains(mask) } ?? false
        edit(r) { ts in ts.enumerateAttribute(.font, in: r) { v, rr, _ in
            let f = (v as? NSFont) ?? Self.base
            ts.addAttribute(.font, value: has ? fm.convert(f, toNotHaveTrait: mask) : fm.convert(f, toHaveTrait: mask), range: rr) } }
    }
    func toggleLine(_ key: NSAttributedString.Key) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let r = tv.selectedRange()
        if r.length == 0 { var ta = tv.typingAttributes; if ta[key] != nil { ta[key] = nil } else { ta[key] = NSUnderlineStyle.single.rawValue }; tv.typingAttributes = ta; return }
        let has = ts.attribute(key, at: r.location, effectiveRange: nil) != nil
        edit(r) { ts in if has { ts.removeAttribute(key, range: r) } else { ts.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: r) } }
    }
    func setColor(_ c: NSColor) {
        guard let tv = tv else { return }
        let r = tv.selectedRange()
        if r.length == 0 { var ta = tv.typingAttributes; ta[.foregroundColor] = c; tv.typingAttributes = ta } else { edit(r) { $0.addAttribute(.foregroundColor, value: c, range: r) } }
    }
    func setFamily(_ family: String) {
        guard let tv = tv else { return }
        let fm = NSFontManager.shared, r = tv.selectedRange()
        if r.length == 0 { var ta = tv.typingAttributes; ta[.font] = fm.convert((ta[.font] as? NSFont) ?? Self.base, toFamily: family); tv.typingAttributes = ta }
        else { edit(r) { ts in ts.enumerateAttribute(.font, in: r) { v, rr, _ in ts.addAttribute(.font, value: fm.convert((v as? NSFont) ?? Self.base, toFamily: family), range: rr) } } }
        fontName = family
    }
    func refreshFontName() {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let r = tv.selectedRange()
        let f = (r.length > 0 || (ts.length > 0 && r.location < ts.length) ? ts.attribute(.font, at: min(r.location, max(ts.length - 1, 0)), effectiveRange: nil) as? NSFont : nil) ?? (tv.typingAttributes[.font] as? NSFont) ?? Self.base
        let name = f.familyName ?? "Helvetica Neue"
        if name != fontName { DispatchQueue.main.async { self.fontName = name } }
    }
    func setSize(_ size: CGFloat) {
        guard let tv = tv else { return }
        let fm = NSFontManager.shared, r = tv.selectedRange()
        if r.length == 0 { var ta = tv.typingAttributes; ta[.font] = fm.convert((ta[.font] as? NSFont) ?? Self.base, toSize: size); tv.typingAttributes = ta; return }
        edit(r) { ts in ts.enumerateAttribute(.font, in: r) { v, rr, _ in ts.addAttribute(.font, value: fm.convert((v as? NSFont) ?? Self.base, toSize: size), range: rr) } }
    }
    func undo() { tv?.undoManager?.undo() }
    func redo() { tv?.undoManager?.redo() }
    func align(_ a: NSTextAlignment) {
        switch a { case .center: tv?.alignCenter(nil); case .right: tv?.alignRight(nil); case .justified: tv?.alignJustified(nil); default: tv?.alignLeft(nil) }
    }

    // MARK: HTML (so the web Writer can open native documents too)
    func html() -> String {
        guard let ts = storage else { return "" }
        let ns = ts.string as NSString, fm = NSFontManager.shared
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var out = "", open = ""
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, range, _, _ in
            let info = self.listInfo(sub ?? "")
            let r = NSRange(location: range.location + info.markerLen, length: max(0, range.length - info.markerLen))
            var inner = ""
            let paraSize = r.length > 0 ? ((ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 16) : 16
            let isHeading = info.kind == .none && paraSize >= 18          // headings are bold by definition; don't repeat it
            if r.length > 0 {
                ts.enumerateAttributes(in: r) { at, rr, _ in
                    var s = esc(ns.substring(with: rr).replacingOccurrences(of: "\u{FFFC}", with: ""))
                    if let f = at[.font] as? NSFont { let t = fm.traits(of: f); if t.contains(.boldFontMask) && !isHeading { s = "<b>\(s)</b>" }; if t.contains(.italicFontMask) { s = "<i>\(s)</i>" } }
                    if at[.underlineStyle] != nil { s = "<u>\(s)</u>" }
                    if at[.strikethroughStyle] != nil { s = "<s>\(s)</s>" }
                    if let l = at[.link] { s = "<a href=\"\(esc("\(l)"))\">\(s)</a>" }
                    inner += s
                }
            }
            let wanted = info.kind == .bullet ? "ul" : info.kind == .number ? "ol" : ""
            if open != wanted { if !open.isEmpty { out += "</\(open)>" }; if !wanted.isEmpty { out += "<\(wanted)>" }; open = wanted }
            if info.kind != .none { out += "<li>\(inner)</li>"; return }
            let size = r.length > 0 ? ((ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 16) : 16
            let tag = size >= 26 ? "h1" : size >= 21 ? "h2" : size >= 18 ? "h3" : "p"
            var style = ""
            if r.length > 0, let ps = ts.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle {
                switch ps.alignment { case .center: style = " style=\"text-align:center\""; case .right: style = " style=\"text-align:right\""; case .justified: style = " style=\"text-align:justify\""; default: break }
            }
            out += "<\(tag)\(style)>\(inner.isEmpty ? "<br>" : inner)</\(tag)>"
        }
        if !open.isEmpty { out += "</\(open)>" }
        return out
    }
}

// MARK: - NSTextView host

struct WriterText: NSViewRepresentable {
    let doc: WriterDoc
    func makeCoordinator() -> Coordinator { Coordinator(doc) }
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        sv.appearance = NSAppearance(named: .aqua)            // paper stays white in dark mode
        sv.drawsBackground = false; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.allowsMagnification = true; sv.minMagnification = 0.5; sv.maxMagnification = 3
        sv.hasHorizontalRuler = true; sv.rulersVisible = false
        tv.isRichText = true; tv.allowsUndo = true; tv.usesFindBar = true; tv.isIncrementalSearchingEnabled = true; tv.usesRuler = true
        tv.isAutomaticSpellingCorrectionEnabled = true; tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = true; tv.importsGraphics = true
        tv.isAutomaticQuoteSubstitutionEnabled = true; tv.isAutomaticDashSubstitutionEnabled = true; tv.isAutomaticTextReplacementEnabled = true; tv.smartInsertDeleteEnabled = true
        tv.backgroundColor = .white; tv.drawsBackground = true; tv.insertionPointColor = .black
        tv.textContainerInset = NSSize(width: 64, height: 56)
        tv.typingAttributes = [.font: WriterDoc.base, .foregroundColor: NSColor.black]
        tv.textStorage?.setAttributedString(doc.initial)
        tv.delegate = context.coordinator
        doc.tv = tv; doc.storage = tv.textStorage; doc.scroll = sv; doc.updateStats(); doc.computeOutline()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv); context.coordinator.hover = DocHoverWatcher(tv) }
        return sv
    }
    func updateNSView(_ v: NSScrollView, context: Context) {}
    final class Coordinator: NSObject, NSTextViewDelegate {
        let doc: WriterDoc
        var hover: DocHoverWatcher?
        init(_ d: WriterDoc) { doc = d }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let u = link as? URL, u.scheme == "freeoffice" { DocLinks.open(url: u); return true }
            return false
        }
        func textDidChange(_ n: Notification) { doc.changed() }
        func textViewDidChangeSelection(_ n: Notification) { doc.refreshFontName(); doc.updateSelectionStats() }
        func textView(_ textView: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
            if s == " ", r.length == 0, doc.markdownShortcut(at: r.location) { return false }
            if s == "@", r.length == 0 {
                let ns = textView.string as NSString
                let prev = r.location > 0 ? ns.substring(with: NSRange(location: r.location - 1, length: 1)) : "\n"
                if prev.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || "(,".contains(prev) { DispatchQueue.main.async { DocMentionAppKit.present(in: textView, at: r.location) } }
            }
            return true
        }
        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { return doc.handleReturn() }
            return false
        }
    }
}

// MARK: - View

struct WriterView: View {
    @StateObject private var doc: WriterDoc
    @State private var outlineOpen = false
    @State private var showMedia = false
    let tab: Tab
    init(id: String, dir: URL, tab: Tab) { _doc = StateObject(wrappedValue: WriterDoc(id: id, dir: dir)); self.tab = tab }

    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
    }
    private let textPalette: [(String, NSColor)] = [("Black", .black), ("Grey", NSColor(white: 0.45, alpha: 1)), ("Red", NSColor(red: 0.85, green: 0.18, blue: 0.13, alpha: 1)), ("Orange", NSColor(red: 0.97, green: 0.56, blue: 0.04, alpha: 1)),
                                                    ("Green", NSColor(red: 0.07, green: 0.72, blue: 0.42, alpha: 1)), ("Blue", NSColor(red: 0.18, green: 0.43, blue: 0.96, alpha: 1)), ("Purple", NSColor(red: 0.48, green: 0.25, blue: 0.95, alpha: 1))]
    private let highlights: [(String, NSColor)] = [("Yellow", NSColor(red: 1, green: 0.95, blue: 0.5, alpha: 1)), ("Green", NSColor(red: 0.78, green: 0.94, blue: 0.83, alpha: 1)), ("Blue", NSColor(red: 0.81, green: 0.88, blue: 1, alpha: 1)),
                                                   ("Pink", NSColor(red: 1, green: 0.82, blue: 0.9, alpha: 1)), ("Orange", NSColor(red: 1, green: 0.85, blue: 0.7, alpha: 1))]

    /// Everything for writing, always visible: font, style, character, paragraph, list, insert, view and file controls.
    var ribbon: some View {
        GlassEffectContainer(spacing: 8) {
            WrapLayout(spacing: 8) {
                do {
                    group {
                        FontPickerButton(selection: Binding(get: { doc.fontName }, set: { doc.setFamily($0) }), width: 170)
                        Menu {
                            ForEach(WStyle.allCases) { s in Button(s.name) { doc.applyStyle(s) } }
                        } label: { Text("Style") }.menuStyle(.borderlessButton).fixedSize()
                        Menu {
                            ForEach([10, 11, 12, 14, 16, 18, 20, 24, 32, 48, 72], id: \.self) { s in Button("\(s) pt") { doc.setSize(CGFloat(s)) } }
                        } label: { Text("Size") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    group {
                        Button { doc.toggleTrait(.boldFontMask) } label: { Image(systemName: "bold") }.help("Bold (⌘B)")
                        Button { doc.toggleTrait(.italicFontMask) } label: { Image(systemName: "italic") }.help("Italic (⌘I)")
                        Button { doc.toggleLine(.underlineStyle) } label: { Image(systemName: "underline") }.help("Underline (⌘U)")
                        Button { doc.toggleLine(.strikethroughStyle) } label: { Image(systemName: "strikethrough") }.help("Strikethrough")
                        Button { doc.toggleScript(1) } label: { Image(systemName: "textformat.superscript") }.help("Superscript")
                        Button { doc.toggleScript(-1) } label: { Image(systemName: "textformat.subscript") }.help("Subscript")
                    }
                    group {
                        Menu {
                            ForEach(textPalette, id: \.0) { n, c in Button { doc.setColor(c) } label: { Label(n, systemImage: "circle.fill").foregroundStyle(Color(nsColor: c)) } }
                            Divider(); Button("More colours…") { doc.openColorPanel(highlight: false) }
                        } label: { Image(systemName: "textformat") }.menuStyle(.borderlessButton).fixedSize().help("Text colour")
                        Menu {
                            ForEach(highlights, id: \.0) { n, c in Button { doc.setHighlight(c) } label: { Label(n, systemImage: "circle.fill").foregroundStyle(Color(nsColor: c)) } }
                            Divider(); Button("More colours…") { doc.openColorPanel(highlight: true) }; Button("Remove highlight") { doc.setHighlight(nil) }
                        } label: { Image(systemName: "highlighter") }.menuStyle(.borderlessButton).fixedSize().help("Highlight")
                        Button { doc.clearFormatting() } label: { Image(systemName: "eraser") }.help("Clear formatting")
                    }
                    group {
                        Button { doc.align(.left) } label: { Image(systemName: "text.alignleft") }
                        Button { doc.align(.center) } label: { Image(systemName: "text.aligncenter") }
                        Button { doc.align(.right) } label: { Image(systemName: "text.alignright") }
                        Button { doc.align(.justified) } label: { Image(systemName: "text.justify") }
                        Menu {
                            Text("Line spacing")
                            ForEach([("Single", 1.0), ("1.15", 1.15), ("1.5", 1.5), ("Double", 2.0)], id: \.0) { n, v in Button(n) { doc.setLineSpacing(CGFloat(v)) } }
                            Divider(); Text("Space after paragraph")
                            ForEach([("None", 0.0), ("Small", 6.0), ("Medium", 12.0), ("Large", 20.0)], id: \.0) { n, v in Button(n) { doc.setParagraphSpacing(CGFloat(v)) } }
                        } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }.menuStyle(.borderlessButton).fixedSize().help("Spacing")
                    }
                    group {
                        Button { doc.toggleBullets() } label: { Image(systemName: "list.bullet") }.help("Bulleted list")
                        Button { doc.toggleNumbering() } label: { Image(systemName: "list.number") }.help("Numbered list")
                        Button { doc.indent(-1) } label: { Image(systemName: "decrease.indent") }.help("Decrease indent (⌘[)")
                        Button { doc.indent(1) } label: { Image(systemName: "increase.indent") }.help("Increase indent (⌘])")
                    }
                    group {
                        Menu {
                            Button("Link…") { doc.insertLink() }; Button("Image…") { doc.insertImage() }; Button("Photos, icons & backgrounds…") { showMedia = true }
                            Menu("Table") { ForEach([(2, 2), (3, 3), (4, 3), (5, 4)], id: \.0) { r, c in Button("\(r) × \(c)") { doc.insertTable(rows: r, cols: c) } } }
                            Button("Divider line") { doc.insertDivider() }; Button("Today's date") { doc.insertDate() }; Button("Symbols…") { doc.showSymbols() }
                        } label: { Label("Insert", systemImage: "plus.square") }.menuStyle(.borderlessButton).fixedSize()
                        Button { doc.showFind() } label: { Image(systemName: "magnifyingglass") }.help("Find & replace (⌘F)")
                        Menu {
                            Button(outlineOpen ? "Hide outline" : "Show outline") { outlineOpen.toggle() }
                            Menu("Zoom") { ForEach([0.75, 1.0, 1.25, 1.5], id: \.self) { z in Button("\(Int(z * 100))%") { doc.setZoom(z) } } }
                            Menu("Margins") { Button("Narrow") { doc.setMargin(0) }; Button("Normal") { doc.setMargin(1) }; Button("Wide") { doc.setMargin(2) } }
                            Button("Ruler") { doc.toggleRuler() }
                        } label: { Label("View", systemImage: "rectangle.expand.vertical") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    group {
                        Menu {
                            Button("Import…") { doc.importFile() }
                            Divider()
                            Menu("Export as") {
                                Button("Word (.docx)…") { doc.export("docx") }; Button("PDF…") { doc.exportPDF() }; Button("Rich Text (.rtf)…") { doc.export("rtf") }
                                Button("Web page (.html)…") { doc.export("html") }; Button("Markdown (.md)…") { doc.export("md") }; Button("Plain text (.txt)…") { doc.export("txt") }
                            }
                            Button("Print…") { doc.printDocument() }
                        } label: { Label("File", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    var outlinePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Outline", systemImage: "list.bullet.indent").font(.fo(.headline))
            if doc.outline.isEmpty { Text("Headings you add (Style → Heading 1–3) appear here.").font(.fo(.caption)).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(doc.outline) { item in
                        Button { doc.jump(to: item.location) } label: {
                            Text(item.title).font(.fo(size: item.level == 1 ? 13 : 12, weight: item.level == 1 ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                .padding(.leading, CGFloat(item.level - 1) * 14).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14).frame(width: 230).frame(maxHeight: .infinity, alignment: .top).glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    var body: some View {
        ZStack {
            Backdrop()
            HStack(alignment: .top, spacing: 14) {
                if outlineOpen { outlinePanel.padding(.top, 12) }
                VStack(spacing: 12) {
                    ribbon
                    WriterText(doc: doc)
                        .frame(maxWidth: 816)
                        .clipShape(.rect(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
            .padding(.horizontal, 14).padding(.bottom, 18)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                Image(systemName: "textformat.size")
                Text("\(doc.words) words")
                Text("· \(doc.chars) characters · \(max(1, Int((Double(doc.words) / 230).rounded(.up)))) min read")
                if doc.selWords > 0 { Text("· \(doc.selWords) selected").fontWeight(.semibold) }
                if let s = doc.savedAt { Text("· Saved \(s, format: .dateTime.hour().minute())") }
            }
            .font(.fo(.caption)).padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 14)
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Title", text: $doc.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { doc.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { doc.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
        }
        .onChange(of: doc.title, initial: true) { _, t in tab.title = t.isEmpty ? "Untitled" : t }
        .onAppear {
            tab.onUndo = { doc.undo() }; tab.onRedo = { doc.redo() }
            tab.onFormat = { cmd in
                switch cmd {
                case "bold": doc.toggleTrait(.boldFontMask); case "italic": doc.toggleTrait(.italicFontMask)
                case "underline": doc.toggleLine(.underlineStyle); case "strike": doc.toggleLine(.strikethroughStyle)
                case "link": doc.insertLink(); case "bullets": doc.toggleBullets(); case "numbers": doc.toggleNumbering()
                case "indent": doc.indent(1); case "outdent": doc.indent(-1)
                case "h1": doc.applyStyle(.h1); case "h2": doc.applyStyle(.h2); case "h3": doc.applyStyle(.h3); case "body": doc.applyStyle(.body)
                default: break
                }
            }
        }
        .onDisappear { doc.flush() }
        .sheet(isPresented: $showMedia) { MediaPanel(onPick: { doc.insertMedia($0) }, aspect: CGSize(width: 1600, height: 900)) }
    }
}
