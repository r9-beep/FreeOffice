import SwiftUI
import AppKit

let sheetCols = 52, sheetRows = 500
let cellH: CGFloat = 28, rowHeadW: CGFloat = 46, defaultColW: CGFloat = 108

struct CellStyle: Equatable {
    var b = false, i = false
    var color = "", fill = "", align = "", nf = ""       // hex colours · "left"/"center"/"right" · number-format code
    var isDefault: Bool { !b && !i && color.isEmpty && fill.isEmpty && align.isEmpty && nf.isEmpty }
    init() {}
    init(json d: [String: Any]) {
        b = (d["b"] as? Bool) ?? false; i = (d["i"] as? Bool) ?? false
        color = (d["c"] as? String) ?? ""; fill = (d["f"] as? String) ?? ""; align = (d["a"] as? String) ?? ""; nf = (d["n"] as? String) ?? ""
    }
    var json: [String: Any] {
        var o: [String: Any] = [:]
        if b { o["b"] = true }; if i { o["i"] = true }
        if !color.isEmpty { o["c"] = color }; if !fill.isEmpty { o["f"] = fill }; if !align.isEmpty { o["a"] = align }; if !nf.isEmpty { o["n"] = nf }
        return o
    }
}

struct ChartSpec: Equatable, Identifiable { var id: Int; var type: String; var range: String; var title: String }   // bar | line | area | pie

struct SheetData: Equatable {
    var name: String
    var cells: [String: String] = [:]
    var styles: [String: CellStyle] = [:]
    var colW: [Int: Double] = [:]
    var charts: [ChartSpec] = []
}
struct BookState: Equatable { var sheets: [SheetData]; var active: Int }
struct SelRect: Equatable {
    var c0: Int, r0: Int, c1: Int, r1: Int
    func contains(_ c: Int, _ r: Int) -> Bool { c >= c0 && c <= c1 && r >= r0 && r <= r1 }
    var cols: Int { c1 - c0 + 1 }; var rows: Int { r1 - r0 + 1 }
    var isSingle: Bool { c0 == c1 && r0 == r1 }
    var label: String { isSingle ? cellAddress(c0, r0) : cellAddress(c0, r0) + ":" + cellAddress(c1, r1) }
}
struct ChartData { var cats: [String]; var series: [(name: String, vals: [Double])] }

/// What ⌘C remembers, so pasting inside FreeOffice keeps formulas (shifted) and formatting.
struct ClipBlock { var c: Int, r: Int, raw: [[String]], styles: [[CellStyle]], tsv: String }

final class SheetModel: ObservableObject {
    let history = UndoHistory<BookState>()
    @Published var title: String { didSet { if ready { saver.touch() } } }
    @Published var sheets: [SheetData] { didSet { recalc(); if ready { history.record(BookState(sheets: oldValue, active: active)); saver.touch() } } }
    @Published var active = 0 { didSet { recalc() } }
    @Published var values: [String: CV] = [:]
    @Published var anchorC = 0
    @Published var anchorR = 0
    @Published var curC = 0
    @Published var curR = 0
    @Published var editing = false
    @Published var draft = ""
    @Published var savedAt: Date?
    @Published var status: String?
    private(set) var engine = SheetEngine([:])
    static var clip: ClipBlock?
    let saver: AutoSaver
    private var ready = false

    init(id: String, dir: URL) {
        saver = AutoSaver(url: docURL(dir, "sheets", id))
        var t = "", book: [SheetData] = []
        if let d = try? Data(contentsOf: saver.url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            t = (o["title"] as? String) ?? ""
            if let arr = o["sheets"] as? [[String: Any]] {
                book = arr.map { SheetModel.parseSheet($0) }
            } else {                                              // older single-sheet documents
                var s = SheetData(name: "Sheet1")
                for (k, v) in (o["cells"] as? [String: Any]) ?? [:] { s.cells[k] = "\(v)" }
                for k in ((o["bold"] as? [String: Any]) ?? [:]).keys { var st = CellStyle(); st.b = true; s.styles[k] = st }
                book = [s]
            }
        }
        if book.isEmpty { book = [SheetData(name: "Sheet1")] }
        title = t; sheets = book
        recalc(); ready = true
        saver.make = { [weak self] in self?.encode() }
        saver.onSaved = { [weak self] in self?.savedAt = Date() }
    }

