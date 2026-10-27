import DroppyKit
import SwiftUI

/// The strip: the sender's photo (or the app's icon) on the left wing, the app's name on the right, nothing across the
/// camera housing.
struct NotificationStrip: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        HStack {
            SenderAvatar(droplet: droplet, notification: notification, size: 16)
            Spacer(minLength: 0)
            Text(notification.appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
        }
    }
}

/// The card: who wrote and what with its picture, reply and dismiss at hand, then a row of what can be done without
/// opening anything: copy a code, a suggested reply, the app's own buttons.
struct NotificationCard: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    /// The card's content height: one more row when there is something to do in a click.
    static func height(for notification: PhoneNotification) -> CGFloat {
        QuickActions.hasAny(notification) ? 76 : 44
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                SenderAvatar(droplet: droplet, notification: notification, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    // A link is one long word: break it by character instead of losing the second line.
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let picture = droplet.picture(for: notification) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                }
                HStack(spacing: DroppySpacing.xs) {
                    Button {
                        droplet.revealNotifications()
                        if notification.hasReply { droplet.startReply(to: notification) }
                    } label: { Image(systemName: notification.hasReply ? "arrowshape.turn.up.left" : "chevron.down") }
                        .help(notification.hasReply ? "Reply" : "Show in the shelf")
                        .accessibilityLabel(notification.hasReply ? "Reply" : "Show")
                    Button { droplet.dismiss(notification) } label: { Image(systemName: "xmark") }
                        .help("Dismiss on phone")
                        .accessibilityLabel("Dismiss")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
            }
            if QuickActions.hasAny(notification) {
                ScrollView(.horizontal, showsIndicators: false) {
                    QuickActions(droplet: droplet, notification: notification, limit: 3)
                }
            }
        }
        .droppyFlatGlassControls()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A call: who is calling, how long it has lasted once answered, and the dialer's own buttons (Answer, Decline, Hang up).
/// The audio stays on the phone.
struct CallCard: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.sm) {
                SenderAvatar(droplet: droplet, notification: notification, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(notification.body.isEmpty ? notification.appName : notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                LiveTime(live: notification.live)
            }
            HStack(spacing: DroppySpacing.sm) {
                Spacer(minLength: 0)
                ForEach(notification.actions ?? [], id: \.self) { action in
                    Button(action.title) { droplet.perform(action, on: notification) }
                        .buttonStyle(isDecline(action) ? AnyButtonStyle(DroppyQuietButtonStyle(size: .small))
                                                       : AnyButtonStyle(DroppyAccentButtonStyle(color: .green, size: .small)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isDecline(_ action: NotificationAction) -> Bool {
        let title = action.title.lowercased()
        return ["decline", "rechazar", "hang up", "colgar", "end", "finalizar"].contains { title.contains($0) }
    }
}

/// Lets the call card pick a style per button.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Low battery, the way Droppy's own battery HUD reads: a red battery on the left wing, the level on the right.
struct BatteryStrip: View {
    let level: Int

    var body: some View {
        HStack {
            Image(systemName: BatterySymbol.name(level: level, charging: false))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.red)
            Spacer(minLength: 0)
            Text("Phone \(level)%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
    }
}

// MARK: - Live activity

/// The compact activity's left wing: the live notification's photo or icon, or the playing media's artwork.
struct ActivityLeading: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        switch droplet.activityFocus {
        case .live(let notification):
            SenderAvatar(droplet: droplet, notification: notification, size: DroppyLiveActivityMetrics.iconSize + 5)
        case .media(let deviceID, _):
            MediaArtwork(image: droplet.artwork(for: deviceID), size: DroppyLiveActivityMetrics.iconSize + 5)
        case nil:
            EmptyView()
        }
    }
}

/// The right wing: a progress ring, a running time, or the waveform of playing media.
struct ActivityTrailing: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        Group {
            switch droplet.activityFocus {
            case .live(let notification):
                if let fraction = notification.live?.fraction {
                    ZStack {
                        Circle().stroke(AdaptiveColors.notchSurfaceCardFill, lineWidth: DroppyLiveActivityMetrics.progressRingLineWidth)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: DroppyLiveActivityMetrics.progressRingLineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: DroppyLiveActivityMetrics.progressRingSize, height: DroppyLiveActivityMetrics.progressRingSize)
                } else if notification.live?.chronometerDate != nil {
                    LiveTime(live: notification.live)
                } else {
                    Image(systemName: notification.live?.isCall == true ? "phone.fill" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(notification.live?.isCall == true ? Color.green : AdaptiveColors.notchSurfacePrimaryText)
                }
            case .media:
                Image(systemName: "waveform")
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
    }
}
