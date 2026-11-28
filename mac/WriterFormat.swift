// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Writer's formatting, list, insert and import/export logic (kept separate from the view so it can be tested without a window).

enum WStyle: String, CaseIterable, Identifiable {
    case body, title, subtitle, h1, h2, h3, quote, code
    var id: String { rawValue }
    var name: String {
        switch self { case .body: return "Body"; case .title: return "Title"; case .subtitle: return "Subtitle"; case .h1: return "Heading 1"; case .h2: return "Heading 2"; case .h3: return "Heading 3"; case .quote: return "Quote"; case .code: return "Code" }
    }
}
enum ListKind { case none, bullet, number }
struct OutlineItem: Identifiable { let id = UUID(); var title: String; var level: Int; var location: Int }

final class ColorTarget: NSObject {
    var handler: (NSColor) -> Void = { _ in }
    @objc func changed(_ s: NSColorPanel) { handler(s.color) }
}

private let listStep: CGFloat = 28
let bulletChars: [Character] = ["•", "◦", "▪"]

extension WriterDoc {
    // MARK: paragraph helpers
    /// Each paragraph touching `r`: its text range (without newline) and enclosing range (with newline).
    func paragraphs(in r: NSRange) -> [(sub: NSRange, enc: NSRange)] {
        guard let ts = storage, ts.length > 0 else { return [] }
        let ns = ts.string as NSString
        var out: [(NSRange, NSRange)] = []
        ns.enumerateSubstrings(in: ns.paragraphRange(for: r), options: .byParagraphs) { _, sub, enc, _ in out.append((sub, enc)) }
        if ns.length > 0 && ns.character(at: ns.length - 1) == 10 && NSMaxRange(ns.paragraphRange(for: r)) == ns.length && r.location >= ns.length {
            out.append((NSRange(location: ns.length, length: 0), NSRange(location: ns.length, length: 0)))   // empty last line
        }
        return out
    }
    func unionRange(_ ps: [(sub: NSRange, enc: NSRange)]) -> NSRange {
        guard let f = ps.first, let l = ps.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: f.enc.location, length: max(1, NSMaxRange(l.enc) - f.enc.location))
    }
    func listInfo(_ s: String) -> (kind: ListKind, markerLen: Int, number: Int) {
        let c = Array(s)
        if c.count >= 2, bulletChars.contains(c[0]), c[1] == "\t" { return (.bullet, 2, 0) }
        var d = 0; while d < c.count, c[d].isNumber { d += 1 }
        if d > 0, d + 1 < c.count, c[d] == ".", c[d + 1] == "\t" { return (.number, d + 2, Int(String(c[0..<d])) ?? 1) }
        return (.none, 0, 0)
    }
    func level(of ps: NSParagraphStyle?) -> Int { max(0, Int(((ps?.firstLineHeadIndent ?? 0) / listStep).rounded())) }
    func listStyle(level: Int, base: NSParagraphStyle?) -> NSMutableParagraphStyle {
        let m = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        m.firstLineHeadIndent = listStep * CGFloat(level); m.headIndent = listStep * CGFloat(level) + 24
        m.tabStops = [NSTextTab(textAlignment: .left, location: m.headIndent)]; m.defaultTabInterval = 24
        return m
    }
    func plainStyle(from base: NSParagraphStyle?) -> NSMutableParagraphStyle {
        let m = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        m.firstLineHeadIndent = 0; m.headIndent = 0; m.tabStops = []; return m
    }
    func pStyle(at loc: Int) -> NSParagraphStyle? {
        guard let ts = storage, ts.length > 0 else { return nil }
        return ts.attribute(.paragraphStyle, at: min(loc, ts.length - 1), effectiveRange: nil) as? NSParagraphStyle
    }

    func updateParagraphStyles(_ f: (NSMutableParagraphStyle) -> Void) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let ps = paragraphs(in: tv.selectedRange())
        if ps.isEmpty || ts.length == 0 {
            var ta = tv.typingAttributes; let m = (ta[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle(); f(m); ta[.paragraphStyle] = m; tv.typingAttributes = ta; return
        }
        edit(unionRange(ps)) { s in for p in ps where p.enc.length > 0 {
            let m = (s.attribute(.paragraphStyle, at: p.enc.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            f(m); s.addAttribute(.paragraphStyle, value: m, range: p.enc)
        } }
    }
    func setLineSpacing(_ m: CGFloat) { updateParagraphStyles { $0.lineHeightMultiple = m } }
    func setParagraphSpacing(_ after: CGFloat) { updateParagraphStyles { $0.paragraphSpacing = after } }

    // MARK: named styles
    func applyStyle(_ s: WStyle) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let size: CGFloat, bold: Bool, italic: Bool, color: NSColor, before: CGFloat, after: CGFloat, indent: CGFloat
        switch s {
        case .body: (size, bold, italic, color, before, after, indent) = (16, false, false, .black, 0, 6, 0)
        case .title: (size, bold, italic, color, before, after, indent) = (38, true, false, .black, 0, 8, 0)
        case .subtitle: (size, bold, italic, color, before, after, indent) = (20, false, false, NSColor(white: 0.4, alpha: 1), 0, 14, 0)
        case .h1: (size, bold, italic, color, before, after, indent) = (30, true, false, .black, 14, 6, 0)
        case .h2: (size, bold, italic, color, before, after, indent) = (23, true, false, .black, 10, 4, 0)
        case .h3: (size, bold, italic, color, before, after, indent) = (19, true, false, .black, 8, 3, 0)
        case .quote: (size, bold, italic, color, before, after, indent) = (17, false, true, NSColor(white: 0.35, alpha: 1), 6, 6, 28)
        case .code: (size, bold, italic, color, before, after, indent) = (14, false, false, NSColor(white: 0.15, alpha: 1), 2, 2, 12)
        }
        var f: NSFont = s == .code ? (NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)) : fm.convert(fm.convert(Self.base, toFamily: fontName), toSize: size)
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) } else if s != .code { f = fm.convert(f, toNotHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) } else if s != .code { f = fm.convert(f, toNotHaveTrait: .italicFontMask) }
        let ps = paragraphs(in: tv.selectedRange())
        if ps.isEmpty {
            var ta = tv.typingAttributes; ta[.font] = f; ta[.foregroundColor] = color; tv.typingAttributes = ta; return
        }
        edit(unionRange(ps)) { storage in for p in ps where p.enc.length > 0 {
            let old = storage.attribute(.paragraphStyle, at: p.enc.location, effectiveRange: nil) as? NSParagraphStyle
            let m = (old?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            m.paragraphSpacingBefore = before; m.paragraphSpacing = after
            if listInfo(storage.string.substring(p.sub)).kind == .none { m.firstLineHeadIndent = indent; m.headIndent = indent; m.tabStops = [] }
            storage.addAttributes([.font: f, .foregroundColor: color, .paragraphStyle: m], range: p.enc)
            if s == .code { storage.addAttribute(.backgroundColor, value: NSColor(white: 0.94, alpha: 1), range: p.enc) } else { storage.removeAttribute(.backgroundColor, range: p.enc) }
        } }
        refreshFontName()
    }

    func clearFormatting() {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let r = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: ts.length)
        guard r.length > 0 else { return }
        edit(r) { s in
            s.setAttributes([.font: Self.base, .foregroundColor: NSColor.black], range: r)
        }
    }

    // MARK: lists
    func toggleList(_ kind: ListKind) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        var ps = paragraphs(in: tv.selectedRange())
        if ps.isEmpty { ts.insert(NSAttributedString(string: "", attributes: tv.typingAttributes), at: 0); ps = [(NSRange(location: 0, length: 0), NSRange(location: 0, length: 0))] }
        let ns0 = ts.string as NSString
        let allKind = ps.allSatisfy { listInfo(ns0.substring(with: $0.sub)).kind == kind }
        let editRange = unionRange(ps)
        let lengthBefore = ts.length
        defer { reselect(NSRange(location: editRange.location, length: max(0, editRange.length + ts.length - lengthBefore))) }
        edit(editRange) { s in
            let str = s.string as NSString
            for p in ps.reversed() {
                let info = listInfo(str.substring(with: p.sub))
                let old = s.length > 0 ? s.attribute(.paragraphStyle, at: min(p.enc.location, s.length - 1), effectiveRange: nil) as? NSParagraphStyle : nil
                let attrs: [NSAttributedString.Key: Any] = s.length > 0 ? s.attributes(at: min(p.sub.location, s.length - 1), effectiveRange: nil) : [.font: Self.base]
                if allKind {
                    s.deleteCharacters(in: NSRange(location: p.sub.location, length: info.markerLen))
                    let len = max(0, p.enc.length - info.markerLen)
                    if len > 0 { s.addAttribute(.paragraphStyle, value: plainStyle(from: old), range: NSRange(location: p.enc.location, length: len)) }
                } else {
                    let lvl = info.kind == .none ? 0 : level(of: old)
                    let marker = kind == .bullet ? String(bulletChars[min(lvl, 2)]) + "\t" : "1.\t"
                    var markerAttrs = attrs; markerAttrs[.backgroundColor] = nil
                    if info.kind != .none { s.replaceCharacters(in: NSRange(location: p.sub.location, length: info.markerLen), with: NSAttributedString(string: marker, attributes: markerAttrs)) }
                    else { s.insert(NSAttributedString(string: marker, attributes: markerAttrs), at: p.sub.location) }
                    let newLen = p.enc.length - info.markerLen + marker.count
                    s.addAttribute(.paragraphStyle, value: listStyle(level: lvl, base: old), range: NSRange(location: p.enc.location, length: max(1, min(newLen, s.length - p.enc.location))))
                }
            }
        }
        renumberAll()
    }
    /// Select the paragraphs that were just reformatted, so a second click acts on all of them.
    func reselect(_ r: NSRange) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let loc = min(r.location, ts.length)
        tv.setSelectedRange(NSRange(location: loc, length: min(r.length, ts.length - loc)))
    }
    func toggleBullets() { toggleList(.bullet) }
    func toggleNumbering() { toggleList(.number) }

    /// Re-numbers every numbered list (restarting after non-list paragraphs and per nesting level).
    func renumberAll() {
        guard let tv = tv, let ts = tv.textStorage, ts.length > 0 else { return }
        let ns = ts.string as NSString
        var counters: [Int: Int] = [:], edits: [(NSRange, String)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { text, sub, enc, _ in
            let info = self.listInfo(text ?? ""), lvl = self.level(of: ts.attribute(.paragraphStyle, at: min(enc.location, ts.length - 1), effectiveRange: nil) as? NSParagraphStyle)
            switch info.kind {
            case .number:
                let n = (counters[lvl] ?? 0) + 1; counters[lvl] = n; counters = counters.filter { $0.key <= lvl }
                if info.number != n { edits.append((NSRange(location: sub.location, length: info.markerLen - 1), "\(n).")) }
            case .bullet: counters = counters.filter { $0.key < lvl }
            case .none: counters = [:]
            }
        }
        guard !edits.isEmpty else { return }
        let full = NSRange(location: 0, length: ts.length)
        guard tv.shouldChangeText(in: full, replacementString: nil) else { return }
        ts.beginEditing(); for (r, s) in edits.reversed() { ts.replaceCharacters(in: r, with: s) }; ts.endEditing(); tv.didChangeText()
    }

    func indent(_ delta: Int) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let ps = paragraphs(in: tv.selectedRange()); guard !ps.isEmpty else { return }
        let whole = unionRange(ps), lengthBefore = ts.length
        defer { reselect(NSRange(location: whole.location, length: max(0, whole.length + ts.length - lengthBefore))) }
        edit(unionRange(ps)) { s in
            let str = s.string as NSString
            for p in ps.reversed() {
                let info = listInfo(str.substring(with: p.sub))
                let old = s.attribute(.paragraphStyle, at: min(p.enc.location, s.length - 1), effectiveRange: nil) as? NSParagraphStyle
                if info.kind != .none {
                    let lvl = max(0, min(5, level(of: old) + delta))
                    if info.kind == .bullet {
                        let attrs = s.attributes(at: p.sub.location, effectiveRange: nil)
                        s.replaceCharacters(in: NSRange(location: p.sub.location, length: info.markerLen), with: NSAttributedString(string: String(bulletChars[min(lvl, 2)]) + "\t", attributes: attrs))
                    }
                    s.addAttribute(.paragraphStyle, value: listStyle(level: lvl, base: old), range: NSRange(location: p.enc.location, length: max(1, min(p.enc.length, s.length - p.enc.location))))
                } else {
                    let m = (old?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    m.firstLineHeadIndent = max(0, m.firstLineHeadIndent + listStep * CGFloat(delta)); m.headIndent = max(0, m.headIndent + listStep * CGFloat(delta))
                    s.addAttribute(.paragraphStyle, value: m, range: p.enc)
                }
            }
        }
        renumberAll()
    }

    /// Return inside a list continues it; Return on an empty item ends it.
    func handleReturn() -> Bool {
        guard let tv = tv, let ts = tv.textStorage, tv.selectedRange().length == 0, ts.length > 0 else { return false }
        let ns = ts.string as NSString, loc = min(tv.selectedRange().location, ns.length)
        let ps = paragraphs(in: NSRange(location: loc == ns.length ? max(0, loc - 1) : loc, length: 0)); guard let p = ps.first else { return false }
        let text = ns.substring(with: p.sub), info = listInfo(text)
        guard info.kind != .none else { return false }
        let content = String(text.dropFirst(info.markerLen)).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            edit(p.enc) { s in
                s.deleteCharacters(in: NSRange(location: p.sub.location, length: info.markerLen))
                let len = max(0, p.enc.length - info.markerLen)
                if len > 0 { s.addAttribute(.paragraphStyle, value: self.plainStyle(from: s.attribute(.paragraphStyle, at: p.enc.location, effectiveRange: nil) as? NSParagraphStyle), range: NSRange(location: p.enc.location, length: len)) }
            }
            return true
        }
        let lvl = level(of: pStyle(at: p.sub.location))
        let marker = info.kind == .bullet ? String(bulletChars[min(lvl, 2)]) + "\t" : "\(info.number + 1).\t"
        tv.insertText("\n" + marker, replacementRange: tv.selectedRange())
        DispatchQueue.main.async { self.renumberAll() }
        return true
    }

    // MARK: Markdown-style shortcuts (type "# ", "- ", "1. ", "> " at the start of a line)
    func markdownShortcut(at loc: Int) -> Bool {
        guard let tv = tv, let ts = tv.textStorage else { return false }
        let ns = ts.string as NSString; guard loc <= ns.length else { return false }
        let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        let prefix = ns.substring(with: NSRange(location: pr.location, length: loc - pr.location))
        guard !prefix.isEmpty, prefix.count <= 4, listInfo(ns.substring(with: pr)).kind == .none else { return false }
        enum Action { case style(WStyle), list(ListKind) }
        let action: Action
        switch prefix {
        case "#": action = .style(.h1); case "##": action = .style(.h2); case "###": action = .style(.h3)
        case "-", "*", "+": action = .list(.bullet); case ">": action = .style(.quote)
        default:
            if prefix.hasSuffix("."), Int(prefix.dropLast()) != nil { action = .list(.number) } else { return false }
        }
        DispatchQueue.main.async {
            let pre = NSRange(location: pr.location, length: prefix.count)
            self.edit(pre) { $0.deleteCharacters(in: pre) }
            tv.setSelectedRange(NSRange(location: pr.location, length: 0))
            switch action { case .style(let s): self.applyStyle(s); case .list(let k): self.toggleList(k) }
        }
        return true
    }

    // MARK: character formatting
    func setHighlight(_ c: NSColor?) {
        guard let tv = tv else { return }
        let r = tv.selectedRange()
        if r.length == 0 { var ta = tv.typingAttributes; ta[.backgroundColor] = c; tv.typingAttributes = ta; return }
        edit(r) { s in if let c = c { s.addAttribute(.backgroundColor, value: c, range: r) } else { s.removeAttribute(.backgroundColor, range: r) } }
    }
    func toggleScript(_ sign: Int) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let r = tv.selectedRange()
        if r.length == 0 { var ta = tv.typingAttributes; ta[.superscript] = (ta[.superscript] as? Int) == sign ? nil : sign; tv.typingAttributes = ta; return }
        let has = (ts.attribute(.superscript, at: r.location, effectiveRange: nil) as? Int) == sign
        edit(r) { s in if has { s.removeAttribute(.superscript, range: r) } else { s.addAttribute(.superscript, value: sign, range: r) } }
    }
    func openColorPanel(highlight: Bool) {
        colorTarget.handler = { [weak self] c in if highlight { self?.setHighlight(c) } else { self?.setColor(c) } }
        let p = NSColorPanel.shared; p.setTarget(colorTarget); p.setAction(#selector(ColorTarget.changed(_:))); p.isContinuous = true; p.orderFront(nil)
    }

    // MARK: insert
    func prompt(_ title: String, _ value: String = "") -> String? {
        let a = NSAlert(); a.messageText = title; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); f.stringValue = value; a.accessoryView = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }
    func insertLink() {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let r = tv.selectedRange()
        let existing = r.length > 0 && r.location < ts.length ? (ts.attribute(.link, at: r.location, effectiveRange: nil).map { "\($0)" } ?? "") : ""
        guard let url = prompt("Link address (leave empty to remove)", existing) else { return }
        let u = url.trimmingCharacters(in: .whitespaces)
        if r.length == 0 {
            guard !u.isEmpty else { return }
            tv.insertText(NSAttributedString(string: u, attributes: [.link: URL(string: u.contains("://") ? u : "https://" + u) as Any, .font: Self.base]), replacementRange: r)
        } else {
            edit(r) { s in if u.isEmpty { s.removeAttribute(.link, range: r) } else { s.addAttribute(.link, value: URL(string: u.contains("://") ? u : "https://" + u) as Any, range: r) } }
        }
    }
    func insertImage() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) else { return }
        insertImage(img)
    }
    func insertImage(_ img: NSImage, maxWidth: CGFloat = 480) {
        guard let tv = tv else { return }
        let k = min(1, maxWidth / max(img.size.width, 1)), att = NSTextAttachment()
        att.image = img; att.bounds = CGRect(x: 0, y: 0, width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        tv.insertText(NSAttributedString(attachment: att), replacementRange: tv.selectedRange())
    }
    func insertMedia(_ p: MediaPick) {
        guard let img = p.image, let tv = tv else { return }
        insertImage(img, maxWidth: p.symbol != nil ? 96 : 480)
        if let c = p.credit {
            let f = NSFontManager.shared.convert(NSFont(name: "Helvetica Neue", size: 11) ?? .systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
            tv.insertText(NSAttributedString(string: "\n" + c + "\n", attributes: [.font: f, .foregroundColor: NSColor(white: 0.45, alpha: 1)]), replacementRange: tv.selectedRange())
            tv.typingAttributes = [.font: WriterDoc.base, .foregroundColor: NSColor.black]
        }
    }
    func insertTable(rows: Int, cols: Int) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let table = NSTextTable(); table.numberOfColumns = cols; table.setContentWidth(100, type: .percentageValueType)
        let out = NSMutableAttributedString()
        let fm = NSFontManager.shared
        for r in 0..<rows { for c in 0..<cols {
            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
            block.setBorderColor(NSColor(white: 0.7, alpha: 1)); block.setWidth(0.75, type: .absoluteValueType, for: .border); block.setWidth(6, type: .absoluteValueType, for: .padding)
            if r == 0 { block.backgroundColor = NSColor(white: 0.95, alpha: 1) }
            let ps = NSMutableParagraphStyle(); ps.textBlocks = [block]
            let f = r == 0 ? fm.convert(Self.base, toHaveTrait: .boldFontMask) : Self.base
            out.append(NSAttributedString(string: (r == 0 ? "Heading \(c + 1)" : "") + "\n", attributes: [.font: f, .paragraphStyle: ps, .foregroundColor: NSColor.black]))
        } }
        var loc = tv.selectedRange().location
        let ns = ts.string as NSString
        if loc > 0, loc <= ns.length, ns.character(at: loc - 1) != 10 { out.insert(NSAttributedString(string: "\n", attributes: [.font: Self.base]), at: 0) }
        out.append(NSAttributedString(string: "\n", attributes: [.font: Self.base, .foregroundColor: NSColor.black]))
        loc = min(loc, ns.length)
        tv.insertText(out, replacementRange: NSRange(location: loc, length: tv.selectedRange().length))
    }
    func insertDivider() {
        guard let tv = tv else { return }
        let table = NSTextTable(); table.numberOfColumns = 1; table.setContentWidth(100, type: .percentageValueType)
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setBorderColor(NSColor(white: 0.55, alpha: 1)); block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY); block.setWidth(2, type: .absoluteValueType, for: .padding)
        let ps = NSMutableParagraphStyle(); ps.textBlocks = [block]
        let s = NSMutableAttributedString(string: "\u{200B}\n", attributes: [.paragraphStyle: ps, .font: NSFont.systemFont(ofSize: 6)])
        s.append(NSAttributedString(string: "\n", attributes: [.font: Self.base, .foregroundColor: NSColor.black]))
        tv.insertText(s, replacementRange: tv.selectedRange())
    }
    func insertDate() {
        guard let tv = tv else { return }
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        tv.insertText(f.string(from: Date()), replacementRange: tv.selectedRange())
    }
    func showSymbols() { NSApp.orderFrontCharacterPalette(nil) }
    func showFind() { let i = NSMenuItem(); i.tag = Int(NSFindPanelAction.showFindPanel.rawValue); tv?.performFindPanelAction(i); tv?.window?.makeFirstResponder(tv) }

    // MARK: view
    func setZoom(_ z: Double) { zoom = z; scroll?.magnification = CGFloat(z) }
    func setMargin(_ m: Int) { margin = m; let w: CGFloat = m == 0 ? 32 : m == 2 ? 100 : 64; tv?.textContainerInset = NSSize(width: w, height: 56) }
    func toggleRuler() { scroll?.rulersVisible.toggle() }
    func jump(to loc: Int) {
        guard let tv = tv else { return }
        let r = NSRange(location: min(loc, (tv.string as NSString).length), length: 0)
        tv.setSelectedRange(r); tv.scrollRangeToVisible(NSRange(location: r.location, length: 1)); tv.window?.makeFirstResponder(tv)
    }

    // MARK: stats & outline
    func updateStats() {
        let t = storage?.string ?? ""
        words = t.split { $0.isWhitespace || $0.isNewline }.count
        chars = t.filter { !$0.isNewline }.count
    }
    func updateSelectionStats() {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let r = tv.selectedRange()
        selWords = r.length > 0 && NSMaxRange(r) <= ts.length ? ts.attributedSubstring(from: r).string.split { $0.isWhitespace || $0.isNewline }.count : 0
    }
    func computeOutline() {
        guard let ts = storage, ts.length > 0 else { outline = []; return }
        let ns = ts.string as NSString; var out: [OutlineItem] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { text, sub, _, _ in
            guard sub.length > 0, let text = text, text.count <= 120 else { return }
            guard let f = ts.attribute(.font, at: sub.location, effectiveRange: nil) as? NSFont, NSFontManager.shared.traits(of: f).contains(.boldFontMask), f.pointSize >= 19 else { return }
            let level = f.pointSize >= 26 ? 1 : f.pointSize >= 21 ? 2 : 3
            out.append(OutlineItem(title: text.trimmingCharacters(in: .whitespaces), level: level, location: sub.location))
        }
        outline = out
    }

    // MARK: import / export
    func printingView() -> NSTextView {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let w = max(200, info.paperSize.width - info.leftMargin - info.rightMargin)
        let pv = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        pv.appearance = NSAppearance(named: .aqua); pv.isVerticallyResizable = true; pv.isHorizontallyResizable = false
        pv.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude); pv.textContainer?.widthTracksTextView = true
        pv.textStorage?.setAttributedString(NSAttributedString(attributedString: storage ?? NSTextStorage()))
        pv.layoutManager?.ensureLayout(for: pv.textContainer!); pv.sizeToFit()
        return pv
    }
    func printDocument() { NSPrintOperation(view: printingView(), printInfo: NSPrintInfo.shared).run() }
    func exportPDF() { if let u = savePanel(title + ".pdf") { writePDF(to: u) } }
    func writePDF(to u: URL) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save; info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = u
        let op = NSPrintOperation(view: printingView(), printInfo: info); op.showsPrintPanel = false; op.showsProgressPanel = false; _ = op.run()
    }
    func fullRange() -> NSRange { NSRange(location: 0, length: storage?.length ?? 0) }
    func exportData(_ type: NSAttributedString.DocumentType) -> Data? {
        guard let ts = storage else { return nil }
        return try? ts.data(from: fullRange(), documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue])
    }
    func export(_ kind: String) {
        let ext: String, data: Data?
        switch kind {
        case "docx": ext = "docx"; data = exportData(.officeOpenXML)
        case "rtf": ext = "rtf"; data = exportData(.rtf)
        case "html": ext = "html"; data = exportData(.html)
        case "md": ext = "md"; data = markdown().data(using: .utf8)
        default: ext = "txt"; data = (storage?.string ?? "").data(using: .utf8)
        }
        guard let d = data, let u = savePanel(title + "." + ext) else { return }
        try? d.write(to: u)
    }
    func markdown() -> String {
        guard let ts = storage, ts.length > 0 else { return "" }
        let ns = ts.string as NSString, fm = NSFontManager.shared
        var lines: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { text, sub, _, _ in
            let t = text ?? ""; let info = self.listInfo(t)
            let body = NSRange(location: sub.location + info.markerLen, length: max(0, sub.length - info.markerLen))
            var s = ""
            if body.length > 0 { ts.enumerateAttributes(in: body) { at, rr, _ in
                var piece = ns.substring(with: rr)
                if let f = at[.font] as? NSFont { let tr = fm.traits(of: f); if tr.contains(.boldFontMask) && f.pointSize < 19 { piece = "**\(piece)**" }; if tr.contains(.italicFontMask) { piece = "*\(piece)*" } }
                if let l = at[.link] { piece = "[\(piece)](\(l))" }
                s += piece
            } }
            let size = sub.length > 0 ? ((ts.attribute(.font, at: sub.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 16) : 16
            let lvl = self.level(of: self.pStyle(at: sub.location))
            let pad = String(repeating: "  ", count: lvl)
            switch info.kind {
            case .bullet: lines.append(pad + "- " + s)
            case .number: lines.append(pad + "\(info.number). " + s)
            case .none:
                if size >= 30 { lines.append("# " + s) } else if size >= 21 { lines.append("## " + s) } else if size >= 19 { lines.append("### " + s) } else { lines.append(s) }
            }
        }
        return lines.joined(separator: "\n")
    }
    func replaceAll(with a: NSAttributedString) {
        guard let tv = tv, let ts = tv.textStorage else { return }
        let full = NSRange(location: 0, length: ts.length)
        guard tv.shouldChangeText(in: full, replacementString: a.string) else { return }
        ts.beginEditing(); ts.setAttributedString(a); ts.endEditing(); tv.didChangeText()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
    }
    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.rtf, .rtfd, .html, .plainText, UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc"), UTType(filenameExtension: "md")].compactMap { $0 }
        guard p.runModal() == .OK, let u = p.url else { return }
        importFile(u)
    }
    func importFile(_ u: URL) {
        let ext = u.pathExtension.lowercased()
        var result: NSAttributedString?
        if ext == "md" || ext == "markdown" { if let s = try? String(contentsOf: u, encoding: .utf8) { result = markdownAttributed(s) } }
        else if ext == "txt" { if let s = try? String(contentsOf: u, encoding: .utf8) { result = NSAttributedString(string: s, attributes: [.font: Self.base, .foregroundColor: NSColor.black]) } }
        else { result = try? NSAttributedString(url: u, options: [:], documentAttributes: nil) }
        guard let a = result else { return }
        replaceAll(with: a)
        if title == "Untitled" || title.isEmpty { title = u.deletingPathExtension().lastPathComponent }
    }

    /// A small Markdown reader: # headings, - bullets, 1. numbers, > quotes, **bold**, *italic*, `code`, [links](url).
    func markdownAttributed(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString(), fm = NSFontManager.shared
        func font(_ size: CGFloat, bold: Bool, italic: Bool, mono: Bool = false) -> NSFont {
            var f: NSFont = mono ? (NSFont(name: "Menlo", size: size - 2) ?? Self.base) : fm.convert(Self.base, toSize: size)
            if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }; if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }; return f
        }
        func inline(_ s: String, size: CGFloat, bold b0: Bool, italic i0: Bool, color: NSColor) -> NSAttributedString {
            let r = NSMutableAttributedString(); var bold = b0, italic = i0, i = s.startIndex
            func add(_ t: String, mono: Bool = false, link: String? = nil) {
                var at: [NSAttributedString.Key: Any] = [.font: font(size, bold: bold, italic: italic, mono: mono), .foregroundColor: color]
                if mono { at[.backgroundColor] = NSColor(white: 0.93, alpha: 1) }
                if let l = link, let u = URL(string: l) { at[.link] = u }
                r.append(NSAttributedString(string: t, attributes: at))
            }
            while i < s.endIndex {
                let rest = s[i...]
                if rest.hasPrefix("**") { bold.toggle(); i = s.index(i, offsetBy: 2) }
                else if rest.hasPrefix("*") || rest.hasPrefix("_") { italic.toggle(); i = s.index(after: i) }
                else if rest.hasPrefix("`"), let e = rest.dropFirst().firstIndex(of: "`") { add(String(rest[rest.index(after: rest.startIndex)..<e]), mono: true); i = s.index(after: e) }
                else if rest.hasPrefix("["), let close = rest.firstIndex(of: "]"), rest[rest.index(after: close)...].hasPrefix("("), let e = rest[close...].firstIndex(of: ")") {
                    add(String(rest[rest.index(after: rest.startIndex)..<close]), link: String(rest[rest.index(close, offsetBy: 2)..<e])); i = s.index(after: e)
                } else { add(String(s[i])); i = s.index(after: i) }
            }
            return r
        }
        var num = 0
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw, size: CGFloat = 16, bold = false, italic = false, color = NSColor.black, prefix = "", ps = NSMutableParagraphStyle()
            ps.paragraphSpacing = 6
            if line.hasPrefix("### ") { line = String(line.dropFirst(4)); size = 19; bold = true; ps.paragraphSpacingBefore = 8; num = 0 }
            else if line.hasPrefix("## ") { line = String(line.dropFirst(3)); size = 23; bold = true; ps.paragraphSpacingBefore = 10; num = 0 }
            else if line.hasPrefix("# ") { line = String(line.dropFirst(2)); size = 30; bold = true; ps.paragraphSpacingBefore = 14; num = 0 }
            else if line.hasPrefix("> ") { line = String(line.dropFirst(2)); italic = true; color = NSColor(white: 0.35, alpha: 1); ps.firstLineHeadIndent = 28; ps.headIndent = 28; num = 0 }
            else if let m = line.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
                let lvl = line[m].filter { $0 == " " }.count / 2; line = String(line[m.upperBound...]); prefix = String(bulletChars[min(lvl, 2)]) + "\t"
                ps = listStyle(level: lvl, base: ps); num = 0
            } else if let m = line.range(of: #"^(\s*)\d+\. "#, options: .regularExpression) {
                let lvl = line[m].filter { $0 == " " }.count / 2; line = String(line[m.upperBound...]); num += 1; prefix = "\(num).\t"; ps = listStyle(level: lvl, base: ps)
            } else { num = 0 }
            let l = NSMutableAttributedString()
            if !prefix.isEmpty { l.append(NSAttributedString(string: prefix, attributes: [.font: font(size, bold: false, italic: false), .foregroundColor: color])) }
            l.append(inline(line, size: size, bold: bold, italic: italic, color: color)); l.append(NSAttributedString(string: "\n", attributes: [.font: font(size, bold: bold, italic: italic)]))
            l.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: l.length)); out.append(l)
        }
        return out
    }
}

private extension String {
    func substring(_ r: NSRange) -> String { (self as NSString).substring(with: r) }
}
