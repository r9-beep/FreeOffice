import SwiftUI
import Combine

// MARK: - App registry

struct AppInfo: Identifiable, Hashable {
    let key: String, name: String, letter: String, symbol: String, page: String, one: String, blurb: String
    let tint: Color
    var id: String { key }
    var mark: String { "F" + letter }
}

let allApps: [AppInfo] = [
    AppInfo(key: "writer", name: "Writer", letter: "w", symbol: "doc.text", page: "writer.html", one: "document", blurb: "Documents", tint: .blue),
    AppInfo(key: "sheets", name: "Sheets", letter: "s", symbol: "tablecells", page: "sheets.html", one: "spreadsheet", blurb: "Spreadsheets", tint: .green),
    AppInfo(key: "slides", name: "Slides", letter: "l", symbol: "rectangle.on.rectangle", page: "slides.html", one: "presentation", blurb: "Presentations", tint: .orange),
    AppInfo(key: "poster", name: "Poster", letter: "p", symbol: "paintpalette", page: "poster.html", one: "poster", blurb: "Posters & layouts", tint: .pink),
    AppInfo(key: "diagrams", name: "Diagrams", letter: "g", symbol: "point.3.connected.trianglepath.dotted", page: "diagrams.html", one: "diagram", blurb: "Flowcharts & diagrams", tint: .teal),
    AppInfo(key: "planner", name: "Planner", letter: "m", symbol: "calendar", page: "planner.html", one: "plan", blurb: "Calendar, tasks & timeline", tint: .red),
    AppInfo(key: "reader", name: "Reader", letter: "r", symbol: "doc.richtext", page: "reader.html", one: "PDF", blurb: "PDFs: read, mark up, sign", tint: .brown),
    AppInfo(key: "math", name: "Math", letter: "x", symbol: "function", page: "math.html", one: "notebook", blurb: "Calculator, equations & graphs", tint: .indigo),
    AppInfo(key: "data", name: "Data", letter: "d", symbol: "cylinder.split.1x2", page: "data.html", one: "database", blurb: "Databases", tint: .purple),
]
func appFor(_ key: String) -> AppInfo? { allApps.first { $0.key == key } }

struct FileEntry: Identifiable {
    let app: AppInfo, docId: String, title: String, modified: Date
    var id: String { app.key + ":" + docId }
}

// MARK: - Tabs

final class Tab: ObservableObject, Identifiable {
    enum Kind: Equatable { case home, cloud, updates, learn(String?), doc(String, String) }   // doc(app key, doc id)
    let id = UUID()
    @Published var kind: Kind
    @Published var title: String
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onFormat: ((String) -> Void)?
    var editorModel: AnyObject?          // keeps an editor's state (and undo history) when you switch tabs
    init(_ kind: Kind, title: String) { self.kind = kind; self.title = title }

    var app: AppInfo? { if case .doc(let k, _) = kind { return appFor(k) }; return nil }
    var symbol: String {
        switch kind { case .home: return "house.fill"; case .cloud: return "icloud.fill"; case .updates: return "arrow.down.circle.fill"; case .learn: return "graduationcap.fill"; case .doc: return app?.symbol ?? "doc" }
    }
}

// MARK: - Model

final class Model: ObservableObject {
    static weak var shared: Model?
    static var pendingURLs: [URL] = []
    @Published var tabs: [Tab] = []
    @Published var selected: UUID?
    @Published var files: [FileEntry] = []
    let storage = Storage()
    let updater: Updater

    let appKey = (Bundle.main.object(forInfoDictionaryKey: "FOApp") as? String) ?? ""
    let appName = (Bundle.main.object(forInfoDictionaryKey: "FOName") as? String) ?? "FreeOffice"
    private var bag = Set<AnyCancellable>()

    var visibleApps: [AppInfo] { appKey.isEmpty ? allApps : allApps.filter { $0.key == appKey } }
    var single: AppInfo? { appKey.isEmpty ? nil : appFor(appKey) }
    var current: Tab? { tabs.first { $0.id == selected } }

