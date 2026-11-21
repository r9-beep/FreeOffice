import SwiftUI
import AppKit

// Math: a notebook. Calculation lines with live answers, typeset equations, graphs and notes — in any order.

struct MCell: Codable, Identifiable, Equatable {
    var id: Int
    var kind = "calc"                         // calc · tex · graph · note
    var text = ""                             // calc lines, LaTeX source or note text
    var fns: [String] = []                    // graph: one function of x per entry
    var gx0 = -10.0, gx1 = 10.0, gy0 = -6.0, gy1 = 6.0
    var gauto = true
    var size = 28.0                           // equation size
    init(id: Int, kind: String = "calc", text: String = "") { self.id = id; self.kind = kind; self.text = text; if kind == "graph" { fns = ["x^2 / 4", "sin(x)"] } }
    enum CodingKeys: String, CodingKey { case id, kind, text, fns, gx0, gx1, gy0, gy1, gauto, size }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = try c.decode(Int.self, forKey: .id); kind = v(.kind, "calc"); text = v(.text, ""); fns = v(.fns, []); gx0 = v(.gx0, -10); gx1 = v(.gx1, 10); gy0 = v(.gy0, -6); gy1 = v(.gy1, 6); gauto = v(.gauto, true); size = v(.size, 28)
    }
}
struct MathState: Equatable { var cells: [MCell]; var degrees: Bool }

let graphColors: [Color] = [Color(red: 0.18, green: 0.43, blue: 0.96), Color(red: 0.9, green: 0.2, blue: 0.2), Color(red: 0.1, green: 0.65, blue: 0.35), Color(red: 0.95, green: 0.55, blue: 0.05), Color(red: 0.55, green: 0.3, blue: 0.9), Color(red: 0.05, green: 0.6, blue: 0.7)]

final class MathModel: ObservableObject {
    let history = UndoHistory<MathState>()
    @Published var cells: [MCell] { didSet { if ready { history.record(MathState(cells: oldValue, degrees: degrees)); saver.touch(); scheduleEval() } } }
    @Published var degrees: Bool { didSet { if ready { history.record(MathState(cells: cells, degrees: oldValue)); saver.touch(); scheduleEval() } } }
    @Published var title: String { didSet { if ready { saver.touch() } } }
    @Published var results: [Int: [MResult]] = [:]
    @Published var scope: [(name: String, text: String)] = []
    @Published var showScope = true
    @Published var savedAt: Date?
    @Published var status: String?
    let saver: AutoSaver
    private var ready = false
    private var work: DispatchWorkItem?
    private(set) var env = MathEnv()
    private(set) var compiled: [Int: [((Double) -> Double)?]] = [:]

    init(id: String, dir: URL) {
        saver = AutoSaver(url: docURL(dir, "math", id))
        struct In: Decodable { var title: String?; var cells: [MCell]?; var degrees: Bool? }
        var c: [MCell] = [], t = "", d = false
        if let data = try? Data(contentsOf: saver.url), let o = try? JSONDecoder().decode(In.self, from: data) { c = o.cells ?? []; t = o.title ?? ""; d = o.degrees ?? false }
        else { c = [MCell(id: 1, kind: "calc", text: "// Each line is a calculation\n2 + 3 * 4\nr = 5\npi * r^2\nf(x) = x^2 - 2\nsolve(f(x), 1)")] }
        cells = c; title = t; degrees = d
        ready = true
        saver.make = { [weak self] in
            guard let m = self else { return nil }
            struct Out: Encodable { var title: String; var cells: [MCell]; var degrees: Bool; var modified: Double }
            return try? JSONEncoder().encode(Out(title: m.title, cells: m.cells, degrees: m.degrees, modified: nowMillis()))
        }
        saver.onSaved = { [weak self] in self?.savedAt = Date() }
        evaluate()
    }

