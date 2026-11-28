// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

// Planner: a calendar, a task list and a timeline in one document. No accounts, no invitations — just your plan.

struct PEvent: Codable, Identifiable, Equatable {
    var id: Int
    var title = ""
    var start = 0.0, end = 0.0              // seconds since 1970; all-day events run from start day to end day inclusive
    var allDay = false
    var color = "#cfe0ff"
    var location = "", notes = ""
    var repeatRule = "none"                 // none · daily · weekly · monthly · yearly
    var until: Double?
    init(id: Int, title: String = "", start: Date, end: Date, allDay: Bool = false) { self.id = id; self.title = title; self.start = start.timeIntervalSince1970; self.end = end.timeIntervalSince1970; self.allDay = allDay }
    enum CodingKeys: String, CodingKey { case id, title, start, end, allDay, color, location, notes, repeatRule, until }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = try c.decode(Int.self, forKey: .id); title = v(.title, ""); start = v(.start, 0); end = v(.end, start); allDay = v(.allDay, false); color = v(.color, "#cfe0ff")
        location = v(.location, ""); notes = v(.notes, ""); repeatRule = v(.repeatRule, "none"); until = try? c.decodeIfPresent(Double.self, forKey: .until)
    }
    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }
}

struct PTask: Codable, Identifiable, Equatable {
    var id: Int
    var title = ""
    var status = "todo"                     // todo · doing · done
    var priority = 0                        // 0 none · 1 low · 2 medium · 3 high
    var start: Double?, due: Double?        // start of day
    var tag = "", notes = ""
    var deps: [Int] = []                    // tasks that must finish first
    var color = "#cfe0ff"
    var done: Bool { status == "done" }
    init(id: Int, title: String = "") { self.id = id; self.title = title }
    enum CodingKeys: String, CodingKey { case id, title, status, priority, start, due, tag, notes, deps, color }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        id = try c.decode(Int.self, forKey: .id); title = v(.title, ""); status = v(.status, "todo"); priority = v(.priority, 0)
        start = try? c.decodeIfPresent(Double.self, forKey: .start); due = try? c.decodeIfPresent(Double.self, forKey: .due)
        tag = v(.tag, ""); notes = v(.notes, ""); deps = v(.deps, []); color = v(.color, "#cfe0ff")
    }
    var startDate: Date? { start.map { Date(timeIntervalSince1970: $0) } }
    var dueDate: Date? { due.map { Date(timeIntervalSince1970: $0) } }
}

struct POcc: Identifiable { let event: PEvent; let start: Date, end: Date
    var id: String { "\(event.id)@\(Int(start.timeIntervalSince1970))" } }

struct PlannerState: Equatable { var events: [PEvent]; var tasks: [PTask] }

let plannerColors = ["#cfe0ff", "#c8f0d4", "#ffd9b3", "#ffc9c4", "#e3d6ff", "#fff3b0", "#d3f0f5", "#e6e6e6"]

final class PlannerModel: ObservableObject {
    let history = UndoHistory<PlannerState>()
    @Published var events: [PEvent] { didSet { if ready { history.record(PlannerState(events: oldValue, tasks: tasks)); saver.touch() } } }
    @Published var tasks: [PTask] { didSet { if ready { history.record(PlannerState(events: events, tasks: oldValue)); saver.touch() } } }
    @Published var title: String { didSet { if ready { saver.touch() } } }
    @Published var view: String { didSet { if ready { saver.touch() } } }          // month · week · agenda · tasks · timeline
    @Published var anchor = Date()
    @Published var editEvent: Int?
    @Published var editTask: Int?
    @Published var search = ""
    @Published var showDone = true
    @Published var tasksAsBoard = false
    @Published var savedAt: Date?
    @Published var status: String?
    let saver: AutoSaver
    private var ready = false
    var cal = Calendar.current

