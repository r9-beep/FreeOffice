import SwiftUI
import AppKit
import Charts

private let filterOps: [(String, String)] = [("contains", "contains"), ("notContains", "doesn't contain"), ("is", "is"), ("isNot", "is not"), ("gt", "is greater than"), ("lt", "is less than"),
                                              ("gte", "is at least"), ("lte", "is at most"), ("empty", "is empty"), ("notEmpty", "is not empty")]
private let aggChoices: [(String, String)] = [("", "None"), ("count", "Count"), ("sum", "Sum"), ("avg", "Average"), ("min", "Minimum"), ("max", "Maximum")]
private let rowH: CGFloat = 34, headH: CGFloat = 36, numW: CGFloat = 54

private func defaultWidth(_ f: Field) -> CGFloat {
    if let w = f.width { return CGFloat(w) }
    switch f.type { case "checkbox": return 90; case "rating": return 120; case "date": return 140; case "number", "percent": return 110; case "currency": return 120; case "select": return 150; case "longtext": return 240; case "link": return 170; default: return 180 }
}
private func chip(_ text: String, _ hex: String) -> some View {
    Text(text).font(.fo(.caption).weight(.medium)).lineLimit(1).padding(.horizontal, 9).padding(.vertical, 3)
        .background(Color(hex: hex), in: .capsule).foregroundStyle(Color.black.opacity(0.85))
}

