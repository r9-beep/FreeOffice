import SwiftUI
import AppKit

private let transitions: [(String, String)] = [("None", "none"), ("Fade", "fade"), ("Slide", "slide"), ("Push", "push"), ("Zoom", "zoom")]
private let bgPresets: [(String, String)] = [("White", "#ffffff"), ("Light grey", "#f2f2f4"), ("Midnight", "#14213d"), ("Blue", "#3b6cf6"), ("Green", "#10291f"), ("Warm", "#f6f1e7"), ("Black", "#000000")]

struct SlidesEditorView: View {
    @StateObject private var m: SlidesModel
    let docTab: Tab
    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? SlidesModel) ?? { let x = SlidesModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        HStack(spacing: 0) {
            thumbnails
            VStack(spacing: 8) {
                ribbon.padding(.horizontal, 12).padding(.top, 10)
                CanvasSurface(m: m)
                if m.notesOpen { notesPane.padding(.horizontal, 14).padding(.bottom, 10) }
            }
            ElementInspector(m: m, themeFonts: true) { slideSettings }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled presentation", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                Button { Presenter.start(m.slides, m.deck, m.images, from: m.cur) } label: { Label("Present", systemImage: "play.fill") }
            }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled presentation" : t }
        .onChange(of: m.selected) { _, _ in m.sel = nil; m.editing = nil }
        .onAppear { docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() } }
        .onDisappear { m.saver.flush() }
    }

    // MARK: thumbnails
    var thumbnails: some View {
        List(selection: $m.selected) {
            ForEach(Array(m.slides.enumerated()), id: \.element.id) { i, s in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1)").font(.fo(.caption)).foregroundStyle(.secondary).frame(width: 18)
                    SlideThumb(slide: s, deck: m.deck, number: i + 1, images: m.images, width: 150).clipShape(.rect(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(m.selected == s.id ? Color.accentColor : .black.opacity(0.18), lineWidth: m.selected == s.id ? 2.5 : 0.5) }
                        .allowsHitTesting(false)
                }
                .tag(s.id).listRowSeparator(.hidden).listRowBackground(Color.clear)
                .contextMenu {
                    Button("Duplicate") { m.selected = s.id; m.duplicateSlide() }
                    Menu("New slide after") { ForEach(SlideLayout.allCases) { l in Button(l.name) { m.selected = s.id; m.addSlide(l) } } }
                    Button("Delete", role: .destructive) { m.selected = s.id; m.deleteSlide() }
                }
            }
            .onMove { m.slides.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).frame(width: 210)
        .background(.ultraThinMaterial)
    }

    // MARK: ribbon
    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
    }
    var ribbon: some View {
        GlassEffectContainer(spacing: 8) {
            WrapLayout(spacing: 8) {
                group {
                    Menu {
                        ForEach(SlideLayout.allCases) { l in Button { m.addSlide(l) } label: { Label(l.name, systemImage: l.symbol) } }
                    } label: { Label("New slide", systemImage: "plus.rectangle.on.rectangle") }.menuStyle(.borderlessButton).fixedSize()
                    Button { m.duplicateSlide() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate slide")
                    Button { m.deleteSlide() } label: { Image(systemName: "trash") }.help("Delete slide").disabled(m.slides.count < 2)
                }
                group {
                    Button { m.addDefault("text") } label: { Label("Text", systemImage: "textformat") }
                    Menu {
                        Button("Rectangle") { m.addDefault("rect") }
                        Button("Rounded rectangle") { m.addDefault("rect"); if let i = m.index { m.els[i].rad = 28 } }
                        Button("Ellipse") { m.addDefault("ellipse") }
                        Button("Line") { m.addDefault("line") }
                    } label: { Label("Shape", systemImage: "square.on.circle") }.menuStyle(.borderlessButton).fixedSize()
                    Button { m.addImage() } label: { Label("Image", systemImage: "photo") }
                }
                group {
                    Menu {
                        ForEach(slideThemes) { t in Button { m.deck.theme = t.id } label: { Label(t.name, systemImage: m.deck.theme == t.id ? "checkmark.circle.fill" : "circle.fill").foregroundStyle(Color(hex: t.accent)) } }
                    } label: { Label("Theme", systemImage: "paintpalette") }.menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        ForEach(bgPresets, id: \.1) { n, h in Button { m.setBackground(h) } label: { Label(n, systemImage: "circle.fill").foregroundStyle(Color(hex: h)) } }
                        Divider(); Button("Theme background") { m.setBackground("") }
                    } label: { Label("Background", systemImage: "rectangle.fill") }.menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        ForEach(transitions, id: \.1) { n, t in Button(n) { m.deck.transition = t } }
                    } label: { Label("Transition", systemImage: "sparkles.tv") }.menuStyle(.borderlessButton).fixedSize()
                }
                group {
                    Button { Presenter.start(m.slides, m.deck, m.images, from: m.cur) } label: { Label("Present", systemImage: "play.fill") }
                    Button { Presenter.start(m.slides, m.deck, m.images, from: 0) } label: { Image(systemName: "backward.end.fill") }.help("Present from the first slide")
                    Button { m.notesOpen.toggle() } label: { Image(systemName: m.notesOpen ? "note.text" : "note.text.badge.plus") }.help("Speaker notes")
                    Menu {
                        Button("PDF…") { m.exportPDF() }; Button("PowerPoint (.pptx)…") { m.exportPPTX() }; Button("Web slideshow (.html)…") { m.exportHTML() }
                        Divider(); Button("This slide as PNG…") { m.exportPNGCurrent() }; Button("Every slide as PNG…") { m.exportPNGAll() }
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            .buttonStyle(.plain)
        }
    }

    var notesPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Speaker notes", systemImage: "note.text").font(.fo(.caption)).foregroundStyle(.secondary)
            TextEditor(text: m.notesBinding).font(.fo(.body)).scrollContentBackground(.hidden).frame(height: 70).padding(6)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    // MARK: inspector (slide & deck settings, shown above the element controls)
    var slideSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("THEME").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 8), count: 4), spacing: 8) {
                    ForEach(slideThemes) { t in
                        Button { m.deck.theme = t.id } label: {
                            ZStack { RoundedRectangle(cornerRadius: 8).fill(Color(hex: t.bg)); Text("Aa").font(.custom(t.heading, size: 15).bold()).foregroundStyle(Color(hex: t.fg)); Circle().fill(Color(hex: t.accent)).frame(width: 9, height: 9).offset(x: 14, y: 12) }
                                .frame(width: 48, height: 34).overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(m.deck.theme == t.id ? Color.accentColor : .black.opacity(0.2), lineWidth: m.deck.theme == t.id ? 2.5 : 0.5) }
                        }.buttonStyle(.plain).help(t.name)
                    }
                }
                Text(themeFor(m.deck.theme).name).font(.fo(.caption)).foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 8) {
                Text("THIS SLIDE").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    ColorPicker("Background", selection: Binding(get: { Color(hex: m.slides[m.cur].bg.isEmpty ? m.theme.bg : m.slides[m.cur].bg) }, set: { m.setBackground($0.hexString) }))
                    Button("Theme") { m.setBackground("") }.buttonStyle(.glass).font(.fo(.caption))
                }
                Picker("Transition", selection: Binding(get: { m.slides[m.cur].transition }, set: { m.setTransition($0) })) {
                    Text("Deck default").tag(""); ForEach(transitions, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 8) {
                Text("EVERY SLIDE").font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary)
                TextField("Footer text", text: $m.deck.footer).textFieldStyle(.roundedBorder)
                Toggle("Slide numbers", isOn: $m.deck.numbers)
                Picker("Transition", selection: $m.deck.transition) { ForEach(transitions, id: \.1) { Text($0.0).tag($0.1) } }
                if let s = m.savedAt { Text("Saved \(s, format: .dateTime.hour().minute())").font(.fo(.caption)).foregroundStyle(.secondary) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}