    // MARK: persistence
    static func parseSheet(_ o: [String: Any]) -> SheetData {
        var s = SheetData(name: (o["name"] as? String) ?? "Sheet")
        for (k, v) in (o["cells"] as? [String: Any]) ?? [:] { s.cells[k] = "\(v)" }
        for (k, v) in (o["styles"] as? [String: Any]) ?? [:] { if let d = v as? [String: Any] { let st = CellStyle(json: d); if !st.isDefault { s.styles[k] = st } } }
        for (k, v) in (o["colW"] as? [String: Any]) ?? [:] { if let c = Int(k), let w = (v as? NSNumber)?.doubleValue { s.colW[c] = w } }
        for c in (o["charts"] as? [[String: Any]]) ?? [] {
            if let id = (c["id"] as? NSNumber)?.intValue { s.charts.append(ChartSpec(id: id, type: (c["type"] as? String) ?? "bar", range: (c["range"] as? String) ?? "A1:B2", title: (c["title"] as? String) ?? "")) }
        }
        return s
    }
    func encode() -> Data? {
        let arr: [[String: Any]] = sheets.map { s in
            ["name": s.name, "cells": s.cells,
             "styles": Dictionary(uniqueKeysWithValues: s.styles.map { ($0.key, $0.value.json) }),
             "colW": Dictionary(uniqueKeysWithValues: s.colW.map { (String($0.key), $0.value) }),
             "charts": s.charts.map { ["id": $0.id, "type": $0.type, "range": $0.range, "title": $0.title] }]
        }
        let first = sheets[0]
        let o: [String: Any] = ["title": title, "sheets": arr, "active": active, "modified": nowMillis(),
                                "cells": first.cells, "bold": Dictionary(uniqueKeysWithValues: first.styles.filter { $0.value.b }.map { ($0.key, 1) })]   // legacy keys keep old readers working
        return try? JSONSerialization.data(withJSONObject: o)
    }

    // MARK: derived
    var sheet: SheetData { sheets[min(active, sheets.count - 1)] }
    func recalc() {
        guard !sheets.isEmpty else { return }
        if active >= sheets.count { active = sheets.count - 1 }
        engine = SheetEngine(sheets: Dictionary(sheets.map { ($0.name, $0.cells) }, uniquingKeysWith: { a, _ in a }), current: sheets[active].name)
        values = engine.all()
    }
    func mutate(_ f: (inout SheetData) -> Void) { var s = sheets[active]; f(&s); if s != sheets[active] { sheets[active] = s } }

    var rect: SelRect { SelRect(c0: min(anchorC, curC), r0: min(anchorR, curR), c1: max(anchorC, curC), r1: max(anchorR, curR)) }
    var addr: String { cellAddress(curC, curR) }
    func raw(_ a: String) -> String { sheet.cells[a] ?? "" }
    func style(_ a: String) -> CellStyle { sheet.styles[a] ?? CellStyle() }
    func colWidth(_ c: Int) -> CGFloat { CGFloat(sheet.colW[c] ?? Double(defaultColW)) }
    func display(_ a: String) -> (text: String, number: Bool, error: Bool) {
        guard let v = values[a] else { return ("", false, false) }
        return (formatDisplay(v, style(a).nf), v.isNumber, v.isError)
    }
    func usedBounds() -> (c: Int, r: Int)? {
        var mc = -1, mr = -1
        for k in sheet.cells.keys { if let p = parseAddress(k) { mc = max(mc, p.c); mr = max(mr, p.r) } }
        return mc < 0 ? nil : (mc, mr)
    }

