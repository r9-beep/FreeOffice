// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CoreGraphics
import SwiftUI

// Diagrams engine: a graph of nodes and connectors that stay attached, plus routing, auto-layout, a text format and SVG output.
// Pure Foundation/CoreGraphics so it can be tested without any UI.

enum Side: String, Codable { case auto, top, right, bottom, left }

struct DNode: Codable, Identifiable, Equatable {
    var id: Int
    var shape = "rect"          // rect round pill ellipse diamond parallelogram hexagon cylinder document note triangle text
    var x = 0.0, y = 0.0, w = 140.0, h = 64.0
    var text = ""
    var fill = "#ffffff", stroke = "#1d1d1f", color = "#1d1d1f"
    var size = 15.0, sw = 1.5
    var bold = false, italic = false, dash = false
    var src = ""                // image: a data URL · icon: an SF Symbol name

    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }
    init(id: Int, shape: String = "rect", x: Double = 0, y: Double = 0, w: Double? = nil, h: Double? = nil, text: String = "") {
        self.id = id; self.shape = shape; self.x = x; self.y = y; self.text = text
        let d = DShapes.defaultSize(shape); self.w = w ?? d.w; self.h = h ?? d.h
        if shape == "text" { stroke = "#00000000"; fill = "#00000000" }
    }
    enum CodingKeys: String, CodingKey { case id, shape, x, y, w, h, text, fill, stroke, color, size, sw, bold, italic, dash, src }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = try c.decode(Int.self, forKey: .id)
        shape = v(.shape, "rect"); x = v(.x, 0); y = v(.y, 0); w = v(.w, 140); h = v(.h, 64); text = v(.text, "")
        fill = v(.fill, "#ffffff"); stroke = v(.stroke, "#1d1d1f"); color = v(.color, "#1d1d1f"); size = v(.size, 15); sw = v(.sw, 1.5)
        bold = v(.bold, false); italic = v(.italic, false); dash = v(.dash, false); src = v(.src, "")
    }
}

struct DEdge: Codable, Identifiable, Equatable {
    var id: Int
    var from: Int, to: Int
    var fromSide = Side.auto, toSide = Side.auto
    var route = "ortho"         // ortho | straight | curve
    var head = "arrow", tail = "none"   // arrow | open | dot | diamond | none
    var dash = false
    var color = "#1d1d1f"
    var width = 1.5
    var label = ""
    var bend = 0.0              // shifts the middle segment of an elbow connector
    init(id: Int, from: Int, to: Int) { self.id = id; self.from = from; self.to = to }
    enum CodingKeys: String, CodingKey { case id, from, to, fromSide, toSide, route, head, tail, dash, color, width, label, bend }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = try c.decode(Int.self, forKey: .id); from = try c.decode(Int.self, forKey: .from); to = try c.decode(Int.self, forKey: .to)
        fromSide = v(.fromSide, Side.auto); toSide = v(.toSide, Side.auto); route = v(.route, "ortho"); head = v(.head, "arrow"); tail = v(.tail, "none")
        dash = v(.dash, false); color = v(.color, "#1d1d1f"); width = v(.width, 1.5); label = v(.label, ""); bend = v(.bend, 0)
    }
}

// MARK: - Shapes

