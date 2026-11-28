// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Import / export for Data: CSV, JSON, Excel (.xlsx) and an SQL dump.

extension DataDocModel {
    private var fileBase: String { doc.title.isEmpty ? "database" : doc.title }

    // MARK: building tables from rows of text
    func makeTable(name: String, header: [String], body: [[String]]) -> Table {
        var fields: [Field] = []
        for (i, h) in header.enumerated() {
            let col = body.map { $0.indices.contains(i) ? $0[i] : "" }
            let type = inferType(col)
            var f = Field(id: i + 1, name: h.isEmpty ? "Field \(i + 1)" : h, type: type)
            if type == "select" { f.options = Array(Set(col.filter { !$0.isEmpty })).sorted().enumerated().map { FieldOption(name: $1, color: optionColors[$0 % optionColors.count]) } }
            fields.append(f)
        }
        let rows: [Row] = body.enumerated().map { ri, r in
            var v: [String: Val] = [:]
            for f in fields { let i = f.id - 1; guard r.indices.contains(i), !r[i].isEmpty else { continue }; v[String(f.id)] = coerce(.s(r[i]), to: f) }
            return Row(id: ri + 1, v: v)
        }
        return Table(id: nextId(doc.tables.map(\.id)), name: uniqueTableName(name), fields: fields, rows: rows)
    }
    func uniqueTableName(_ base: String) -> String {
        var n = base.isEmpty ? "Table" : base, i = 2; while doc.tables.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { n = "\(base) \(i)"; i += 1 }; return n
    }