    // MARK: selection
    func select(_ c: Int, _ r: Int, extend: Bool = false) {
        commitEdit()
        let c = max(0, min(sheetCols - 1, c)), r = max(0, min(sheetRows - 1, r))
        curC = c; curR = r; if !extend { anchorC = c; anchorR = r }
    }
    func move(_ dc: Int, _ dr: Int, extend: Bool = false) { select(curC + dc, curR + dr, extend: extend) }
    func selectRow(_ r: Int) { commitEdit(); anchorC = 0; curC = sheetCols - 1; anchorR = r; curR = r }
    func selectCol(_ c: Int) { commitEdit(); anchorC = c; curC = c; anchorR = 0; curR = sheetRows - 1 }
    func selectAll() { commitEdit(); anchorC = 0; anchorR = 0; curC = sheetCols - 1; curR = sheetRows - 1 }

    // MARK: editing
    func startEdit(_ initial: String? = nil) { draft = initial ?? raw(addr); editing = true }
    func commitEdit() { if editing { set(addr, draft); editing = false } }
    func cancelEdit() { editing = false }
    func set(_ a: String, _ v: String) { mutate { if v.isEmpty { $0.cells[a] = nil } else { $0.cells[a] = v } } }
    func clearSelection() { let r = rect; mutate { s in for row in r.r0...r.r1 { for c in r.c0...r.c1 { s.cells[cellAddress(c, row)] = nil } } } }
    func clearFormats() { let r = rect; mutate { s in for row in r.r0...r.r1 { for c in r.c0...r.c1 { s.styles[cellAddress(c, row)] = nil } } } }

    // MARK: styling
    func applyStyle(_ f: (inout CellStyle) -> Void) {
        let r = rect
        mutate { s in
            for row in r.r0...r.r1 { for c in r.c0...r.c1 {
                let a = cellAddress(c, row); var st = s.styles[a] ?? CellStyle(); f(&st); s.styles[a] = st.isDefault ? nil : st
            } }
        }
    }
    func toggleBold() { let on = !style(addr).b; applyStyle { $0.b = on } }
    func toggleItalic() { let on = !style(addr).i; applyStyle { $0.i = on } }
    func setColumnWidth(_ c: Int, _ w: Double) { mutate { $0.colW[c] = max(36, min(600, w)) } }

    // MARK: clipboard
    func tsv(_ r: SelRect) -> String {
        (r.r0...r.r1).map { row in (r.c0...r.c1).map { display(cellAddress($0, row)).text }.joined(separator: "\t") }.joined(separator: "\n")
    }
    func copy() -> String {
        commitEdit(); let r = rect
        let raws = (r.r0...r.r1).map { row in (r.c0...r.c1).map { raw(cellAddress($0, row)) } }
        let styles = (r.r0...r.r1).map { row in (r.c0...r.c1).map { style(cellAddress($0, row)) } }
        let text = tsv(r)
        SheetModel.clip = ClipBlock(c: r.c0, r: r.r0, raw: raws, styles: styles, tsv: text)
        return text
    }
    func cut() -> String { let t = copy(); clearSelection(); return t }
    func paste(_ text: String) {
        commitEdit(); let r = rect
        if let clip = SheetModel.clip, clip.tsv == text {
            let h = clip.raw.count, w = clip.raw.first?.count ?? 0
            let fillSel = h == 1 && w == 1 && !r.isSingle
            let rows = fillSel ? r.rows : h, cols = fillSel ? r.cols : w
            mutate { s in
                for dy in 0..<rows { for dx in 0..<cols {
                    let c = r.c0 + dx, row = r.r0 + dy
                    guard c < sheetCols, row < sheetRows else { continue }
                    let sy = fillSel ? 0 : dy, sx = fillSel ? 0 : dx
                    let a = cellAddress(c, row), v = shiftFormula(clip.raw[sy][sx], dc: c - (clip.c + sx), dr: row - (clip.r + sy))
                    s.cells[a] = v.isEmpty ? nil : v
                    let st = clip.styles[sy][sx]; s.styles[a] = st.isDefault ? nil : st
                } }
            }
            anchorC = r.c0; anchorR = r.r0; curC = min(sheetCols - 1, r.c0 + cols - 1); curR = min(sheetRows - 1, r.r0 + rows - 1)
        } else {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            let grid = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            mutate { s in
                for (dy, line) in grid.enumerated() { for (dx, v) in line.enumerated() {
                    let c = r.c0 + dx, row = r.r0 + dy; guard c < sheetCols, row < sheetRows else { continue }
                    s.cells[cellAddress(c, row)] = v.isEmpty ? nil : v
                } }
            }
            anchorC = r.c0; anchorR = r.r0; curC = min(sheetCols - 1, r.c0 + (grid.map(\.count).max() ?? 1) - 1); curR = min(sheetRows - 1, r.r0 + grid.count - 1)
        }
    }

