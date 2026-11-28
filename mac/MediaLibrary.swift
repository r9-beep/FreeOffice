// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

// The Media panel: free stock photos (Openverse), icons (SF Symbols), generated backgrounds and your own image library.
// Whatever you pick is copied into the document, so it keeps working offline.

/// What the panel hands back to an editor.
struct MediaPick {
    var data: Data                 // PNG or JPEG
    var mime: String
    var size: CGSize               // pixels
    var credit: String?            // attribution line, when the licence asks for one
    var symbol: String?            // set for icons, so Diagrams can keep them as vectors
    var symbolColor: String?
    var isBackground = false
    var dataURL: String { "data:\(mime);base64," + data.base64EncodedString() }
    var image: NSImage? { NSImage(data: data) }
}

// MARK: - Openverse

struct OVImage: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let url: String
    let thumbnail: String?
    let creator: String?
    let license: String
    let license_version: String?
    let foreign_landing_url: String?
    let width: Int?
    let height: Int?
    var needsCredit: Bool { !["cc0", "pdm"].contains(license.lowercased()) }
    var licenceLabel: String { license.lowercased() == "pdm" ? "Public domain" : license.lowercased() == "cc0" ? "CC0" : "CC " + license.uppercased() + (license_version.map { " " + $0 } ?? "") }
    var credit: String { "“\((title ?? "Untitled").trimmingCharacters(in: .whitespaces))” by \(creator ?? "unknown") · \(licenceLabel)" + (foreign_landing_url.map { " · " + $0 } ?? "") }
}
struct OVPage: Decodable { let result_count: Int; let page_count: Int; let results: [OVImage] }

enum Openverse {
    static func searchURL(_ q: String, page: Int, freeOnly: Bool) -> URL? {
        var c = URLComponents(string: "https://api.openverse.org/v1/images/")
        c?.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page_size", value: "20"),
                         URLQueryItem(name: "license", value: freeOnly ? "cc0,pdm" : "cc0,pdm,by,by-sa"), URLQueryItem(name: "mature", value: "false")]
        return c?.url
    }
    static func request(_ u: URL, timeout: Double = 20) -> URLRequest {
        var r = URLRequest(url: u); r.timeoutInterval = timeout; r.setValue("FreeOffice/2 (macOS)", forHTTPHeaderField: "User-Agent"); return r
    }
    static func search(_ q: String, page: Int, freeOnly: Bool) async throws -> OVPage {
        guard let u = searchURL(q, page: page, freeOnly: freeOnly) else { throw URLError(.badURL) }
        let (d, resp) = try await URLSession.shared.data(for: request(u))
        if let h = resp as? HTTPURLResponse, h.statusCode == 429 { throw MediaError("Openverse is busy — wait a minute and try again.") }
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let detail = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["detail"] as? String
            throw MediaError("Openverse couldn't search (\(h.statusCode))" + (detail.map { ": " + $0 } ?? "."))
        }
        return try JSONDecoder().decode(OVPage.self, from: d)
    }
    /// Downloads the photo (falling back to Openverse's own large copy) and shrinks it to a sensible size for documents.
    static func download(_ img: OVImage) async throws -> MediaPick {
        var data: Data?
        for s in [img.url, "https://api.openverse.org/v1/images/\(img.id)/thumb/?full_size=true"] {
            guard let u = URL(string: s), let (d, r) = try? await URLSession.shared.data(for: request(u, timeout: 40)), (r as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true, NSImage(data: d) != nil else { continue }
            data = d; break
        }
        guard let d = data, let pick = Media.normalise(d, maxSide: 2000) else { throw MediaError("Couldn't download that photo.") }
        var p = pick; p.credit = img.needsCredit ? img.credit : nil; return p
    }
}
struct MediaError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

// MARK: - Shared helpers

