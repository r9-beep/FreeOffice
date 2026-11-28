// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

// A free-form canvas shared by Poster (one big page) and Slides (one page per slide).

struct PEl: Identifiable, Equatable {
    var id: Int
    var type: String                      // text | rect | ellipse | line | image
    var x: Double, y: Double, w: Double, h: Double
    var text = "", font = "Helvetica Neue", size: Double = 36, bold = false, italic = false, color = "#111111", align = "left", fill = ""
    var stroke = "", sw: Double = 0, rad: Double = 0, src = ""
    var bullets = false, valign = "top"

    init(id: Int, type: String, x: Double, y: Double, w: Double, h: Double) { self.id = id; self.type = type; self.x = x; self.y = y; self.w = w; self.h = h }
    init?(_ d: [String: Any]) {
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        guard let id = (d["id"] as? NSNumber)?.intValue, let t = d["type"] as? String else { return nil }
        self.init(id: id, type: t, x: num("x") ?? 0, y: num("y") ?? 0, w: num("w") ?? 100, h: num("h") ?? 100)
        text = (d["text"] as? String) ?? ""; font = (d["font"] as? String) ?? "Helvetica Neue"; size = num("size") ?? 36
        bold = (d["bold"] as? NSNumber)?.boolValue ?? false; italic = (d["italic"] as? NSNumber)?.boolValue ?? false
        color = (d["color"] as? String) ?? "#111111"; align = (d["align"] as? String) ?? "left"; fill = (d["fill"] as? String) ?? ""
        stroke = (d["stroke"] as? String) ?? ""; sw = num("sw") ?? 0; rad = num("rad") ?? 0; src = (d["src"] as? String) ?? ""
        bullets = (d["bullets"] as? NSNumber)?.boolValue ?? false; valign = (d["valign"] as? String) ?? "top"
    }
    var dict: [String: Any] {
        var o: [String: Any] = ["id": id, "type": type, "x": x.rounded(), "y": y.rounded(), "w": w.rounded(), "h": h.rounded()]
        switch type {
        case "text": o.merge(["text": text, "font": font, "size": size, "bold": bold, "italic": italic, "color": color, "align": align, "fill": fill, "bullets": bullets, "valign": valign]) { $1 }
        case "rect": o.merge(["fill": fill, "stroke": stroke, "sw": sw, "rad": rad]) { $1 }
        case "ellipse": o.merge(["fill": fill, "stroke": stroke, "sw": sw]) { $1 }
        case "line": o.merge(["stroke": stroke, "sw": sw]) { $1 }
        default: o["src"] = src
        }
        return o
    }
}

/// Decodes (and caches) the data-URL images stored in elements.
final class ImageCache {
    private var cache: [Int: (String, NSImage)] = [:]
    func image(_ e: PEl) -> NSImage? {
        if let c = cache[e.id], c.0 == e.src { return c.1 }
        guard let comma = e.src.firstIndex(of: ","), let d = Data(base64Encoded: String(e.src[e.src.index(after: comma)...])), let img = NSImage(data: d) else { return nil }
        cache[e.id] = (e.src, img); return img
    }
}

protocol CanvasHost: ObservableObject {
    var els: [PEl] { get set }
    var sel: Int? { get set }
    var editing: Int? { get set }
    var bgColor: String { get }
    var page: (w: Double, h: Double) { get }
    var images: ImageCache { get }
    var defaultTextColor: String { get }
    var defaultFont: String { get }
    var defaultFill: String { get }
    var defaultStroke: String { get }
    var overlayContent: AnyView { get }
    func resolveColor(_ c: String) -> Color
    func resolveFont(_ f: String) -> String
}

extension CanvasHost {
    var defaultTextColor: String { "#111111" }
    var defaultFont: String { "Helvetica Neue" }
    var defaultFill: String { "#3b6cf6" }
    var defaultStroke: String { "#111111" }
    var overlayContent: AnyView { AnyView(EmptyView()) }
    func resolveColor(_ c: String) -> Color { c.isEmpty ? .clear : Color(hex: c) }
    func resolveFont(_ f: String) -> String { f }
    func image(_ e: PEl) -> NSImage? { images.image(e) }