    // MARK: import
    func importCSV() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        let rs = parseCSV(s); guard let head = rs.first else { status = "That file is empty."; return }
        let t = makeTable(name: u.deletingPathExtension().lastPathComponent, header: head, body: Array(rs.dropFirst()))
        doc.tables.append(t); tableId = t.id; status = "Imported \(t.rows.count) rows into “\(t.name)”"
    }
    func importJSON() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url, let data = try? Data(contentsOf: u), let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        var sets: [(String, [[String: Any]])] = []
        if let arr = obj as? [[String: Any]] { sets = [(u.deletingPathExtension().lastPathComponent, arr)] }
        else if let dict = obj as? [String: Any] { for (k, v) in dict.sorted(by: { $0.key < $1.key }) { if let arr = v as? [[String: Any]] { sets.append((k, arr)) } } }
        guard !sets.isEmpty else { status = "Expected a list of objects, or an object of lists."; return }
        var made = 0
        for (name, arr) in sets {
            var keys: [String] = []; for o in arr { for k in o.keys.sorted() where !keys.contains(k) { keys.append(k) } }
            let body = arr.map { o in keys.map { k -> String in if let v = o[k], !(v is NSNull) { if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }; return "\(v)" }; return "" } }
            let t = makeTable(name: name, header: keys, body: body); doc.tables.append(t); tableId = t.id; made += 1
        }
        status = "Imported \(made) table\(made == 1 ? "" : "s") from JSON"
    }
    func importXLSX() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "xlsx")!]
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            let book = try XLSX.read(u); var made = 0
            for s in book {
                var maxR = -1, maxC = -1
                for k in s.cells.keys { if let a = parseAddress(k) { maxR = max(maxR, a.r); maxC = max(maxC, a.c) } }
                guard maxR >= 0 else { continue }
                let engine = SheetEngine(sheets: Dictionary(book.map { ($0.name, $0.cells) }, uniquingKeysWith: { a, _ in a }), current: s.name).all()
                func text(_ c: Int, _ r: Int) -> String { let a = cellAddress(c, r); if let v = engine[a] { return v.text }; return s.cells[a] ?? "" }
                let head = (0...maxC).map { text($0, 0) }, body = (maxR >= 1 ? Array(1...maxR) : []).map { r in (0...maxC).map { text($0, r) } }
                let t = makeTable(name: s.name, header: head, body: body); doc.tables.append(t); tableId = t.id; made += 1
            }
            status = "Imported \(made) table\(made == 1 ? "" : "s") from Excel"
        } catch { status = "Import failed: \(error.localizedDescription)" }
    }

    // MARK: export
    private func asText(_ t: Table, _ r: Row, _ f: Field) -> String {
        let v = cellValue(r, f, in: t)
        switch f.type { case "link": return linkLabel(f, v); case "checkbox": return v.isNull ? "" : (v.truthy ? "true" : "false"); default: return v.text }
    }
    func exportCSV() {
        let t = table
        guard let u = savePanel(t.name + ".csv") else { return }
        let rows = [t.fields.map(\.name)] + visibleRows().map { r in t.fields.map { asText(t, r, $0) } }
        try? toCSV(rows).write(to: u, atomically: true, encoding: .utf8)
    }
    func exportJSON() {
        guard let u = savePanel(fileBase + ".json") else { return }
        var out: [String: Any] = [:]
        for t in doc.tables {
            out[t.name] = t.rows.map { r -> [String: Any] in
                var o: [String: Any] = [:]
                for f in t.fields { let v = cellValue(r, f, in: t); switch v { case .n(let n): o[f.name] = n; case .b(let b): o[f.name] = b; case .s(let s): o[f.name] = f.type == "link" ? linkLabel(f, v) : s; case .null: o[f.name] = NSNull() }
                    if f.type == "link" { o[f.name] = linkLabel(f, v) } }
                return o
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: u) }
    }
    func exportXLSX() {
        guard let u = savePanel(fileBase + ".xlsx") else { return }
        var sheets: [SheetData] = []
        for t in doc.tables {
            var s = SheetData(name: String(t.name.prefix(31)).replacingOccurrences(of: "/", with: "-"))
            for (c, f) in t.fields.enumerated() where c < sheetCols {
                var h = CellStyle(); h.b = true; h.fill = "#cfe0ff"; s.styles[cellAddress(c, 0)] = h; s.cells[cellAddress(c, 0)] = f.name; s.colW[c] = f.width ?? 130
                var nf = CellStyle(); nf.nf = f.type == "currency" ? "cur" : f.type == "percent" ? "pct" : ""
                for (ri, r) in t.rows.enumerated() where ri + 1 < sheetRows {
                    let v = cellValue(r, f, in: t), a = cellAddress(c, ri + 1)
                    switch f.type {
                    case "number", "currency", "percent", "rating": if let n = v.num { s.cells[a] = formatNumber(n) }
                    case "link": s.cells[a] = linkLabel(f, v)
                    case "checkbox": if !v.isNull { s.cells[a] = v.truthy ? "TRUE" : "FALSE" }
                    default: if !v.isNull, !v.text.isEmpty { s.cells[a] = v.text }
                    }
                    if !nf.isDefault { s.styles[a] = nf }
                }
            }
            sheets.append(s)
        }
        do { try XLSX.write(sheets, to: u); status = "Exported \(u.lastPathComponent)" } catch { status = "Export failed: \(error.localizedDescription)" }
    }
    func sqlDump() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func lit(_ v: Val) -> String { switch v { case .n(let n): return formatNumber(n); case .b(let b): return b ? "1" : "0"; case .s(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"; case .null: return "NULL" } }
        var out = "-- FreeOffice Data export\n"
        for t in doc.tables {
            let stored = t.fields.filter { $0.type != "formula" }
            out += "\nCREATE TABLE \(q(t.name)) (\n  \"id\" INTEGER PRIMARY KEY" + stored.map { f in
                let ty = ["number", "currency", "percent", "rating", "link"].contains(f.type) ? "REAL" : f.type == "checkbox" ? "INTEGER" : "TEXT"; return ",\n  \(q(f.name)) \(ty)" }.joined() + "\n);\n"
            for r in t.rows { out += "INSERT INTO \(q(t.name)) (\"id\", " + stored.map { q($0.name) }.joined(separator: ", ") + ") VALUES (\(r.id), " + stored.map { lit(r.v[String($0.id)] ?? .null) }.joined(separator: ", ") + ");\n" }
        }
        return out
    }
    func exportSQLDump() { if let u = savePanel(fileBase + ".sql") { try? sqlDump().write(to: u, atomically: true, encoding: .utf8) } }
    func exportResult(_ r: SQLResult) {
        guard let u = savePanel("query result.csv") else { return }
        try? toCSV([r.cols] + r.rows.map { $0.map(\.text) }).write(to: u, atomically: true, encoding: .utf8)
    }
}
