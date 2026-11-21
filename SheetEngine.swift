import Foundation

// Spreadsheet formula engine: a recursive-descent parser (no eval, no JavaScript).
// Runtime errors are *values* (#DIV/0!, #REF! …) so IFERROR/ISERROR work; only syntax errors abort a formula.

enum CV: Equatable {
    case empty, num(Double), str(String), bool(Bool), err(String), list([CV], Int)   // list(values, columns)

    var text: String {
        switch self {
        case .empty: return ""
        case .num(let d): return formatNumber(d)
        case .str(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .err(let e): return e
        case .list(let l, _): return l.first?.text ?? ""
        }
    }
    var isError: Bool { if case .err = self { return true }; return false }
    var isNumber: Bool { if case .num = self { return true }; return false }
    var isEmpty: Bool { if case .empty = self { return true }; return false }
}

func formatNumber(_ d: Double) -> String {
    if !d.isFinite { return "#NUM!" }
    if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
    return String(format: "%.10g", d)
}

// MARK: addresses  (A…Z, AA…, up to three letters)

func colName(_ c: Int) -> String {
    var n = c + 1, s = ""
    while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
    return s
}
func colIndex(_ s: String) -> Int? {
    guard !s.isEmpty, s.count <= 3 else { return nil }
    var n = 0
    for u in s.uppercased().unicodeScalars { guard u.value >= 65, u.value <= 90 else { return nil }; n = n * 26 + Int(u.value) - 64 }
    return n - 1
}
func cellAddress(_ c: Int, _ r: Int) -> String { colName(c) + String(r + 1) }
func parseAddress(_ raw: String) -> (c: Int, r: Int)? {
    let s = raw.replacingOccurrences(of: "$", with: "")
    let letters = s.prefix { $0.isLetter }, digits = s.dropFirst(letters.count)
    guard let c = colIndex(String(letters)), let n = Int(digits), n >= 1, digits.allSatisfy({ $0.isNumber }) else { return nil }
    return (c, n - 1)
}

// MARK: dates (Excel serial numbers: days since 1899-12-30, UTC)

private let utcCal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let epoch = DateComponents(calendar: utcCal, timeZone: utcCal.timeZone, year: 1899, month: 12, day: 30).date!
func dateFromSerial(_ d: Double) -> Date { epoch.addingTimeInterval(d * 86400) }
func serialFromDate(_ d: Date) -> Double { d.timeIntervalSince(epoch) / 86400 }
func serialFrom(_ y: Int, _ m: Int, _ d: Int) -> Double? {
    guard let dt = DateComponents(calendar: utcCal, timeZone: utcCal.timeZone, year: y, month: m, day: d).date else { return nil }
    return floor(serialFromDate(dt))
}
func parseISODate(_ s: String) -> Double? {
    let p = s.split(separator: "-").compactMap { Int($0) }
    return p.count == 3 ? serialFrom(p[0], p[1], p[2]) : nil
}

// MARK: display formatting (number formats)

private let fmtCache: [String: NumberFormatter] = {
    func nf(_ style: NumberFormatter.Style, _ minF: Int, _ maxF: Int) -> NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = style; f.minimumFractionDigits = minF; f.maximumFractionDigits = maxF; f.usesGroupingSeparator = (style != .percent); return f
    }
    return ["n0": nf(.decimal, 0, 0), "n2": nf(.decimal, 2, 2), "cur": nf(.currency, 2, 2), "pct": nf(.percent, 0, 2)]
}()
private let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.timeZone = TimeZone(identifier: "UTC"); return f }()

/// nf codes: "" general · n0 · n2 · cur · pct · date · sci
func formatDisplay(_ v: CV, _ nf: String) -> String {
    guard case .num(let d) = v, !nf.isEmpty else { return v.text }
    switch nf {
    case "date": return dateFmt.string(from: dateFromSerial(d))
    case "sci": return String(format: "%.3E", d)
    default: return fmtCache[nf]?.string(from: NSNumber(value: d)) ?? v.text
    }
}

// MARK: reference rewriting (copy/paste, fill, insert/delete)