    var index: Int? { els.firstIndex { $0.id == sel } }
    var selected: PEl? { index.map { els[$0] } }
    func nextId() -> Int { (els.map(\.id).max() ?? 0) + 1 }
    func add(_ e: PEl) { els.append(e); sel = e.id; editing = nil }
    func addDefault(_ type: String) {
        let o = 80 + Double(els.count % 10) * 14; var e = PEl(id: nextId(), type: type, x: o, y: o, w: 300, h: 200)
        switch type {
        case "text": e.w = 400; e.h = 80; e.text = "New text"; e.size = 36; e.color = defaultTextColor; e.font = defaultFont
        case "rect": e.fill = defaultFill
        case "ellipse": e.w = 240; e.h = 240; e.fill = defaultFill
        default: e.w = 400; e.h = 6; e.stroke = defaultStroke; e.sw = 6
        }
        add(e)
    }
    func addImage() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url, let data = try? Data(contentsOf: u), let img = NSImage(data: data) else { return }
        let mime = u.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        let k = min(1, page.w * 0.5 / max(img.size.width, 1)); var e = PEl(id: nextId(), type: "image", x: 60, y: 60, w: (img.size.width * k).rounded(), h: (img.size.height * k).rounded())
        e.src = "data:\(mime);base64," + data.base64EncodedString(); add(e)
    }
    /// Drops a photo, icon or background from the Media panel onto the page (backgrounds fill it, behind everything).
    func addMedia(_ p: MediaPick) {
        let (pw, ph) = page
        var e = PEl(id: nextId(), type: "image", x: 0, y: 0, w: pw, h: ph); e.src = p.dataURL
        if p.isBackground { els.insert(e, at: 0); sel = e.id; editing = nil; return }
        let maxW = p.symbol != nil ? pw * 0.18 : pw * 0.55, k = min(maxW / max(p.size.width, 1), ph * 0.6 / max(p.size.height, 1))
        e.w = (p.size.width * k).rounded(); e.h = (p.size.height * k).rounded(); e.x = ((pw - e.w) / 2).rounded(); e.y = ((ph - e.h) / 2).rounded()
        add(e)
        if let c = p.credit {
            var t = PEl(id: nextId(), type: "text", x: e.x, y: e.y + e.h + 6, w: max(e.w, 300), h: 40); t.text = c; t.size = 13; t.color = "muted"; t.font = defaultFont
            if t.color == "muted" && !(self is SlidesModel) { t.color = "#6e6e73" }
            add(t); sel = e.id
        }
    }
    func duplicate() { if var e = selected { e.id = nextId(); e.x += 20; e.y += 20; add(e) } }
    func delete() { if let i = index { els.remove(at: i); sel = nil; editing = nil } }
    func front() { if let i = index { let e = els.remove(at: i); els.append(e) } }
    func back() { if let i = index { let e = els.remove(at: i); els.insert(e, at: 0) } }
    func nudge(_ dx: Double, _ dy: Double) { if let i = index { els[i].x += dx; els[i].y += dy } }
    func align(_ how: String) {      // align the selected element to the page
        guard let i = index else { return }
        let e = els[i]
        switch how {
        case "left": els[i].x = 0; case "right": els[i].x = page.w - e.w; case "centre": els[i].x = ((page.w - e.w) / 2).rounded()
        case "top": els[i].y = 0; case "bottom": els[i].y = page.h - e.h; default: els[i].y = ((page.h - e.h) / 2).rounded()
        }
    }
}

// MARK: - The page (shared by the editing canvas, thumbnails, presenter and exports)

struct CanvasPage<M: CanvasHost>: View {
    @ObservedObject var m: M
    var interactive: Bool
    var zoom: Double = 1
    @State private var dragStart: [Int: (Double, Double)] = [:]
    @State private var sizeStart: [Int: (Double, Double)] = [:]

