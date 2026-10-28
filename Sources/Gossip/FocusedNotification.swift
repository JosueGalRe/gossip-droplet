import AppKit
import DroppyKit
import SwiftUI

/// One notification on its own, in place of the list: who and when, all of its text, its picture at full width, the
/// suggested replies and the app's buttons, and a field to reply. The widget grows to fit it while it is focused.
struct FocusedNotification: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification
    @FocusState private var replyFocused: Bool

    /// The widget's solo width less its insets, where the text and the picture are laid out.
    static let contentWidth: CGFloat = 404
    static let maxHeight: CGFloat = 440
    static let maxPictureHeight: CGFloat = 200
    private static let bodyFont = NSFont.systemFont(ofSize: 12)

    /// The widget's height for this notification: header, the person and all the text, the picture, a row of
    /// suggestions and buttons, the reply field and the insets, capped so a huge message scrolls instead.
    static func height(for notification: PhoneNotification, picture: NSImage?) -> CGFloat {
        let textWidth = contentWidth - 40
        let lineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        let measured = (notification.body as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont]
        )
        var height: CGFloat = 16 + 24 + 8   // insets, the widget's header, spacing
        height += 22 + 8                      // back, app and time
        height += max(32, 17 + 2 + ceil(measured.height / lineHeight) * lineHeight)
        if let picture, picture.size.width > 0 {
            height += 8 + pictureHeight(picture)
        }
        if QuickActions.hasAny(notification) { height += 8 + 28 }
        if notification.hasReply { height += 8 + 28 }
        return min(maxHeight, ceil(height))
    }

    static func pictureHeight(_ picture: NSImage) -> CGFloat {
        min(maxPictureHeight, (contentWidth - 40) * picture.size.height / max(1, picture.size.width))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Button { droplet.unfocus() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("All notifications")
                    .accessibilityLabel("All notifications")
                AppIcon(image: droplet.icon(for: notification), size: 14)
                Text(notification.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Text("· \(RelativeTime.short(notification.date))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                Spacer(minLength: 0)
                Button { droplet.dismiss(notification) } label: { Image(systemName: "xmark") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Dismiss on phone")
                    .accessibilityLabel("Dismiss on phone")
            }
            .frame(height: 22)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(alignment: .top, spacing: DroppySpacing.sm) {
                        SenderAvatar(droplet: droplet, notification: notification, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.headline)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            Text(notification.body)
                                .font(.system(size: 12))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let picture = droplet.picture(for: notification) {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: Self.contentWidth - 40, maxHeight: Self.pictureHeight(picture), alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                            .padding(.leading, 40)
                    }
                }
            }

            if QuickActions.hasAny(notification) {
                ScrollView(.horizontal, showsIndicators: false) {
                    QuickActions(droplet: droplet, notification: notification, limit: 8)
                }
                .padding(.leading, 40)
            }

            if notification.hasReply {
                HStack(spacing: DroppySpacing.sm) {
                    TextField("Reply to \(notification.headline)", text: $droplet.replyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .focused($replyFocused)
                        .onSubmit { droplet.sendReply() }
                        .onExitCommand { droplet.unfocus() }
                    Button("Send") { droplet.sendReply() }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                        .disabled(droplet.replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, DroppySpacing.smd)
                .frame(height: 28)
                .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule())
                .padding(.leading, 40)
            }
        }
        .droppyFlatGlassControls()
        .onAppear { replyFocused = notification.hasReply }
    }
}
