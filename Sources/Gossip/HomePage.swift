import DroppyKit
import SwiftUI

/// The phone at a glance: battery, what is waiting (notifications, unread SMS), what is in progress and what is playing.
/// The counts lead to their pages. Narrow, it keeps the counts and one line each for the live item and the music.
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

    /// Wide: the phone at a glance on the left; on the right what is in progress, what is playing, and the newest
    /// notifications in the room they leave.
    private var full: some View {
        let latest = droplet.visibleNotifications.filter { $0.live == nil }
        let live = droplet.homeShowsLive, media = droplet.homeShowsMedia
        // The page's body less the live (40) and media (60) tiles with their gaps; a row is 33 and a 2 gap. Neither
        // tile: three rows; one: two rows or one; both: none.
        let room = droplet.pageBodyHeight(context) - (live ? 48 : 0) - (media ? 68 : 0)
        let rows = GossipDroplet.rows(fitting: room)
        return HStack(alignment: .top, spacing: DroppySpacing.sm) {
            StatusTile(droplet: droplet, notifications: latest.count)
                .frame(width: 140)
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                if let first = droplet.liveNotifications.first {
                    LiveTile(droplet: droplet, notification: first)
                }
                if media {
                    MediaTile(droplet: droplet)
                }
                if rows > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        if latest.isEmpty {
                            Message(text: "Nothing new on the phone").padding(.horizontal, DroppySpacing.xs)
                        }
                        ForEach(latest.prefix(rows), id: \.key) { notification in
                            Button { droplet.open(notification) } label: {
                                CompactNotificationRow(droplet: droplet, notification: notification)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var compact: some View {
        let latest = droplet.visibleNotifications.filter { $0.live == nil }
        let live = droplet.homeShowsLive, media = droplet.homeShowsMedia
        // The counts line (16), the live line (18) and the player (28), each with a 4 gap; rows as on the wide page.
        let room = droplet.pageBodyHeight(context) - 16 - (live ? 22 : 0) - (media ? 32 : 0) - 4
        let rows = GossipDroplet.rows(fitting: room)
        return VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Button { droplet.reveal(.notifications) } label: {
                HStack(spacing: DroppySpacing.xs) {
                    CountLabel(value: latest.count, label: "notifications")
                    Text("·").foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    CountLabel(value: droplet.unreadCount, label: "SMS")
                }
            }
            .buttonStyle(.plain)
            .frame(height: 16)
            if let first = droplet.liveNotifications.first {
                Button { droplet.open(first) } label: { LiveLine(droplet: droplet, notification: first) }
                    .buttonStyle(.plain)
                    .frame(height: 18)
            }
            if let playing = droplet.currentMedia {
                HStack(spacing: DroppySpacing.sm) {
                    MediaArtwork(image: droplet.artwork(for: playing.deviceID), size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(playing.playing.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Text(playing.playing.artist).font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { droplet.media(playing.playing.isPlaying ? "pause" : "play") } label: {
                        Image(systemName: playing.playing.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 22))
                    .accessibilityLabel(playing.playing.isPlaying ? "Pause" : "Play")
                }
                .frame(height: 28)
                .droppyFlatGlassControls()
            }
            if rows > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(latest.prefix(rows), id: \.key) { notification in
                        Button { droplet.open(notification) } label: {
                            CompactNotificationRow(droplet: droplet, notification: notification)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Tiles

/// A raised tile: the one place a widget may use a fill, for something that reads as its own thing.
struct Tile<Content: View>: View {
    var verticalPadding: CGFloat = DroppySpacing.sm
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, DroppySpacing.smd)
            .padding(.vertical, verticalPadding)
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

/// Home's left column: the battery, and the counts that lead to the notifications and SMS pages.
private struct StatusTile: View {
    @ObservedObject var droplet: GossipDroplet
    let notifications: Int

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 2) {
                if let battery = droplet.phone?.battery {
                    HStack(spacing: DroppySpacing.sm) {
                        ZStack {
                            BatteryRing(level: battery.level, charging: battery.charging, size: 40, lineWidth: 4.5)
                            Text("\(battery.level)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Battery").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            Text(battery.charging ? "Charging" : "On battery").font(.system(size: 11))
                                .foregroundStyle(battery.charging ? Color.green : AdaptiveColors.notchSurfaceTertiaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("No battery reading").font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                Spacer(minLength: 0)
                CountButton(value: notifications, label: "notifications") { droplet.select(.notifications) }
                CountButton(value: droplet.unreadCount, label: "unread SMS", accent: droplet.unreadCount > 0) {
                    droplet.select(.messages)
                }
            }
        }
    }
}

private struct CountButton: View {
    let value: Int
    let label: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(label).font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                if accent { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
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
        Tile(verticalPadding: DroppySpacing.xsm) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                LiveLine(droplet: droplet, notification: notification)
                if let live = notification.live, live.fraction != nil || live.indeterminate == true {
                    // The bar's own height, not the control's, so the tile keeps its 40.
                    LiveProgress(live: live).frame(height: 6)
                }
            }
        }
        .frame(height: 40)
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
            Tile(verticalPadding: DroppySpacing.xsm) {
                VStack(alignment: .leading, spacing: 2) {
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
                    .buttonStyle(DroppyCircleButtonStyle(size: 16))
                }
            }
            .frame(height: 60)
            .droppyFlatGlassControls()
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
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverHighlight()
    }
}

/// A quiet text link to a whole list, so it never outweighs the rows above it.
struct SeeAllButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(count > 0 ? "See all \(count)" : "See all")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
