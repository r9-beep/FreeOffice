import SwiftUI
import AppKit

// MARK: - Rendering (one routine draws the editing canvas and every export)

struct DrawOpts {
    var selNodes = Set<Int>(), selEdge: Int?, hover: Int?, editing: Int?
    var zoom = 1.0
    var single: DNode?
    var connect: (from: CGPoint, to: CGPoint)?
    var connectTarget: Int?
    var marquee: CGRect?
    var guides: [(vertical: Bool, pos: Double)] = []
    var interactive = false
}

enum DiagramDraw {
    static let accent = Color(red: 0.18, green: 0.43, blue: 0.96)

    static func rounded(_ pts: [CGPoint], radius r: Double) -> Path {
        var p = Path(); guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for i in 1..<(pts.count - 1) {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1], d1 = DGeo.dist(a, b), d2 = DGeo.dist(b, c)
            guard d1 > 0, d2 > 0 else { continue }
            let k1 = min(r, d1 / 2), k2 = min(r, d2 / 2)
            p.addLine(to: CGPoint(x: b.x + (a.x - b.x) / d1 * k1, y: b.y + (a.y - b.y) / d1 * k1))
            p.addQuadCurve(to: CGPoint(x: b.x + (c.x - b.x) / d2 * k2, y: b.y + (c.y - b.y) / d2 * k2), control: b)
        }
        p.addLine(to: pts[pts.count - 1]); return p
    }

    static func draw(_ ctx: inout GraphicsContext, nodes: [DNode], edges: [DEdge], o: DrawOpts) {
        let by = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let ui = 1 / o.zoom
        // connectors
        var labels: [(DEdge, CGPoint)] = []
        for e in edges {
            guard let a = by[e.from], let b = by[e.to] else { continue }
            let r = DGeo.route(e, a, b), col = Color(hex: e.color)
            var path = Path()
            if let bz = r.bezier { path.move(to: bz.0); path.addCurve(to: bz.3, control1: bz.1, control2: bz.2) }
            else if r.pts.count > 2 { path = rounded(r.pts, radius: 10) } else { path.addLines(r.pts) }
            if o.selEdge == e.id { ctx.stroke(path, with: .color(accent.opacity(0.28)), style: StrokeStyle(lineWidth: e.width + 7 * ui, lineCap: .round, lineJoin: .round)) }
            ctx.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: e.width, lineCap: .round, lineJoin: .round, dash: e.dash ? [7, 5] : []))
            for (kind, tip, dir) in [(e.head, r.pts.last!, r.endDir), (e.tail, r.pts[0], CGPoint(x: -r.startDir.x, y: -r.startDir.y))] {
                let h = DGeo.head(kind, tip: tip, dir: dir, size: 8 + e.width * 2)
                if let c = h.circle { ctx.fill(Path(ellipseIn: c), with: .color(col)) }
                else if h.pts.count > 1 { var hp = Path(); hp.addLines(h.pts); if h.filled { hp.closeSubpath(); ctx.fill(hp, with: .color(col)) } else { ctx.stroke(hp, with: .color(col), style: StrokeStyle(lineWidth: e.width, lineCap: .round, lineJoin: .round)) } }
            }
            if !e.label.isEmpty { labels.append((e, r.mid)) }
            if o.selEdge == e.id && o.interactive { for p in [r.pts.first!, r.pts.last!] { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4 * ui, y: p.y - 4 * ui, width: 8 * ui, height: 8 * ui)), with: .color(accent)) } }
        }
        // shapes
        for n in nodes {
            let path = Path(DShapes.path(n.shape, n.frame))
            if n.shape != "text" {
                ctx.fill(path, with: .color(Color(hex: n.fill)))
                ctx.stroke(path, with: .color(Color(hex: n.stroke)), style: StrokeStyle(lineWidth: n.sw, lineJoin: .round, dash: n.dash ? [7, 5] : []))
            }
            if o.editing != n.id, !n.text.isEmpty, let s = ctx.resolveSymbol(id: "n\(n.id)") { ctx.draw(s, at: n.center, anchor: .center) }
            if o.interactive && (o.selNodes.contains(n.id) || o.connectTarget == n.id) {
                ctx.stroke(Path(roundedRect: n.frame.insetBy(dx: -3 * ui, dy: -3 * ui), cornerRadius: 4 * ui), with: .color(accent), style: StrokeStyle(lineWidth: 1.5 * ui, dash: o.connectTarget == n.id ? [] : [5 * ui, 3 * ui]))
            }
        }
        for (e, m) in labels {
            let w = Double(e.label.count) * 7.4 + 14
            ctx.fill(Path(roundedRect: CGRect(x: m.x - w / 2, y: m.y - 11, width: w, height: 22), cornerRadius: 6), with: .color(.white))
            if let s = ctx.resolveSymbol(id: "e\(e.id)") { ctx.draw(s, at: m, anchor: .center) }
        }
        guard o.interactive else { return }
        // ports and handles
        if let n = o.single ?? o.hover.flatMap({ by[$0] }) {
            for side in [Side.top, .right, .bottom, .left] {
                let p = DGeo.port(n, side) + DGeo.normal(side) * (14 * ui), r = 5.5 * ui
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(accent), lineWidth: 1.5 * ui)
            }
        }
        if let n = o.single {
            for h in DiagramModel.Handle.allCases {
                let p: CGPoint; let f = n.frame
                switch h { case .nw: p = CGPoint(x: f.minX, y: f.minY); case .n: p = CGPoint(x: f.midX, y: f.minY); case .ne: p = CGPoint(x: f.maxX, y: f.minY); case .e: p = CGPoint(x: f.maxX, y: f.midY)
                case .se: p = CGPoint(x: f.maxX, y: f.maxY); case .s: p = CGPoint(x: f.midX, y: f.maxY); case .sw: p = CGPoint(x: f.minX, y: f.maxY); case .w: p = CGPoint(x: f.minX, y: f.midY) }
                let r = CGRect(x: p.x - 4 * ui, y: p.y - 4 * ui, width: 8 * ui, height: 8 * ui)
                ctx.fill(Path(r), with: .color(.white)); ctx.stroke(Path(r), with: .color(accent), lineWidth: 1.5 * ui)
            }
        }
        if let c = o.connect { var p = Path(); p.move(to: c.from); p.addLine(to: c.to); ctx.stroke(p, with: .color(accent), style: StrokeStyle(lineWidth: 2 * ui, lineCap: .round, dash: [6 * ui, 4 * ui])) }
        for g in o.guides { var p = Path(); if g.vertical { p.move(to: CGPoint(x: g.pos, y: -50000)); p.addLine(to: CGPoint(x: g.pos, y: 50000)) } else { p.move(to: CGPoint(x: -50000, y: g.pos)); p.addLine(to: CGPoint(x: 50000, y: g.pos)) }
            ctx.stroke(p, with: .color(Color(red: 0.95, green: 0.2, blue: 0.6).opacity(0.8)), lineWidth: 1 * ui) }
        if let m = o.marquee { ctx.fill(Path(m), with: .color(accent.opacity(0.1))); ctx.stroke(Path(m), with: .color(accent), lineWidth: 1 * ui) }
    }
}

