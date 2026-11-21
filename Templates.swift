import SwiftUI

enum Art { case page, table, slide, poster, cards, graph }

struct Template: Identifiable {
    let id: String
    let appKey: String
    let name: String
    let blurb: String
    let colors: [Color]
    let art: Art
    let build: () -> [String: Any]
    var app: AppInfo { allApps.first { $0.key == appKey }! }
    func data() -> Data {
        var o = build(); o["modified"] = Date().timeIntervalSince1970 * 1000
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
}

// MARK: helpers matching each web app's document format
private func el(_ id: Int, _ type: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ extra: [String: Any]) -> [String: Any] {
    var o: [String: Any] = ["id": id, "type": type, "x": x, "y": y, "w": w, "h": h]; extra.forEach { o[$0] = $1 }; return o
}
private func text(_ id: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ t: String, size: Int, bold: Bool = false, color: String = "#111111", font: String = "Helvetica Neue", align: String = "left") -> [String: Any] {
    el(id, "text", x, y, w, h, ["text": t, "font": font, "size": size, "bold": bold, "italic": false, "color": color, "align": align, "fill": ""])
}
private func rect(_ id: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fill: String) -> [String: Any] { el(id, "rect", x, y, w, h, ["fill": fill, "stroke": "", "sw": 0, "rad": 0]) }
private func dataTable(_ id: Int, _ name: String, _ fields: [(String, String)], _ rows: [[Any]]) -> [String: Any] {
    ["id": id, "name": name,
     "fields": fields.enumerated().map { ["id": $0 + 1, "name": $1.0, "type": $1.1] as [String: Any] },
     "rows": rows.enumerated().map { ri, r in ["id": ri + 1, "v": Dictionary(uniqueKeysWithValues: r.enumerated().map { (String($0 + 1), $1) })] as [String: Any] }]
}

private func opts(_ names: [String]) -> [[String: Any]] {
    let cols = ["#cfe0ff", "#c8f0d4", "#ffd9b3", "#ffc9c4", "#e3d6ff", "#fff3b0"]
    return names.enumerated().map { ["name": $1, "color": cols[$0 % cols.count]] }
}
private func richTable(_ id: Int, _ name: String, _ fields: [(String, String, [String: Any])], _ rows: [[Any]]) -> [String: Any] {
    ["id": id, "name": name,
     "fields": fields.enumerated().map { i, f in var o: [String: Any] = ["id": i + 1, "name": f.0, "type": f.1]; for (k, v) in f.2 { o[k] = v }; return o },
     "rows": rows.enumerated().map { ri, r in
        var v: [String: Any] = [:]
        for (i, x) in r.enumerated() { if x is NSNull { continue }; if let s = x as? String, s.isEmpty { continue }; if let n = x as? Int, n == 0, fields[i].1 == "rating" { continue }; v[String(i + 1)] = x }
        return ["id": ri + 1, "v": v] as [String: Any] }]
}

// MARK: Diagrams
private func diagramDoc(_ title: String, _ p: DParsed, _ layout: DiagramModel.LayoutKind) -> [String: Any] {
    var nodes = p.nodes
    let pos = layout == .radial ? DLayout.radial(nodes, p.edges) : DLayout.layered(nodes, p.edges, horizontal: layout == .right)
    for i in nodes.indices { if let q = pos[nodes[i].id] { nodes[i].x = q.x; nodes[i].y = q.y } }
    var edges = p.edges
    if layout == .radial { for i in edges.indices { edges[i].route = "curve"; edges[i].head = "none" } } else { edges = DLayout.routeBackEdges(nodes, edges, horizontal: layout == .right) }
    func json<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? [] }
    return ["title": title, "nodes": json(nodes), "edges": json(edges), "grid": "dots", "snap": true]
}