    // MARK: evaluation (top to bottom, one shared scope)
    func scheduleEval() { work?.cancel(); let w = DispatchWorkItem { [weak self] in self?.evaluate() }; work = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w) }
    func evaluate() {
        let e = MathEnv(); e.degrees = degrees
        var out: [Int: [MResult]] = [:]
        for c in cells where c.kind == "calc" { out[c.id] = e.runBlock(c.text) }
        env = e; results = out
        compiled = Dictionary(uniqueKeysWithValues: cells.filter { $0.kind == "graph" }.map { ($0.id, $0.fns.map { e.compile($0) }) })
        var s: [(String, String)] = []
        for (k, v) in e.vars.sorted(by: { $0.key < $1.key }) where !["pi", "e", "tau", "phi", "ans"].contains(k) { s.append((k, MathFormat.string(v))) }
        for (k, f) in e.funcs.sorted(by: { $0.key < $1.key }) { s.append((k + "(" + f.params.joined(separator: ", ") + ")", f.text.trimmingCharacters(in: .whitespaces))) }
        scope = s
        objectWillChange.send()
    }

    func undo() { if let s = history.undo(current: MathState(cells: cells, degrees: degrees)) { apply(s) } }
    func redo() { if let s = history.redo(current: MathState(cells: cells, degrees: degrees)) { apply(s) } }
    private func apply(_ s: MathState) { history.applying = true; cells = s.cells; degrees = s.degrees; history.applying = false; saver.touch(); evaluate() }

    // MARK: cells
    var nextId: Int { (cells.map(\.id).max() ?? 0) + 1 }
    @discardableResult func add(_ kind: String, after id: Int? = nil) -> Int {
        var c = MCell(id: nextId, kind: kind)
        if kind == "tex" { c.text = "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}" }
        if let id = id, let i = cells.firstIndex(where: { $0.id == id }) { cells.insert(c, at: i + 1) } else { cells.append(c) }
        return c.id
    }
    func delete(_ id: Int) { cells.removeAll { $0.id == id } }
    func move(_ id: Int, _ d: Int) { guard let i = cells.firstIndex(where: { $0.id == id }), cells.indices.contains(i + d) else { return }; cells.swapAt(i, i + d) }
    func duplicate(_ id: Int) { guard let i = cells.firstIndex(where: { $0.id == id }) else { return }; var c = cells[i]; c.id = nextId; cells.insert(c, at: i + 1) }
    func update(_ id: Int, _ f: (inout MCell) -> Void) { if let i = cells.firstIndex(where: { $0.id == id }) { var c = cells[i]; f(&c); if c != cells[i] { cells[i] = c } } }
    func lines(_ c: MCell) -> [String] { let l = c.text.components(separatedBy: "\n"); return l.isEmpty ? [""] : l }
    func setLine(_ id: Int, _ i: Int, _ t: String) { update(id) { c in var l = c.text.components(separatedBy: "\n"); while l.count <= i { l.append("") }; l[i] = t.replacingOccurrences(of: "\n", with: " "); c.text = l.joined(separator: "\n") } }
    func insertLine(_ id: Int, after i: Int) { update(id) { c in var l = c.text.components(separatedBy: "\n"); l.insert("", at: min(i + 1, l.count)); c.text = l.joined(separator: "\n") } }
    func removeLine(_ id: Int, _ i: Int) { update(id) { c in var l = c.text.components(separatedBy: "\n"); if l.count > 1, l.indices.contains(i) { l.remove(at: i) }; c.text = l.joined(separator: "\n") } }

    // MARK: graph helpers
    func autoRange(_ c: MCell) -> (Double, Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for f in compiled[c.id] ?? [] { guard let f = f else { continue }
            for i in 0...200 { let y = f(c.gx0 + (c.gx1 - c.gx0) * Double(i) / 200); if y.isFinite && abs(y) < 1e6 { lo = min(lo, y); hi = max(hi, y) } } }
        if !lo.isFinite || !hi.isFinite { return (-6, 6) }
        if hi - lo < 1e-9 { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.12; return (lo - pad, hi + pad)
    }

    // MARK: export
    func exportText() {
        guard let u = savePanel((title.isEmpty ? "notebook" : title) + ".md") else { return }
        var out = "# \(title.isEmpty ? "Math notebook" : title)\n\n"
        for c in cells {
            switch c.kind {
            case "calc": out += "```\n" + zip(lines(c), results[c.id] ?? []).map { $0.1 == .empty ? $0.0 : ($0.1.isError ? "\($0.0)    ⚠ \($0.1.text)" : "\($0.0)    →  \($0.1.text)") }.joined(separator: "\n") + "\n```\n\n"
            case "tex": out += "$$\n\(c.text)\n$$\n\n"
            case "graph": out += "Graph of " + c.fns.joined(separator: ", ") + "\n\n"
            default: out += DocLinks.plain(c.text) + "\n\n"
            }
        }
        try? out.write(to: u, atomically: true, encoding: .utf8); status = "Exported \(u.lastPathComponent)"
    }
}

// MARK: - Graph

