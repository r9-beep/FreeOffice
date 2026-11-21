import SwiftUI

struct Guide: Identifiable {
    let key: String?            // nil = general
    let title: String, symbol: String, intro: String
    let steps: [(symbol: String, title: String, body: String)]
    var id: String { key ?? "general" }
}

let allGuides: [Guide] = [
    Guide(key: nil, title: "Welcome to FreeOffice", symbol: "hand.wave.fill", intro: "Five apps, one window. Everything you make is saved automatically.", steps: [
        ("square.on.square", "Work in tabs", "Open as many documents as you like. Click + for a new tab, and switch between files, apps and this guide without leaving the window."),
        ("sidebar.left", "Use the sidebar", "Under Create, every app lists its templates. Click one to start from it, or choose “Blank” for an empty file."),
        ("sparkles.rectangle.stack", "Start from a template", "Cover letters, budgets, pitch decks, posters, databases — templates are real documents you can edit freely."),
        ("icloud.fill", "Save to your NAS", "Open FreeOffice Cloud in the sidebar to point FreeOffice at a network folder. Documents are then saved there."),
        ("magnifyingglass", "Find anything", "The search box on Home filters your recent files and the templates at the same time."),
        ("paintpalette.fill", "Pick a theme", "Switch between Colourful, Dark and Plain white from the buttons at the bottom of the sidebar, or the Theme menu. The choice is shared by all FreeOffice apps."),
        ("keyboard", "Shortcuts", "⌘N new document, ⇧⌘N spreadsheet, ⌥⌘N presentation, ⌃⌘N poster, ⇧⌥⌘N database, ⌘T new tab, ⌘W close tab."),
    ]),
    Guide(key: "writer", title: "Writer", symbol: "doc.text", intro: "A full word processor with styles, lists, tables, images and Word export.", steps: [
        ("at", "Link any document with @", "Type @ in Writer, a Sheets cell, a slide or poster text box, or a Data field or SQL query to pick another document from any app. Hover a mention for a live preview; click it to open."),
        ("textformat", "Fonts and styles", "The ribbon lists every installed font. The Style menu has Title, Subtitle, Headings 1–3, Body, Quote and Code. Select text first for character changes; paragraph changes apply to the whole paragraph."),
        ("keyboard", "Type Markdown", "At the start of a line type # then a space for a heading (## and ### for smaller ones), - or * for bullets, 1. for a numbered list, or > for a quote. It converts as you type."),
        ("list.number", "Lists that behave", "Bulleted and numbered lists continue when you press Return, and an empty item ends the list. Indent with ⌘] and outdent with ⌘[ to nest. Numbers renumber automatically."),
        ("paintbrush", "Colour, highlight, spacing", "Text colour, highlight, superscript and subscript are in the ribbon. The spacing button sets line spacing and the gap after paragraphs. ⌘B, ⌘I, ⌘U and ⌘K (link) work everywhere."),
        ("plus.square", "Insert", "Insert links, images, tables (2×2 up to 5×4), divider lines, today's date and special symbols. Images stay in the document."),
        ("list.bullet.indent", "Outline, zoom and margins", "View → Show outline lists your headings; click one to jump to it. You can also zoom, change the margins and show a ruler."),
        ("square.and.arrow.up", "Open and export anything", "File → Import opens Word, RTF, HTML, Markdown and text. Export as Word (.docx), PDF, RTF, web page, Markdown or plain text. ⌘F finds and replaces."),
    ]),
    Guide(key: "sheets", title: "Sheets", symbol: "tablecells", intro: "A full spreadsheet: sheets, formulas, formats and charts.", steps: [
        ("at", "Link any document with @", "Type @ in Writer, a Sheets cell, a slide or poster text box, or a Data field or SQL query to pick another document from any app. Hover a mention for a live preview; click it to open."),
        ("character.cursor.ibeam", "Type to edit", "Select a cell and start typing. Enter or double-click edits, Tab and Enter move, arrows move, Shift+arrows or dragging select a range, and clicking a row or column header selects the whole line."),
        ("function", "Formulas", "Start with =. Over 100 functions: SUM, AVERAGE, IF, IFERROR, VLOOKUP, INDEX/MATCH, SUMIF, COUNTIF, TEXT, DATE, LEFT/MID, ROUND and more. Use $A$1 for absolute references and Sheet2!A1 to reach other sheets."),
        ("doc.on.doc", "Copy, paste and fill", "⌘C ⌘X ⌘V keep formulas and formatting, and shift references like Excel. ⌘D fills down and ⌘R fills right. Pasting from other apps works too."),
        ("paintbucket", "Make it look right", "The ribbon sets bold, italic, text and fill colour, alignment and number formats (currency, percent, date…). Drag a column border to resize it."),
        ("arrow.up.arrow.down", "Sort, insert, delete", "Sort A→Z or Z→A by the selected column. Cells → insert or delete rows and columns, and formulas are repaired automatically."),
        ("chart.bar.xaxis", "Charts", "Select a table and choose Chart: column, line, area or pie. The first row becomes series names and the first column the categories."),
        ("square.stack.3d.up", "Multiple sheets", "Use the tabs at the bottom: + adds a sheet, double-click renames, right-click duplicates or deletes."),
        ("square.and.arrow.up", "Excel and CSV", "File → Import or Export .xlsx for Excel, Numbers and Google Sheets, or CSV for the current sheet. ⌘F finds and replaces."),
    ]),
    Guide(key: "slides", title: "Slides", symbol: "rectangle.on.rectangle", intro: "Design and present slide decks with themes, layouts and speaker notes.", steps: [
        ("at", "Link any document with @", "Type @ in Writer, a Sheets cell, a slide or poster text box, or a Data field or SQL query to pick another document from any app. Hover a mention for a live preview; click it to open."),
        ("rectangle.on.rectangle", "Start from a layout", "New slide offers Title, Title & bullets, Section, Two columns, Text & image, Big statement, Quote and Blank. Everything on a slide is free-form: click to select, drag to move, drag the corner to resize."),
        ("character.cursor.ibeam", "Type on the slide", "Double-click any text to type on the slide itself (Esc to finish). The panel on the right sets font, size, colour, alignment and bullets for the selected item."),
        ("paintpalette", "Change the whole deck's look", "Pick a theme (Light, Midnight, Bold blue, Sunset, Forest, Paper, Mono, Neon) and every slide restyles. Items that use theme colours and fonts follow along; set a colour yourself to override it."),
        ("photo", "Add shapes and images", "Insert text boxes, shapes, lines and pictures from the ribbon. Bring to front and send to back are in the panel, and Align to page centres an item."),
        ("note.text", "Speaker notes", "Write notes under each slide. Press N while presenting to see your notes, the next slide and a timer."),
        ("play.fill", "Present", "Present runs full screen. Arrow keys, space or a click move on; B blanks the screen to black, W to white, Esc exits. Choose a transition (Fade, Slide, Push, Zoom) for the deck or per slide."),
        ("square.and.arrow.up", "Share it", "Export a PDF, a PowerPoint (.pptx) file, a standalone web slideshow, or PNG images of the slides. Footer text and slide numbers are set for the whole deck."),
    ]),
    Guide(key: "poster", title: "Poster", symbol: "paintpalette", intro: "Lay out posters, flyers and social cards.", steps: [
        ("textformat", "Add things", "Use Text, Box, Ellipse, Line and Image in the toolbar. New items land on the page ready to move."),
        ("hand.draw", "Move and resize", "Drag an item to move it; drag the round handle to resize. Arrow keys nudge (hold Shift for bigger steps)."),
        ("character.cursor.ibeam", "Edit text", "Select a text box and type in the panel on the right (double-click jumps there). The panel also sets font, size, colour and alignment."),
        ("square.3.layers.3d", "Arrange", "Bring to front, Send to back, Duplicate and Delete are at the bottom of the panel."),
        ("photo", "Export", "Export → PNG, PDF or HTML. Pick a page size from the Page menu first, and use Undo if you move something by mistake."),
    ]),
    Guide(key: "data", title: "Data", symbol: "cylinder.split.1x2", intro: "A real database: typed fields, views, linked tables and SQL.", steps: [
        ("at", "Link any document with @", "Type @ in Writer, a Sheets cell, a slide or poster text box, or a Data field or SQL query to pick another document from any app. Hover a mention for a live preview; click it to open."),
        ("tablecells", "Typed fields", "Click + in the header (or Fields ▸ New field) to add text, numbers, currency, dates, checkboxes, single choice, ratings, links and formulas. Right-click a header to edit, sort, group, hide or total it."),
        ("line.3.horizontal.decrease", "Filter, sort and group", "Use the Filter and Sort buttons for several rules at once, and Group to fold rows into sections. Search looks in every field. Each table remembers its own view."),
        ("rectangle.split.3x1", "Board and Cards", "Switch to Board to drag rows between the columns of a Single choice field, or Cards for a gallery. Click a row's arrow to open it as a full form."),
        ("arrow.triangle.branch", "Link tables", "A ‘Link to table’ field picks a row from another table, so a contact can point at its company. Formula fields compute from other fields, e.g. Quantity * Price."),
        ("terminal", "Ask questions with SQL", "Open SQL and try: SELECT Status, COUNT(*) AS n FROM Books GROUP BY Status. JOIN, HAVING, CASE, LIKE and more work. INSERT, UPDATE and DELETE ask first and can be undone."),
        ("chart.bar", "Insights", "The Insights tab charts any field as bars, a pie or a line, counting rows or adding up a number."),
        ("square.and.arrow.down", "Import and export", "File imports CSV, JSON or Excel into new tables and exports CSV, JSON, Excel or a SQL dump."),
    ]),
    Guide(key: "diagrams", title: "Diagrams", symbol: "point.3.connected.trianglepath.dotted", intro: "Flowcharts, org charts, mind maps and system sketches.", steps: [
        ("at", "Link any document with @", "Type @ in a shape's text to link a document from any app. Hover for a live preview; click to open."),
        ("square.on.circle", "Add shapes", "Click a shape in the palette, or double-click empty space. Double-click a shape to type in it."),
        ("arrow.triangle.branch", "Connect and grow", "Hover a shape to see dots on its sides. Drag from a dot onto another shape to connect them, or onto empty space to create a new connected shape. Connectors stay attached when you move things."),
        ("slider.horizontal.3", "Style connectors", "Click a connector to choose elbow, straight or curved, arrowheads, dashes, a label and which sides it uses. Drag an elbow line to move its bend."),
        ("text.badge.plus", "Text to diagram", "Press Text to diagram… and type A --> B lines for a flowchart, or an indented list for an org chart or mind map."),
        ("wand.and.stars", "Auto layout", "Layout arranges everything top-to-bottom, left-to-right or as a radial mind map. Loops that go back swing round the side."),
        ("square.and.arrow.up", "Export", "Export as PNG, PDF or SVG from the Export menu."),
    ]),
    Guide(key: "planner", title: "Planner", symbol: "calendar", intro: "A calendar, a task list and a timeline in one place.", steps: [
        ("at", "Link any document with @", "Type @ in an event or task's notes to link a document from any app. Hover for a preview."),
        ("calendar", "Calendar", "Month and Week views show events and tasks. Double-click a day (or an hour in Week view) to add an event, and drag events to reschedule them."),
        ("repeat", "Repeating events", "Open an event and choose Repeats — every day, week, month or year, with an optional end date."),
        ("checklist", "Quick-add tasks", "In Tasks, type like a sentence: “Call Sam tomorrow !high #work”. Dates, priority and tags are picked out for you. Switch to Board to drag tasks between To do, Doing and Done."),
        ("chart.bar.xaxis", "Timeline", "Give tasks a start and due date to see them as bars. Drag a bar to move it, drag its right edge to change the due date. Tasks that wait on others show connecting lines."),
        ("square.and.arrow.up", "Import and export", "File imports and exports standard .ics calendars, so it works with other calendar apps."),
    ]),
    Guide(key: "reader", title: "Reader", symbol: "doc.richtext", intro: "Read, mark up, fill in and sign PDFs.", steps: [
        ("doc", "Open a PDF", "Choose a PDF, drop one on the window, or right-click one in Finder and Open With FreeOffice Reader. Reader keeps its own copy, so your original is never changed."),
        ("highlighter", "Highlight and underline", "Select text, then press Highlight, Underline or Strike through. The arrow next to Highlight picks the colour."),
        ("note.text", "Notes, text and drawing", "Pick Note, Text or Draw, then click or drag on the page. Press Delete to remove a mark you've selected."),
        ("signature", "Sign", "Choose Sign ▸ Create signature…, draw it once, then click where it should go. It's saved for every page and every document."),
        ("list.bullet.indent", "Find your way around", "The sidebar shows thumbnails, the outline, and a list of every highlight and note. Copy them all as a list from the File menu."),
        ("square.on.square", "Pages", "Rotate, move, delete or insert pages, and add pages from another PDF. Export flattened to burn marks into the page."),
    ]),
    Guide(key: "math", title: "Math", symbol: "function", intro: "A notebook with a calculator, equations and graphs.", steps: [
        ("at", "Link any document with @", "Type @ in a note to link a document from any app. Hover for a live preview."),
        ("equal.square", "Calculations", "Each line is its own calculation, and answers appear as you type. Press Return for a new line. Later lines can use earlier ones."),
        ("function", "Variables and functions", "Write r = 5 or f(x) = x^2 + 1, then use them: f(r). Everything you define is listed in the Scope panel."),
        ("sum", "Calculus and solving", "Try integrate(sin(x), 0, pi), diff(x^3, 2), solve(x^2 = 2, 1) and sum(k^2, k, 1, 10)."),
        ("textformat.superscript", "Equations", "Add an Equation cell and write LaTeX such as \\frac{a}{b}, \\sqrt{x}, \\sum, \\int or \\begin{pmatrix}…\\end{pmatrix}. Insert has ready-made pieces. Copy the LaTeX or save a PNG."),
        ("chart.xyaxis.line", "Graphs", "Add a Graph cell and list functions of x, including ones you defined. Drag to pan, ⌘-scroll or pinch to zoom, hover to read values."),
    ]),
    Guide(key: "updates", title: "Updates", symbol: "arrow.down.circle.fill", intro: "Get new versions without reinstalling.", steps: [
        ("arrow.down.circle", "Update available", "When a newer version is published to your update source, a green “Update available” card appears in the sidebar and on Home."),
        ("bolt.fill", "One click", "Press Update now. FreeOffice downloads the new version, checks it, swaps the apps in place and reopens. Your documents are untouched."),
        ("link", "Set the update source", "Open Updates and enter a web address or a folder (a folder on your NAS works well). Turn on automatic checks, or press Check now."),
        ("shippingbox", "Publishing a version", "Run ./release.sh <folder> in the project to build a release and write the feed file that the apps read."),
    ]),
    Guide(key: "cloud", title: "FreeOffice Cloud", symbol: "icloud.fill", intro: "Keep your files on your NAS.", steps: [
        ("link", "Connect", "Open FreeOffice Cloud, type your share address (for example smb://nas.local/Documents) and press Connect."),
        ("folder", "Choose a folder", "Pick a mounted network volume, or browse to any folder on it."),
        ("switch.2", "Turn it on", "Switch on “Save documents to FreeOffice Cloud”. FreeOffice syncs once, newest copy wins."),
        ("wifi.slash", "Offline is fine", "If the NAS is asleep or you're away, FreeOffice saves locally and syncs when it comes back. Nothing is deleted by a sync."),
    ]),
]

