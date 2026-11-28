// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

private let hourH: CGFloat = 52
private let gutterW: CGFloat = 52

private func chipColor(_ hex: String) -> Color { Color(hex: hex) }

struct PlannerEditorView: View {
    @StateObject private var m: PlannerModel
    @State private var quick = ""
    @State private var drag: (id: String, t: CGSize)?
    @State private var dayW: CGFloat = 30
    @State private var taskDrag: (id: Int, dx: CGFloat, edge: Bool)?
    let docTab: Tab

    init(id: String, dir: URL, tab: Tab) {
        let model = (tab.editorModel as? PlannerModel) ?? { let x = PlannerModel(id: id, dir: dir); tab.editorModel = x; return x }()
        _m = StateObject(wrappedValue: model); docTab = tab
    }

    var body: some View {
        VStack(spacing: 8) {
            topBar.padding(.horizontal, 14).padding(.top, 10)
            Group {
                switch m.view {
                case "week": weekView
                case "agenda": agendaView
                case "tasks": tasksView
                case "timeline": timelineView
                default: monthView
                }
            }
        }
        .background { Backdrop().opacity(0.6) }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { TextField("Untitled plan", text: $m.title).textFieldStyle(.plain).multilineTextAlignment(.center).font(.fo(.headline)).frame(minWidth: 110, idealWidth: 190, maxWidth: 260) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                Button { m.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
        }
        .onChange(of: m.title, initial: true) { _, t in docTab.title = t.isEmpty ? "Untitled plan" : t }
        .onChange(of: m.status) { _, s in if s != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { m.status = nil } } }
        .onAppear { docTab.onUndo = { m.undo() }; docTab.onRedo = { m.redo() } }
        .onDisappear { m.saver.flush() }
        .sheet(isPresented: Binding(get: { m.editEvent != nil }, set: { if !$0 { m.editEvent = nil } })) { if let id = m.editEvent, let e = m.event(id) { EventSheet(m: m, draft: e) } }
        .sheet(isPresented: Binding(get: { m.editTask != nil }, set: { if !$0 { m.editTask = nil } })) { if let id = m.editTask, let t = m.task(id) { TaskSheet(m: m, draft: t) } }
    }