enum Media {
    /// Re-encodes as JPEG (or PNG when there's transparency), no bigger than `maxSide` pixels.
    static func normalise(_ d: Data, maxSide: CGFloat) -> MediaPick? {
        guard let rep0 = NSBitmapImageRep(data: d) else { return nil }
        let w = CGFloat(rep0.pixelsWide), h = CGFloat(rep0.pixelsHigh); guard w > 0, h > 0 else { return nil }
        let k = min(1, maxSide / max(w, h)), nw = Int((w * k).rounded()), nh = Int((h * k).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: nh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx; ctx.imageInterpolation = .high
        rep0.draw(in: NSRect(x: 0, y: 0, width: nw, height: nh)); NSGraphicsContext.restoreGraphicsState()
        let alpha = rep0.hasAlpha
        guard let out = alpha ? rep.representation(using: .png, properties: [:]) : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { return nil }
        return MediaPick(data: out, mime: alpha ? "image/png" : "image/jpeg", size: CGSize(width: nw, height: nh))
    }
    @MainActor static func png(_ view: some View, size: CGSize) -> MediaPick? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)); r.scale = 1
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg); guard let d = rep.representation(using: .png, properties: [:]) else { return nil }
        return MediaPick(data: d, mime: "image/png", size: size)
    }
    static func symbolPNG(_ name: String, color: NSColor, weight: NSFont.Weight, px: CGFloat = 512) -> MediaPick? {
        let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.8, weight: weight).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let s = sym.size, k = px / max(s.width, s.height), w = Int((s.width * k).rounded()), h = Int((s.height * k).rounded())
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        sym.draw(in: NSRect(x: 0, y: 0, width: w, height: h)); NSGraphicsContext.restoreGraphicsState()
        guard let d = rep.representation(using: .png, properties: [:]) else { return nil }
        return MediaPick(data: d, mime: "image/png", size: CGSize(width: w, height: h), symbol: name, symbolColor: color.usingColorSpace(.sRGB).map { String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) })
    }
}

// MARK: - Icons (the SF Symbols that ship with macOS)

enum SymbolCatalogue {
    struct Category: Hashable { let key: String; let icon: String; var label: String { Self.names[key] ?? (key.prefix(1).uppercased() + key.dropFirst()) }
        static let names = ["all": "All", "whatsnew": "New", "objectsandtools": "Objects & tools", "textformatting": "Text", "cameraandphotos": "Camera & photos", "privacyandsecurity": "Privacy & security", "maps": "Maps & places", "indices": "Numbers & letters", "math": "Maths"] }
    static let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
    static func plist(_ n: String) -> Any? { (try? Data(contentsOf: resources.appendingPathComponent(n))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } }
    static let restricted: Set<String> = {
        guard let s = try? String(contentsOf: resources.appendingPathComponent("symbol_restrictions.strings"), encoding: .utf8) else { return [] }
        return Set(s.components(separatedBy: "\n").compactMap { l in l.hasPrefix("\"") ? l.split(separator: "\"").first.map(String.init) : nil })
    }()
    /// Every usable symbol, minus language variants and Apple-only logos.
    static let names: [String] = {
        let all = (plist("symbol_order.plist") as? [String]) ?? fallback
        let langs = [".ar", ".he", ".hi", ".ja", ".ko", ".th", ".zh", ".rtl", ".bn", ".gu", ".kn", ".ml", ".mr", ".or", ".pa", ".ta", ".te", ".my", ".km", ".sat", ".mni", ".el", ".ru", ".sr"]
        return all.filter { n in !restricted.contains(n) && !langs.contains { n.hasSuffix($0) || n.contains($0 + ".") }}
    }()
    static let categories: [Category] = ((plist("categories.plist") as? [[String: Any]]) ?? []).compactMap { d in (d["key"] as? String).map { Category(key: $0, icon: (d["icon"] as? String) ?? "square") } }.filter { $0.key != "multicolor" && $0.key != "variable" }
    static let byCategory: [String: [String]] = (plist("symbol_categories.plist") as? [String: [String]]) ?? [:]
    static let keywords: [String: [String]] = (plist("symbol_search.plist") as? [String: [String]]) ?? [:]
    static let fallback = ["star", "heart", "house", "person", "person.2", "envelope", "phone", "calendar", "clock", "cart", "bag", "creditcard", "gift", "lightbulb", "bolt", "flame", "leaf", "globe", "map", "location", "camera", "photo", "music.note", "book", "pencil", "trash", "folder", "doc", "paperplane", "bell", "lock", "key", "gearshape", "wrench", "hammer", "chart.bar", "chart.pie", "cloud", "sun.max", "moon", "car", "airplane", "bicycle", "cup.and.saucer", "fork.knife", "checkmark.circle", "xmark.circle", "exclamationmark.triangle", "questionmark.circle", "info.circle", "arrow.right", "arrow.up", "server.rack", "desktopcomputer", "laptopcomputer", "iphone", "wifi", "network", "cylinder", "shield", "person.3", "building.2", "graduationcap", "stethoscope", "pawprint", "tree", "mountain.2", "drop", "snowflake", "sparkles", "trophy", "flag", "tag", "megaphone"]
    static func search(_ q: String, category: String) -> [String] {
        var list = names
        if category != "all", !byCategory.isEmpty { list = list.filter { byCategory[$0]?.contains(category) ?? false } }
        let t = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return list }
        return list.filter { $0.contains(t) || (keywords[$0]?.contains { $0.contains(t) } ?? false) }
    }
}