/// The text inside shapes and on connectors, supplied to the Canvas as symbols.
struct DiagramSymbols: View {
    let nodes: [DNode], edges: [DEdge]
    private struct Item: Identifiable { let id: String; let node: DNode?; let edge: DEdge? }
    private var items: [Item] { nodes.map { Item(id: "n\($0.id)", node: $0, edge: nil) } + edges.filter { !$0.label.isEmpty }.map { Item(id: "e\($0.id)", node: nil, edge: $0) } }
    var body: some View {
        ForEach(items) { it in
            if let n = it.node {
                Text(DocLinks.plain(n.text)).font(Font.custom("Helvetica Neue", size: n.size).weight(n.bold ? .bold : .regular)).italic(n.italic)
                    .foregroundStyle(Color(hex: n.color)).multilineTextAlignment(.center).frame(width: max(n.w - 16, 10)).tag(it.id)
            } else if let e = it.edge {
                Text(e.label).font(Font.custom("Helvetica Neue", size: 13)).foregroundStyle(Color(hex: e.color)).fixedSize().tag(it.id)
            }
        }
    }
}

struct DiagramExportView: View {
    let nodes: [DNode], edges: [DEdge]
    var body: some View {
        let b = DSVG.bounds(nodes, edges).insetBy(dx: -40, dy: -40)
        Canvas { ctx, _ in
            ctx.translateBy(x: -b.minX, y: -b.minY)
            DiagramDraw.draw(&ctx, nodes: nodes, edges: edges, o: DrawOpts())
        } symbols: { DiagramSymbols(nodes: nodes, edges: edges) }
        .frame(width: b.width, height: b.height).background(Color.white)
    }
}