enum DShapes {
    static let all: [(id: String, name: String)] = [("rect", "Box"), ("round", "Rounded"), ("pill", "Pill"), ("ellipse", "Ellipse"), ("diamond", "Decision"), ("parallelogram", "Data"),
                                                     ("hexagon", "Hexagon"), ("cylinder", "Database"), ("document", "Document"), ("note", "Note"), ("triangle", "Triangle"), ("text", "Text")]
    static func defaultSize(_ s: String) -> (w: Double, h: Double) {
        switch s { case "diamond": return (150, 90); case "ellipse": return (140, 80); case "cylinder": return (110, 84); case "triangle": return (110, 90); case "text": return (120, 36); case "image": return (240, 160); case "icon": return (64, 64); case "pill": return (150, 52); case "note": return (150, 100)
        default: return (140, 64) }
    }
    static func path(_ shape: String, _ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        switch shape {
        case "round": p.addRoundedRect(in: r, cornerWidth: 14, cornerHeight: 14)
        case "pill": p.addRoundedRect(in: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2)
        case "ellipse": p.addEllipse(in: r)
        case "diamond": p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]); p.closeSubpath()
        case "parallelogram": let k = min(26, r.width * 0.18)
            p.addLines(between: [CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - k, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]); p.closeSubpath()
        case "hexagon": let k = min(26, r.width * 0.2)
            p.addLines(between: [CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX - k, y: r.maxY), CGPoint(x: r.minX + k, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]); p.closeSubpath()
        case "cylinder":
            let ry = min(14, r.height * 0.2), k = 0.5523 * ry, mx = r.midX, rx = r.width / 2
            p.move(to: CGPoint(x: r.minX, y: r.minY + ry)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - ry))
            p.addCurve(to: CGPoint(x: mx, y: r.maxY), control1: CGPoint(x: r.minX, y: r.maxY - ry + k), control2: CGPoint(x: mx - 0.5523 * rx, y: r.maxY))
            p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - ry), control1: CGPoint(x: mx + 0.5523 * rx, y: r.maxY), control2: CGPoint(x: r.maxX, y: r.maxY - ry + k))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + ry))
            p.addCurve(to: CGPoint(x: mx, y: r.minY + 2 * ry), control1: CGPoint(x: r.maxX, y: r.minY + ry + k), control2: CGPoint(x: mx + 0.5523 * rx, y: r.minY + 2 * ry))
            p.addCurve(to: CGPoint(x: r.minX, y: r.minY + ry), control1: CGPoint(x: mx - 0.5523 * rx, y: r.minY + 2 * ry), control2: CGPoint(x: r.minX, y: r.minY + ry + k))
            p.closeSubpath(); p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: 2 * ry))
        case "document":
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 10))
            p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - 10), control1: CGPoint(x: r.minX + r.width * 0.75, y: r.maxY - 26), control2: CGPoint(x: r.minX + r.width * 0.25, y: r.maxY + 6)); p.closeSubpath()
        case "note": let k = 18.0
            p.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.minY + k), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]); p.closeSubpath()
            p.move(to: CGPoint(x: r.maxX - k, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY + k)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + k))
        case "triangle": p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]); p.closeSubpath()
        case "text": break
        default: p.addRect(r)
        }
        return p
    }
    static func svgPath(_ cg: CGPath) -> String {
        var d = ""
        cg.applyWithBlock { e in
            let p = e.pointee.points
            func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
            switch e.pointee.type {
            case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y)) "
            case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y)) "
            case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) "
            case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y)) "
            case .closeSubpath: d += "Z "
            @unknown default: break
            }
        }
        return d
    }
}

// MARK: - Geometry and routing

struct DRoute {
    var pts: [CGPoint]                                   // polyline (for curves, a fine sampling of the bezier)
    var bezier: (CGPoint, CGPoint, CGPoint, CGPoint)?    // set for curved connectors
    var startDir: CGPoint, endDir: CGPoint               // unit vectors pointing along the line at each end (towards the tip)
    var mid: CGPoint { DGeo.pointAlong(pts, 0.5) }
}

func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func * (a: CGPoint, k: Double) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