private let refRegex = try! NSRegularExpression(pattern: #"((?:'[^']+'|[A-Za-z_][A-Za-z0-9_]*)!)?(?<![A-Za-z0-9_$.])(\$?)([A-Za-z]{1,3})(\$?)(\d+)(?![A-Za-z0-9_(])"#)

/// Rewrites every cell reference in a formula (outside string literals). `map` gets
/// (sheet qualifier or nil, col, colAbsolute, row, rowAbsolute) and returns the new (col,row), or nil for #REF!.
func transformRefs(_ formula: String, _ map: (String?, Int, Bool, Int, Bool) -> (Int, Int)?) -> String {
    var out = "", inStr = false, seg = ""
    func flush() {
        guard !seg.isEmpty else { return }
        let ns = seg as NSString; var last = 0; var res = ""
        for m in refRegex.matches(in: seg, range: NSRange(location: 0, length: ns.length)) {
            res += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let pre = m.range(at: 1).location == NSNotFound ? nil : ns.substring(with: m.range(at: 1))
            let sheet = pre.map { String($0.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            let cAbs = ns.substring(with: m.range(at: 2)) == "$", rAbs = ns.substring(with: m.range(at: 4)) == "$"
            if let c = colIndex(ns.substring(with: m.range(at: 3))), let r = Int(ns.substring(with: m.range(at: 5))) {
                if let (nc, nr) = map(sheet, c, cAbs, r - 1, rAbs) { res += (pre ?? "") + (cAbs ? "$" : "") + colName(nc) + (rAbs ? "$" : "") + String(nr + 1) }
                else { res += "#REF!" }
            } else { res += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
        }
        res += ns.substring(from: last); out += res; seg = ""
    }
    for ch in formula {
        if ch == "\"" { if !inStr { flush(); out.append(ch) } else { out.append(ch) }; inStr.toggle() }
        else if inStr { out.append(ch) } else { seg.append(ch) }
    }
    flush(); return out
}

/// Copy/paste/fill: relative references move by (dc, dr); $-absolute ones stay.
func shiftFormula(_ f: String, dc: Int, dr: Int) -> String {
    guard f.hasPrefix("=") else { return f }
    return transformRefs(f) { _, c, cAbs, r, rAbs in (cAbs ? c : max(0, c + dc), rAbs ? r : max(0, r + dr)) }
}

/// Row/column insert (+1) or delete (-1) at `at` on `target`; `formulaSheet` is the sheet the formula lives in.
func adjustRefs(_ f: String, formulaSheet: String, target: String, columns: Bool, at: Int, delta: Int) -> String {
    guard f.hasPrefix("=") else { return f }
    return transformRefs(f) { sheet, c, _, r, _ in
        let refSheet = sheet ?? formulaSheet
        guard refSheet.caseInsensitiveCompare(target) == .orderedSame else { return (c, r) }
        let v = columns ? c : r
        if delta > 0 { let n = v >= at ? v + delta : v; return columns ? (n, r) : (c, n) }
        if v == at { return nil }
        let n = v > at ? v - 1 : v; return columns ? (n, r) : (c, n)
    }
}

// MARK: engine

final class SheetEngine {
    let sheets: [String: [String: String]]
    let current: String
    private var cache: [String: CV] = [:]

    init(sheets: [String: [String: String]], current: String) { self.sheets = sheets; self.current = current }
    convenience init(_ raw: [String: String]) { self.init(sheets: ["Sheet1": raw], current: "Sheet1") }

    func all() -> [String: CV] { var out: [String: CV] = [:]; for k in (sheets[current] ?? [:]).keys { out[k] = value(current, k, []) }; return out }
    func resolve(_ name: String) -> String? { sheets.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } }

    func value(_ sheet: String, _ a: String, _ stack: [String]) -> CV {
        let key = sheet + "!" + a
        if let c = cache[key] { return c }
        if stack.contains(key) { return .err("#CIRC") }
        guard let s = sheets[sheet]?[a], !s.isEmpty else { return .empty }
        let v: CV
        if s.hasPrefix("=") {
            do { var p = try Parser(String(s.dropFirst()), engine: self, sheet: sheet, stack: stack + [key]); v = try p.run() }
            catch { v = .err("#ERR") }
        } else {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, let d = Double(t) { v = .num(d) }
            else if t.uppercased() == "TRUE" { v = .bool(true) } else if t.uppercased() == "FALSE" { v = .bool(false) }
            else { v = .str(s) }
        }
        cache[key] = v; return v
    }

    enum Tok: Equatable { case num(Double), str(String), id(String), sheet(String), op(String), end }
    struct SyntaxError: Error {}

    struct Parser {
        var toks: [Tok] = []; var i = 0
        let engine: SheetEngine; let sheet: String; let stack: [String]

        init(_ src: String, engine: SheetEngine, sheet: String, stack: [String]) throws {
            self.engine = engine; self.sheet = sheet; self.stack = stack
            let c = Array(src); var p = 0
            while p < c.count {
                let ch = c[p]
                if ch == " " { p += 1; continue }
                if ch.isNumber || (ch == "." && p + 1 < c.count && c[p + 1].isNumber) {
                    var s = ""; while p < c.count, c[p].isNumber || c[p] == "." { s.append(c[p]); p += 1 }
                    if p < c.count, c[p] == "E" || c[p] == "e", p + 1 < c.count, c[p + 1].isNumber || c[p + 1] == "-" || c[p + 1] == "+" {
                        s.append(c[p]); p += 1; s.append(c[p]); p += 1; while p < c.count, c[p].isNumber { s.append(c[p]); p += 1 } }
                    guard let d = Double(s) else { throw SyntaxError() }; toks.append(.num(d)); continue
                }
                if ch == "\"" {
                    var s = ""; p += 1
                    while p < c.count { if c[p] == "\"" { if p + 1 < c.count, c[p + 1] == "\"" { s.append("\""); p += 2; continue }; break }; s.append(c[p]); p += 1 }
                    guard p < c.count else { throw SyntaxError() }; p += 1; toks.append(.str(s)); continue
                }
                if ch == "'" {
                    var s = ""; p += 1; while p < c.count, c[p] != "'" { s.append(c[p]); p += 1 }
                    guard p + 1 < c.count, c[p + 1] == "!" else { throw SyntaxError() }; p += 2; toks.append(.sheet(s)); continue
                }
                if ch.isLetter || ch == "$" || ch == "_" {
                    var s = ""; while p < c.count, c[p].isLetter || c[p].isNumber || c[p] == "_" || c[p] == "$" || c[p] == "." { s.append(c[p]); p += 1 }
                    if p < c.count, c[p] == "!" { p += 1; toks.append(.sheet(s)) } else { toks.append(.id(s.uppercased())) }
                    continue
                }
                let two = p + 1 < c.count ? String([ch, c[p + 1]]) : ""
                if ["<>", "<=", ">="].contains(two) { toks.append(.op(two)); p += 2; continue }
                if "+-*/^&(),:=<>%".contains(ch) { toks.append(.op(String(ch))); p += 1; continue }
                throw SyntaxError()
            }
            toks.append(.end)
        }

        mutating func run() throws -> CV {
            let v = try compare()
            guard toks[i] == .end else { throw SyntaxError() }
            if case .list(let l, _) = v { return l.first ?? .empty }
            return v
        }
        var cur: Tok { toks[i] }
        mutating func eat(_ o: String) -> Bool { if cur == .op(o) { i += 1; return true }; return false }

        // ---- value helpers (errors propagate as values)
        static func num(_ v: CV) -> Double? {
            switch v { case .num(let d): return d; case .bool(let b): return b ? 1 : 0; case .empty: return 0
            case .str(let s): return Double(s.trimmingCharacters(in: .whitespaces)); default: return nil }
        }
        static func scalar(_ v: CV) -> CV { if case .list(let l, _) = v { return l.first ?? .empty }; return v }
        static func arith(_ a: CV, _ b: CV, _ f: (Double, Double) -> CV) -> CV {
            let a = scalar(a), b = scalar(b)
            if case .err = a { return a }; if case .err = b { return b }
            guard let x = num(a), let y = num(b) else { return .err("#VALUE!") }
            return f(x, y)
        }
        static func isText(_ v: CV) -> Bool { if case .str = v { return true }; return false }
        static func cmp(_ a: CV, _ b: CV, _ o: String) -> CV {
            let a = scalar(a), b = scalar(b)
            if case .err = a { return a }; if case .err = b { return b }
            let c: Int
            if let x = num(a), let y = num(b), !(isText(a) && isText(b)) { c = x < y ? -1 : x > y ? 1 : 0 }
            else { let x = a.text.lowercased(), y = b.text.lowercased(); c = x < y ? -1 : x > y ? 1 : 0 }
            switch o { case "=": return .bool(c == 0); case "<>": return .bool(c != 0); case "<": return .bool(c < 0); case ">": return .bool(c > 0); case "<=": return .bool(c <= 0); default: return .bool(c >= 0) }
        }

        mutating func compare() throws -> CV {
            var l = try concat()
            while case .op(let o) = cur, ["=", "<>", "<", ">", "<=", ">="].contains(o) { i += 1; let r = try concat(); l = Self.cmp(l, r, o) }
            return l
        }
        mutating func concat() throws -> CV {
            var l = try additive()
            while eat("&") { let r = try additive(); if case .err = l {} else if case .err = r { l = r } else { l = .str(Self.scalar(l).text + Self.scalar(r).text) } }
            return l
        }
        mutating func additive() throws -> CV {
            var l = try term()
            while true {
                if eat("+") { let r = try term(); l = Self.arith(l, r) { .num($0 + $1) } }
                else if eat("-") { let r = try term(); l = Self.arith(l, r) { .num($0 - $1) } }
                else { return l }
            }
        }
        mutating func term() throws -> CV {
            var l = try power()
            while true {
                if eat("*") { let r = try power(); l = Self.arith(l, r) { .num($0 * $1) } }
                else if eat("/") { let r = try power(); l = Self.arith(l, r) { $1 == 0 ? .err("#DIV/0!") : .num($0 / $1) } }
                else { return l }
            }
        }
        mutating func power() throws -> CV {
            let l = try unary()
            if eat("^") { let r = try power(); return Self.arith(l, r) { let v = pow($0, $1); return v.isFinite ? .num(v) : .err("#NUM!") } }
            return l
        }
        mutating func unary() throws -> CV {
            if eat("-") { let v = try unary(); return Self.arith(v, .num(0)) { x, _ in .num(-x) } }
            if eat("+") { return try unary() }
            var v = try primary()
            while eat("%") { v = Self.arith(v, .num(100)) { .num($0 / $1) } }
            return v
        }

        mutating func primary() throws -> CV {
            let t = cur; i += 1
            switch t {
            case .num(let d): return .num(d)
            case .str(let s): return .str(s)
            case .op("("): let v = try compare(); guard eat(")") else { throw SyntaxError() }; return v
            case .sheet(let name):
                guard case .id(let ref) = cur, parseAddress(ref) != nil else { throw SyntaxError() }
                i += 1; return try reference(ref, sheetName: name)
            case .id(let name):
                if cur == .op("(") {
                    i += 1; var args: [CV] = []
                    if !eat(")") { repeat { args.append(try compare()) } while eat(","); guard eat(")") else { throw SyntaxError() } }
                    return Funcs.call(name, args)
                }
                if name == "TRUE" { return .bool(true) }
                if name == "FALSE" { return .bool(false) }
                guard parseAddress(name) != nil else { return .err("#NAME?") }
                return try reference(name, sheetName: nil)
            default: throw SyntaxError()
            }
        }

        mutating func reference(_ first: String, sheetName: String?) throws -> CV {
            var sh = sheet
            if let n = sheetName { guard let r = engine.resolve(n) else { return .err("#REF!") }; sh = r }
            guard let a = parseAddress(first) else { throw SyntaxError() }
            if cur == .op(":") {
                i += 1
                guard case .id(let e) = cur, let b = parseAddress(e) else { throw SyntaxError() }; i += 1
                var out: [CV] = []
                let c0 = min(a.c, b.c), c1 = max(a.c, b.c)
                for r in min(a.r, b.r)...max(a.r, b.r) { for c in c0...c1 { out.append(engine.value(sh, cellAddress(c, r), stack)) } }
                return .list(out, c1 - c0 + 1)
            }
            return engine.value(sh, cellAddress(a.c, a.r), stack)
        }
    }
}