struct DataEditorView: View {
    @StateObject private var m: DataDocModel
    @State private var tab = "grid"
    @State private var filterOpen = false
    @State private var sortOpen = false
    @State private var fieldDraft: Field?
    @State private var isNewField = false
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var collapsed = Set<String>()
    @State private var resizeBase: Double?
    @State private var query = ""
    @State private var queryResult: SQLResult?
    @State private var queryError: String?
    @State private var saveQueryOpen = false
    @State private var queryName = ""
    @State private var igGroup: Int?
    @State private var igValue: Int?
    @State private var igAgg = "count"
    @State private var igType = "bar"
    @State private var deleteTable: Int?
    let docTab: Tab

    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? DataDocModel) ?? { let x = DataDocModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 8) {
                topBar.padding(.horizontal, 14).padding(.top, 10)
                if let s = m.status { Text(s).font(.fo(.caption)).foregroundStyle(.secondary) }
                content
            }
            .background { Backdrop().opacity(0.6) }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Database name", text: $m.doc.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
        }
        .onChange(of: m.doc.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled database" : t }
        .onChange(of: m.status) { _, s in if s != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { m.status = nil } } }
        .onChange(of: m.tableId) { _, _ in m.selected = []; collapsed = []; if ["grid", "board", "cards"].contains(tab) { tab = m.view.mode } }
        .onAppear { tab = m.view.mode; if query.isEmpty { query = "SELECT * FROM \"\(m.table.name)\" LIMIT 20" }; docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() } }
        .onDisappear { m.flush() }
        .sheet(item: $fieldDraft) { f in
            FieldEditor(m: m, field: f, isNew: isNewField) { saved in if isNewField { m.doc.tables[m.ti].fields.append(saved) } else { m.updateField(saved) }; fieldDraft = nil } onCancel: { fieldDraft = nil }
        }
        .sheet(isPresented: Binding(get: { m.recordId != nil }, set: { if !$0 { m.recordId = nil } })) { RecordEditor(m: m) }
        .alert("Rename table", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText); Button("Rename") { if let i = renaming { m.renameTable(i, renameText) }; renaming = nil }; Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Save query", isPresented: $saveQueryOpen) {
            TextField("Name", text: $queryName); Button("Save") { if !queryName.isEmpty { m.saveQuery(queryName, query) }; queryName = "" }; Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this table and all its rows?", isPresented: Binding(get: { deleteTable != nil }, set: { if !$0 { deleteTable = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let i = deleteTable { m.deleteTable(i) }; deleteTable = nil }
        }
    }

    // MARK: sidebar
    var sidebar: some View {
        List(selection: Binding(get: { m.tableId as Int? }, set: { if let v = $0 { m.tableId = v } })) {
            Section("Tables") {
                ForEach(m.doc.tables) { t in
                    Label { Text(t.name); Spacer(); Text("\(t.rows.count)").foregroundStyle(.secondary) } icon: { Image(systemName: "tablecells") }
                        .tag(t.id)
                        .contextMenu {
                            Button("Rename…") { renameText = t.name; renaming = t.id }
                            Button("Duplicate") { m.duplicateTable(t.id) }
                            Button("Delete table…", role: .destructive) { deleteTable = t.id }.disabled(m.doc.tables.count < 2)
                        }
                }
            }
            if !(m.doc.queries ?? []).isEmpty {
                Section("Saved queries") {
                    ForEach(m.doc.queries ?? []) { q in
                        Button { query = q.sql; tab = "query" } label: { Label(q.name, systemImage: "terminal") }.buttonStyle(.plain)
                            .contextMenu { Button("Delete", role: .destructive) { m.deleteQuery(q.id) } }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { m.addTable("Table \(m.doc.tables.count + 1)") } label: { Label("Add table", systemImage: "plus") }.buttonStyle(.glass).padding(10)
        }
        .scrollContentBackground(.hidden).frame(width: 220)
    }

    // MARK: top bar
    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
    }
    var topBar: some View {
        GlassEffectContainer(spacing: 8) {
            WrapLayout(spacing: 8) {
                group {
                    Picker("", selection: $tab) {
                        Label("Grid", systemImage: "tablecells").tag("grid"); Label("Board", systemImage: "rectangle.split.3x1").tag("board"); Label("Cards", systemImage: "square.grid.2x2").tag("cards")
                        Label("SQL", systemImage: "terminal").tag("query"); Label("Insights", systemImage: "chart.bar").tag("insights")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 400)
                    .onChange(of: tab) { _, t in if ["grid", "board", "cards"].contains(t) { m.setView { $0.mode = t } } }
                }
                if ["grid", "board", "cards"].contains(tab) {
                    group {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: Binding(get: { m.view.search }, set: { v in m.setView { $0.search = v } })).textFieldStyle(.plain).frame(width: 140)
                    }
                    group {
                        Button { filterOpen.toggle() } label: { Label(m.view.filters.isEmpty ? "Filter" : "Filter (\(m.view.filters.count))", systemImage: "line.3.horizontal.decrease") }
                            .popover(isPresented: $filterOpen) { filterPanel }
                        Button { sortOpen.toggle() } label: { Label(m.view.sorts.isEmpty ? "Sort" : "Sort (\(m.view.sorts.count))", systemImage: "arrow.up.arrow.down") }
                            .popover(isPresented: $sortOpen) { sortPanel }
                        Menu {
                            Button("No grouping") { m.setView { $0.groupBy = nil } }; Divider()
                            ForEach(m.table.fields.filter { $0.type != "longtext" }) { f in Button(f.name) { m.setView { $0.groupBy = f.id } } }
                        } label: { Label(m.field(m.view.groupBy).map { "Group: \($0.name)" } ?? "Group", systemImage: "rectangle.3.group") }.menuStyle(.borderlessButton).fixedSize()
                        Menu {
                            ForEach(m.table.fields) { f in Button { var g = f; g.hidden = !(f.hidden ?? false); m.updateField(g) } label: { Label(f.name, systemImage: (f.hidden ?? false) ? "eye.slash" : "eye") } }
                            Divider(); Button("New field…") { isNewField = true; fieldDraft = Field(id: m.nextId(m.table.fields.map(\.id)), name: "", type: "text") }
                        } label: { Label("Fields", systemImage: "list.bullet") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    group {
                        Button { m.recordId = m.addRow(); } label: { Label("Row", systemImage: "plus") }.help("Add a row and edit it")
                    }
                }
                group {
                    Menu {
                        Button("Import CSV…") { m.importCSV() }; Button("Import JSON…") { m.importJSON() }; Button("Import Excel…") { m.importXLSX() }
                        Divider(); Button("Export this table (CSV)…") { m.exportCSV() }; Button("Export everything (JSON)…") { m.exportJSON() }
                        Button("Export Excel (.xlsx)…") { m.exportXLSX() }; Button("Export SQL dump…") { m.exportSQLDump() }
                    } label: { Label("File", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: filter / sort panels
    var filterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter rows").font(.fo(.headline))
            ForEach(m.view.filters) { fl in
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { fl.field }, set: { v in update(fl) { $0.field = v } })) { ForEach(m.table.fields) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 120)
                    Picker("", selection: Binding(get: { fl.op }, set: { v in update(fl) { $0.op = v } })) { ForEach(filterOps, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 130)
                    if !["empty", "notEmpty"].contains(fl.op) { filterValue(fl) }
                    Button { m.setView { $0.filters.removeAll { $0.id == fl.id } } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            HStack {
                Button { if let f = m.table.fields.first { m.setView { $0.filters.append(Filter(id: (($0.filters.map(\.id).max() ?? 0) + 1), field: f.id, op: "contains", value: "")) } } } label: { Label("Add filter", systemImage: "plus") }.buttonStyle(.glass)
                if m.view.filters.count > 1 { Picker("", selection: Binding(get: { m.view.matchAll }, set: { v in m.setView { $0.matchAll = v } })) { Text("Match all").tag(true); Text("Match any").tag(false) }.pickerStyle(.segmented).frame(width: 170).labelsHidden() }
            }
        }.padding(16).frame(minWidth: 420)
    }
    @ViewBuilder func filterValue(_ fl: Filter) -> some View {
        if let f = m.field(fl.field), f.type == "select" {
            Picker("", selection: Binding(get: { fl.value }, set: { v in update(fl) { $0.value = v } })) { Text("—").tag(""); ForEach(f.options ?? [], id: \.name) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width: 130)
        } else if let f = m.field(fl.field), f.type == "checkbox" {
            Picker("", selection: Binding(get: { fl.value }, set: { v in update(fl) { $0.value = v } })) { Text("checked").tag("true"); Text("unchecked").tag("false") }.labelsHidden().frame(width: 130)
        } else { TextField("value", text: Binding(get: { fl.value }, set: { v in update(fl) { $0.value = v } })).textFieldStyle(.roundedBorder).frame(width: 130) }
    }
    func update(_ fl: Filter, _ f: (inout Filter) -> Void) { m.setView { v in if let i = v.filters.firstIndex(where: { $0.id == fl.id }) { f(&v.filters[i]) } } }
    var sortPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sort rows").font(.fo(.headline))
            ForEach(Array(m.view.sorts.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 6) {
                    Text(i == 0 ? "Sort by" : "then by").frame(width: 56, alignment: .leading)
                    Picker("", selection: Binding(get: { s.field }, set: { v in m.setView { $0.sorts[i].field = v } })) { ForEach(m.table.fields) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 140)
                    Picker("", selection: Binding(get: { s.asc }, set: { v in m.setView { $0.sorts[i].asc = v } })) { Text("A → Z").tag(true); Text("Z → A").tag(false) }.pickerStyle(.segmented).frame(width: 110).labelsHidden()
                    Button { m.setView { $0.sorts.remove(at: i) } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            Button { if let f = m.table.fields.first { m.setView { $0.sorts.append(SortKey(field: f.id, asc: true)) } } } label: { Label("Add sort", systemImage: "plus") }.buttonStyle(.glass)
        }.padding(16).frame(minWidth: 400)
    }

    // MARK: content switch
    @ViewBuilder var content: some View {
        switch tab {
        case "board": boardView
        case "cards": cardsView
        case "query": queryView
        case "insights": insightsView
        default: gridView
        }
    }

    // MARK: grid
    func width(_ f: Field) -> CGFloat { defaultWidth(f) }
    var gridView: some View {
        let groups = m.groups(), fields = m.shownFields, total = m.visibleRows().count
        return VStack(spacing: 6) {
            if !m.selected.isEmpty {
                HStack(spacing: 12) {
                    Text("\(m.selected.count) selected").fontWeight(.semibold)
                    Button("Duplicate") { m.duplicateRows(m.selected) }; Button("Delete", role: .destructive) { m.deleteRows(m.selected) }; Button("Clear") { m.selected = [] }
                }.buttonStyle(.glass).padding(.horizontal, 14).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders, .sectionFooters]) {
                    Section {
                        ForEach(groups, id: \.key) { g in
                            if m.view.groupBy != nil { groupHeader(g) }
                            if !collapsed.contains(g.key) { ForEach(g.rows) { r in rowView(r, fields) } }
                        }
                    } header: { headerRow(fields) } footer: { footerRow(fields, m.visibleRows()) }
                }
            }
            .background(.regularMaterial).clipShape(.rect(cornerRadius: 12)).padding(.horizontal, 14)
            Text("\(total) of \(m.table.rows.count) rows").font(.fo(.caption)).foregroundStyle(.secondary).padding(.bottom, 8)
        }
    }
    func headerRow(_ fields: [Field]) -> some View {
        HStack(spacing: 0) {
            Text("#").font(.fo(.caption)).foregroundStyle(.secondary).frame(width: numW, height: headH)
            ForEach(fields) { f in headerCell(f) }
            Button { isNewField = true; fieldDraft = Field(id: m.nextId(m.table.fields.map(\.id)), name: "", type: "text") } label: { Image(systemName: "plus").frame(width: 36, height: headH) }.buttonStyle(.plain).help("New field")
        }.background(.ultraThinMaterial).overlay(alignment: .bottom) { Divider() }
    }
    func headerCell(_ f: Field) -> some View {
        let sort = m.view.sorts.first { $0.field == f.id }
        return Button {
            m.setView { v in if let i = v.sorts.firstIndex(where: { $0.field == f.id }) { if v.sorts[i].asc { v.sorts[i].asc = false } else { v.sorts.remove(at: i) } } else { v.sorts = [SortKey(field: f.id, asc: true)] } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: fieldSymbol(f.type)).font(.caption2).foregroundStyle(.secondary)
                Text(f.name).fontWeight(.semibold).lineLimit(1)
                if let s = sort { Image(systemName: s.asc ? "chevron.up" : "chevron.down").font(.caption2) }
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(width: width(f), height: headH, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.black.opacity(0.001)).frame(width: 8).contentShape(Rectangle())
                .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in if resizeBase == nil { resizeBase = Double(width(f)) }; m.setWidth(f.id, (resizeBase ?? 150) + Double(v.translation.width)) }.onEnded { _ in resizeBase = nil })
        }
        .overlay(alignment: .trailing) { Divider() }
        .contextMenu {
            Button("Edit field…") { isNewField = false; fieldDraft = f }
            Button("Sort A → Z") { m.setView { $0.sorts = [SortKey(field: f.id, asc: true)] } }; Button("Sort Z → A") { m.setView { $0.sorts = [SortKey(field: f.id, asc: false)] } }
            Button("Group by this field") { m.setView { $0.groupBy = f.id } }
            Menu("Footer total") { ForEach(aggChoices, id: \.0) { c in Button(c.1) { var g = f; g.agg = c.0.isEmpty ? nil : c.0; m.updateField(g) } } }
            Divider(); Button("Hide field") { var g = f; g.hidden = true; m.updateField(g) }
            Button("Move left") { m.moveField(f.id, by: -1) }; Button("Move right") { m.moveField(f.id, by: 1) }
            Divider(); Button("Delete field", role: .destructive) { m.deleteField(f.id) }.disabled(m.table.fields.count < 2)
        }
    }
    func groupHeader(_ g: (key: String, rows: [Row])) -> some View {
        Button { if collapsed.contains(g.key) { collapsed.remove(g.key) } else { collapsed.insert(g.key) } } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed.contains(g.key) ? "chevron.right" : "chevron.down").font(.caption)
                if let f = m.field(m.view.groupBy), f.type == "select", g.key != "—" { chip(g.key, m.optionColor(f, g.key)) } else { Text(g.key).fontWeight(.semibold) }
                Text("\(g.rows.count)").foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).frame(height: 30).background(Color.primary.opacity(0.06)).contentShape(.rect)
        }.buttonStyle(.plain)
    }
    func rowView(_ r: Row, _ fields: [Field]) -> some View {
        let idx = (m.table.rows.firstIndex { $0.id == r.id } ?? 0) + 1, sel = m.selected.contains(r.id)
        return HStack(spacing: 0) {
            Button { if sel { m.selected.remove(r.id) } else { m.selected.insert(r.id) } } label: {
                Group { if sel { Image(systemName: "checkmark.square.fill").foregroundStyle(Color.accentColor) } else { Text("\(idx)").font(.fo(.caption)).foregroundStyle(.secondary) } }.frame(width: numW - 22, height: rowH)
            }.buttonStyle(.plain)
            Button { m.recordId = r.id } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.secondary).frame(width: 22, height: rowH) }.buttonStyle(.plain).help("Open record")
            ForEach(fields) { f in DataCell(m: m, rowId: r.id, field: f).frame(width: width(f), height: rowH, alignment: .leading).overlay(alignment: .trailing) { Divider() } }
        }
        .background(sel ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contextMenu {
            Button("Open record") { m.recordId = r.id }; Button("Duplicate") { m.duplicateRows([r.id]) }
            Button("Delete", role: .destructive) { m.deleteRows([r.id]) }
        }
    }
    func footerRow(_ fields: [Field], _ rows: [Row]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: numW, height: 28)
            ForEach(fields) { f in
                Menu {
                    ForEach(aggChoices, id: \.0) { c in Button(c.1) { var g = f; g.agg = c.0.isEmpty ? nil : c.0; m.updateField(g) } }
                } label: {
                    Text(m.aggregate(f, rows).isEmpty ? "" : "\(aggChoices.first { $0.0 == (f.agg ?? "") }?.1 ?? "") \(m.aggregate(f, rows))").font(.fo(.caption).weight(.medium)).lineLimit(1)
                        .frame(width: width(f), height: 28, alignment: .trailing).padding(.trailing, 8).contentShape(.rect)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: width(f))
            }
        }.background(.ultraThinMaterial).overlay(alignment: .top) { Divider() }
    }

    // MARK: board
    var boardView: some View {
        Group {
            if let bf = m.boardField {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(m.boardColumns(), id: \.name) { col in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { if col.name.hasPrefix("No ") { Text(col.name).font(.fo(.callout).weight(.semibold)).foregroundStyle(.secondary) } else { chip(col.name, m.optionColor(bf, col.name)) }; Text("\(col.rows.count)").foregroundStyle(.secondary); Spacer()
                                    Button { let id = m.addRow(col.name.hasPrefix("No ") ? [:] : [bf.id: .s(col.name)]); m.recordId = id } label: { Image(systemName: "plus") }.buttonStyle(.plain) }
                                ScrollView { LazyVStack(spacing: 8) { ForEach(col.rows) { r in card(r, compact: true).draggable(String(r.id)) } } }
                            }
                            .padding(10).frame(width: 270).frame(maxHeight: .infinity, alignment: .top).glassEffect(.regular, in: .rect(cornerRadius: 18))
                            .dropDestination(for: String.self) { items, _ in for s in items { if let id = Int(s) { m.moveRow(id, toColumn: col.name) } }; return true }
                        }
                    }.padding(14)
                }
                HStack { Text("Board grouped by").foregroundStyle(.secondary); Menu(bf.name) { ForEach(m.selectFields) { f in Button(f.name) { m.setView { $0.boardField = f.id } } } }.fixedSize() }.font(.fo(.caption)).padding(.bottom, 8)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("A board needs a Single choice field").font(.fo(.headline))
                    Text("It makes one column for each choice, like To do / Doing / Done.").foregroundStyle(.secondary)
                    Button { var f = Field(id: m.nextId(m.table.fields.map(\.id)), name: "Status", type: "select"); f.options = ["To do", "Doing", "Done"].enumerated().map { FieldOption(name: $1, color: optionColors[$0]) }; m.doc.tables[m.ti].fields.append(f) } label: { Label("Add a Status field", systemImage: "plus") }.buttonStyle(.glassProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    func card(_ r: Row, compact: Bool) -> some View {
        let fields = m.shownFields.filter { $0.id != m.primary?.id }
        return VStack(alignment: .leading, spacing: 6) {
            Text(m.primary.map { m.display(r, $0) } ?? "").font(.fo(.headline)).lineLimit(2)
            ForEach(Array(fields.prefix(compact ? 3 : 8))) { f in
                let t = m.display(r, f)
                if !t.isEmpty { HStack(alignment: .top, spacing: 6) { Text(f.name).font(.fo(.caption)).foregroundStyle(.secondary).frame(width: compact ? 70 : 90, alignment: .leading)
                    if f.type == "select" { chip(t, m.optionColor(f, t)) } else { Text(t).font(.fo(.caption)).lineLimit(2) } } }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: .rect(cornerRadius: 14)).contentShape(.rect)
        .onTapGesture { m.recordId = r.id }
        .contextMenu { Button("Open") { m.recordId = r.id }; Button("Duplicate") { m.duplicateRows([r.id]) }; Button("Delete", role: .destructive) { m.deleteRows([r.id]) } }
    }
    var cardsView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 12)], spacing: 12) { ForEach(m.visibleRows()) { r in card(r, compact: false) } }.padding(14)
        }
    }

    // MARK: SQL
    var queryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $query).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).frame(height: 130).padding(8).glassEffect(.regular, in: .rect(cornerRadius: 16)).docMentions($query)
                MentionStrip(text: query)
                HStack {
                    Button { runCurrent() } label: { Label("Run", systemImage: "play.fill") }.buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                    Button { saveQueryOpen = true } label: { Label("Save…", systemImage: "bookmark") }.buttonStyle(.glass)
                    Menu {
                        let t = m.table.name, f = m.table.fields.first?.name ?? "Name"
                        Button("Everything") { query = "SELECT * FROM \"\(t)\"" }
                        Button("Count rows") { query = "SELECT COUNT(*) AS rows FROM \"\(t)\"" }
                        Button("Group and count") { query = "SELECT \"\(f)\", COUNT(*) AS n FROM \"\(t)\" GROUP BY \"\(f)\" ORDER BY n DESC" }
                        Button("Search text") { query = "SELECT * FROM \"\(t)\" WHERE \"\(f)\" LIKE '%a%' ORDER BY \"\(f)\"" }
                        if m.doc.tables.count > 1 { let o = m.doc.tables.first { $0.id != m.table.id }!; Button("Join two tables") { query = "SELECT a.*, b.* FROM \"\(t)\" a JOIN \"\(o.name)\" b ON a.id = b.id" } }
                        Divider(); Button("Insert a row") { query = "INSERT INTO \"\(t)\" (\"\(f)\") VALUES ('New')" }; Button("Update rows") { query = "UPDATE \"\(t)\" SET \"\(f)\" = 'Changed' WHERE id = 1" }
                    } label: { Label("Examples", systemImage: "lightbulb") }.menuStyle(.borderlessButton).fixedSize()
                    if let r = queryResult, !r.cols.isEmpty { Button { m.exportResult(r) } label: { Label("Export result", systemImage: "square.and.arrow.up") }.buttonStyle(.glass) }
                }
                Text("SELECT with JOIN, WHERE, GROUP BY, HAVING, ORDER BY, LIMIT/OFFSET, DISTINCT, CASE, IN, BETWEEN, LIKE, IS NULL and functions — plus INSERT, UPDATE and DELETE (you'll be asked first). Tables: " + m.doc.tables.map { "\($0.name) (\($0.fields.map(\.name).joined(separator: ", ")))" }.joined(separator: " • "))
                    .font(.fo(.caption)).foregroundStyle(.secondary)
                if let e = queryError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.fo(.callout)) }
                if let r = queryResult {
                    if let msg = r.message { Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.fo(.callout)) }
                    if !r.cols.isEmpty { resultTable(r) }
                }
            }.padding(16)
        }
    }
    func resultTable(_ r: SQLResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) { ForEach(Array(r.cols.enumerated()), id: \.offset) { _, c in Text(c).fontWeight(.semibold).padding(8).frame(width: 160, alignment: .leading) } }.background(.ultraThinMaterial)
                    ForEach(Array(r.rows.prefix(500).enumerated()), id: \.offset) { i, row in
                        HStack(spacing: 0) { ForEach(Array(row.enumerated()), id: \.offset) { _, v in Text(v.text).lineLimit(1).padding(8).frame(width: 160, alignment: .leading) } }
                            .background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.04))
                    }
                }
            }.glassEffect(.regular, in: .rect(cornerRadius: 14))
            Text("\(r.rows.count) row\(r.rows.count == 1 ? "" : "s")\(r.rows.count > 500 ? " (showing the first 500)" : "")").font(.fo(.caption)).foregroundStyle(.secondary)
        }
    }
    func runCurrent() {
        queryError = nil; queryResult = nil
        let sql = DocLinks.sqlText(query)
        do {
            if m.isWrite(sql) {
                let dry = try SQLEngine(m.doc.tables).run(sql)
                let a = NSAlert(); a.messageText = "Run this change?"; a.informativeText = "\(dry.message ?? "") — this can be undone with Undo."
                a.addButton(withTitle: "Run"); a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                queryResult = try m.applyWrite(sql)
            } else { queryResult = try m.runQuery(sql) }
        } catch { queryError = error.localizedDescription }
    }

    // MARK: insights
    var insightsView: some View {
        let fields = m.table.fields
        let g = m.field(igGroup) ?? fields.first(where: { ["select", "text", "checkbox", "date"].contains($0.type) }) ?? fields.first
        let v = m.field(igValue)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Picker("Group by", selection: Binding(get: { g?.id ?? 0 }, set: { igGroup = $0 })) { ForEach(fields) { Text($0.name).tag($0.id) } }.frame(width: 220)
                    Picker("Measure", selection: $igAgg) { Text("Number of rows").tag("count"); Text("Sum").tag("sum"); Text("Average").tag("avg"); Text("Minimum").tag("min"); Text("Maximum").tag("max") }.frame(width: 220)
                    if igAgg != "count" { Picker("of", selection: Binding(get: { v?.id ?? fields.first(where: { ["number", "currency", "percent", "rating"].contains($0.type) })?.id ?? 0 }, set: { igValue = $0 })) { ForEach(fields.filter { ["number", "currency", "percent", "rating", "formula"].contains($0.type) }) { Text($0.name).tag($0.id) } }.frame(width: 200) }
                    Picker("", selection: $igType) { Text("Bars").tag("bar"); Text("Pie").tag("pie"); Text("Line").tag("line") }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
                }
                if let g = g {
                    let vf = igAgg == "count" ? nil : (v ?? fields.first(where: { ["number", "currency", "percent", "rating"].contains($0.type) }))
                    let data = m.insight(group: g, value: vf, agg: igAgg)
                    if data.isEmpty { Text("No rows to chart (check your filters).").foregroundStyle(.secondary) }
                    else {
                        Chart {
                            ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                                if igType == "pie" { SectorMark(angle: .value("Value", max(d.value, 0)), innerRadius: .ratio(0.5)).foregroundStyle(by: .value("Group", d.label)) }
                                else if igType == "line" { LineMark(x: .value("Group", d.label), y: .value("Value", d.value)); PointMark(x: .value("Group", d.label), y: .value("Value", d.value)) }
                                else { BarMark(x: .value("Group", d.label), y: .value("Value", d.value)).foregroundStyle(by: .value("Group", d.label)) }
                            }
                        }.frame(height: 320).padding(16).glassEffect(.regular, in: .rect(cornerRadius: 20))
                        VStack(spacing: 0) { ForEach(Array(data.enumerated()), id: \.offset) { i, d in
                            HStack { Text(d.label); Spacer(); Text(Val.n((d.value * 100).rounded() / 100).text).fontWeight(.medium) }.padding(.horizontal, 14).padding(.vertical, 6).background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.04))
                        } }.glassEffect(.regular, in: .rect(cornerRadius: 14)).frame(maxWidth: 520)
                    }
                }
                Text("Charts use the rows that match your current filters.").font(.fo(.caption)).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}