// MARK: - Backgrounds

struct BackgroundSpec: Identifiable, Hashable {
    let id: Int; let kind: String; let colors: [String]
    @ViewBuilder var view: some View {
        let c = colors.map { Color(hex: $0) }
        switch kind {
        case "mesh": MeshGradient(width: 3, height: 3, points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]], colors: [c[0], c[1], c[2], c[1], c[3], c[0], c[2], c[0], c[1]])
        case "radial": RadialGradient(colors: [c[1], c[0]], center: .init(x: 0.3, y: 0.3), startRadius: 0, endRadius: 900)
        case "dots": ZStack { c[0]; Canvas { ctx, s in var p = Path(); var y = 12.0; while y < s.height { var x = 12.0; while x < s.width { p.addEllipse(in: CGRect(x: x, y: y, width: 6, height: 6)); x += 30 }; y += 30 }; ctx.fill(p, with: .color(c[1].opacity(0.55))) } }
        case "stripes": ZStack { c[0]; Canvas { ctx, s in var p = Path(); var x = -s.height; while x < s.width { p.move(to: CGPoint(x: x, y: s.height)); p.addLine(to: CGPoint(x: x + s.height, y: 0)); x += 46 }; ctx.stroke(p, with: .color(c[1].opacity(0.5)), lineWidth: 16) } }
        case "grid": ZStack { c[0]; Canvas { ctx, s in var p = Path(); var x = 0.0; while x < s.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: s.height)); x += 48 }; var y = 0.0; while y < s.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: s.width, y: y)); y += 48 }; ctx.stroke(p, with: .color(c[1].opacity(0.35)), lineWidth: 2) } }
        case "waves": ZStack { c[0]; Canvas { ctx, s in for i in 0..<5 { var p = Path(); let base = s.height * (0.35 + Double(i) * 0.14); p.move(to: CGPoint(x: 0, y: base)); var x = 0.0; while x <= s.width { p.addLine(to: CGPoint(x: x, y: base + sin(x / s.width * 2 * .pi * 1.5 + Double(i)) * s.height * 0.06)); x += 8 }; p.addLine(to: CGPoint(x: s.width, y: s.height)); p.addLine(to: CGPoint(x: 0, y: s.height)); p.closeSubpath(); ctx.fill(p, with: .color((i % 2 == 0 ? c[1] : c[2]).opacity(0.28))) } } }
        default: LinearGradient(colors: [c[0], c[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    static let palettes: [[String]] = [["#ff6a88", "#ff99ac", "#fcb69f", "#ffd1a1"], ["#4facfe", "#00f2fe", "#43e97b", "#38f9d7"], ["#667eea", "#764ba2", "#f093fb", "#a18cd1"], ["#0f2027", "#203a43", "#2c5364", "#4ca1af"],
                                       ["#f6d365", "#fda085", "#ff7eb3", "#ffcf71"], ["#1d1d1f", "#3a3a3c", "#636366", "#8e8e93"], ["#fdfbfb", "#ebedee", "#dfe9f3", "#cfd9df"], ["#11998e", "#38ef7d", "#a8e063", "#56ab2f"],
                                       ["#c471f5", "#fa71cd", "#fbc2eb", "#a6c1ee"], ["#ff512f", "#dd2476", "#f09819", "#ff5e62"], ["#0b0f2a", "#1b2a6b", "#3a5bd9", "#7a9bff"], ["#f5f0e1", "#e8d9b5", "#c9b38a", "#a68a64"]]
    static let kinds = ["mesh", "linear", "radial", "waves", "dots", "stripes", "grid"]
    static func all() -> [BackgroundSpec] { var out: [BackgroundSpec] = []; for (k, kind) in kinds.enumerated() { for (p, pal) in palettes.enumerated() { out.append(BackgroundSpec(id: k * 100 + p, kind: kind, colors: pal)) } }; return out }
}

// MARK: - Your library (lives with your documents, so it syncs with FreeOffice Cloud)

struct LibraryItem: Identifiable, Hashable { let id: String; let url: URL; var credit: String?; var title: String }

enum MediaLibraryStore {
    static var dir: URL { DocLinks.dir }
    static func items() -> [LibraryItem] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.lastPathComponent.hasPrefix("office__media__") && ["jpg", "png"].contains($0.pathExtension) }
        return files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.map { u in
            let id = String(u.deletingPathExtension().lastPathComponent.dropFirst("office__media__".count))
            let meta = (try? Data(contentsOf: metaURL(id))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] } ?? [:]
            return LibraryItem(id: id, url: u, credit: meta["credit"], title: meta["title"] ?? "Image")
        }
    }
    static func metaURL(_ id: String) -> URL { dir.appendingPathComponent("office__media__\(id).credit") }
    @discardableResult static func save(_ p: MediaPick, title: String) -> LibraryItem? {
        let id = Model.newId(), u = dir.appendingPathComponent("office__media__\(id).\(p.mime == "image/png" ? "png" : "jpg")")
        guard (try? p.data.write(to: u)) != nil else { return nil }
        var meta = ["title": title]; if let c = p.credit { meta["credit"] = c }
        if let d = try? JSONSerialization.data(withJSONObject: meta) { try? d.write(to: metaURL(id)) }
        return LibraryItem(id: id, url: u, credit: p.credit, title: title)
    }
    static func importFiles(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls { if let d = try? Data(contentsOf: u), let p = Media.normalise(d, maxSide: 2400) { save(p, title: u.deletingPathExtension().lastPathComponent); n += 1 } }
        return n
    }
    static func delete(_ it: LibraryItem) { try? FileManager.default.removeItem(at: it.url); try? FileManager.default.removeItem(at: metaURL(it.id)) }
    static func pick(_ it: LibraryItem) -> MediaPick? { (try? Data(contentsOf: it.url)).flatMap { Media.normalise($0, maxSide: 2400) }.map { var p = $0; p.credit = it.credit; return p } }
}

