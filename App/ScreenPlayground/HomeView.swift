import AppKit
import AVFoundation
import Capture
import PlaygroundCore
import SwiftUI

/// Start screen: record button, permissions checklist and recent projects.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var permissions: [Permission: Bool] = [:]
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 48, height: 48)
                    .accessibilityLabel("Screen Playground logo")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Playground").font(.system(size: 22, weight: .bold))
                    Text("Beautiful screen recordings in minutes. Free for everyone.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button { app.recorder.showPicker() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("New recording")
                        Text("⌥⌘↩").font(.system(size: 11)).opacity(0.7)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if permissions.values.contains(false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permissions").font(.system(size: 13, weight: .semibold))
                    ForEach(Permission.allCases) { p in
                        HStack {
                            Image(systemName: permissions[p] == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(permissions[p] == true ? .green : Theme.secondaryText)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title + (p.isRequired ? "" : " (optional)")).font(.system(size: 12, weight: .medium))
                                Text(p.purpose).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if permissions[p] != true {
                                Button("Allow") {
                                    Task {
                                        await PermissionCenter.request(p)
                                        if !PermissionCenter.isGranted(p) { NSWorkspace.shared.open(p.settingsURL) }
                                        refresh()
                                    }
                                }
                                .buttonStyle(SmallButtonStyle())
                            }
                        }
                    }
                    Text("After allowing Screen Recording, macOS may ask you to quit and reopen Screen Playground.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            }

            HStack {
                Text("Recent projects").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Import video…") { app.importVideoPanel() }.buttonStyle(SmallButtonStyle())
                Button("Open…") { app.openProjectPanel() }.buttonStyle(SmallButtonStyle())
                Button { NSWorkspace.shared.open(app.projectsFolder) } label: { Image(systemName: "folder") }.buttonStyle(SmallButtonStyle())
            }
            if app.recents.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "record.circle",
                                       description: Text("Press ⌥⌘↩ anywhere to start recording."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                        ForEach(app.recents, id: \.self) { url in ProjectCard(url: url) }
                    }
                }
            }
        }
        .padding(24)
        .padding(.top, 10)
        .frame(minWidth: 720, minHeight: 480)
        .background(Theme.background)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    func refresh() {
        var p: [Permission: Bool] = [:]
        for perm in Permission.allCases { p[perm] = PermissionCenter.isGranted(perm) }
        permissions = p
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    let url: URL
    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        Button { app.openProject(url) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.panel)
                    if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "film").font(.system(size: 24)).foregroundStyle(Theme.secondaryText) }
                }
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovering ? Theme.accentSoft : Theme.stroke, lineWidth: hovering ? 2 : 1))
                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Move to Trash", role: .destructive) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                app.reloadRecents()
            }
        }
        .task(id: url) { thumb = await Self.thumbnail(url) }
    }

    /// First-second frame of the raw recording.
    static func thumbnail(_ url: URL) async -> NSImage? {
        let bundle = ProjectBundle(url: url)
        guard let manifest = try? bundle.loadManifest(), let ch = manifest.channel(.display) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: bundle.channelURL(ch)))
        gen.maximumSize = CGSize(width: 480, height: 300)
        gen.appliesPreferredTrackTransform = true
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: min(1, manifest.duration / 2), preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