    init(id: String, dir: URL, now: Date = Date()) {
        saver = AutoSaver(url: docURL(dir, "planner", id))
        struct In: Decodable { var title: String?; var events: [PEvent]?; var tasks: [PTask]?; var view: String? }
        var e: [PEvent] = [], t: [PTask] = [], ti = "", v = "month"
        if let d = try? Data(contentsOf: saver.url), let o = try? JSONDecoder().decode(In.self, from: d) { e = o.events ?? []; t = o.tasks ?? []; ti = o.title ?? ""; v = o.view ?? "month" }
        if let fv = ProcessInfo.processInfo.environment["FO_VIEW"] { v = fv }
        events = e; tasks = t; title = ti; view = v; anchor = now
        ready = true
        saver.make = { [weak self] in
            guard let m = self else { return nil }
            struct Out: Encodable { var title: String; var events: [PEvent]; var tasks: [PTask]; var view: String; var modified: Double }
            return try? JSONEncoder().encode(Out(title: m.title, events: m.events, tasks: m.tasks, view: m.view, modified: nowMillis()))
        }
        saver.onSaved = { [weak self] in self?.savedAt = Date() }
    }

    func undo() { if let s = history.undo(current: PlannerState(events: events, tasks: tasks)) { apply(s) } }
    func redo() { if let s = history.redo(current: PlannerState(events: events, tasks: tasks)) { apply(s) } }
    private func apply(_ s: PlannerState) { history.applying = true; events = s.events; tasks = s.tasks; history.applying = false; saver.touch() }