    // MARK: fill
    func fillDown() {
        let r = rect; let src = r.r1 > r.r0 ? r.r0 : r.r0 - 1
        guard src >= 0 else { return }
        mutate { s in
            for c in r.c0...r.c1 {
                let sa = cellAddress(c, src), raw = s.cells[sa] ?? "", st = s.styles[sa]
                for row in (src == r.r0 ? r.r0 + 1 : r.r0)...r.r1 {
                    let a = cellAddress(c, row), v = shiftFormula(raw, dc: 0, dr: row - src)
                    s.cells[a] = v.isEmpty ? nil : v; s.styles[a] = st
                }
            }
        }
    }
    func fillRight() {
        let r = rect; let src = r.c1 > r.c0 ? r.c0 : r.c0 - 1
        guard src >= 0 else { return }
        mutate { s in
            for row in r.r0...r.r1 {
                let sa = cellAddress(src, row), raw = s.cells[sa] ?? "", st = s.styles[sa]
                for c in (src == r.c0 ? r.c0 + 1 : r.c0)...r.c1 {
                    let a = cellAddress(c, row), v = shiftFormula(raw, dc: c - src, dr: 0)
                    s.cells[a] = v.isEmpty ? nil : v; s.styles[a] = st
                }
            }
        }
    }

    // MARK: sort (by the cursor column; a lone cell sorts the whole data region)
    func sortSelection(ascending: Bool) {
        commitEdit()
        var rc = rect
        if rc.isSingle, let u = usedBounds() { rc = SelRect(c0: 0, r0: 0, c1: u.c, r1: u.r) }
        let key = max(rc.c0, min(rc.c1, curC))
        var top = rc.r0
        if rc.r1 > rc.r0, case .str = values[cellAddress(key, rc.r0)] ?? .empty, case .num = values[cellAddress(key, rc.r0 + 1)] ?? .empty { top += 1 }   // skip a header row
        guard rc.r1 > top else { return }
        struct Row { var src: Int; var cells: [(String, CellStyle?)]; var key: CV }
        var rows: [Row] = []
        let s0 = sheets[active]
        for r in top...rc.r1 {
            rows.append(Row(src: r, cells: (rc.c0...rc.c1).map { c in let a = cellAddress(c, r); return (s0.cells[a] ?? "", s0.styles[a]) }, key: values[cellAddress(key, r)] ?? .empty))
        }
        func rank(_ v: CV) -> Int { switch v { case .empty: return 3; case .num, .bool: return 0; default: return 1 } }
        rows.sort { a, b in
            if rank(a.key) != rank(b.key) { return rank(a.key) < rank(b.key) }
            if rank(a.key) == 3 { return false }
            let lt: Bool
            if case .num(let x) = a.key, case .num(let y) = b.key { lt = x < y } else { lt = a.key.text.localizedCaseInsensitiveCompare(b.key.text) == .orderedAscending }
            let gt: Bool
            if case .num(let x) = a.key, case .num(let y) = b.key { gt = x > y } else { gt = a.key.text.localizedCaseInsensitiveCompare(b.key.text) == .orderedDescending }
            return ascending ? lt : gt
        }
        mutate { s in
            for (i, row) in rows.enumerated() {
                let dest = top + i
                for (j, cell) in row.cells.enumerated() {
                    let a = cellAddress(rc.c0 + j, dest), v = shiftFormula(cell.0, dc: 0, dr: dest - row.src)
                    s.cells[a] = v.isEmpty ? nil : v; s.styles[a] = cell.1
                }
            }
        }
    }

