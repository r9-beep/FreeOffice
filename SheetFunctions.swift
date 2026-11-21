import Foundation

/// The spreadsheet function library. Every function takes already-evaluated arguments and returns a value
/// (errors are returned, never thrown). Ranges arrive as `.list(values, columns)`.
enum Funcs {
    typealias P = SheetEngine.Parser

    static func flat(_ a: [CV]) -> [CV] { a.flatMap { v -> [CV] in if case .list(let l, _) = v { return l }; return [v] } }
    static func nums(_ a: [CV]) -> [Double] { flat(a).compactMap { v -> Double? in if case .num(let d) = v { return d }; return nil } }
    static func firstError(_ a: [CV]) -> CV? { flat(a).first { $0.isError } }
    static func sc(_ v: CV) -> CV { P.scalar(v) }
    static func dbl(_ v: CV) -> Double? { P.num(sc(v)) }
    static func table(_ v: CV) -> (vals: [CV], cols: Int, rows: Int)? {
        if case .list(let l, let c) = v, c > 0 { return (l, c, l.count / c) }
        return nil
    }

    // MARK: criteria (COUNTIF / SUMIF / …)
    static func matches(_ v: CV, _ crit: CV) -> Bool {
        let crit = sc(crit)
        if case .num(let n) = crit { return dbl(v) == n && !(v.isEmpty) }
        var s = crit.text, op = "="
        for o in [">=", "<=", "<>", ">", "<", "="] where s.hasPrefix(o) { op = o; s = String(s.dropFirst(o.count)); break }
        if let n = Double(s.trimmingCharacters(in: .whitespaces)) {
            guard let x = dbl(v), !v.isEmpty, !P.isText(v) || Double(v.text) != nil else { return op == "<>" }
            switch op { case "=": return x == n; case "<>": return x != n; case ">": return x > n; case "<": return x < n; case ">=": return x >= n; default: return x <= n }
        }
        let t = v.text.lowercased(), c = s.lowercased()
        if c.contains("*") || c.contains("?") {
            let pat = "^" + NSRegularExpression.escapedPattern(for: c).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            let hit = t.range(of: pat, options: .regularExpression) != nil
            return op == "<>" ? !hit : hit
        }
        switch op { case "<>": return t != c; case ">": return t > c; case "<": return t < c; case ">=": return t >= c; case "<=": return t <= c; default: return t == c }
    }

    // MARK: TEXT()
    static func text(_ v: CV, _ fmt: String) -> CV {
        guard let d = dbl(v) else { return .str(v.text) }
        let f = fmt.lowercased()
        if f.contains("y") || (f.contains("d") && !f.contains("0")) || f.contains("mmm") {
            var p = fmt.replacingOccurrences(of: "mmmm", with: "MMMM").replacingOccurrences(of: "mmm", with: "MMM")
            p = p.replacingOccurrences(of: "mm", with: "MM").replacingOccurrences(of: "hh", with: "HH")
            let df = DateFormatter(); df.dateFormat = p; df.timeZone = TimeZone(identifier: "UTC")
            return .str(df.string(from: dateFromSerial(d)))
        }
        let nf = NumberFormatter()
        let pct = f.contains("%")
        let decimals = f.split(separator: ".", maxSplits: 1).count > 1 ? f.split(separator: ".")[1].filter { $0 == "0" || $0 == "#" }.count : 0
        nf.numberStyle = pct ? .percent : .decimal
        nf.minimumFractionDigits = decimals; nf.maximumFractionDigits = decimals
        nf.usesGroupingSeparator = f.contains(",")
        var out = nf.string(from: NSNumber(value: d)) ?? v.text
        if let cur = fmt.first(where: { "$£€".contains($0) }) { out = String(cur) + out }
        return .str(out)
    }

