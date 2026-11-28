// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// A small but real SQL engine over the document's tables: SELECT (DISTINCT, JOIN, WHERE, GROUP BY, HAVING, ORDER BY, LIMIT/OFFSET,
// expressions, CASE, IN, BETWEEN, LIKE, IS NULL, aggregates) plus INSERT, UPDATE and DELETE. Also evaluates formula fields.

struct SQLResult { var cols: [String]; var rows: [[Val]]; var message: String?; var changed = 0; var isWrite = false }
struct SQLError: LocalizedError { let msg: String; var errorDescription: String? { msg }; init(_ m: String) { msg = m } }

indirect enum Expr {
    case lit(Val)
    case col(String?, String)                              // optional table alias, column
    case star(String?)
    case fn(String, [Expr], Bool)                          // name, args, DISTINCT
    case bin(String, Expr, Expr)
    case neg(Expr)
    case not(Expr)
    case isNull(Expr, Bool)                                // expr, negated
    case inList(Expr, [Expr], Bool)
    case between(Expr, Expr, Expr, Bool)
    case like(Expr, Expr, Bool)
    case caseWhen([(Expr, Expr)], Expr?)
}

private enum Tok: Equatable { case num(Double), str(String), id(String), quoted(String), op(String), end }
private struct Tk { let t: Tok; let start: Int; let end: Int }

