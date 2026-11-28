// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Math engine: a calculator language with variables, your own functions, calculus helpers and a root finder.
//   a = 5          f(x) = x^2 + 1      f(a) * 2        integrate(sin(x), 0, pi)      solve(x^2 = 2, 1)      sum(k^2, k, 1, 10)

indirect enum MNode {
    case num(Double), v(String), neg(MNode), bin(Character, MNode, MNode), call(String, [MNode]), fact(MNode), pct(MNode), eq(MNode, MNode)
}

struct MathError: Error { let message: String }

enum MResult: Equatable {
    case value(Double), defined(String, Double), function(String), error(String), empty
    var text: String {
        switch self {
        case .value(let d): return MathFormat.string(d)
        case .defined(let n, let d): return "\(n) = \(MathFormat.string(d))"
        case .function(let s): return s
        case .error(let e): return e
        case .empty: return ""
        }
    }
    var isError: Bool { if case .error = self { return true }; return false }
}

enum MathFormat {
    static let sup: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻", "+": "⁺"]
    static func string(_ d: Double, digits: Int = 10) -> String {
        if d.isNaN { return "undefined" }
        if d.isInfinite { return d < 0 ? "−∞" : "∞" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)).replacingOccurrences(of: "-", with: "−") }
        var s = String(format: "%.\(digits)g", d)
        if let r = s.range(of: "e") {
            var mant = String(s[..<r.lowerBound]), exp = String(s[r.upperBound...])
            if mant.contains(".") { while mant.hasSuffix("0") { mant.removeLast() }; if mant.hasSuffix(".") { mant.removeLast() } }
            if exp.hasPrefix("+") { exp.removeFirst() }
            exp = exp.replacingOccurrences(of: "-0", with: "-").replacingOccurrences(of: "^0+(?=\\d)", with: "", options: .regularExpression)
            return (mant + " × 10" + String(exp.map { sup[$0] ?? $0 })).replacingOccurrences(of: "-", with: "−")
        }
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s.replacingOccurrences(of: "-", with: "−")
    }
}

// MARK: - Lexer and parser

enum MTok: Equatable { case num(Double), id(String), op(Character), end }

struct MathParser {
    var toks: [MTok] = [], pos = 0
    let isFunc: (String) -> Bool

