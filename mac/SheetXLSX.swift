// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AppKit

struct XLSXError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }

/// Minimal Office Open XML (.xlsx) reader/writer: sheets, values, formulas (with cached results), basic styles, column widths.
enum XLSX {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func rgb(_ hex: String) -> String { "FF" + hex.replacingOccurrences(of: "#", with: "").uppercased() }
    private static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { throw XLSXError("A system tool failed (\(exe.split(separator: "/").last ?? "")).") }
    }

    // MARK: - write
    static func write(_ sheets: [SheetData], to url: URL) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // ---- style tables
        var fonts: [String] = ["<font><sz val=\"11\"/><name val=\"Helvetica Neue\"/></font>"]
        var fills: [String] = ["<fill><patternFill patternType=\"none\"/></fill>", "<fill><patternFill patternType=\"gray125\"/></fill>"]
        var xfs: [String] = ["<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"]
        var xfIndex: [String: Int] = [:]
        func xf(for s: CellStyle) -> Int {
            if s.isDefault { return 0 }
            let key = "\(s.b)|\(s.i)|\(s.color)|\(s.fill)|\(s.align)|\(s.nf)"
            if let i = xfIndex[key] { return i }
            var font = 0
            if s.b || s.i || !s.color.isEmpty {
                let x = "<font>\(s.b ? "<b/>" : "")\(s.i ? "<i/>" : "")<sz val=\"11\"/>\(s.color.isEmpty ? "" : "<color rgb=\"\(rgb(s.color))\"/>")<name val=\"Helvetica Neue\"/></font>"
                font = fonts.firstIndex(of: x) ?? { fonts.append(x); return fonts.count - 1 }()
            }
            var fill = 0
            if !s.fill.isEmpty {
                let x = "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(rgb(s.fill))\"/><bgColor indexed=\"64\"/></patternFill></fill>"
                fill = fills.firstIndex(of: x) ?? { fills.append(x); return fills.count - 1 }()
            }
            let nf: Int = ["n0": 3, "n2": 4, "pct": 10, "date": 15, "sci": 11, "cur": 164][s.nf] ?? 0
            let align = s.align.isEmpty ? "" : "<alignment horizontal=\"\(s.align)\"/>"
            let head = "<xf numFmtId=\"\(nf)\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\"" + (align.isEmpty ? "" : " applyAlignment=\"1\"")
            xfs.append(head + (align.isEmpty ? "/>" : ">" + align + "</xf>"))
            xfIndex[key] = xfs.count - 1; return xfs.count - 1
        }

        // ---- worksheets
        let book = Dictionary(sheets.map { ($0.name, $0.cells) }, uniquingKeysWith: { a, _ in a })
        for (n, s) in sheets.enumerated() {
            let vals = SheetEngine(sheets: book, current: s.name).all()
            var rows: [Int: [(Int, String)]] = [:]
            var keys = Set(s.cells.keys); keys.formUnion(s.styles.keys)
            for k in keys {
                guard let p = parseAddress(k) else { continue }
                let st = xf(for: s.styles[k] ?? CellStyle()), raw = s.cells[k] ?? ""
                var x: String
                if raw.isEmpty { x = "<c r=\"\(k)\" s=\"\(st)\"/>" }
                else if raw.hasPrefix("=") {
                    let f = esc(String(raw.dropFirst())), v = vals[k] ?? .empty
                    switch v {
                    case .num(let d): x = "<c r=\"\(k)\" s=\"\(st)\"><f>\(f)</f><v>\(formatNumber(d))</v></c>"
                    case .bool(let b): x = "<c r=\"\(k)\" s=\"\(st)\" t=\"b\"><f>\(f)</f><v>\(b ? 1 : 0)</v></c>"
                    case .err(let e): x = "<c r=\"\(k)\" s=\"\(st)\" t=\"e\"><f>\(f)</f><v>\(esc(e))</v></c>"
                    default: x = "<c r=\"\(k)\" s=\"\(st)\" t=\"str\"><f>\(f)</f><v>\(esc(v.text))</v></c>"
                    }
                } else if let d = Double(raw.trimmingCharacters(in: .whitespaces)) { x = "<c r=\"\(k)\" s=\"\(st)\"><v>\(formatNumber(d))</v></c>" }
                else { x = "<c r=\"\(k)\" s=\"\(st)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(raw))</t></is></c>" }
                rows[p.r, default: []].append((p.c, x))
            }
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            if !s.colW.isEmpty {
                xml += "<cols>" + s.colW.keys.sorted().map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\(String(format: "\"%.2f\"", (s.colW[$0] ?? 108) / 7)) customWidth=\"1\"/>" }.joined() + "</cols>"
            }
            xml += "<sheetData>"
            for r in rows.keys.sorted() { xml += "<row r=\"\(r + 1)\">" + rows[r]!.sorted { $0.0 < $1.0 }.map(\.1).joined() + "</row>" }
            xml += "</sheetData></worksheet>"
            try xml.write(to: root.appendingPathComponent("xl/worksheets/sheet\(n + 1).xml"), atomically: true, encoding: .utf8)
        }

        // ---- package parts
        let ns = "http://schemas.openxmlformats.org/officeDocument/2006"
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            + sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined() + "</Types>")
            .write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(ns)/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
            .write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(ns)/relationships\"><sheets>"
            + sheets.enumerated().map { "<sheet name=\"\(esc($1.name))\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined() + "</sheets></workbook>")
            .write(to: root.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(ns)/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined()
            + "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"\(ns)/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
            .write(to: root.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"&quot;$&quot;#,##0.00\"/></numFmts><fonts count=\"\(fonts.count)\">\(fonts.joined())</fonts><fills count=\"\(fills.count)\">\(fills.joined())</fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"\(xfs.count)\">\(xfs.joined())</cellXfs></styleSheet>")
            .write(to: root.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: url)
        try run("/usr/bin/zip", ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "xl"], cwd: root)
    }

    // MARK: - read
    private final class SAX: NSObject, XMLParserDelegate {
        var onStart: (String, [String: String]) -> Void = { _, _ in }
        var onEnd: (String) -> Void = { _ in }
        var onText: (String) -> Void = { _ in }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) { onStart(e, a) }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) { onEnd(e) }
        func parser(_ p: XMLParser, foundCharacters s: String) { onText(s) }
    }
    private static func parse(_ url: URL, _ configure: (SAX) -> Void) {
        guard let d = try? Data(contentsOf: url) else { return }
        let sax = SAX(); configure(sax); let p = XMLParser(data: d); p.delegate = sax; p.parse()
    }
    private static func hex(_ argb: String?) -> String {
        guard let a = argb, a.count == 8 else { return "" }; return "#" + a.suffix(6).lowercased()
    }
    private static func nfCode(id: Int, custom: [Int: String]) -> String {
        switch id { case 3: return "n0"; case 4: return "n2"; case 9, 10: return "pct"; case 11, 12: return "sci"; case 14...22, 45...47: return "date"; default: break }
        guard let c = custom[id]?.lowercased() else { return "" }
        if c.contains("%") { return "pct" }
        if c.contains("yy") || (c.contains("d") && c.contains("m")) { return "date" }
        if c.contains("$") || c.contains("£") || c.contains("€") { return "cur" }
        if c.contains("0.00") { return "n2" }
        if c.contains("#,##0") || c == "0" { return "n0" }
        return ""
    }

    static func read(_ url: URL) throws -> [SheetData] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        try run("/usr/bin/ditto", ["-x", "-k", url.path, root.path])

        // workbook: sheet names + relationship ids
        var named: [(name: String, rid: String)] = []
        parse(root.appendingPathComponent("xl/workbook.xml")) { s in s.onStart = { e, a in if e == "sheet", let n = a["name"], let r = a["r:id"] { named.append((n, r)) } } }
        guard !named.isEmpty else { throw XLSXError("This doesn't look like an Excel workbook.") }
        var targets: [String: String] = [:]
        parse(root.appendingPathComponent("xl/_rels/workbook.xml.rels")) { s in s.onStart = { e, a in if e == "Relationship", let i = a["Id"], let t = a["Target"] { targets[i] = t } } }

        // shared strings
        var shared: [String] = [], inSI = false, inT = false, cur = ""
        parse(root.appendingPathComponent("xl/sharedStrings.xml")) { s in
            s.onStart = { e, _ in if e == "si" { inSI = true; cur = "" } else if e == "t" && inSI { inT = true } }
            s.onText = { if inT { cur += $0 } }
            s.onEnd = { e in if e == "t" { inT = false } else if e == "si" { shared.append(cur); inSI = false } }
        }

        // styles → CellStyle per cellXfs index
        var custom: [Int: String] = [:], fonts: [(b: Bool, i: Bool, c: String)] = [], fills: [String] = [], xfs: [CellStyle] = []
        var section = "", fb = false, fi = false, fc = "", fillColor = ""
        parse(root.appendingPathComponent("xl/styles.xml")) { s in
            s.onStart = { e, a in
                switch e {
                case "numFmts", "fonts", "fills", "cellXfs", "cellStyleXfs", "borders": section = e
                case "numFmt": if let i = Int(a["numFmtId"] ?? ""), let c = a["formatCode"] { custom[i] = c }
                case "font": fb = false; fi = false; fc = ""
                case "b": if section == "fonts" { fb = true }
                case "i": if section == "fonts" { fi = true }
                case "color": if section == "fonts" { fc = hex(a["rgb"]) }
                case "fill": fillColor = ""
                case "fgColor": if section == "fills" { fillColor = hex(a["rgb"]) }
                case "xf":
                    if section == "cellXfs" {
                        var st = CellStyle()
                        let fo = Int(a["fontId"] ?? "0") ?? 0, fl = Int(a["fillId"] ?? "0") ?? 0
                        if fo < fonts.count { st.b = fonts[fo].b; st.i = fonts[fo].i; st.color = fonts[fo].c == "#000000" ? "" : fonts[fo].c }
                        if fl >= 2, fl < fills.count { st.fill = fills[fl] }
                        st.nf = nfCode(id: Int(a["numFmtId"] ?? "0") ?? 0, custom: custom)
                        xfs.append(st)
                    }
                case "alignment": if section == "cellXfs", !xfs.isEmpty, let h = a["horizontal"], ["left", "center", "right"].contains(h) { xfs[xfs.count - 1].align = h }
                default: break
                }
            }
            s.onEnd = { e in if e == "font" { fonts.append((fb, fi, fc)) } else if e == "fill" { fills.append(fillColor) } }
        }

        // worksheets
        var out: [SheetData] = []
        for (name, rid) in named {
            guard var t = targets[rid] else { continue }
            t = t.hasPrefix("/") ? String(t.dropFirst()) : "xl/" + t
            var sheet = SheetData(name: name)
            var addr = "", type = "", styleIdx = 0, hasF = false, f = "", v = "", isT = "", inIS = false, inV = false, inF = false, inTT = false
            parse(root.appendingPathComponent(t)) { s in
                s.onStart = { e, a in
                    switch e {
                    case "col": if let lo = Int(a["min"] ?? ""), let hi = Int(a["max"] ?? ""), let w = Double(a["width"] ?? "") { for c in (lo - 1)...(hi - 1) where c < sheetCols { sheet.colW[c] = w * 7 } }
                    case "c": addr = a["r"] ?? ""; type = a["t"] ?? ""; styleIdx = Int(a["s"] ?? "0") ?? 0; hasF = false; f = ""; v = ""; isT = ""
                    case "f": hasF = true; inF = true
                    case "v": inV = true
                    case "is": inIS = true
                    case "t": if inIS { inTT = true }
                    default: break
                    }
                }
                s.onText = { str in if inF { f += str } else if inV { v += str } else if inTT { isT += str } }
                s.onEnd = { e in
                    switch e {
                    case "f": inF = false
                    case "v": inV = false
                    case "is": inIS = false
                    case "t": inTT = false
                    case "c":
                        guard let p = parseAddress(addr), p.c < sheetCols, p.r < sheetRows else { return }
                        var raw = ""
                        if hasF && !f.isEmpty { raw = "=" + f }
                        else if type == "s", let i = Int(v), i < shared.count { raw = shared[i] }
                        else if type == "inlineStr" { raw = isT }
                        else if type == "b" { raw = v == "1" ? "TRUE" : "FALSE" }
                        else { raw = v }
                        if !raw.isEmpty { sheet.cells[addr] = raw }
                        if styleIdx > 0, styleIdx < xfs.count, !xfs[styleIdx].isDefault { sheet.styles[addr] = xfs[styleIdx] }
                    default: break
                    }
                }
            }
            out.append(sheet)
        }
        guard !out.isEmpty else { throw XLSXError("The workbook has no readable sheets.") }
        return out
    }
}

extension SheetModel {
    func exportXLSX() {
        commitEdit()
        guard let url = savePanel((title.isEmpty ? "Workbook" : title) + ".xlsx") else { return }
        do { try XLSX.write(sheets, to: url); status = "Exported \(url.lastPathComponent)" } catch { status = "Export failed: \(error.localizedDescription)" }
    }
    func importXLSX() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let book = try XLSX.read(url)
            sheets = book; active = 0; select(0, 0)
            if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            status = "Imported \(book.count) sheet\(book.count == 1 ? "" : "s")"
        } catch { status = "Import failed: \(error.localizedDescription)" }
    }
}