    // MARK: insert / delete rows & columns (formulas everywhere are repaired)
    func restructure(columns: Bool, at: Int, count: Int, insert: Bool) {
        commitEdit()
        var book = sheets
        let target = book[active].name
        func remap(_ key: String) -> String? {
            guard let p = parseAddress(key) else { return key }
            let idx = columns ? p.c : p.r
            var n = idx
            if insert { if idx >= at { n = idx + count } }
            else { if idx >= at && idx < at + count { return nil }; if idx >= at + count { n = idx - count } }
            if n >= (columns ? sheetCols : sheetRows) { return nil }
            return columns ? cellAddress(n, p.r) : cellAddress(p.c, n)
        }
        for si in book.indices {
            var cells: [String: String] = [:]
            for (k, v) in book[si].cells {
                var f = v
                for _ in 0..<count { f = adjustRefs(f, formulaSheet: book[si].name, target: target, columns: columns, at: at, delta: insert ? 1 : -1) }
                if si == active { if let nk = remap(k) { cells[nk] = f } } else { cells[k] = f }
            }
            book[si].cells = cells
        }
        var styles: [String: CellStyle] = [:]
        for (k, v) in book[active].styles { if let nk = remap(k) { styles[nk] = v } }
        book[active].styles = styles
        if columns {
            var w: [Int: Double] = [:]
            for (c, x) in book[active].colW { if insert { w[c >= at ? c + count : c] = x } else if c < at { w[c] = x } else if c >= at + count { w[c - count] = x } }
            book[active].colW = w
        }
        sheets = book
    }
    func insertRows() { let r = rect; restructure(columns: false, at: r.r0, count: r.rows, insert: true) }
    func deleteRows() { let r = rect; restructure(columns: false, at: r.r0, count: r.rows, insert: false); select(curC, min(r.r0, sheetRows - 1)) }
    func insertCols() { let r = rect; restructure(columns: true, at: r.c0, count: r.cols, insert: true) }
    func deleteCols() { let r = rect; restructure(columns: true, at: r.c0, count: r.cols, insert: false); select(min(r.c0, sheetCols - 1), curR) }

