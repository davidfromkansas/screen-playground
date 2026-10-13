import SwiftUI

/// The quiet corner toast on Home: update ready, couldn't download, or "updated to X".
struct UpdateToast: View {
    @Bindable var updates = UpdateChecker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if updates.toastVisible, let content = content {
                content
                    .frame(width: 400)
                    .glass(cornerRadius: 22)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16)))
            }
        }
        .animation(Anim.easeOut(0.3), value: updates.toastVisible)
        .sheet(isPresented: $updates.whatsNewPresented) { WhatsNewSheet() }
    }

    var content: AnyView? {
        if let version = updates.justUpdatedTo {
            return AnyView(row(icon: "sparkles", tint: Theme.accentSoft, background: Theme.accent.opacity(0.13),
                               title: "Updated to \(version)", detail: nil) {
                Button("See what's new") { updates.whatsNewPresented = true }.buttonStyle(.link).font(.system(size: 12, weight: .medium))
            } trailing: {
                closeButton { updates.dismissJustUpdated() }
            })
        }
        switch updates.state {
        case let .ready(feed, _):
            if updates.isBusy {
                return AnyView(row(icon: "clock", tint: Theme.text, background: Theme.text.opacity(0.06),
                                   title: "\(feed.version) is ready", detail: "We'll ask again after you finish — nothing will interrupt it.") { EmptyView() } trailing: { EmptyView() })
            }
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                row(icon: "checkmark", tint: Color(red: 0.12, green: 0.48, blue: 0.22), background: Theme.success.opacity(0.16),
                    title: "Screen Playground \(feed.version) is ready",
                    detail: "Restart now to finish updating. Your projects and settings are kept.") { EmptyView() } trailing: { EmptyView() }
                    .padding(.bottom, -12)
                HStack(spacing: 6) {
                    Button("What's new") { updates.whatsNewPresented = true }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.8)).padding(.horizontal, 6)
                    Button("Later") { updates.later() }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.8)).padding(.horizontal, 6)
                    Spacer()
                    Button("Restart Now") { updates.restartNow() }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.leading, 48)
                .padding([.horizontal, .bottom], 16)
            })
        case let .failed(feed, _):
            guard let feed else { return nil }
            return AnyView(row(icon: "arrow.down.circle", tint: Theme.accentSoft, background: Theme.accent.opacity(0.13),
                               title: "Screen Playground \(feed.version) is available",
                               detail: "It couldn't be installed automatically — download it from the website.") {
                Button("Download") { updates.openDownloadInstead(feed) }.buttonStyle(.link).font(.system(size: 12, weight: .semibold))
            } trailing: {
                closeButton { updates.later() }
            })
        default:
            return nil
        }
    }

    func row<Extra: View, Trailing: View>(icon: String, tint: Color, background: Color, title: String, detail: String?,
                                          @ViewBuilder extra: () -> Extra, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true) }
                extra()
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(16)
    }

    func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }
}

/// "What's new" with the release notes, plus Skip / Later / Restart Now.
struct WhatsNewSheet: View {
    @Bindable var updates = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var feed: UpdateFeed? {
        switch updates.state {
        case let .ready(f, _), let .downloading(f, _): return f
        case let .failed(f, _): return f
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in \(feed?.version ?? updates.justUpdatedTo ?? updates.currentVersion)").font(.system(size: 20, weight: .bold))
                    Text(subtitle).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((feed?.notes ?? []).enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentSoft).padding(.top, 2)
                        Text(note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Link("Full release notes on GitHub", destination: feed?.notesURL
                     ?? URL(string: "https://github.com/davidfromkansas/screen-playground/releases")!)
                    .font(.system(size: 12))
            }
            if case let .downloading(_, p) = updates.state {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading…").font(.system(size: 12, weight: .semibold))
                    ProgressView(value: p).tint(Theme.accent)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.text.opacity(0.045)))
            }
            if case .ready = updates.state {
                Label("Checked: signed by the Screen Playground developer and notarized by Apple. Your projects aren't touched.",
                      systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            HStack {
                if let feed, feed.version != updates.currentVersion {
                    Button("Skip This Version") { updates.skip(feed); dismiss() }.buttonStyle(SmallButtonStyle())
                }
                Spacer()
                Button(updates.readyFeed == nil ? "Close" : "Later") { updates.later(); dismiss() }.buttonStyle(SmallButtonStyle())
                if updates.readyFeed != nil {
                    Button("Restart Now") { dismiss(); updates.restartNow() }.primaryGlassButton().disabled(updates.isBusy)
                }
            }
        }
        .padding(26)
        .frame(width: 500)
    }

    var subtitle: String {
        var parts: [String] = []
        if let released = feed?.released { parts.append("Released \(released)") }
        if let size = feed?.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        parts.append("you have \(updates.currentVersion)")
        return parts.joined(separator: " · ")
    }
}
