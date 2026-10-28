import DroppyKit
import SwiftUI

/// The phone at a glance: battery, what is waiting (notifications, unread SMS), what is in progress and what is playing.
/// Each tile leads to its page. Narrow, it keeps the counts and one line each for the live item and the music.
struct HomePage: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        Group {
            if context.isCompact { compact } else { full }
        }
        // The unread SMS count needs the conversation list, which Gossip only refreshes while someone is looking.
        .onAppear { droplet.messagesVisible(true) }
        .onDisappear { droplet.messagesVisible(false) }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.sm) {
                BatteryTile(battery: droplet.phone?.battery)
                StatTile(value: droplet.visibleNotifications.filter { $0.live == nil }.count, label: "notifications") {
                    droplet.select(.notifications)
                }
                StatTile(value: droplet.unreadCount, label: "unread SMS", accent: droplet.unreadCount > 0) {
                    droplet.select(.messages)
                }
            }
            .frame(height: 62)
            if let live = droplet.liveNotifications.first {
                LiveTile(droplet: droplet, notification: live)
            }
            if droplet.currentMedia != nil {
                MediaTile(droplet: droplet)
            }
            if !droplet.homeShowsLive && !droplet.homeShowsMedia {
                LatestNotification(droplet: droplet)
            }
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Button { droplet.reveal(.notifications) } label: {
                HStack(spacing: DroppySpacing.xs) {
                    CountLabel(value: droplet.visibleNotifications.filter { $0.live == nil }.count, label: "notifications")
                    Text("·").foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    CountLabel(value: droplet.unreadCount, label: "SMS")
                }
            }
            .buttonStyle(.plain)
            if let live = droplet.liveNotifications.first {
                Button { droplet.open(live) } label: { LiveLine(droplet: droplet, notification: live) }
                    .buttonStyle(.plain)
            }
            if let media = droplet.currentMedia {
                HStack(spacing: DroppySpacing.sm) {
                    MediaArtwork(image: droplet.artwork(for: media.deviceID), size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(media.playing.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Text(media.playing.artist).font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { droplet.media(media.playing.isPlaying ? "pause" : "play") } label: {
                        Image(systemName: media.playing.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 22))
                    .accessibilityLabel(media.playing.isPlaying ? "Pause" : "Play")
                }
                .droppyFlatGlassControls()
            }
            // The narrow card is as tall as the full one: the room left goes to the newest notifications.
            let latest = droplet.visibleNotifications.filter { $0.live == nil }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(latest.prefix(2), id: \.key) { notification in
                    Button { droplet.open(notification) } label: {
                        CompactNotificationRow(droplet: droplet, notification: notification)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Tiles

/// A raised tile: the one place a widget may use a fill, for something that reads as its own thing.
struct Tile<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, DroppySpacing.smd)
            .padding(.vertical, DroppySpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
    }
}

struct BatteryRing: View {
    let level: Int
    let charging: Bool
    let size: CGFloat
    var lineWidth: CGFloat = 5

    private var tint: Color {
        if charging { return .green }
        return level <= LowBatteryLatch.threshold ? .red : AdaptiveColors.notchSurfacePrimaryText
    }

    var body: some View {
        ZStack {
            Circle().stroke(AdaptiveColors.notchSurfaceCardFill, lineWidth: lineWidth)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, level))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

private struct BatteryTile: View {
    let battery: GossipDevice.Battery?

    var body: some View {
        Tile {
            HStack(spacing: DroppySpacing.smd) {
                if let battery {
                    ZStack {
                        BatteryRing(level: battery.level, charging: battery.charging, size: 42)
                        Text("\(battery.level)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Battery").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Label(battery.charging ? "Charging" : "On battery",
                              systemImage: battery.charging ? "bolt.fill" : "battery.75percent")
                            .labelStyle(.titleOnly)
                            .font(.system(size: 11))
                            .foregroundStyle(battery.charging ? Color.green : AdaptiveColors.notchSurfaceTertiaryText)
                    }
                } else {
                    Text("No battery reading").font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Tile {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DroppySpacing.xs) {
                        Text("\(value)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        if accent { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    }
                    Text(label).font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct CountLabel: View {
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text("\(value)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(label).font(.system(size: 11)).foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
    }
}

/// The first notification in progress as a tile: its photo or icon, what it says, its time or progress, its buttons.
private struct LiveTile: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                LiveLine(droplet: droplet, notification: notification)
                if let live = notification.live, live.fraction != nil || live.indeterminate == true {
                    LiveProgress(live: live)
                }
            }
        }
        .frame(height: 46)
        .onTapGesture { droplet.open(notification) }
    }
}

struct LiveLine: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            SenderAvatar(droplet: droplet, notification: notification, size: 18)
            Text(notification.body.isEmpty ? notification.headline : "\(notification.headline) · \(notification.body)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            LiveTime(live: notification.live)
        }
    }
}

/// What is playing: artwork, title, the transport and the position with volume at either end.
private struct MediaTile: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        if let media = droplet.currentMedia {
            Tile {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    HStack(spacing: DroppySpacing.sm) {
                        MediaArtwork(image: droplet.artwork(for: media.deviceID), size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(media.playing.title).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            Text(media.playing.artist).font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: DroppySpacing.xs) {
                            Button { droplet.media("previous") } label: { Image(systemName: "backward.fill") }
                                .accessibilityLabel("Previous")
                            Button { droplet.media(media.playing.isPlaying ? "pause" : "play") } label: {
                                Image(systemName: media.playing.isPlaying ? "pause.fill" : "play.fill")
                            }
                            .accessibilityLabel(media.playing.isPlaying ? "Pause" : "Play")
                            Button { droplet.media("next") } label: { Image(systemName: "forward.fill") }
                                .accessibilityLabel("Next")
                        }
                        .buttonStyle(DroppyCircleButtonStyle(size: 22))
                    }
                    HStack(spacing: DroppySpacing.xs) {
                        Button { droplet.volume(up: false) } label: { Image(systemName: "speaker.fill") }
                            .accessibilityLabel("Volume down")
                        if media.playing.durationMs > 0 {
                            SeekBar(droplet: droplet, durationMs: media.playing.durationMs, interactive: true)
                        } else {
                            Spacer(minLength: 0)
                        }
                        Button { droplet.volume(up: true) } label: { Image(systemName: "speaker.wave.2.fill") }
                            .accessibilityLabel("Volume up")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 18))
                }
            }
            .frame(height: 70)
            .droppyFlatGlassControls()
        }
    }
}

