// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit
import Charts

private let textPalette: [(String, String)] = [("Black", "#111111"), ("Grey", "#7a7a7a"), ("Red", "#d92d20"), ("Orange", "#f79009"), ("Green", "#12b76a"), ("Blue", "#2e6df6"), ("Purple", "#7a3ff2"), ("White", "#ffffff")]
private let fillPalette: [(String, String)] = [("Yellow", "#fff3b0"), ("Orange", "#ffd9b3"), ("Red", "#ffc9c4"), ("Green", "#c8f0d4"), ("Blue", "#cfe0ff"), ("Purple", "#e3d6ff"), ("Grey", "#e6e6e6"), ("Dark", "#2b2f3a")]
private let numberFormats: [(String, String)] = [("General", ""), ("Number  1,234", "n0"), ("Number  1,234.50", "n2"), ("Currency", "cur"), ("Percent", "pct"), ("Date", "date"), ("Scientific", "sci")]

struct SheetsEditorView: View {
    @StateObject private var m: SheetModel
    @FocusState private var gridFocus: Bool
    @FocusState private var editFocus: Bool
    @State private var findOpen = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var findInfo = ""
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var dragMode = 0              // 0 none · 1 cells · 2 row header
    @State private var lastX: CGFloat = 0
    @State private var resizeBase: Double?
    let docTab: Tab

    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? SheetModel) ?? { let x = SheetModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        VStack(spacing: 8) {
            ribbon
            formulaBar
            grid
            if !m.sheet.charts.isEmpty { chartsPanel }
            sheetTabs
        }
        .padding(14)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled spreadsheet", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
        }
        .alert("Rename sheet", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let i = renaming { m.renameSheet(i, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled spreadsheet" : t }
        .onChange(of: m.status) { _, s in if s != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { m.status = nil } } }
        .onAppear { gridFocus = true; docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() }; docTab.onFormat = { c in if c == "bold" { m.toggleBold() } else if c == "italic" { m.toggleItalic() } } }
        .onDisappear { m.saver.flush() }
    }

    // MARK: ribbon
    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
    }
    func menuLabel(_ t: String, _ symbol: String) -> some View { Label(t, systemImage: symbol).labelStyle(.titleAndIcon) }

    var ribbon: some View {
        GlassEffectContainer(spacing: 8) {
            WrapLayout(spacing: 8) {
                do {
                    group {
                        Button { m.toggleBold() } label: { Image(systemName: "bold") }.help("Bold (⌘B)")
                        Button { m.toggleItalic() } label: { Image(systemName: "italic") }.help("Italic (⌘I)")
                        Menu {
                            ForEach(textPalette, id: \.1) { n, h in Button { m.applyStyle { $0.color = h } } label: { Label(n, systemImage: "circle.fill").foregroundStyle(Color(hex: h)) } }
                            Divider(); Button("Default") { m.applyStyle { $0.color = "" } }
                        } label: { Image(systemName: "textformat") }.menuStyle(.borderlessButton).fixedSize().help("Text colour")
                        Menu {
                            ForEach(fillPalette, id: \.1) { n, h in Button { m.applyStyle { $0.fill = h } } label: { Label(n, systemImage: "circle.fill").foregroundStyle(Color(hex: h)) } }
                            Divider(); Button("No fill") { m.applyStyle { $0.fill = "" } }
                        } label: { Image(systemName: "drop.fill") }.menuStyle(.borderlessButton).fixedSize().help("Fill colour")
                    }
                    group {
                        Button { m.applyStyle { $0.align = "left" } } label: { Image(systemName: "text.alignleft") }
                        Button { m.applyStyle { $0.align = "center" } } label: { Image(systemName: "text.aligncenter") }
                        Button { m.applyStyle { $0.align = "right" } } label: { Image(systemName: "text.alignright") }
                        Menu {
                            ForEach(numberFormats, id: \.1) { n, code in Button(n) { m.applyStyle { $0.nf = code } } }
                        } label: { Text("123") }.menuStyle(.borderlessButton).fixedSize().help("Number format")
                    }
                    group {
                        Button { m.sortSelection(ascending: true) } label: { Image(systemName: "arrow.up.to.line") }.help("Sort A → Z by this column")
                        Button { m.sortSelection(ascending: false) } label: { Image(systemName: "arrow.down.to.line") }.help("Sort Z → A by this column")
                        Button { m.fillDown() } label: { Image(systemName: "arrow.down.to.line.compact") }.help("Fill down (⌘D)")
                        Button { m.fillRight() } label: { Image(systemName: "arrow.right.to.line.compact") }.help("Fill right (⌘R)")
                    }
                    group {
                        Menu {
                            Button("Insert row above") { m.insertRows() }; Button("Insert column left") { m.insertCols() }
                            Divider(); Button("Delete row(s)") { m.deleteRows() }; Button("Delete column(s)") { m.deleteCols() }
                            Divider(); Button("Clear formatting") { m.clearFormats() }
                        } label: { Text("Cells") }.menuStyle(.borderlessButton).fixedSize()
                        Menu {
                            Button("Column chart") { m.addChart(type: "bar") }; Button("Line chart") { m.addChart(type: "line") }
                            Button("Area chart") { m.addChart(type: "area") }; Button("Pie chart") { m.addChart(type: "pie") }
                        } label: { Label("Chart", systemImage: "chart.bar.xaxis") }.menuStyle(.borderlessButton).fixedSize()
                        Button { findOpen.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Find & replace (⌘F)")
                            .popover(isPresented: $findOpen) { findPanel }
                    }
                    group {
                        Menu {
                            Button("Import Excel (.xlsx)…") { m.importXLSX() }; Button("Import CSV…") { m.importCSV() }
                            Divider(); Button("Export Excel (.xlsx)…") { m.exportXLSX() }; Button("Export CSV (this sheet)…") { m.exportCSV() }
                        } label: { Label("File", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    var findPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find & replace").font(.fo(.headline))
            TextField("Find", text: $findText).textFieldStyle(.roundedBorder).onSubmit { runFind() }
            TextField("Replace with", text: $replaceText).textFieldStyle(.roundedBorder)
            HStack {
                Button("Find next") { runFind() }.buttonStyle(.glass)
                Button("Replace all") { let n = m.replaceAll(findText, with: replaceText); findInfo = "Replaced in \(n) cell\(n == 1 ? "" : "s")" }.buttonStyle(.glass).disabled(findText.isEmpty)
            }
            if !findInfo.isEmpty { Text(findInfo).font(.fo(.caption)).foregroundStyle(.secondary) }
        }.padding(16).frame(width: 280)
    }
    func runFind() { let n = m.findNext(findText); findInfo = n == 0 ? "No matches" : "\(n) match\(n == 1 ? "" : "es")" }

    var formulaBar: some View {
        HStack(spacing: 10) {
            Text(m.rect.label).font(.system(.body, design: .monospaced).weight(.semibold)).lineLimit(1).frame(minWidth: 56).padding(.horizontal, 10).padding(.vertical, 7).glassEffect(.regular, in: .capsule)
            Text("ƒx").italic().foregroundStyle(.secondary)
            TextField("Value or =formula, e.g. =SUM(A1:A5)*2", text: Binding(get: { m.editing ? m.draft : m.raw(m.addr) }, set: { new in if !m.editing { if new == m.raw(m.addr) { return }; m.startEdit() }; m.draft = new }))
                .textFieldStyle(.plain).padding(.horizontal, 14).padding(.vertical, 7).glassEffect(.regular, in: .capsule)
                .docMentions($m.draft)
                .onSubmit { m.commitEdit(); m.move(0, 1); gridFocus = true }
            if let s = m.status { Text(s).font(.fo(.caption)).foregroundStyle(.secondary) }
            else if let s = m.savedAt { Text("Saved \(s, format: .dateTime.hour().minute())").font(.fo(.caption)).foregroundStyle(.secondary) }
        }
    }

    // MARK: grid
    func colAt(_ x: CGFloat) -> Int {
        var acc: CGFloat = 0
        for c in 0..<sheetCols { acc += m.colWidth(c); if x < acc { return c } }
        return sheetCols - 1
    }

    var grid: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(0..<sheetRows, id: \.self) { r in
                            HStack(spacing: 0) {
                                Text("\(r + 1)").font(.fo(.caption)).foregroundStyle(m.rect.r0 <= r && r <= m.rect.r1 ? Color.accentColor : .secondary)
                                    .frame(width: rowHeadW, height: cellH).background(Color(white: 0.95)).overlay(alignment: .bottom) { Divider() }.overlay(alignment: .trailing) { Divider() }
                                ForEach(0..<sheetCols, id: \.self) { c in cell(c, r).id(cellAddress(c, r)) }
                            }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sheetGrid")).onChanged { drag($0) }.onEnded { _ in dragMode = 0 })
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if lastX >= rowHeadW { m.startEdit() } })
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Color(white: 0.93).frame(width: rowHeadW, height: cellH).onTapGesture { m.selectAll(); gridFocus = true }
                            ForEach(0..<sheetCols, id: \.self) { c in
                                let inSel = m.rect.c0 <= c && c <= m.rect.c1
                                Text(colName(c)).font(.fo(.caption).weight(.semibold)).foregroundStyle(inSel ? Color.accentColor : .secondary)
                                    .frame(width: m.colWidth(c), height: cellH).background(inSel ? Color.accentColor.opacity(0.12) : Color(white: 0.93))
                                    .overlay(alignment: .trailing) {
                                        Rectangle().fill(Color.black.opacity(0.001)).frame(width: 9).contentShape(Rectangle())
                                            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                                            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                                                if resizeBase == nil { resizeBase = Double(m.colWidth(c)) }
                                                m.setColumnWidth(c, (resizeBase ?? 108) + Double(v.translation.width))
                                            }.onEnded { _ in resizeBase = nil })
                                    }
                                    .overlay(alignment: .trailing) { Divider() }
                                    .onTapGesture { m.selectCol(c); gridFocus = true }
                            }
                        }.overlay(alignment: .bottom) { Divider() }
                    }
                }
                .coordinateSpace(name: "sheetGrid")
            }
            .environment(\.colorScheme, .light)
            .background(.white).clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
            .focusable().focused($gridFocus).focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
            .onCopyCommand { [NSItemProvider(object: m.copy() as NSString)] }
            .onCutCommand { [NSItemProvider(object: m.cut() as NSString)] }
            .onPasteCommand(of: [.plainText]) { providers in
                providers.first?.loadObject(ofClass: NSString.self) { s, _ in if let s = s as? String { DispatchQueue.main.async { m.paste(s) } } }
            }
            .onChange(of: m.addr) { _, a in withAnimation(.none) { proxy.scrollTo(a) } }
        }
    }

    func drag(_ v: DragGesture.Value) {
        let loc = v.location
        lastX = v.startLocation.x
        let row = max(0, min(sheetRows - 1, Int((loc.y - cellH) / cellH)))
        let col = colAt(loc.x - rowHeadW)
        if dragMode == 0 {
            let startRow = max(0, min(sheetRows - 1, Int((v.startLocation.y - cellH) / cellH)))
            if v.startLocation.x < rowHeadW { dragMode = 2; m.selectRow(startRow); gridFocus = true; return }
            let startCol = colAt(v.startLocation.x - rowHeadW)
            if m.editing && startCol == m.curC && startRow == m.curR { return }          // clicking inside the cell being edited
            dragMode = 1; m.select(startCol, startRow, extend: NSEvent.modifierFlags.contains(.shift)); gridFocus = true
        }
        if dragMode == 1 { if !(m.editing) { m.select(col, row, extend: true) } }
        else if dragMode == 2 { m.anchorC = 0; m.curC = sheetCols - 1; m.curR = row }
    }

    @ViewBuilder func cell(_ c: Int, _ r: Int) -> some View {
        let a = cellAddress(c, r), st = m.style(a), d = m.display(a)
        let inSel = m.rect.contains(c, r), isCur = c == m.curC && r == m.curR
        let alignment: Alignment = st.align == "center" ? .center : st.align == "right" ? .trailing : st.align == "left" ? .leading : (d.number ? .trailing : .leading)
        ZStack {
            if isCur && m.editing {
                TextField("", text: $m.draft).textFieldStyle(.plain).focused($editFocus).padding(.horizontal, 6).docMentions($m.draft)
                    .onSubmit { m.commitEdit(); m.move(0, 1); gridFocus = true }
                    .onKeyPress(.escape) { m.cancelEdit(); gridFocus = true; return .handled }
                    .onKeyPress(.tab) { m.commitEdit(); m.move(1, 0); gridFocus = true; return .handled }
                    .onAppear { editFocus = true }
            } else {
                if DocLinks.hasRefs(d.text) { LinkedText(text: d.text).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                Text(d.text).font(.fo(size: 13, weight: st.b ? .bold : .regular)).italic(st.i)
                    .foregroundStyle(d.error ? Color.red : (st.color.isEmpty ? Color.black : Color(hex: st.color)))
                    .lineLimit(1).padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: alignment)
                }
            }
        }
        .frame(width: m.colWidth(c), height: cellH)
        .background(st.fill.isEmpty ? Color.white : Color(hex: st.fill))
        .overlay(inSel && !isCur ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(Rectangle().stroke(isCur ? Color.accentColor : Color(white: 0.9), lineWidth: isCur ? 2 : 0.5))
    }

    func handleKey(_ p: KeyPress) -> KeyPress.Result {
        if m.editing { return .ignored }
        let shift = p.modifiers.contains(.shift)
        if p.modifiers.contains(.command) {
            switch p.characters.lowercased() {
            case "b": m.toggleBold(); case "i": m.toggleItalic(); case "d": m.fillDown(); case "r": m.fillRight()
            case "a": m.selectAll(); case "f": findOpen = true
            default: return .ignored
            }
            return .handled
        }
        switch p.key {
        case .upArrow: m.move(0, -1, extend: shift)
        case .downArrow: m.move(0, 1, extend: shift)
        case .leftArrow: m.move(-1, 0, extend: shift)
        case .rightArrow: m.move(1, 0, extend: shift)
        case .tab: m.move(shift ? -1 : 1, 0)
        case .return: m.startEdit()
        case .delete, .deleteForward: m.clearSelection()
        case .escape: m.select(m.curC, m.curR)
        default:
            guard !p.modifiers.contains(.control), let ch = p.characters.first, ch.isLetter || ch.isNumber || "=+-.*/\"'(<>@#$%&_ ".contains(ch) else { return .ignored }
            m.startEdit(p.characters)
        }
        return .handled
    }

    // MARK: sheet tabs
    var sheetTabs: some View {
        GlassEffectContainer(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(m.sheets.enumerated()), id: \.offset) { i, s in
                        Text(s.name).font(.fo(.callout).weight(i == m.active ? .semibold : .regular)).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 6).contentShape(.capsule)
                            .onTapGesture(count: 2) { renameText = s.name; renaming = i }
                            .onTapGesture { m.commitEdit(); m.active = i; gridFocus = true }
                            .glassEffect(i == m.active ? .regular.tint(.green.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
                            .contextMenu {
                                Button("Rename…") { renameText = s.name; renaming = i }
                                Button("Duplicate") { m.duplicateSheet(i) }
                                Button("Delete", role: .destructive) { m.deleteSheet(i) }.disabled(m.sheets.count < 2)
                            }
                    }
                    Button { m.addSheet() } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).help("New sheet")
                }
            }
        }
    }

    // MARK: charts
    var chartsPanel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) { ForEach(m.sheet.charts) { spec in ChartCard(m: m, spec: spec) } }.padding(2)
        }.frame(height: 250)
    }
}