    // MARK: dates
    func day(_ d: Date) -> Date { cal.startOfDay(for: d) }
    func add(_ n: Int, _ c: Calendar.Component, to d: Date) -> Date { cal.date(byAdding: c, value: n, to: d) ?? d }
    var today: Date { day(Date()) }
    func weekStart(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)?.start ?? day(d) }
    func monthGrid(_ d: Date) -> [Date] {
        let first = cal.dateInterval(of: .month, for: d)!.start, start = weekStart(first)
        return (0..<42).map { add($0, .day, to: start) }
    }
    func move(_ dir: Int) {
        switch view { case "week": anchor = add(7 * dir, .day, to: anchor); case "month": anchor = add(dir, .month, to: anchor); default: anchor = add(7 * dir, .day, to: anchor) }
    }
    var rangeTitle: String {
        let f = DateFormatter()
        switch view {
        case "month": f.dateFormat = "LLLL yyyy"; return f.string(from: anchor)
        case "week": let s = weekStart(anchor), e = add(6, .day, to: s); f.dateFormat = "d MMM"; let y = DateFormatter(); y.dateFormat = "yyyy"; return "\(f.string(from: s)) – \(f.string(from: e)) \(y.string(from: e))"
        case "agenda": return "Coming up"
        case "tasks": return "Tasks"
        default: f.dateFormat = "LLLL yyyy"; return "Timeline · " + f.string(from: anchor)
        }
    }

    // MARK: events
    @discardableResult func addEvent(on d: Date, hour: Int? = nil, title: String = "New event") -> Int {
        let id = (events.map(\.id).max() ?? 0) + 1
        var e: PEvent
        if let h = hour { let s = cal.date(bySettingHour: h, minute: 0, second: 0, of: d)!; e = PEvent(id: id, title: title, start: s, end: add(1, .hour, to: s)) }
        else { e = PEvent(id: id, title: title, start: day(d), end: day(d), allDay: true) }
        e.color = plannerColors[id % plannerColors.count]
        events.append(e); editEvent = id; return id
    }
    func event(_ id: Int) -> PEvent? { events.first { $0.id == id } }
    func updateEvent(_ e: PEvent) { if let i = events.firstIndex(where: { $0.id == e.id }) { events[i] = e } }
    func deleteEvent(_ id: Int) { events.removeAll { $0.id == id }; if editEvent == id { editEvent = nil } }
    /// Moves an event so it starts at `newStart`, keeping its length.
    func moveEvent(_ id: Int, to newStart: Date) {
        guard var e = event(id) else { return }
        let len = e.end - e.start
        e.start = (e.allDay ? day(newStart) : newStart).timeIntervalSince1970; e.end = e.start + len; updateEvent(e)
    }

    func occurrences(from lo: Date, to hi: Date) -> [POcc] {
        var out: [POcc] = []
        let q = search.lowercased()
        for e in events where q.isEmpty || e.title.lowercased().contains(q) || e.location.lowercased().contains(q) || e.notes.lowercased().contains(q) {
            let s0 = e.startDate
            let len = e.allDay ? (day(e.endDate).timeIntervalSince(day(s0)) + 86400) : max(e.end - e.start, 900)
            func add(_ s: Date) { let en = s.addingTimeInterval(len); if s < hi && en > lo { out.append(POcc(event: e, start: s, end: en)) } }
            if e.repeatRule == "none" { add(s0); continue }
            let (comp, step): (Calendar.Component, Int) = e.repeatRule == "daily" ? (.day, 1) : e.repeatRule == "weekly" ? (.day, 7) : e.repeatRule == "monthly" ? (.month, 1) : (.year, 1)
            var k = 0
            while k < 6000 {
                let s = cal.date(byAdding: comp, value: step * k, to: s0) ?? s0
                if s >= hi { break }
                if let u = e.until, s.timeIntervalSince1970 > u + 86399 { break }
                add(s); k += 1
            }
        }
        return out.sorted { $0.start < $1.start }
    }
    func occurrences(on d: Date) -> [POcc] { let s = day(d); return occurrences(from: s, to: add(1, .day, to: s)) }

    // MARK: tasks
    @discardableResult func addTask(_ title: String, due: Date? = nil, priority: Int = 0, tag: String = "") -> Int {
        let id = (tasks.map(\.id).max() ?? 0) + 1
        var t = PTask(id: id, title: title); t.due = due.map { day($0).timeIntervalSince1970 }; t.priority = priority; t.tag = tag; t.color = plannerColors[id % plannerColors.count]
        tasks.append(t); return id
    }
    func task(_ id: Int) -> PTask? { tasks.first { $0.id == id } }
    func updateTask(_ t: PTask) { if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } }
    func deleteTask(_ id: Int) { tasks.removeAll { $0.id == id }; for i in tasks.indices { tasks[i].deps.removeAll { $0 == id } }; if editTask == id { editTask = nil } }
    func toggle(_ id: Int) { if var t = task(id) { t.status = t.done ? "todo" : "done"; updateTask(t) } }
    func setStatus(_ id: Int, _ s: String) { if var t = task(id) { t.status = s; updateTask(t) } }
    func blocked(_ t: PTask) -> Bool { t.deps.contains { d in task(d).map { !$0.done } ?? false } }

    /// Overdue · Today · Upcoming · No date · Done
    func groups(now: Date = Date()) -> [(title: String, tasks: [PTask])] {
        let td = day(now), q = search.lowercased()
        let all = tasks.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.tag.lowercased().contains(q) || $0.notes.lowercased().contains(q) }
        func by(_ a: PTask, _ b: PTask) -> Bool { (a.due ?? .infinity, -Double(a.priority)) < (b.due ?? .infinity, -Double(b.priority)) }
        let open = all.filter { !$0.done }
        let g: [(String, [PTask])] = [
            ("Overdue", open.filter { ($0.dueDate ?? .distantFuture) < td }.sorted(by: by)),
            ("Today", open.filter { $0.dueDate.map { day($0) == td } ?? false }.sorted(by: by)),
            ("Upcoming", open.filter { ($0.dueDate ?? .distantPast) > td }.sorted(by: by)),
            ("No date", open.filter { $0.due == nil }.sorted(by: by)),
            ("Done", showDone ? all.filter { $0.done }.sorted(by: by) : [])]
        return g.filter { !$0.1.isEmpty }
    }

    // MARK: quick add — "Call Sam tomorrow !high #work"
    func parseQuickAdd(_ text: String, now: Date = Date()) -> (title: String, due: Date?, priority: Int, tag: String) {
        var words = text.split(separator: " ").map(String.init), due: Date?, pri = 0, tag = ""
        let names = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var keep: [String] = [], i = 0
        while i < words.count {
            let w = words[i], l = w.lowercased()
            if l == "today" { due = day(now) }
            else if l == "tomorrow" || l == "tmrw" { due = add(1, .day, to: day(now)) }
            else if l == "next", i + 1 < words.count, words[i + 1].lowercased() == "week" { due = add(7, .day, to: day(now)); i += 1 }
            else if l == "in", i + 2 < words.count, let n = Int(words[i + 1]), ["day", "days", "week", "weeks"].contains(words[i + 2].lowercased()) { due = add(words[i + 2].lowercased().hasPrefix("week") ? n * 7 : n, .day, to: day(now)); i += 2 }
            else if let wd = names[l] { let cur = cal.component(.weekday, from: now); due = add((wd - cur + 7) % 7 == 0 ? 7 : (wd - cur + 7) % 7, .day, to: day(now)) }
            else if l == "!high" || l == "!3" || l == "!!!" { pri = 3 } else if l == "!med" || l == "!2" || l == "!!" { pri = 2 } else if l == "!low" || l == "!1" || l == "!" { pri = 1 }
            else if w.hasPrefix("#"), w.count > 1 { tag = String(w.dropFirst()) }
            else { keep.append(w) }
            i += 1
        }
        words = keep
        return (words.joined(separator: " "), due, pri, tag)
    }
    func quickAdd(_ text: String) { let p = parseQuickAdd(text); guard !p.title.isEmpty else { return }; addTask(p.title, due: p.due, priority: p.priority, tag: p.tag) }

    // MARK: iCalendar
    func ics() -> String {
        func stamp(_ d: Date, allDay: Bool) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); if allDay { f.dateFormat = "yyyyMMdd"; return f.string(from: d) }; f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f.string(from: d) }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n") }
        var o = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//FreeOffice//Planner//EN"]
        for e in events {
            o += ["BEGIN:VEVENT", "UID:fo-e\(e.id)@freeoffice", "DTSTAMP:\(stamp(Date(), allDay: false))", "SUMMARY:\(esc(e.title))"]
            if e.allDay { o += ["DTSTART;VALUE=DATE:\(stamp(e.startDate, allDay: true))", "DTEND;VALUE=DATE:\(stamp(add(1, .day, to: day(e.endDate)), allDay: true))"] }
            else { o += ["DTSTART:\(stamp(e.startDate, allDay: false))", "DTEND:\(stamp(e.endDate, allDay: false))"] }
            if !e.location.isEmpty { o.append("LOCATION:\(esc(e.location))") }; if !e.notes.isEmpty { o.append("DESCRIPTION:\(esc(DocLinks.plain(e.notes)))") }
            if e.repeatRule != "none" { o.append("RRULE:FREQ=\(e.repeatRule.uppercased())" + (e.until.map { ";UNTIL=\(stamp(Date(timeIntervalSince1970: $0), allDay: true))" } ?? "")) }
            o.append("END:VEVENT")
        }
        for t in tasks {
            o += ["BEGIN:VTODO", "UID:fo-t\(t.id)@freeoffice", "DTSTAMP:\(stamp(Date(), allDay: false))", "SUMMARY:\(esc(t.title))", "STATUS:\(t.done ? "COMPLETED" : t.status == "doing" ? "IN-PROCESS" : "NEEDS-ACTION")"]
            if let d = t.dueDate { o.append("DUE;VALUE=DATE:\(stamp(d, allDay: true))") }; if t.priority > 0 { o.append("PRIORITY:\([0, 9, 5, 1][t.priority])") }
            o.append("END:VTODO")
        }
        return (o + ["END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }
    @discardableResult func importICS(_ text: String) -> (events: Int, tasks: Int) {
        func unesc(_ s: String) -> String { s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\") }
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") { if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else { lines.append(raw) } }
        func date(_ v: String) -> (Date, Bool)? {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            if v.count == 8 { f.dateFormat = "yyyyMMdd"; return f.date(from: v).map { ($0, true) } }
            if v.hasSuffix("Z") { f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'" } else { f.dateFormat = "yyyyMMdd'T'HHmmss" }
            return f.date(from: v).map { ($0, false) }
        }
        var ne = 0, nt = 0, cur: [String: String]?, kind = ""
        var newEvents = events, newTasks = tasks
        for l in lines {
            if l == "BEGIN:VEVENT" || l == "BEGIN:VTODO" { cur = [:]; kind = l.hasSuffix("EVENT") ? "e" : "t"; continue }
            if l == "END:VEVENT" || l == "END:VTODO", let c = cur {
                if kind == "e", let s = c["DTSTART"].flatMap(date) {
                    let en = c["DTEND"].flatMap(date)
                    let id = (newEvents.map(\.id).max() ?? 0) + 1
                    var e = PEvent(id: id, title: unesc(c["SUMMARY"] ?? "Event"), start: s.0, end: s.1 ? add(-1, .day, to: en?.0 ?? add(1, .day, to: s.0)) : (en?.0 ?? s.0.addingTimeInterval(3600)), allDay: s.1)
                    if s.1 && e.end < e.start { e.end = e.start }
                    e.location = unesc(c["LOCATION"] ?? ""); e.notes = unesc(c["DESCRIPTION"] ?? ""); e.color = plannerColors[id % plannerColors.count]
                    if let r = c["RRULE"], let f = r.components(separatedBy: ";").first(where: { $0.hasPrefix("FREQ=") }) { let v = f.dropFirst(5).lowercased(); if ["daily", "weekly", "monthly", "yearly"].contains(v) { e.repeatRule = v }
                        if let u = r.components(separatedBy: ";").first(where: { $0.hasPrefix("UNTIL=") }), let d = date(String(u.dropFirst(6))) { e.until = d.0.timeIntervalSince1970 } }
                    newEvents.append(e); ne += 1
                } else if kind == "t" {
                    let id = (newTasks.map(\.id).max() ?? 0) + 1; var t = PTask(id: id, title: unesc(c["SUMMARY"] ?? "Task"))
                    if let d = c["DUE"].flatMap(date) { t.due = day(d.0).timeIntervalSince1970 }
                    if c["STATUS"] == "COMPLETED" { t.status = "done" } else if c["STATUS"] == "IN-PROCESS" { t.status = "doing" }
                    if let p = c["PRIORITY"].flatMap(Int.init), p > 0 { t.priority = p <= 3 ? 3 : p <= 5 ? 2 : 1 }
                    t.color = plannerColors[id % plannerColors.count]; newTasks.append(t); nt += 1
                }
                cur = nil; continue
            }
            if cur != nil, let r = l.firstIndex(of: ":") { let key = String(l[..<r]).components(separatedBy: ";")[0]; cur![key] = String(l[l.index(after: r)...]) }
        }
        events = newEvents; tasks = newTasks
        return (ne, nt)
    }
    func exportICS() { guard let u = savePanel((title.isEmpty ? "plan" : title) + ".ics") else { return }; try? ics().write(to: u, atomically: true, encoding: .utf8); status = "Exported \(u.lastPathComponent)" }
    func importICSFile() {
        let p = NSOpenPanel(); guard p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        let r = importICS(s); status = "Imported \(r.events) event\(r.events == 1 ? "" : "s") and \(r.tasks) task\(r.tasks == 1 ? "" : "s")"
    }
}