// MARK: - one editable cell

struct DataCell: View {
    @ObservedObject var m: DataDocModel
    let rowId: Int
    let field: Field
    @State private var datePopover = false
    @State private var newOption = ""
    @State private var newOptionOpen = false
    @State private var editText = false

    var row: Row? { m.table.rows.first { $0.id == rowId } }
    var value: Val { row.map { m.cellValue($0, field) } ?? .null }
    func set(_ v: Val) { m.setValue(rowId, field, v) }
    var textBinding: Binding<String> { Binding(get: { value.text }, set: { $0.isEmpty ? set(.null) : set(.s($0)) }) }
    var numBinding: Binding<Double?> { Binding(get: { value.num }, set: { set($0.map { .n($0) } ?? .null) }) }

    var body: some View {
        Group {
            switch field.type {
            case "checkbox": Toggle("", isOn: Binding(get: { value.truthy }, set: { set(.b($0)) })).labelsHidden().padding(.horizontal, 8)
            case "number": TextField("", value: numBinding, format: .number).textFieldStyle(.plain).padding(.horizontal, 8)
            case "currency": TextField("", value: numBinding, format: .currency(code: Locale.current.currency?.identifier ?? "GBP")).textFieldStyle(.plain).padding(.horizontal, 8)
            case "percent": TextField("", value: numBinding, format: .percent).textFieldStyle(.plain).padding(.horizontal, 8)
            case "rating":
                HStack(spacing: 2) { ForEach(1...5, id: \.self) { i in
                    Button { set(.n(Double(Int(value.num ?? 0) == i ? 0 : i))) } label: { Image(systemName: i <= Int(value.num ?? 0) ? "star.fill" : "star").font(.caption).foregroundStyle(i <= Int(value.num ?? 0) ? Color.orange : Color.secondary.opacity(0.6)) }.buttonStyle(.plain)
                } }.padding(.horizontal, 8)
            case "select": selectCell
            case "link": linkCell
            case "formula": Text(row.map { m.display($0, field) } ?? "").font(.fo(.body)).italic().foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 8)
            case "date":
                HStack(spacing: 2) {
                    TextField("yyyy-mm-dd", text: textBinding).textFieldStyle(.plain)
                    Button { datePopover = true } label: { Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary) }.buttonStyle(.plain)
                        .popover(isPresented: $datePopover) {
                            DatePicker("", selection: Binding(get: { dateValue }, set: { set(.s(isoString($0))) }), displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(10)
                        }
                }.padding(.horizontal, 8)
            case "url", "email":
                HStack(spacing: 2) {
                    TextField(field.type == "url" ? "https://" : "name@example.com", text: textBinding).textFieldStyle(.plain)
                    if !value.text.isEmpty { Button { if let u = URL(string: field.type == "email" ? "mailto:" + value.text : (value.text.contains("://") ? value.text : "https://" + value.text)) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(Color.accentColor) }.buttonStyle(.plain) }
                }.padding(.horizontal, 8)
            default:
                if DocLinks.hasRefs(value.text) && !editText {
                    LinkedText(text: value.text).padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        .contextMenu { Button("Edit text") { editText = true } }
                        .onTapGesture(count: 2) { editText = true }
                } else {
                    TextField("", text: textBinding, axis: field.type == "longtext" ? .vertical : .horizontal).lineLimit(1).textFieldStyle(.plain).padding(.horizontal, 8).docMentions(textBinding)
                        .onSubmit { editText = false }
                }
            }
        }
    }
    var dateValue: Date { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f.date(from: value.text) ?? Date() }
    func isoString(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d) }

    var selectCell: some View {
        Menu {
            ForEach(field.options ?? [], id: \.name) { o in Button { set(.s(o.name)) } label: { Label(o.name, systemImage: value.text == o.name ? "checkmark" : "circle.fill").foregroundStyle(Color(hex: o.color)) } }
            Divider(); Button("Clear") { set(.null) }
            Button("New option…") { newOptionOpen = true }
        } label: {
            HStack { if value.text.isEmpty { Text("").frame(maxWidth: .infinity) } else { chip(value.text, m.optionColor(field, value.text)); Spacer(minLength: 0) } }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }.buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden).padding(.horizontal, 6)
        .alert("New option", isPresented: $newOptionOpen) { TextField("Name", text: $newOption); Button("Add") { m.ensureOption(field, newOption); set(.s(newOption)); newOption = "" }; Button("Cancel", role: .cancel) {} }
    }
    var linkCell: some View {
        let target = m.doc.tables.first { $0.id == field.target }
        return Menu {
            if let t = target, let p = t.fields.first(where: { $0.type != "formula" }) {
                ForEach(t.rows.prefix(300)) { r in Button(m.display(r, p, in: t)) { set(.n(Double(r.id))) } }
            } else { Text("Choose a table in the field settings") }
            Divider(); Button("Clear") { set(.null) }
        } label: { Text(row.map { m.display($0, field) } ?? "").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).padding(.horizontal, 8)
    }
}

