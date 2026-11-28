// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import CoreText

// Typesetter: a useful subset of LaTeX math, laid out with boxes and drawn with the STIX Two Math font.
//   \frac{a}{b}  \sqrt[3]{x}  x^2  a_{ij}  \sum_{k=1}^{n}  \int_0^\pi  \left( … \right)  \begin{pmatrix} a & b \\ c & d \end{pmatrix}  \hat{x}  \alpha  \leq  \text{words}

indirect enum TNode {
    enum Kind { case ord, bin, rel, punct, open, close }
    case sym(String, Kind), letter(Character), row([TNode]), frac(TNode, TNode, bar: Bool), sqrt(TNode, TNode?), scripts(TNode, sub: TNode?, sup: TNode?)
    case bigop(String, limits: Bool), fn(String), delim(String, TNode, String), matrix([[TNode]], left: String, right: String, align: String), accent(String, TNode), text(String, bold: Bool), space(CGFloat), lines([TNode])
}

final class MBox {
    var w: CGFloat, asc: CGFloat, desc: CGFloat
    var draw: (CGPoint) -> Void
    init(w: CGFloat, asc: CGFloat, desc: CGFloat, draw: @escaping (CGPoint) -> Void) { self.w = w; self.asc = asc; self.desc = desc; self.draw = draw }
    var h: CGFloat { asc + desc }
}

enum TeX {
    // MARK: symbol tables
    static let symbols: [String: (String, TNode.Kind)] = {
        var t: [String: (String, TNode.Kind)] = [:]
        let greek = ["alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
                     "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"]
        for (k, v) in greek { t[k] = (v, .ord) }
        let ord = ["infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "emptyset": "∅", "varnothing": "∅", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "dots": "…", "hbar": "ℏ", "ell": "ℓ", "angle": "∠", "triangle": "△", "degree": "°", "prime": "′", "neg": "¬", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "top": "⊤", "bot": "⊥", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "{": "{", "}": "}", "lbrace": "{", "rbrace": "}"]
        for (k, v) in ord { t[k] = (v, .ord) }
        let bin = ["pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•", "cup": "∪", "cap": "∩", "oplus": "⊕", "otimes": "⊗", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨", "setminus": "∖", "minus": "−"]
        for (k, v) in bin { t[k] = (v, .bin) }
        let rel = ["leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⟹", "iff": "⟺", "mapsto": "↦", "longrightarrow": "⟶", "uparrow": "↑", "downarrow": "↓", "ll": "≪", "gg": "≫", "perp": "⊥", "parallel": "∥", "mid": "∣", "therefore": "∴", "because": "∵"]
        for (k, v) in rel { t[k] = (v, .rel) }
        return t
    }()
    static let bigops: [String: (String, Bool)] = ["sum": ("∑", true), "prod": ("∏", true), "coprod": ("∐", true), "int": ("∫", false), "iint": ("∬", false), "iiint": ("∭", false), "oint": ("∮", false), "bigcup": ("⋃", true), "bigcap": ("⋂", true)]
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "ln", "log", "lg", "exp", "det", "gcd", "max", "min", "sup", "inf", "lim", "limsup", "liminf", "arg", "deg", "dim", "ker", "Pr", "mod"]
    static let limitFns: Set<String> = ["lim", "limsup", "liminf", "max", "min", "sup", "inf"]
    static let blackboard = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "H": "ℍ"]