    init(_ s: String, isFunc: @escaping (String) -> Bool) throws {
        self.isFunc = isFunc
        let c = Array(s.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "·", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "**", with: "^"))
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == " " || ch == "\t" { i += 1; continue }
            if ch.isNumber || (ch == "." && i + 1 < c.count && c[i + 1].isNumber) {
                var j = i; while j < c.count && (c[j].isNumber || c[j] == "." || c[j] == "_") { j += 1 }
                if j < c.count, c[j] == "e" || c[j] == "E" {
                    var k = j + 1; if k < c.count, c[k] == "+" || c[k] == "-" { k += 1 }
                    if k < c.count, c[k].isNumber { while k < c.count && c[k].isNumber { k += 1 }; j = k }
                }
                guard let d = Double(String(c[i..<j]).replacingOccurrences(of: "_", with: "")) else { throw MathError(message: "Bad number") }
                toks.append(.num(d)); i = j; continue
            }
            if ch.isLetter || ch == "_" || ch == "π" || ch == "θ" || ch == "τ" || ch == "φ" {
                var j = i + 1; while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_") { j += 1 }
                var name = String(c[i..<j]); if name == "π" { name = "pi" } else if name == "τ" { name = "tau" } else if name == "φ" { name = "phi" }
                toks.append(.id(name)); i = j; continue
            }
            if "+-*/^(),=%!".contains(ch) { toks.append(.op(ch)); i += 1; continue }
            if ch == "√" { toks.append(.id("sqrt")); i += 1; continue }
            throw MathError(message: "Unexpected “\(ch)”")
        }
        toks.append(.end)
    }

    var cur: MTok { toks[pos] }
    mutating func eat() { pos += 1 }
    func isPrimaryStart(_ t: MTok) -> Bool { switch t { case .num, .id: return true; case .op(let c): return c == "("; default: return false } }

    mutating func parseAll() throws -> MNode {
        let n = try parse(0)
        guard cur == .end else { throw MathError(message: "Unexpected “\(describe(cur))”") }
        return n
    }
    func describe(_ t: MTok) -> String { switch t { case .num(let d): return MathFormat.string(d); case .id(let s): return s; case .op(let c): return String(c); case .end: return "end" } }

    // binding powers: = 1, + - 10, * / and implicit 20, unary minus 25, ^ 30, postfix 40
    mutating func parse(_ minBP: Int) throws -> MNode {
        var left = try parsePrefix()
        while true {
            switch cur {
            case .op("!"): if 40 >= minBP { eat(); left = .fact(left); continue }
            case .op("%"): if 40 >= minBP { eat(); left = .pct(left); continue }
            case .op("^"): if 30 >= minBP { eat(); let r = try parse(25); left = .bin("^", left, r); continue }
            case .op("*"), .op("/"): if 20 >= minBP, case .op(let o) = cur { eat(); left = .bin(o, left, try parse(21)); continue }
            case .op("+"), .op("-"): if 10 >= minBP, case .op(let o) = cur { eat(); left = .bin(o, left, try parse(11)); continue }
            case .op("="): if 1 >= minBP { eat(); left = .eq(left, try parse(2)); continue }
            default:
                if 20 >= minBP, isPrimaryStart(cur) { left = .bin("*", left, try parse(21)); continue }      // implicit multiplication: 2x, 3(4+1), (a)(b)
            }
            break
        }
        return left
    }
    mutating func parsePrefix() throws -> MNode {
        switch cur {
        case .num(let d): eat(); return .num(d)
        case .op("-"): eat(); return .neg(try parse(25))
        case .op("+"): eat(); return try parse(25)
        case .op("("): eat(); let n = try parse(0); guard cur == .op(")") else { throw MathError(message: "Missing )") }; eat(); return n
        case .id(let name):
            eat()
            if cur == .op("("), isFunc(name) {
                eat(); var args: [MNode] = []
                if cur != .op(")") { while true { args.append(try parse(0)); if cur == .op(",") { eat(); continue }; break } }
                guard cur == .op(")") else { throw MathError(message: "Missing ) after \(name)(") }; eat()
                return .call(name, args)
            }
            if isFunc(name), cur != .op("(") {                  // sqrt 2, sin x
                if isPrimaryStart(cur) { return .call(name, [try parse(26)]) }
            }
            return .v(name)
        case .op(let c): throw MathError(message: "Unexpected “\(c)”")
        case .end: throw MathError(message: "Incomplete expression")
        }
    }
}

// MARK: - Evaluator

final class MathEnv {
    var vars: [String: Double] = ["pi": Double.pi, "e": M_E, "tau": 2 * Double.pi, "phi": (1 + 5.0.squareRoot()) / 2]
    var funcs: [String: (params: [String], body: MNode, text: String)] = [:]
    var degrees = false
    var last: Double?
    var depth = 0

