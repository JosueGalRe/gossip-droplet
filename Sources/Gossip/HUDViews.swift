import DroppyKit
import SwiftUI

/// The strip: the app's icon on the left wing, its name on the right, nothing across the camera housing.
struct NotificationStrip: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        HStack {
            AppIcon(image: droplet.icon(for: notification), size: 16)
            Spacer(minLength: 0)
            Text(notification.appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
        }
    }
}

struct NotificationCard: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                AppIcon(image: droplet.icon(for: notification), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DroppySpacing.sm) {
                Spacer(minLength: 0)
                Button("Dismiss") { droplet.dismiss(notification) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button(notification.hasReply ? "Reply" : "Show") {
                    droplet.revealNotifications()
                    if notification.hasReply { droplet.startReply(to: notification) }
                }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
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
