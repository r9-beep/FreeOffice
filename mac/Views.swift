// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - The "Fo" mark used across the UI (matches the Dock icons: black on white)

struct FMark: View {
    let letter: String
    var size: CGFloat = 44
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: -size * 0.02) {
            Text("F").font(.custom("HelveticaNeue-Bold", size: size * 0.56))
            Text(letter).font(.custom("HelveticaNeue-Bold", size: size * 0.40))
        }
        .foregroundStyle(.black)
        .frame(width: size, height: size)
        .background(LinearGradient(colors: [.white, Color(white: 0.92)], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: size * 0.24))
        .overlay { RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.black.opacity(0.14), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: size * 0.1, y: size * 0.05)
    }
}

// MARK: - Root: sidebar + tabs

struct RootView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var storage: Storage
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TabBar()
                if let tab = m.current { TabPage(tab: tab) }
            }
            .background { Backdrop() }
        }
        .preferredColorScheme(storage.theme.scheme)
        .font(.fo(size: 13))
        .frame(minWidth: 1100, minHeight: 680)
    }
}

struct TabPage: View {
    @EnvironmentObject var m: Model
    @ObservedObject var tab: Tab
    var body: some View {
        Group {
            switch tab.kind {
            case .home: LauncherView()
            case .cloud: CloudView()
            case .updates: UpdatesView()
            case .learn(let k): LearnView(initial: k)
            case .doc(let key, let id):
                switch key {
                case "writer": WriterView(id: id, dir: m.storage.activeDir, tab: tab)
                case "sheets": SheetsEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                case "slides": SlidesEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                case "poster": PosterEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                case "diagrams": DiagramEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                case "planner": PlannerEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                case "reader": ReaderEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                case "math": MathEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                default: DataEditorView(id: id, dir: m.storage.activeDir, tab: tab)
                }
            }
        }
        .id(tab.id.uuidString + String(describing: tab.kind))
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @EnvironmentObject var m: Model
    var body: some View {
        GlassEffectContainer(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(m.tabs) { TabChip(tab: $0) }
                    Button { m.newTab() } label: { Image(systemName: "plus").font(.fo(.callout).weight(.semibold)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).help("New tab")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

struct TabChip: View {
    @EnvironmentObject var m: Model
    @ObservedObject var tab: Tab
    var selected: Bool { m.selected == tab.id }
    var body: some View {
        HStack(spacing: 7) {
            if let a = tab.app { FMark(letter: a.letter, size: 20) } else { Image(systemName: tab.symbol).frame(width: 20) }
            Text(tab.title).font(.fo(.callout).weight(selected ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            Button { m.close(tab) } label: { Image(systemName: "xmark").font(.fo(.caption2).weight(.bold)).foregroundStyle(.secondary).frame(width: 16, height: 16) }
                .buttonStyle(.plain).help("Close tab")
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
        .contentShape(.capsule)
        .onTapGesture { m.select(tab) }
        .glassEffect(selected ? .regular.tint((tab.app?.tint ?? .indigo).opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var storage: Storage
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            Section {
                row("Home", "house.fill", .indigo, m.current?.kind == .home) { m.goHome() }
                CloudRow()
                UpdatesRow()
                row("Learn", "graduationcap.fill", .orange, isLearn) { m.openLearn(nil) }
            }
            Section("Create") {
                ForEach(m.visibleApps) { app in
                    DisclosureGroup(isExpanded: binding(app.key)) {
                        Button { m.open(app) } label: { Label("Blank \(app.one)", systemImage: "plus") }.buttonStyle(.plain)
                        ForEach(allTemplates.filter { $0.appKey == app.key }) { t in
                            Button { m.create(from: t) } label: { Label(t.name, systemImage: "sparkles.rectangle.stack") }.buttonStyle(.plain)
                        }
                        Button { m.openLearn(app.key) } label: { Label("Tutorial", systemImage: "graduationcap") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 10) { FMark(letter: app.letter, size: 24); Text(app.name).fontWeight(.medium) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(storage.theme == .plain ? Color(white: 0.975) : (storage.theme == .plainDark ? Color(white: 0.12) : Color.clear))
        .safeAreaInset(edge: .bottom) { VStack(spacing: 0) { UpdateCard(); ThemePicker().padding(.horizontal, 10).padding(.bottom, 10) } }
        .onAppear { if let s = m.single { expanded = [s.key] } }
        .onChange(of: m.selected) { _, _ in if let a = m.current?.app { expanded.insert(a.key) } }
    }

    var isLearn: Bool { if case .learn = m.current?.kind { return true }; return false }
    func binding(_ k: String) -> Binding<Bool> { Binding(get: { expanded.contains(k) }, set: { if $0 { expanded.insert(k) } else { expanded.remove(k) } }) }

    func row(_ title: String, _ symbol: String, _ tint: Color, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 24)
                Text(title).fontWeight(on ? .semibold : .regular)
                Spacer()
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(on ? tint.opacity(0.16) : .clear).padding(.horizontal, 6))
    }
}

struct UpdatesRow: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var updater: Updater
    var on: Bool { m.current?.kind == .updates }
    var body: some View {
        Button { m.openUpdates() } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(updater.available != nil ? Color.green : .gray).frame(width: 24)
                Text("Updates").fontWeight(on ? .semibold : .regular)
                Spacer()
                if let r = updater.available { Text(r.version).font(.fo(.caption2).weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2).background(.green, in: .capsule).foregroundStyle(.white) }
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(on ? Color.green.opacity(0.16) : .clear).padding(.horizontal, 6))
    }
}

/// "Update available" card pinned to the bottom of the sidebar.
struct UpdateCard: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var updater: Updater
    var body: some View {
        if let r = updater.available {
            VStack(alignment: .leading, spacing: 8) {
                Label("Update available", systemImage: "arrow.down.circle.fill").font(.fo(.callout).weight(.semibold)).foregroundStyle(.green)
                Text("Version \(r.version) is ready.").font(.fo(.caption)).foregroundStyle(.secondary)
                if updater.installError != nil { Label("Couldn't install — see Details", systemImage: "exclamationmark.triangle.fill").font(.fo(.caption)).foregroundStyle(.orange) }
                HStack {
                    Button { updater.install() } label: { Text("Update now").frame(maxWidth: .infinity) }.buttonStyle(.glassProminent).tint(.green)
                    Button { m.openUpdates() } label: { Text("Details") }.buttonStyle(.glass)
                }
            }
            .padding(12).glassEffect(.regular.tint(.green.opacity(0.18)), in: .rect(cornerRadius: 18)).padding(10)
        } else if updater.state == .downloading || updater.state == .installing {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(updater.state == .downloading ? "Downloading update…" : "Installing…").font(.fo(.callout)) }
                .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18)).padding(10)
        }
    }
}

struct CloudRow: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var storage: Storage
    var on: Bool { m.current?.kind == .cloud }
    var body: some View {
        Button { m.openCloud() } label: {
            HStack(spacing: 10) {
                Image(systemName: storage.statusSymbol).foregroundStyle(storage.statusColor == .secondary ? Color.teal : storage.statusColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text("FreeOffice Cloud").fontWeight(on ? .semibold : .regular)
                    Text(storage.statusTitle).font(.fo(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(on ? Color.teal.opacity(0.16) : .clear).padding(.horizontal, 6))
    }
}

// MARK: - Home (launcher), light-mode, maximalist

struct LauncherView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var storage: Storage
    @EnvironmentObject var updater: Updater
    @State private var pendingDelete: FileEntry?
    @State private var search = ""
    @State private var chip: String?

    var single: AppInfo? { m.single }
    var templates: [Template] {
        allTemplates.filter { t in
            (single == nil || t.appKey == single!.key) && (chip == nil || t.appKey == chip) &&
            (search.isEmpty || t.name.localizedCaseInsensitiveContains(search) || t.blurb.localizedCaseInsensitiveContains(search))
        }
    }
    var files: [FileEntry] { m.files.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                hero
                section("Start something new", "sparkles") {
                    GlassEffectContainer(spacing: 18) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 260), spacing: 16)], spacing: 18) {
                            ForEach(m.visibleApps) { AppCard(app: $0) }
                        }
                    }
                }
                if !templates.isEmpty || chip != nil {
                    section("Templates", "square.grid.2x2.fill") {
                        VStack(alignment: .leading, spacing: 16) {
                            if single == nil { chips }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 20)], spacing: 22) {
                                ForEach(templates) { TemplateCard(t: $0) }
                            }
                        }
                    }
                }
                section("Recent files", "clock.fill", trailing: AnyView(
                    Button { m.revealStore() } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(.glass))) {
                    if files.isEmpty {
                        Text(search.isEmpty ? "Nothing yet. Pick an app or a template above." : "No files match “\(search)”.").foregroundStyle(.secondary).padding(.vertical, 6)
                    } else {
                        GlassEffectContainer(spacing: 10) { VStack(spacing: 10) { ForEach(files) { f in FileRow(file: f) { pendingDelete = f } } } }
                    }
                }
            }
            .padding(36).frame(maxWidth: 1180).frame(maxWidth: .infinity)
        }
        .onAppear { m.reloadFiles() }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")” permanently?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let f = pendingDelete { m.delete(f) }; pendingDelete = nil }
        } message: { Text("This can't be undone.") }
    }

    var heroGradient: LinearGradient {
        switch storage.theme {
        case .colourful: return LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.85), Color(red: 0.75, green: 0.2, blue: 0.7), Color(red: 0.95, green: 0.45, blue: 0.3)], startPoint: .leading, endPoint: .trailing)
        case .dark: return LinearGradient(colors: [Color(red: 0.6, green: 0.65, blue: 1.0), Color(red: 0.95, green: 0.6, blue: 0.9), Color(red: 1.0, green: 0.75, blue: 0.55)], startPoint: .leading, endPoint: .trailing)
        case .plain: return LinearGradient(colors: [.black, Color(white: 0.25)], startPoint: .leading, endPoint: .trailing)
        case .plainDark: return LinearGradient(colors: [.white, Color(white: 0.7)], startPoint: .leading, endPoint: .trailing)
        }
    }
    var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            FMark(letter: single?.letter ?? "o", size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(single.map { "FreeOffice \($0.name)" } ?? "FreeOffice")
                    .font(.fo(size: 52, weight: .heavy))
                    .foregroundStyle(heroGradient)
                Text(single?.blurb ?? "Documents · Spreadsheets · Slides · Posters · Databases")
                    .font(.fo(.title3)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 10) {
                if let r = updater.available {
                    Button { m.openUpdates() } label: {
                        HStack(spacing: 8) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green); Text("Update available · \(r.version)").font(.fo(.callout).weight(.semibold)) }
                            .padding(.horizontal, 14).padding(.vertical, 8).contentShape(.capsule)
                    }.buttonStyle(.plain).glassEffect(.regular.tint(.green.opacity(0.3)).interactive(), in: .capsule)
                }
                Button { m.openCloud() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: storage.statusSymbol).foregroundStyle(storage.statusColor == .secondary ? Color.teal : storage.statusColor)
                        Text(storage.statusTitle).font(.fo(.callout).weight(.medium))
                    }.padding(.horizontal, 14).padding(.vertical, 8).contentShape(.capsule)
                }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files & templates", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10).frame(width: 280)
                .glassEffect(.regular, in: .capsule)
            }
        }
    }

    var chips: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                chipButton("All", nil, .gray)
                ForEach(allApps) { chipButton($0.name, $0.key, $0.tint) }
            }
        }
    }
    func chipButton(_ title: String, _ key: String?, _ tint: Color) -> some View {
        Button { chip = key } label: { Text(title).font(.fo(.callout).weight(.medium)).padding(.horizontal, 14).padding(.vertical, 7) }
            .buttonStyle(.plain)
            .glassEffect(chip == key ? .regular.tint(tint.opacity(0.55)).interactive() : .regular.interactive(), in: .capsule)
    }

    func section<C: View>(_ title: String, _ symbol: String, trailing: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(title, systemImage: symbol).font(.fo(.title2).weight(.bold)); Spacer(); trailing }
            content()
        }
    }
}

