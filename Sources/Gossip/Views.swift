import AppKit
import DroppyKit
import SwiftUI

// MARK: - Shared pieces

enum BatterySymbol {
    static func name(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct BatteryLabel: View {
    let battery: GossipDevice.Battery

    var body: some View {
        HStack(spacing: DroppySpacing.xs) {
            Image(systemName: BatterySymbol.name(level: battery.level, charging: battery.charging))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isLow ? Color.red : AdaptiveColors.notchSurfaceSecondaryText)
            Text("\(battery.level)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    private var isLow: Bool { battery.level <= LowBatteryLatch.threshold && !battery.charging }
}

struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.badge")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * DroppyRadius.appIconCornerRatio, style: .continuous))
    }
}

struct MediaArtwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AdaptiveColors.notchSurfaceCardFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct Message: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
    }
}

/// What every widget shows instead of its content when Gossip or the phone is missing.
struct ConnectionGate<Content: View>: View {
    @ObservedObject var droplet: GossipDroplet
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !droplet.isConnected {
            Message(text: "Gossip isn't running on this Mac")
        } else if droplet.phone == nil {
            HStack(spacing: DroppySpacing.sm) {
                Message(text: "No phone paired")
                Button("Pair a phone") { droplet.openInGossip("pair") }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        } else {
            content()
        }
    }
}

// MARK: - Phone widget