    // MARK: top bar
    func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }.padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
    }
    var topBar: some View {
        GlassEffectContainer(spacing: 8) {
            WrapLayout(spacing: 8) {
                if ["month", "week", "agenda", "timeline"].contains(m.view) {
                    group {
                        Button { m.move(-1) } label: { Image(systemName: "chevron.left") }
                        Button("Today") { m.anchor = Date() }
                        Button { m.move(1) } label: { Image(systemName: "chevron.right") }
                    }
                }
                group { Text(m.rangeTitle).font(.fo(.headline)).frame(minWidth: 130) }
                group {
                    Picker("", selection: $m.view) {
                        Label("Month", systemImage: "calendar").tag("month"); Label("Week", systemImage: "calendar.day.timeline.left").tag("week"); Label("Agenda", systemImage: "list.bullet").tag("agenda")
                        Label("Tasks", systemImage: "checklist").tag("tasks"); Label("Timeline", systemImage: "chart.bar.xaxis").tag("timeline")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 430)
                }
                group { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search", text: $m.search).textFieldStyle(.plain).frame(width: 120) }
                group {
                    Menu {
                        Button("New event") { m.addEvent(on: m.anchor, hour: 9) }
                        Button("New all-day event") { m.addEvent(on: m.anchor) }
                        Button("New task") { m.editTask = m.addTask("New task", due: m.anchor) }
                    } label: { Label("New", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                    if m.view == "tasks" {
                        Toggle(isOn: $m.tasksAsBoard) { Label("Board", systemImage: "rectangle.split.3x1") }.toggleStyle(.button)
                        Toggle(isOn: $m.showDone) { Label("Done", systemImage: "checkmark.circle") }.toggleStyle(.button)
                    }
                    if m.view == "timeline" { Picker("", selection: $dayW) { Text("Days").tag(CGFloat(44)); Text("Weeks").tag(CGFloat(30)); Text("Months").tag(CGFloat(14)) }.pickerStyle(.segmented).frame(width: 170).labelsHidden() }
                    Menu { Button("Import calendar (.ics)…") { m.importICSFile() }; Button("Export calendar (.ics)…") { m.exportICS() } } label: { Label("File", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                }
                if let s = m.status { group { Text(s).font(.fo(.caption)) } }
            }.buttonStyle(.plain)
        }
    }

    // MARK: month
    func weekdayHeader(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            ForEach(days.prefix(7), id: \.self) { d in
                Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.fo(.caption).weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
        }
    }
    var monthView: some View {
        let days = m.monthGrid(m.anchor), occs = m.occurrences(from: days[0], to: m.add(1, .day, to: days[41]))
        let month = m.cal.component(.month, from: m.anchor)
        return VStack(spacing: 0) {
            weekdayHeader(days)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<6, id: \.self) { r in
                    GridRow { ForEach(0..<7, id: \.self) { c in dayCell(days[r * 7 + c], occs, month: month) } }
                }
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 14)).clipShape(.rect(cornerRadius: 14)).padding(.horizontal, 14).padding(.bottom, 12)
    }
    func dayCell(_ d: Date, _ occs: [POcc], month: Int) -> some View {
        let todays = occs.filter { $0.start < m.add(1, .day, to: d) && $0.end > d }
        let due = m.tasks.filter { t in t.dueDate.map { m.day($0) == d } ?? false && (m.showDone || !t.done) }
        let isToday = d == m.today, inMonth = m.cal.component(.month, from: d) == month
        var items: [AnyView] = []
        for o in todays { items.append(AnyView(eventChip(o))) }
        for t in due { items.append(AnyView(taskChip(t))) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(m.cal.component(.day, from: d))").font(.fo(.caption).weight(isToday ? .bold : .regular)).foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(width: 22, height: 22).background(isToday ? Color.accentColor : .clear, in: .circle)
                Spacer()
            }
            ForEach(0..<min(items.count, 3), id: \.self) { items[$0] }
            if items.count > 3 { Text("+\(items.count - 3) more").font(.fo(.caption2)).foregroundStyle(.secondary).padding(.leading, 4) }
            Spacer(minLength: 0)
        }
        .padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(m.cal.isDate(d, inSameDayAs: m.anchor) ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(alignment: .topLeading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5) }
        .contentShape(.rect)
        .onTapGesture(count: 2) { m.anchor = d; m.addEvent(on: d) }
        .onTapGesture { m.anchor = d }
        .dropDestination(for: String.self) { items, _ in drop(items, on: d) }
    }
    func eventChip(_ o: POcc) -> some View {
        Button { m.editEvent = o.event.id } label: {
            HStack(spacing: 3) {
                if !o.event.allDay { Text(o.start.formatted(.dateTime.hour().minute())).font(.fo(.caption2)).foregroundStyle(.black.opacity(0.6)) }
                Text(o.event.title).font(.fo(.caption).weight(.medium)).lineLimit(1)
                if o.event.repeatRule != "none" { Image(systemName: "repeat").font(.system(size: 8)) }
            }
            .padding(.horizontal, 5).padding(.vertical, 1).frame(maxWidth: .infinity, alignment: .leading).background(chipColor(o.event.color), in: .rect(cornerRadius: 5)).foregroundStyle(.black.opacity(0.85))
        }.buttonStyle(.plain).draggable("e:\(o.event.id):\(Int(o.start.timeIntervalSince1970))")
    }
    func taskChip(_ t: PTask) -> some View {
        HStack(spacing: 3) {
            Button { m.toggle(t.id) } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").font(.caption2) }.buttonStyle(.plain)
            Button { m.editTask = t.id } label: { Text(t.title).font(.fo(.caption)).lineLimit(1).strikethrough(t.done) }.buttonStyle(.plain)
            Spacer(minLength: 0)
        }.padding(.horizontal, 4).foregroundStyle(t.done ? .secondary : .primary).draggable("t:\(t.id)")
    }
    func drop(_ items: [String], on d: Date) -> Bool {
        guard let s = items.first else { return false }
        let p = s.split(separator: ":").map(String.init)
        if p.count == 3, p[0] == "e", let id = Int(p[1]), let secs = Double(p[2]), let e = m.event(id) {
            let from = Date(timeIntervalSince1970: secs), tod = from.timeIntervalSince(m.day(from)), delta = m.day(d).timeIntervalSince(m.day(from)); _ = tod
            var n = e; n.start += delta; n.end += delta; m.updateEvent(n); return true
        }
        if p.count == 2, p[0] == "t", let id = Int(p[1]), var t = m.task(id) { t.due = m.day(d).timeIntervalSince1970; m.updateTask(t); return true }
        return false
    }

    // MARK: week
    var weekView: some View {
        let start = m.weekStart(m.anchor), days = (0..<7).map { m.add($0, .day, to: start) }
        let occs = m.occurrences(from: start, to: m.add(7, .day, to: start))
        return GeometryReader { geo in
            let colW = (geo.size.width - gutterW - 28) / 7
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterW, height: 1)
                    ForEach(days, id: \.self) { d in
                        VStack(spacing: 2) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.fo(.caption)).foregroundStyle(.secondary)
                            Text("\(m.cal.component(.day, from: d))").font(.fo(.title3).weight(.semibold)).foregroundStyle(d == m.today ? .white : .primary).frame(width: 30, height: 30).background(d == m.today ? Color.accentColor : .clear, in: .circle)
                        }.frame(width: colW)
                    }
                }.padding(.vertical, 6)
                allDayRow(days, occs, colW)
                Divider()
                ScrollViewReader { sp in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) { ForEach(0..<24, id: \.self) { h in
                                HStack(spacing: 0) { Text(h == 0 ? "" : String(format: "%02d:00", h)).font(.fo(.caption2)).foregroundStyle(.secondary).frame(width: gutterW, alignment: .trailing).padding(.trailing, 6).offset(y: -7)
                                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }.frame(height: hourH, alignment: .top).id(h)
                            } }
                            HStack(spacing: 0) {
                                Color.clear.frame(width: gutterW, height: 1)
                                ForEach(days, id: \.self) { d in dayColumn(d, occs, colW) }
                            }
                        }
                    }.onAppear { sp.scrollTo(7, anchor: .top) }
                }
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 14)).clipShape(.rect(cornerRadius: 14)).padding(.horizontal, 14).padding(.bottom, 12)
        }
    }
    func allDayRow(_ days: [Date], _ occs: [POcc], _ colW: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(.fo(.caption2)).foregroundStyle(.secondary).frame(width: gutterW, alignment: .trailing).padding(.trailing, 6)
            ForEach(days, id: \.self) { d in
                VStack(spacing: 2) {
                    ForEach(occs.filter { $0.event.allDay && $0.start < m.add(1, .day, to: d) && $0.end > d }) { eventChip($0) }
                    ForEach(m.tasks.filter { t in t.dueDate.map { m.day($0) == d } ?? false && (m.showDone || !t.done) }) { taskChip($0) }
                }.frame(width: colW, alignment: .top)
                    .dropDestination(for: String.self) { items, _ in drop(items, on: d) }
            }
        }.padding(.bottom, 4).frame(minHeight: 28)
    }
    func lanes(_ list: [POcc]) -> [(POcc, Int, Int)] {
        var out: [(POcc, Int, Int)] = [], cluster: [POcc] = [], clusterEnd = Date.distantPast
        func flush() {
            var ends: [Date] = [], placed: [(POcc, Int)] = []
            for o in cluster { if let i = ends.firstIndex(where: { $0 <= o.start }) { ends[i] = o.end; placed.append((o, i)) } else { ends.append(o.end); placed.append((o, ends.count - 1)) } }
            for (o, l) in placed { out.append((o, l, max(ends.count, 1))) }; cluster = []
        }
        for o in list { if o.start >= clusterEnd { flush() }; cluster.append(o); clusterEnd = max(clusterEnd, o.end) }
        flush(); return out
    }
    func dayColumn(_ d: Date, _ occs: [POcc], _ colW: CGFloat) -> some View {
        let next = m.add(1, .day, to: d)
        let timed = occs.filter { !$0.event.allDay && $0.start < next && $0.end > d }.map { o -> POcc in POcc(event: o.event, start: max(o.start, d), end: min(o.end, next)) }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(d == m.today ? Color.accentColor.opacity(0.05) : Color.clear).frame(width: colW, height: hourH * 24)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5) }
                .contentShape(.rect)
                .gesture(SpatialTapGesture(count: 2).onEnded { v in m.addEvent(on: d, hour: max(0, min(23, Int(v.location.y / hourH)))) })
                .dropDestination(for: String.self) { items, loc in dropTimed(items, d, loc.y) }
            ForEach(lanes(timed), id: \.0.id) { o, lane, n in timedBlock(o, d, lane, n, colW) }
            if d == m.today { let y = CGFloat(Date().timeIntervalSince(d) / 3600) * hourH; Rectangle().fill(.red).frame(width: colW, height: 1.5).offset(y: y).allowsHitTesting(false) }
        }.frame(width: colW, height: hourH * 24)
    }
    func dropTimed(_ items: [String], _ d: Date, _ y: CGFloat) -> Bool {
        guard let s = items.first else { return false }
        let p = s.split(separator: ":").map(String.init)
        if p.count == 3, p[0] == "e", let id = Int(p[1]), let e = m.event(id), !e.allDay {
            let mins = (Double(y / hourH) * 60 / 15).rounded() * 15
            let target = d.addingTimeInterval(mins * 60), from = Date(timeIntervalSince1970: Double(p[2])!)
            var n = e; let delta = target.timeIntervalSince(from); n.start += delta; n.end += delta; m.updateEvent(n); return true
        }
        return drop(items, on: d)
    }
    func timedBlock(_ o: POcc, _ d: Date, _ lane: Int, _ n: Int, _ colW: CGFloat) -> some View {
        let y = CGFloat(o.start.timeIntervalSince(d) / 3600) * hourH, h = max(CGFloat(o.end.timeIntervalSince(o.start) / 3600) * hourH, 22)
        let w = (colW - 4) / CGFloat(n), live = drag?.id == o.id ? drag!.t : .zero
        return VStack(alignment: .leading, spacing: 1) {
            Text(o.event.title).font(.fo(.caption).weight(.semibold)).lineLimit(2)
            if h > 34 { Text(o.start.formatted(.dateTime.hour().minute())).font(.fo(.caption2)).opacity(0.7) }
        }
        .padding(4).frame(width: w - 2, height: h - 1, alignment: .topLeading).background(chipColor(o.event.color), in: .rect(cornerRadius: 6)).foregroundStyle(.black.opacity(0.85))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.12)))
        .offset(x: CGFloat(lane) * w + 2 + live.width, y: y + live.height)
        .zIndex(drag?.id == o.id ? 10 : 1)
        .onTapGesture { m.editEvent = o.event.id }
        .gesture(DragGesture(minimumDistance: 6).onChanged { drag = (o.id, $0.translation) }.onEnded { v in
            let dd = Int((v.translation.width / colW).rounded()), mins = (Double(v.translation.height / hourH) * 60 / 15).rounded() * 15
            if var e = m.event(o.event.id) { let delta = Double(dd) * 86400 + mins * 60; e.start += delta; e.end += delta; m.updateEvent(e) }
            drag = nil
        })
    }

    // MARK: agenda
    var agendaView: some View {
        let start = m.day(m.anchor), end = m.add(60, .day, to: start), occs = m.occurrences(from: start, to: end)
        let days = (0..<60).map { m.add($0, .day, to: start) }.filter { d in occs.contains { $0.start < m.add(1, .day, to: d) && $0.end > d } || m.tasks.contains { t in t.dueDate.map { m.day($0) == d } ?? false && !t.done } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if days.isEmpty { Text("Nothing planned in the next 60 days.").foregroundStyle(.secondary).padding(30) }
                ForEach(days, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d == m.today ? "Today" : d.formatted(.dateTime.weekday(.wide).day().month())).font(.fo(.headline))
                        VStack(spacing: 0) {
                            ForEach(occs.filter { $0.start < m.add(1, .day, to: d) && $0.end > d }) { o in
                                Button { m.editEvent = o.event.id } label: {
                                    HStack(spacing: 10) {
                                        Rectangle().fill(chipColor(o.event.color)).frame(width: 4).clipShape(.capsule)
                                        Text(o.event.allDay ? "all-day" : o.start.formatted(.dateTime.hour().minute())).font(.fo(.callout)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 1) { Text(o.event.title).font(.fo(.body).weight(.medium)); if !o.event.location.isEmpty { Text(o.event.location).font(.fo(.caption)).foregroundStyle(.secondary) } }
                                        Spacer()
                                    }.padding(10).contentShape(.rect)
                                }.buttonStyle(.plain)
                            }
                            ForEach(m.tasks.filter { t in t.dueDate.map { m.day($0) == d } ?? false && !t.done }) { t in taskRow(t).padding(.horizontal, 10) }
                        }.background(.regularMaterial, in: .rect(cornerRadius: 12))
                    }
                }
            }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }

    // MARK: tasks
    func taskRow(_ t: PTask) -> some View {
        let overdue = !t.done && (t.dueDate ?? .distantFuture) < m.today
        return HStack(spacing: 10) {
            Button { m.toggle(t.id) } label: { Image(systemName: t.done ? "checkmark.circle.fill" : (t.status == "doing" ? "circle.lefthalf.filled" : "circle")).font(.title3).foregroundStyle(t.done ? Color.green : Color.secondary) }.buttonStyle(.plain)
            Button { m.editTask = t.id } label: {
                HStack(spacing: 8) {
                    Text(DocLinks.plain(t.title)).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary).lineLimit(1)
                    if m.blocked(t) { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).help("Waiting on another task") }
                    if t.priority > 0 { Image(systemName: "flag.fill").font(.caption).foregroundStyle([Color.gray, .blue, .orange, .red][t.priority]) }
                    if !t.tag.isEmpty { Text("#" + t.tag).font(.fo(.caption)).padding(.horizontal, 6).padding(.vertical, 1).background(.thinMaterial, in: .capsule) }
                    Spacer(minLength: 0)
                    if let d = t.dueDate { Text(d.formatted(.dateTime.day().month(.abbreviated))).font(.fo(.caption)).foregroundStyle(overdue ? .red : .secondary) }
                }.contentShape(.rect)
            }.buttonStyle(.plain)
        }.padding(.vertical, 7)
        .contextMenu { Button("Edit") { m.editTask = t.id }; Menu("Status") { Button("To do") { m.setStatus(t.id, "todo") }; Button("Doing") { m.setStatus(t.id, "doing") }; Button("Done") { m.setStatus(t.id, "done") } }
            Divider(); Button("Delete", role: .destructive) { m.deleteTask(t.id) } }
    }
    var tasksView: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("Add a task — try “Call Sam tomorrow !high #work”", text: $quick).textFieldStyle(.plain).onSubmit { m.quickAdd(quick); quick = "" }
            }.padding(12).glassEffect(.regular, in: .capsule).padding(.horizontal, 14)
            if m.tasksAsBoard { board } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let g = m.groups()
                        if g.isEmpty { Text("No tasks yet. Type one above and press Return.").foregroundStyle(.secondary).padding(30) }
                        ForEach(g, id: \.title) { grp in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(grp.title) · \(grp.tasks.count)").font(.fo(.caption).weight(.semibold)).foregroundStyle(grp.title == "Overdue" ? .red : .secondary)
                                VStack(spacing: 0) { ForEach(grp.tasks) { t in taskRow(t).padding(.horizontal, 12); if t.id != grp.tasks.last?.id { Divider().padding(.leading, 12) } } }
                                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            }
                        }
                    }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
        }
    }
    var board: some View {
        let q = m.search.lowercased()
        return HStack(alignment: .top, spacing: 12) {
            ForEach([("todo", "To do"), ("doing", "Doing"), ("done", "Done")], id: \.0) { key, name in
                let col = m.tasks.filter { $0.status == key && (q.isEmpty || $0.title.lowercased().contains(q)) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(name) · \(col.count)").font(.fo(.callout).weight(.semibold))
                    ScrollView { LazyVStack(spacing: 8) { ForEach(col) { t in
                        VStack(alignment: .leading, spacing: 4) { taskRow(t) }.padding(.horizontal, 10).background(.thinMaterial, in: .rect(cornerRadius: 12)).draggable("s:\(t.id)")
                    } } }
                }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).glassEffect(.regular, in: .rect(cornerRadius: 18))
                .dropDestination(for: String.self) { items, _ in
                    for s in items { let p = s.split(separator: ":"); if p.count == 2, p[0] == "s", let id = Int(p[1]) { m.setStatus(id, key) } }; return true
                }
            }
        }.padding(.horizontal, 14).padding(.bottom, 12)
    }

    // MARK: timeline (Gantt)
    var timelineView: some View {
        let dated = m.tasks.filter { ($0.start != nil || $0.due != nil) && (m.search.isEmpty || $0.title.lowercased().contains(m.search.lowercased())) && (m.showDone || !$0.done) }
            .sorted { ($0.start ?? $0.due ?? 0) < ($1.start ?? $1.due ?? 0) }
        let lo = m.add(-14, .day, to: min(m.day(m.anchor), dated.compactMap { $0.startDate ?? $0.dueDate }.min() ?? m.day(m.anchor)))
        let hi = m.add(28, .day, to: max(m.add(42, .day, to: m.day(m.anchor)), dated.compactMap { $0.dueDate ?? $0.startDate }.max() ?? m.day(m.anchor)))
        let nDays = max(Int(hi.timeIntervalSince(lo) / 86400), 30), rowH: CGFloat = 34, labelW: CGFloat = 210
        func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(lo) / 86400) * dayW }
        func barRange(_ t: PTask) -> (Date, Date) { let s = t.startDate ?? t.dueDate ?? lo, e = t.dueDate ?? s; return (min(s, e), max(s, e)) }
        return VStack(spacing: 0) {
            if dated.isEmpty { Text("Give tasks a start or due date and they appear here as bars.").foregroundStyle(.secondary).padding(40) }
            else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        // day header + grid
                        Canvas { ctx, size in
                            for i in 0..<nDays {
                                let d = m.add(i, .day, to: lo), xx = CGFloat(i) * dayW + labelW
                                if m.cal.isDateInWeekend(d) { ctx.fill(Path(CGRect(x: xx, y: 40, width: dayW, height: size.height)), with: .color(.primary.opacity(0.04))) }
                                if m.cal.component(.day, from: d) == 1 || (i == 0) { ctx.draw(Text(d.formatted(.dateTime.month(.abbreviated).year(.twoDigits))).font(.caption.weight(.semibold)), at: CGPoint(x: xx + 4, y: 11), anchor: .leading); var p = Path(); p.move(to: CGPoint(x: xx, y: 0)); p.addLine(to: CGPoint(x: xx, y: size.height)); ctx.stroke(p, with: .color(.primary.opacity(0.15)), lineWidth: 0.5) }
                                if dayW >= 28 || m.cal.component(.weekday, from: d) == m.cal.firstWeekday { ctx.draw(Text("\(m.cal.component(.day, from: d))").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: xx + dayW / 2, y: 30)) }
                            }
                            let tx = x(m.today) + labelW + dayW / 2; var tp = Path(); tp.move(to: CGPoint(x: tx, y: 36)); tp.addLine(to: CGPoint(x: tx, y: size.height)); ctx.stroke(tp, with: .color(.red.opacity(0.7)), lineWidth: 1.5)
                            // dependency elbows
                            for (ri, t) in dated.enumerated() { for dep in t.deps { if let di = dated.firstIndex(where: { $0.id == dep }) {
                                let (_, de) = barRange(dated[di]), (ts, _) = barRange(t)
                                let a = CGPoint(x: x(de) + dayW + labelW, y: 40 + CGFloat(di) * rowH + rowH / 2), b = CGPoint(x: x(ts) + labelW, y: 40 + CGFloat(ri) * rowH + rowH / 2)
                                var p = Path(); p.move(to: a); p.addLine(to: CGPoint(x: a.x + 8, y: a.y)); p.addLine(to: CGPoint(x: a.x + 8, y: b.y)); p.addLine(to: b)
                                ctx.stroke(p, with: .color(.orange.opacity(0.8)), lineWidth: 1.2)
                            } } }
                        }.frame(width: labelW + CGFloat(nDays) * dayW, height: 40 + CGFloat(dated.count) * rowH + 20)
                        ForEach(Array(dated.enumerated()), id: \.element.id) { i, t in
                            let (s, e) = barRange(t), live = taskDrag?.id == t.id ? taskDrag! : nil
                            Group {
                                HStack(spacing: 6) {
                                    Button { m.toggle(t.id) } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? Color.green : Color.secondary) }.buttonStyle(.plain)
                                    Text(DocLinks.plain(t.title)).font(.fo(.callout)).lineLimit(1).strikethrough(t.done)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 10).frame(width: labelW, height: rowH, alignment: .leading).background(.ultraThinMaterial).onTapGesture { m.editTask = t.id }
                                    .offset(x: 0, y: 40 + CGFloat(i) * rowH)
                                let bx = x(s) + labelW + (live.map { $0.edge ? 0 : $0.dx } ?? 0), bw = max(x(e) - x(s) + dayW, dayW) + (live.map { $0.edge ? $0.dx : 0 } ?? 0)
                                RoundedRectangle(cornerRadius: 7).fill(t.done ? Color.green.opacity(0.5) : chipColor(t.color)).overlay(alignment: .leading) { Text(DocLinks.plain(t.title)).font(.fo(.caption).weight(.medium)).foregroundStyle(.black.opacity(0.8)).padding(.leading, 6).lineLimit(1) }
                                    .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.001)).frame(width: 8).onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                                        .gesture(DragGesture(minimumDistance: 1).onChanged { taskDrag = (t.id, $0.translation.width, true) }.onEnded { v in
                                            if var n = m.task(t.id) { let days = Int((v.translation.width / dayW).rounded()); n.due = max(m.add(days, .day, to: m.dueOrStart(n)), n.startDate ?? m.dueOrStart(n)).timeIntervalSince1970; m.updateTask(n) }; taskDrag = nil }) }
                                    .frame(width: max(bw, 14), height: rowH - 12).offset(x: bx, y: 40 + CGFloat(i) * rowH + 6)
                                    .onTapGesture { m.editTask = t.id }
                                    .gesture(DragGesture(minimumDistance: 4).onChanged { taskDrag = (t.id, $0.translation.width, false) }.onEnded { v in
                                        if var n = m.task(t.id) { let days = Int((v.translation.width / dayW).rounded()); n.start = n.start.map { m.add(days, .day, to: Date(timeIntervalSince1970: $0)).timeIntervalSince1970 }; n.due = n.due.map { m.add(days, .day, to: Date(timeIntervalSince1970: $0)).timeIntervalSince1970 }; m.updateTask(n) }; taskDrag = nil })
                            }
                        }
                    }
                }
                .background(.regularMaterial, in: .rect(cornerRadius: 14)).clipShape(.rect(cornerRadius: 14)).padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }
}

