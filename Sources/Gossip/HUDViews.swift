import AppKit
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

/// The card: who wrote and what, with reply and dismiss at hand, then a row of what can be done in a click (copy a code,
/// a suggested reply, the app's own buttons). Compact it shows three lines and times out; a click opens it with all the
/// text, the picture large and every button, and it stays until closed.
struct NotificationCard: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    let layout: Layout
    let expanded: Bool

    struct Layout {
        /// Lines the body shows, and the lines it needs at this width.
        let bodyLines: Int
        let measuredLines: Int
        /// Open and longer than [maxExpandedLines]: the body scrolls.
        let scrolls: Bool
        let pictureHeight: CGFloat
        let height: CGFloat
    }

    static let maxCompactLines = 3
    static let maxExpandedLines = 12
    private static let bodyFont = NSFont.systemFont(ofSize: 12)
    static var lineHeight: CGFloat { ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading) }

    /// Measures the body at the card's real text width (the card is the notch's width plus 120 a side, less its 48pt
    /// insets; the island's is narrower) and asks for the height that shows what this shape shows, plus the picture
    /// when open and a row when there is something to do in a click.
    static func layout(for notification: PhoneNotification, geometry: DropletNotchGeometry, picture: NSImage?,
                       expanded: Bool) -> Layout {
        let contentWidth = geometry.isHardwareNotch ? geometry.closedWidth + 144 : 208
        let buttons: CGFloat = expanded ? 80 : 52
        let textWidth = max(120, contentWidth - 36 - buttons - 8 - (!expanded && picture != nil ? 48 : 0))
        let measured = (notification.body as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont]
        )
        let measuredLines = max(1, Int(ceil(measured.height / lineHeight)))
        let maxLines = expanded ? maxExpandedLines : maxCompactLines
        let bodyLines = min(maxLines, measuredLines)
        var height = max(28, 17 + 2 + CGFloat(bodyLines) * lineHeight)
        var pictureHeight: CGFloat = 0
        if expanded, let picture, picture.size.width > 0 {
            pictureHeight = min(160, (contentWidth - 36) * picture.size.height / picture.size.width)
            height += 8 + pictureHeight
        }
        if QuickActions.hasAny(notification) { height += 8 + 28 }
        return Layout(bodyLines: bodyLines, measuredLines: measuredLines, scrolls: expanded && measuredLines > maxLines,
                      pictureHeight: pictureHeight, height: ceil(height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                SenderAvatar(droplet: droplet, notification: notification, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DroppySpacing.xs) {
                        Text(notification.headline)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                        if droplet.arrivedWhileHeld > 0 {
                            Text("\(droplet.arrivedWhileHeld) new")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule())
                                .help("Arrived while this one was open; they are in the shelf")
                        }
                    }
                    bodyText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !expanded, let picture = droplet.picture(for: notification) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                }
                HStack(spacing: DroppySpacing.xs) {
                    Button {
                        droplet.revealNotifications()
                        if notification.hasReply { droplet.startReply(to: notification) }
                    } label: { Image(systemName: notification.hasReply ? "arrowshape.turn.up.left" : "tray") }
                        .help(notification.hasReply ? "Reply" : "Show in the shelf")
                        .accessibilityLabel(notification.hasReply ? "Reply" : "Show in the shelf")
                    if expanded {
                        Button { droplet.closeHUD() } label: { Image(systemName: "chevron.up") }
                            .help("Close (keeps it on the phone)")
                            .accessibilityLabel("Close")
                    }
                    Button { droplet.dismiss(notification) } label: { Image(systemName: "xmark") }
                        .help("Dismiss on phone")
                        .accessibilityLabel("Dismiss on phone")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
            }
            if expanded, layout.pictureHeight > 0, let picture = droplet.picture(for: notification) {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: layout.pictureHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                    .padding(.leading, 36)
            }
            if QuickActions.hasAny(notification) {
                ScrollView(.horizontal, showsIndicators: false) {
                    QuickActions(droplet: droplet, notification: notification, limit: expanded ? 8 : 3)
                }
            }
        }
        .droppyFlatGlassControls()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { droplet.toggleHUDExpanded() }
        .onHover { droplet.hudHover($0) }
        .accessibilityAction(named: expanded ? "Fold" : "Open") { droplet.toggleHUDExpanded() }
    }

    /// Long messages scroll once open; links (one long word) break by character instead of losing their line.
    @ViewBuilder private var bodyText: some View {
        let text = Text(notification.body)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        if layout.scrolls {
            ScrollView(.vertical, showsIndicators: true) {
                text.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: CGFloat(layout.bodyLines) * Self.lineHeight)
        } else {
            text.lineLimit(layout.bodyLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

// MARK: - Notices

/// A notice's strip: its symbol beside the notch.
struct NoticeStrip: View {
    let symbol: String

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Spacer(minLength: 0)
        }
    }
}

/// Something worth a glance, not an action: what was copied on the phone, why an app window did not open.
struct NoticeCard: View {
    let symbol: String
    let title: String
    let detail: String?
    let image: NSImage?

    static let maxImageHeight: CGFloat = 96

    /// Insets, the title, and two lines of detail or the picture.
    static func height(detail: String?, image: NSImage?) -> CGFloat {
        var height: CGFloat = 16 + 16
        if let image, image.size.width > 0 { height += 6 + imageHeight(image) } else if detail?.isEmpty == false { height += 2 + 30 }
        return height
    }

    private static func imageHeight(_ image: NSImage) -> CGFloat {
        min(maxImageHeight, image.size.height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: image == nil ? 2 : 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: Self.imageHeight(image), alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                } else if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DroppySpacing.sm)
        .accessibilityElement(children: .combine)
    }
}
