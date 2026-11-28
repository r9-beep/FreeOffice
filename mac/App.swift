// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func application(_ app: NSApplication, open urls: [URL]) { if Model.shared == nil { Model.pendingURLs += urls } else { urls.forEach { DocLinks.open(url: $0) } } }
}

@main
struct FreeOfficeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup(model.appName) {
            RootView().environmentObject(model).environmentObject(model.storage).environmentObject(model.updater)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) { Button("Check for Updates…") { model.openUpdates(); model.updater.check() } }
            CommandMenu("Format") {
                Button("Bold") { model.current?.onFormat?("bold") }.keyboardShortcut("b", modifiers: .command)
                Button("Italic") { model.current?.onFormat?("italic") }.keyboardShortcut("i", modifiers: .command)
                Button("Underline") { model.current?.onFormat?("underline") }.keyboardShortcut("u", modifiers: .command)
                Button("Strikethrough") { model.current?.onFormat?("strike") }.keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Add Link…") { model.current?.onFormat?("link") }.keyboardShortcut("k", modifiers: .command)
                Button("Bulleted List") { model.current?.onFormat?("bullets") }.keyboardShortcut("8", modifiers: [.command, .shift])
                Button("Numbered List") { model.current?.onFormat?("numbers") }.keyboardShortcut("7", modifiers: [.command, .shift])
                Button("Increase Indent") { model.current?.onFormat?("indent") }.keyboardShortcut("]", modifiers: .command)
                Button("Decrease Indent") { model.current?.onFormat?("outdent") }.keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Heading 1") { model.current?.onFormat?("h1") }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Heading 2") { model.current?.onFormat?("h2") }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Heading 3") { model.current?.onFormat?("h3") }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Body Text") { model.current?.onFormat?("body") }.keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandMenu("Theme") {
                Picker("Theme", selection: Binding(get: { model.storage.theme }, set: { model.storage.theme = $0 })) {
                    ForEach(AppTheme.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.inline)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { if let f = model.current?.onUndo { f() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { if let f = model.current?.onRedo { f() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.open(allApps[0]) }.keyboardShortcut("n", modifiers: .command)
                Button("New Spreadsheet") { model.open(allApps[1]) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Presentation") { model.open(allApps[2]) }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Poster") { model.open(allApps[3]) }.keyboardShortcut("n", modifiers: [.command, .control])
                Button("New Database") { model.open(allApps[4]) }.keyboardShortcut("n", modifiers: [.command, .shift, .option])
                Divider()
                Button("New Tab") { model.newTab() }.keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { model.closeCurrent() }.keyboardShortcut("w", modifiers: .command)
                Button("Next Tab") { model.step(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Home") { model.goHome() }.keyboardShortcut("0", modifiers: .command)
                Button("FreeOffice Cloud") { model.openCloud() }
                Button("Learn") { model.openLearn(nil) }
                Button("Show Files in Finder") { model.revealStore() }
            }
        }
    }
}