/// Home with nothing in progress and nothing playing: the newest notification, and the way to the rest.
private struct LatestNotification: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        let rest = droplet.visibleNotifications.filter { $0.live == nil }
        if let latest = rest.first {
            HStack(spacing: DroppySpacing.sm) {
                Button { droplet.open(latest) } label: { CompactNotificationRow(droplet: droplet, notification: latest) }
                    .buttonStyle(.plain)
                SeeAllButton(count: rest.count) { droplet.select(.notifications) }
            }
            .frame(height: 44)
        } else {
            Message(text: "Nothing new on the phone")
                .frame(height: 44)
        }
    }
}

/// One notification on one line pair, the whole row a button: photo, name, text, time.
struct CompactNotificationRow: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            SenderAvatar(droplet: droplet, notification: notification, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(notification.headline).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(notification.body).font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Text(RelativeTime.short(notification.date))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        .padding(.horizontal, DroppySpacing.xs)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .hoverHighlight()
    }
}

struct SeeAllButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(count > 0 ? "See all \(count)" : "See all")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(DroppyQuietButtonStyle(size: .small))
        .fixedSize()
    }
}

extension View {
    /// The card fill under the pointer, so a row reads as something to click.
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? AdaptiveColors.notchSurfaceCardFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
            .onHover { hovering = $0 }
    }
}
