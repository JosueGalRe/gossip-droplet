//
//  GossipDroplet.swift
//  Gossip
//

import AppKit
import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(GossipPrincipal)
public final class GossipPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { GossipDroplet() }
}

/// A paired device as the Gossip Mac app reports it.
struct GossipDevice: Decodable, Equatable, Identifiable {
    struct Battery: Decodable, Equatable {
        let level: Int
        let charging: Bool
    }

    let id: String
    let name: String
    let type: String
    let online: Bool
    let battery: Battery?
}

/// A notification a phone is mirroring.
struct PhoneNotification: Decodable, Equatable {
    let deviceId: String
    let id: String
    let appName: String
    let title: String
    let body: String
    let iconBase64: String?
    let hasReply: Bool
    let timestamp: Int64
    let replay: Bool?

    var key: String { "\(deviceId)|\(id)" }
}

/// Phone notifications and battery from the Gossip Mac app, on the shelf and as a HUD when one arrives.
@MainActor
public final class GossipDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "gossip"
    static let widgetID: ShelfWidgetID = "gossip"
    static let hudID = "gossip.notification"

    @Published private(set) var isConnected = false
    @Published private(set) var devices: [GossipDevice] = []
    /// Newest first.
    @Published private(set) var notifications: [PhoneNotification] = []
    @Published var replyingTo: String?
    @Published var replyText = ""

    private var host: DropletHost?
    private var client: BridgeClient?
    private var icons: [String: NSImage] = [:]
    private var hudKey: String?
    private let isSample: Bool

    public override init() {
        isSample = false
        super.init()
    }

    /// For the harness: fixed data and no connection.
    public static func sample() -> GossipDroplet {
        let droplet = GossipDroplet(sample: ())
        droplet.isConnected = true
        droplet.devices = [GossipDevice(id: "pixel", name: "Pixel 9 Pro XL", type: "phone", online: true,
                                        battery: .init(level: 64, charging: false))]
        droplet.notifications = [
            PhoneNotification(deviceId: "pixel", id: "1", appName: "WhatsApp", title: "Ana", body: "¿Llegas a las 7?",
                              iconBase64: nil, hasReply: true, timestamp: 0, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "2", appName: "Gmail", title: "Railway",
                              body: "Your deployment succeeded", iconBase64: nil, hasReply: false, timestamp: 0, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "3", appName: "Messages", title: "+503 7000 0000",
                              body: "Tu código es 482913", iconBase64: nil, hasReply: true, timestamp: 0, replay: nil),
        ]
        return droplet
    }

    private init(sample: Void) {
        isSample = true
        super.init()
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        guard !isSample else {
            // So the harness's HUD page has something to draw.
            if let first = notifications.first { announce(first) }
            return
        }
        let client = BridgeClient()
        client.onLine = { [weak self] line in self?.handle(line) }
        client.onConnectionChange = { [weak self] connected in self?.connectionChanged(connected) }
        self.client = client
        client.start()
    }

    public func deactivate() {
        client?.stop()
        client = nil
        if hudKey != nil { host?.hud.dismiss(id: Self.hudID) }
        host = nil
    }

    // MARK: Bridge

    private func connectionChanged(_ connected: Bool) {
        isConnected = connected
        guard !connected else { return }
        // Gossip resends everything on the next connect.
        devices = []
        notifications = []
        icons = [:]
        replyingTo = nil
    }

    private struct Kind: Decodable { let type: String }
    private struct State: Decodable { let devices: [GossipDevice] }
    private struct Removed: Decodable {
        let deviceId: String
        let id: String
    }

    private func handle(_ line: Data) {
        let decoder = JSONDecoder()
        guard let kind = try? decoder.decode(Kind.self, from: line) else { return }
        switch kind.type {
        case "state":
            if let state = try? decoder.decode(State.self, from: line) { devices = state.devices }
        case "notification.posted":
            guard let posted = try? decoder.decode(PhoneNotification.self, from: line) else { return }
            notifications.removeAll { $0.key == posted.key }
            notifications.insert(posted, at: 0)
            notifications.sort { $0.timestamp > $1.timestamp }
            icons[posted.key] = nil
            if posted.replay != true { announce(posted) }
        case "notification.removed":
            guard let removed = try? decoder.decode(Removed.self, from: line) else { return }
            let key = "\(removed.deviceId)|\(removed.id)"
            notifications.removeAll { $0.key == key }
            icons[key] = nil
            if replyingTo == key { replyingTo = nil }
            if hudKey == key {
                hudKey = nil
                host?.hud.dismiss(id: Self.hudID)
            }
        default:
            break
        }
    }

    // MARK: Actions

    func dismiss(_ notification: PhoneNotification) {
        client?.send(["type": "dismiss", "deviceId": notification.deviceId, "id": notification.id])
    }

    func startReply(to notification: PhoneNotification) {
        replyText = ""
        replyingTo = notification.key
        host?.shelf.requestKeyboardFocus()
    }

    func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = replyingTo, !text.isEmpty,
              let notification = notifications.first(where: { $0.key == key }) else { return }
        client?.send(["type": "reply", "deviceId": notification.deviceId, "id": notification.id, "text": text])
        replyingTo = nil
        replyText = ""
        host?.feedback.play(.success)
    }

    func cancelReply() {
        replyingTo = nil
        replyText = ""
    }

    func openShelf() {
        host?.hud.dismiss(id: Self.hudID)
        hudKey = nil
        host?.shelf.open(revealing: Self.widgetID)
    }

    func icon(for notification: PhoneNotification) -> NSImage? {
        if let cached = icons[notification.key] { return cached }
        guard let base64 = notification.iconBase64, let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return nil }
        icons[notification.key] = image
        return image
    }

    var phone: GossipDevice? {
        devices.first { $0.type != "mac" && $0.online } ?? devices.first { $0.type != "mac" }
    }

    // MARK: HUD

    private func announce(_ notification: PhoneNotification) {
        guard let host else { return }
        hudKey = notification.key
        let presented = host.hud.present(DropletHUDRequest(
            id: Self.hudID, duration: 6,
            accessibilityLabel: "\(notification.appName): \(notification.title)",
            isExpanded: true, expandedContentHeight: 66
        ) { [weak self] in
            if let self { NotificationStrip(droplet: self, notification: notification) }
        } expanded: { [weak self] in
            if let self { NotificationCard(droplet: self, notification: notification) }
        })
        if !presented { hudKey = nil }
    }
}