    var body: some View {
        let (w, h) = m.page
        ZStack(alignment: .topLeading) {
            m.resolveColor(m.bgColor)
            ForEach(m.els) { e in element(e) }
            m.overlayContent
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { if interactive { m.sel = nil; m.editing = nil } }
    }

    @ViewBuilder func element(_ e: PEl) -> some View {
        let selected = interactive && m.sel == e.id
        content(e)
            .frame(width: e.w, height: e.type == "line" ? max(e.sw, 1) : e.h, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if selected && m.editing != e.id {
                    Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: 14, height: 14).offset(x: 7, y: 7)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasOuter")).onChanged { v in
                            if sizeStart[e.id] == nil { sizeStart[e.id] = (e.w, e.h) }
                            let s = sizeStart[e.id]!; if let i = m.els.firstIndex(where: { $0.id == e.id }) {
                                m.els[i].w = max(10, (s.0 + v.translation.width / zoom).rounded()); if e.type != "line" { m.els[i].h = max(10, (s.1 + v.translation.height / zoom).rounded()) } }
                        }.onEnded { _ in sizeStart[e.id] = nil })
                }
            }
            .overlay { if selected { Rectangle().stroke(Color.accentColor, lineWidth: (m.editing == e.id ? 1 : 2) / max(zoom, 0.2)).padding(-1).allowsHitTesting(false) } }
            .offset(x: e.x, y: e.y)
            .onTapGesture(count: 2) { if interactive { m.sel = e.id; if e.type == "text" { m.editing = e.id } } }
            .onTapGesture { if interactive { m.sel = e.id; if m.editing != e.id { m.editing = nil } } }
            .gesture(interactive && m.editing != e.id ? DragGesture(minimumDistance: 3, coordinateSpace: .named("canvasOuter")).onChanged { v in
                if dragStart[e.id] == nil { dragStart[e.id] = (e.x, e.y); m.sel = e.id }
                let s = dragStart[e.id]!; if let i = m.els.firstIndex(where: { $0.id == e.id }) {
                    m.els[i].x = (s.0 + v.translation.width / zoom).rounded(); m.els[i].y = (s.1 + v.translation.height / zoom).rounded() }
            }.onEnded { _ in dragStart[e.id] = nil } : nil)
    }

    func displayText(_ e: PEl) -> String {
        let text = DocLinks.plain(e.text)
        guard e.bullets else { return text }
        return text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : "•  " + $0 }.joined(separator: "\n")
    }
    func alignment(_ e: PEl) -> Alignment {
        let v = e.valign == "middle" ? "" : (e.valign == "bottom" ? "bottom" : "top")
        switch (e.align, v) {
        case ("center", "top"): return .top; case ("right", "top"): return .topTrailing; case (_, "top"): return .topLeading
        case ("center", "bottom"): return .bottom; case ("right", "bottom"): return .bottomTrailing; case (_, "bottom"): return .bottomLeading
        case ("center", _): return .center; case ("right", _): return .trailing; default: return .leading
        }
    }

    @ViewBuilder func content(_ e: PEl) -> some View {
        switch e.type {
        case "text":
            let font = Font.custom(m.resolveFont(e.font), size: e.size).weight(e.bold ? .bold : .regular)
            if interactive && m.editing == e.id {
                InlineEditor(text: Binding(get: { m.els.first { $0.id == e.id }?.text ?? "" }, set: { v in if let i = m.els.firstIndex(where: { $0.id == e.id }) { m.els[i].text = v } }),
                             font: font, color: m.resolveColor(e.color), align: e.align == "center" ? .center : e.align == "right" ? .trailing : .leading, onDone: { m.editing = nil })
                    .frame(width: e.w, height: e.h, alignment: alignment(e)).background(e.fill.isEmpty ? Color.clear : m.resolveColor(e.fill))
            } else {
                Text(displayText(e)).font(font).italic(e.italic)
                    .foregroundStyle(m.resolveColor(e.color)).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(e.align == "center" ? .center : e.align == "right" ? .trailing : .leading)
                    .frame(width: e.w, height: e.h, alignment: alignment(e))
                    .background(e.fill.isEmpty ? Color.clear : m.resolveColor(e.fill)).clipped()
            }
        case "rect":
            RoundedRectangle(cornerRadius: e.rad).fill(m.resolveColor(e.fill))
                .overlay { if e.sw > 0 && !e.stroke.isEmpty { RoundedRectangle(cornerRadius: e.rad).strokeBorder(m.resolveColor(e.stroke), lineWidth: e.sw) } }
        case "ellipse":
            Ellipse().fill(m.resolveColor(e.fill))
                .overlay { if e.sw > 0 && !e.stroke.isEmpty { Ellipse().strokeBorder(m.resolveColor(e.stroke), lineWidth: e.sw) } }
        case "line":
            Rectangle().fill(m.resolveColor(e.stroke.isEmpty ? "#000000" : e.stroke))
        default:
            if let img = m.image(e) { Image(nsImage: img).resizable().scaledToFill().frame(width: e.w, height: e.h).clipped() }
            else { ZStack { Color.gray.opacity(0.25); Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.gray) } }
        }
    }
}