enum DGeo {
    static func normal(_ s: Side) -> CGPoint {
        switch s { case .top: return CGPoint(x: 0, y: -1); case .bottom: return CGPoint(x: 0, y: 1); case .left: return CGPoint(x: -1, y: 0); case .right: return CGPoint(x: 1, y: 0); case .auto: return .zero }
    }
    static func port(_ n: DNode, _ s: Side) -> CGPoint {
        switch s { case .top: return CGPoint(x: n.x + n.w / 2, y: n.y); case .bottom: return CGPoint(x: n.x + n.w / 2, y: n.y + n.h)
        case .left: return CGPoint(x: n.x, y: n.y + n.h / 2); case .right: return CGPoint(x: n.x + n.w, y: n.y + n.h / 2); case .auto: return n.center }
    }
    static func autoSides(_ a: DNode, _ b: DNode) -> (Side, Side) {
        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
        if abs(dx) / (a.w + b.w) > abs(dy) / (a.h + b.h) { return dx >= 0 ? (.right, .left) : (.left, .right) }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }
    /// The side of `n` closest to a point (used when dropping a connector on a shape).
    static func nearestSide(_ n: DNode, to p: CGPoint) -> Side {
        let dx = (p.x - n.center.x) / max(n.w, 1), dy = (p.y - n.center.y) / max(n.h, 1)
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .bottom : .top)
    }
    static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint { let d = max(dist(a, b), 0.0001); return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d) }

    /// Where a line from the node's centre towards `p` leaves the shape's outline.
    static func clip(_ n: DNode, toward p: CGPoint) -> CGPoint {
        let c = n.center, dx = p.x - c.x, dy = p.y - c.y
        if abs(dx) < 0.0001 && abs(dy) < 0.0001 { return c }
        let hw = n.w / 2, hh = n.h / 2
        let t: Double
        switch n.shape {
        case "ellipse": t = 1 / sqrt((dx * dx) / (hw * hw) + (dy * dy) / (hh * hh))
        case "diamond": t = 1 / (abs(dx) / hw + abs(dy) / hh)
        default: t = min(abs(dx) > 0.0001 ? hw / abs(dx) : .infinity, abs(dy) > 0.0001 ? hh / abs(dy) : .infinity)
        }
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    static func route(_ e: DEdge, _ a: DNode, _ b: DNode) -> DRoute {
        if a.id == b.id {                                   // a loop back to the same shape
            let r = a.x + a.w, cy = a.y + a.h / 2, t = a.y, cx = a.x + a.w / 2
            let pts = [CGPoint(x: r, y: cy), CGPoint(x: r + 34, y: cy), CGPoint(x: r + 34, y: t - 30), CGPoint(x: cx, y: t - 30), CGPoint(x: cx, y: t)]
            return DRoute(pts: pts, bezier: nil, startDir: CGPoint(x: 1, y: 0), endDir: CGPoint(x: 0, y: 1))
        }
        var (sa, sb) = autoSides(a, b)
        if e.fromSide != .auto { sa = e.fromSide }
        if e.toSide != .auto { sb = e.toSide }
        if e.route == "straight" && e.fromSide == .auto && e.toSide == .auto {
            let p0 = clip(a, toward: b.center), p1 = clip(b, toward: a.center)
            let u = unit(p0, p1); return DRoute(pts: [p0, p1], bezier: nil, startDir: u, endDir: u)
        }
        let p0 = port(a, sa), p1 = port(b, sb), n0 = normal(sa), n1 = normal(sb)
        if e.route == "straight" { let u = unit(p0, p1); return DRoute(pts: [p0, p1], bezier: nil, startDir: u, endDir: u) }
        if e.route == "curve" {
            let k = max(40, dist(p0, p1) / 3), c1 = p0 + n0 * k, c2 = p1 + n1 * k
            var pts: [CGPoint] = []
            for i in 0...28 { let t = Double(i) / 28, u = 1 - t
                pts.append(CGPoint(x: u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p1.x, y: u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p1.y)) }
            return DRoute(pts: pts, bezier: (p0, c1, c2, p1), startDir: unit(p0, c1), endDir: unit(c2, p1))
        }
        let pts = ortho(p0, n0, p1, n1, bend: e.bend)
        let sd = pts.count > 1 ? unit(pts[0], pts[1]) : n0, ed = pts.count > 1 ? unit(pts[pts.count - 2], pts[pts.count - 1]) : n1
        return DRoute(pts: pts, bezier: nil, startDir: sd, endDir: ed)
    }

    static func ortho(_ p0: CGPoint, _ n0: CGPoint, _ p1: CGPoint, _ n1: CGPoint, bend: Double) -> [CGPoint] {
        let stub = 26.0, s0 = p0 + n0 * stub, s1 = p1 + n1 * stub
        let h0 = n0.x != 0, h1 = n1.x != 0
        var pts: [CGPoint]
        if h0 && h1 {
            if n0.x * (p1.x - p0.x) > 0 && n1.x * (p0.x - p1.x) > 0 { let mx = (p0.x + p1.x) / 2 + bend; pts = [p0, CGPoint(x: mx, y: p0.y), CGPoint(x: mx, y: p1.y), p1] }
            else { let mx = (n0.x == n1.x ? (n0.x > 0 ? max(s0.x, s1.x) : min(s0.x, s1.x)) : (s0.x + s1.x) / 2) + bend; pts = [p0, s0, CGPoint(x: mx, y: s0.y), CGPoint(x: mx, y: s1.y), s1, p1] }
        } else if !h0 && !h1 {
            if n0.y * (p1.y - p0.y) > 0 && n1.y * (p0.y - p1.y) > 0 { let my = (p0.y + p1.y) / 2 + bend; pts = [p0, CGPoint(x: p0.x, y: my), CGPoint(x: p1.x, y: my), p1] }
            else { let my = (n0.y == n1.y ? (n0.y > 0 ? max(s0.y, s1.y) : min(s0.y, s1.y)) : (s0.y + s1.y) / 2) + bend; pts = [p0, s0, CGPoint(x: s0.x, y: my), CGPoint(x: s1.x, y: my), s1, p1] }
        } else if h0 {
            if n0.x * (p1.x - p0.x) > 0 && n1.y * (p0.y - p1.y) > 0 { pts = [p0, CGPoint(x: p1.x, y: p0.y), p1] }
            else { pts = [p0, s0, CGPoint(x: s0.x, y: s1.y), s1, p1] }
        } else {
            if n0.y * (p1.y - p0.y) > 0 && n1.x * (p0.x - p1.x) > 0 { pts = [p0, CGPoint(x: p0.x, y: p1.y), p1] }
            else { pts = [p0, s0, CGPoint(x: s1.x, y: s0.y), s1, p1] }
        }
        return cleaned(pts)
    }
    static func cleaned(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts { if let l = out.last, dist(l, p) < 0.5 { continue }; out.append(p) }
        var i = 1
        while i < out.count - 1 {
            let a = out[i - 1], b = out[i], c = out[i + 1]
            if (abs(a.x - b.x) < 0.5 && abs(b.x - c.x) < 0.5) || (abs(a.y - b.y) < 0.5 && abs(b.y - c.y) < 0.5) { out.remove(at: i) } else { i += 1 }
        }
        return out
    }
    static func length(_ pts: [CGPoint]) -> Double { zip(pts, pts.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) } }
    static func pointAlong(_ pts: [CGPoint], _ t: Double) -> CGPoint {
        guard pts.count > 1 else { return pts.first ?? .zero }
        var want = length(pts) * t
        for (a, b) in zip(pts, pts.dropFirst()) { let d = dist(a, b); if want <= d { let k = d == 0 ? 0 : want / d; return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k) }; want -= d }
        return pts.last!
    }
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        if l2 == 0 { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)); return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
    static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> Double { zip(pts, pts.dropFirst()).map { distance(p, toSegment: $0.0, $0.1) }.min() ?? .infinity }

    /// End decorations: polygon points (filled or open) or a circle, with the tip at `tip` and the line arriving along `dir`.
    static func head(_ kind: String, tip: CGPoint, dir: CGPoint, size: Double) -> (pts: [CGPoint], filled: Bool, circle: CGRect?) {
        let s = size, back = CGPoint(x: tip.x - dir.x * s, y: tip.y - dir.y * s), perp = CGPoint(x: -dir.y, y: dir.x)
        switch kind {
        case "arrow": return ([tip, CGPoint(x: back.x + perp.x * s * 0.45, y: back.y + perp.y * s * 0.45), CGPoint(x: back.x - perp.x * s * 0.45, y: back.y - perp.y * s * 0.45)], true, nil)
        case "open": return ([CGPoint(x: back.x + perp.x * s * 0.5, y: back.y + perp.y * s * 0.5), tip, CGPoint(x: back.x - perp.x * s * 0.5, y: back.y - perp.y * s * 0.5)], false, nil)
        case "diamond": let mid = CGPoint(x: tip.x - dir.x * s * 0.6, y: tip.y - dir.y * s * 0.6), far = CGPoint(x: tip.x - dir.x * s * 1.2, y: tip.y - dir.y * s * 1.2)
            return ([tip, CGPoint(x: mid.x + perp.x * s * 0.4, y: mid.y + perp.y * s * 0.4), far, CGPoint(x: mid.x - perp.x * s * 0.4, y: mid.y - perp.y * s * 0.4)], true, nil)
        case "dot": let r = s * 0.35, c = CGPoint(x: tip.x - dir.x * r, y: tip.y - dir.y * r); return ([], true, CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        default: return ([], false, nil)
        }
    }
}