// MARK: - record editor (a form for one row)

struct RecordEditor: View {
    @ObservedObject var m: DataDocModel
    @Environment(\.dismiss) private var dismiss
    var row: Row? { m.table.rows.first { $0.id == m.recordId } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(row.flatMap { r in m.primary.map { m.display(r, $0) } }.flatMap { $0.isEmpty ? nil : $0 } ?? "Record").font(.fo(.title2)).lineLimit(1)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.up") }; Button { step(1) } label: { Image(systemName: "chevron.down") }
                Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(m.table.fields) { f in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(f.name, systemImage: fieldSymbol(f.type)).font(.fo(.caption)).foregroundStyle(.secondary)
                            if let r = row {
                                if f.type == "longtext" { LongText(m: m, rowId: r.id, field: f) }
                                else { DataCell(m: m, rowId: r.id, field: f).frame(minHeight: 34, alignment: .leading).padding(.horizontal, -4).background(.thinMaterial, in: .rect(cornerRadius: 10)) }
                            }
                        }
                    }
                }.padding(18)
            }
            Divider()
            HStack { Button("Duplicate") { if let id = m.recordId { m.duplicateRows([id]) } }.buttonStyle(.glass); Button("Delete record", role: .destructive) { if let id = m.recordId { m.deleteRows([id]); dismiss() } }.buttonStyle(.glass); Spacer() }.padding(14)
        }.frame(width: 520, height: 600)
    }
    func step(_ d: Int) {
        let ids = m.visibleRows().map(\.id); guard let cur = m.recordId, let i = ids.firstIndex(of: cur), ids.indices.contains(i + d) else { return }; m.recordId = ids[i + d]
    }
}
struct LongText: View {
    @ObservedObject var m: DataDocModel
    let rowId: Int, field: Field
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        TextEditor(text: Binding(get: { m.table.rows.first { $0.id == rowId }?.v[String(field.id)]?.text ?? "" }, set: { m.setValue(rowId, field, $0.isEmpty ? .null : .s($0)) }))
            .scrollContentBackground(.hidden).frame(height: 110).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 10))
            .docMentions(Binding(get: { m.table.rows.first { $0.id == rowId }?.v[String(field.id)]?.text ?? "" }, set: { m.setValue(rowId, field, $0.isEmpty ? .null : .s($0)) }))
        MentionStrip(text: m.table.rows.first { $0.id == rowId }?.v[String(field.id)]?.text ?? "")
        }
    }
}

