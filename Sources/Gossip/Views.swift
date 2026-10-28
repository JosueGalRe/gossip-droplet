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
    /// A person's photo is a circle; an app icon keeps its squircle.
    var round = false

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
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : size * DroppyRadius.appIconCornerRatio, style: .continuous))
    }
}

/// The sender's photo with the app's icon as a badge, or just the app's icon when there is no photo.
struct SenderAvatar: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    let size: CGFloat

    var body: some View {
        if let avatar = droplet.avatar(for: notification) {
            AppIcon(image: avatar, size: size, round: true)
                .overlay(alignment: .bottomTrailing) {
                    AppIcon(image: droplet.icon(for: notification), size: size * 0.45)
                        .offset(x: 2, y: 2)
                }
        } else {
            AppIcon(image: droplet.icon(for: notification), size: size)
        }
    }
}

/// The ways to act on a notification in one row: copy its code, a suggested reply, then the app's own buttons.
struct QuickActions: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    var limit = 4

    var body: some View {
        HStack(spacing: DroppySpacing.xs) {
            if let code = notification.otpCode {
                Button { droplet.copyCode(code) } label: { Label("Copy \(code)", systemImage: "doc.on.doc") }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
            ForEach((notification.smartReplies ?? []).prefix(limit), id: \.self) { reply in
                Button(reply) { droplet.quickReply(reply, to: notification) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    .help("Send “\(reply)”")
            }
            ForEach((notification.actions ?? []).prefix(2), id: \.self) { action in
                Button(action.title) { droplet.perform(action, on: notification) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    static func hasAny(_ notification: PhoneNotification) -> Bool {
        notification.otpCode != nil || !(notification.smartReplies ?? []).isEmpty || !(notification.actions ?? []).isEmpty
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

/// The one widget: phone and battery in the header with its page switch, and the page below.
struct PhoneWidget: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            ConnectionGate(droplet: droplet) {
                switch droplet.page {
                case .home: HomePage(droplet: droplet, context: context)
                case .notifications: NotificationsPage(droplet: droplet, context: context)
                case .messages: MessagesPage(droplet: droplet, context: context)
                }
            }
            // The page gets exactly what is under the header: a page a few points too tall loses its bottom edge
            // instead of pushing the header up.
            .frame(height: max(0, droplet.contentHeight - context.contentInsets.top - context.contentInsets.bottom - 32),
                   alignment: .top)
            .clipped()
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Files dropped on the widget go to the phone.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { droplet.receiveDrop($0) }
        .overlay {
            if dropTargeted, let phone = droplet.phone {
                VStack(spacing: DroppySpacing.xs) {
                    Image(systemName: "arrow.up.doc").font(.system(size: 22, weight: .medium))
                    Text("Send to \(phone.name)").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .padding(context.contentInsets)
                .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if context.isCompact {
                // Narrow: the battery is the phone's status, in the title's place, and the switch takes the rest.
                if let battery = droplet.phone?.battery {
                    BatteryRing(level: battery.level, charging: battery.charging, size: 14, lineWidth: 2.5)
                    Text("\(battery.level)%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                } else {
                    Image(systemName: "iphone").font(.system(size: 12, weight: .medium))
                }
            } else {
                Image(systemName: "iphone")
                    .font(.system(size: 12, weight: .medium))
                Text(droplet.phone?.name ?? "Phone")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let phone = droplet.phone {
                    ConnectionLabel(phone: phone)
                }
            }
            Spacer(minLength: 0)
            if !context.isCompact, droplet.phone != nil {
                Button { droplet.ringPhone() } label: {
                    Image(systemName: droplet.isRingingPhone ? "bell.slash.fill" : "bell.and.waves.left.and.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help(droplet.isRingingPhone ? "Stop ringing" : "Ring phone")
                .accessibilityLabel(droplet.isRingingPhone ? "Stop ringing" : "Ring phone")
                if let hotspot = droplet.phone?.hotspot {
                    let on = droplet.hotspotRequested ?? hotspot.enabled
                    Button { droplet.toggleHotspot() } label: {
                        Image(systemName: "personalhotspot").foregroundStyle(on ? Color.blue : AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .opacity(droplet.hotspotRequested == nil ? 1 : 0.5)
                    .disabled(droplet.hotspotRequested != nil)
                    .help(on ? "Hotspot on\(hotspot.ssid.map { " (\($0))" } ?? ""): click to turn off" : "Turn on the hotspot and join it")
                    .accessibilityLabel(on ? "Turn off hotspot" : "Turn on hotspot")
                }
                if let dnd = droplet.phone?.dnd {
                    Button { droplet.setPhoneDND(!dnd) } label: {
                        Image(systemName: dnd ? "moon.fill" : "moon").foregroundStyle(dnd ? Color.indigo : AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help(dnd ? "Do Not Disturb is on: click to turn off" : "Turn on Do Not Disturb")
                    .accessibilityLabel(dnd ? "Turn off Do Not Disturb" : "Turn on Do Not Disturb")
                }
                AppsMenu(droplet: droplet)
            }
            if droplet.isConnected, droplet.phone != nil {
                PageSwitch(droplet: droplet)
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .droppyFlatGlassControls()
        .frame(height: 24)
    }
}

/// How the phone is reached: a green dot on the local network, blue through the relay, grey when it is not.
private struct ConnectionLabel: View {
    let phone: GossipDevice

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        !phone.online ? AdaptiveColors.notchSurfaceTertiaryText : phone.relayed == true ? .blue : .green
    }

    private var text: String {
        !phone.online ? "Offline" : phone.relayed == true ? "Relay" : "Local"
    }
}

/// Three small discs in one track, as in OpenChamber's widget: the page showing is green.
private struct PageSwitch: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        HStack(spacing: 2) {
            segment(.home, symbol: "house", label: "Phone")
            segment(.notifications, symbol: "bell", label: "Notifications")
            segment(.messages, symbol: "message", label: "Messages")
        }
        .padding(2)
        .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule())
    }

    private func segment(_ page: GossipDroplet.Page, symbol: String, label: String) -> some View {
        let selected = droplet.page == page
        return Button { droplet.select(page) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(DroppyCircleButtonStyle(
            size: 20,
            destructive: false,
            solidFill: selected ? Color.green.opacity(0.24) : Color.clear,
            foregroundColorOverride: selected ? .green : AdaptiveColors.notchSurfaceTertiaryText
        ))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Notifications page

private struct NotificationsPage: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        if context.isCompact {
            compactBody
        } else if let focused = droplet.focusedNotification {
            FocusedNotification(droplet: droplet, notification: focused)
        } else if droplet.visibleNotifications.isEmpty {
            Message(text: droplet.showsNotifications ? "No notifications" : "Phone notifications are off")
        } else {
            NotificationList(droplet: droplet)
        }
    }

    /// Narrow: the newest three, each a button to the full widget with that one open, and the way to the rest.
    @ViewBuilder private var compactBody: some View {
        let list = droplet.visibleNotifications
        if list.isEmpty {
            Message(text: "No notifications")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(list.prefix(3), id: \.key) { notification in
                    Button { droplet.open(notification) } label: {
                        CompactNotificationRow(droplet: droplet, notification: notification)
                    }
                    .buttonStyle(.plain)
                }
                if list.count > 3 {
                    SeeAllButton(count: list.count) { droplet.reveal(.notifications) }
                        .padding(.horizontal, DroppySpacing.xs)
                        .padding(.top, 2)
                }
            }
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
                    ForEach(droplet.liveNotifications, id: \.key) { notification in
                        LiveRow(droplet: droplet, notification: notification)
                    }
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

/// One notification in the history: a click opens it on its own; reply and dismiss show under the pointer.
private struct NotificationRow: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            Group {
                if let avatar = droplet.avatar(for: notification) {
                    AppIcon(image: avatar, size: 22, round: true)
                } else {
                    Color.clear
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(notification.headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(notification.body)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            // The time and the thumbnail at rest; the row's buttons under the pointer.
            if hovering {
                HStack(spacing: DroppySpacing.xs) {
                    if notification.hasReply {
                        Button { droplet.startReply(to: notification) } label: { Image(systemName: "arrowshape.turn.up.left") }
                            .help("Reply")
                            .accessibilityLabel("Reply to \(notification.headline)")
                    }
                    Button { droplet.dismiss(notification) } label: { Image(systemName: "xmark") }
                        .help("Dismiss on phone")
                        .accessibilityLabel("Dismiss \(notification.headline)")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
            } else {
                if let picture = droplet.picture(for: notification) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(RelativeTime.short(notification.date, now: now))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .frame(minWidth: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, DroppySpacing.xs)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { droplet.open(notification) }
        .background(hovering ? AdaptiveColors.notchSurfaceCardFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
        .onHover { hovering = $0 }
        .droppyFlatGlassControls()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open") { droplet.open(notification) }
        .accessibilityAction(named: "Dismiss on phone") { droplet.dismiss(notification) }
    }
}

/// A notification in progress: a call, a timer, a delivery or a download, with its progress or time and its buttons.
struct LiveRow: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(spacing: DroppySpacing.sm) {
                SenderAvatar(droplet: droplet, notification: notification, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(notification.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                LiveTime(live: notification.live)
            }
            if let live = notification.live, live.fraction != nil || live.indeterminate == true {
                LiveProgress(live: live).padding(.leading, 30)
            }
            if !(notification.actions ?? []).isEmpty {
                QuickActions(droplet: droplet, notification: notification).padding(.leading, 30)
            }
        }
        .padding(DroppySpacing.sm)
        .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
        .droppyFlatGlassControls()
    }
}

/// A chronometer counting from (or down to) its base, or nothing.
struct LiveTime: View {
    let live: LiveInfo?

    var body: some View {
        if let base = live?.chronometerDate {
            Group {
                if live?.countDown == true, base > Date() {
                    Text(timerInterval: Date()...base, countsDown: true)
                } else {
                    Text(base, style: .timer)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .frame(minWidth: 40, alignment: .trailing)
        }
    }
}

struct LiveProgress: View {
    let live: LiveInfo

    var body: some View {
        Group {
            if let fraction = live.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(.green)
        .controlSize(.small)
    }
}

// MARK: - Media

/// The playback position, advancing on its own while it plays; click or drag to seek.
struct SeekBar: View {
    @ObservedObject var droplet: GossipDroplet
    let durationMs: Int
    let interactive: Bool
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let position = droplet.mediaPosition(at: timeline.date)
            let fraction = dragFraction ?? Double(position) / Double(max(1, durationMs))
            HStack(spacing: DroppySpacing.sm) {
                Text(Self.format(dragFraction.map { Int($0 * Double(durationMs)) } ?? position))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AdaptiveColors.notchSurfaceCardFill)
                        Capsule().fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.85))
                            .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(interactive ? DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(1, max(0, $0.location.x / proxy.size.width)) }
                        .onEnded { value in
                            droplet.seek(toFraction: value.location.x / proxy.size.width)
                            dragFraction = nil
                        } : nil)
                }
                .frame(height: 12)
                Text(Self.format(durationMs))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
    }

    static func format(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
                Button("Send files…") { droplet.pickFilesToSend() }
                if let hotspot = phone.hotspot {
                    Button(hotspot.enabled ? "Turn off hotspot" : "Turn on hotspot") { droplet.toggleHotspot() }
                        .disabled(droplet.hotspotRequested != nil)
                }
                if let dnd = phone.dnd {
                    Button(dnd ? "Turn off Do Not Disturb" : "Turn on Do Not Disturb") { droplet.setPhoneDND(!dnd) }
                }
                Button("Messages") { droplet.reveal(.messages) }
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

/// The phone's screen or one of its apps on the Mac: the whole screen, the apps that notified last, then every app.
private struct AppsMenu: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        Menu {
            Button("Mirror the screen…") { droplet.openInGossip("mirror") }
            Button("Send files…") { droplet.pickFilesToSend() }
            let recent = droplet.recentApps
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { item($0) }
                }
            }
            if let apps = droplet.phoneApps, !apps.isEmpty {
                Menu("All apps") {
                    ForEach(apps.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) { item($0) }
                }
            }
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(AdaptiveColors.notchSurfaceCardFill, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mirror the phone or open one of its apps on the Mac")
        .accessibilityLabel("Phone screen and apps")
    }

    private func item(_ app: PhoneApp) -> some View {
        Button { droplet.openOnMac(app.package) } label: {
            if let icon = droplet.menuIcon(app.package) {
                Label { Text(app.label) } icon: { Image(nsImage: icon) }
            } else {
                Text(app.label)
            }
        }
    }
}

// MARK: - Settings

struct GossipSettings: View {
    @ObservedObject var droplet: GossipDroplet

    enum AppMode: String, CaseIterable, Hashable {
        case announce = "Announce", show = "Show only", hide = "Hidden"
    }

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Phone notifications",
                    subtitle: "Shows the phone's notifications in the widget and the notch.",
                    isOn: Binding(get: { droplet.showsNotifications }, set: { droplet.setPreference($0, forKey: "show") })
                )
                DropletToggleRow(
                    title: "Announce new notifications",
                    subtitle: "Shows each new notification in the notch, with its photo, suggested replies and buttons.",
                    isOn: Binding(get: { droplet.announcesNotifications },
                                  set: { droplet.setPreference($0, forKey: "announce") })
                )
                DropletControlRow(title: pauseTitle) {
                    if droplet.announcementsPausedUntil != nil {
                        Button("Resume") { droplet.pauseAnnouncements(for: nil) }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    } else {
                        HStack(spacing: DroppySpacing.xs) {
                            Button("1 hour") { droplet.pauseAnnouncements(for: 3600) }
                            Button("Until tomorrow") { droplet.pauseAnnouncements(for: untilTomorrow) }
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
                DropletSliderRow(
                    title: "Announcement length",
                    value: "\(Int(droplet.hudDuration)) s",
                    binding: Binding(get: { droplet.hudDuration },
                                     set: { droplet.setPreference($0.rounded(), forKey: "hudDuration") }),
                    range: 3...15
                )
                DropletToggleRow(
                    title: "Clipboard alert",
                    subtitle: "Shows what you copied on the phone in the notch when it lands on the Mac.",
                    isOn: Binding(get: { droplet.alertsClipboard },
                                  set: { droplet.setPreference($0, forKey: "clipboardAlerts") })
                )
                DropletToggleRow(
                    title: "Low battery alert",
                    subtitle: "Shows a notch alert when the phone drops to \(LowBatteryLatch.threshold)% while not charging.",
                    isOn: Binding(get: { droplet.alertsLowBattery },
                                  set: { droplet.setPreference($0, forKey: "lowBattery") })
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Apps")
            } content: {
                DropletSettingsCard {
                    // Only the apps that do not announce; the rest are switched on the apps page.
                    ForEach(droplet.appExceptions, id: \.self) { package in
                        SettingsAppRow(icon: droplet.appIcons[package], name: droplet.appName(package)) {
                            Picker(droplet.appName(package), selection: mode(for: package)) {
                                Text(AppMode.show.rawValue).tag(AppMode.show)
                                Text(AppMode.hide.rawValue).tag(AppMode.hide)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            Button { mode(for: package).wrappedValue = .announce } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Announce again")
                            .accessibilityLabel("Announce \(droplet.appName(package)) again")
                        }
                    }
                    DropletSettingsPageLink("Phone apps", subtitle: appsSummary, page: AppsPage.id) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .onAppear { droplet.appsVisible(true) }
        .onDisappear { droplet.appsVisible(false) }
    }

    private var appsSummary: String {
        let hidden = droplet.hiddenApps.count
        let quiet = droplet.appExceptions.count - hidden
        guard quiet + hidden > 0 else { return "Every app announces. Turn off the ones that should stay quiet." }
        return [quiet > 0 ? "\(quiet) quiet" : nil, hidden > 0 ? "\(hidden) hidden" : nil]
            .compactMap { $0 }.joined(separator: ", ") + "; the rest announce."
    }

    private var pauseTitle: String {
        guard let until = droplet.announcementsPausedUntil else { return "Pause announcements" }
        return "Announcements paused until \(until.formatted(date: .omitted, time: .shortened))"
    }

    private var untilTomorrow: TimeInterval {
        let calendar = Calendar.current
        let morning = calendar.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime) ?? Date()
        return morning.timeIntervalSinceNow
    }

    private func mode(for package: String) -> Binding<AppMode> {
        Binding(
            get: { droplet.isHidden(package) ? .hide : droplet.isMuted(package) ? .show : .announce },
            set: { mode in
                droplet.setHidden(package, mode == .hide)
                droplet.setMuted(package, mode != .announce)
            }
        )
    }
}