// MARK: - Auto layout

enum DLayout {
    /// Layered layout (flowcharts, org charts, trees). Returns each node's new top-left, normalised so the diagram starts at (0, 0).
    static func layered(_ nodes: [DNode], _ edges: [DEdge], horizontal: Bool, gapMain: Double = 90, gapCross: Double = 36) -> [Int: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let ids = nodes.map(\.id), known = Set(ids)
        var succ: [Int: [Int]] = [:], pred: [Int: [Int]] = [:]
        for e in edges where e.from != e.to && known.contains(e.from) && known.contains(e.to) && !(succ[e.from]?.contains(e.to) ?? false) { succ[e.from, default: []].append(e.to) }
        // break cycles: drop edges that point back to a node still on the DFS stack
        var state: [Int: Int] = [:]   // 1 = visiting, 2 = done
        var dag: [Int: [Int]] = [:]
        func dfs(_ v: Int) { state[v] = 1; for w in succ[v] ?? [] { if state[w] == 1 { continue }; dag[v, default: []].append(w); if state[w] == nil { dfs(w) } }; state[v] = 2 }
        let hasIn = Set(succ.values.flatMap { $0 })
        for v in ids where !hasIn.contains(v) && state[v] == nil { dfs(v) }
        for v in ids where state[v] == nil { dfs(v) }
        for (v, ws) in dag { for w in ws { pred[w, default: []].append(v) } }
        // longest-path layering
        var layerOf: [Int: Int] = [:]
        func layer(_ v: Int) -> Int { if let l = layerOf[v] { return l }; let l = (pred[v] ?? []).map { layer($0) + 1 }.max() ?? 0; layerOf[v] = l; return l }
        for v in ids { _ = layer(v) }
        let maxL = layerOf.values.max() ?? 0
        var layers: [[Int]] = Array(repeating: [], count: maxL + 1)
        for v in ids { layers[layerOf[v]!].append(v) }
        // reduce crossings: barycentre sweeps
        func index() -> [Int: Double] { var m: [Int: Double] = [:]; for l in layers { for (i, v) in l.enumerated() { m[v] = Double(i) } }; return m }
        for sweep in 0..<6 {
            let down = sweep % 2 == 0
            for li in (down ? Array(1...max(maxL, 1)) : Array((0..<max(maxL, 1)).reversed())) where li <= maxL {
                let pos = index()
                let neighbours: (Int) -> [Int] = { down ? (pred[$0] ?? []) : (dag[$0] ?? []) }
                let keyed = layers[li].enumerated().map { (i, v) -> (Int, Double) in let ns = neighbours(v); return (v, ns.isEmpty ? Double(i) : ns.map { pos[$0] ?? 0 }.reduce(0, +) / Double(ns.count)) }
                layers[li] = keyed.enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1 }.map { $0.element.0 }
            }
        }
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        func main(_ v: Int) -> Double { horizontal ? byId[v]!.w : byId[v]!.h }
        func cross(_ v: Int) -> Double { horizontal ? byId[v]!.h : byId[v]!.w }
        // main-axis position per layer
        var mainPos: [Double] = [], acc = 0.0
        for l in layers { let size = l.map(main).max() ?? 0; mainPos.append(acc); acc += size + gapMain }
        // cross-axis: sequential, centred, then pulled towards neighbours without overlapping
        var c: [Int: Double] = [:]
        for l in layers { var x = 0.0; for v in l { c[v] = x + cross(v) / 2; x += cross(v) + gapCross }; let total = x - gapCross; for v in l { c[v]! -= total / 2 } }
        func settle(_ order: [Int], neighbours: (Int) -> [Int]) {
            for li in order {
                let l = layers[li]; if l.isEmpty { continue }
                let want = l.map { v -> Double in let ns = neighbours(v); return ns.isEmpty ? c[v]! : ns.map { c[$0]! }.reduce(0, +) / Double(ns.count) }
                var fwd = want, bwd = want
                for i in 0..<l.count where i > 0 { fwd[i] = max(want[i], fwd[i - 1] + cross(l[i - 1]) / 2 + gapCross + cross(l[i]) / 2) }
                for i in (0..<l.count - 1).reversed() { bwd[i] = min(want[i], bwd[i + 1] - cross(l[i + 1]) / 2 - gapCross - cross(l[i]) / 2) }
                for (i, v) in l.enumerated() { c[v] = (fwd[i] + bwd[i]) / 2 }
            }
        }
        settle(Array(1...max(maxL, 1)).filter { $0 <= maxL }, neighbours: { pred[$0] ?? [] })
        settle(Array((0..<max(maxL, 1)).reversed()).filter { $0 <= maxL }, neighbours: { dag[$0] ?? [] })
        settle(Array(1...max(maxL, 1)).filter { $0 <= maxL }, neighbours: { pred[$0] ?? [] })
        var out: [Int: CGPoint] = [:]
        for (li, l) in layers.enumerated() { for v in l { out[v] = horizontal ? CGPoint(x: mainPos[li], y: c[v]! - cross(v) / 2) : CGPoint(x: c[v]! - cross(v) / 2, y: mainPos[li]) } }
        let minX = out.values.map(\.x).min() ?? 0, minY = out.values.map(\.y).min() ?? 0
        return out.mapValues { CGPoint(x: $0.x - minX, y: $0.y - minY) }
    }

    /// Connectors that run against the flow (a loop back up the page) swing round the side instead of cutting through shapes.
    static func routeBackEdges(_ nodes: [DNode], _ edges: [DEdge], horizontal: Bool) -> [DEdge] {
        let by = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return edges.map { e in
            var e = e
            guard e.from != e.to, e.route == "ortho", let a = by[e.from], let b = by[e.to] else { return e }
            let back = horizontal ? b.center.x < a.center.x - 1 : b.center.y < a.center.y - 1
            if back { let s: Side = horizontal ? .bottom : .right; e.fromSide = s; e.toSide = s }
            else if e.fromSide != .auto && e.fromSide == e.toSide { e.fromSide = .auto; e.toSide = .auto }
            return e
        }
    }

    /// Mind-map layout: the root in the middle, branches fanning out in rings.
    static func radial(_ nodes: [DNode], _ edges: [DEdge], root: Int? = nil) -> [Int: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        var adj: [Int: [Int]] = [:]
        for e in edges where e.from != e.to { adj[e.from, default: []].append(e.to); adj[e.to, default: []].append(e.from) }
        let hasIn = Set(edges.map(\.to))
        let rootId = root ?? nodes.first(where: { !hasIn.contains($0.id) })?.id ?? nodes[0].id
        var children: [Int: [Int]] = [:], depth: [Int: Int] = [rootId: 0], queue = [rootId], order = [rootId]
        while !queue.isEmpty { let v = queue.removeFirst(); for w in adj[v] ?? [] where depth[w] == nil { depth[w] = depth[v]! + 1; children[v, default: []].append(w); queue.append(w); order.append(w) } }
        var leaves: [Int: Double] = [:]
        for v in order.reversed() { let cs = children[v] ?? []; leaves[v] = cs.isEmpty ? 1 : cs.map { leaves[$0]! }.reduce(0, +) }
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let ring = (nodes.map(\.w).max() ?? 140) + 70
        var centre: [Int: CGPoint] = [rootId: .zero]
        func place(_ v: Int, _ a0: Double, _ a1: Double) {
            var a = a0; let total = leaves[v]!
            for w in children[v] ?? [] { let span = (a1 - a0) * leaves[w]! / total, mid = a + span / 2, r = Double(depth[w]!) * ring
                centre[w] = CGPoint(x: r * cos(mid), y: r * sin(mid) * 0.8); place(w, a, a + span); a += span }
        }
        place(rootId, -Double.pi / 2 - 0.0, 3 * Double.pi / 2)
        var out: [Int: CGPoint] = [:]
        for (v, p) in centre { let n = byId[v]!; out[v] = CGPoint(x: p.x - n.w / 2, y: p.y - n.h / 2) }
        var extra = (out.values.map { $0.y }.max() ?? 0) + 120
        for n in nodes where out[n.id] == nil { out[n.id] = CGPoint(x: Double(out.count) * 20, y: extra); extra += n.h + 20 }
        let minX = out.values.map(\.x).min() ?? 0, minY = out.values.map(\.y).min() ?? 0
        return out.mapValues { CGPoint(x: $0.x - minX, y: $0.y - minY) }
    }
}