// MARK: - field editor

struct FieldEditor: View {
    @ObservedObject var m: DataDocModel
    @State var field: Field
    let isNew: Bool
    var onSave: (Field) -> Void
    var onCancel: () -> Void
    @State private var newOption = ""

    var preview: String {
        guard field.type == "formula", let r = m.table.rows.first else { return "" }
        var t = m.table; if let i = t.fields.firstIndex(where: { $0.id == field.id }) { t.fields[i] = field } else { t.fields.append(field) }
        let e = SQLEngine(m.doc.tables.map { $0.id == t.id ? t : $0 }); return e.rowData(t, r)[field.name.lowercased()]?.text ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New field" : "Edit field").font(.fo(.title2))
            TextField("Field name", text: $field.name).textFieldStyle(.roundedBorder)
            Picker("Type", selection: $field.type) { ForEach(fieldTypes, id: \.id) { Label($0.label, systemImage: $0.symbol).tag($0.id) } }
            if field.type == "select" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choices").font(.fo(.caption)).foregroundStyle(.secondary)
                    ForEach(Array((field.options ?? []).enumerated()), id: \.offset) { i, o in
                        HStack {
                            Menu { ForEach(optionColors, id: \.self) { c in Button { field.options?[i].color = c } label: { Label(c, systemImage: "circle.fill").foregroundStyle(Color(hex: c)) } } } label: { Circle().fill(Color(hex: o.color)).frame(width: 18, height: 18).overlay(Circle().stroke(.black.opacity(0.2))) }.menuStyle(.borderlessButton).fixedSize()
                            TextField("", text: Binding(get: { o.name }, set: { field.options?[i].name = $0 })).textFieldStyle(.roundedBorder)
                            Button { field.options?.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    HStack { TextField("Add a choice", text: $newOption).textFieldStyle(.roundedBorder).onSubmit(addOption); Button("Add", action: addOption).buttonStyle(.glass) }
                }
            }
            if field.type == "link" {
                Picker("Links to", selection: Binding(get: { field.target ?? 0 }, set: { field.target = $0 })) { ForEach(m.doc.tables.filter { $0.id != m.table.id }) { Text($0.name).tag($0.id) } }
                Text("Each row picks one row from that table.").font(.fo(.caption)).foregroundStyle(.secondary)
            }
            if field.type == "formula" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Formula").font(.fo(.caption)).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { field.formula ?? "" }, set: { field.formula = $0 })).font(.system(.body, design: .monospaced)).frame(height: 80).scrollContentBackground(.hidden).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 10))
                    Text("Use other field names, e.g.  Price * Qty   or   IF(Age > 30, 'senior', 'junior')   or   UPPER(Name) || ' ' || City").font(.fo(.caption)).foregroundStyle(.secondary)
                    if !preview.isEmpty { Label("First row: \(preview)", systemImage: "eye").font(.fo(.callout)) }
                }
            }
            HStack {
                if !isNew { Button("Delete field", role: .destructive) { m.deleteField(field.id); onCancel() }.buttonStyle(.glass).disabled(m.table.fields.count < 2) }
                Spacer(); Button("Cancel", action: onCancel).buttonStyle(.glass)
                Button(isNew ? "Add field" : "Save") { onSave(field) }.buttonStyle(.glassProminent).disabled(field.name.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 440)
    }
    func addOption() {
        let n = newOption.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        var o = field.options ?? []; if !o.contains(where: { $0.name == n }) { o.append(FieldOption(name: n, color: optionColors[o.count % optionColors.count])) }; field.options = o; newOption = ""
    }
}