    // MARK: parser
    enum Tok: Equatable { case cmd(String), ch(Character), lb, rb, caret, under, amp, nl, raw(String) }
    struct Parser {
        var t: [Tok] = [], i = 0
        init(_ s: String) {
            let c = Array(s); var k = 0
            while k < c.count {
                let ch = c[k]
                switch ch {
                case "\\":
                    k += 1; guard k < c.count else { break }
                    if c[k] == "\\" { t.append(.nl) }
                    else if c[k].isLetter {
                        var j = k; while j < c.count && c[j].isLetter { j += 1 }
                        let name = String(c[k..<j]); t.append(.cmd(name)); k = j - 1
                        if ["text", "mathrm", "textrm", "operatorname", "mbox", "mathbf", "textbf", "mathbb"].contains(name) {
                            var q = j; while q < c.count && c[q] == " " { q += 1 }
                            if q < c.count, c[q] == "{" { var depth = 1, e = q + 1; while e < c.count && depth > 0 { if c[e] == "{" { depth += 1 } else if c[e] == "}" { depth -= 1 }; e += 1 }
                                t.append(.raw(String(c[(q + 1)..<(depth == 0 ? e - 1 : e)]))); k = e - 1 }
                        }
                    }
                    else { t.append(.cmd(String(c[k]))) }
                case "{": t.append(.lb); case "}": t.append(.rb); case "^": t.append(.caret); case "_": t.append(.under); case "&": t.append(.amp)
                case " ", "\n", "\t": break
                default: t.append(.ch(ch))
                }
                k += 1
            }
        }
        var cur: Tok? { i < t.count ? t[i] : nil }
        mutating func rawGroup() -> String {                       // {text} → text, for \begin{...} and \text{...}
            guard cur == .lb else { return "" }; i += 1; var s = "", depth = 1
            while let x = cur { i += 1
                if x == .lb { depth += 1 } else if x == .rb { depth -= 1; if depth == 0 { break } }
                switch x { case .raw(let r): s += r; case .ch(let c): s.append(c); case .cmd(let n): s += n.count == 1 ? n : "\\" + n; case .lb: s += "{"; case .rb: s += "}"; case .caret: s += "^"; case .under: s += "_"; case .amp: s += "&"; case .nl: s += " " }
            }
            return s
        }
        mutating func row(until stop: (Tok) -> Bool) -> TNode {
            var items: [TNode] = []
            while let x = cur, !stop(x) { if let a = atom() { items.append(withScripts(a)) } else { i += 1 } }
            return items.count == 1 ? items[0] : .row(items)
        }
        mutating func group() -> TNode {
            if cur == .lb { i += 1; let r = row { $0 == .rb }; if cur == .rb { i += 1 }; return r }
            if let a = atom() { return a }; return .row([])
        }
        mutating func withScripts(_ base: TNode) -> TNode {
            var sub: TNode?, sup: TNode?
            while let x = cur, x == .caret || x == .under {
                i += 1; let g = group()
                if x == .caret { sup = g } else { sub = g }
            }
            return sub == nil && sup == nil ? base : .scripts(base, sub: sub, sup: sup)
        }
        mutating func delimiter() -> String {
            guard let x = cur else { return "." }; i += 1
            switch x { case .ch(let c): return String(c); case .cmd(let n): return n == "{" || n == "lbrace" ? "{" : n == "}" || n == "rbrace" ? "}" : n == "langle" ? "⟨" : n == "rangle" ? "⟩" : n == "|" || n == "Vert" ? "‖" : n == "lvert" || n == "rvert" ? "|" : n == "lfloor" ? "⌊" : n == "rfloor" ? "⌋" : n == "lceil" ? "⌈" : n == "rceil" ? "⌉" : "."
            case .lb: return "{"; case .rb: return "}"; default: return "." }
        }
        mutating func atom() -> TNode? {
            guard let x = cur else { return nil }; i += 1
            switch x {
            case .lb: let r = row { $0 == .rb }; if cur == .rb { i += 1 }; return r
            case .ch(let c):
                if c.isLetter { return .letter(c) }
                if "+-*/".contains(c) { return .sym(c == "-" ? "−" : c == "*" ? "∗" : String(c), .bin) }
                if "=<>".contains(c) { return .sym(String(c), .rel) }
                if ",;".contains(c) { return .sym(String(c), .punct) }
                if "([".contains(c) { return .sym(String(c), .open) }; if ")]".contains(c) { return .sym(String(c), .close) }
                if c == "!" || c == "'" { return .sym(c == "'" ? "′" : "!", .ord) }
                if c == "|" { return .sym("|", .ord) }
                return .sym(String(c), .ord)
            case .cmd(let n): return command(n)
            case .raw(let s): return .text(s, bold: false)
            case .amp, .nl, .rb, .caret, .under: i -= 1; return nil
            }
        }
        mutating func command(_ n: String) -> TNode? {
            if let s = TeX.symbols[n] { return .sym(s.0, s.1) }
            if let b = TeX.bigops[n] { return .bigop(b.0, limits: b.1) }
            if TeX.functions.contains(n) { return .fn(n) }
            switch n {
            case "frac", "dfrac", "tfrac": let a = group(), b = group(); return .frac(a, b, bar: true)
            case "binom": let a = group(), b = group(); return .delim("(", .frac(a, b, bar: false), ")")
            case "sqrt":
                var idx: TNode?
                if cur == .ch("[") { i += 1; idx = row { $0 == .ch("]") }; if cur == .ch("]") { i += 1 } }
                return .sqrt(group(), idx)
            case "left":
                let l = delimiter(); let body = row { $0 == .cmd("right") }
                if cur == .cmd("right") { i += 1 }; let r = delimiter(); return .delim(l, body, r)
            case "begin": return environment(rawGroup())
            case "text", "mathrm", "textrm", "operatorname", "mbox": if case .raw(let s)? = cur { i += 1; return .text(s, bold: false) }; return .text(rawGroup(), bold: false)
            case "mathbf", "textbf", "boldsymbol", "bm": if case .raw(let s)? = cur { i += 1; return .text(s, bold: true) }; return .text(rawGroup(), bold: true)
            case "mathbb": var g = ""; if case .raw(let s)? = cur { i += 1; g = s } else { g = rawGroup() }; return .text(g.map { TeX.blackboard[String($0)] ?? String($0) }.joined(), bold: false)
            case "hat", "widehat", "bar", "overline", "vec", "dot", "ddot", "tilde", "widetilde", "underline": return .accent(n, group())
            case ",": return .space(0.17); case ":", ">": return .space(0.22); case ";": return .space(0.28); case "!": return .space(-0.17); case " ": return .space(0.28)
            case "quad": return .space(1); case "qquad": return .space(2)
            case "mathit", "mathcal", "mathscr", "mathsf", "mathtt", "displaystyle", "textstyle", "limits", "nolimits", "big", "Big", "bigg": return n.hasPrefix("math") ? group() : nil
            case "end": _ = rawGroup(); return nil
            default: return .text(n, bold: false)
            }
        }
        mutating func environment(_ env: String) -> TNode {
            var rows: [[TNode]] = [], cur: [TNode] = []
            func closeRow() { rows.append(cur); cur = [] }
            var cell: [TNode] = []
            func closeCell(_ s: inout Parser) { cur.append(cell.count == 1 ? cell[0] : .row(cell)); cell = [] }
            while let x = self.cur {
                if x == .cmd("end") { i += 1; _ = rawGroup(); break }
                if x == .amp { i += 1; closeCell(&self); continue }
                if x == .nl { i += 1; closeCell(&self); closeRow(); continue }
                if let a = atom() { cell.append(withScripts(a)) } else { i += 1 }
            }
            if !cell.isEmpty || !cur.isEmpty { closeCell(&self); closeRow() }
            let kinds: [String: (String, String, String)] = ["pmatrix": ("(", ")", "c"), "bmatrix": ("[", "]", "c"), "Bmatrix": ("{", "}", "c"), "vmatrix": ("|", "|", "c"), "Vmatrix": ("‖", "‖", "c"), "matrix": (".", ".", "c"), "cases": ("{", ".", "l"), "aligned": (".", ".", "a"), "align": (".", ".", "a"), "array": (".", ".", "c"), "gathered": (".", ".", "c")]
            let k = kinds[env] ?? (".", ".", "c")
            return .matrix(rows, left: k.0, right: k.1, align: k.2)
        }
    }