// MARK: - Text formats (a Mermaid-style flowchart subset, and indented outlines)

struct DParsed { var nodes: [DNode] = []; var edges: [DEdge] = []; var horizontal = false }

enum DText {
    static let palette = ["#cfe0ff", "#c8f0d4", "#ffd9b3", "#ffc9c4", "#e3d6ff", "#fff3b0", "#d3f0f5"]

    static func fit(_ n: inout DNode) {
        let lines = n.text.components(separatedBy: "\n"), longest = Double(lines.map(\.count).max() ?? 0)
        var w = max(110, longest * n.size * 0.58 + 36), h = max(52, Double(lines.count) * (n.size + 5) + 28)
        switch n.shape {
        case "diamond": w *= 1.35; h *= 1.5
        case "ellipse": w *= 1.15; h *= 1.2
        case "cylinder": h += 16
        case "hexagon", "parallelogram": w += 30
        case "text": w = max(40, longest * n.size * 0.58 + 12); h = max(28, Double(lines.count) * (n.size + 5) + 8)
        default: break
        }
        n.w = (w / 10).rounded(.up) * 10; n.h = (h / 10).rounded(.up) * 10
    }

    /// `flowchart LR` / `A[Box] --> B(Round) -->|label| C{Decision}`; also `-.->` dashed, `==>` thick, `---` no arrow, `((circle))`, `([pill])`, `[(database)]`, `{{hexagon}}`, `[/data/]`.
    static func parseFlow(_ text: String) -> DParsed {
        var out = DParsed(), index: [String: Int] = [:], nextId = 1
        func ensure(_ key: String, text t: String?, shape: String?) -> Int {
            if let i = index[key] { if let t = t { out.nodes[i].text = t }; if let s = shape { out.nodes[i].shape = s }; return i }
            var n = DNode(id: nextId, shape: shape ?? "rect", text: t ?? key); nextId += 1; out.nodes.append(n); index[key] = out.nodes.count - 1; n = out.nodes[index[key]!]; return index[key]!
        }
        let arrowRE = try! NSRegularExpression(pattern: "^(<)?(-{2,}>?|-\\.+-?>?|={2,}>?)")
        let openers: [(String, String, String)] = [("((", "))", "ellipse"), ("([", "])", "pill"), ("[(", ")]", "cylinder"), ("{{", "}}", "hexagon"), ("[/", "/]", "parallelogram"), ("[", "]", "rect"), ("(", ")", "round"), ("{", "}", "diamond")]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let low = line.lowercased()
            if low.hasPrefix("flowchart") || low.hasPrefix("graph") { out.horizontal = low.hasSuffix("lr") || low.hasSuffix("rl"); continue }
            let c = Array(line); var i = 0, prev: Int?
            var pendingArrow: (dash: Bool, thick: Bool, head: Bool, tail: Bool)?, pendingLabel = ""
            func skipSpace() { while i < c.count && c[i] == " " { i += 1 } }
            while i < c.count {
                skipSpace(); if i >= c.count { break }
                if c[i] == "&" || c[i] == ";" { i += 1; continue }
                // arrow?
                let rest = String(c[i...])
                if prev != nil, let m = arrowRE.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                    let tok = (rest as NSString).substring(with: m.range)
                    pendingArrow = (tok.contains("."), tok.contains("="), tok.hasSuffix(">"), tok.hasPrefix("<")); i += tok.count; skipSpace()
                    if i < c.count && c[i] == "|" { var j = i + 1; var s = ""; while j < c.count && c[j] != "|" { s.append(c[j]); j += 1 }; pendingLabel = s.trimmingCharacters(in: .whitespaces); i = min(j + 1, c.count) }
                    continue
                }
                // node
                var key = ""; while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" { key.append(c[i]); i += 1 }
                if key.isEmpty { i += 1; continue }
                var label: String?, shape: String?
                let tail = String(c[i...])
                for (o, cl, sh) in openers where tail.hasPrefix(o) {
                    let body = String(tail.dropFirst(o.count)); if let r = body.range(of: cl) { label = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "<br>", with: "\n"); shape = sh; i += o.count + body.distance(from: body.startIndex, to: r.upperBound); break }
                }
                let ni = ensure(key, text: label, shape: shape)
                if let p = prev, let a = pendingArrow {
                    var e = DEdge(id: out.edges.count + 1, from: out.nodes[p].id, to: out.nodes[ni].id)
                    e.dash = a.dash; e.width = a.thick ? 3 : 1.5; e.head = a.head ? "arrow" : "none"; e.tail = a.tail ? "arrow" : "none"; e.label = pendingLabel; out.edges.append(e)
                }
                pendingArrow = nil; pendingLabel = ""; prev = ni
            }
        }
        for i in out.nodes.indices {
            fit(&out.nodes[i])
            switch out.nodes[i].shape { case "pill": out.nodes[i].fill = "#c8f0d4"; case "diamond": out.nodes[i].fill = "#fff3b0"; case "cylinder": out.nodes[i].fill = "#cfe0ff"; case "hexagon": out.nodes[i].fill = "#e3d6ff"; case "parallelogram": out.nodes[i].fill = "#ffd9b3"; default: break }
        }
        return out
    }

    /// An indented list becomes a tree: `Root` / `  Child` / `    Grandchild` (leading "- " or "* " are ignored).
    static func parseOutline(_ text: String, mind: Bool) -> DParsed {
        var out = DParsed(), stack: [(level: Int, id: Int, branch: Int)] = [], branches = 0
        for raw in text.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var level = 0, k = raw.startIndex
            while k < raw.endIndex { if raw[k] == " " { level += 1 } else if raw[k] == "\t" { level += 2 } else { break }; k = raw.index(after: k) }
            var label = String(raw[k...]).trimmingCharacters(in: .whitespaces)
            for p in ["- ", "* ", "• "] where label.hasPrefix(p) { label = String(label.dropFirst(2)) }
            while let l = stack.last, l.level >= level { stack.removeLast() }
            let id = out.nodes.count + 1
            var n = DNode(id: id, shape: mind ? (stack.isEmpty ? "pill" : "round") : "rect", text: label)
            var branch = 0
            if let parent = stack.last { branch = parent.level == 0 || stack.count == 1 ? branches : parent.branch; var e = DEdge(id: out.edges.count + 1, from: parent.id, to: id); e.route = mind ? "curve" : "ortho"; e.head = "none"; out.edges.append(e) }
            else { branches += 0 }
            if stack.count == 1 { branches += 1; branch = branches - 1 }
            if mind { if stack.isEmpty { n.fill = "#1d1d1f"; n.color = "#ffffff"; n.bold = true; n.size = 18 } else { n.fill = palette[branch % palette.count]; n.stroke = "#00000022" } }
            else if stack.isEmpty { n.fill = "#cfe0ff" }
            fit(&n); out.nodes.append(n); stack.append((level, id, branch))
        }
        return out
    }
}