struct ChartCard: View {
    @ObservedObject var m: SheetModel
    let spec: ChartSpec

    func update(_ f: (inout ChartSpec) -> Void) { m.mutate { s in if let i = s.charts.firstIndex(where: { $0.id == spec.id }) { f(&s.charts[i]) } } }

    var body: some View {
        let data = m.chartData(spec)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Title", text: Binding(get: { spec.title }, set: { t in update { $0.title = t } })).textFieldStyle(.plain).font(.fo(.headline))
                Menu {
                    ForEach([("Column", "bar"), ("Line", "line"), ("Area", "area"), ("Pie", "pie")], id: \.1) { n, t in Button(n) { update { $0.type = t } } }
                } label: { Image(systemName: "chart.bar") }.menuStyle(.borderlessButton).fixedSize()
                Button { m.mutate { $0.charts.removeAll { $0.id == spec.id } } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            Text(spec.range).font(.fo(.caption)).foregroundStyle(.secondary)
            if data.series.isEmpty || data.cats.isEmpty { Text("Select cells with numbers and add a chart.").font(.fo(.caption)).foregroundStyle(.secondary); Spacer() }
            else {
                Chart {
                    if spec.type == "pie", let s = data.series.first {
                        ForEach(Array(zip(data.cats, s.vals).enumerated()), id: \.offset) { _, p in
                            SectorMark(angle: .value("Value", max(p.1, 0)), innerRadius: .ratio(0.45)).foregroundStyle(by: .value("Category", p.0))
                        }
                    } else {
                        ForEach(data.series, id: \.name) { s in
                            ForEach(Array(zip(data.cats, s.vals).enumerated()), id: \.offset) { _, p in
                                if spec.type == "line" { LineMark(x: .value("Category", p.0), y: .value(s.name, p.1)).foregroundStyle(by: .value("Series", s.name)); PointMark(x: .value("Category", p.0), y: .value(s.name, p.1)).foregroundStyle(by: .value("Series", s.name)) }
                                else if spec.type == "area" { AreaMark(x: .value("Category", p.0), y: .value(s.name, p.1)).foregroundStyle(by: .value("Series", s.name)).opacity(0.7) }
                                else { BarMark(x: .value("Category", p.0), y: .value(s.name, p.1)).foregroundStyle(by: .value("Series", s.name)).position(by: .value("Series", s.name)) }
                            }
                        }
                    }
                }
            }
        }
        .padding(12).frame(width: 380, height: 240).glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