    static let builtins: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "sqrt", "cbrt", "abs", "exp", "ln", "log", "log2", "log10", "floor", "ceil", "round", "sign", "min", "max", "mod", "gcd", "lcm", "fact", "ncr", "npr", "hypot", "root", "deg", "rad", "mean", "median", "stdev", "sum", "product", "integrate", "diff", "solve", "gamma", "pow", "trunc", "frac", "clamp"]
    func isFunc(_ n: String) -> Bool { Self.builtins.contains(n) || funcs[n] != nil }

    func parse(_ s: String) throws -> MNode { var p = try MathParser(s, isFunc: { [unowned self] in self.isFunc($0) }); return try p.parseAll() }

    /// Runs one statement: an expression, `name = expr`, or `f(x, y) = expr`.
    func run(_ line: String) -> MResult {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("//") || t.hasPrefix("#") { return .empty }
        do {
            // function definition  f(x, y) = ...
            if let m = t.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\s*\\(\\s*[A-Za-z_][A-Za-z0-9_]*(\\s*,\\s*[A-Za-z_][A-Za-z0-9_]*)*\\s*\\)\\s*=(?!=)", options: .regularExpression) {
                let head = String(t[m]), name = head.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                let open = head.firstIndex(of: "(")!, close = head.lastIndex(of: ")")!
                let params = head[head.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if Self.builtins.contains(name) { return .error("“\(name)” is built in") }
                let body = String(t[m.upperBound...])
                funcs[name] = (params, .num(0), body)                                   // register first so recursion parses
                let node = try parse(body); funcs[name] = (params, node, body)
                return .function("\(name)(\(params.joined(separator: ", "))) = \(body.trimmingCharacters(in: .whitespaces))")
            }
            // assignment  a = expr
            if let m = t.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\s*=(?!=)", options: .regularExpression) {
                let name = String(t[m]).dropLast().trimmingCharacters(in: .whitespaces)
                if ["pi", "e", "tau", "phi"].contains(name) { return .error("“\(name)” is a constant") }
                let v = try eval(try parse(String(t[m.upperBound...])), [:]); vars[name] = v; last = v
                return .defined(name, v)
            }
            let v = try eval(try parse(t), [:]); last = v; vars["ans"] = v
            return .value(v)
        } catch let e as MathError { return .error(e.message) } catch { return .error("Couldn't read that") }
    }

    func angle(_ x: Double) -> Double { degrees ? x * .pi / 180 : x }
    func unangle(_ x: Double) -> Double { degrees ? x * 180 / .pi : x }

    func eval(_ n: MNode, _ loc: [String: Double]) throws -> Double {
        depth += 1; defer { depth -= 1 }
        if depth > 400 { throw MathError(message: "Too deeply nested") }
        switch n {
        case .num(let d): return d
        case .v(let s): if let d = loc[s] { return d }; if let d = vars[s] { return d }; throw MathError(message: "“\(s)” isn't defined")
        case .neg(let a): return -(try eval(a, loc))
        case .fact(let a): return try factorial(try eval(a, loc))
        case .pct(let a): return try eval(a, loc) / 100
        case .eq(let l, let r): return try eval(l, loc) - eval(r, loc)
        case .bin(let o, let l, let r):
            let a = try eval(l, loc), b = try eval(r, loc)
            switch o { case "+": return a + b; case "-": return a - b; case "*": return a * b
            case "/": if b == 0 { throw MathError(message: "Division by zero") }; return a / b
            default: let p = pow(a, b); if p.isNaN && !a.isNaN && !b.isNaN { throw MathError(message: "Not a real number") }; return p }
        case .call(let name, let args): return try call(name, args, loc)
        }
    }

    func factorial(_ x: Double) throws -> Double {
        guard x >= 0, x == x.rounded() else { return tgamma(x + 1) }
        if x > 170 { return .infinity }
        return (1...max(Int(x), 1)).reduce(1.0) { $0 * Double($1) }
    }
    func need(_ args: [MNode], _ n: Int, _ name: String) throws { if args.count != n { throw MathError(message: "\(name) needs \(n) value\(n == 1 ? "" : "s")") } }

    func call(_ name: String, _ args: [MNode], _ loc: [String: Double]) throws -> Double {
        if let f = funcs[name] {
            guard f.params.count == args.count else { throw MathError(message: "\(name) needs \(f.params.count) value\(f.params.count == 1 ? "" : "s")") }
            var l = loc; for (p, a) in zip(f.params, args) { l[p] = try eval(a, loc) }
            return try eval(f.body, l)
        }
        // lazy forms: the first argument is an expression in x (or the named variable)
        switch name {
        case "integrate":
            try need(args, 3, name); let a = try eval(args[1], loc), b = try eval(args[2], loc)
            return try simpson(args[0], a, b, loc)
        case "diff":
            try need(args, 2, name); let x0 = try eval(args[1], loc)
            func f(_ x: Double) throws -> Double { var l = loc; l["x"] = x; return try eval(args[0], l) }
            let h = 1e-4 * max(1, abs(x0))
            let d1 = (try f(x0 + h) - f(x0 - h)) / (2 * h), d2 = (try f(x0 + h / 2) - f(x0 - h / 2)) / h
            let d = (4 * d2 - d1) / 3
            return abs(d) < 1e-9 * max(1, abs(try f(x0))) ? 0 : d
        case "solve":
            guard args.count == 2 else { throw MathError(message: "solve needs an equation and a starting guess") }
            let r = try root(args[0], try eval(args[1], loc), loc)
            return abs(r) < 1e-12 ? 0 : r
        case "sum", "product":
            if args.count == 4, case .v(let k) = args[1] {
                let a = Int(try eval(args[2], loc)), b = Int(try eval(args[3], loc)); guard b - a < 1_000_000 else { throw MathError(message: "Too many terms") }
                var acc = name == "sum" ? 0.0 : 1.0
                if a <= b { for i in a...b { var l = loc; l[k] = Double(i); let t = try eval(args[0], l); acc = name == "sum" ? acc + t : acc * t } }
                return acc
            }
        default: break
        }
        let v = try args.map { try eval($0, loc) }
        func one() throws -> Double { guard v.count == 1 else { throw MathError(message: "\(name) needs one value") }; return v[0] }
        func two() throws -> (Double, Double) { guard v.count == 2 else { throw MathError(message: "\(name) needs two values") }; return (v[0], v[1]) }
        func domain(_ ok: Bool, _ x: Double, _ r: Double) throws -> Double { if !ok { throw MathError(message: "\(name) isn't defined for \(MathFormat.string(x))") }; return r }
        switch name {
        case "sin": return sin(angle(try one())); case "cos": return cos(angle(try one()))
        case "tan": let x = angle(try one()); if abs(cos(x)) < 1e-14 { throw MathError(message: "tan is undefined here") }; return tan(x)
        case "asin": let x = try one(); return try domain(abs(x) <= 1, x, unangle(asin(x))); case "acos": let x = try one(); return try domain(abs(x) <= 1, x, unangle(acos(x)))
        case "atan": return unangle(atan(try one())); case "atan2": let (y, x) = try two(); return unangle(atan2(y, x))
        case "sinh": return sinh(try one()); case "cosh": return cosh(try one()); case "tanh": return tanh(try one())
        case "sqrt": let x = try one(); return try domain(x >= 0, x, x.squareRoot()); case "cbrt": return cbrt(try one())
        case "abs": return abs(try one()); case "exp": return exp(try one())
        case "ln": let x = try one(); return try domain(x > 0, x, log(x))
        case "log", "log10": let x = try one(); return try domain(x > 0, x, log10(x)); case "log2": let x = try one(); return try domain(x > 0, x, log2(x))
        case "floor": return floor(try one()); case "ceil": return ceil(try one()); case "trunc": return trunc(try one())
        case "round": if v.count == 2 { let p = pow(10, v[1]); return (v[0] * p).rounded() / p }; return (try one()).rounded()
        case "frac": let x = try one(); return x - floor(x)
        case "sign": let x = try one(); return x > 0 ? 1 : x < 0 ? -1 : 0
        case "min": guard !v.isEmpty else { throw MathError(message: "min needs values") }; return v.min()!
        case "max": guard !v.isEmpty else { throw MathError(message: "max needs values") }; return v.max()!
        case "clamp": guard v.count == 3 else { throw MathError(message: "clamp needs value, low, high") }; return min(max(v[0], v[1]), v[2])
        case "mod": let (a, b) = try two(); if b == 0 { throw MathError(message: "Division by zero") }; return a - b * floor(a / b)
        case "gcd": var (a, b) = try two(); a = abs(a); b = abs(b); while b != 0 { (a, b) = (b, a.truncatingRemainder(dividingBy: b)) }; return a
        case "lcm": var (a, b) = try two(); let p = abs(a * b); a = abs(a); b = abs(b); while b != 0 { (a, b) = (b, a.truncatingRemainder(dividingBy: b)) }; return a == 0 ? 0 : p / a
        case "fact": return try factorial(try one()); case "gamma": return tgamma(try one())
        case "ncr": let (n, k) = try two(); guard n >= k, k >= 0 else { return 0 }; return ((try factorial(n)) / ((try factorial(k)) * (try factorial(n - k)))).rounded()
        case "npr": let (n, k) = try two(); guard n >= k, k >= 0 else { return 0 }; return ((try factorial(n)) / (try factorial(n - k))).rounded()
        case "hypot": let (a, b) = try two(); return hypot(a, b)
        case "pow": let (a, b) = try two(); return pow(a, b)
        case "root": let (x, n) = try two(); if x < 0 && Int(n) % 2 != 0 { return -pow(-x, 1 / n) }; return try domain(x >= 0, x, pow(x, 1 / n))
        case "deg": return try one() * 180 / .pi; case "rad": return try one() * .pi / 180
        case "mean": guard !v.isEmpty else { throw MathError(message: "mean needs values") }; return v.reduce(0, +) / Double(v.count)
        case "sum": return v.reduce(0, +)
        case "product": return v.reduce(1, *)
        case "median": guard !v.isEmpty else { throw MathError(message: "median needs values") }; let s = v.sorted(), n = s.count; return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
        case "stdev": guard v.count > 1 else { throw MathError(message: "stdev needs two or more values") }; let m = v.reduce(0, +) / Double(v.count); return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
        default: throw MathError(message: "Unknown function “\(name)”")
        }
    }

    func simpson(_ body: MNode, _ a: Double, _ b: Double, _ loc: [String: Double]) throws -> Double {
        func f(_ x: Double) throws -> Double { var l = loc; l["x"] = x; return try eval(body, l) }
        if a == b { return 0 }
        let n = 2000, h = (b - a) / Double(n)
        var s = try f(a) + f(b), big = max(abs(try f(a)), abs(try f(b)))
        for i in 1..<n { let y = try f(a + Double(i) * h); big = max(big, abs(y)); s += (i % 2 == 0 ? 2 : 4) * y }
        var r = s * h / 3
        if abs(r) < 1e-10 * big * abs(b - a) { r = 0 }                       // round-off, not a real answer
        if r.isNaN || r.isInfinite { throw MathError(message: "The integral doesn't converge here") }
        return r
    }
    func root(_ body: MNode, _ guess: Double, _ loc: [String: Double]) throws -> Double {
        func f(_ x: Double) -> Double { var l = loc; l["x"] = x; return (try? eval(body, l)) ?? .nan }
        var x = guess
        for _ in 0..<80 {
            let fx = f(x); if fx.isNaN { break }
            if abs(fx) < 1e-12 { return abs(x) < 1e-12 ? 0 : x }
            let h = 1e-6 * max(1, abs(x)), d = (f(x + h) - f(x - h)) / (2 * h)
            if d == 0 || d.isNaN { break }
            let nx = x - fx / d; if abs(nx - x) < 1e-13 * max(1, abs(x)) { return nx }; x = nx
        }
        // fall back to scanning for a sign change around the guess
        var step = 0.5, lo = guess - step, hi = guess + step
        for _ in 0..<40 {
            if f(lo) * f(hi) < 0 { for _ in 0..<200 { let mid = (lo + hi) / 2; if f(lo) * f(mid) <= 0 { hi = mid } else { lo = mid } }; return (lo + hi) / 2 }
            step *= 2; lo = guess - step; hi = guess + step
        }
        throw MathError(message: "No solution found near \(MathFormat.string(guess))")
    }

    /// A fast function of x for graphing; nil if it doesn't parse.
    func compile(_ text: String) -> ((Double) -> Double)? {
        var t = text.trimmingCharacters(in: .whitespaces)
        for p in ["y=", "y =", "f(x)=", "f(x) ="] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        guard !t.isEmpty, let node = try? parse(t) else { return nil }
        return { [unowned self] x in (try? self.eval(node, ["x": x])) ?? .nan }
    }

    /// Evaluates a whole notebook's calc text top to bottom; returns one result per line.
    func runBlock(_ text: String) -> [MResult] { text.components(separatedBy: "\n").map { run($0) } }
}
