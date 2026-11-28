// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Same JSON shape as the web Data app for the basics (title, tables, fields, rows); newer features are optional extra keys.

enum Val: Codable, Equatable, Hashable {
    case s(String), n(Double), b(Bool), null
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .b(b) }
        else if let n = try? c.decode(Double.self) { self = .n(n) }
        else if let s = try? c.decode(String.self) { self = .s(s) }
        else { self = .null }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .s(let x): try c.encode(x); case .n(let x): try c.encode(x); case .b(let x): try c.encode(x); case .null: try c.encodeNil() }
    }
    var text: String {
        switch self {
        case .s(let x): return x
        case .n(let x): return x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
        case .b(let x): return x ? "true" : "false"
        case .null: return ""
        }
    }
    var num: Double? { switch self { case .n(let x): return x; case .s(let x): return Double(x.trimmingCharacters(in: .whitespaces)); case .b(let b): return b ? 1 : 0; default: return nil } }
    var isNull: Bool { if case .null = self { return true }; return false }
    var isStr: Bool { if case .s = self { return true }; return false }
    var truthy: Bool { switch self { case .b(let b): return b; case .n(let n): return n != 0; case .s(let s): return !s.isEmpty && s.lowercased() != "false" && s != "0"; case .null: return false } }
}

struct FieldOption: Codable, Hashable { var name: String; var color: String }

/// text · longtext · number · currency · percent · date · checkbox · select · rating · url · email · link · formula
struct Field: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var type: String
    var options: [FieldOption]?           // select
    var target: Int?                      // link: id of the table it points to
    var formula: String?                  // formula: an expression over this row's fields, e.g.  Price * Qty
    var width: Double?
    var hidden: Bool?
    var agg: String?                      // footer total: count · sum · avg · min · max
}

let fieldTypes: [(id: String, label: String, symbol: String)] = [
    ("text", "Text", "textformat"), ("longtext", "Long text", "text.alignleft"), ("number", "Number", "number"), ("currency", "Currency", "sterlingsign.circle"),
    ("percent", "Percent", "percent"), ("date", "Date", "calendar"), ("checkbox", "Checkbox", "checkmark.square"), ("select", "Single choice", "list.bullet.circle"),
    ("rating", "Rating", "star"), ("url", "Link (URL)", "link"), ("email", "Email", "envelope"), ("link", "Link to table", "arrow.triangle.branch"), ("formula", "Formula", "function"),
]
func fieldSymbol(_ t: String) -> String { fieldTypes.first { $0.id == t }?.symbol ?? "textformat" }
let optionColors = ["#cfe0ff", "#c8f0d4", "#ffd9b3", "#ffc9c4", "#e3d6ff", "#fff3b0", "#d3f0f5", "#e6e6e6"]

struct Row: Codable, Identifiable { var id: Int; var v: [String: Val] }

struct Filter: Codable, Hashable, Identifiable {
    var id: Int
    var field: Int
    var op: String        // contains · notContains · is · isNot · gt · lt · gte · lte · empty · notEmpty
    var value: String
}
struct SortKey: Codable, Hashable { var field: Int; var asc: Bool }
struct TableView: Codable {
    var mode: String = "grid"             // grid · board · cards
    var filters: [Filter] = []
    var matchAll = true
    var sorts: [SortKey] = []
    var groupBy: Int?
    var boardField: Int?
    var search = ""
}

struct Table: Codable, Identifiable {
    var id: Int
    var name: String
    var fields: [Field]
    var rows: [Row]
    var view: TableView?
}
struct SavedQuery: Codable, Identifiable, Hashable { var id: Int; var name: String; var sql: String }

struct DataDoc: Codable {
    var title: String
    var tables: [Table]
    var modified: Double?
    var queries: [SavedQuery]?
}

func compareVals(_ a: Val, _ b: Val) -> Int {
    switch (a, b) {
    case (.null, .null): return 0
    case (.null, _): return -1
    case (_, .null): return 1
    default:
        if let x = a.num, let y = b.num, !(a.isStr && b.isStr && (Double(a.text) == nil || Double(b.text) == nil)) { return x < y ? -1 : x > y ? 1 : 0 }
        let x = a.text.lowercased(), y = b.text.lowercased(); return x < y ? -1 : x > y ? 1 : 0
    }
}

/// Converts a raw value to what a field of this type stores.
func coerce(_ v: Val, to f: Field) -> Val {
    if v.isNull { return .null }
    switch f.type {
    case "number", "currency", "percent", "rating", "link": if let n = v.num { return .n(f.type == "rating" ? max(0, min(5, n.rounded())) : n) }; return .null
    case "checkbox": return .b(v.truthy)
    case "formula": return .null
    default: return .s(v.text)
    }
}

// MARK: - CSV

func parseCSV(_ t: String) -> [[String]] {
    var rows: [[String]] = [], r: [String] = [], f = "", q = false
    let ch = Array(t); var i = 0
    while i < ch.count {
        let c = ch[i]
        if q { if c == "\"" { if i + 1 < ch.count && ch[i + 1] == "\"" { f.append("\""); i += 1 } else { q = false } } else { f.append(c) } }
        else if c == "\"" { q = true } else if c == "," { r.append(f); f = "" }
        else if c == "\n" || c == "\r\n" { r.append(f); rows.append(r); r = []; f = "" } else if c != "\r" { f.append(c) }
        i += 1
    }
    if !f.isEmpty || !r.isEmpty { r.append(f); rows.append(r) }
    return rows.filter { $0.contains { !$0.isEmpty } }
}
func toCSV(_ rows: [[String]]) -> String {
    rows.map { $0.map { $0.contains(where: { ",\"\n".contains($0) }) ? "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : $0 }.joined(separator: ",") }.joined(separator: "\n")
}

/// Guesses a field type for a column of imported text.
func inferType(_ vals: [String]) -> String {
    let v = vals.filter { !$0.isEmpty }
    guard !v.isEmpty else { return "text" }
    if v.allSatisfy({ ["true", "false", "yes", "no"].contains($0.lowercased()) }) { return "checkbox" }
    if v.allSatisfy({ Double($0) != nil }) { return "number" }
    if v.allSatisfy({ $0.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil }) { return "date" }
    if v.allSatisfy({ $0.contains("@") && $0.contains(".") && !$0.contains(" ") }) { return "email" }
    if v.allSatisfy({ $0.hasPrefix("http://") || $0.hasPrefix("https://") }) { return "url" }
    let distinct = Set(v)
    if v.count >= 6 && distinct.count <= 8 && distinct.count * 2 <= v.count { return "select" }
    return "text"
}