// MARK: Planner
private func plannerDoc(_ title: String, view: String, events: [(String, Int, Int?, Double, Int, String)], tasks: [(String, Int?, Int?, String, Int, String, [Int])]) -> [String: Any] {
    let cal = Calendar.current, today = cal.startOfDay(for: Date())
    func at(_ off: Int, _ hour: Int?) -> Date { let d = cal.date(byAdding: .day, value: off, to: today)!; return hour.map { cal.date(bySettingHour: $0, minute: 0, second: 0, of: d)! } ?? d }
    let cols = plannerColors
    var evs: [PEvent] = [], tks: [PTask] = []
    for (i, e) in events.enumerated() {
        var ev = PEvent(id: i + 1, title: e.0, start: at(e.1, e.2), end: e.2 == nil ? at(e.1, nil) : at(e.1, e.2!).addingTimeInterval(e.3 * 3600), allDay: e.2 == nil)
        ev.color = cols[e.4 % cols.count]; ev.repeatRule = e.5; evs.append(ev)
    }
    for (i, t) in tasks.enumerated() {
        var tk = PTask(id: i + 1, title: t.0); tk.start = t.1.map { at($0, nil).timeIntervalSince1970 }; tk.due = t.2.map { at($0, nil).timeIntervalSince1970 }
        tk.status = t.3; tk.priority = t.4; tk.tag = t.5; tk.deps = t.6; tk.color = cols[(i + 1) % cols.count]; tks.append(tk)
    }
    func json<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? [] }
    return ["title": title, "view": view, "events": json(evs), "tasks": json(tks)]
}

// MARK: Math
private func mathDoc(_ title: String, _ cells: [MCell]) -> [String: Any] {
    func json<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? [] }
    return ["title": title, "cells": json(cells), "degrees": false]
}
private func mc(_ id: Int, _ kind: String, _ text: String = "", fns: [String]? = nil) -> MCell { var c = MCell(id: id, kind: kind, text: text); if let f = fns { c.fns = f }; return c }

// MARK: helpers for the multi-sheet Sheets format
private func st(b: Bool = false, i: Bool = false, c: String = "", f: String = "", a: String = "", n: String = "") -> [String: Any] {
    var o: [String: Any] = [:]
    if b { o["b"] = true }; if i { o["i"] = true }; if !c.isEmpty { o["c"] = c }; if !f.isEmpty { o["f"] = f }; if !a.isEmpty { o["a"] = a }; if !n.isEmpty { o["n"] = n }
    return o
}
private func rangeStyle(_ c0: Int, _ c1: Int, _ r0: Int, _ r1: Int, _ s: [String: Any]) -> [String: Any] {
    var o: [String: Any] = [:]
    for r in r0...r1 { for c in c0...c1 { o[cellAddress(c, r)] = s } }
    return o
}
private func merge(_ parts: [String: Any]...) -> [String: Any] { parts.reduce(into: [:]) { acc, p in acc.merge(p) { $1 } } }
private func sheetDict(_ name: String, _ cells: [String: String], styles: [String: Any], colW: [Int: Double], charts: [[String: Any]]) -> [String: Any] {
    ["name": name, "cells": cells, "styles": styles, "colW": Dictionary(uniqueKeysWithValues: colW.map { (String($0.key), $0.value) }), "charts": charts]
}