// MARK: - The panel

final class MediaPanelModel: ObservableObject {
    @Published var tab = "photos"
    @Published var query = ""
    @Published var freeOnly = true
    @Published var photos: [OVImage] = []
    @Published var page = 1
    @Published var pages = 0
    @Published var total = 0
    @Published var loading = false
    @Published var busyId: String?
    @Published var error: String?
    @Published var note: String?
    @Published var iconQuery = ""
    @Published var iconCategory = "all"
    @Published var iconColor = "#1d1d1f"
    @Published var iconWeight = 1
    @Published var selectedIcon: String?
    @Published var library: [LibraryItem] = []
    static let weights: [(String, NSFont.Weight, Font.Weight)] = [("Light", .light, .light), ("Regular", .regular, .regular), ("Semibold", .semibold, .semibold), ("Bold", .bold, .bold)]

    func search(more: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return }
        let p = more ? page + 1 : 1
        loading = true; error = nil
        Task { @MainActor in
            do {
                let r = try await Openverse.search(q, page: p, freeOnly: freeOnly)
                photos = more ? photos + r.results : r.results; page = p; pages = r.page_count; total = r.result_count
                if r.results.isEmpty && !more { error = "No photos found for “\(q)”." }
            } catch let e as MediaError { error = e.message } catch { self.error = "Couldn't reach Openverse. Are you online?" }
            loading = false
        }
    }
    func fetch(_ img: OVImage, then: @escaping (MediaPick) -> Void) {
        busyId = img.id; error = nil
        Task { @MainActor in
            do { let p = try await Openverse.download(img); busyId = nil; then(p) } catch { busyId = nil; self.error = (error as? MediaError)?.message ?? "Couldn't download that photo." }
        }
    }
    func reloadLibrary() { library = MediaLibraryStore.items() }
}

