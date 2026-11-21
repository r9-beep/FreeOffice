import SwiftUI
import AppKit

struct DiagramState: Equatable { var nodes: [DNode]; var edges: [DEdge] }

final class DiagramModel: ObservableObject {
    let history = UndoHistory<DiagramState>()
    @Published var nodes: [DNode] { didSet { if ready { history.record(DiagramState(nodes: oldValue, edges: edges)); saver.touch() } } }
    @Published var edges: [DEdge] { didSet { if ready { history.record(DiagramState(nodes: nodes, edges: oldValue)); saver.touch() } } }
    @Published var title: String { didSet { if ready { saver.touch() } } }
    @Published var grid: String { didSet { if ready { saver.touch() } } }        // none · dots · lines
    @Published var snap: Bool { didSet { if ready { saver.touch() } } }
    @Published var sel = Set<Int>()
    @Published var selEdge: Int?
    @Published var editing: Int?
    @Published var offset = CGPoint(x: 80, y: 80)
    @Published var zoom = 1.0
    @Published var guides: [(vertical: Bool, pos: Double)] = []
    @Published var savedAt: Date?
    @Published var status: String?
    var viewSize = CGSize(width: 900, height: 600)
    var needsFit = false
    let saver: AutoSaver
    private var ready = false
    static var clip: DiagramState?
    static let gridSize = 20.0

    init(id: String, dir: URL) {
        saver = AutoSaver(url: docURL(dir, "diagrams", id))
        struct In: Decodable { var title: String?; var nodes: [DNode]?; var edges: [DEdge]?; var grid: String?; var snap: Bool?; var ox: Double?; var oy: Double?; var zoom: Double? }
        var n: [DNode] = [], e: [DEdge] = [], t = "", g = "dots", s = true
        var ox = 80.0, oy = 80.0, z = 1.0
        if let d = try? Data(contentsOf: saver.url), let o = try? JSONDecoder().decode(In.self, from: d) {
            n = o.nodes ?? []; e = o.edges ?? []; t = o.title ?? ""; g = o.grid ?? "dots"; s = o.snap ?? true; ox = o.ox ?? 80; oy = o.oy ?? 80; z = o.zoom ?? 1
        } else {
            var a = DNode(id: 1, shape: "pill", x: 0, y: 0, text: "Start"); a.fill = "#c8f0d4"
            var b = DNode(id: 2, shape: "rect", x: 0, y: 120, text: "Do something"); var c = DNode(id: 3, shape: "diamond", x: 0, y: 240, text: "Done?")
            n = [a, b, c]; e = [DEdge(id: 1, from: 1, to: 2), DEdge(id: 2, from: 2, to: 3)]
        }
        nodes = n; edges = e; title = t; grid = g; snap = s; offset = CGPoint(x: ox, y: oy); zoom = z
        needsFit = !((try? Data(contentsOf: saver.url)).flatMap { try? JSONDecoder().decode(In.self, from: $0) }?.zoom != nil)
        ready = true
        saver.make = { [weak self] in
            guard let m = self else { return nil }
            struct Out: Encodable { var title: String; var nodes: [DNode]; var edges: [DEdge]; var grid: String; var snap: Bool; var ox: Double; var oy: Double; var zoom: Double; var modified: Double }
            return try? JSONEncoder().encode(Out(title: m.title, nodes: m.nodes, edges: m.edges, grid: m.grid, snap: m.snap, ox: m.offset.x, oy: m.offset.y, zoom: m.zoom, modified: nowMillis()))
        }
        saver.onSaved = { [weak self] in self?.savedAt = Date() }
    }

    // MARK: undo
    func undo() { if let s = history.undo(current: DiagramState(nodes: nodes, edges: edges)) { apply(s) } }
    func redo() { if let s = history.redo(current: DiagramState(nodes: nodes, edges: edges)) { apply(s) } }
    private func apply(_ s: DiagramState) {
        history.applying = true; nodes = s.nodes; edges = s.edges; history.applying = false
        sel = sel.filter { id in nodes.contains { $0.id == id } }; if let e = selEdge, !edges.contains(where: { $0.id == e }) { selEdge = nil }; editing = nil
        saver.touch()
    }