    static func parse(_ s: String) -> TNode {
        var p = Parser(s)
        var lines: [TNode] = []
        while p.i < p.t.count {
            lines.append(p.row { $0 == .nl })
            if p.cur == .nl { p.i += 1 }
        }
        return lines.count <= 1 ? (lines.first ?? .row([])) : .lines(lines)
    }

    // MARK: layout
    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        if let f = NSFont(name: bold ? "STIXTwoMath-Regular" : "STIXTwoMath-Regular", size: size) { return bold ? (NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)) : f }
        return NSFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
    }
    static func italic(_ c: Character) -> String {
        guard let a = c.asciiValue else { return String(c) }
        if a >= 97 && a <= 122 { if c == "h" { return "ℎ" }; return String(UnicodeScalar(0x1D44E + UInt32(a - 97))!) }
        if a >= 65 && a <= 90 { return String(UnicodeScalar(0x1D434 + UInt32(a - 65))!) }
        return String(c)
    }

    static func glyphs(_ s: String, _ size: CGFloat, color: NSColor, bold: Bool = false) -> MBox {
        let f = font(size, bold: bold), attr = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let asc = max(b.maxY, size * 0.1), desc = max(-b.minY, 0)
        return MBox(w: w, asc: asc, desc: desc) { p in
            NSGraphicsContext.current?.cgContext.textPosition = .zero
            attr.draw(at: CGPoint(x: p.x, y: p.y + f.descender))
        }
    }

    static func build(_ n: TNode, _ size: CGFloat, _ color: NSColor) -> MBox {
        func g(_ s: String, _ bold: Bool = false) -> MBox { glyphs(s, size, color: bold ? color : color, bold: bold) }
        switch n {
        case .letter(let c): return g(italic(c))
        case .sym(let s, _): return g(s)
        case .text(let s, let b): return g(s, b)
        case .space(let em): return MBox(w: em * size, asc: 0, desc: 0) { _ in }
        case .fn(let name): let b = g(name); let sp = size * 0.17; return MBox(w: b.w + sp, asc: b.asc, desc: b.desc) { b.draw($0) }
        case .row(let items): return hbox(items, size, color)
        case .lines(let ls):
            let rows = ls.map { build($0, size, color) }, gap = size * 0.35
            let w = rows.map(\.w).max() ?? 0, total = rows.map(\.h).reduce(0, +) + gap * CGFloat(max(rows.count - 1, 0))
            return MBox(w: w, asc: total, desc: 0) { p in
                var y = p.y + total - (rows.first?.asc ?? 0)
                for r in rows { r.draw(CGPoint(x: p.x + (w - r.w) / 2, y: y)); y -= r.h + gap }
            }
        case .frac(let a, let b, let bar):
            let s = size * 0.88, na = build(a, s, color), de = build(b, s, color), axis = size * 0.27, pad = size * 0.1, t = size * 0.055
            let w = max(na.w, de.w) + pad * 2
            let up = axis + t / 2 + size * 0.14 + na.desc, down = -axis + t / 2 + size * 0.14 + de.asc
            return MBox(w: w, asc: up + na.asc, desc: down + de.desc) { p in
                na.draw(CGPoint(x: p.x + (w - na.w) / 2, y: p.y + up)); de.draw(CGPoint(x: p.x + (w - de.w) / 2, y: p.y - down))
                if bar, let c = NSGraphicsContext.current?.cgContext { c.setFillColor(color.cgColor); c.fill(CGRect(x: p.x + pad / 2, y: p.y + axis - t / 2, width: w - pad, height: t)) }
            }
        case .sqrt(let body, let idx):
            let b = build(body, size, color), ix = idx.map { build($0, size * 0.55, color) }
            let gap = size * 0.18, t = size * 0.05, rw = size * 0.62, top = b.asc + gap + t, ih = ix.map { $0.h - size * 0.1 } ?? 0
            let lead = max((ix?.w ?? 0) - rw * 0.45, 0)
            return MBox(w: lead + rw + b.w + gap, asc: max(top, ih + size * 0.4), desc: b.desc) { p in
                guard let c = NSGraphicsContext.current?.cgContext else { return }
                let x0 = p.x + lead, bot = p.y - b.desc, tp = p.y + top
                c.setStrokeColor(color.cgColor); c.setLineWidth(t); c.setLineJoin(.miter)
                c.move(to: CGPoint(x: x0, y: p.y + size * 0.22)); c.addLine(to: CGPoint(x: x0 + rw * 0.22, y: p.y + size * 0.3)); c.addLine(to: CGPoint(x: x0 + rw * 0.55, y: bot)); c.addLine(to: CGPoint(x: x0 + rw, y: tp)); c.addLine(to: CGPoint(x: x0 + rw + b.w + gap, y: tp)); c.strokePath()
                b.draw(CGPoint(x: x0 + rw + gap / 2, y: p.y)); ix?.draw(CGPoint(x: p.x, y: p.y + size * 0.42))
            }
        case .scripts(let base, let sub, let sup):
            let bb = build(base, size, color), s = max(size * 0.7, 6)
            let su = sup.map { build($0, s, color) }, sb = sub.map { build($0, s, color) }
            let up = max(size * 0.4, bb.asc * 0.72), down = max(size * 0.2, bb.desc + size * 0.12)
            var supY: CGFloat? = su == nil ? nil : up, subY: CGFloat? = sb == nil ? nil : -down
            if let a = su, let b = sb { let overlap = (supY ?? 0) - a.desc - ((subY ?? 0) + b.asc); if overlap < size * 0.12 { let k = (size * 0.12 - overlap) / 2; supY = (supY ?? 0) + k; subY = (subY ?? 0) - k } }
            let w = bb.w + max(su?.w ?? 0, sb?.w ?? 0) + size * 0.04
            return MBox(w: w, asc: max(bb.asc, (supY ?? 0) + (su?.asc ?? 0)), desc: max(bb.desc, -(subY ?? 0) + (sb?.desc ?? 0))) { p in
                bb.draw(p); let x = p.x + bb.w + size * 0.03
                if let a = su { a.draw(CGPoint(x: x, y: p.y + (supY ?? 0))) }; if let b = sb { b.draw(CGPoint(x: x, y: p.y + (subY ?? 0))) }
            }
        case .bigop(let s, let limits): return g(s)      // bare operator; limits handled in hbox via scripts
        case .delim(let l, let body, let r):
            let b = build(body, size, color), axis = size * 0.25, half = max(b.asc - axis, b.desc + axis, size * 0.5) + size * 0.08
            let lw = delimWidth(l, size), rw = delimWidth(r, size)
            return MBox(w: lw + b.w + rw, asc: half + axis, desc: half - axis) { p in
                drawDelim(l, left: true, x: p.x, y: p.y + axis, half: half, w: lw, size: size, color: color)
                b.draw(CGPoint(x: p.x + lw, y: p.y)); drawDelim(r, left: false, x: p.x + lw + b.w, y: p.y + axis, half: half, w: rw, size: size, color: color)
            }
        case .matrix(let rows, let l, let r, let align):
            let cells = rows.map { $0.map { build($0, size, color) } }, nc = cells.map(\.count).max() ?? 0
            var colW = [CGFloat](repeating: 0, count: nc)
            for row in cells { for (j, c) in row.enumerated() { colW[j] = max(colW[j], c.w) } }
            let colGap = align == "a" ? 0 : size * 1.0, rowGap = size * 0.4
            let rh = cells.map { row in (row.map(\.asc).max() ?? 0, row.map(\.desc).max() ?? 0) }
            let total = rh.map { $0.0 + $0.1 }.reduce(0, +) + rowGap * CGFloat(max(cells.count - 1, 0)), axis = size * 0.25
            let w = colW.reduce(0, +) + colGap * CGFloat(max(nc - 1, 0)), lw = delimWidth(l, size) + (l == "." ? 0 : size * 0.1), rw = delimWidth(r, size) + (r == "." ? 0 : size * 0.1)
            let half = total / 2 + size * 0.06
            return MBox(w: lw + w + rw, asc: half + axis, desc: half - axis) { p in
                if l != "." { drawDelim(l, left: true, x: p.x, y: p.y + axis, half: half, w: delimWidth(l, size), size: size, color: color) }
                var y = p.y + axis + total / 2
                for (i, row) in cells.enumerated() {
                    y -= rh[i].0; var x = p.x + lw
                    for (j, c) in row.enumerated() {
                        let dx: CGFloat = align == "l" ? 0 : (align == "a" ? (j == 0 ? colW[j] - c.w : 0) : (colW[j] - c.w) / 2)
                        c.draw(CGPoint(x: x + dx, y: y)); x += colW[j] + colGap
                    }
                    y -= rh[i].1 + rowGap
                }
                if r != "." { drawDelim(r, left: false, x: p.x + lw + w + size * 0.1, y: p.y + axis, half: half, w: delimWidth(r, size), size: size, color: color) }
            }
        case .accent(let kind, let body):
            let b = build(body, size, color), gap = size * 0.08, lift = b.asc + gap
            return MBox(w: b.w, asc: lift + size * 0.18, desc: b.desc) { p in
                b.draw(p); guard let c = NSGraphicsContext.current?.cgContext else { return }
                let cx = p.x + b.w / 2, y = p.y + lift; c.setStrokeColor(color.cgColor); c.setFillColor(color.cgColor); c.setLineWidth(size * 0.05); c.setLineCap(.round)
                switch kind {
                case "bar", "overline": c.move(to: CGPoint(x: p.x, y: y)); c.addLine(to: CGPoint(x: p.x + b.w, y: y)); c.strokePath()
                case "underline": c.move(to: CGPoint(x: p.x, y: p.y - b.desc - gap)); c.addLine(to: CGPoint(x: p.x + b.w, y: p.y - b.desc - gap)); c.strokePath()
                case "vec": c.move(to: CGPoint(x: p.x + b.w * 0.1, y: y)); c.addLine(to: CGPoint(x: p.x + b.w * 0.95, y: y)); c.move(to: CGPoint(x: p.x + b.w * 0.95 - size * 0.12, y: y + size * 0.08)); c.addLine(to: CGPoint(x: p.x + b.w * 0.95, y: y)); c.addLine(to: CGPoint(x: p.x + b.w * 0.95 - size * 0.12, y: y - size * 0.08)); c.strokePath()
                case "dot": c.fillEllipse(in: CGRect(x: cx - size * 0.04, y: y, width: size * 0.08, height: size * 0.08))
                case "ddot": c.fillEllipse(in: CGRect(x: cx - size * 0.12, y: y, width: size * 0.08, height: size * 0.08)); c.fillEllipse(in: CGRect(x: cx + size * 0.04, y: y, width: size * 0.08, height: size * 0.08))
                case "tilde", "widetilde": c.move(to: CGPoint(x: cx - b.w * 0.3, y: y)); c.addCurve(to: CGPoint(x: cx + b.w * 0.3, y: y + size * 0.08), control1: CGPoint(x: cx - b.w * 0.1, y: y + size * 0.14), control2: CGPoint(x: cx + b.w * 0.1, y: y - size * 0.04)); c.strokePath()
                default: c.move(to: CGPoint(x: cx - b.w * 0.3, y: y)); c.addLine(to: CGPoint(x: cx, y: y + size * 0.12)); c.addLine(to: CGPoint(x: cx + b.w * 0.3, y: y)); c.strokePath()
                }
            }
        }
    }

    static func delimWidth(_ d: String, _ size: CGFloat) -> CGFloat { d == "." ? 0 : (d == "|" ? size * 0.22 : d == "‖" ? size * 0.3 : size * 0.38) }
    static func drawDelim(_ d: String, left: Bool, x: CGFloat, y: CGFloat, half: CGFloat, w: CGFloat, size: CGFloat, color: NSColor) {
        guard d != ".", let c = NSGraphicsContext.current?.cgContext else { return }
        c.setStrokeColor(color.cgColor); c.setLineWidth(max(size * 0.06, 1)); c.setLineCap(.round); c.setLineJoin(.round)
        let top = y + half, bot = y - half, inner = left ? x + w - size * 0.06 : x + size * 0.06, outer = left ? x + size * 0.1 : x + w - size * 0.1
        switch d {
        case "(", ")": c.move(to: CGPoint(x: inner, y: top)); c.addCurve(to: CGPoint(x: inner, y: bot), control1: CGPoint(x: outer, y: top - half * 0.35), control2: CGPoint(x: outer, y: bot + half * 0.35))
        case "[", "]", "⌊", "⌋", "⌈", "⌉":
            let cap = size * 0.14, dir: CGFloat = left ? 1 : -1; let flatTop = d != "⌊" && d != "⌋", flatBot = d != "⌈" && d != "⌉"
            c.move(to: CGPoint(x: inner, y: flatTop ? top : top)); c.addLine(to: CGPoint(x: outer, y: top)); c.move(to: CGPoint(x: outer, y: flatTop ? top : top)); c.addLine(to: CGPoint(x: outer, y: bot)); c.addLine(to: CGPoint(x: inner, y: bot))
            _ = cap; _ = dir; _ = flatBot
        case "{", "}":
            let mid = (inner + outer) / 2, tip = left ? outer - size * 0.04 : outer + size * 0.04
            c.move(to: CGPoint(x: inner, y: top)); c.addCurve(to: CGPoint(x: mid, y: top - size * 0.3), control1: CGPoint(x: mid, y: top), control2: CGPoint(x: mid, y: top - size * 0.1))
            c.addLine(to: CGPoint(x: mid, y: y + size * 0.15)); c.addCurve(to: CGPoint(x: tip, y: y), control1: CGPoint(x: mid, y: y + size * 0.06), control2: CGPoint(x: (mid + tip) / 2, y: y))
            c.addCurve(to: CGPoint(x: mid, y: y - size * 0.15), control1: CGPoint(x: (mid + tip) / 2, y: y), control2: CGPoint(x: mid, y: y - size * 0.06))
            c.addLine(to: CGPoint(x: mid, y: bot + size * 0.3)); c.addCurve(to: CGPoint(x: inner, y: bot), control1: CGPoint(x: mid, y: bot + size * 0.1), control2: CGPoint(x: mid, y: bot))
        case "|": let m = x + w / 2; c.move(to: CGPoint(x: m, y: top)); c.addLine(to: CGPoint(x: m, y: bot))
        case "‖": let m = x + w / 2; c.move(to: CGPoint(x: m - size * 0.05, y: top)); c.addLine(to: CGPoint(x: m - size * 0.05, y: bot)); c.move(to: CGPoint(x: m + size * 0.05, y: top)); c.addLine(to: CGPoint(x: m + size * 0.05, y: bot))
        case "⟨", "⟩": c.move(to: CGPoint(x: left ? outer : inner, y: top)); c.addLine(to: CGPoint(x: left ? inner : outer, y: y)); c.addLine(to: CGPoint(x: left ? outer : inner, y: bot))
        default: break
        }
        c.strokePath()
    }

    /// Lays out a row, adding operator spacing and attaching limits to big operators.
    static func hbox(_ items: [TNode], _ size: CGFloat, _ color: NSColor) -> MBox {
        var parts: [(MBox, CGFloat)] = []            // box + space before it
        var prevKind: TNode.Kind?
        func kind(_ n: TNode) -> TNode.Kind? { if case .sym(_, let k) = n { return k }; return nil }
        for n in items {
            var lead: CGFloat = 0, k = kind(n)
            if case .scripts(let base, _, _) = n { k = kind(base) }
            if k == .rel { lead = size * 0.28 } else if k == .bin, let p = prevKind, p != .bin, p != .rel, p != .open, p != .punct { lead = size * 0.22 }
            if let p = prevKind, p == .rel { lead = max(lead, size * 0.28) } else if let p = prevKind, p == .bin { lead = max(lead, size * 0.22) } else if prevKind == .punct { lead = max(lead, size * 0.17) }
            // big operator with limits (display style)
            if case .scripts(let base, let sub, let sup) = n, case .bigop(let s, let limits) = base {
                parts.append((bigOp(s, limits, sub, sup, size, color), lead + size * 0.1))
            } else if case .scripts(let base, let sub, let sup) = n, case .fn(let name) = base, limitFns.contains(name), sup == nil, let sb = sub {
                parts.append((limitFn(name, sb, size, color), lead + size * 0.1))
            } else if case .bigop(let s, let limits) = n { parts.append((bigOp(s, limits, nil, nil, size, color), lead + size * 0.1)) }
            else { parts.append((build(n, size, color), lead)) }
            prevKind = k ?? .ord
        }
        let w = parts.reduce(0) { $0 + $1.1 + $1.0.w }, asc = parts.map { $0.0.asc }.max() ?? 0, desc = parts.map { $0.0.desc }.max() ?? 0
        return MBox(w: w, asc: asc, desc: desc) { p in var x = p.x; for (b, lead) in parts { x += lead; b.draw(CGPoint(x: x, y: p.y)); x += b.w } }
    }
    static func bigOp(_ s: String, _ limits: Bool, _ sub: TNode?, _ sup: TNode?, _ size: CGFloat, _ color: NSColor) -> MBox {
        let isInt = s.hasPrefix("∫") || s.hasPrefix("∬") || s.hasPrefix("∭") || s.hasPrefix("∮")
        let op = glyphs(s, size * (isInt ? 1.5 : 1.35), color: color), ss = max(size * 0.7, 6)
        let lo = sub.map { build($0, ss, color) }, hi = sup.map { build($0, ss, color) }
        let axis = size * 0.25, opMid = (op.asc - op.desc) / 2, shift = axis - opMid
        if limits {
            let w = max(op.w, lo?.w ?? 0, hi?.w ?? 0), gap = size * 0.1
            let up = op.asc + shift + gap + (hi?.desc ?? 0), down = op.desc - shift + gap + (lo?.asc ?? 0)
            return MBox(w: w, asc: up + (hi?.asc ?? 0), desc: down + (lo?.desc ?? 0)) { p in
                op.draw(CGPoint(x: p.x + (w - op.w) / 2, y: p.y + shift))
                if let h = hi { h.draw(CGPoint(x: p.x + (w - h.w) / 2, y: p.y + up)) }; if let l = lo { l.draw(CGPoint(x: p.x + (w - l.w) / 2, y: p.y - down)) }
            }
        }
        let w = op.w + max(lo?.w ?? 0, hi?.w ?? 0) * 0.9 + size * 0.05
        return MBox(w: w, asc: max(op.asc + shift, (hi?.asc ?? 0) + op.asc * 0.6), desc: max(op.desc - shift, (lo?.desc ?? 0) + op.desc * 0.7)) { p in
            op.draw(CGPoint(x: p.x, y: p.y + shift)); let x = p.x + op.w * (isInt ? 0.78 : 1)
            if let h = hi { h.draw(CGPoint(x: x + (isInt ? size * 0.32 : 0), y: p.y + op.asc * 0.72)) }; if let l = lo { l.draw(CGPoint(x: x - (isInt ? size * 0.2 : 0), y: p.y - op.desc * 0.78 - l.asc * 0.2)) }
        }
    }
    static func limitFn(_ name: String, _ sub: TNode, _ size: CGFloat, _ color: NSColor) -> MBox {
        let f = glyphs(name, size, color: color), lo = build(sub, max(size * 0.7, 6), color), w = max(f.w, lo.w), gap = size * 0.1
        return MBox(w: w + size * 0.12, asc: f.asc, desc: f.desc + gap + lo.h) { p in f.draw(CGPoint(x: p.x + (w - f.w) / 2, y: p.y)); lo.draw(CGPoint(x: p.x + (w - lo.w) / 2, y: p.y - f.desc - gap - lo.asc)) }
    }

    // MARK: output
    static func layout(_ tex: String, size: CGFloat, color: NSColor = .black) -> MBox { build(parse(tex), size, color) }
    /// A tightly cropped image of the equation (re-render when the colour scheme changes).
    static func image(_ tex: String, size: CGFloat, color: NSColor, pad: CGFloat = 4) -> NSImage? {
        let b = layout(tex, size: size, color: color)
        guard b.w > 0, b.h > 0 else { return nil }
        let img = NSImage(size: NSSize(width: ceil(b.w + pad * 2), height: ceil(b.h + pad * 2)), flipped: false) { _ in b.draw(CGPoint(x: pad, y: pad + b.desc)); return true }
        return img
    }
    static func pngData(_ tex: String, size: CGFloat, color: NSColor = .black, scale: CGFloat = 3) -> Data? {
        let b = layout(tex, size: size * scale, color: color), pad = 6 * scale
        guard b.w > 0 else { return nil }
        let w = Int(ceil(b.w + pad * 2)), h = Int(ceil(b.h + pad * 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        b.draw(CGPoint(x: pad, y: pad + b.desc)); NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