struct AppCard: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var storage: Storage
    let app: AppInfo
    var body: some View {
        Button { m.open(app) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack { FMark(letter: app.letter, size: 48); Spacer(); Image(systemName: app.symbol).font(.fo(.title)).foregroundStyle(app.tint).symbolRenderingMode(.hierarchical) }
                Spacer(minLength: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New \(app.one)").font(.fo(.headline))
                    Text("FreeOffice \(app.name)").font(.fo(.subheadline)).foregroundStyle(.secondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(app.tint.opacity(0.28 * storage.theme.tint)).interactive(), in: .rect(cornerRadius: 26))
    }
}

// Mini "page" art used on template thumbnails
struct ArtView: View {
    let art: Art
    var body: some View {
        switch art {
        case .page:
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.75)).frame(width: 60, height: 8)
                ForEach(0..<7, id: \.self) { i in RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.18)).frame(width: i % 3 == 2 ? 70 : 104, height: 4) }
            }
        case .table:
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<5, id: \.self) { r in GridRow { ForEach(0..<4, id: \.self) { c in Rectangle().fill(r == 0 ? .black.opacity(0.6) : .black.opacity(c == 0 ? 0.25 : 0.12)).frame(width: 26, height: 10) } } }
            }
        case .slide:
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.8)).frame(width: 70, height: 9)
                ForEach(0..<3, id: \.self) { i in HStack(spacing: 4) { Circle().fill(.black.opacity(0.4)).frame(width: 4); RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.2)).frame(width: 60 + CGFloat(i) * 12, height: 4) } }
            }
        case .poster:
            ZStack(alignment: .bottomLeading) {
                Circle().fill(.black.opacity(0.15)).frame(width: 60).offset(x: 36, y: -22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BIG").font(.fo(size: 24, weight: .black)); Text("TYPE").font(.fo(size: 24, weight: .black))
                    RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.4)).frame(width: 60, height: 4)
                }.foregroundStyle(.black.opacity(0.85))
            }
        case .graph:
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.7), lineWidth: 1.5).frame(width: 44, height: 18)
                HStack(spacing: 18) { ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.5), lineWidth: 1.5).frame(width: 40, height: 16) } }
                    .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.35)).frame(width: 58, height: 1.5).offset(y: -4) }
            }
        case .cards:
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 6) { Circle().fill(.black.opacity(0.35)).frame(width: 10); VStack(alignment: .leading, spacing: 3) { RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.55)).frame(width: 50, height: 4); RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.2)).frame(width: 74, height: 3) }; Spacer(minLength: 0) }
                        .padding(5).frame(width: 118).background(.white.opacity(0.7), in: .rect(cornerRadius: 6))
                }
            }
        }
    }
}