struct MediaPanel: View {
    var onPick: (MediaPick) -> Void
    var aspect: CGSize = CGSize(width: 1920, height: 1080)       // background size to render
    @StateObject private var m = MediaPanelModel()
    @Environment(\.dismiss) private var dismiss
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Media").font(.fo(.title2))
                Picker("", selection: $m.tab) { Label("Photos", systemImage: "photo").tag("photos"); Label("Icons", systemImage: "star.square").tag("icons"); Label("Backgrounds", systemImage: "square.stack.3d.down.right").tag("backgrounds"); Label("My library", systemImage: "books.vertical").tag("library") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 470)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
            Group {
                switch m.tab {
                case "icons": icons
                case "backgrounds": backgrounds
                case "library": library
                default: photos
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let e = m.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.fo(.callout)) }
            else if let n = m.note { Label(n, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.fo(.callout)) }
        }
        .padding(18).frame(width: 920, height: 640)
        .onAppear {
            m.reloadLibrary()
            let env = ProcessInfo.processInfo.environment          // test hooks: FO_MEDIA=photos|icons|backgrounds|library, FO_MEDIA_Q=search
            if let t = env["FO_MEDIA"], ["photos", "icons", "backgrounds", "library"].contains(t) { m.tab = t }
            if let q = env["FO_MEDIA_Q"] { if m.tab == "icons" { m.iconQuery = q } else { m.query = q; m.search() } }
        }
        .onChange(of: m.note) { _, n in if n != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { m.note = nil } } }
    }
    func use(_ p: MediaPick) { onPick(p); dismiss() }

    // MARK: photos
    var photos: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search free photos — try “mountains”, “coffee”, “city at night”", text: $m.query).textFieldStyle(.plain).onSubmit { m.search() } }
                    .padding(9).background(.thinMaterial, in: .rect(cornerRadius: 10))
                Picker("", selection: $m.freeOnly) { Text("No credit needed").tag(true); Text("Include credit-required").tag(false) }.frame(width: 210).labelsHidden()
                    .onChange(of: m.freeOnly) { _, _ in m.search() }
                Button("Search") { m.search() }.buttonStyle(.glassProminent).disabled(m.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                if m.photos.isEmpty && !m.loading {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Millions of openly licensed photos from Openverse.").font(.fo(.headline))
                        Text("Searches are sent to openverse.org. Photos you insert are copied into your document.").font(.fo(.callout)).foregroundStyle(.secondary)
                    }.padding(.top, 80)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(m.photos) { p in photoTile(p) }
                }
                if m.page < m.pages && !m.photos.isEmpty { Button(m.loading ? "Loading…" : "Load more") { m.search(more: true) }.buttonStyle(.glass).padding(10).disabled(m.loading) }
                else if m.loading { ProgressView().padding(30) }
            }
            if m.total > 0 { Text("\(m.total.formatted()) results · Openverse · \(m.freeOnly ? "public domain and CC0: free to use without credit" : "credit is added automatically where the licence asks for it")").font(.fo(.caption)).foregroundStyle(.secondary) }
        }
    }
    func photoTile(_ p: OVImage) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: p.thumbnail ?? p.url)) { ph in
                if let i = ph.image { i.resizable().scaledToFill() } else if ph.error != nil { Color.gray.opacity(0.2).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) } else { Color.gray.opacity(0.12).overlay(ProgressView()) }
            }.frame(minWidth: 0, maxWidth: .infinity).frame(height: 120).clipped()
            Text(p.licenceLabel).font(.fo(.caption2).weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.ultraThinMaterial, in: .capsule).padding(6)
            if m.busyId == p.id { Color.black.opacity(0.35); ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 0, maxWidth: .infinity).frame(height: 120).clipShape(.rect(cornerRadius: 10)).contentShape(.rect)
        .onTapGesture { m.fetch(p) { use($0) } }
        .contextMenu {
            Button("Insert") { m.fetch(p) { use($0) } }
            Button("Save to My library") { m.fetch(p) { pick in MediaLibraryStore.save(pick, title: p.title ?? "Photo"); m.reloadLibrary(); m.note = "Saved to My library" } }
            if let l = p.foreign_landing_url, let u = URL(string: l) { Button("View source page") { NSWorkspace.shared.open(u) } }
        }
        .help("\(p.title ?? "Untitled") — \(p.creator ?? "unknown") · \(p.licenceLabel)")
    }

    // MARK: icons
    var icons: some View {
        let list = SymbolCatalogue.search(m.iconQuery, category: m.iconCategory)
        return HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([SymbolCatalogue.Category(key: "all", icon: "square.grid.2x2")] + SymbolCatalogue.categories.filter { $0.key != "all" }, id: \.key) { c in
                        Button { m.iconCategory = c.key } label: { Label(c.label, systemImage: c.icon).frame(maxWidth: .infinity, alignment: .leading).padding(6).background(m.iconCategory == c.key ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 7)).contentShape(.rect) }.buttonStyle(.plain)
                    }
                }
            }.frame(width: 160)
            VStack(spacing: 8) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search \(SymbolCatalogue.names.count.formatted()) icons", text: $m.iconQuery).textFieldStyle(.plain) }
                    .padding(9).background(.thinMaterial, in: .rect(cornerRadius: 10))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                        ForEach(list.prefix(1500), id: \.self) { n in
                            Image(systemName: n).font(.system(size: 22)).frame(width: 52, height: 46).background(m.selectedIcon == n ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 8)).contentShape(.rect)
                                .onTapGesture { m.selectedIcon = n }.onTapGesture(count: 2) { insertIcon(n) }.help(n)
                        }
                    }
                }
                Text("\(list.count.formatted()) icons · Apple's SF Symbols, built into macOS — great for your own documents; check Apple's terms before using them in something you publish commercially.").font(.fo(.caption)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("PREVIEW").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
                Image(systemName: m.selectedIcon ?? "star").font(.system(size: 70, weight: MediaPanelModel.weights[m.iconWeight].2)).foregroundStyle(Color(hex: m.iconColor)).frame(width: 170, height: 130).background(.white, in: .rect(cornerRadius: 12))
                Text(m.selectedIcon ?? "Pick an icon").font(.fo(.caption)).foregroundStyle(.secondary).lineLimit(2)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 6), spacing: 6) {
                    ForEach(["#1d1d1f", "#ffffff", "#2f6ef6", "#e5484d", "#30a46c", "#f5a524", "#8e4ec6", "#0ea5b7", "#ff6a88", "#636366", "#7a9bff", "#a68a64"], id: \.self) { c in
                        Button { m.iconColor = c } label: { Circle().fill(Color(hex: c)).frame(width: 20, height: 20).overlay(Circle().stroke(Color.primary.opacity(m.iconColor == c ? 0.9 : 0.25), lineWidth: m.iconColor == c ? 2 : 1)) }.buttonStyle(.plain)
                    }
                }
                ColorPicker("Custom", selection: Binding(get: { Color(hex: m.iconColor) }, set: { m.iconColor = $0.hexString }))
                Picker("Weight", selection: $m.iconWeight) { ForEach(0..<4, id: \.self) { Text(MediaPanelModel.weights[$0].0).tag($0) } }
                Spacer()
                Button { if let n = m.selectedIcon { insertIcon(n) } } label: { Label("Insert icon", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.glassProminent).disabled(m.selectedIcon == nil)
            }.frame(width: 180)
        }
    }
    func insertIcon(_ n: String) {
        guard let p = Media.symbolPNG(n, color: NSColor(Color(hex: m.iconColor)), weight: MediaPanelModel.weights[m.iconWeight].1) else { m.error = "Couldn't draw that icon."; return }
        use(p)
    }

    // MARK: backgrounds
    var backgrounds: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(BackgroundSpec.all()) { b in
                        b.view.frame(height: 90).clipShape(.rect(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1))).contentShape(.rect)
                            .onTapGesture { if var p = Media.png(b.view, size: aspect) { p.isBackground = true; use(p) } }
                            .contextMenu { Button("Save to My library") { if let p = Media.png(b.view, size: aspect) { MediaLibraryStore.save(p, title: "Background"); m.reloadLibrary(); m.note = "Saved to My library" } } }
                    }
                }
            }
            Text("Made on your Mac at \(Int(aspect.width)) × \(Int(aspect.height)) — no downloads, no licences to worry about.").font(.fo(.caption)).foregroundStyle(.secondary)
        }
    }

    // MARK: library
    var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = true; if p.runModal() == .OK { let n = MediaLibraryStore.importFiles(p.urls); m.reloadLibrary(); m.note = "Added \(n) image\(n == 1 ? "" : "s")" } } label: { Label("Add images…", systemImage: "plus") }.buttonStyle(.glass)
                Text("Drop images here too. Your library is stored with your documents, so it syncs with FreeOffice Cloud.").font(.fo(.caption)).foregroundStyle(.secondary)
            }
            ScrollView {
                if m.library.isEmpty { Text("Nothing here yet. Right-click a photo or background and choose Save to My library.").foregroundStyle(.secondary).padding(.top, 60) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(m.library) { it in
                        Group { if let i = NSImage(contentsOf: it.url) { Image(nsImage: i).resizable().scaledToFill() } else { Color.gray.opacity(0.2) } }
                            .frame(minWidth: 0, maxWidth: .infinity).frame(height: 110).clipShape(.rect(cornerRadius: 10)).contentShape(.rect)
                            .onTapGesture { if let p = MediaLibraryStore.pick(it) { use(p) } }
                            .contextMenu { Button("Insert") { if let p = MediaLibraryStore.pick(it) { use(p) } }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }; Divider(); Button("Remove from library", role: .destructive) { MediaLibraryStore.delete(it); m.reloadLibrary() } }
                            .help(it.credit ?? it.title)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in let n = MediaLibraryStore.importFiles(urls); m.reloadLibrary(); m.note = "Added \(n) image\(n == 1 ? "" : "s")"; return n > 0 } isTargeted: { dropping = $0 }
            .overlay { if dropping { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10])) } }
        }
    }
}