extension PlannerModel { func dueOrStart(_ t: PTask) -> Date { t.dueDate ?? t.startDate ?? today } }

// MARK: - Editors

struct EventSheet: View {
    @ObservedObject var m: PlannerModel
    @State var draft: PEvent
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Event").font(.fo(.title2))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder).docMentions($draft.title)
            Toggle("All-day", isOn: $draft.allDay.animation())
            if draft.allDay {
                DatePicker("From", selection: Binding(get: { draft.startDate }, set: { draft.start = $0.timeIntervalSince1970; if draft.end < draft.start { draft.end = draft.start } }), displayedComponents: .date)
                DatePicker("To", selection: Binding(get: { draft.endDate }, set: { draft.end = max($0.timeIntervalSince1970, draft.start) }), displayedComponents: .date)
            } else {
                DatePicker("Starts", selection: Binding(get: { draft.startDate }, set: { let len = draft.end - draft.start; draft.start = $0.timeIntervalSince1970; draft.end = draft.start + max(len, 900) }))
                DatePicker("Ends", selection: Binding(get: { draft.endDate }, set: { draft.end = max($0.timeIntervalSince1970, draft.start + 900) }))
            }
            Picker("Repeats", selection: $draft.repeatRule) { Text("Never").tag("none"); Text("Every day").tag("daily"); Text("Every week").tag("weekly"); Text("Every month").tag("monthly"); Text("Every year").tag("yearly") }
            if draft.repeatRule != "none" {
                Toggle("Stop repeating on a date", isOn: Binding(get: { draft.until != nil }, set: { draft.until = $0 ? draft.start + 86400 * 90 : nil }))
                if let u = draft.until { DatePicker("Until", selection: Binding(get: { Date(timeIntervalSince1970: u) }, set: { draft.until = $0.timeIntervalSince1970 }), displayedComponents: .date) }
            }
            TextField("Location", text: $draft.location).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) { Text("Colour"); ForEach(plannerColors, id: \.self) { c in Button { draft.color = c } label: { Circle().fill(Color(hex: c)).frame(width: 20, height: 20).overlay(Circle().stroke(Color.primary.opacity(draft.color == c ? 0.9 : 0.25), lineWidth: draft.color == c ? 2 : 1)) }.buttonStyle(.plain) } }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.fo(.caption)).foregroundStyle(.secondary)
                TextEditor(text: $draft.notes).frame(height: 80).scrollContentBackground(.hidden).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 10)).docMentions($draft.notes)
                MentionStrip(text: draft.notes)
                Text("Type @ to link a document — it previews on hover.").font(.fo(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Delete", role: .destructive) { m.deleteEvent(draft.id); dismiss() }.buttonStyle(.glass)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass)
                Button("Save") { m.updateEvent(draft); dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 460)
    }
}

