import SwiftUI
import AppKit

private let isoFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
private let shownDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
private let moneyFmt: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .currency; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; return f }()
private let pctFmt: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .percent; f.maximumFractionDigits = 2; return f }()

final class DataDocModel: ObservableObject {
    let history = UndoHistory<DataDoc>()
    @Published var doc: DataDoc { didSet { engineCache = nil; rowCache = [:]; if ready { history.record(oldValue); dirty = true; scheduleSave() } } }
    @Published var tableId: Int
    @Published var selected = Set<Int>()
    @Published var recordId: Int?
    @Published var savedAt: Date?
    @Published var status: String?
    let id: String, url: URL
    private var ready = false, dirty = false
    private var work: DispatchWorkItem?
    private var engineCache: SQLEngine?
    private var rowCache: [String: [String: Val]] = [:]

    init(id: String, dir: URL) {
        self.id = id
        url = dir.appendingPathComponent("office__data__\(id).json")
        let loaded: DataDoc
        if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(DataDoc.self, from: d) { loaded = x }
        else {
            loaded = DataDoc(title: "", tables: [Table(id: 1, name: "Contacts", fields: [Field(id: 1, name: "Name", type: "text"), Field(id: 2, name: "Age", type: "number"), Field(id: 3, name: "Joined", type: "date"), Field(id: 4, name: "Active", type: "checkbox")],
                rows: [Row(id: 1, v: ["1": .s("Ada Lovelace"), "2": .n(36), "3": .s("2024-01-15"), "4": .b(true)]),
                       Row(id: 2, v: ["1": .s("Alan Turing"), "2": .n(41), "3": .s("2024-03-02"), "4": .b(true)]),
                       Row(id: 3, v: ["1": .s("Grace Hopper"), "2": .n(85), "3": .s("2023-11-30"), "4": .b(false)])])])
        }
        doc = loaded
        tableId = loaded.tables.first?.id ?? 1
        ready = true
    }