    // MARK: find & replace
    func findAll(_ needle: String, matchCase: Bool = false) -> [(c: Int, r: Int)] {
        guard !needle.isEmpty else { return [] }
        let n = matchCase ? needle : needle.lowercased()
        var hits: [(c: Int, r: Int)] = []
        for (k, v) in sheet.cells {
            let hay = matchCase ? v : v.lowercased(), shown = matchCase ? (values[k]?.text ?? "") : (values[k]?.text.lowercased() ?? "")
            if hay.contains(n) || shown.contains(n), let p = parseAddress(k) { hits.append((p.c, p.r)) }
        }
        return hits.sorted { ($0.r, $0.c) < ($1.r, $1.c) }
    }
    @discardableResult func findNext(_ needle: String, matchCase: Bool = false) -> Int {
        let hits = findAll(needle, matchCase: matchCase)
        guard !hits.isEmpty else { return 0 }
        let next = hits.first { ($0.r, $0.c) > (curR, curC) } ?? hits[0]
        select(next.c, next.r); return hits.count
    }
    func replaceAll(_ needle: String, with rep: String, matchCase: Bool = false) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        mutate { s in
            for (k, v) in s.cells {
                let opts: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
                if v.range(of: needle, options: opts) != nil { s.cells[k] = v.replacingOccurrences(of: needle, with: rep, options: opts); count += 1 }
            }
        }
        return count
    }

    // MARK: sheets (tabs)
    func uniqueName(_ base: String) -> String {
        var n = base, i = 2; while sheets.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { n = "\(base) \(i)"; i += 1 }; return n
    }
    func addSheet() { commitEdit(); sheets.append(SheetData(name: uniqueName("Sheet\(sheets.count + 1)"))); active = sheets.count - 1; select(0, 0) }
    func duplicateSheet(_ i: Int) { var s = sheets[i]; s.name = uniqueName(s.name + " copy"); sheets.insert(s, at: i + 1); active = i + 1 }
    func deleteSheet(_ i: Int) {
        guard sheets.count > 1 else { return }
        let gone = sheets[i].name
        var book = sheets; book.remove(at: i)
        for si in book.indices { for (k, v) in book[si].cells where v.hasPrefix("=") && (v.contains(gone + "!") || v.contains("'" + gone + "'!")) { book[si].cells[k] = v.replacingOccurrences(of: "'" + gone + "'!", with: "#REF!").replacingOccurrences(of: gone + "!", with: "#REF!") } }
        sheets = book; active = min(active, sheets.count - 1)
    }
    func renameSheet(_ i: Int, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("!"), !n.contains("'"), sheets[i].name != n, !sheets.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        let old = sheets[i].name
        var book = sheets
        let q = n.contains(" ") ? "'" + n + "'" : n
        for si in book.indices { for (k, v) in book[si].cells where v.hasPrefix("=") {
            book[si].cells[k] = v.replacingOccurrences(of: "'" + old + "'!", with: q + "!").replacingOccurrences(of: old + "!", with: q + "!")
        } }
        book[i].name = n; sheets = book
    }

    // MARK: charts
    func addChart(type: String) {
        let r = rect.isSingle ? (usedBounds().map { SelRect(c0: 0, r0: 0, c1: $0.c, r1: $0.r) } ?? rect) : rect
        let id = (sheet.charts.map(\.id).max() ?? 0) + 1
        mutate { $0.charts.append(ChartSpec(id: id, type: type, range: r.label, title: "Chart \(id)")) }
    }
    func chartData(_ spec: ChartSpec) -> ChartData {
        let parts = spec.range.split(separator: ":").map(String.init)
        guard let a = parseAddress(parts[0]), let b = parseAddress(parts.last ?? parts[0]) else { return ChartData(cats: [], series: []) }
        let c0 = min(a.c, b.c), c1 = max(a.c, b.c), r0 = min(a.r, b.r), r1 = max(a.r, b.r)
        func v(_ c: Int, _ r: Int) -> CV { values[cellAddress(c, r)] ?? .empty }
        func isText(_ x: CV) -> Bool { if case .str = x { return true }; return false }
        let multiCol = c1 > c0
        let hasHeader = r1 > r0 && (c0 + (multiCol ? 1 : 0)...c1).allSatisfy { isText(v($0, r0)) || v($0, r0).isEmpty } && (c0 + (multiCol ? 1 : 0)...c1).contains { v($0, r0 + 1).isNumber }
        let first = hasHeader ? r0 + 1 : r0
        let hasCats = multiCol && (first...r1).filter({ isText(v(c0, $0)) }).count * 2 >= (r1 - first + 1)
        let dataCols = Array((hasCats ? c0 + 1 : c0)...c1)
        let cats = (first...r1).map { hasCats ? v(c0, $0).text : String($0 - first + 1) }
        let series = dataCols.map { c -> (name: String, vals: [Double]) in
            (hasHeader ? v(c, r0).text : colName(c), (first...r1).map { if case .num(let d) = v(c, $0) { return d }; return 0 })
        }
        return ChartData(cats: cats, series: series)
    }

    // MARK: undo / redo
    func undo() { commitEdit(); if let s = history.undo(current: BookState(sheets: sheets, active: active)) { restore(s) } }
    func redo() { commitEdit(); if let s = history.redo(current: BookState(sheets: sheets, active: active)) { restore(s) } }
    private func restore(_ s: BookState) { history.applying = true; sheets = s.sheets; active = min(s.active, s.sheets.count - 1); history.applying = false }

    // MARK: CSV (active sheet)
    func exportCSV() {
        guard let u = usedBounds() else { return }
        let rows = (0...u.r).map { r in (0...u.c).map { display(cellAddress($0, r)).text } }
        if let url = savePanel((title.isEmpty ? sheet.name : title) + ".csv") { try? toCSV(rows).write(to: url, atomically: true, encoding: .utf8) }
    }
    func importCSV() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        var cells: [String: String] = [:]
        for (r, line) in parseCSV(s).enumerated() where r < sheetRows { for (c, v) in line.enumerated() where c < sheetCols && !v.isEmpty { cells[cellAddress(c, r)] = v } }
        mutate { $0.cells = cells; $0.styles = [:] }
        if title.isEmpty { title = u.deletingPathExtension().lastPathComponent }
    }
}