/// Typing directly on the canvas (double-click a text box).
struct InlineEditor: View {
    @Binding var text: String
    let font: Font, color: Color, align: TextAlignment
    var onDone: () -> Void
    @FocusState private var focus: Bool
    var body: some View {
        TextEditor(text: $text).font(font).foregroundStyle(color).multilineTextAlignment(align)
            .scrollContentBackground(.hidden).scrollDisabled(true).focused($focus)
            .padding(.horizontal, -5).padding(.vertical, -8)
            .onAppear { focus = true }
            .onKeyPress(.escape) { onDone(); return .handled }
    }
}

// MARK: - The scrollable, zoomable surface with keyboard nudging

struct CanvasSurface<M: CanvasHost>: View {
    @ObservedObject var m: M
    var zoom: Double = 0                  // 0 = fit to the available space
    var margin: CGFloat = 30
    @FocusState private var focus: Bool
    var body: some View {
        GeometryReader { g in
            let (w, h) = m.page
            let z = zoom > 0 ? zoom : max(0.1, min((g.size.width - margin * 2) / w, (g.size.height - margin * 2) / h))
            ScrollView([.horizontal, .vertical]) {
                CanvasPage(m: m, interactive: true, zoom: z)
                    .scaleEffect(z, anchor: .topLeading)
                    .frame(width: w * z, height: h * z, alignment: .topLeading)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                    .padding(margin)
                    .frame(minWidth: g.size.width, minHeight: g.size.height)
            }
            .coordinateSpace(name: "canvasOuter")
            .focusable().focused($focus).focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { p in
                if m.editing != nil { return .ignored }
                let s: Double = p.modifiers.contains(.shift) ? 10 : 1
                switch p.key {
                case .leftArrow: m.nudge(-s, 0); case .rightArrow: m.nudge(s, 0); case .upArrow: m.nudge(0, -s); case .downArrow: m.nudge(0, s)
                case .delete, .deleteForward: m.delete()
                case .escape: m.sel = nil
                case .return: if m.selected?.type == "text" { m.editing = m.sel } else { return .ignored }
                default: return .ignored
                }
                return .handled
            }
            .onAppear { focus = true }
            .onChange(of: m.sel) { _, s in if s == nil { focus = true } }
        }
    }
}

// MARK: - The inspector for the selected element

struct ElementInspector<M: CanvasHost, Top: View>: View {
    @ObservedObject var m: M
    var themeFonts = false                // Slides: offer "theme" fonts
    @ViewBuilder var top: () -> Top
    @FocusState private var textFocus: Bool