struct TaskSheet: View {
    @ObservedObject var m: PlannerModel
    @State var draft: PTask
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task").font(.fo(.title2))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder).docMentions($draft.title)
            HStack {
                Picker("Status", selection: $draft.status) { Text("To do").tag("todo"); Text("Doing").tag("doing"); Text("Done").tag("done") }
                Picker("Priority", selection: $draft.priority) { Text("None").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3) }
            }
            Toggle("Start date", isOn: Binding(get: { draft.start != nil }, set: { draft.start = $0 ? (draft.due ?? m.today.timeIntervalSince1970) : nil }))
            if let s = draft.start { DatePicker("Starts", selection: Binding(get: { Date(timeIntervalSince1970: s) }, set: { draft.start = m.day($0).timeIntervalSince1970 }), displayedComponents: .date) }
            Toggle("Due date", isOn: Binding(get: { draft.due != nil }, set: { draft.due = $0 ? (draft.start ?? m.today.timeIntervalSince1970) : nil }))
            if let d = draft.due { DatePicker("Due", selection: Binding(get: { Date(timeIntervalSince1970: d) }, set: { draft.due = m.day($0).timeIntervalSince1970 }), displayedComponents: .date) }
            TextField("Tag", text: $draft.tag).textFieldStyle(.roundedBorder)
            HStack {
                Text("Waits for")
                Menu {
                    ForEach(m.tasks.filter { $0.id != draft.id && !draft.deps.contains($0.id) }) { t in Button(t.title) { draft.deps.append(t.id) } }
                } label: { Label("Add", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                ForEach(draft.deps, id: \.self) { d in
                    if let t = m.task(d) { Button { draft.deps.removeAll { $0 == d } } label: { Label(t.title, systemImage: "xmark.circle.fill").lineLimit(1) }.buttonStyle(.glass) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.fo(.caption)).foregroundStyle(.secondary)
                TextEditor(text: $draft.notes).frame(height: 80).scrollContentBackground(.hidden).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 10)).docMentions($draft.notes)
                MentionStrip(text: draft.notes)
            }
            HStack {
                Button("Delete", role: .destructive) { m.deleteTask(draft.id); dismiss() }.buttonStyle(.glass)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass)
                Button("Save") { m.updateTask(draft); dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 460)
    }
}
