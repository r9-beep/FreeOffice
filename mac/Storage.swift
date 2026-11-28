// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Where documents live. Always a local folder; optionally a "FreeOffice Cloud" folder on a NAS / LAN share
/// (anything macOS can mount: SMB, NFS, AFP, WebDAV). Settings are shared by all FreeOffice apps.
final class Storage: ObservableObject {
    static weak var shared: Storage?
    /// Where new installs look for updates until you choose something else in Updates.
    static let defaultFeed = "https://github.com/r9-beep/FreeOffice/releases/latest/download/appcast.json"
    let localDir: URL
    private let configURL: URL

    @Published var cloudPath: String? { didSet { persist(); checkReachability() } }
    @Published var useCloud: Bool { didSet { persist(); checkReachability() } }
    @Published var updateFeed: String? { didSet { persist() } }
    @Published var autoCheckUpdates: Bool { didSet { persist() } }
    @Published var theme: AppTheme { didSet { persist() } }
    @Published var reachable = false
    @Published var busy = false
    @Published var lastSync: Date?
    @Published var message: String?
    private var timer: Timer?
    private var wasReachable = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FreeOffice", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        localDir = base
        configURL = base.appendingPathComponent(".config.json")
        let cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Any] ?? [:]
        cloudPath = cfg["cloudPath"] as? String
        useCloud = (cfg["useCloud"] as? Bool) ?? false
        updateFeed = (cfg["updateFeed"] as? String) ?? Storage.defaultFeed       // an empty string means "none, on purpose"
        autoCheckUpdates = (cfg["autoCheckUpdates"] as? Bool) ?? true
        theme = AppTheme(rawValue: (cfg["theme"] as? String) ?? "") ?? .colourful
        Storage.shared = self
        checkReachability()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkReachability() }
    }

    private func persist() {
        var o: [String: Any] = ["useCloud": useCloud, "autoCheckUpdates": autoCheckUpdates, "theme": theme.rawValue]
        if let p = cloudPath { o["cloudPath"] = p }
        o["updateFeed"] = updateFeed ?? ""
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: configURL, options: .atomic) }
    }

    var cloudDir: URL? { cloudPath.map { URL(fileURLWithPath: $0).appendingPathComponent("FreeOffice Files", isDirectory: true) } }
    /// Where reads and writes go right now: the cloud folder when it's enabled and reachable, otherwise local.
    var activeDir: URL { (useCloud && reachable ? cloudDir : nil) ?? localDir }
    var usingCloud: Bool { useCloud && reachable && cloudDir != nil }

    // MARK: status for the UI
    var statusTitle: String {
        guard cloudPath != nil else { return "Local only" }
        if !useCloud { return "Cloud off" }
        return reachable ? "Cloud connected" : "Cloud offline"
    }
    var statusDetail: String {
        guard let p = cloudPath else { return "Saving on this Mac" }
        if !useCloud { return "Saving on this Mac" }
        return reachable ? URL(fileURLWithPath: p).lastPathComponent : "Saving locally until it's back"
    }
    var statusSymbol: String { usingCloud ? "icloud.fill" : (useCloud ? "icloud.slash" : "internaldrive") }
    var statusColor: Color { usingCloud ? .green : (useCloud ? .orange : .secondary) }

    // MARK: reachability (off the main thread — a sleeping NAS can block file calls)
    func checkReachability() {
        guard let p = cloudPath else { reachable = false; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            var ok = fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: p)
            if ok {
                let d = URL(fileURLWithPath: p).appendingPathComponent("FreeOffice Files", isDirectory: true)
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                ok = fm.isWritableFile(atPath: d.path)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let back = ok && !self.wasReachable
                self.wasReachable = ok
                if self.reachable != ok { self.reachable = ok }
                if back && self.useCloud { self.syncNow() }       // came online: reconcile
            }
        }
    }

    // MARK: files
    func fileFor(_ key: String, in dir: URL? = nil) -> URL? {
        guard key.range(of: "^office:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return (dir ?? activeDir).appendingPathComponent(key.replacingOccurrences(of: ":", with: "__") + ".json")
    }
    func entries() -> [(key: String, json: String)] {
        let dir = activeDir
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("office__") && $0.pathExtension == "json" }
            .compactMap { f in
                guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
                return (f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "__", with: ":"), s)
            }
    }
    func loadStore() -> [String: String] { Dictionary(uniqueKeysWithValues: entries().map { ($0.key, $0.json) }) }
    func write(key: String, json: String?) {
        guard let f = fileFor(key) else { return }
        if let j = json { try? j.write(to: f, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: f) }
    }
    func delete(key: String) {
        for d in [localDir, cloudDir].compactMap({ $0 }) where d == localDir || reachable {
            if let f = fileFor(key, in: d) { try? FileManager.default.removeItem(at: f); try? FileManager.default.removeItem(at: f.deletingPathExtension().appendingPathExtension("pdf")) }
        }
    }

    // MARK: sync — newest file wins, nothing is ever deleted by a sync
    func syncNow() {
        guard let cloud = cloudDir, reachable else { message = "The cloud folder isn't reachable right now."; return }
        busy = true; message = nil
        let local = localDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            func names(_ d: URL) -> Set<String> { Set(((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix("office__") && ($0.hasSuffix(".json") || $0.hasSuffix(".pdf") || ($0.hasPrefix("office__media__") && ($0.hasSuffix(".jpg") || $0.hasSuffix(".png") || $0.hasSuffix(".credit")))) }) }
            func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
            func copy(_ a: URL, _ b: URL) -> Bool {
                guard let m = mtime(a) else { return false }
                try? fm.removeItem(at: b)
                guard (try? fm.copyItem(at: a, to: b)) != nil else { return false }
                try? fm.setAttributes([.modificationDate: m], ofItemAtPath: b.path); return true
            }
            var up = 0, down = 0
            for n in names(local).union(names(cloud)) {
                let l = local.appendingPathComponent(n), c = cloud.appendingPathComponent(n)
                switch (mtime(l), mtime(c)) {
                case (_?, nil): if copy(l, c) { up += 1 }
                case (nil, _?): if copy(c, l) { down += 1 }
                case (let a?, let b?):
                    if a.timeIntervalSince(b) > 1 { if copy(l, c) { up += 1 } } else if b.timeIntervalSince(a) > 1 { if copy(c, l) { down += 1 } }
                default: break
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false; self.lastSync = Date()
                self.message = up + down == 0 ? "Everything is up to date." : "Synced: \(up) sent to the cloud, \(down) brought down."
                self.objectWillChange.send()
            }
        }
    }

    /// Network volumes macOS currently has mounted (SMB / NFS / AFP / WebDAV shares).
    func networkVolumes() -> [(name: String, url: URL)] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeNameKey], options: [.skipHiddenVolumes]) ?? [])
            .compactMap { u in
                let v = try? u.resourceValues(forKeys: [.volumeIsLocalKey, .volumeNameKey])
                guard v?.volumeIsLocal == false else { return nil }
                return (v?.volumeName ?? u.lastPathComponent, u)
            }
    }
}