extension GossipDroplet: HUDPresenting {}

// MARK: - Shelf widget

extension GossipDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Gossip",
                systemImage: "iphone",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(140)
                ),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["phone", "android", "notifications", "battery"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(GossipWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

private struct GossipWidget: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if !droplet.isConnected {
                Message(text: "Gossip isn't running on this Mac")
            } else if droplet.phone == nil {
                Message(text: "Pair a phone in Gossip")
            } else if context.isCompact {
                compactBody
            } else if let key = droplet.replyingTo,
                      let notification = droplet.notifications.first(where: { $0.key == key }) {
                ReplyComposer(droplet: droplet, notification: notification)
            } else if droplet.notifications.isEmpty {
                Message(text: "No notifications")
            } else {
                VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                    ForEach(droplet.notifications.prefix(3), id: \.key) { notification in
                        NotificationRow(droplet: droplet, notification: notification)
                    }
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
            Text(droplet.phone?.name ?? "Gossip")
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
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    /// The header already carries the battery, so the paired card spends its room on the newest notification.
    @ViewBuilder private var compactBody: some View {
        if let latest = droplet.notifications.first {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                HStack(spacing: DroppySpacing.xsm) {
                    AppIcon(image: droplet.icon(for: latest), size: 16)
                    Text(latest.title.isEmpty ? latest.appName : latest.title)
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

private struct Message: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
    }
}

private struct BatteryLabel: View {
    let battery: GossipDevice.Battery

    var body: some View {
        HStack(spacing: DroppySpacing.xs) {
            Image(systemName: battery.charging ? "battery.100percent.bolt" : symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(battery.level <= 20 && !battery.charging ? Color.red : AdaptiveColors.notchSurfaceSecondaryText)
            Text("\(battery.level)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    private var symbol: String {
        switch battery.level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct AppIcon: View {
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

private struct NotificationRow: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            AppIcon(image: droplet.icon(for: notification), size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(notification.title.isEmpty ? notification.appName : notification.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(notification.body)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if notification.hasReply {
                Button { droplet.startReply(to: notification) } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Reply")
                    .accessibilityLabel("Reply to \(notification.title)")
            }
            Button { droplet.dismiss(notification) } label: { Image(systemName: "xmark") }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Dismiss on phone")
                .accessibilityLabel("Dismiss \(notification.title)")
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
            HStack(spacing: DroppySpacing.sm) {
                AppIcon(image: droplet.icon(for: notification), size: 18)
                Text("\(notification.title): \(notification.body)")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(2)
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

// MARK: - HUD views

/// The strip: the app's icon on the left wing, its name on the right, nothing across the camera housing.
private struct NotificationStrip: View {
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

private struct NotificationCard: View {
    @ObservedObject var droplet: GossipDroplet
    let notification: PhoneNotification

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                AppIcon(image: droplet.icon(for: notification), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title.isEmpty ? notification.appName : notification.title)
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
                    droplet.openShelf()
                    if notification.hasReply { droplet.startReply(to: notification) }
                }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