    // MARK: saving
    func scheduleSave() { work?.cancel(); let w = DispatchWorkItem { [weak self] in self?.save() }; work = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w) }
    func flush() { work?.cancel(); if dirty { save() } }
    func save() {
        var d = doc; d.modified = Date().timeIntervalSince1970 * 1000
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: url, options: .atomic); savedAt = Date(); dirty = false }
    }
    func undo() { if let s = history.undo(current: doc) { history.applying = true; doc = s; history.applying = false; fixSelection() } }
    func redo() { if let s = history.redo(current: doc) { history.applying = true; doc = s; history.applying = false; fixSelection() } }
    private func fixSelection() { if !doc.tables.contains(where: { $0.id == tableId }) { tableId = doc.tables.first?.id ?? 1 }; selected = [] }
    func nextId(_ ids: [Int]) -> Int { (ids.max() ?? 0) + 1 }

    // MARK: tables, fields, views
    var ti: Int { doc.tables.firstIndex { $0.id == tableId } ?? 0 }
    var table: Table { doc.tables[ti] }
    var view: TableView { table.view ?? TableView() }
    func setView(_ f: (inout TableView) -> Void) { var v = view; f(&v); doc.tables[ti].view = v }
    var shownFields: [Field] { table.fields.filter { !($0.hidden ?? false) } }
    var primary: Field? { table.fields.first { $0.type != "formula" } ?? table.fields.first }
    func field(_ id: Int?) -> Field? { id.flatMap { i in table.fields.first { $0.id == i } } }
    var selectFields: [Field] { table.fields.filter { $0.type == "select" } }
    var engine: SQLEngine { if let e = engineCache { return e }; let e = SQLEngine(doc.tables); engineCache = e; return e }

    // MARK: values
    func cellValue(_ r: Row, _ f: Field, in t: Table? = nil) -> Val {
        let t = t ?? table
        if f.type == "formula" {
            let key = "\(t.id).\(r.id)"
            let d = rowCache[key] ?? { let x = engine.rowData(t, r); rowCache[key] = x; return x }()
            return d[f.name.lowercased()] ?? .null
        }
        return r.v[String(f.id)] ?? .null
    }
    func linkLabel(_ f: Field, _ v: Val) -> String {
        guard let tid = f.target, let n = v.num, let t = doc.tables.first(where: { $0.id == tid }), let row = t.rows.first(where: { $0.id == Int(n) }), let p = t.fields.first(where: { $0.type != "formula" }) else { return "" }
        return display(row, p, in: t)
    }
    func display(_ r: Row, _ f: Field, in t: Table? = nil) -> String {
        let v = cellValue(r, f, in: t)
        if v.isNull { return "" }
        switch f.type {
        case "currency": return v.num.flatMap { moneyFmt.string(from: NSNumber(value: $0)) } ?? v.text
        case "percent": return v.num.flatMap { pctFmt.string(from: NSNumber(value: $0)) } ?? v.text
        case "rating": let n = Int(v.num ?? 0); return String(repeating: "★", count: n) + String(repeating: "☆", count: max(0, 5 - n))
        case "date": return isoFormatter.date(from: v.text).map { shownDate.string(from: $0) } ?? v.text
        case "checkbox": return v.truthy ? "✓" : ""
        case "link": return linkLabel(f, v)
        default: return v.text
        }
    }
    func optionColor(_ f: Field, _ name: String) -> String { f.options?.first { $0.name == name }?.color ?? "#e6e6e6" }

    // MARK: filtering, sorting, grouping
    func passes(_ r: Row, _ fl: Filter) -> Bool {
        guard let f = field(fl.field) else { return true }
        let v = cellValue(r, f), shown = display(r, f).lowercased(), want = fl.value.lowercased()
        switch fl.op {
        case "contains": return shown.contains(want) || v.text.lowercased().contains(want)
        case "notContains": return !(shown.contains(want) || v.text.lowercased().contains(want))
        case "is": if f.type == "checkbox" { return v.truthy == (want == "true" || want == "yes" || want == "checked") }
            if let a = v.num, let b = Double(want), !f.type.hasPrefix("l") { return a == b }; return shown == want || v.text.lowercased() == want
        case "isNot": return !passes(r, Filter(id: fl.id, field: fl.field, op: "is", value: fl.value))
        case "gt", "lt", "gte", "lte":
            let c: Int
            if let a = v.num, let b = Double(fl.value) { c = a < b ? -1 : a > b ? 1 : 0 } else { c = compareVals(v, .s(fl.value)) }
            if v.isNull { return false }
            return fl.op == "gt" ? c > 0 : fl.op == "lt" ? c < 0 : fl.op == "gte" ? c >= 0 : c <= 0
        case "empty": return v.isNull || v.text.isEmpty || (f.type == "checkbox" && !v.truthy)
        case "notEmpty": return !(v.isNull || v.text.isEmpty) && !(f.type == "checkbox" && !v.truthy)
        default: return true
        }
    }
    func visibleRows() -> [Row] {
        var rs = table.rows; let v = view
        if !v.search.isEmpty { let q = v.search.lowercased(); rs = rs.filter { r in table.fields.contains { display(r, $0).lowercased().contains(q) } } }
        if !v.filters.isEmpty { rs = rs.filter { r in v.matchAll ? v.filters.allSatisfy { passes(r, $0) } : v.filters.contains { passes(r, $0) } } }
        var keys = v.sorts; if let g = v.groupBy, !keys.contains(where: { $0.field == g }) { keys.insert(SortKey(field: g, asc: true), at: 0) }
        if !keys.isEmpty {
            rs.sort { a, b in
                for k in keys { guard let f = field(k.field) else { continue }
                    let c = f.type == "link" ? display(a, f).localizedCaseInsensitiveCompare(display(b, f)).rawValue : compareVals(cellValue(a, f), cellValue(b, f))
                    if c != 0 { return k.asc ? c < 0 : c > 0 } }
                return false
            }
        }
        return rs
    }
    func groups() -> [(key: String, rows: [Row])] {
        let rs = visibleRows()
        guard let g = field(view.groupBy) else { return [("", rs)] }
        var order: [String] = [], map: [String: [Row]] = [:]
        for r in rs { let k = display(r, g).isEmpty ? "—" : display(r, g); if map[k] == nil { order.append(k) }; map[k, default: []].append(r) }
        return order.map { ($0, map[$0] ?? []) }
    }
    func aggregate(_ f: Field, _ rows: [Row]) -> String {
        guard let a = f.agg, !a.isEmpty else { return "" }
        let vals = rows.map { cellValue($0, f) }.filter { !$0.isNull && !($0 == .s("")) }
        let nums = vals.compactMap(\.num)
        func fmt(_ d: Double) -> String { f.type == "currency" ? (moneyFmt.string(from: NSNumber(value: d)) ?? "\(d)") : f.type == "percent" ? (pctFmt.string(from: NSNumber(value: d)) ?? "\(d)") : Val.n((d * 100).rounded() / 100).text }
        switch a {
        case "count": return "\(vals.count)"
        case "sum": return nums.isEmpty ? "" : fmt(nums.reduce(0, +))
        case "avg": return nums.isEmpty ? "" : fmt(nums.reduce(0, +) / Double(nums.count))
        case "min": return nums.min().map(fmt) ?? ""
        case "max": return nums.max().map(fmt) ?? ""
        default: return ""
        }
    }

    // MARK: editing rows
    func setValue(_ rowId: Int, _ f: Field, _ v: Val) {
        guard let ri = table.rows.firstIndex(where: { $0.id == rowId }) else { return }
        let c = coerce(v, to: f); doc.tables[ti].rows[ri].v[String(f.id)] = c.isNull ? nil : c
    }
    @discardableResult func addRow(_ values: [Int: Val] = [:]) -> Int {
        let id = nextId(table.rows.map(\.id)); var r = Row(id: id, v: [:])
        for (fid, v) in values { r.v[String(fid)] = v }
        doc.tables[ti].rows.append(r); return id
    }
    func deleteRows(_ ids: Set<Int>) { doc.tables[ti].rows.removeAll { ids.contains($0.id) }; selected.subtract(ids); if let r = recordId, ids.contains(r) { recordId = nil } }
    func duplicateRows(_ ids: Set<Int>) {
        for r in table.rows where ids.contains(r.id) { var c = r; c.id = nextId(table.rows.map(\.id)); doc.tables[ti].rows.append(c) }
    }

    // MARK: editing fields
    func addField(_ name: String, _ type: String) {
        var f = Field(id: nextId(table.fields.map(\.id)), name: name, type: type)
        if type == "select" { f.options = [] }
        if type == "link" { f.target = doc.tables.first { $0.id != table.id }?.id }
        if type == "formula" { f.formula = "" }
        doc.tables[ti].fields.append(f)
    }
    func updateField(_ f: Field) { if let i = table.fields.firstIndex(where: { $0.id == f.id }) { doc.tables[ti].fields[i] = f } }
    func deleteField(_ id: Int) {
        guard table.fields.count > 1 else { return }
        doc.tables[ti].fields.removeAll { $0.id == id }
        for i in doc.tables[ti].rows.indices { doc.tables[ti].rows[i].v[String(id)] = nil }
        setView { v in v.filters.removeAll { $0.field == id }; v.sorts.removeAll { $0.field == id }; if v.groupBy == id { v.groupBy = nil }; if v.boardField == id { v.boardField = nil } }
    }
    func moveField(_ id: Int, by d: Int) {
        guard let i = table.fields.firstIndex(where: { $0.id == id }), table.fields.indices.contains(i + d) else { return }
        doc.tables[ti].fields.swapAt(i, i + d)
    }
    func setWidth(_ id: Int, _ w: Double) { if var f = field(id) { f.width = max(60, min(600, w)); updateField(f) } }
    /// Adds an option to a select field (with the next colour) if it isn't there yet.
    func ensureOption(_ f: Field, _ name: String) {
        guard f.type == "select", !name.isEmpty, !(f.options ?? []).contains(where: { $0.name == name }) else { return }
        var g = f; var o = g.options ?? []; o.append(FieldOption(name: name, color: optionColors[o.count % optionColors.count])); g.options = o; updateField(g)
    }

    // MARK: tables
    func addTable(_ name: String) {
        let id = nextId(doc.tables.map(\.id))
        doc.tables.append(Table(id: id, name: name, fields: [Field(id: 1, name: "Name", type: "text")], rows: [])); tableId = id; selected = []
    }
    func renameTable(_ id: Int, _ n: String) { if let i = doc.tables.firstIndex(where: { $0.id == id }), !n.isEmpty { doc.tables[i].name = n } }
    func deleteTable(_ id: Int) {
        guard doc.tables.count > 1 else { return }
        doc.tables.removeAll { $0.id == id }
        for ti in doc.tables.indices { for fi in doc.tables[ti].fields.indices where doc.tables[ti].fields[fi].target == id { doc.tables[ti].fields[fi].target = nil } }
        if tableId == id { tableId = doc.tables[0].id }; selected = []
    }
    func duplicateTable(_ id: Int) {
        guard var t = doc.tables.first(where: { $0.id == id }) else { return }
        t.id = nextId(doc.tables.map(\.id)); t.name += " copy"; doc.tables.append(t); tableId = t.id
    }

    // MARK: board
    var boardField: Field? { field(view.boardField) ?? selectFields.first }
    func boardColumns() -> [(name: String, rows: [Row])] {
        guard let f = boardField else { return [] }
        let rs = visibleRows(); var cols = (f.options ?? []).map { o in (o.name, rs.filter { cellValue($0, f).text == o.name }) }
        let known = Set((f.options ?? []).map(\.name))
        let rest = rs.filter { let t = cellValue($0, f).text; return t.isEmpty || !known.contains(t) }
        cols.append(("No \(f.name.lowercased())", rest)); return cols
    }
    func moveRow(_ id: Int, toColumn name: String) {
        guard let f = boardField else { return }
        let none = name == "No \(f.name.lowercased())"; setValue(id, f, none ? .null : .s(name))
    }

    // MARK: insights
    func insight(group: Field, value: Field?, agg: String) -> [(label: String, value: Double)] {
        var order: [String] = [], map: [String: [Row]] = [:]
        for r in visibleRows() { let k = display(r, group).isEmpty ? "—" : display(r, group); if map[k] == nil { order.append(k) }; map[k, default: []].append(r) }
        return order.map { k in
            let rows = map[k] ?? []
            if agg == "count" || value == nil { return (k, Double(rows.count)) }
            let n = rows.compactMap { cellValue($0, value!).num }
            let v: Double = agg == "sum" ? n.reduce(0, +) : agg == "avg" ? (n.isEmpty ? 0 : n.reduce(0, +) / Double(n.count)) : agg == "min" ? (n.min() ?? 0) : (n.max() ?? 0)
            return (k, v)
        }
    }

    // MARK: SQL
    func isWrite(_ sql: String) -> Bool { let s = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); return s.hasPrefix("INSERT") || s.hasPrefix("UPDATE") || s.hasPrefix("DELETE") }
    func runQuery(_ sql: String) throws -> SQLResult { try SQLEngine(doc.tables).run(sql) }     // always on a copy; writes are applied separately
    func applyWrite(_ sql: String) throws -> SQLResult {
        let e = SQLEngine(doc.tables); let r = try e.run(sql)
        if r.isWrite { doc.tables = e.tables }
        return r
    }
    func saveQuery(_ name: String, _ sql: String) {
        var q = doc.queries ?? []; q.append(SavedQuery(id: nextId(q.map(\.id)), name: name, sql: sql)); doc.queries = q
    }
    func deleteQuery(_ id: Int) { doc.queries?.removeAll { $0.id == id } }
}