    init() {
        updater = Updater(storage: storage)
        Model.shared = self
        let home = Tab(.home, title: "Home")
        tabs = [home]; selected = home.id
        reloadFiles()
        storage.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.reloadFiles() } }.store(in: &bag)

        let queued = Model.pendingURLs; Model.pendingURLs = []
        DispatchQueue.main.async { for u in queued { DocLinks.open(url: u) } }
        // Launch hooks (handy for scripting/testing): FO_TEMPLATE=<id>, FO_OPEN=<app key>, FO_TAB=cloud|learn
        let env = ProcessInfo.processInfo.environment
        DispatchQueue.main.async { [self] in
            if let tid = env["FO_TEMPLATE"], let t = allTemplates.first(where: { $0.id == tid }) { create(from: t) }
            else if let k = env["FO_OPEN"], let a = appFor(k) { open(a) }
            else if env["FO_TAB"] == "cloud" { openCloud() }
            else if env["FO_TAB"] == "learn" { openLearn(nil) }
            else if env["FO_TAB"] == "updates" { openUpdates() }
            if env["FO_UPDATE"] == "install" { updater.check(); autoInstall() }
        }
    }

    static func newId() -> String { String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) }

    // MARK: tab management
    func select(_ t: Tab) { selected = t.id }

    /// Opens `kind` in the current tab if that's an empty Home tab (like a browser's new-tab page), otherwise in a new tab.
    private func place(_ kind: Tab.Kind, title: String) -> Tab {
        if let cur = current, cur.kind == .home { cur.kind = kind; cur.title = title; return cur }
        let t = Tab(kind, title: title); tabs.append(t); selected = t.id; return t
    }
    func newTab() {
        if let cur = current, cur.kind == .home { return }
        let t = Tab(.home, title: "Home"); tabs.append(t); selected = t.id
    }
    func close(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty { let h = Tab(.home, title: "Home"); tabs = [h]; selected = h.id }
        else if selected == t.id { selected = tabs[min(i, tabs.count - 1)].id }
    }
    func closeCurrent() { if let c = current { close(c) } }
    func step(_ d: Int) { guard let i = tabs.firstIndex(where: { $0.id == selected }), !tabs.isEmpty else { return }; selected = tabs[(i + d + tabs.count) % tabs.count].id }
    func goHome() { if let h = tabs.first(where: { $0.kind == .home }) { select(h) } else { newTab() } }

    func openCloud() {
        if let t = tabs.first(where: { $0.kind == .cloud }) { select(t); return }
        _ = place(.cloud, title: "FreeOffice Cloud")
    }
    func openUpdates() {
        if let t = tabs.first(where: { $0.kind == .updates }) { select(t); return }
        _ = place(.updates, title: "Updates")
    }
    /// Test hook: wait for the check, then install.
    private func autoInstall(_ tries: Int = 0) {
        if updater.available != nil { updater.install(); return }
        if tries < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.autoInstall(tries + 1) } }
    }
    func openLearn(_ key: String?) {
        if let t = tabs.first(where: { if case .learn = $0.kind { return true }; return false }) { t.kind = .learn(key); select(t); return }
        _ = place(.learn(key), title: "Learn")
    }

    /// Every editor is native SwiftUI.
    func open(_ app: AppInfo, doc: String? = nil) {
        let id = doc ?? Model.newId()
        let kind = Tab.Kind.doc(app.key, id)
        if let t = tabs.first(where: { $0.kind == kind }) { select(t); return }
        _ = place(kind, title: app.name)
    }
    /// A PDF handed to us from Finder or "Open With": copy it into a new Reader document.
    func openPDF(_ url: URL) {
        guard let id = ReaderModel.importPDF(url, into: storage.activeDir), let app = appFor("reader") else { return }
        reloadFiles(); open(app, doc: id)
    }
    func create(from t: Template) {
        let id = Model.newId()
        storage.write(key: "office:\(t.appKey):\(id)", json: String(data: t.data(), encoding: .utf8))
        open(t.app, doc: id)
    }

    // MARK: files
    func reloadFiles() {
        var list: [FileEntry] = []
        for (key, json) in storage.entries() {
            let p = key.split(separator: ":").map(String.init)
            guard p.count == 3, let app = visibleApps.first(where: { $0.key == p[1] }),
                  let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            let t = (o["title"] as? String) ?? ""
            let ms = (o["modified"] as? Double) ?? 0
            list.append(FileEntry(app: app, docId: p[2], title: t.isEmpty ? "Untitled" : t, modified: Date(timeIntervalSince1970: ms / 1000)))
        }
        files = list.sorted { $0.modified > $1.modified }
    }
    func delete(_ f: FileEntry) {
        for t in tabs where t.kind == .doc(f.app.key, f.docId) { close(t) }
        storage.delete(key: "office:\(f.app.key):\(f.docId)")
        reloadFiles()
    }
    func revealStore() { NSWorkspace.shared.open(storage.activeDir) }
}