    // MARK: lookup
    func node(_ id: Int) -> DNode? { nodes.first { $0.id == id } }
    func index(_ id: Int) -> Int? { nodes.firstIndex { $0.id == id } }
    var nextNodeId: Int { (nodes.map(\.id).max() ?? 0) + 1 }
    var nextEdgeId: Int { (edges.map(\.id).max() ?? 0) + 1 }
    var selectedNodes: [DNode] { nodes.filter { sel.contains($0.id) } }
    var single: DNode? { sel.count == 1 ? node(sel.first!) : nil }
    func route(_ e: DEdge) -> DRoute? { guard let a = node(e.from), let b = node(e.to) else { return nil }; return DGeo.route(e, a, b) }

    // MARK: coordinates
    func toModel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom) }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y) }
    var viewCentre: CGPoint { toModel(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) }

    // MARK: hit testing (model space; `slop` is in view pixels)
    func nodeAt(_ p: CGPoint) -> DNode? {
        for n in nodes.reversed() {
            if n.shape == "text" || n.shape == "note" || n.shape == "document" || n.shape == "parallelogram" { if n.frame.insetBy(dx: -2, dy: -2).contains(p) { return n } }
            else if DShapes.path(n.shape, n.frame).contains(p) || n.frame.insetBy(dx: 3, dy: 3).contains(p) && n.shape == "rect" { return n }
        }
        return nil
    }
    func edgeAt(_ p: CGPoint, slop: Double = 6) -> DEdge? {
        let tol = slop / zoom
        var best: (DEdge, Double)?
        for e in edges { if let r = route(e) { let d = DGeo.distance(p, toPolyline: r.pts); if d <= tol && d < (best?.1 ?? .infinity) { best = (e, d) } } }
        return best?.0
    }
    enum Handle: Int, CaseIterable { case nw, n, ne, e, se, s, sw, w }
    func handlePoint(_ h: Handle, _ r: CGRect) -> CGPoint {
        switch h { case .nw: return CGPoint(x: r.minX, y: r.minY); case .n: return CGPoint(x: r.midX, y: r.minY); case .ne: return CGPoint(x: r.maxX, y: r.minY); case .e: return CGPoint(x: r.maxX, y: r.midY)
        case .se: return CGPoint(x: r.maxX, y: r.maxY); case .s: return CGPoint(x: r.midX, y: r.maxY); case .sw: return CGPoint(x: r.minX, y: r.maxY); case .w: return CGPoint(x: r.minX, y: r.midY) }
    }
    func handleAt(_ p: CGPoint) -> Handle? {
        guard let n = single else { return nil }
        let tol = 7 / zoom; return Handle.allCases.first { DGeo.dist(handlePoint($0, n.frame), p) <= tol }
    }
    /// Connection dots sit just outside each side's midpoint.
    func portPoint(_ n: DNode, _ s: Side) -> CGPoint { DGeo.port(n, s) + DGeo.normal(s) * (14 / zoom) }
    func portAt(_ n: DNode, _ p: CGPoint) -> Side? {
        let tol = 10 / zoom; return [Side.top, .right, .bottom, .left].first { DGeo.dist(portPoint(n, $0), p) <= tol }
    }

    // MARK: selection
    func select(_ id: Int?, extend: Bool = false) {
        selEdge = nil
        guard let id = id else { if !extend { sel = [] }; return }
        if extend { if sel.contains(id) { sel.remove(id) } else { sel.insert(id) } } else if !sel.contains(id) { sel = [id] }
    }
    func selectAll() { sel = Set(nodes.map(\.id)); selEdge = nil }
    func clearSelection() { sel = []; selEdge = nil; editing = nil }
    func select(in r: CGRect, extend: Bool) {
        let hit = Set(nodes.filter { r.intersects($0.frame) }.map(\.id)); sel = extend ? sel.union(hit) : hit; selEdge = nil
    }

    // MARK: editing
    @discardableResult func addNode(_ shape: String, at p: CGPoint? = nil, text: String? = nil) -> Int {
        var n = DNode(id: nextNodeId, shape: shape, text: text ?? (shape == "text" ? "Text" : ""))
        let c = p ?? viewCentre
        n.x = c.x - n.w / 2 + (p == nil ? Double(nodes.count % 5) * 14 : 0); n.y = c.y - n.h / 2 + (p == nil ? Double(nodes.count % 5) * 14 : 0)
        if snap { n.x = (n.x / Self.gridSize).rounded() * Self.gridSize; n.y = (n.y / Self.gridSize).rounded() * Self.gridSize }
        nodes.append(n); sel = [n.id]; selEdge = nil
        return n.id
    }
    /// A new shape next to `id`, joined to it.
    @discardableResult func addConnected(from id: Int, side: Side, at drop: CGPoint? = nil) -> Int? {
        guard let a = node(id) else { return nil }
        var n = a; n.id = nextNodeId; n.text = ""
        let gap = 70.0, nrm = DGeo.normal(side)
        if let d = drop { n.x = d.x - n.w / 2; n.y = d.y - n.h / 2 }
        else { n.x = a.x + (nrm.x > 0 ? a.w + gap : nrm.x < 0 ? -n.w - gap : 0); n.y = a.y + (nrm.y > 0 ? a.h + gap : nrm.y < 0 ? -n.h - gap : 0) }
        if snap { n.x = (n.x / Self.gridSize).rounded() * Self.gridSize; n.y = (n.y / Self.gridSize).rounded() * Self.gridSize }
        nodes.append(n)
        var e = DEdge(id: nextEdgeId, from: id, to: n.id); e.fromSide = side; edges.append(e)
        sel = [n.id]; selEdge = nil; editing = n.id
        return n.id
    }
    @discardableResult func connect(_ a: Int, _ b: Int, fromSide: Side = .auto, toSide: Side = .auto) -> Int? {
        guard node(a) != nil, node(b) != nil, !edges.contains(where: { $0.from == a && $0.to == b && $0.fromSide == fromSide && $0.toSide == toSide }) else { return nil }
        var e = DEdge(id: nextEdgeId, from: a, to: b); e.fromSide = fromSide; e.toSide = toSide
        if let last = edges.last(where: { $0.from == a }) ?? edges.last { e.route = last.route; e.color = last.color; e.width = last.width; e.head = last.head }
        edges.append(e); sel = []; selEdge = e.id; return e.id
    }
    func deleteSelection() {
        if let e = selEdge { edges.removeAll { $0.id == e }; selEdge = nil; return }
        guard !sel.isEmpty else { return }
        let ids = sel; nodes.removeAll { ids.contains($0.id) }; edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }; sel = []; editing = nil
    }
    func move(_ ids: Set<Int>, dx: Double, dy: Double) { for i in nodes.indices where ids.contains(nodes[i].id) { nodes[i].x += dx; nodes[i].y += dy } }
    func style(_ f: (inout DNode) -> Void) { for i in nodes.indices where sel.contains(nodes[i].id) { f(&nodes[i]) } }
    func edgeStyle(_ f: (inout DEdge) -> Void) {
        if let id = selEdge, let i = edges.firstIndex(where: { $0.id == id }) { f(&edges[i]) }
        else { for i in edges.indices where sel.contains(edges[i].from) || sel.contains(edges[i].to) { f(&edges[i]) } }
    }
    func setText(_ id: Int, _ t: String) { if let i = index(id) { nodes[i].text = t } }
    func resizeToFit() { style { DText.fit(&$0) } }

    func duplicate() {
        guard !sel.isEmpty else { return }
        let src = selectedNodes; var map: [Int: Int] = [:], next = nextNodeId
        var copies: [DNode] = []; for var n in src { map[n.id] = next; n.id = next; n.x += 30; n.y += 30; next += 1; copies.append(n) }
        var eid = nextEdgeId; var newEdges: [DEdge] = []
        for var e in edges where map[e.from] != nil && map[e.to] != nil { e.id = eid; e.from = map[e.from]!; e.to = map[e.to]!; eid += 1; newEdges.append(e) }
        nodes += copies; edges += newEdges; sel = Set(copies.map(\.id)); selEdge = nil
    }
    func copy() {
        let ids = sel; guard !ids.isEmpty else { return }
        Self.clip = DiagramState(nodes: nodes.filter { ids.contains($0.id) }, edges: edges.filter { ids.contains($0.from) && ids.contains($0.to) })
    }
    func cut() { copy(); deleteSelection() }
    func paste() {
        guard let c = Self.clip else { return }
        var map: [Int: Int] = [:], next = nextNodeId, copies: [DNode] = []
        for var n in c.nodes { map[n.id] = next; n.id = next; n.x += 30; n.y += 30; next += 1; copies.append(n) }
        var eid = nextEdgeId, newEdges: [DEdge] = []
        for var e in c.edges { e.id = eid; e.from = map[e.from] ?? e.from; e.to = map[e.to] ?? e.to; eid += 1; newEdges.append(e) }
        nodes += copies; edges += newEdges; sel = Set(copies.map(\.id)); selEdge = nil
        DiagramModel.clip = DiagramState(nodes: copies, edges: newEdges)            // a repeated paste keeps stepping along
    }
    func bringToFront() { let ids = sel; nodes = nodes.filter { !ids.contains($0.id) } + nodes.filter { ids.contains($0.id) } }
    func sendToBack() { let ids = sel; nodes = nodes.filter { ids.contains($0.id) } + nodes.filter { !ids.contains($0.id) } }

    enum Align { case left, centre, right, top, middle, bottom }
    func align(_ a: Align) {
        let s = selectedNodes; guard s.count > 1 else { return }
        let minX = s.map(\.x).min()!, maxX = s.map { $0.x + $0.w }.max()!, minY = s.map(\.y).min()!, maxY = s.map { $0.y + $0.h }.max()!
        style { n in switch a { case .left: n.x = minX; case .right: n.x = maxX - n.w; case .centre: n.x = (minX + maxX) / 2 - n.w / 2; case .top: n.y = minY; case .bottom: n.y = maxY - n.h; case .middle: n.y = (minY + maxY) / 2 - n.h / 2 } }
    }
    func distribute(horizontal: Bool) {
        let s = selectedNodes.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }; guard s.count > 2 else { return }
        let total = horizontal ? (s.last!.x + s.last!.w - s.first!.x) : (s.last!.y + s.last!.h - s.first!.y)
        let used = s.map { horizontal ? $0.w : $0.h }.reduce(0, +), gap = (total - used) / Double(s.count - 1)
        var pos = horizontal ? s.first!.x : s.first!.y
        for n in s { if let i = index(n.id) { if horizontal { nodes[i].x = pos } else { nodes[i].y = pos }; pos += (horizontal ? n.w : n.h) + gap } }
    }

    // MARK: layout and text import
    enum LayoutKind { case down, right, radial }
    func autoLayout(_ k: LayoutKind) {
        guard !nodes.isEmpty else { return }
        let origin = CGPoint(x: nodes.map(\.x).min() ?? 0, y: nodes.map(\.y).min() ?? 0)
        let pos: [Int: CGPoint]
        switch k { case .down: pos = DLayout.layered(nodes, edges, horizontal: false); case .right: pos = DLayout.layered(nodes, edges, horizontal: true); case .radial: pos = DLayout.radial(nodes, edges, root: sel.first) }
        for i in nodes.indices { if let p = pos[nodes[i].id] { nodes[i].x = p.x + origin.x; nodes[i].y = p.y + origin.y } }
        for i in edges.indices where edges[i].fromSide != .auto || edges[i].toSide != .auto { edges[i].fromSide = .auto; edges[i].toSide = .auto }
        if k == .radial { for i in edges.indices { edges[i].route = "curve"; edges[i].head = "none" } }
        else { edges = DLayout.routeBackEdges(nodes, edges, horizontal: k == .right) }
        fit()
    }
    /// Adds parsed shapes and connectors, laid out, to the right of what's already there (or replaces everything).
    func insert(_ p: DParsed, replace: Bool, layout: LayoutKind) {
        guard !p.nodes.isEmpty else { return }
        var ns = p.nodes, es = p.edges
        let pos = layout == .radial ? DLayout.radial(ns, es) : DLayout.layered(ns, es, horizontal: layout == .right)
        var base = CGPoint(x: 0, y: 0)
        if !replace, let r = nodes.map(\.frame).reduce(nil as CGRect?, { $0 == nil ? $1 : $0!.union($1) }) { base = CGPoint(x: r.maxX + 80, y: r.minY) }
        let nOff = replace ? 0 : (nodes.map(\.id).max() ?? 0), eOff = replace ? 0 : (edges.map(\.id).max() ?? 0)
        for i in ns.indices { let q = pos[ns[i].id] ?? .zero; ns[i].x = q.x + base.x; ns[i].y = q.y + base.y; ns[i].id += nOff }
        for i in es.indices { es[i].id += eOff; es[i].from += nOff; es[i].to += nOff }
        if layout != .radial { es = DLayout.routeBackEdges(ns, es, horizontal: layout == .right) }
        if replace { nodes = ns; edges = es } else { nodes += ns; edges += es }
        sel = Set(ns.map(\.id)); selEdge = nil; fit()
    }

    // MARK: view
    func bounds() -> CGRect? { nodes.map(\.frame).reduce(nil as CGRect?) { $0 == nil ? $1 : $0!.union($1) } }
    func fit() {
        guard let r = bounds() else { zoom = 1; offset = CGPoint(x: 80, y: 80); return }
        let pad = 70.0, z = min(1.25, max(0.1, min((viewSize.width - pad * 2) / max(r.width, 1), (viewSize.height - pad * 2) / max(r.height, 1))))
        zoom = z; offset = CGPoint(x: viewSize.width / 2 - r.midX * z, y: viewSize.height / 2 - r.midY * z)
    }
    func setZoom(_ z: Double, around v: CGPoint? = nil) {
        let c = v ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), m = toModel(c), nz = min(4, max(0.1, z))
        zoom = nz; offset = CGPoint(x: c.x - m.x * nz, y: c.y - m.y * nz)
    }

    /// Alignment guides and grid snapping while moving `ids` by a raw delta; returns the adjusted delta.
    func snapDelta(_ ids: Set<Int>, start: [Int: CGPoint], dx: Double, dy: Double) -> (Double, Double) {
        var dx = dx, dy = dy; guides = []
        let moving = nodes.filter { ids.contains($0.id) }; guard !moving.isEmpty else { return (dx, dy) }
        var r = CGRect.null; for n in moving { let s = start[n.id] ?? CGPoint(x: n.x, y: n.y); r = r.union(CGRect(x: s.x + dx, y: s.y + dy, width: n.w, height: n.h)) }
        let tol = 6 / zoom, others = nodes.filter { !ids.contains($0.id) }
        var bx: (d: Double, g: Double)?, by: (d: Double, g: Double)?
        for o in others { for (m, t) in [(r.minX, o.x), (r.minX, o.x + o.w), (r.midX, o.center.x), (r.maxX, o.x), (r.maxX, o.x + o.w)] { let d = t - m; if abs(d) < tol && abs(d) < abs(bx?.d ?? .infinity) { bx = (d, t) } }
            for (m, t) in [(r.minY, o.y), (r.minY, o.y + o.h), (r.midY, o.center.y), (r.maxY, o.y), (r.maxY, o.y + o.h)] { let d = t - m; if abs(d) < tol && abs(d) < abs(by?.d ?? .infinity) { by = (d, t) } } }
        if let b = bx { dx += b.d; guides.append((true, b.g)) } else if snap, let f = moving.first { let s = start[f.id] ?? .zero; dx = ((s.x + dx) / Self.gridSize).rounded() * Self.gridSize - s.x }
        if let b = by { dy += b.d; guides.append((false, b.g)) } else if snap, let f = moving.first { let s = start[f.id] ?? .zero; dy = ((s.y + dy) / Self.gridSize).rounded() * Self.gridSize - s.y }
        return (dx, dy)
    }

    // MARK: export
    func svg() -> String { DSVG.svg(nodes, edges) }
    func exportSVG() { guard let u = savePanel((title.isEmpty ? "diagram" : title) + ".svg") else { return }; try? svg().write(to: u, atomically: true, encoding: .utf8); status = "Exported \(u.lastPathComponent)" }
    @MainActor func exportPNG() {
        guard let u = savePanel((title.isEmpty ? "diagram" : title) + ".png") else { return }
        let r = ImageRenderer(content: DiagramExportView(nodes: nodes, edges: edges)); r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: u); status = "Exported \(u.lastPathComponent)" }
    }
    @MainActor func exportPDF() {
        guard let u = savePanel((title.isEmpty ? "diagram" : title) + ".pdf") else { return }
        let r = ImageRenderer(content: DiagramExportView(nodes: nodes, edges: edges))
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        status = "Exported \(u.lastPathComponent)"
    }
}
