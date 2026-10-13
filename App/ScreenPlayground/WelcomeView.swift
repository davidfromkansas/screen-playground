import AppKit
import SwiftUI

/// First launch: explains that everything stays on this Mac and lets people pick the storage folder.
struct WelcomeView: View {
    var onContinue: (StorageLocation) -> Void

    @State private var root = StorageLocation.defaultRoot(home: StorageLocation.home)
    private var home: URL { StorageLocation.home }
    private var isDefault: Bool { root.standardizedFileURL.path == StorageLocation.defaultRoot(home: home).standardizedFileURL.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)
                Text("Welcome to Screen Playground")
                    .font(.system(size: 26, weight: .bold))
                Text("Free, with no account. Your recordings stay on this Mac — pick where they live.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                Text("Save everything in").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.8))
                locationRow
                if !isDefault {
                    Button("Use the default (~/ScreenPlayground) instead") { root = StorageLocation.defaultRoot(home: home) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.leading, 4)
                }
                VStack(alignment: .leading, spacing: 7) {
                    folderLine("Projects", "recordings and your edits")
                    folderLine("Exports", "finished MP4s and GIFs")
                    folderLine("Presets", "your saved looks")
                }
                .padding(.leading, 18)
                .padding(.top, 4)
            }

            if let service = StorageLocation.cloudService(for: root) {
                note(icon: "exclamationmark.triangle", tint: Color(red: 0.42, green: 0.23, blue: 0),
                     background: Color.orange.opacity(0.12),
                     text: Text("This folder syncs to \(service). ").bold()
                        + Text("Recordings are large, so they'll use \(service) storage and upload in the background. Recording still happens locally first."))
            } else {
                note(icon: "info.circle", tint: Theme.text.opacity(0.75), background: Theme.text.opacity(0.045),
                     text: Text("A minute of recording takes roughly 100–250 MB. You can move everything later in Settings › Storage."))
            }

            HStack {
                Text(isDefault ? "No account, no tracking, nothing uploaded." : "You can change this anytime in Settings › Storage.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Continue") { onContinue(StorageLocation(root: root, layout: .standard)) }
                    .primaryGlassButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 30)
        .frame(width: 600)
        .glass(cornerRadius: 28)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.stage.ignoresSafeArea())
    }

    var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accentSoft)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(isDefault ? "ScreenPlayground" : root.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                    if isDefault {
                        Text("Default").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.text.opacity(0.07)))
                    }
                }
                Text(subtitle).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Change…") { pick() }.buttonStyle(SmallButtonStyle())
        }
        .padding(.vertical, 14)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDefault ? Color.black.opacity(0.06) : Theme.accent, lineWidth: isDefault ? 1 : 2)
        )
    }

    var subtitle: String {
        var parts = [StorageLocation.displayPath(root, home: home)]
        if let service = StorageLocation.cloudService(for: root) { parts.append(service) }
        if let free = StorageLocation.freeSpace(at: root) {
            parts.append(ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free")
        }
        return parts.joined(separator: " · ")
    }

    func folderLine(_ name: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            Text(name).font(.system(size: 12, weight: .semibold))
            Text("— \(detail)").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
    }

    func note(icon: String, tint: Color, background: Color, text: Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            text.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background))
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Screen Playground keeps your recordings. A ScreenPlayground folder is created inside it."
        panel.directoryURL = home
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = StorageLocation.root(inside: url)
    }
}