private let keywords: Set<String> = ["SELECT", "DISTINCT", "FROM", "JOIN", "INNER", "LEFT", "OUTER", "ON", "WHERE", "GROUP", "BY", "HAVING", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "AS",
                                     "AND", "OR", "NOT", "IN", "BETWEEN", "LIKE", "IS", "NULL", "TRUE", "FALSE", "CASE", "WHEN", "THEN", "ELSE", "END", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE"]
private let aggregates: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT"]

struct SelectItem { var expr: Expr; var name: String }
struct SelectStmt {
    var distinct = false
    var items: [SelectItem] = []
    var from: (table: String, alias: String) = ("", "")
    var joins: [(left: Bool, table: String, alias: String, on: Expr)] = []
    var whereE: Expr?
    var groupBy: [Expr] = []
    var having: Expr?
    var orderBy: [(Expr, Bool)] = []
    var limit: Int?, offset: Int?
}
enum Statement {
    case select(SelectStmt)
    case insert(table: String, cols: [String], rows: [[Expr]])
    case update(table: String, sets: [(String, Expr)], whereE: Expr?)
    case delete(table: String, whereE: Expr?)
}

// MARK: - parser

final class SQLParser {
    private var toks: [Tk] = []
    private var i = 0
    private let src: [Character]

    init(_ s: String) throws {
        src = Array(s); var p = 0
        while p < src.count {
            let c = src[p]
            if c.isWhitespace { p += 1; continue }
            if c == "-", p + 1 < src.count, src[p + 1] == "-" { while p < src.count, src[p] != "\n" { p += 1 }; continue }       // -- comment
            let start = p
            if c.isNumber || (c == "." && p + 1 < src.count && src[p + 1].isNumber) {
                var t = ""; while p < src.count, src[p].isNumber || src[p] == "." { t.append(src[p]); p += 1 }
                guard let d = Double(t) else { throw SQLError("Bad number: \(t)") }; toks.append(Tk(t: .num(d), start: start, end: p)); continue
            }
            if c == "'" {
                var t = ""; p += 1
                while p < src.count { if src[p] == "'" { if p + 1 < src.count, src[p + 1] == "'" { t.append("'"); p += 2; continue }; break }; t.append(src[p]); p += 1 }
                guard p < src.count else { throw SQLError("Unterminated text: missing a closing '") }; p += 1; toks.append(Tk(t: .str(t), start: start, end: p)); continue
            }
            if c == "\"" || c == "`" || c == "[" {
                let close: Character = c == "[" ? "]" : c; var t = ""; p += 1
                while p < src.count, src[p] != close { t.append(src[p]); p += 1 }
                guard p < src.count else { throw SQLError("Unterminated name: missing a closing \(close)") }; p += 1; toks.append(Tk(t: .quoted(t), start: start, end: p)); continue
            }
            if c.isLetter || c == "_" {
                var t = ""; while p < src.count, src[p].isLetter || src[p].isNumber || src[p] == "_" { t.append(src[p]); p += 1 }
                toks.append(Tk(t: .id(t), start: start, end: p)); continue
            }
            let two = p + 1 < src.count ? String([c, src[p + 1]]) : ""
            if ["<>", "<=", ">=", "!=", "||"].contains(two) { toks.append(Tk(t: .op(two), start: start, end: p + 2)); p += 2; continue }
            if "=<>+-*/%(),.;".contains(c) { toks.append(Tk(t: .op(String(c)), start: start, end: p + 1)); p += 1; continue }
            throw SQLError("Unexpected character “\(c)”")
        }
        toks.append(Tk(t: .end, start: src.count, end: src.count))
    }

    private var cur: Tok { toks[i].t }
    private func isKw(_ k: String) -> Bool { if case .id(let s) = cur { return s.uppercased() == k }; return false }
    private func eatKw(_ k: String) -> Bool { if isKw(k) { i += 1; return true }; return false }
    private func eatOp(_ o: String) -> Bool { if cur == .op(o) { i += 1; return true }; return false }
    private func expectKw(_ k: String) throws { guard eatKw(k) else { throw SQLError("Expected \(k) near “\(near())”") } }
    private func expectOp(_ o: String) throws { guard eatOp(o) else { throw SQLError("Expected “\(o)” near “\(near())”") } }
    private func near() -> String { let t = toks[i]; return t.t == .end ? "end of query" : String(src[t.start..<min(t.end + 12, src.count)]).trimmingCharacters(in: .whitespaces) }
    private func name() throws -> String {
        switch cur {
        case .id(let s): if keywords.contains(s.uppercased()) && !["COUNT"].contains(s.uppercased()) { throw SQLError("Expected a name near “\(near())”") }; i += 1; return s
        case .quoted(let s): i += 1; return s
        default: throw SQLError("Expected a name near “\(near())”")
        }
    }

    // MARK: statements
    func parseStatement() throws -> Statement {
        let s: Statement
        if eatKw("SELECT") { s = .select(try parseSelect()) }
        else if eatKw("INSERT") {
            try expectKw("INTO"); let t = try name(); var cols: [String] = []
            if eatOp("(") { repeat { cols.append(try name()) } while eatOp(","); try expectOp(")") }
            try expectKw("VALUES"); var rows: [[Expr]] = []
            repeat { try expectOp("("); var r: [Expr] = []; repeat { r.append(try parseExpr()) } while eatOp(","); try expectOp(")"); rows.append(r) } while eatOp(",")
            s = .insert(table: t, cols: cols, rows: rows)
        } else if eatKw("UPDATE") {
            let t = try name(); try expectKw("SET"); var sets: [(String, Expr)] = []
            repeat { let c = try name(); try expectOp("="); sets.append((c, try parseExpr())) } while eatOp(",")
            s = .update(table: t, sets: sets, whereE: eatKw("WHERE") ? try parseExpr() : nil)
        } else if eatKw("DELETE") {
            try expectKw("FROM"); let t = try name(); s = .delete(table: t, whereE: eatKw("WHERE") ? try parseExpr() : nil)
        } else { throw SQLError("Start with SELECT, INSERT, UPDATE or DELETE.") }
        _ = eatOp(";")
        guard cur == .end else { throw SQLError("Unexpected “\(near())”") }
        return s
    }

    private func parseSelect() throws -> SelectStmt {
        var s = SelectStmt(); s.distinct = eatKw("DISTINCT")
        repeat {
            if eatOp("*") { s.items.append(SelectItem(expr: .star(nil), name: "*")); continue }
            let start = toks[i].start
            let e = try parseExpr()
            var label = String(src[start..<toks[i - 1].end]).trimmingCharacters(in: .whitespaces)
            if case .col(_, let c) = e { label = c }
            if eatKw("AS") { label = try name() }
            else if case .id(let a) = cur, !keywords.contains(a.uppercased()) { label = a; i += 1 }
            else if case .quoted(let a) = cur { label = a; i += 1 }
            s.items.append(SelectItem(expr: e, name: label))
        } while eatOp(",")
        try expectKw("FROM")
        let t = try name(); var alias = t
        if eatKw("AS") { alias = try name() } else if case .id(let a) = cur, !keywords.contains(a.uppercased()) { alias = a; i += 1 } else if case .quoted(let a) = cur { alias = a; i += 1 }
        s.from = (t, alias)
        while true {
            var left = false
            if eatKw("LEFT") { _ = eatKw("OUTER"); left = true; try expectKw("JOIN") } else if eatKw("INNER") { try expectKw("JOIN") } else if !eatKw("JOIN") { break }
            let jt = try name(); var ja = jt
            if eatKw("AS") { ja = try name() } else if case .id(let a) = cur, !keywords.contains(a.uppercased()) { ja = a; i += 1 } else if case .quoted(let a) = cur { ja = a; i += 1 }
            try expectKw("ON"); s.joins.append((left, jt, ja, try parseExpr()))
        }
        if eatKw("WHERE") { s.whereE = try parseExpr() }
        if eatKw("GROUP") { try expectKw("BY"); repeat { s.groupBy.append(try parseExpr()) } while eatOp(",") }
        if eatKw("HAVING") { s.having = try parseExpr() }
        if eatKw("ORDER") { try expectKw("BY"); repeat { let e = try parseExpr(); let asc = eatKw("DESC") ? false : { _ = eatKw("ASC"); return true }(); s.orderBy.append((e, asc)) } while eatOp(",") }
        if eatKw("LIMIT") { guard case .num(let n) = cur else { throw SQLError("LIMIT needs a number") }; i += 1; s.limit = Int(n)
            if eatOp(",") { guard case .num(let m) = cur else { throw SQLError("LIMIT needs a number") }; i += 1; s.offset = Int(n); s.limit = Int(m) } }
        if eatKw("OFFSET") { guard case .num(let n) = cur else { throw SQLError("OFFSET needs a number") }; i += 1; s.offset = Int(n) }
        return s
    }

    // MARK: expressions (OR < AND < NOT < comparison < || < + - < * / % < unary)
    func parseExpr() throws -> Expr { try parseOr() }
    private func parseOr() throws -> Expr { var l = try parseAnd(); while eatKw("OR") { l = .bin("OR", l, try parseAnd()) }; return l }
    private func parseAnd() throws -> Expr { var l = try parseNot(); while eatKw("AND") { l = .bin("AND", l, try parseNot()) }; return l }
    private func parseNot() throws -> Expr { if eatKw("NOT") { return .not(try parseNot()) }; return try parseCmp() }
    private func parseCmp() throws -> Expr {
        let l = try parseConcat()
        if eatKw("IS") { let neg = eatKw("NOT"); try expectKw("NULL"); return .isNull(l, neg) }
        let neg = isKw("NOT") && { if case .id(let s) = toks[i + 1].t { return ["LIKE", "IN", "BETWEEN"].contains(s.uppercased()) }; return false }()
        if neg { i += 1 }
        if eatKw("LIKE") { return .like(l, try parseConcat(), neg) }
        if eatKw("IN") {
            try expectOp("("); var items: [Expr] = []; repeat { items.append(try parseExpr()) } while eatOp(","); try expectOp(")"); return .inList(l, items, neg)
        }
        if eatKw("BETWEEN") { let a = try parseConcat(); try expectKw("AND"); return .between(l, a, try parseConcat(), neg) }
        for o in ["=", "<>", "!=", "<=", ">=", "<", ">"] where eatOp(o) { return .bin(o == "!=" ? "<>" : o, l, try parseConcat()) }
        return l
    }
    private func parseConcat() throws -> Expr { var l = try parseAdd(); while eatOp("||") { l = .bin("||", l, try parseAdd()) }; return l }
    private func parseAdd() throws -> Expr {
        var l = try parseMul()
        while true { if eatOp("+") { l = .bin("+", l, try parseMul()) } else if eatOp("-") { l = .bin("-", l, try parseMul()) } else { return l } }
    }
    private func parseMul() throws -> Expr {
        var l = try parseUnary()
        while true { if eatOp("*") { l = .bin("*", l, try parseUnary()) } else if eatOp("/") { l = .bin("/", l, try parseUnary()) } else if eatOp("%") { l = .bin("%", l, try parseUnary()) } else { return l } }
    }
    private func parseUnary() throws -> Expr { if eatOp("-") { return .neg(try parseUnary()) }; _ = eatOp("+"); return try parsePrimary() }
    private func parsePrimary() throws -> Expr {
        let t = cur
        switch t {
        case .num(let d): i += 1; return .lit(.n(d))
        case .str(let s): i += 1; return .lit(.s(s))
        case .op("("): i += 1; let e = try parseExpr(); try expectOp(")"); return e
        case .quoted(let n): i += 1; if eatOp(".") { return .col(n, try name()) }; return .col(nil, n)
        case .id(let s):
            let u = s.uppercased()
            if u == "NULL" { i += 1; return .lit(.null) }
            if u == "TRUE" { i += 1; return .lit(.b(true)) }
            if u == "FALSE" { i += 1; return .lit(.b(false)) }
            if u == "CASE" {
                i += 1; var arms: [(Expr, Expr)] = []; var other: Expr?
                while eatKw("WHEN") { let c = try parseExpr(); try expectKw("THEN"); arms.append((c, try parseExpr())) }
                if eatKw("ELSE") { other = try parseExpr() }; try expectKw("END"); return .caseWhen(arms, other)
            }
            if keywords.contains(u) { throw SQLError("Unexpected “\(s)”") }
            i += 1
            if eatOp("(") {                                                   // function call
                var args: [Expr] = []; var distinct = false
                if eatOp("*") { args = [.star(nil)] }
                else if !eatOp(")") { distinct = eatKw("DISTINCT"); repeat { args.append(try parseExpr()) } while eatOp(",")
                }
                if !(toks[i - 1].t == .op(")")) { try expectOp(")") }
                return .fn(u, args, distinct)
            }
            if eatOp(".") { if eatOp("*") { return .star(s) }; return .col(s, try name()) }
            return .col(nil, s)
        default: throw SQLError("Unexpected “\(near())”")
        }
    }
}

// MARK: - evaluation

struct Ctx { var rows: [(alias: String, data: [String: Val])]; var extra: [String: Val] = [:] }

final class SQLEngine {
    var tables: [Table]
    private var formulaCache: [String: Expr] = [:]
    private var inFlight = Set<String>()

    init(_ t: [Table]) { tables = t }

    func table(_ n: String) throws -> Table {
        guard let t = tables.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { throw SQLError("No such table: \(n)") }; return t
    }

    /// One row as {lowercased field name: value}, with formula fields computed and the row's id available as `id`.
    func rowData(_ t: Table, _ r: Row) -> [String: Val] {
        var d: [String: Val] = ["id": .n(Double(r.id)), "rowid": .n(Double(r.id))]
        for f in t.fields where f.type != "formula" { d[f.name.lowercased()] = r.v[String(f.id)] ?? .null }
        for f in t.fields where f.type == "formula" { d[f.name.lowercased()] = formulaValue(t, r, f, d) }
        return d
    }
    func formulaValue(_ t: Table, _ r: Row, _ f: Field, _ partial: [String: Val]) -> Val {
        let key = "\(t.id).\(f.id).\(r.id)"
        guard let src = f.formula, !src.trimmingCharacters(in: .whitespaces).isEmpty, !inFlight.contains(key) else { return .null }
        inFlight.insert(key); defer { inFlight.remove(key) }
        let cacheKey = "\(t.id).\(f.id).\(src)"
        let expr: Expr
        if let e = formulaCache[cacheKey] { expr = e }
        else { guard let p = try? SQLParser(src), let e = try? p.parseExpr() else { return .s("#ERR") }; formulaCache[cacheKey] = e; expr = e }
        var d = partial
        for g in t.fields where g.type == "formula" && d[g.name.lowercased()] == nil && g.id != f.id { d[g.name.lowercased()] = formulaValue(t, r, g, d) }   // formulas may use other formulas
        return (try? eval(expr, Ctx(rows: [(t.name, d)]), nil)) ?? .s("#ERR")
    }

    // MARK: expressions
    private func cv(_ v: Val) -> CV { switch v { case .n(let n): return .num(n); case .s(let s): return .str(s); case .b(let b): return .bool(b); case .null: return .empty } }
    private func val(_ c: CV) -> Val { switch c { case .num(let n): return .n(n); case .str(let s): return .s(s); case .bool(let b): return .b(b); case .empty: return .null; case .err(let e): return .s(e); case .list(let l, _): return l.first.map(val) ?? .null } }

    func resolve(_ alias: String?, _ name: String, _ c: Ctx) throws -> Val {
        let key = name.lowercased()
        if let a = alias {
            guard let row = c.rows.first(where: { $0.alias.caseInsensitiveCompare(a) == .orderedSame }) else { throw SQLError("Unknown table or alias “\(a)”") }
            if row.data.isEmpty { return .null }                                 // the unmatched side of a LEFT JOIN
            guard let v = row.data[key] else { throw SQLError("No column “\(name)” in \(a)") }; return v
        }
        if let v = c.extra[key] { return v }
        for r in c.rows { if let v = r.data[key] { return v } }
        if c.rows.contains(where: { $0.data.isEmpty }) { return .null }           // the unmatched side of a LEFT JOIN
        throw SQLError("No such column: \(name)")
    }

    func eval(_ e: Expr, _ c: Ctx, _ group: [Ctx]?) throws -> Val {
        switch e {
        case .lit(let v): return v
        case .col(let a, let n): return try resolve(a, n, c)
        case .star: throw SQLError("* can only be used in the select list")
        case .neg(let x): if let n = try eval(x, c, group).num { return .n(-n) }; return .null
        case .not(let x): return .b(!(try eval(x, c, group).truthy))
        case .isNull(let x, let neg): return .b(try eval(x, c, group).isNull != neg)
        case .inList(let x, let items, let neg):
            let v = try eval(x, c, group); if v.isNull { return .b(false) }
            let hit = try items.contains { try equal(v, eval($0, c, group)) }; return .b(hit != neg)
        case .between(let x, let a, let b, let neg):
            let v = try eval(x, c, group), lo = try eval(a, c, group), hi = try eval(b, c, group)
            if v.isNull { return .b(false) }
            return .b((compareVals(v, lo) >= 0 && compareVals(v, hi) <= 0) != neg)
        case .like(let x, let p, let neg):
            let v = try eval(x, c, group), pat = try eval(p, c, group); if v.isNull { return .b(false) }
            let esc = NSRegularExpression.escapedPattern(for: pat.text).replacingOccurrences(of: "%", with: ".*").replacingOccurrences(of: "_", with: ".")
            let hit = v.text.range(of: "^\(esc)$", options: [.regularExpression, .caseInsensitive]) != nil
            return .b(hit != neg)
        case .caseWhen(let arms, let other):
            for (cond, res) in arms where try eval(cond, c, group).truthy { return try eval(res, c, group) }
            return try other.map { try eval($0, c, group) } ?? .null
        case .bin(let op, let l, let r):
            if op == "AND" { return .b(try eval(l, c, group).truthy && eval(r, c, group).truthy) }
            if op == "OR" { return .b(try eval(l, c, group).truthy || eval(r, c, group).truthy) }
            let a = try eval(l, c, group), b = try eval(r, c, group)
            switch op {
            case "=": return .b(!a.isNull && !b.isNull && equal(a, b))
            case "<>": return .b(!a.isNull && !b.isNull && !equal(a, b))
            case "<": return .b(!a.isNull && !b.isNull && compareVals(a, b) < 0)
            case ">": return .b(!a.isNull && !b.isNull && compareVals(a, b) > 0)
            case "<=": return .b(!a.isNull && !b.isNull && compareVals(a, b) <= 0)
            case ">=": return .b(!a.isNull && !b.isNull && compareVals(a, b) >= 0)
            case "||": return .s(a.text + b.text)
            default:
                guard let x = a.num, let y = b.num else { return .null }
                switch op {
                case "+": return .n(x + y); case "-": return .n(x - y); case "*": return .n(x * y)
                case "/": return y == 0 ? .null : .n(x / y)
                default: return y == 0 ? .null : .n(x - y * (x / y).rounded(.down))
                }
            }
        case .fn(let name, let args, let distinct):
            if aggregates.contains(name) {
                guard let rows = group else { throw SQLError("\(name)() can only be used with GROUP BY or in a summary query") }
                return try aggregate(name, args, distinct, rows)
            }
            return try scalar(name, try args.map { try eval($0, c, group) })
        }
    }
    func equal(_ a: Val, _ b: Val) -> Bool {
        if let x = a.num, let y = b.num, !(a.isStr && b.isStr) { return x == y }
        return a.text.caseInsensitiveCompare(b.text) == .orderedSame
    }

    private func scalar(_ name: String, _ a: [Val]) throws -> Val {
        switch name {
        case "COALESCE", "IFNULL": return a.first { !$0.isNull } ?? .null
        case "NULLIF": return a.count == 2 && equal(a[0], a[1]) ? .null : (a.first ?? .null)
        case "IIF": return a.count == 3 ? (a[0].truthy ? a[1] : a[2]) : .null
        case "LENGTH": return .n(Double(a.first?.text.count ?? 0))
        case "SUBSTR", "SUBSTRING": return val(Funcs.call("MID", a.map(cv)))
        case "REPLACE": return val(Funcs.call("SUBSTITUTE", a.map(cv)))
        case "CAST": return a.first ?? .null
        default:
            let r = Funcs.call(name, a.map(cv))
            if case .err("#NAME?") = r { throw SQLError("Unknown function: \(name)") }
            return val(r)
        }
    }

    private func aggregate(_ name: String, _ args: [Expr], _ distinct: Bool, _ rows: [Ctx]) throws -> Val {
        if name == "COUNT", case .star? = args.first { return .n(Double(rows.count)) }
        guard let arg = args.first else { throw SQLError("\(name) needs an argument") }
        var vals = try rows.map { try eval(arg, $0, nil) }.filter { !$0.isNull }
        if distinct { var seen = Set<String>(); vals = vals.filter { seen.insert($0.text.lowercased()).inserted } }
        switch name {
        case "COUNT": return .n(Double(vals.count))
        case "SUM": let n = vals.compactMap(\.num); return n.isEmpty ? .null : .n(n.reduce(0, +))
        case "AVG": let n = vals.compactMap(\.num); return n.isEmpty ? .null : .n((n.reduce(0, +) / Double(n.count) * 1e6).rounded() / 1e6)
        case "MIN": return vals.min { compareVals($0, $1) < 0 } ?? .null
        case "MAX": return vals.max { compareVals($0, $1) < 0 } ?? .null
        default:
            let sep: String = args.count > 1 ? (try eval(args[1], rows.first ?? Ctx(rows: []), nil)).text : ", "
            return vals.isEmpty ? .null : .s(vals.map(\.text).joined(separator: sep))
        }
    }
    private func hasAggregate(_ e: Expr) -> Bool {
        switch e {
        case .fn(let n, let a, _): return aggregates.contains(n) || a.contains(where: hasAggregate)
        case .bin(_, let l, let r): return hasAggregate(l) || hasAggregate(r)
        case .neg(let x), .not(let x), .isNull(let x, _): return hasAggregate(x)
        case .inList(let x, let l, _): return hasAggregate(x) || l.contains(where: hasAggregate)
        case .between(let x, let a, let b, _): return hasAggregate(x) || hasAggregate(a) || hasAggregate(b)
        case .like(let x, let p, _): return hasAggregate(x) || hasAggregate(p)
        case .caseWhen(let arms, let o): return arms.contains { hasAggregate($0.0) || hasAggregate($0.1) } || (o.map(hasAggregate) ?? false)
        default: return false
        }
    }

    // MARK: statements
    func run(_ sql: String) throws -> SQLResult {
        switch try SQLParser(sql).parseStatement() {
        case .select(let s): return try runSelect(s)
        case .insert(let t, let cols, let rows): return try runInsert(t, cols, rows)
        case .update(let t, let sets, let w): return try runUpdate(t, sets, w)
        case .delete(let t, let w): return try runDelete(t, w)
        }
    }

    private func runSelect(_ s: SelectStmt) throws -> SQLResult {
        let base = try table(s.from.table)
        var contexts: [Ctx] = base.rows.map { Ctx(rows: [(s.from.alias, rowData(base, $0))]) }
        for j in s.joins {
            let jt = try table(j.table); let jrows = jt.rows.map { rowData(jt, $0) }
            var next: [Ctx] = []
            for c in contexts {
                var matched = false
                for d in jrows { var n = c; n.rows.append((j.alias, d)); if try eval(j.on, n, nil).truthy { next.append(n); matched = true } }
                if !matched && j.left { var n = c; n.rows.append((j.alias, [:])); next.append(n) }
            }
            contexts = next
        }
        if let w = s.whereE { contexts = try contexts.filter { try eval(w, $0, nil).truthy } }

        // expand * into columns
        var items: [SelectItem] = []
        for it in s.items {
            if case .star(let a) = it.expr {
                var sources: [(alias: String, table: Table)] = []
                if a == nil { sources = [(s.from.alias, base)] + (try s.joins.map { ($0.alias, try table($0.table)) }) }
                else if a!.caseInsensitiveCompare(s.from.alias) == .orderedSame { sources = [(s.from.alias, base)] }
                else if let j = s.joins.first(where: { $0.alias.caseInsensitiveCompare(a!) == .orderedSame }) { sources = [(j.alias, try table(j.table))] }
                else { throw SQLError("Unknown table or alias “\(a!)”") }
                for src in sources { for f in src.table.fields { items.append(SelectItem(expr: .col(src.alias, f.name), name: f.name)) } }
            } else { items.append(it) }
        }

        let aggregated = !s.groupBy.isEmpty || items.contains { hasAggregate($0.expr) } || (s.having.map(hasAggregate) ?? false)
        var out: [(cells: [Val], ctx: Ctx, group: [Ctx]?)] = []
        if aggregated {
            var order: [String] = [], groups: [String: [Ctx]] = [:]
            for c in contexts { let key = try s.groupBy.map { try eval($0, c, nil).text.lowercased() }.joined(separator: "\u{1}"); if groups[key] == nil { order.append(key) }; groups[key, default: []].append(c) }
            if contexts.isEmpty && s.groupBy.isEmpty { order = [""]; groups[""] = [] }
            for k in order {
                let g = groups[k] ?? []; var rep = g.first ?? Ctx(rows: [(s.from.alias, [:])])
                let cells = try items.map { try eval($0.expr, rep, g) }
                for (it, v) in zip(items, cells) { rep.extra[it.name.lowercased()] = v }
                if let h = s.having, !(try eval(h, rep, g).truthy) { continue }
                out.append((cells, rep, g))
            }
        } else {
            for c in contexts { var rep = c; let cells = try items.map { try eval($0.expr, c, nil) }; for (it, v) in zip(items, cells) { rep.extra[it.name.lowercased()] = v }; out.append((cells, rep, nil)) }
        }
        if s.distinct { var seen = Set<String>(); out = out.filter { seen.insert($0.cells.map { $0.text.lowercased() }.joined(separator: "\u{1}")).inserted } }
        if !s.orderBy.isEmpty {
            let keyed = try out.map { r in (r, try s.orderBy.map { try eval($0.0, r.ctx, r.group) }) }
            out = keyed.sorted { a, b in
                for (i, o) in s.orderBy.enumerated() { let c = compareVals(a.1[i], b.1[i]); if c != 0 { return o.1 ? c < 0 : c > 0 } }
                return false
            }.map { $0.0 }
        }
        var rows = out.map(\.cells)
        if let o = s.offset { rows = Array(rows.dropFirst(max(0, o))) }
        if let l = s.limit { rows = Array(rows.prefix(max(0, l))) }
        return SQLResult(cols: items.map(\.name), rows: rows)
    }

    private func runInsert(_ tn: String, _ cols: [String], _ rows: [[Expr]]) throws -> SQLResult {
        guard let ti = tables.firstIndex(where: { $0.name.caseInsensitiveCompare(tn) == .orderedSame }) else { throw SQLError("No such table: \(tn)") }
        let fields = tables[ti].fields.filter { $0.type != "formula" }
        let targets: [Field] = try (cols.isEmpty ? fields : cols.map { c in
            guard let f = tables[ti].fields.first(where: { $0.name.caseInsensitiveCompare(c) == .orderedSame }) else { throw SQLError("No column “\(c)” in \(tn)") }
            if f.type == "formula" { throw SQLError("“\(c)” is a formula field and can't be set") }; return f })
        var next = (tables[ti].rows.map(\.id).max() ?? 0) + 1
        for r in rows {
            guard r.count == targets.count else { throw SQLError("\(targets.count) columns but \(r.count) values") }
            var row = Row(id: next, v: [:]); next += 1
            for (f, e) in zip(targets, r) { let v = coerce(try eval(e, Ctx(rows: []), nil), to: f); if !v.isNull { row.v[String(f.id)] = v } }
            tables[ti].rows.append(row)
        }
        return SQLResult(cols: [], rows: [], message: "\(rows.count) row\(rows.count == 1 ? "" : "s") inserted", changed: rows.count, isWrite: true)
    }
    private func runUpdate(_ tn: String, _ sets: [(String, Expr)], _ w: Expr?) throws -> SQLResult {
        guard let ti = tables.firstIndex(where: { $0.name.caseInsensitiveCompare(tn) == .orderedSame }) else { throw SQLError("No such table: \(tn)") }
        let t = tables[ti]
        let targets: [(Field, Expr)] = try sets.map { c, e in
            guard let f = t.fields.first(where: { $0.name.caseInsensitiveCompare(c) == .orderedSame }) else { throw SQLError("No column “\(c)” in \(tn)") }
            if f.type == "formula" { throw SQLError("“\(c)” is a formula field and can't be set") }; return (f, e) }
        var n = 0
        for (ri, r) in t.rows.enumerated() {
            let ctx = Ctx(rows: [(t.name, rowData(t, r))])
            if let w = w, !(try eval(w, ctx, nil).truthy) { continue }
            for (f, e) in targets { let v = coerce(try eval(e, ctx, nil), to: f); tables[ti].rows[ri].v[String(f.id)] = v.isNull ? nil : v }
            n += 1
        }
        return SQLResult(cols: [], rows: [], message: "\(n) row\(n == 1 ? "" : "s") updated", changed: n, isWrite: true)
    }
    private func runDelete(_ tn: String, _ w: Expr?) throws -> SQLResult {
        guard let ti = tables.firstIndex(where: { $0.name.caseInsensitiveCompare(tn) == .orderedSame }) else { throw SQLError("No such table: \(tn)") }
        let t = tables[ti]; var keep: [Row] = [], n = 0
        for r in t.rows { if let w = w, !(try eval(w, Ctx(rows: [(t.name, rowData(t, r))]), nil).truthy) { keep.append(r) } else if w == nil { n += 1 } else { n += 1 } }
        tables[ti].rows = keep
        return SQLResult(cols: [], rows: [], message: "\(n) row\(n == 1 ? "" : "s") deleted", changed: n, isWrite: true)
    }
}