struct PhoneWidget: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            ConnectionGate(droplet: droplet) {
                if context.isCompact {
                    compactBody
                } else if let key = droplet.replyingTo,
                          let notification = droplet.notifications.first(where: { $0.key == key }) {
                    ReplyComposer(droplet: droplet, notification: notification)
                } else if droplet.notifications.isEmpty {
                    Message(text: "No notifications")
                } else {
                    NotificationList(droplet: droplet)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "iphone")
                .font(.system(size: 12, weight: .medium))
            Text(droplet.phone?.name ?? "Phone")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let phone = droplet.phone, !phone.online {
                Text("offline")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            Spacer(minLength: 0)
            if let battery = droplet.phone?.battery {
                BatteryLabel(battery: battery)
            }
            if !context.isCompact, droplet.phone != nil {
                Button { droplet.ringPhone() } label: {
                    Image(systemName: droplet.isRingingPhone ? "bell.slash.fill" : "bell.and.waves.left.and.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help(droplet.isRingingPhone ? "Stop ringing" : "Ring phone")
                .accessibilityLabel(droplet.isRingingPhone ? "Stop ringing" : "Ring phone")
                Button { droplet.openInGossip("mirror") } label: { Image(systemName: "rectangle.on.rectangle") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Mirror phone or open its apps")
                    .accessibilityLabel("Mirror phone")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .droppyFlatGlassControls()
    }

    /// The header already carries the battery, so the paired card spends its room on the newest notification.
    @ViewBuilder private var compactBody: some View {
        if let latest = droplet.notifications.first {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                HStack(spacing: DroppySpacing.xsm) {
                    AppIcon(image: droplet.icon(for: latest), size: 16)
                    Text(latest.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                }
                Text(latest.body)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(2)
                if droplet.notifications.count > 1 {
                    Text("+\(droplet.notifications.count - 1) more")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
        } else {
            Message(text: "No notifications")
        }
    }
}

/// Every notification, grouped by app, scrolling inside the widget. Times refresh once a minute.
private struct NotificationList: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    ForEach(droplet.notificationGroups) { group in
                        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                            HStack(spacing: DroppySpacing.xsm) {
                                AppIcon(image: droplet.icon(for: group.latest), size: 14)
                                Text(group.appName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                if group.notifications.count > 1 {
                                    Text("\(group.notifications.count)")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                                }
                            }
                            ForEach(group.notifications, id: \.key) { notification in
                                NotificationRow(droplet: droplet, notification: notification, now: timeline.date)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NotificationRow: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    let now: Date

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DroppySpacing.xs) {
                    Text(notification.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(RelativeTime.short(notification.date, now: now))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                Text(notification.body)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            .padding(.leading, 20)
            Spacer(minLength: 0)
            if notification.hasReply {
                Button { droplet.startReply(to: notification) } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Reply")
                    .accessibilityLabel("Reply to \(notification.headline)")
            }
            Button { droplet.dismiss(notification) } label: { Image(systemName: "xmark") }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Dismiss on phone")
                .accessibilityLabel("Dismiss \(notification.headline)")
        }
        .droppyFlatGlassControls()
    }
}

private struct ReplyComposer: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                AppIcon(image: droplet.icon(for: notification), size: 18)
                Text("\(notification.headline): \(notification.body)")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(3)
            }
            HStack(spacing: DroppySpacing.sm) {
                TextField("Reply", text: $droplet.replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .focused($focused)
                    .onSubmit { droplet.sendReply() }
                    .onExitCommand { droplet.cancelReply() }
                Button("Cancel") { droplet.cancelReply() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button("Send") { droplet.sendReply() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(droplet.replyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Media widget

struct MediaWidget: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        ConnectionGate(droplet: droplet) {
            if let media = droplet.currentMedia {
                HStack(spacing: DroppySpacing.md) {
                    MediaArtwork(image: droplet.artwork(for: media.deviceID), size: context.isCompact ? 36 : 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.playing.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Text(media.playing.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if !context.isCompact {
                        controls(isPlaying: media.playing.isPlaying)
                    }
                }
            } else {
                HStack(spacing: DroppySpacing.xsm) {
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Message(text: "Nothing playing on the phone")
                }
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func controls(isPlaying: Bool) -> some View {
        HStack(spacing: DroppySpacing.xs) {
            Button { droplet.media("previous") } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { droplet.media(isPlaying ? "pause" : "play") } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button { droplet.media("next") } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .droppyFlatGlassControls()
    }
}

// MARK: - Menu bar

struct PhoneMenu: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if let phone = droplet.phone {
                HStack(spacing: DroppySpacing.md) {
                    Text(phone.name).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: DroppySpacing.xl)
                    if let battery = phone.battery {
                        Text("\(battery.level)%\(battery.charging ? " ⚡︎" : "")")
                            .font(.system(size: 13))
                            .monospacedDigit()
                    }
                }
                Button(droplet.isRingingPhone ? "Stop ringing" : "Ring phone") { droplet.ringPhone() }
                Button("Mirror phone…") { droplet.openInGossip("mirror") }
                Button("Messages…") { droplet.openInGossip("messages") }
            } else {
                Text(droplet.isConnected ? "No phone paired" : "Gossip isn't running")
                    .font(.system(size: 13))
            }
            Button("Pair a phone…") { droplet.openInGossip("pair") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(AdaptiveColors.primaryTextAuto)
        .padding(.vertical, DroppySpacing.xs)
        .frame(minWidth: 200, alignment: .leading)
    }
}

// MARK: - Settings

struct GossipSettings: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Announce new notifications",
                    subtitle: "Shows each new phone notification in the notch.",
                    isOn: Binding(get: { droplet.announcesNotifications },
                                  set: { droplet.setPreference($0, forKey: "announce") })
                )
                DropletSliderRow(
                    title: "Announcement length",
                    value: "\(Int(droplet.hudDuration)) s",
                    binding: Binding(get: { droplet.hudDuration },
                                     set: { droplet.setPreference($0.rounded(), forKey: "hudDuration") }),
                    range: 3...15
                )
                DropletToggleRow(
                    title: "Low battery alert",
                    subtitle: "Shows a notch alert when the phone drops to \(LowBatteryLatch.threshold)% while not charging.",
                    isOn: Binding(get: { droplet.alertsLowBattery },
                                  set: { droplet.setPreference($0, forKey: "lowBattery") })
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Announce notifications from")
            } content: {
                DropletSettingsCard {
                    if droplet.knownApps.isEmpty {
                        DropletControlRow(title: "Apps appear here after their first notification") { EmptyView() }
                    }
                    ForEach(droplet.knownApps.sorted { $0.value < $1.value }, id: \.key) { package, name in
                        DropletToggleRow(
                            title: name,
                            subtitle: package,
                            isOn: Binding(get: { !droplet.isMuted(package) },
                                          set: { droplet.setMuted(package, !$0) })
                        )
                    }
                }
            }

            DropletSettingsCard {
                DropletControlRow(title: "Pair a new phone") {
                    Button("Pair…") { droplet.openInGossip("pair") }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }
}
