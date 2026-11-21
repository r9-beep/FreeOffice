import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var storage: Storage
    @State private var feed = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 46)).foregroundStyle(LinearGradient(colors: [.mint, .green], startPoint: .top, endPoint: .bottom))
                        .frame(width: 84, height: 84).glassEffect(.regular, in: .rect(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updates").font(.fo(size: 44, weight: .heavy))
                        Text("FreeOffice \(Updater.currentVersion) · build \(Updater.currentBuild)").font(.fo(.title3)).foregroundStyle(.secondary)
                    }
                }

                statusCard

                if let r = updater.available, let n = r.notes, !n.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What's new in \(r.version)").font(.fo(.headline))
                        Text(n).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 22))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Update source").font(.fo(.title3).weight(.semibold))
                    Text("A web address (https://…) or a folder that contains an appcast.json file. A folder on your NAS works well.").foregroundStyle(.secondary)
                    HStack {
                        TextField("https://example.com/freeoffice  or  /Volumes/NAS/FreeOffice Updates", text: $feed).textFieldStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 8).glassEffect(.regular, in: .capsule).onSubmit(save)
                        Button("Save") { save() }.buttonStyle(.glassProminent)
                        Button("Choose folder…") { browse() }.buttonStyle(.glass)
                    }
                    HStack {
                        if let c = storage.cloudPath { Button { feed = c + "/FreeOffice Updates"; save() } label: { Label("Use my FreeOffice Cloud folder", systemImage: "icloud") }.buttonStyle(.glass) }
                        Toggle("Check automatically", isOn: $storage.autoCheckUpdates).toggleStyle(.switch)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Publishing a new version").font(.fo(.headline))
                    Text("In the FreeOffice project folder run  ./release.sh \"/path/to/update folder\"  — it builds all six apps, zips them, and writes appcast.json for the apps to read.")
                        .foregroundStyle(.secondary).font(.fo(.callout)).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 6)
            }
            .padding(36).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .onAppear { feed = storage.updateFeed ?? "" }
    }

    @ViewBuilder var statusCard: some View {
        HStack(spacing: 16) {
            switch updater.state {
            case .available(let r):
                Image(systemName: "arrow.down.circle.fill").font(.fo(.title)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(r.version) is available").font(.fo(.headline))
                    Text("Updates in place — no reinstall. FreeOffice will reopen.").font(.fo(.callout)).foregroundStyle(.secondary)
                    if let e = updater.installError { Label(e, systemImage: "exclamationmark.triangle.fill").font(.fo(.callout)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                Button { updater.install() } label: { Label("Update now", systemImage: "arrow.down.circle") }.buttonStyle(.glassProminent).tint(.green)
            case .checking:
                ProgressView().controlSize(.small); Text("Checking for updates…"); Spacer()
            case .downloading:
                ProgressView().controlSize(.small); Text("Downloading update…"); Spacer()
            case .installing:
                ProgressView().controlSize(.small); Text("Installing — FreeOffice will reopen in a moment…"); Spacer()
            case .upToDate:
                Image(systemName: "checkmark.seal.fill").font(.fo(.title)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) { Text("You're up to date").font(.fo(.headline)); if let d = updater.lastChecked { Text("Checked \(d, format: .dateTime.hour().minute())").font(.fo(.caption)).foregroundStyle(.secondary) } }
                Spacer(); checkButton
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.fo(.title)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) { Text("Couldn't update").font(.fo(.headline)); Text(msg).font(.fo(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(); checkButton
            case .idle:
                Image(systemName: "arrow.triangle.2.circlepath").font(.fo(.title)).foregroundStyle(.secondary)
                Text(updater.hasFeed ? "Not checked yet" : "Set an update source below to check for updates"); Spacer(); checkButton
            }
        }
        .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
    var checkButton: some View { Button { updater.check() } label: { Label("Check now", systemImage: "arrow.clockwise") }.buttonStyle(.glass).disabled(!updater.hasFeed) }

    func save() { storage.updateFeed = feed.trimmingCharacters(in: .whitespaces); if updater.hasFeed { updater.check() } }
    func browse() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Use Folder"
        p.message = "Choose the folder that contains appcast.json"
        if p.runModal() == .OK, let u = p.url { feed = u.path; save() }
    }
}