struct TemplateCard: View {
    @EnvironmentObject var m: Model
    let t: Template
    var body: some View {
        Button { m.create(from: t) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: t.colors.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    ArtView(art: t.art).padding(14)
                        .frame(width: 150, height: 112, alignment: .topLeading)
                        .background(.white.opacity(0.94), in: .rect(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    FMark(letter: t.app.letter, size: 26).padding(10)
                }
                .frame(height: 150).clipShape(.rect(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(.fo(.headline))
                    Text(t.blurb).font(.fo(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, 4)
            }
            .padding(8)
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }
}

struct FileRow: View {
    @EnvironmentObject var m: Model
    let file: FileEntry
    let onDelete: () -> Void
    var body: some View {
        Button { m.open(file.app, doc: file.docId) } label: {
            HStack(spacing: 14) {
                FMark(letter: file.app.letter, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.title).font(.fo(.body).weight(.medium)).lineLimit(1)
                    Text(file.app.name).font(.fo(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(file.modified, format: .dateTime.day().month().year().hour().minute()).font(.fo(.caption)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .contextMenu { Button("Open") { m.open(file.app, doc: file.docId) }; Button("Delete…", role: .destructive, action: onDelete) }
    }
}

// Backdrop per theme: pastel mesh (Colourful), deep mesh (Dark), or plain white.
struct Backdrop: View {
    @EnvironmentObject var storage: Storage
    var body: some View {
        Group {
            switch storage.theme {
            case .plain: Color.white
            case .plainDark: Color(white: 0.09)
            case .colourful: mesh(colourfulColors, orbOpacity: 0.38)
            case .dark: mesh(darkColors, orbOpacity: 0.5)
            }
        }
        .ignoresSafeArea()
    }
    let colourfulColors: [Color] = [Color(red: 0.93, green: 0.95, blue: 1.0), Color(red: 0.82, green: 0.87, blue: 1.0), Color(red: 0.95, green: 0.97, blue: 1.0),
                                    Color(red: 0.99, green: 0.88, blue: 0.96), Color(red: 0.84, green: 0.93, blue: 1.0), Color(red: 0.88, green: 0.98, blue: 0.96),
                                    Color(red: 0.97, green: 0.97, blue: 1.0), Color(red: 1.0, green: 0.90, blue: 0.88), Color(red: 0.92, green: 0.95, blue: 1.0)]
    let darkColors: [Color] = [Color(red: 0.05, green: 0.06, blue: 0.12), Color(red: 0.10, green: 0.10, blue: 0.28), Color(red: 0.04, green: 0.08, blue: 0.16),
                               Color(red: 0.16, green: 0.07, blue: 0.24), Color(red: 0.08, green: 0.20, blue: 0.34), Color(red: 0.05, green: 0.14, blue: 0.20),
                               Color(red: 0.03, green: 0.03, blue: 0.07), Color(red: 0.20, green: 0.08, blue: 0.20), Color(red: 0.04, green: 0.05, blue: 0.10)]

    func mesh(_ colors: [Color], orbOpacity: Double) -> some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]], colors: colors)
            TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                GeometryReader { g in
                    ZStack {
                        orb(.pink, g, 0.18 + 0.06 * sin(t / 5), 0.22 + 0.05 * cos(t / 7), 380)
                        orb(.blue, g, 0.82 + 0.05 * cos(t / 6), 0.30 + 0.06 * sin(t / 4), 440)
                        orb(.orange, g, 0.55 + 0.07 * sin(t / 8), 0.85 + 0.04 * cos(t / 5), 340)
                        orb(.purple, g, 0.10 + 0.04 * cos(t / 9), 0.80 + 0.05 * sin(t / 6), 300)
                        orb(.mint, g, 0.92 + 0.03 * sin(t / 7), 0.88 + 0.04 * cos(t / 8), 320)
                    }.blur(radius: 80).opacity(orbOpacity)
                }
            }
        }
    }
    func orb(_ c: Color, _ g: GeometryProxy, _ x: Double, _ y: Double, _ d: CGFloat) -> some View {
        Circle().fill(c).frame(width: d, height: d).position(x: g.size.width * x, y: g.size.height * y)
    }
}