struct GraphView: View {
    @ObservedObject var m: MathModel
    let cell: MCell
    @State private var hover: CGPoint?
    @State private var panStart: MCell?
    @State private var zoomStart: MCell?
    @State private var monitor = DiagramScrollMonitor()

    func range(_ c: MCell) -> (y0: Double, y1: Double) { c.gauto ? m.autoRange(c) : (c.gy0, c.gy1) }
    func niceStep(_ span: Double) -> Double { let raw = span / 6, p = pow(10, floor(log10(raw))), f = raw / p; return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p }

    var body: some View {
        let r = range(cell)
        return GeometryReader { geo in AnyView(graph(geo.size, cell, r.y0, r.y1)) }
    }
    func graph(_ size: CGSize, _ c: MCell, _ y0: Double, _ y1: Double) -> some View {
        let W = size.width, H = size.height
        let sx = W / (c.gx1 - c.gx0), sy = H / (y1 - y0)
        func px(_ x: Double) -> CGFloat { CGFloat((x - c.gx0) * sx) }
        func py(_ y: Double) -> CGFloat { CGFloat(H) - CGFloat((y - y0) * sy) }
        return Canvas { ctx, size in
            let stepX = niceStep(c.gx1 - c.gx0), stepY = niceStep(y1 - y0)
            var grid = Path(), ticks: [(CGPoint, String, Bool)] = []
            var x = ceil(c.gx0 / stepX) * stepX
            while x <= c.gx1 { grid.move(to: CGPoint(x: px(x), y: 0)); grid.addLine(to: CGPoint(x: px(x), y: size.height)); if abs(x) > stepX / 2 { ticks.append((CGPoint(x: px(x), y: min(max(py(0), 12), size.height - 12) + 11), MathFormat.string((x * 1e9).rounded() / 1e9), true)) }; x += stepX }
            var y = ceil(y0 / stepY) * stepY
            while y <= y1 { grid.move(to: CGPoint(x: 0, y: py(y))); grid.addLine(to: CGPoint(x: size.width, y: py(y))); if abs(y) > stepY / 2 { ticks.append((CGPoint(x: min(max(px(0), 24), size.width - 8) - 4, y: py(y) - 8), MathFormat.string((y * 1e9).rounded() / 1e9), false)) }; y += stepY }
            ctx.stroke(grid, with: .color(.gray.opacity(0.18)), lineWidth: 0.7)
            var axes = Path()
            if c.gx0 < 0 && c.gx1 > 0 { axes.move(to: CGPoint(x: px(0), y: 0)); axes.addLine(to: CGPoint(x: px(0), y: size.height)) }
            if y0 < 0 && y1 > 0 { axes.move(to: CGPoint(x: 0, y: py(0))); axes.addLine(to: CGPoint(x: size.width, y: py(0))) }
            ctx.stroke(axes, with: .color(.gray.opacity(0.7)), lineWidth: 1.2)
            for t in ticks { ctx.draw(Text(t.1).font(.system(size: 10)).foregroundStyle(.secondary), at: t.0, anchor: t.2 ? .center : .trailing) }
            for (i, f) in (m.compiled[c.id] ?? []).enumerated() {
                guard let f = f else { continue }
                var p = Path(), pen = false, last = CGFloat.nan
                let n = Int(size.width / 1.5)
                for k in 0...n {
                    let xv = c.gx0 + (c.gx1 - c.gx0) * Double(k) / Double(n), yv = f(xv)
                    guard yv.isFinite, abs(yv) < 1e9 else { pen = false; continue }
                    let pt = CGPoint(x: px(xv), y: py(yv))
                    if pen, abs(pt.y - last) < size.height * 1.5 { p.addLine(to: pt) } else { p.move(to: pt) }
                    pen = true; last = pt.y
                }
                ctx.stroke(p, with: .color(graphColors[i % graphColors.count]), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            if let h = hover {
                let xv = c.gx0 + Double(h.x) / sx
                var v = Path(); v.move(to: CGPoint(x: h.x, y: 0)); v.addLine(to: CGPoint(x: h.x, y: size.height)); ctx.stroke(v, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                var line = 0
                ctx.draw(Text("x = \(MathFormat.string((xv * 1e4).rounded() / 1e4))").font(.system(size: 11, weight: .semibold)), at: CGPoint(x: min(max(h.x + 8, 8), size.width - 90), y: 10 + CGFloat(line) * 15), anchor: .topLeading); line += 1
                for (i, f) in (m.compiled[c.id] ?? []).enumerated() { if let f = f { let yv = f(xv); if yv.isFinite {
                    ctx.fill(Path(ellipseIn: CGRect(x: h.x - 4, y: py(yv) - 4, width: 8, height: 8)), with: .color(graphColors[i % graphColors.count]))
                    ctx.draw(Text("\(MathFormat.string((yv * 1e4).rounded() / 1e4))").font(.system(size: 11)).foregroundStyle(graphColors[i % graphColors.count]), at: CGPoint(x: min(max(h.x + 8, 8), size.width - 90), y: 10 + CGFloat(line) * 15), anchor: .topLeading); line += 1 } } }
            }
        }
        .background(Color.white).clipShape(.rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .onContinuousHover { phase in switch phase { case .active(let p): hover = p; installMonitor(W: W); case .ended: hover = nil; monitor.stop() } }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            if panStart == nil { var s = c; if s.gauto { let r = range(c); s.gy0 = r.y0; s.gy1 = r.y1 }; panStart = s }
            guard let s = panStart else { return }
            let dx = -Double(v.translation.width) / sx, dy = Double(v.translation.height) / sy
            m.update(c.id) { $0.gx0 = s.gx0 + dx; $0.gx1 = s.gx1 + dx; $0.gy0 = s.gy0 + dy; $0.gy1 = s.gy1 + dy; $0.gauto = false }
        }.onEnded { _ in panStart = nil })
        .gesture(MagnifyGesture().onChanged { v in
            if zoomStart == nil { var s = c; if s.gauto { let r = range(c); s.gy0 = r.y0; s.gy1 = r.y1 }; zoomStart = s }
            if let s = zoomStart { zoom(s, by: 1 / v.magnification) }
        }.onEnded { _ in zoomStart = nil })
    }
    func zoom(_ s: MCell, by k: Double) {
        let cx = (s.gx0 + s.gx1) / 2, cy = (s.gy0 + s.gy1) / 2, hx = (s.gx1 - s.gx0) / 2 * k, hy = (s.gy1 - s.gy0) / 2 * k
        m.update(s.id) { $0.gx0 = cx - hx; $0.gx1 = cx + hx; $0.gy0 = cy - hy; $0.gy1 = cy + hy; $0.gauto = false }
    }
    func installMonitor(W: CGFloat) {
        monitor.start { e in
            guard e.modifierFlags.contains(.command), let c = m.cells.first(where: { $0.id == cell.id }) else { return false }
            var s = c; if s.gauto { let r = range(c); s.gy0 = r.y0; s.gy1 = r.y1 }
            zoom(s, by: exp(-Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.01 : 0.05))); return true
        }
    }
}

// MARK: - Notebook UI

struct MathEditorView: View {
    @StateObject private var m: MathModel
    @FocusState private var focus: LineFocus?
    @Environment(\.colorScheme) private var scheme
    struct LineFocus: Hashable { let cell: Int; let line: Int }
    let docTab: Tab
    static let symbols: [(String, String)] = [("a/b", "\\frac{a}{b}"), ("√", "\\sqrt{x}"), ("xⁿ", "x^{n}"), ("xₙ", "x_{n}"), ("Σ", "\\sum_{k=1}^{n} k"), ("∫", "\\int_{a}^{b} f(x)\\,dx"), ("lim", "\\lim_{x \\to 0} f(x)"), ("( )", "\\left( x \\right)"),
                                                  ("[ ]ᵐ", "\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}"), ("{ cases", "\\begin{cases} x & x \\geq 0 \\\\ -x & x < 0 \\end{cases}"), ("α β γ", "\\alpha \\beta \\gamma"), ("θ φ ω", "\\theta \\varphi \\omega"), ("π", "\\pi"), ("∞", "\\infty"), ("≤ ≥ ≠", "\\leq \\geq \\neq"), ("± × ÷", "\\pm \\times \\div"), ("→ ⇒", "\\to \\Rightarrow"), ("∈ ℝ", "\\in \\mathbb{R}"), ("∂ ∇", "\\partial \\nabla"), ("vec", "\\vec{v}"), ("x̂", "\\hat{x}"), ("x̄", "\\bar{x}")]

    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? MathModel) ?? { let x = MathModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        HStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(m.cells) { c in cellView(c) }
                    addBar
                }.padding(16).frame(maxWidth: 860).frame(maxWidth: .infinity)
            }
            if m.showScope { scope.frame(width: 250).padding(.trailing, 10).padding(.vertical, 10) }
        }
        .background { Backdrop().opacity(0.6) }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled notebook", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("", selection: $m.degrees) { Text("Rad").tag(false); Text("Deg").tag(true) }.pickerStyle(.segmented).frame(width: 90).help("Angle units for sin, cos, tan…")
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                Button { m.showScope.toggle() } label: { Label("Scope", systemImage: "sidebar.right") }
                Menu { Button("Export as Markdown…") { m.exportText() } } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled notebook" : t }
        .onChange(of: m.status) { _, s in if s != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { m.status = nil } } }
        .onAppear { docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() } }
        .onDisappear { m.saver.flush() }
    }

    // MARK: cell chrome
    func header(_ c: MCell, _ label: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary); Text(label).font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Move up") { m.move(c.id, -1) }; Button("Move down") { m.move(c.id, 1) }; Button("Duplicate") { m.duplicate(c.id) }
                Divider(); Menu("Add below") { Button("Calculation") { m.add("calc", after: c.id) }; Button("Equation") { m.add("tex", after: c.id) }; Button("Graph") { m.add("graph", after: c.id) }; Button("Note") { m.add("note", after: c.id) } }
                Divider(); Button("Delete cell", role: .destructive) { m.delete(c.id) }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }
    }
    @ViewBuilder func cellView(_ c: MCell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch c.kind {
            case "tex": header(c, "Equation", "function"); texBody(c)
            case "graph": header(c, "Graph", "chart.xyaxis.line"); graphBody(c)
            case "note": header(c, "Note", "text.alignleft"); noteBody(c)
            default: header(c, "Calculation", "equal.square"); calcBody(c)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: calculation
    func calcBody(_ c: MCell) -> some View {
        let lines = m.lines(c), res = m.results[c.id] ?? []
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let r = i < res.count ? res[i] : MResult.empty
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TextField(i == 0 ? "Type a calculation, e.g. 2(3+4)" : "", text: Binding(get: { i < m.lines(c).count ? m.lines(c)[i] : "" }, set: { m.setLine(c.id, i, $0) }))
                        .textFieldStyle(.plain).font(.system(size: 16, design: .monospaced)).focused($focus, equals: LineFocus(cell: c.id, line: i))
                        .onSubmit { m.insertLine(c.id, after: i); focus = LineFocus(cell: c.id, line: i + 1) }
                        .onKeyPress(.delete) { if line.isEmpty, lines.count > 1 { m.removeLine(c.id, i); focus = LineFocus(cell: c.id, line: max(i - 1, 0)); return .handled }; return .ignored }
                        .onKeyPress(.upArrow) { if i > 0 { focus = LineFocus(cell: c.id, line: i - 1); return .handled }; return .ignored }
                        .onKeyPress(.downArrow) { if i < lines.count - 1 { focus = LineFocus(cell: c.id, line: i + 1); return .handled }; return .ignored }
                    Spacer(minLength: 8)
                    resultView(r)
                }.padding(.vertical, 3)
            }
        }
    }
    @ViewBuilder func resultView(_ r: MResult) -> some View {
        switch r {
        case .empty: EmptyView()
        case .value(let d): Button { copy(MathFormat.string(d)) } label: { Text("= " + MathFormat.string(d)).font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentColor) }.buttonStyle(.plain).help("Click to copy")
        case .defined(_, let d): Button { copy(MathFormat.string(d)) } label: { Text("= " + MathFormat.string(d)).font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Click to copy")
        case .function(let s): Text(s).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        case .error(let e): Label(e, systemImage: "exclamationmark.triangle.fill").font(.fo(.caption)).foregroundStyle(.red).lineLimit(1)
        }
    }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.replacingOccurrences(of: "−", with: "-"), forType: .string); m.status = "Copied \(s)" }

    // MARK: equation
    func texBody(_ c: MCell) -> some View {
        let img = TeX.image(c.text, size: CGFloat(c.size), color: scheme == .dark ? .white : .black)
        return VStack(alignment: .leading, spacing: 8) {
            Group { if let i = img { Image(nsImage: i).frame(maxWidth: .infinity, minHeight: 50) } else { Text("Write LaTeX below and it appears here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 50) } }
                .padding(10).background(.thinMaterial, in: .rect(cornerRadius: 14))
            TextEditor(text: Binding(get: { m.cells.first { $0.id == c.id }?.text ?? "" }, set: { v in m.update(c.id) { $0.text = v } }))
                .font(.system(size: 14, design: .monospaced)).scrollContentBackground(.hidden).frame(height: 66).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 10))
            HStack(spacing: 10) {
                Menu {
                    ForEach(Self.symbols, id: \.0) { s in Button(s.0) { m.update(c.id) { $0.text += ($0.text.isEmpty || $0.text.hasSuffix(" ") ? "" : " ") + s.1 } } }
                } label: { Label("Insert", systemImage: "plus.square") }.menuStyle(.borderlessButton).fixedSize()
                Stepper("Size \(Int(c.size))", value: Binding(get: { c.size }, set: { v in m.update(c.id) { $0.size = v } }), in: 14...72, step: 2).fixedSize()
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.text, forType: .string); m.status = "Copied LaTeX" } label: { Label("LaTeX", systemImage: "doc.on.doc") }
                Button { if let d = TeX.pngData(c.text, size: CGFloat(c.size), color: .black), let i = NSImage(data: d) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([i]); m.status = "Copied equation as an image" } } label: { Label("Image", systemImage: "photo") }
                Button { if let d = TeX.pngData(c.text, size: CGFloat(c.size), color: .black), let u = savePanel("equation.png") { try? d.write(to: u); m.status = "Saved \(u.lastPathComponent)" } } label: { Label("PNG…", systemImage: "square.and.arrow.down") }
            }.buttonStyle(.plain).font(.fo(.callout))
        }
    }

    // MARK: graph
    func graphBody(_ c: MCell) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(c.fns.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 8) {
                    Circle().fill(graphColors[i % graphColors.count]).frame(width: 12, height: 12)
                    Text("y =").font(.system(size: 15, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("function of x", text: Binding(get: { i < (m.cells.first { $0.id == c.id }?.fns.count ?? 0) ? m.cells.first { $0.id == c.id }!.fns[i] : "" }, set: { v in m.update(c.id) { if i < $0.fns.count { $0.fns[i] = v } } }))
                        .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced))
                    if (m.compiled[c.id] ?? []).indices.contains(i), m.compiled[c.id]![i] == nil, !f.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Couldn't read this function") }
                    Button { m.update(c.id) { if i < $0.fns.count { $0.fns.remove(at: i) } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            GraphView(m: m, cell: c).frame(height: 320)
            HStack(spacing: 10) {
                Button { m.update(c.id) { $0.fns.append("") } } label: { Label("Add function", systemImage: "plus") }
                Spacer()
                Button { m.update(c.id) { $0.gx0 = -10; $0.gx1 = 10; $0.gauto = true } } label: { Label("Reset view", systemImage: "arrow.counterclockwise") }
                Text("Drag to pan · ⌘-scroll or pinch to zoom · hover to trace").font(.fo(.caption)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).font(.fo(.callout))
        }
    }

    // MARK: note
    func noteBody(_ c: MCell) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { m.cells.first { $0.id == c.id }?.text ?? "" }, set: { v in m.update(c.id) { $0.text = v } }))
                .font(.fo(.body)).scrollContentBackground(.hidden).frame(minHeight: 60).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 10))
                .docMentions(Binding(get: { m.cells.first { $0.id == c.id }?.text ?? "" }, set: { v in m.update(c.id) { $0.text = v } }))
            MentionStrip(text: c.text)
        }
    }

    // MARK: bottom bar + scope
    var addBar: some View {
        HStack(spacing: 10) {
            Button { let id = m.add("calc"); focus = LineFocus(cell: id, line: 0) } label: { Label("Calculation", systemImage: "equal.square") }
            Button { m.add("tex") } label: { Label("Equation", systemImage: "function") }
            Button { m.add("graph") } label: { Label("Graph", systemImage: "chart.xyaxis.line") }
            Button { m.add("note") } label: { Label("Note", systemImage: "text.alignleft") }
            if let s = m.status { Text(s).font(.fo(.caption)).foregroundStyle(.secondary) }
        }.buttonStyle(.glass).padding(.top, 4)
    }
    var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCOPE").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
            if m.scope.isEmpty { Text("Variables and functions you define show up here.").font(.fo(.caption)).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(m.scope, id: \.name) { s in
                        VStack(alignment: .leading, spacing: 1) { Text(s.name).font(.system(size: 13, weight: .semibold, design: .monospaced)); Text(s.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.thinMaterial, in: .rect(cornerRadius: 10))
                    }
                }
            }
            Divider()
            Text("Try").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
            Text("f(x) = x^2 − 4\nsolve(f(x), 1)\nintegrate(sin(x), 0, pi)\nsum(k^2, k, 1, 10)\ndiff(x^3, 2)\nmean(2, 4, 9)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(12).frame(maxHeight: .infinity, alignment: .top).glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
