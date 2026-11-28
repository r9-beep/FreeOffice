// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import CryptoKit

/// In-place updates: the app reads a small "appcast.json" feed (a web URL, or a folder — e.g. on your NAS),
/// and when a newer build exists it downloads the zip, verifies it, swaps the apps and relaunches.
struct Release: Codable, Equatable {
    let version: String
    let build: Int
    let notes: String?
    let url: String          // absolute URL/path, or relative to the feed
    let sha256: String?
}

final class Updater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available(Release), downloading, installing, failed(String) }
    @Published var state: State = .idle
    @Published var lastChecked: Date?
    @Published var installError: String?     // survives re-checks so the reason is never lost
    private let storage: Storage
    private var timer: Timer?

    static var currentVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }
    static var currentBuild: Int { Int((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0") ?? 0 }

    init(storage: Storage) {
        self.storage = storage
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.autoCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
    }

    var available: Release? { if case .available(let r) = state { return r }; return nil }
    var hasFeed: Bool { !(storage.updateFeed ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    private func autoCheck() { if storage.autoCheckUpdates && hasFeed { check() } }

    // MARK: locating the feed
    private func feedURL() -> URL? {
        let f = (storage.updateFeed ?? "").trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return nil }
        if f.hasPrefix("http://") || f.hasPrefix("https://") {
            guard var u = URL(string: f) else { return nil }
            if u.pathExtension.lowercased() != "json" { u = u.appendingPathComponent("appcast.json") }
            return u
        }
        var u = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { u = u.appendingPathComponent("appcast.json") }
        return u
    }
    private func fetch(_ u: URL) async throws -> Data {
        if u.isFileURL { return try Data(contentsOf: u) }
        var req = URLRequest(url: u); req.cachePolicy = .reloadIgnoringLocalCacheData; req.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw UpdateError("The update server answered \(h.statusCode).") }
        return d
    }
    private func resolve(_ r: Release, relativeTo feed: URL) -> URL? {
        if r.url.contains("://") { return URL(string: r.url) }
        if r.url.hasPrefix("/") { return URL(fileURLWithPath: r.url) }
        return feed.deletingLastPathComponent().appendingPathComponent(r.url)
    }

    // MARK: check
    func check() {
        if state == .downloading || state == .installing { return }       // never interrupt an install
        guard let feed = feedURL() else { state = .failed("No update source is set."); return }
        state = .checking
        Task { @MainActor in
            do {
                let r = try JSONDecoder().decode(Release.self, from: try await fetch(feed))
                lastChecked = Date()
                state = r.build > Self.currentBuild ? .available(r) : .upToDate
            } catch {
                state = .failed("Couldn't read the update feed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: install
    func install() {
        guard case .available(let r) = state, let feed = feedURL(), let src = resolve(r, relativeTo: feed) else { return }
        let appURL = Bundle.main.bundleURL, dest = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dest.path) else {
            installError = "FreeOffice can't write to \(dest.path). Move the apps to Applications (or another folder you own) and try again."; return
        }
        installError = nil
        state = .downloading
        Task { @MainActor in
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("FreeOfficeUpdate-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                if src.isFileURL { try fm.copyItem(at: src, to: zip) }
                else { let (tmp, resp) = try await URLSession.shared.download(from: src); if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw UpdateError("Download failed (\(h.statusCode)).") }; try fm.moveItem(at: tmp, to: zip) }

                if let want = r.sha256?.lowercased(), !want.isEmpty {
                    let got = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                    guard got == want else { throw UpdateError("The download didn't match its checksum, so it was not installed.") }
                }
                state = .installing
                let out = work.appendingPathComponent("new", isDirectory: true)
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
                let apps = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".app") }
                guard !apps.isEmpty else { throw UpdateError("The update didn't contain any apps.") }
                for a in apps {                                   // only ever install FreeOffice apps
                    let plist = out.appendingPathComponent(a).appendingPathComponent("Contents/Info.plist")
                    let id = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) ?? ""
                    guard id.hasPrefix("local.freeoffice.") else { throw UpdateError("The update contains something that isn't a FreeOffice app.") }
                }
                // Swap the bundles after this process exits, then relaunch.
                let script = work.appendingPathComponent("swap.sh")
                try """
                #!/bin/sh
                PID="$1"; NEW="$2"; DEST="$3"; SELF="$4"
                while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
                for app in "$NEW"/*.app; do
                  n=$(basename "$app")
                  if [ -d "$DEST/$n" ]; then
                    rm -rf "$DEST/$n.old"
                    if mv "$DEST/$n" "$DEST/$n.old" && ditto "$app" "$DEST/$n"; then rm -rf "$DEST/$n.old"
                    else rm -rf "$DEST/$n"; mv "$DEST/$n.old" "$DEST/$n"; fi
                    xattr -cr "$DEST/$n" 2>/dev/null
                  fi
                done
                open "$DEST/$SELF"
                rm -rf "$(dirname "$NEW")"
                """.write(to: script, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), out.path, dest.path, appURL.lastPathComponent]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run()
                NSApp.terminate(nil)
            } catch {
                installError = error.localizedDescription
                state = .available(r)                                // stay on "available" so it can be retried
            }
        }
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError("Couldn't unpack the update.") }
    }
}

struct UpdateError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
