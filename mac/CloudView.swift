// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

/// FreeOffice Cloud: point FreeOffice at a NAS / LAN share and documents are saved there.
struct CloudView: View {
    @EnvironmentObject var storage: Storage
    @State private var address = ""
    @State private var volumes: [(name: String, url: URL)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    Image(systemName: "icloud.fill").font(.system(size: 46)).foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 84, height: 84).glassEffect(.regular, in: .rect(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FreeOffice Cloud").font(.fo(size: 44, weight: .heavy))
                        Text("Save your documents on your own NAS or any computer on your network.").font(.fo(.title3)).foregroundStyle(.secondary)
                    }
                }

                // Status
                HStack(spacing: 16) {
                    Image(systemName: storage.statusSymbol).font(.fo(.title)).foregroundStyle(storage.statusColor == .secondary ? Color.teal : storage.statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(storage.statusTitle).font(.fo(.headline))
                        Text(storage.usingCloud ? (storage.cloudDir?.path ?? "") : storage.activeDir.path).font(.fo(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let s = storage.lastSync { Text("Last sync \(s, format: .dateTime.hour().minute())").font(.fo(.caption)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if storage.busy { ProgressView().controlSize(.small) }
                    Button { storage.syncNow() } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.glass).disabled(!(storage.useCloud && storage.reachable) || storage.busy)
                }
                .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 22))
                if let msg = storage.message { Text(msg).font(.fo(.callout)).foregroundStyle(.secondary) }

                step(1, "Connect to your NAS", "Enter the address of a shared folder. macOS will mount it (you may be asked to sign in).") {
                    HStack {
                        TextField("smb://nas.local/Documents", text: $address).textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule).onSubmit(connect)
                        Button { connect() } label: { Label("Connect", systemImage: "link") }.buttonStyle(.glassProminent)
                    }
                    Text("Works with anything macOS can mount: SMB, NFS, AFP or WebDAV (e.g. smb://192.168.1.20/share).").font(.fo(.caption)).foregroundStyle(.secondary)
                }

                step(2, "Pick a folder", "Choose any folder on a connected share. FreeOffice keeps its files in a “FreeOffice Files” folder inside it.") {
                    if !volumes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connected network volumes").font(.fo(.subheadline).weight(.medium))
                            GlassEffectContainer(spacing: 8) {
                                ForEach(volumes, id: \.url) { v in
                                    HStack { Image(systemName: "externaldrive.connected.to.line.below"); Text(v.name); Spacer(); Button("Use this volume") { choose(v.url.path) }.buttonStyle(.glass) }
                                        .padding(.horizontal, 14).padding(.vertical, 8).glassEffect(.regular, in: .rect(cornerRadius: 16))
                                }
                            }
                        }
                    }
                    HStack {
                        Button { browse() } label: { Label("Choose folder…", systemImage: "folder.badge.plus") }.buttonStyle(.glass)
                        Button { refreshVolumes() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.glass)
                        if let p = storage.cloudPath { Text(p).font(.fo(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                }

                step(3, "Save to the cloud", "New and existing documents are kept in sync. Newest copy wins and nothing is deleted by a sync.") {
                    Toggle(isOn: $storage.useCloud) { Text("Save documents to FreeOffice Cloud").fontWeight(.medium) }
                        .toggleStyle(.switch).disabled(storage.cloudPath == nil)
                    if storage.useCloud && !storage.reachable && storage.cloudPath != nil {
                        Label("The folder can't be reached. FreeOffice is saving locally and will sync when it's back.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.fo(.callout))
                    }
                    if storage.cloudPath != nil {
                        Button(role: .destructive) { storage.useCloud = false; storage.cloudPath = nil } label: { Label("Disconnect", systemImage: "eject") }.buttonStyle(.glass)
                    }
                }
            }
            .padding(36).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .onAppear { refreshVolumes() }
    }

    func step<C: View>(_ n: Int, _ title: String, _ sub: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(n)").font(.fo(.title3).weight(.bold)).frame(width: 38, height: 38).glassEffect(.regular.tint(.blue.opacity(0.3)), in: .circle)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.fo(.title3).weight(.semibold))
                Text(sub).foregroundStyle(.secondary)
                content()
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    func connect() {
        var a = address.trimmingCharacters(in: .whitespaces)
        if !a.contains("://") { a = "smb://" + a }
        if let u = URL(string: a), !a.isEmpty { NSWorkspace.shared.open(u) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { refreshVolumes() }
    }
    func refreshVolumes() { volumes = storage.networkVolumes() }
    func choose(_ path: String) { storage.cloudPath = path; storage.useCloud = true }
    func browse() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: "/Volumes"); p.prompt = "Use Folder"; p.message = "Choose a folder on your NAS or network share"
        if p.runModal() == .OK, let u = p.url { choose(u.path) }
    }
}