// MARK: - Scroll wheel: two-finger scroll pans, ⌘/pinch-scroll zooms

final class DiagramScrollMonitor {
    var monitor: Any?
    func start(_ handler: @escaping (NSEvent) -> Bool) { stop(); monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { handler($0) ? nil : $0 } }
    func stop() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
    deinit { stop() }
}

// MARK: - Editor

struct DiagramEditorView: View {
    @StateObject private var m: DiagramModel
    let docTab: Tab
    enum Mode { case idle, move([Int: CGPoint]), resize(DiagramModel.Handle, CGRect), connect(Int, Side), marquee(CGPoint), pan(CGPoint), bend(Int, Double) }
    @State private var mode = Mode.idle
    @State private var moved = false
    @State private var hover: Int?
    @State private var overCanvas = false
    @State private var connectTo: CGPoint?
    @State private var connectTarget: Int?
    @State private var marquee: CGRect?
    @State private var startZoom: Double?
    @State private var showImport = false
    @State private var importText = ""
    @State private var importKind = 0
    @State private var importAppend = true
    @State private var scroll = DiagramScrollMonitor()
    @FocusState private var canvasFocus: Bool
    @FocusState private var editFocus: Bool

    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? DiagramModel) ?? { let x = DiagramModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        HStack(spacing: 10) {
            palette
            canvasArea
            inspector
        }
        .padding(10)
        .background { Backdrop().opacity(0.6) }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled diagram", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                Menu {
                    Button("Fit to window") { m.fit() }
                    Divider()
                    ForEach([25, 50, 75, 100, 150, 200], id: \.self) { z in Button("\(z)%") { m.setZoom(Double(z) / 100) } }
                } label: { Label("\(Int(m.zoom * 100))%", systemImage: "magnifyingglass") }
                Menu {
                    Button("Top to bottom") { m.autoLayout(.down) }; Button("Left to right") { m.autoLayout(.right) }; Button("Mind map (radial)") { m.autoLayout(.radial) }
                } label: { Label("Layout", systemImage: "square.grid.3x1.below.line.grid.1x2") }
                Menu {
                    Button("PNG image…") { m.exportPNG() }; Button("PDF…") { m.exportPDF() }; Button("SVG…") { m.exportSVG() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled diagram" : t }
        .onChange(of: m.status) { _, s in if s != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { m.status = nil } } }
        .onAppear { docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() } }
        .onDisappear { m.saver.flush(); scroll.stop() }
        .sheet(isPresented: $showImport) { importSheet }
    }

    // MARK: palette
    func shapeThumb(_ id: String) -> some View {
        Canvas { ctx, size in
            let r = CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
            if id == "text" { ctx.draw(Text("Aa").font(.system(size: 16, weight: .semibold)), at: CGPoint(x: size.width / 2, y: size.height / 2)); return }
            ctx.stroke(Path(DShapes.path(id, r)), with: .color(.primary.opacity(0.75)), lineWidth: 1.4)
        }.frame(height: 38)
    }
    var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SHAPES").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(DShapes.all, id: \.id) { s in
                    Button { let id = m.addNode(s.id); if s.id == "text" { m.editing = id } } label: { shapeThumb(s.id).frame(maxWidth: .infinity).background(.thinMaterial, in: .rect(cornerRadius: 10)) }
                        .buttonStyle(.plain).help(s.name)
                }
            }
            Divider().padding(.vertical, 4)
            Button { showImport = true } label: { Label("Text to diagram…", systemImage: "text.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.glass)
            Menu {
                Button("Top to bottom") { m.autoLayout(.down) }; Button("Left to right") { m.autoLayout(.right) }; Button("Mind map (radial)") { m.autoLayout(.radial) }
            } label: { Label("Auto layout", systemImage: "wand.and.stars").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.glass)
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text("Double-click empty space to add a shape.").font(.fo(.caption)).foregroundStyle(.secondary)
                Text("Drag from a dot to connect or grow.").font(.fo(.caption)).foregroundStyle(.secondary)
                Text("Scroll to pan · ⌘-scroll or pinch to zoom.").font(.fo(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 196).frame(maxHeight: .infinity, alignment: .top).glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: canvas
    var opts: DrawOpts {
        var o = DrawOpts(); o.selNodes = m.sel; o.selEdge = m.selEdge; o.hover = hover; o.editing = m.editing; o.zoom = m.zoom; o.single = m.single; o.interactive = true
        if case .connect(let id, let side) = mode, let n = m.node(id), let to = connectTo { o.connect = (DGeo.port(n, side), to); o.connectTarget = connectTarget }
        o.marquee = marquee; o.guides = m.guides
        return o
    }
    func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard m.grid != "none" else { return }
        let g = DiagramModel.gridSize * m.zoom; guard g >= 8 else { return }
        var p = Path(); var x = m.offset.x.truncatingRemainder(dividingBy: g); if x < 0 { x += g }
        let y0 = { () -> Double in var y = m.offset.y.truncatingRemainder(dividingBy: g); if y < 0 { y += g }; return y }()
        if m.grid == "lines" { while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += g }
            var y = y0; while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += g }
            ctx.stroke(p, with: .color(.black.opacity(0.06)), lineWidth: 1) }
        else { while x < size.width { var y = y0; while y < size.height { p.addRect(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)); y += g }; x += g }
            ctx.fill(p, with: .color(.black.opacity(0.22))) }
    }
    var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { ctx, size in
                    drawGrid(&ctx, size)
                    ctx.translateBy(x: m.offset.x, y: m.offset.y); ctx.scaleBy(x: m.zoom, y: m.zoom)
                    DiagramDraw.draw(&ctx, nodes: m.nodes, edges: m.edges, o: opts)
                } symbols: { DiagramSymbols(nodes: m.nodes, edges: m.edges) }
                .background(Color.white)
                .gesture(drag)
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { doubleClick($0.location) })
                .simultaneousGesture(MagnifyGesture().onChanged { v in if startZoom == nil { startZoom = m.zoom }; m.setZoom((startZoom ?? 1) * v.magnification) }.onEnded { _ in startZoom = nil })
                if let id = m.editing, let n = m.node(id) { inlineEditor(n) }
                if m.nodes.isEmpty { Text("Double-click to add a shape,\nor use Text to diagram…").multilineTextAlignment(.center).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            .clipShape(.rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
            .overlay(alignment: .bottomLeading) { if let s = m.status { Text(s).font(.fo(.caption)).padding(8).glassEffect(.regular, in: .capsule).padding(10) } }
            .focusable().focused($canvasFocus).focusEffectDisabled()
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): overCanvas = true; let mp = m.toModel(p); let pad = 26 / m.zoom
                    let h = m.nodes.reversed().first { $0.frame.insetBy(dx: -pad, dy: -pad).contains(mp) }?.id; if h != hover { hover = h }
                case .ended: overCanvas = false; hover = nil
                }
            }
            .onKeyPress(phases: [.down, .repeat]) { press in keyPress(press) }
            .onDeleteCommand { m.deleteSelection() }
            .onCopyCommand { m.copy(); return m.sel.isEmpty ? [] : [NSItemProvider(object: m.svg() as NSString)] }
            .onCutCommand { m.cut(); return [NSItemProvider(object: m.svg() as NSString)] }
            .onPasteCommand(of: [.plainText]) { _ in m.paste() }
            .onAppear { sizeChanged(geo.size); installScroll() }
            .onChange(of: geo.size) { _, s in sizeChanged(s) }
        }
    }

    func sizeChanged(_ s: CGSize) {
        m.viewSize = s
        if m.needsFit && s.width > 300 && s.height > 200 { m.needsFit = false; DispatchQueue.main.async { m.fit() } }
    }
    func installScroll() {
        scroll.start { e in
            guard overCanvas, m.editing == nil else { return false }
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
                let mouse = e.locationInWindow; _ = mouse
                m.setZoom(m.zoom * exp(Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.01 : 0.05)))
            } else { m.offset = CGPoint(x: m.offset.x + e.scrollingDeltaX * (e.hasPreciseScrollingDeltas ? 1 : 8), y: m.offset.y + e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 8)) }
            return true
        }
    }

    func inlineEditor(_ n: DNode) -> some View {
        let z = m.zoom, c = m.toView(n.center), lines = max(1, n.text.components(separatedBy: "\n").count), lh = n.size * z * 1.3
        let top = max((n.h * z - Double(lines) * lh) / 2 - 7, 0)
        return TextEditor(text: Binding(get: { m.node(n.id)?.text ?? "" }, set: { m.setText(n.id, $0) }))
            .font(Font.custom("Helvetica Neue", size: n.size * z).weight(n.bold ? .bold : .regular)).multilineTextAlignment(.center)
            .scrollContentBackground(.hidden).scrollDisabled(true).foregroundStyle(Color(hex: n.color)).padding(.top, top)
            .focused($editFocus)
            .docMentions(Binding(get: { m.node(n.id)?.text ?? "" }, set: { m.setText(n.id, $0) }))
            .frame(width: max(n.w * z, 60), height: max(n.h * z, 30))
            .background(Color.white.opacity(0.01))
            .position(c)
            .onAppear { editFocus = true }
            .onKeyPress(.escape) { m.editing = nil; canvasFocus = true; return .handled }
    }

    // MARK: gestures
    var drag: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { v in
            if case .idle = mode { begin(v) } else { update(v) }
        }.onEnded { v in finish(v) }
    }
    func begin(_ v: DragGesture.Value) {
        canvasFocus = true; if m.editing != nil { m.editing = nil }
        moved = false; m.guides = []
        let p = m.toModel(v.startLocation), extend = NSEvent.modifierFlags.contains(.shift)
        if NSEvent.modifierFlags.contains(.option) { mode = .pan(m.offset); return }
        if let h = m.handleAt(p), let n = m.single { mode = .resize(h, n.frame); return }
        let src = m.single ?? hover.flatMap { m.node($0) }
        if let n = src, let side = m.portAt(n, p) { mode = .connect(n.id, side); connectTo = p; connectTarget = nil; return }
        if let n = m.nodeAt(p) {
            m.select(n.id, extend: extend)
            mode = .move(Dictionary(uniqueKeysWithValues: m.selectedNodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })); return
        }
        if let e = m.edgeAt(p) { m.sel = []; m.selEdge = e.id; mode = .bend(e.id, e.bend); return }
        if !extend { m.clearSelection() }
        mode = .marquee(p)
    }
    func update(_ v: DragGesture.Value) {
        let dx = v.translation.width / m.zoom, dy = v.translation.height / m.zoom, p = m.toModel(v.location)
        if abs(v.translation.width) + abs(v.translation.height) > 3 { moved = true }
        switch mode {
        case .move(let start):
            guard moved else { return }
            let (sx, sy) = m.snapDelta(Set(start.keys), start: start, dx: dx, dy: dy)
            for i in m.nodes.indices { if let s = start[m.nodes[i].id] { m.nodes[i].x = s.x + sx; m.nodes[i].y = s.y + sy } }
        case .resize(let h, let r):
            guard let id = m.single?.id, let i = m.index(id) else { return }
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            let gx = m.snap ? (p.x / 10).rounded() * 10 : p.x, gy = m.snap ? (p.y / 10).rounded() * 10 : p.y
            switch h { case .nw, .w, .sw: minX = min(gx, maxX - 30); case .ne, .e, .se: maxX = max(gx, minX + 30); default: break }
            switch h { case .nw, .n, .ne: minY = min(gy, maxY - 24); case .sw, .s, .se: maxY = max(gy, minY + 24); default: break }
            m.nodes[i].x = minX; m.nodes[i].y = minY; m.nodes[i].w = maxX - minX; m.nodes[i].h = maxY - minY
        case .connect(let from, _):
            connectTo = p; connectTarget = m.nodeAt(p).flatMap { $0.id == from ? nil : $0.id }
        case .marquee(let s):
            marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            if let r = marquee { m.select(in: r, extend: NSEvent.modifierFlags.contains(.shift)) }
        case .pan(let o): m.offset = CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height)
        case .bend(let id, let b0):
            guard moved, let i = m.edges.firstIndex(where: { $0.id == id }), m.edges[i].route == "ortho", let r = m.route(m.edges[i]) else { return }
            let seg = zip(r.pts, r.pts.dropFirst()).min { DGeo.distance(m.toModel(v.startLocation), toSegment: $0.0, $0.1) < DGeo.distance(m.toModel(v.startLocation), toSegment: $1.0, $1.1) }
            let vertical = seg.map { abs($0.0.x - $0.1.x) < 0.5 } ?? true
            m.edges[i].bend = b0 + (vertical ? dx : dy)
        case .idle: break
        }
    }
    func finish(_ v: DragGesture.Value) {
        defer { mode = .idle; connectTo = nil; connectTarget = nil; marquee = nil; m.guides = [] }
        if case .idle = mode { begin(v); return }
        let p = m.toModel(v.location)
        switch mode {
        case .connect(let from, let side):
            if let t = connectTarget { m.connect(from, t, fromSide: side, toSide: .auto) }
            else if moved { m.addConnected(from: from, side: side, at: p) }
            else { m.addConnected(from: from, side: side) }
        case .move: if !moved, let n = m.nodeAt(m.toModel(v.startLocation)), !NSEvent.modifierFlags.contains(.shift) { m.sel = [n.id] }
        default: break
        }
    }
    func doubleClick(_ loc: CGPoint) {
        let p = m.toModel(loc)
        if let n = m.nodeAt(p) { m.sel = [n.id]; m.selEdge = nil; m.editing = n.id }
        else if let e = m.edgeAt(p) { m.sel = []; m.selEdge = e.id }
        else { let id = m.addNode("rect", at: p); m.editing = id }
    }
    func keyPress(_ press: KeyPress) -> KeyPress.Result {
        guard m.editing == nil else { return .ignored }
        let cmd = press.modifiers.contains(.command), step = press.modifiers.contains(.shift) ? 20.0 : 4.0
        switch press.key {
        case .delete, .deleteForward: m.deleteSelection(); return .handled
        case .return: if let n = m.single { m.editing = n.id; return .handled }; return .ignored
        case .escape: m.clearSelection(); return .handled
        case .leftArrow: m.move(m.sel, dx: -step, dy: 0); return .handled
        case .rightArrow: m.move(m.sel, dx: step, dy: 0); return .handled
        case .upArrow: m.move(m.sel, dx: 0, dy: -step); return .handled
        case .downArrow: m.move(m.sel, dx: 0, dy: step); return .handled
        default: break
        }
        if cmd { switch press.characters { case "d": m.duplicate(); return .handled; case "a": m.selectAll(); return .handled; case "0": m.fit(); return .handled
            case "=", "+": m.setZoom(m.zoom * 1.2); return .handled; case "-": m.setZoom(m.zoom / 1.2); return .handled; default: break } }
        return .ignored
    }

    // MARK: inspector
    let swatches = ["#ffffff", "#cfe0ff", "#c8f0d4", "#ffd9b3", "#ffc9c4", "#e3d6ff", "#fff3b0", "#d3f0f5", "#1d1d1f"]
    func colorRow(_ label: String, _ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.fo(.callout)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(swatches, id: \.self) { c in
                    Button { set(c) } label: { Circle().fill(Color(hex: c)).frame(width: 16, height: 16).overlay(Circle().stroke(Color.primary.opacity(get() == c ? 0.9 : 0.25), lineWidth: get() == c ? 2 : 1)) }.buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { Color(hex: get()) }, set: { set($0.hexString) })).labelsHidden().controlSize(.small).frame(width: 34)
            }
        }
    }
    func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title.uppercased()).font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary); c() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    var inspector: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let e = m.selEdge.flatMap({ id in m.edges.first { $0.id == id } }) { edgeInspector(e) }
                else if !m.sel.isEmpty { nodeInspector }
                else { diagramInspector }
            }.padding(.bottom, 4)
        }
        .frame(width: 290).scrollIndicators(.hidden)
    }
    var nodeInspector: some View {
        let first = m.selectedNodes.first ?? DNode(id: 0)
        return VStack(spacing: 10) {
            if let n = m.single {
                card("Text") {
                    TextEditor(text: Binding(get: { m.node(n.id)?.text ?? "" }, set: { m.setText(n.id, $0) })).frame(height: 70).scrollContentBackground(.hidden).padding(6).foregroundStyle(.black).background(.white.opacity(0.85), in: .rect(cornerRadius: 8))
                        .docMentions(Binding(get: { m.node(n.id)?.text ?? "" }, set: { m.setText(n.id, $0) }))
                    MentionStrip(text: n.text)
                    Text("Type @ to link another document").font(.fo(.caption)).foregroundStyle(.secondary)
                }
            } else { card("Selection") { Text("\(m.sel.count) shapes selected").font(.fo(.callout)) } }
            card("Shape") {
                Menu { ForEach(DShapes.all, id: \.id) { s in Button(s.name) { m.style { $0.shape = s.id } } } } label: { Label(DShapes.all.first { $0.id == first.shape }?.name ?? "Shape", systemImage: "square.on.circle") }.menuStyle(.borderlessButton).fixedSize()
                colorRow("Fill", { first.fill }) { c in m.style { $0.fill = c } }
                colorRow("Line", { first.stroke }) { c in m.style { $0.stroke = c } }
                HStack { Text("Width").font(.fo(.callout)); Slider(value: Binding(get: { first.sw }, set: { v in m.style { $0.sw = v } }), in: 0...6, step: 0.5); Toggle("Dashed", isOn: Binding(get: { first.dash }, set: { v in m.style { $0.dash = v } })).toggleStyle(.button) }
                Button { m.resizeToFit() } label: { Label("Fit to text", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.glass)
            }
            card("Text style") {
                colorRow("Colour", { first.color }) { c in m.style { $0.color = c } }
                HStack {
                    Stepper("Size \(Int(first.size))", value: Binding(get: { first.size }, set: { v in m.style { $0.size = v } }), in: 8...64)
                    Toggle(isOn: Binding(get: { first.bold }, set: { v in m.style { $0.bold = v } })) { Image(systemName: "bold") }.toggleStyle(.button)
                    Toggle(isOn: Binding(get: { first.italic }, set: { v in m.style { $0.italic = v } })) { Image(systemName: "italic") }.toggleStyle(.button)
                }
            }
            if let n = m.single {
                card("Add connected") {
                    HStack(spacing: 8) {
                        Button { m.addConnected(from: n.id, side: .left) } label: { Image(systemName: "arrow.left") }
                        Button { m.addConnected(from: n.id, side: .top) } label: { Image(systemName: "arrow.up") }
                        Button { m.addConnected(from: n.id, side: .bottom) } label: { Image(systemName: "arrow.down") }
                        Button { m.addConnected(from: n.id, side: .right) } label: { Image(systemName: "arrow.right") }
                    }.buttonStyle(.glass)
                }
            }
            card("Arrange") {
                HStack(spacing: 6) {
                    Button { m.bringToFront() } label: { Image(systemName: "square.2.layers.3d.top.filled") }.help("Bring to front")
                    Button { m.sendToBack() } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }.help("Send to back")
                    Button { m.duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
                    Button(role: .destructive) { m.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete")
                }.buttonStyle(.glass)
                if m.sel.count > 1 {
                    HStack(spacing: 6) {
                        Button { m.align(.left) } label: { Image(systemName: "align.horizontal.left") }; Button { m.align(.centre) } label: { Image(systemName: "align.horizontal.center") }; Button { m.align(.right) } label: { Image(systemName: "align.horizontal.right") }
                        Button { m.align(.top) } label: { Image(systemName: "align.vertical.top") }; Button { m.align(.middle) } label: { Image(systemName: "align.vertical.center") }; Button { m.align(.bottom) } label: { Image(systemName: "align.vertical.bottom") }
                    }.buttonStyle(.glass)
                    HStack(spacing: 6) {
                        Button { m.distribute(horizontal: true) } label: { Label("Spread across", systemImage: "distribute.horizontal.center") }; Button { m.distribute(horizontal: false) } label: { Label("Spread down", systemImage: "distribute.vertical.center") }
                    }.buttonStyle(.glass)
                }
            }
        }
    }
    func edgeInspector(_ e: DEdge) -> some View {
        let sides: [(Side, String)] = [(.auto, "Auto"), (.top, "Top"), (.right, "Right"), (.bottom, "Bottom"), (.left, "Left")]
        let heads: [(String, String)] = [("none", "None"), ("arrow", "Arrow"), ("open", "Open arrow"), ("dot", "Dot"), ("diamond", "Diamond")]
        return VStack(spacing: 10) {
            card("Connector") {
                Picker("", selection: Binding(get: { e.route }, set: { v in m.edgeStyle { $0.route = v; $0.bend = 0 } })) { Text("Elbow").tag("ortho"); Text("Straight").tag("straight"); Text("Curve").tag("curve") }.pickerStyle(.segmented).labelsHidden()
                TextField("Label", text: Binding(get: { e.label }, set: { v in m.edgeStyle { $0.label = v } })).textFieldStyle(.roundedBorder)
                colorRow("Colour", { e.color }) { c in m.edgeStyle { $0.color = c } }
                HStack { Text("Width").font(.fo(.callout)); Slider(value: Binding(get: { e.width }, set: { v in m.edgeStyle { $0.width = v } }), in: 1...6, step: 0.5); Toggle("Dashed", isOn: Binding(get: { e.dash }, set: { v in m.edgeStyle { $0.dash = v } })).toggleStyle(.button) }
            }
            card("Ends") {
                HStack { Text("Start").frame(width: 44, alignment: .leading); Picker("", selection: Binding(get: { e.tail }, set: { v in m.edgeStyle { $0.tail = v } })) { ForEach(heads, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden() }
                HStack { Text("End").frame(width: 44, alignment: .leading); Picker("", selection: Binding(get: { e.head }, set: { v in m.edgeStyle { $0.head = v } })) { ForEach(heads, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden() }
                HStack { Text("From").frame(width: 44, alignment: .leading); Picker("", selection: Binding(get: { e.fromSide }, set: { v in m.edgeStyle { $0.fromSide = v } })) { ForEach(sides, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden() }
                HStack { Text("To").frame(width: 44, alignment: .leading); Picker("", selection: Binding(get: { e.toSide }, set: { v in m.edgeStyle { $0.toSide = v } })) { ForEach(sides, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden() }
                HStack {
                    Button { m.edgeStyle { let f = $0.from; $0.from = $0.to; $0.to = f; let s = $0.fromSide; $0.fromSide = $0.toSide; $0.toSide = s } } label: { Label("Reverse", systemImage: "arrow.left.arrow.right") }.buttonStyle(.glass)
                    Button(role: .destructive) { m.deleteSelection() } label: { Label("Delete", systemImage: "trash") }.buttonStyle(.glass)
                }
                if e.route == "ortho" { Text("Drag the line to move its bend.").font(.fo(.caption)).foregroundStyle(.secondary) }
            }
        }
    }
    var diagramInspector: some View {
        VStack(spacing: 10) {
            card("Diagram") {
                Picker("Grid", selection: $m.grid) { Text("None").tag("none"); Text("Dots").tag("dots"); Text("Lines").tag("lines") }.pickerStyle(.segmented)
                Toggle("Snap to grid and guides", isOn: $m.snap)
                Text("\(m.nodes.count) shapes · \(m.edges.count) connectors").font(.fo(.caption)).foregroundStyle(.secondary)
                if let s = m.saver.dirty ? nil : m.savedAt { Text("Saved \(s, format: .dateTime.hour().minute())").font(.fo(.caption)).foregroundStyle(.secondary) }
            }
            card("Layout") {
                Button { m.autoLayout(.down) } label: { Label("Top to bottom", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.glass)
                Button { m.autoLayout(.right) } label: { Label("Left to right", systemImage: "arrow.right.to.line").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.glass)
                Button { m.autoLayout(.radial) } label: { Label("Mind map", systemImage: "circle.hexagongrid").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.glass)
                Text("Select a shape first to choose the centre of a mind map.").font(.fo(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: text → diagram
    static let examples = ["flowchart TD\n  A([Start]) --> B{Valid?}\n  B -->|yes| C[Save it]\n  B -->|no| D[Show an error]\n  D --> B\n  C --> E([Done])",
                           "CEO\n  CTO\n    Engineering\n    Security\n  CFO\n    Finance\n  COO\n    Operations",
                           "My project\n  Goals\n    Ship version one\n    Learn from users\n  Team\n    Design\n    Build\n  Risks"]
    var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text to diagram").font(.fo(.title2))
            Picker("", selection: $importKind) { Text("Flowchart").tag(0); Text("Org chart / tree").tag(1); Text("Mind map").tag(2) }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: importKind) { _, k in importText = Self.examples[k] }
            TextEditor(text: $importText).font(.system(.body, design: .monospaced)).frame(height: 220).scrollContentBackground(.hidden).padding(8).background(.thinMaterial, in: .rect(cornerRadius: 12))
            Text(importKind == 0 ? "One link per line: A[Box] --> B(Rounded) -->|label| C{Decision}. Use -.-> for dashed, ((x)) circle, ([x]) pill, [(x)] database." : "One item per line; indent with spaces to make children.")
                .font(.fo(.caption)).foregroundStyle(.secondary)
            HStack {
                Toggle("Add beside what's there", isOn: $importAppend)
                Spacer()
                Button("Cancel") { showImport = false }.buttonStyle(.glass)
                Button("Create") {
                    let parsed = importKind == 0 ? DText.parseFlow(importText) : DText.parseOutline(importText, mind: importKind == 2)
                    m.insert(parsed, replace: !importAppend || m.nodes.isEmpty, layout: importKind == 2 ? .radial : (importKind == 0 && parsed.horizontal ? .right : .down))
                    showImport = false
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { if importText.isEmpty { importText = Self.examples[importKind] } }
    }
}