    // MARK: dispatch
    static func call(_ f: String, _ a: [CV]) -> CV {
        // functions that must see errors / unused branches
        switch f {
        case "IF":
            guard a.count >= 2 else { return .err("#N/A") }
            let c = sc(a[0]); if c.isError { return c }
            let truthy: Bool; if case .bool(let b) = c { truthy = b } else { truthy = (dbl(c) ?? 0) != 0 }
            return truthy ? sc(a[1]) : (a.count > 2 ? sc(a[2]) : .bool(false))
        case "IFS":
            var i = 0; while i + 1 < a.count { let c = sc(a[i]); if c.isError { return c }; if (dbl(c) ?? 0) != 0 || c == .bool(true) { return sc(a[i + 1]) }; i += 2 }
            return .err("#N/A")
        case "IFERROR": guard a.count >= 2 else { return .err("#N/A") }; return sc(a[0]).isError ? sc(a[1]) : sc(a[0])
        case "IFNA": guard a.count >= 2 else { return .err("#N/A") }; return sc(a[0]) == .err("#N/A") ? sc(a[1]) : sc(a[0])
        case "ISERROR": return .bool(a.first.map { sc($0).isError } ?? false)
        case "ISNA": return .bool(a.first.map { sc($0) == .err("#N/A") } ?? false)
        case "ISBLANK": return .bool(a.first.map { sc($0).isEmpty } ?? false)
        case "ISNUMBER": return .bool(a.first.map { sc($0).isNumber } ?? false)
        case "ISTEXT": return .bool(a.first.map { P.isText(sc($0)) } ?? false)
        case "TRUE": return .bool(true)
        case "FALSE": return .bool(false)
        case "PI": return .num(Double.pi)
        case "RAND": return .num(Double.random(in: 0..<1))
        case "TODAY": return .num(floor(serialFromDate(Date())))
        case "NOW": return .num(serialFromDate(Date()))
        default: break
        }
        if let e = firstError(a) { return e }
        let n = nums(a)

        func arg(_ i: Int) -> CV { i < a.count ? sc(a[i]) : .err("#N/A") }
        func argN(_ i: Int) -> Double? { i < a.count ? dbl(a[i]) : nil }
        func one(_ g: (Double) -> Double) -> CV { guard let x = argN(0) else { return .err("#VALUE!") }; let r = g(x); return r.isFinite ? .num(r) : .err("#NUM!") }
        func str(_ i: Int) -> String { arg(i).text }

        switch f {
        // ---- aggregates
        case "SUM": return .num(n.reduce(0, +))
        case "AVERAGE": return n.isEmpty ? .err("#DIV/0!") : .num(n.reduce(0, +) / Double(n.count))
        case "MIN": return .num(n.min() ?? 0)
        case "MAX": return .num(n.max() ?? 0)
        case "COUNT": return .num(Double(n.count))
        case "COUNTA": return .num(Double(flat(a).filter { !$0.isEmpty }.count))
        case "COUNTBLANK": return .num(Double(flat(a).filter { $0.isEmpty || $0.text.isEmpty }.count))
        case "PRODUCT": return .num(n.reduce(1, *))
        case "SUMSQ": return .num(n.reduce(0) { $0 + $1 * $1 })
        case "MEDIAN":
            guard !n.isEmpty else { return .err("#NUM!") }
            let s = n.sorted(); return .num(s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        case "VAR", "STDEV":
            guard n.count > 1 else { return .err("#DIV/0!") }
            let m = n.reduce(0, +) / Double(n.count), v = n.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n.count - 1)
            return .num(f == "VAR" ? v : v.squareRoot())
        case "LARGE", "SMALL":
            guard let k = argN(1), k >= 1 else { return .err("#NUM!") }
            let s = nums([a[0]]).sorted(by: f == "LARGE" ? (>) : (<)); return Int(k) <= s.count ? .num(s[Int(k) - 1]) : .err("#NUM!")
        case "SUMPRODUCT":
            let lists = a.map { nums([$0]) }; guard let first = lists.first, lists.allSatisfy({ $0.count == first.count }) else { return .err("#VALUE!") }
            return .num((0..<first.count).reduce(0.0) { acc, i in acc + lists.reduce(1.0) { $0 * $1[i] } })
        // ---- math
        case "ABS": return one { abs($0) }
        case "SQRT": return one { $0.squareRoot() }
        case "EXP": return one { exp($0) }
        case "LN": return one { log($0) }
        case "LOG10": return one { log10($0) }
        case "LOG": if let b = argN(1) { return one { log($0) / log(b) } }; return one { log10($0) }
        case "SIN": return one { sin($0) }
        case "COS": return one { cos($0) }
        case "TAN": return one { tan($0) }
        case "INT": return one { floor($0) }
        case "SIGN": return one { $0 > 0 ? 1 : $0 < 0 ? -1 : 0 }
        case "POWER": guard let x = argN(0), let y = argN(1) else { return .err("#VALUE!") }; let r = pow(x, y); return r.isFinite ? .num(r) : .err("#NUM!")
        case "MOD": guard let x = argN(0), let y = argN(1), y != 0 else { return .err("#DIV/0!") }; return .num(x - y * floor(x / y))
        case "ROUND", "ROUNDUP", "ROUNDDOWN":
            guard let x = argN(0) else { return .err("#VALUE!") }
            let m = pow(10, argN(1) ?? 0), v = x * m
            let r = f == "ROUND" ? v.rounded(.toNearestOrAwayFromZero) : f == "ROUNDUP" ? (v < 0 ? floor(v) : ceil(v)) : (v < 0 ? ceil(v) : floor(v))
            return .num(r / m)
        case "CEILING": guard let x = argN(0), let s = argN(1), s != 0 else { return .err("#DIV/0!") }; return .num(ceil(x / s) * s)
        case "FLOOR": guard let x = argN(0), let s = argN(1), s != 0 else { return .err("#DIV/0!") }; return .num(floor(x / s) * s)
        case "RANDBETWEEN": guard let lo = argN(0), let hi = argN(1), hi >= lo else { return .err("#NUM!") }; return .num(Double(Int.random(in: Int(lo)...Int(hi))))
        // ---- logic
        case "AND": return .bool(flat(a).allSatisfy { (dbl($0) ?? 0) != 0 })
        case "OR": return .bool(flat(a).contains { (dbl($0) ?? 0) != 0 })
        case "NOT": return .bool((dbl(arg(0)) ?? 0) == 0)
        // ---- text
        case "CONCAT", "CONCATENATE": return .str(flat(a).map(\.text).joined())
        case "UPPER": return .str(str(0).uppercased())
        case "LOWER": return .str(str(0).lowercased())
        case "PROPER": return .str(str(0).capitalized)
        case "LEN": return .num(Double(str(0).count))
        case "TRIM": return .str(str(0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        case "LEFT": let k = Int(argN(1) ?? 1); return .str(String(str(0).prefix(max(0, k))))
        case "RIGHT": let k = Int(argN(1) ?? 1); return .str(String(str(0).suffix(max(0, k))))
        case "MID": guard let s = argN(1), let l = argN(2), s >= 1 else { return .err("#VALUE!") }
            return .str(String(str(0).dropFirst(Int(s) - 1).prefix(max(0, Int(l)))))
        case "REPT": return .str(String(repeating: str(0), count: max(0, Int(argN(1) ?? 0))))
        case "SUBSTITUTE": return .str(str(0).replacingOccurrences(of: str(1), with: str(2)))
        case "EXACT": return .bool(str(0) == str(1))
        case "FIND", "SEARCH":
            let hay = f == "FIND" ? str(1) : str(1).lowercased(), needle = f == "FIND" ? str(0) : str(0).lowercased()
            let start = max(1, Int(argN(2) ?? 1)) - 1
            guard start <= hay.count, let r = hay.range(of: needle, range: hay.index(hay.startIndex, offsetBy: start)..<hay.endIndex) else { return .err("#VALUE!") }
            return .num(Double(hay.distance(from: hay.startIndex, to: r.lowerBound) + 1))
        case "VALUE": return dbl(arg(0)).map { .num($0) } ?? (parseISODate(str(0)).map { .num($0) } ?? .err("#VALUE!"))
        case "TEXT": return text(arg(0), str(1))
        // ---- dates
        case "DATE": guard let y = argN(0), let m = argN(1), let d = argN(2), let s = serialFrom(Int(y), Int(m), Int(d)) else { return .err("#VALUE!") }; return .num(s)
        case "YEAR", "MONTH", "DAY", "WEEKDAY":
            guard let d = argN(0) else { return .err("#VALUE!") }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: dateFromSerial(d))
            return .num(Double(f == "YEAR" ? c.year! : f == "MONTH" ? c.month! : f == "DAY" ? c.day! : c.weekday!))
        case "DAYS": guard let e = argN(0), let s = argN(1) else { return .err("#VALUE!") }; return .num(e - s)
        // ---- lookup & conditional
        case "CHOOSE": guard let i = argN(0), Int(i) >= 1, Int(i) < a.count else { return .err("#VALUE!") }; return sc(a[Int(i)])
        case "INDEX":
            guard let t = table(a[0]) else { return a.count > 0 ? sc(a[0]) : .err("#REF!") }
            let r = Int(argN(1) ?? 1), c = Int(argN(2) ?? (t.rows == 1 ? 0 : 1))
            let rr = t.rows == 1 && a.count == 2 ? 1 : r, cc = t.rows == 1 && a.count == 2 ? r : (c == 0 ? 1 : c)
            guard rr >= 1, rr <= t.rows, cc >= 1, cc <= t.cols else { return .err("#REF!") }
            return t.vals[(rr - 1) * t.cols + (cc - 1)]
        case "MATCH":
            guard a.count >= 2, let t = table(a[1]) ?? Optional((flat([a[1]]), 1, 1)) else { return .err("#N/A") }
            let key = arg(0), type = Int(argN(2) ?? 1), vals = t.vals
            if type == 0 { if let i = vals.firstIndex(where: { P.cmp($0, key, "=") == .bool(true) }) { return .num(Double(i + 1)) }; return .err("#N/A") }
            var best: Int?
            for (i, v) in vals.enumerated() where !v.isEmpty { if P.cmp(v, key, type > 0 ? "<=" : ">=") == .bool(true) { best = i } else if type > 0 { break } }
            return best.map { .num(Double($0 + 1)) } ?? .err("#N/A")
        case "VLOOKUP", "HLOOKUP":
            guard a.count >= 3, let t = table(a[1]), let idx = argN(2), idx >= 1 else { return .err("#N/A") }
            let key = arg(0), exact = a.count > 3 && (dbl(a[3]) ?? 1) == 0, v = f == "VLOOKUP"
            let count = v ? t.rows : t.cols, span = v ? t.cols : t.rows
            guard Int(idx) <= span else { return .err("#REF!") }
            func head(_ i: Int) -> CV { v ? t.vals[i * t.cols] : t.vals[i] }
            func pick(_ i: Int) -> CV { v ? t.vals[i * t.cols + Int(idx) - 1] : t.vals[(Int(idx) - 1) * t.cols + i] }
            if exact { for i in 0..<count where P.cmp(head(i), key, "=") == .bool(true) { return pick(i) }; return .err("#N/A") }
            var best: Int?; for i in 0..<count { if P.cmp(head(i), key, "<=") == .bool(true) { best = i } else { break } }
            return best.map(pick) ?? .err("#N/A")
        case "COUNTIF": guard a.count >= 2 else { return .err("#N/A") }; return .num(Double(flat([a[0]]).filter { matches($0, a[1]) }.count))
        case "SUMIF", "AVERAGEIF":
            guard a.count >= 2 else { return .err("#N/A") }
            let r = flat([a[0]]), s = a.count > 2 ? flat([a[2]]) : r
            var hits: [Double] = []; for (i, v) in r.enumerated() where matches(v, a[1]) && i < s.count { if case .num(let d) = s[i] { hits.append(d) } }
            return f == "SUMIF" ? .num(hits.reduce(0, +)) : (hits.isEmpty ? .err("#DIV/0!") : .num(hits.reduce(0, +) / Double(hits.count)))
        case "COUNTIFS", "SUMIFS":
            let sumRange = f == "SUMIFS" ? flat([a[0]]) : [], start = f == "SUMIFS" ? 1 : 0
            var pairs: [([CV], CV)] = []; var i = start; while i + 1 < a.count { pairs.append((flat([a[i]]), a[i + 1])); i += 2 }
            guard let len = pairs.first?.0.count else { return .err("#N/A") }
            var total = 0.0
            for k in 0..<len where pairs.allSatisfy({ k < $0.0.count && matches($0.0[k], $0.1) }) {
                if f == "COUNTIFS" { total += 1 } else if k < sumRange.count, case .num(let d) = sumRange[k] { total += d }
            }
            return .num(total)
        default: return .err("#NAME?")
        }
    }
}
