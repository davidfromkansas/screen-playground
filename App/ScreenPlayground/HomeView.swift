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
        HStack(spacing: 0) {
            HomeSidebar()
                .frame(width: 210)
                .padding(12)
            mainContent
        }
        .overlay(alignment: .bottomTrailing) { UpdateToast().padding(24) }
        .frame(minWidth: 860, minHeight: 540)
        .background(Theme.stage.ignoresSafeArea())
        .preferredColorScheme(.light)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    var mainContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 48, height: 48)
                    .accessibilityLabel("Screen Playground logo")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Playground").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Beautiful screen recordings in minutes. Free for everyone.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button { app.recorder.showPicker() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(.white).frame(width: 10, height: 10)
                        Text("New recording")
                        Text("⌥⌘↩").font(.system(size: 11)).opacity(0.8)
                    }
                    .padding(.horizontal, 4)
                }
                .recordGlassButton()
            }

            if permissions.values.contains(false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permissions").font(.system(size: 13, weight: .semibold))
                    ForEach(Permission.allCases) { p in
                        HStack {
                            Image(systemName: permissions[p] == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(permissions[p] == true ? Theme.success : Theme.secondaryText)
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
                .padding(16)
                .glass(cornerRadius: 20)
            }

            HStack {
                Text("Recent projects").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18)], spacing: 18) {
                        ForEach(Array(app.recents.enumerated()), id: \.element) { i, url in ProjectCard(url: url, index: i) }
                    }
                    .padding(6)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 20)
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
    var index = 0
    @State private var thumb: NSImage?
    @State private var hovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { app.openProject(url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Theme.control
                    if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "film").font(.system(size: 24)).foregroundStyle(Theme.secondaryText) }
                }
                .frame(height: 120)
                .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        Text(date, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(hovering ? Theme.accent : Color.black.opacity(0.04), lineWidth: hovering ? 2 : 1))
            .shadow(color: Color(red: 0.12, green: 0.12, blue: 0.24).opacity(hovering ? 0.14 : 0.07), radius: hovering ? 14 : 10, y: 6)
            .animation(Anim.hover, value: hovering)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        // Staggered entrance (50ms apart, first eight cards only) when Home opens.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            guard !appeared else { return }
            withAnimation(Anim.easeOut(0.3).delay(Double(min(index, 8)) * 0.05)) { appeared = true }
        }
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


/// Glass navigation sidebar on the Home window.
struct HomeSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 30) // traffic lights
            row("Recent", "clock", selected: true) {}
            row("All recordings", "play.rectangle") { NSWorkspace.shared.open(app.projectsFolder) }
            row("Presets", "sparkles") { NSWorkspace.shared.open(PresetStore.folder) }
            row("Exports", "square.and.arrow.up") { NSWorkspace.shared.open(app.exportsFolder) }
            Spacer()
            row("Settings", "gearshape") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .glass(cornerRadius: 24)
    }

    func row(_ title: String, _ icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accentSoft : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.13) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