// MARK: - SVG

enum DSVG {
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    static func hex(_ c: String) -> (String, Double) {
        var s = c; if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8, let a = UInt32(s.suffix(2), radix: 16) { return ("#" + s.prefix(6), Double(a) / 255) }
        return (s.count == 6 || s.count == 3 ? "#" + s : "none", 1)
    }
    static func wrap(_ text: String, width: Double, size: Double) -> [String] {
        let maxChars = max(4, Int(width / (size * 0.56))); var lines: [String] = []
        for para in text.components(separatedBy: "\n") {
            var cur = ""; for w in para.split(separator: " ", omittingEmptySubsequences: false) { let t = cur.isEmpty ? String(w) : cur + " " + w; if t.count > maxChars && !cur.isEmpty { lines.append(cur); cur = String(w) } else { cur = t } }
            lines.append(cur)
        }
        return lines
    }
    static func bounds(_ nodes: [DNode], _ edges: [DEdge]) -> CGRect {
        var r = CGRect.null
        for n in nodes { r = r.union(n.frame) }
        let by = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for e in edges { if let a = by[e.from], let b = by[e.to] { for p in DGeo.route(e, a, b).pts { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } } }
        return r.isNull ? CGRect(x: 0, y: 0, width: 200, height: 100) : r
    }
    static func svg(_ nodes: [DNode], _ edges: [DEdge], background: String? = "#ffffff") -> String {
        let b = bounds(nodes, edges).insetBy(dx: -40, dy: -40)
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(Int(b.minX)) \(Int(b.minY)) \(Int(b.width)) \(Int(b.height))\" width=\"\(Int(b.width))\" height=\"\(Int(b.height))\" font-family=\"Helvetica Neue, Helvetica, Arial, sans-serif\">\n"
        if let bg = background { s += "<rect x=\"\(Int(b.minX))\" y=\"\(Int(b.minY))\" width=\"\(Int(b.width))\" height=\"\(Int(b.height))\" fill=\"\(bg)\"/>\n" }
        let by = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for e in edges {
            guard let a = by[e.from], let bn = by[e.to] else { continue }
            let r = DGeo.route(e, a, bn), (col, _) = hex(e.color)
            var d = ""
            if let bz = r.bezier { d = String(format: "M%.1f %.1f C%.1f %.1f %.1f %.1f %.1f %.1f", bz.0.x, bz.0.y, bz.1.x, bz.1.y, bz.2.x, bz.2.y, bz.3.x, bz.3.y) }
            else { d = r.pts.enumerated().map { String(format: "%@%.1f %.1f", $0.offset == 0 ? "M" : "L", $0.element.x, $0.element.y) }.joined(separator: " ") }
            s += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(col)\" stroke-width=\"\(e.width)\"\(e.dash ? " stroke-dasharray=\"7 5\"" : "") stroke-linejoin=\"round\"/>\n"
            for (kind, tip, dir) in [(e.head, r.pts.last!, r.endDir), (e.tail, r.pts[0], CGPoint(x: -r.startDir.x, y: -r.startDir.y))] {
                let h = DGeo.head(kind, tip: tip, dir: dir, size: 8 + e.width * 2)
                if let c = h.circle { s += "<circle cx=\"\(Int(c.midX))\" cy=\"\(Int(c.midY))\" r=\"\(Int(c.width / 2))\" fill=\"\(col)\"/>\n" }
                else if h.pts.count > 1 { let pts = h.pts.map { String(format: "%.1f,%.1f", $0.x, $0.y) }.joined(separator: " ")
                    s += h.filled ? "<polygon points=\"\(pts)\" fill=\"\(col)\"/>\n" : "<polyline points=\"\(pts)\" fill=\"none\" stroke=\"\(col)\" stroke-width=\"\(e.width)\"/>\n" }
            }
            if !e.label.isEmpty { let m = r.mid
                s += "<rect x=\"\(Int(m.x) - e.label.count * 4 - 4)\" y=\"\(Int(m.y) - 10)\" width=\"\(e.label.count * 8 + 8)\" height=\"20\" fill=\"#ffffff\"/>\n<text x=\"\(Int(m.x))\" y=\"\(Int(m.y) + 5)\" text-anchor=\"middle\" font-size=\"13\" fill=\"\(col)\">\(esc(e.label))</text>\n" }
        }
        for n in nodes {
            let (f, fa) = hex(n.fill), (st, sa) = hex(n.stroke), (tc, _) = hex(n.color)
            if n.shape == "image" { s += "<image href=\"\(n.src)\" x=\"\(Int(n.x))\" y=\"\(Int(n.y))\" width=\"\(Int(n.w))\" height=\"\(Int(n.h))\" preserveAspectRatio=\"none\"/>\n" }
            else if n.shape == "icon", let p = Media.symbolPNG(n.src, color: NSColor(Color(hex: n.color)), weight: .regular, px: 256) { s += "<image href=\"\(p.dataURL)\" x=\"\(Int(n.x))\" y=\"\(Int(n.y))\" width=\"\(Int(n.w))\" height=\"\(Int(n.h))\"/>\n" }
            else if n.shape != "text" { s += "<path d=\"\(DShapes.svgPath(DShapes.path(n.shape, n.frame)))\" fill=\"\(f)\" fill-opacity=\"\(fa)\" stroke=\"\(st)\" stroke-opacity=\"\(sa)\" stroke-width=\"\(n.sw)\"\(n.dash ? " stroke-dasharray=\"7 5\"" : "") fill-rule=\"nonzero\"/>\n" }
            let lines = wrap(DocLinks.plain(n.text), width: n.w - 16, size: n.size), lh = n.size * 1.25, top = n.center.y - Double(lines.count) * lh / 2 + n.size
            for (i, l) in lines.enumerated() { s += "<text x=\"\(Int(n.center.x))\" y=\"\(String(format: "%.1f", top + Double(i) * lh - 3))\" text-anchor=\"middle\" font-size=\"\(n.size)\" fill=\"\(tc)\"\(n.bold ? " font-weight=\"bold\"" : "")\(n.italic ? " font-style=\"italic\"" : "")>\(esc(l))</text>\n" }
        }
        return s + "</svg>\n"
    }
}