let allTemplates: [Template] = [
    // ---- Writer
    Template(id: "w-letter", appKey: "writer", name: "Cover letter", blurb: "A clean, one-page letter", colors: [.blue, .cyan], art: .page) { [
        "title": "Cover letter",
        "html": "<p>Your Name<br>Your address · you@example.com</p><p>19 November 2026</p><p>Hiring Manager<br>Company name</p><h3>Application for the role of …</h3><p>Dear Hiring Manager,</p><p>I'm writing to apply for … I'd bring … to your team.</p><p>In my last role I … This taught me …</p><p>Thank you for your time. I'd love to talk further.</p><p>Sincerely,<br>Your Name</p>"] },
    Template(id: "w-notes", appKey: "writer", name: "Meeting notes", blurb: "Agenda, notes and actions", colors: [.indigo, .blue], art: .page) { [
        "title": "Meeting notes",
        "html": "<h1>Meeting notes</h1><p><b>Date:</b> …<br><b>Attendees:</b> …</p><h2>Agenda</h2><ul><li>Item one</li><li>Item two</li></ul><h2>Notes</h2><p>…</p><h2>Action items</h2><ul><li>Who — what — by when</li></ul>"] },
    Template(id: "w-brief", appKey: "writer", name: "Project brief", blurb: "Goals, scope and timeline", colors: [.teal, .blue], art: .page) { [
        "title": "Project brief",
        "html": "<h1>Project brief</h1><h2>Overview</h2><p>What is this and why does it matter?</p><h2>Goals</h2><ul><li>Goal one</li><li>Goal two</li></ul><h2>Scope</h2><p>In scope … Out of scope …</p><h2>Timeline</h2><p>Milestones and dates.</p>"] },
    // ---- Sheets (multi-sheet format: styles, number formats, charts)
    Template(id: "s-budget", appKey: "sheets", name: "Monthly budget", blurb: "Planned vs actual, with a chart", colors: [.green, .mint], art: .table) { [
        "title": "Monthly budget", "active": 0,
        "sheets": [sheetDict("Budget",
            ["A1": "Item", "B1": "Planned", "C1": "Actual", "D1": "Difference",
             "A2": "Rent", "B2": "1200", "C2": "1200", "D2": "=B2-C2", "A3": "Food", "B3": "400", "C3": "435", "D3": "=B3-C3",
             "A4": "Transport", "B4": "120", "C4": "98", "D4": "=B4-C4", "A5": "Fun", "B5": "150", "C5": "210", "D5": "=B5-C5",
             "A7": "Total", "B7": "=SUM(B2:B5)", "C7": "=SUM(C2:C5)", "D7": "=SUM(D2:D5)"],
            styles: merge(rangeStyle(0, 3, 0, 0, st(b: true, f: "#cfe0ff")), rangeStyle(1, 3, 1, 6, st(n: "cur")), rangeStyle(0, 3, 6, 6, st(b: true, f: "#e6e6e6", n: "cur"))),
            colW: [0: 150, 1: 110, 2: 110, 3: 110], charts: [["id": 1, "type": "bar", "range": "A1:C5", "title": "Planned vs actual"]])]] },
    Template(id: "s-invoice", appKey: "sheets", name: "Invoice", blurb: "Line items that total themselves", colors: [.green, .teal], art: .table) { [
        "title": "Invoice", "active": 0,
        "sheets": [sheetDict("Invoice",
            ["A1": "INVOICE", "A3": "Description", "B3": "Qty", "C3": "Price", "D3": "Total",
             "A4": "Design work", "B4": "10", "C4": "60", "D4": "=B4*C4", "A5": "Development", "B5": "20", "C5": "75", "D5": "=B5*C5",
             "A6": "Hosting", "B6": "12", "C6": "9", "D6": "=B6*C6", "C8": "Subtotal", "D8": "=SUM(D4:D6)", "C9": "VAT 20%", "D9": "=D8*0.2", "C10": "Total due", "D10": "=D8+D9"],
            styles: merge(["A1": st(b: true)], rangeStyle(0, 3, 2, 2, st(b: true, f: "#cfe0ff")), rangeStyle(2, 3, 3, 9, st(n: "cur")), rangeStyle(2, 3, 9, 9, st(b: true, f: "#e6e6e6", n: "cur"))),
            colW: [0: 170, 1: 70, 2: 100, 3: 110], charts: [])]] },
    Template(id: "s-sales", appKey: "sheets", name: "Sales tracker", blurb: "Two sheets, lookups and a chart", colors: [.green, .blue], art: .table) { [
        "title": "Sales tracker", "active": 0,
        "sheets": [
            sheetDict("Sales",
                ["A1": "Month", "B1": "Revenue", "C1": "Units", "D1": "Price",
                 "A2": "Jan", "B2": "=C2*D2", "C2": "120", "D2": "24.5", "A3": "Feb", "B3": "=C3*D3", "C3": "135", "D3": "24.5",
                 "A4": "Mar", "B4": "=C4*D4", "C4": "160", "D4": "26", "A5": "Apr", "B5": "=C5*D5", "C5": "148", "D5": "26",
                 "A6": "May", "B6": "=C6*D6", "C6": "190", "D6": "27.5", "A7": "Jun", "B7": "=C7*D7", "C7": "210", "D7": "27.5"],
                styles: merge(rangeStyle(0, 3, 0, 0, st(b: true, f: "#cfe0ff")), rangeStyle(1, 1, 1, 6, st(n: "cur")), rangeStyle(3, 3, 1, 6, st(n: "cur"))),
                colW: [0: 90, 1: 120], charts: [["id": 1, "type": "line", "range": "A1:B7", "title": "Revenue by month"]]),
            sheetDict("Summary",
                ["A1": "Total revenue", "B1": "=SUM(Sales!B2:B7)", "A2": "Average month", "B2": "=AVERAGE(Sales!B2:B7)",
                 "A3": "Best month", "B3": "=INDEX(Sales!A2:A7,MATCH(MAX(Sales!B2:B7),Sales!B2:B7,0))", "A4": "Units sold", "B4": "=SUM(Sales!C2:C7)",
                 "A5": "Months over 5,000", "B5": "=COUNTIF(Sales!B2:B7,\">5000\")"],
                styles: merge(rangeStyle(0, 0, 0, 4, st(b: true)), ["B1": st(b: true, n: "cur"), "B2": st(n: "cur")]), colW: [0: 160, 1: 130], charts: [])]] },
    // ---- Slides (layouts, themes, speaker notes)
    Template(id: "l-pitch", appKey: "slides", name: "Pitch deck", blurb: "Problem, solution, market, ask", colors: [.orange, .pink], art: .slide) { [
        "title": "Pitch deck", "theme": "dark", "numbers": true, "transition": "fade",
        "slides": [
            templateSlide(.title, ["Company name", "One line that says what you do"], notes: "Introduce yourself in one sentence."),
            templateSlide(.statement, ["Every team loses hours to a problem nobody owns."], notes: "Open with the pain, then pause."),
            templateSlide(.content, ["The problem", "Who has it\nWhy it hurts\nWhat they do today"]),
            templateSlide(.content, ["Our solution", "How it works\nWhy it's better\nProof it works"]),
            templateSlide(.two, ["The market", "Size\nGrowth\nWhy now", "Customers\nCompetitors\nOur edge"]),
            templateSlide(.section, ["The ask", "What we're raising and what it unlocks"])]] },
    Template(id: "l-update", appKey: "slides", name: "Weekly update", blurb: "Wins, progress, blockers", colors: [.orange, .yellow], art: .slide) { [
        "title": "Weekly update", "theme": "light", "numbers": true, "transition": "fade",
        "slides": [
            templateSlide(.title, ["Weekly update", "Week of …"]),
            templateSlide(.content, ["Wins", "…\n…"]), templateSlide(.content, ["In progress", "…\n…"]),
            templateSlide(.content, ["Blockers", "…"]), templateSlide(.content, ["Next week", "…\n…"])]] },
    Template(id: "l-talk", appKey: "slides", name: "Conference talk", blurb: "Big statements and a quote", colors: [.purple, .orange], art: .slide) { [
        "title": "Conference talk", "theme": "sunset", "numbers": false, "transition": "push",
        "slides": [
            templateSlide(.title, ["A talk worth giving", "Your name · Event · Date"], notes: "Smile. Say hello. Say why you're here."),
            templateSlide(.section, ["Why this matters", "Set the stage in one sentence"]),
            templateSlide(.statement, ["The big idea, in one line."]),
            templateSlide(.image, ["What it looks like", "Describe the picture\nKey detail\nWhy it works"]),
            templateSlide(.quote, ["“Something memorable someone once said.”", "— Source"]),
            templateSlide(.content, ["Takeaways", "One thing to remember\nOne thing to try\nWhere to learn more"]),
            templateSlide(.section, ["Thank you", "Questions?"])]] },
    // ---- Poster
    Template(id: "p-event", appKey: "poster", name: "Event poster", blurb: "Bold, dark, big type", colors: [.pink, .orange], art: .poster) { [
        "title": "Event poster", "size": "A4 portrait", "bg": "#111111",
        "els": [rect(1, 0, 0, 794, 1123, "#111111"), el(2, "ellipse", 440, -120, 500, 500, ["fill": "#f6a33b", "stroke": "", "sw": 0]),
                text(3, 60, 380, 674, 350, "SUMMER\nNIGHT\nMARKET", size: 96, bold: true, color: "#ffffff"),
                el(4, "line", 60, 740, 200, 0, ["stroke": "#f6a33b", "sw": 8]),
                text(5, 60, 780, 674, 130, "Saturday 14 June · 6pm\nRiverside Park", size: 34, color: "#ffffff"),
                text(6, 60, 1010, 674, 50, "Free entry · Live music · Street food", size: 22, color: "#aaaaaa")]] },
    Template(id: "p-sale", appKey: "poster", name: "Big sale", blurb: "Loud yellow sale poster", colors: [.yellow, .orange], art: .poster) { [
        "title": "Big sale", "size": "A4 portrait", "bg": "#ffd23f",
        "els": [text(1, 50, 140, 700, 400, "BIG\nSALE", size: 150, bold: true), text(2, 50, 650, 700, 90, "UP TO 50% OFF", size: 64, bold: true),
                rect(3, 0, 880, 794, 160, "#111111"), text(4, 50, 925, 700, 70, "This weekend only · In store & online", size: 30, color: "#ffffff")]] },
    Template(id: "p-quote", appKey: "poster", name: "Quote card", blurb: "Square, ready to share", colors: [.purple, .indigo], art: .poster) { [
        "title": "Quote card", "size": "Square 1080", "bg": "#1b1b3a",
        "els": [text(1, 100, 230, 880, 520, "“Make the thing you wish existed.”", size: 84, bold: true, color: "#ffffff", font: "Georgia"),
                el(2, "line", 100, 800, 160, 0, ["stroke": "#7a9bff", "sw": 8]), text(3, 100, 840, 880, 60, "— Your name", size: 36, color: "#c8d0ff")]] },
    // ---- Data
    Template(id: "d-contacts", appKey: "data", name: "Contacts book", blurb: "People, companies, status and ratings", colors: [.purple, .indigo], art: .cards) { [
        "title": "Contacts",
        "tables": [
            dataTable(1, "Companies", [("Name", "text"), ("Website", "url")], [["Analytical Engines", "https://example.com"], ["US Navy", "https://example.org"]]),
            richTable(2, "Contacts", [("Name", "text", [:]), ("Email", "email", [:]), ("Company", "link", ["target": 1]), ("Status", "select", ["options": opts(["Lead", "Active", "Friend"])]),
                                      ("Rating", "rating", [:]), ("Met on", "date", [:]), ("Favourite", "checkbox", [:])],
                      [["Ada Lovelace", "ada@example.com", 1, "Active", 5, "2026-02-11", true], ["Grace Hopper", "grace@example.com", 2, "Friend", 4, "2026-05-03", false], ["Alan Turing", "alan@example.com", 1, "Lead", 3, "2026-06-20", false]])]] },
    Template(id: "d-inventory", appKey: "data", name: "Inventory", blurb: "Stock, prices and a computed total", colors: [.purple, .pink], art: .cards) { [
        "title": "Inventory",
        "tables": [richTable(1, "Inventory", [("Item", "text", [:]), ("Category", "select", ["options": opts(["Stationery", "Office", "Tech"])]), ("Quantity", "number", [:]), ("Price", "currency", [:]),
                                              ("Value", "formula", ["formula": "Quantity * Price", "agg": "sum"]), ("In stock", "checkbox", [:])],
                             [["Notebook", "Stationery", 120, 3.5, NSNull(), true], ["Pen", "Stationery", 340, 1.2, NSNull(), true], ["Stapler", "Office", 0, 8.0, NSNull(), false], ["Keyboard", "Tech", 14, 39.0, NSNull(), true]])]] },
    Template(id: "d-books", appKey: "data", name: "Reading list", blurb: "A board of what to read, reading and read", colors: [.indigo, .blue], art: .cards) { [
        "title": "Reading list",
        "tables": [richTable(1, "Books", [("Title", "text", [:]), ("Author", "text", [:]), ("Status", "select", ["options": opts(["To read", "Reading", "Done"])]), ("Rating", "rating", [:]), ("Finished", "date", [:])],
                             [["Dune", "Frank Herbert", "Done", 5, "2026-03-20"], ["Piranesi", "Susanna Clarke", "Done", 4, "2026-06-01"], ["The Dispossessed", "Ursula K. Le Guin", "Reading", 0, ""], ["Hyperion", "Dan Simmons", "To read", 0, ""]])]] },
    // ---- Diagrams
    Template(id: "g-flow", appKey: "diagrams", name: "Flowchart", blurb: "Steps, decisions and a loop back", colors: [.teal, .green], art: .graph) {
        diagramDoc("Flowchart", DText.parseFlow("flowchart TD\n  A([Start]) --> B[Do the thing]\n  B --> C{Did it work?}\n  C -->|yes| D([Done])\n  C -->|no| E[Fix it]\n  E --> B"), .down) },
    Template(id: "g-org", appKey: "diagrams", name: "Org chart", blurb: "Who reports to whom", colors: [.teal, .blue], art: .graph) {
        diagramDoc("Org chart", DText.parseOutline("Managing director\n  Engineering\n    Frontend\n    Backend\n    Platform\n  Operations\n    Support\n    Logistics\n  Finance\n    Payroll", mind: false), .down) },
    Template(id: "g-mind", appKey: "diagrams", name: "Mind map", blurb: "Ideas branching out from one centre", colors: [.teal, .purple], art: .graph) {
        diagramDoc("Mind map", DText.parseOutline("My project\n  Goals\n    Ship version one\n    Learn from users\n  Team\n    Design\n    Build\n    Test\n  Risks\n    Time\n    Budget\n  Launch\n    Website\n    Announcement", mind: true), .radial) },
    Template(id: "g-system", appKey: "diagrams", name: "System sketch", blurb: "App, API and database", colors: [.teal, .indigo], art: .graph) {
        diagramDoc("System sketch", DText.parseFlow("flowchart LR\n  U((User)) --> W[Web app]\n  W --> A[API server]\n  A --> D[(Database)]\n  A -.-> Q{{Queue}}\n  Q --> J[Worker]\n  J --> D"), .right) },
    // ---- Planner
    Template(id: "m-week", appKey: "planner", name: "Weekly plan", blurb: "A calendar with a few tasks to start", colors: [.red, .orange], art: .table) {
        plannerDoc("Weekly plan", view: "week", events: [("Team stand-up", 0, 9, 0.5, 0, "weekly"), ("Deep work", 1, 10, 3, 1, "none"), ("Lunch with Sam", 2, 12, 1, 2, "none"), ("Gym", 1, 18, 1, 4, "weekly"), ("Birthday", 4, nil, 0, 3, "yearly")],
                   tasks: [("Reply to emails", nil, 0, "todo", 3, "work", []), ("Book dentist", nil, 2, "todo", 1, "home", []), ("Plan next week", nil, 4, "todo", 2, "", [])]) },
    Template(id: "m-project", appKey: "planner", name: "Project plan", blurb: "Tasks with dates and dependencies on a timeline", colors: [.red, .pink], art: .table) {
        plannerDoc("Project plan", view: "timeline", events: [("Kick-off", 0, 10, 1, 0, "none"), ("Launch day", 28, nil, 0, 3, "none")],
                   tasks: [("Research", 0, 4, "done", 2, "discovery", []), ("Design", 4, 11, "doing", 2, "design", [1]), ("Build", 11, 22, "todo", 3, "engineering", [2]), ("Test", 20, 25, "todo", 2, "qa", [3]), ("Launch", 26, 28, "todo", 3, "release", [4])]) },
    Template(id: "m-study", appKey: "planner", name: "Study timetable", blurb: "Repeating lessons and revision tasks", colors: [.red, .purple], art: .table) {
        plannerDoc("Study timetable", view: "week", events: [("Maths", 0, 9, 1, 0, "weekly"), ("Physics", 1, 11, 1, 1, "weekly"), ("History", 2, 9, 1, 2, "weekly"), ("Revision block", 3, 14, 2, 4, "weekly"), ("Exam", 21, 9, 2, 3, "none")],
                   tasks: [("Past paper: Maths", nil, 3, "todo", 3, "maths", []), ("Flashcards: Physics", nil, 5, "todo", 2, "physics", []), ("Essay plan: History", nil, 6, "todo", 2, "history", [])]) },
    // ---- Math
    Template(id: "x-calc", appKey: "math", name: "Calculator pad", blurb: "Variables, functions and instant answers", colors: [.indigo, .blue], art: .table) {
        mathDoc("Calculator pad", [mc(1, "note", "Each line is its own calculation. Define variables and functions, then use them below."),
            mc(2, "calc", "price = 49.99\nqty = 3\nsubtotal = price * qty\nsubtotal * 1.2\n\nf(x) = x^2 - 4x + 3\nsolve(f(x), 0)\nintegrate(f(x), 0, 3)\ndiff(f(x), 2)\nsum(k^2, k, 1, 10)")]) },
    Template(id: "x-graph", appKey: "math", name: "Function plotter", blurb: "Graph several functions at once", colors: [.indigo, .mint], art: .table) {
        mathDoc("Function plotter", [mc(1, "graph", "", fns: ["sin(x)", "cos(x)", "x^2 / 10", "abs(x) - 3"]), mc(2, "calc", "f(x) = sin(x) + x / 2\nsolve(f(x), 2)\nintegrate(sin(x), 0, pi)"), mc(3, "graph", "", fns: ["f(x)", "tan(x)"])]) },
    Template(id: "x-algebra", appKey: "math", name: "Algebra & calculus", blurb: "Quadratics, roots and a graph", colors: [.indigo, .purple], art: .table) {
        mathDoc("Algebra & calculus", [mc(1, "note", "The quadratic formula, then the same problem worked and plotted."),
            mc(2, "tex", "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
            mc(3, "calc", "a = 1\nb = -3\nc = 2\ndisc = b^2 - 4a*c\nx1 = (-b + sqrt(disc)) / (2a)\nx2 = (-b - sqrt(disc)) / (2a)"),
            mc(4, "graph", "", fns: ["a*x^2 + b*x + c"]),
            mc(5, "tex", "\\int_{1}^{2} (x^2 - 3x + 2)\\,dx = -\\frac{1}{6}"),
            mc(6, "calc", "integrate(a*x^2 + b*x + c, 1, 2)")]) },
    Template(id: "x-physics", appKey: "math", name: "Physics formulas", blurb: "Typeset formulas with worked numbers", colors: [.indigo, .teal], art: .table) {
        mathDoc("Physics formulas", [mc(1, "tex", "F = ma, \\qquad E = mc^2, \\qquad v = \\frac{d}{t}"),
            mc(2, "calc", "g = 9.81\nm = 2.5\nweight = m * g\nc = 299792458\nm * c^2\nheight = 20\nsqrt(2 * g * height)"),
            mc(3, "tex", "T = 2\\pi \\sqrt{\\frac{L}{g}}"),
            mc(4, "calc", "L = 1.5\n2 pi sqrt(L / g)")]) },
]