struct LearnView: View {
    @State private var filter: String?
    init(initial: String?) { _filter = State(initialValue: initial) }

    var guides: [Guide] { allGuides.filter { filter == nil || $0.key == filter || ($0.key == nil && filter == "general") } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 42)).foregroundStyle(.orange)
                        .frame(width: 84, height: 84).glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learn FreeOffice").font(.fo(size: 44, weight: .heavy))
                        Text("Quick guides for every app.").font(.fo(.title3)).foregroundStyle(.secondary)
                    }
                }
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        chip("All", nil)
                        ForEach(allGuides) { g in chip(g.key == nil ? "Basics" : (appFor(g.key!)?.name ?? (g.key == "updates" ? "Updates" : "Cloud")), g.key ?? "general") }
                    }
                }
                ForEach(guides) { g in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            if let k = g.key, let a = appFor(k) { FMark(letter: a.letter, size: 38) } else { Image(systemName: g.symbol).font(.fo(.title)).frame(width: 38, height: 38) }
                            VStack(alignment: .leading, spacing: 1) { Text(g.title).font(.fo(.title2).weight(.bold)); Text(g.intro).foregroundStyle(.secondary) }
                        }
                        ForEach(Array(g.steps.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: s.symbol).font(.fo(.title3)).frame(width: 34, height: 34).glassEffect(.regular.tint((g.key.flatMap(appFor)?.tint ?? .indigo).opacity(0.3)), in: .circle)
                                VStack(alignment: .leading, spacing: 2) { Text("\(i + 1). \(s.title)").font(.fo(.headline)); Text(s.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 26))
                }
            }
            .padding(36).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }
    func chip(_ t: String, _ k: String?) -> some View {
        Button { filter = k } label: { Text(t).font(.fo(.callout).weight(.medium)).padding(.horizontal, 14).padding(.vertical, 7) }
            .buttonStyle(.plain).glassEffect(filter == k ? .regular.tint(.indigo.opacity(0.5)).interactive() : .regular.interactive(), in: .capsule)
    }
}