    func bind<T>(_ kp: WritableKeyPath<PEl, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { m.selected?[keyPath: kp] ?? fallback }, set: { v in if let i = m.index { m.els[i][keyPath: kp] = v } })
    }
    func colorBind(_ kp: WritableKeyPath<PEl, String>) -> Binding<Color> {
        Binding(get: { m.resolveColor(m.selected?[keyPath: kp] ?? "#000000") }, set: { c in if let i = m.index { m.els[i][keyPath: kp] = c.hexString } })
    }
    func numField(_ label: String, _ kp: WritableKeyPath<PEl, Double>, lw: CGFloat = 64) -> some View {
        HStack(spacing: 6) { Text(label).frame(width: lw, alignment: .leading); TextField("", value: bind(kp, 0), format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder).frame(width: 62) }
    }
    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    func clear(_ kp: WritableKeyPath<PEl, String>) { if let i = m.index { m.els[i][keyPath: kp] = "" } }
    var fontLabel: Binding<String> {
        Binding(get: { let f = m.selected?.font ?? ""; return f.hasPrefix("@") ? "" : f }, set: { v in if let i = m.index { m.els[i].font = v } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                top()
                if let e = m.selected {
                    group(e.type.capitalized) {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow { numField("X", \.x, lw: 16); numField("Y", \.y, lw: 16) }
                            GridRow { numField("W", \.w, lw: 16); if e.type != "line" { numField("H", \.h, lw: 16) } }
                        }
                        Menu {
                            Button("Centre horizontally") { m.align("centre") }; Button("Centre vertically") { m.align("middle") }
                            Divider(); Button("Left edge") { m.align("left") }; Button("Right edge") { m.align("right") }; Button("Top edge") { m.align("top") }; Button("Bottom edge") { m.align("bottom") }
                        } label: { Label("Align to page", systemImage: "align.horizontal.center") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if e.type == "text" {
                        group("Text") {
                            TextEditor(text: bind(\.text, "")).focused($textFocus).frame(height: 90).scrollContentBackground(.hidden).padding(6).foregroundStyle(.black).background(.white.opacity(0.85), in: .rect(cornerRadius: 8))
                                .docMentions(bind(\.text, ""))
                            MentionStrip(text: m.els.first { $0.id == e.id }?.text ?? "")
                            Text("Type @ to link another document").font(.fo(.caption)).foregroundStyle(.secondary)
                            HStack {
                                Text("Font").frame(width: 40, alignment: .leading)
                                FontPickerButton(selection: fontLabel, allowDefault: themeFonts, width: 120)
                            }
                            if themeFonts {
                                HStack {
                                    Button("Theme body") { if let i = m.index { m.els[i].font = "@body" } }; Button("Theme heading") { if let i = m.index { m.els[i].font = "@heading" } }
                                }.buttonStyle(.glass).font(.fo(.caption))
                            }
                            numField("Size", \.size)
                            HStack { ColorPicker("Colour", selection: colorBind(\.color)); if themeFonts { Button("Theme") { if let i = m.index { m.els[i].color = "fg" } }.buttonStyle(.glass).font(.fo(.caption)) } }
                            HStack { ColorPicker("Fill", selection: colorBind(\.fill)); Button("None") { clear(\.fill) }.buttonStyle(.glass) }
                            Picker("Align", selection: bind(\.align, "left")) { Image(systemName: "text.alignleft").tag("left"); Image(systemName: "text.aligncenter").tag("center"); Image(systemName: "text.alignright").tag("right") }.pickerStyle(.segmented)
                            Picker("Vertical", selection: bind(\.valign, "top")) { Image(systemName: "align.vertical.top").tag("top"); Image(systemName: "align.vertical.center").tag("middle"); Image(systemName: "align.vertical.bottom").tag("bottom") }.pickerStyle(.segmented)
                            HStack { Toggle("Bold", isOn: bind(\.bold, false)); Toggle("Italic", isOn: bind(\.italic, false)); Toggle("Bullets", isOn: bind(\.bullets, false)) }.toggleStyle(.button)
                        }
                    }
                    if e.type == "rect" || e.type == "ellipse" {
                        group("Style") {
                            HStack { ColorPicker("Fill", selection: colorBind(\.fill)); Button("None") { clear(\.fill) }.buttonStyle(.glass) }
                            ColorPicker("Border", selection: colorBind(\.stroke))
                            numField("Border", \.sw)
                            if e.type == "rect" { numField("Radius", \.rad) }
                        }
                    }
                    if e.type == "line" { group("Style") { ColorPicker("Colour", selection: colorBind(\.stroke)); numField("Thickness", \.sw) } }
                    group("Arrange") {
                        HStack { Button("Bring to front") { m.front() }; Button("Send to back") { m.back() } }.buttonStyle(.glass)
                        HStack { Button("Duplicate") { m.duplicate() }; Button("Delete", role: .destructive) { m.delete() } }.buttonStyle(.glass)
                    }
                } else {
                    Text("Select an element to edit it. Double-click text to type on the canvas.").foregroundStyle(.secondary).font(.fo(.callout))
                }
            }
            .padding(14).frame(width: 260)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
    }
}
