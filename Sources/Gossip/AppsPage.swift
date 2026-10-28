import AppKit
import DroppyKit
import SwiftUI

/// Settings → Phone apps: every app on the phone with its icon, each switched on to announce in the notch. An app
/// switched off stays in the widget quietly; the droplet's page lists it, where it can be hidden altogether.
struct AppsPage: View {
    static let id = "apps"

    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                settingsSectionHeader("Announce in the notch")
            } content: {
                DropletSettingsCard {
                    if let error = droplet.phoneAppsError {
                        DropletControlRow(title: error) { EmptyView() }
                    } else if droplet.phoneApps == nil {
                        DropletControlRow(title: droplet.phone == nil ? "No phone paired" : "Loading the phone's apps…") {
                            if droplet.phone != nil { ProgressView().controlSize(.small) }
                        }
                    }
                    ForEach(shown, id: \.package) { app in
                        SettingsAppRow(icon: droplet.appIcons[app.package], name: app.name) {
                            if droplet.isHidden(app.package) {
                                Text("Hidden").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Toggle(app.name, isOn: announces(app.package))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.mini)
                        }
                    }
                }
            }
        }
        .onAppear { droplet.appsVisible(true) }
        .onDisappear { droplet.appsVisible(false) }
    }

    private var shown: [(package: String, name: String)] {
        let query = droplet.appQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return droplet.allApps }
        return droplet.allApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// On announces; off keeps the app quiet in the widget, and on again announces it even if it was hidden.
    private func announces(_ package: String) -> Binding<Bool> {
        Binding(
            get: { !droplet.isMuted(package) && !droplet.isHidden(package) },
            set: { on in
                droplet.setMuted(package, !on)
                if on { droplet.setHidden(package, false) }
            }
        )
    }

    struct Toolbar: View {
        @ObservedObject var droplet: GossipDroplet

        var body: some View {
            DropletSettingsToolbarSearchField(text: $droplet.appQuery, prompt: "Search apps")
        }
    }
}

/// An app in a settings card: its icon and name, then its controls.
struct SettingsAppRow<Accessory: View>: View {
    let icon: NSImage?
    let name: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: DroppySpacing.smd) {
            SettingsAppIcon(image: icon)
            Text(name).lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            accessory()
        }
    }
}

/// The phone's icon for an app, or a placeholder until it arrives.
struct SettingsAppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app").font(.system(size: 18)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22 * DroppyRadius.appIconCornerRatio, style: .continuous))
    }
}
