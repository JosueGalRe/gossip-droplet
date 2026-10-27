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

/// The phone paired with the Gossip Mac app, on Droppy's surfaces: notifications (HUD and shelf), battery, what it is
/// playing, its SMS conversations, and buttons to ring it, mirror it or pair a new one.
@MainActor
public final class GossipDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "gossip"
    static let phoneWidgetID: ShelfWidgetID = "gossip"
    static let mediaWidgetID: ShelfWidgetID = "gossip.media"
    static let messagesWidgetID: ShelfWidgetID = "gossip.messages"
    static let notificationHUDID = "gossip.notification"
    static let batteryHUDID = "gossip.battery"

    @Published private(set) var isConnected = false
    @Published private(set) var devices: [GossipDevice] = []
    @Published private(set) var ringing: Set<String> = []
    /// Newest first.
    @Published private(set) var notifications: [PhoneNotification] = []
    @Published private(set) var nowPlaying: [String: NowPlaying] = [:]
    @Published var replyingTo: String?
    @Published var replyText = ""

    @Published private(set) var threads: [MessageThread] = []
    @Published private(set) var openThreadID: String?
    @Published private(set) var conversation: [ChatMessage] = []
    @Published private(set) var messagesError: String?
    @Published private(set) var messagesLoading = false
    @Published var composeText = ""

    private var host: DropletHost?
    private var client: BridgeClient?
    private var icons: [String: NSImage] = [:]
    private var artwork: [String: NSImage] = [:]
    private var hudKey: String?
    private var batteryLatches: [String: LowBatteryLatch] = [:]
    private var messagesViewers = 0
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private let lockScreenSubject = CurrentValueSubject<LockScreenStatusEntry?, Never>(nil)
    private let isSample: Bool

    public override init() {
        isSample = false
        super.init()
    }

    private init(sample: Void) {
        isSample = true
        super.init()
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        registerShortcuts()
        guard !isSample else {
            // So the harness's surfaces have something to draw.
            publishActivity()
            publishLockScreen()
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
        if hudKey != nil { host?.hud.dismiss(id: Self.notificationHUDID) }
        activitySubject.send(nil)
        lockScreenSubject.send(nil)
        host = nil
    }

    // MARK: Bridge

    private func connectionChanged(_ connected: Bool) {
        isConnected = connected
        if connected {
            if messagesViewers > 0 { client?.send(["type": "messages.open"]) }
            return
        }
        // Gossip resends everything on the next connect.
        devices = []
        ringing = []
        notifications = []
        nowPlaying = [:]
        icons = [:]
        artwork = [:]
        replyingTo = nil
        publishActivity()
        publishLockScreen()
    }

    private struct Kind: Decodable { let type: String }
    private struct State: Decodable {
        let devices: [GossipDevice]
        let ringing: [String]?
    }
    private struct Removed: Decodable {
        let deviceId: String
        let id: String
    }
    private struct Media: Decodable {
        let deviceId: String
        let nowPlaying: NowPlaying?
    }
    private struct Threads: Decodable { let threads: [MessageThread] }
    private struct History: Decodable {
        let threadId: String
        let messages: [ChatMessage]
    }
    private struct MessagesStatus: Decodable {
        let loading: Bool
        let error: String?
    }

    private func handle(_ line: Data) {
        let decoder = JSONDecoder()
        guard let kind = try? decoder.decode(Kind.self, from: line) else { return }
        switch kind.type {
        case "state":
            guard let state = try? decoder.decode(State.self, from: line) else { return }
            devices = state.devices
            ringing = Set(state.ringing ?? [])
            checkBattery()
            publishLockScreen()
        case "notification.posted":
            guard let posted = try? decoder.decode(PhoneNotification.self, from: line) else { return }
            notifications.removeAll { $0.key == posted.key }
            notifications.append(posted)
            notifications.sort { $0.timestamp > $1.timestamp }
            icons[posted.key] = nil
            rememberApp(package: posted.appPackage, name: posted.appName)
            if posted.replay != true { announce(posted) }
        case "notification.removed":
            guard let removed = try? decoder.decode(Removed.self, from: line) else { return }
            let key = "\(removed.deviceId)|\(removed.id)"
            notifications.removeAll { $0.key == key }
            icons[key] = nil
            if replyingTo == key { replyingTo = nil }
            if hudKey == key {
                hudKey = nil
                host?.hud.dismiss(id: Self.notificationHUDID)
            }
        case "media":
            guard let media = try? decoder.decode(Media.self, from: line) else { return }
            if let playing = media.nowPlaying {
                // Gossip sends artwork only when it changed; keep the last one otherwise.
                if let base64 = playing.artworkBase64, let data = Data(base64Encoded: base64) {
                    artwork[media.deviceId] = NSImage(data: data)
                }
                nowPlaying[media.deviceId] = playing
            } else {
                nowPlaying[media.deviceId] = nil
                artwork[media.deviceId] = nil
            }
            publishActivity()
        case "messages.threads":
            if let list = try? decoder.decode(Threads.self, from: line) { threads = list.threads }
        case "messages.history":
            guard let history = try? decoder.decode(History.self, from: line), history.threadId == openThreadID else { return }
            conversation = history.messages
        case "messages.status":
            guard let status = try? decoder.decode(MessagesStatus.self, from: line) else { return }
            messagesLoading = status.loading
            messagesError = status.error
        default:
            break
        }
    }

    // MARK: Phone

    var phone: GossipDevice? {
        devices.first { $0.isPhone && $0.online } ?? devices.first { $0.isPhone }
    }

    var isRingingPhone: Bool {
        guard let phone else { return false }
        return ringing.contains(phone.id)
    }

    func ringPhone() {
        guard let phone else { return }
        client?.send(["type": "ring", "deviceId": phone.id])
    }

    func openInGossip(_ target: String) {
        client?.send(["type": "open", "target": target])
        host?.shelf.close()
    }

    // MARK: Notifications

    /// Grouped by app, the app with the newest notification first.
    var notificationGroups: [NotificationGroup] {
        var order: [String] = []
        var byApp: [String: [PhoneNotification]] = [:]
        for notification in notifications {
            if byApp[notification.appPackage] == nil { order.append(notification.appPackage) }
            byApp[notification.appPackage, default: []].append(notification)
        }
        return order.map { package in
            let list = byApp[package] ?? []
            return NotificationGroup(appPackage: package, appName: list.first?.appName ?? package, notifications: list)
        }
    }

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

    func revealPhoneWidget() {
        host?.hud.dismiss(id: Self.notificationHUDID)
        hudKey = nil
        host?.shelf.open(revealing: Self.phoneWidgetID)
    }

    func icon(for notification: PhoneNotification) -> NSImage? {
        if let cached = icons[notification.key] { return cached }
        guard let base64 = notification.iconBase64, let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return nil }
        icons[notification.key] = image
        return image
    }

    // MARK: Media

    /// The phone's session, playing ones first.
    var currentMedia: (deviceID: String, playing: NowPlaying)? {
        let sessions = nowPlaying.sorted { $0.key < $1.key }
        let pick = sessions.first { $0.value.isPlaying } ?? sessions.first
        return pick.map { ($0.key, $0.value) }
    }

    func artwork(for deviceID: String) -> NSImage? { artwork[deviceID] }

    func media(_ action: String) {
        client?.send(["type": "media", "action": action])
    }

    // MARK: Messages

    /// The Messages widget appeared or went away: Gossip only refreshes conversations while one is showing.
    func messagesVisible(_ visible: Bool) {
        messagesViewers = max(0, messagesViewers + (visible ? 1 : -1))
        if visible, messagesViewers == 1 {
            client?.send(["type": "messages.open"])
        } else if !visible, messagesViewers == 0 {
            client?.send(["type": "messages.close"])
        }
    }

    var openThread: MessageThread? { threads.first { $0.id == openThreadID } }
    var unreadCount: Int { threads.reduce(0) { $0 + $1.unread } }

    func openThread(_ thread: MessageThread?) {
        openThreadID = thread?.id
        conversation = []
        composeText = ""
        guard let thread else { return }
        client?.send(["type": "messages.thread", "threadId": thread.id])
        host?.shelf.requestKeyboardFocus()
    }

    func sendMessage() {
        let body = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let thread = openThread else { return }
        client?.send(["type": "messages.send", "phoneId": thread.phoneId, "address": thread.address, "body": body])
        composeText = ""
    }

    // MARK: Settings

    var announcesNotifications: Bool {
        host?.preferences.value(forKey: "announce", default: true) ?? true
    }

    var hudDuration: Double {
        host?.preferences.value(forKey: "hudDuration", default: 6.0) ?? 6
    }

    var alertsLowBattery: Bool {
        host?.preferences.value(forKey: "lowBattery", default: true) ?? true
    }

    /// Apps the phone has shown notifications from, package to name, so the settings can mute each one.
    var knownApps: [String: String] {
        host?.preferences.value(forKey: "knownApps", as: [String: String].self) ?? [:]
    }

    func isMuted(_ package: String) -> Bool {
        (host?.preferences.value(forKey: "mutedApps", as: [String].self) ?? []).contains(package)
    }

    func setMuted(_ package: String, _ muted: Bool) {
        var list = Set(host?.preferences.value(forKey: "mutedApps", as: [String].self) ?? [])
        if muted { list.insert(package) } else { list.remove(package) }
        setPreference(list.sorted(), forKey: "mutedApps")
    }

    func setPreference<Value: Codable>(_ value: Value, forKey key: String) {
        objectWillChange.send()
        host?.preferences.setValue(value, forKey: key)
    }

    private func rememberApp(package: String, name: String) {
        var apps = knownApps
        guard apps[package] != name else { return }
        apps[package] = name
        host?.preferences.setValue(apps, forKey: "knownApps")
    }

    // MARK: HUD

    private func announce(_ notification: PhoneNotification) {
        guard let host, announcesNotifications, !isMuted(notification.appPackage) else { return }
        hudKey = notification.key
        let presented = host.hud.present(DropletHUDRequest(
            id: Self.notificationHUDID, duration: hudDuration,
            accessibilityLabel: "\(notification.appName): \(notification.headline)",
            isExpanded: true, expandedContentHeight: 66
        ) { [weak self] in
            if let self { NotificationStrip(droplet: self, notification: notification) }
        } expanded: { [weak self] in
            if let self { NotificationCard(droplet: self, notification: notification) }
        })
        if !presented { hudKey = nil }
    }

    private func checkBattery() {
        for device in devices where device.isPhone {
            guard let battery = device.battery else { continue }
            var latch = batteryLatches[device.id] ?? LowBatteryLatch()
            let alert = latch.update(level: battery.level, charging: battery.charging)
            batteryLatches[device.id] = latch
            guard alert, alertsLowBattery, let host else { continue }
            let name = device.name
            let level = battery.level
            host.hud.present(DropletHUDRequest(
                id: Self.batteryHUDID, duration: 5,
                accessibilityLabel: "\(name) battery at \(level) percent"
            ) {
                BatteryStrip(level: level)
            })
        }
    }

    // MARK: Shortcuts and URLs

    private func registerShortcuts() {
        host?.shortcuts.register(id: "ring", title: "Ring my phone", defaultShortcut: nil) { [weak self] in
            self?.ringPhone()
        }
        host?.shortcuts.register(id: "messages", title: "Show phone messages", defaultShortcut: nil) { [weak self] in
            self?.host?.shelf.open(revealing: Self.messagesWidgetID)
        }
    }

    // MARK: Live activity and lock screen

    private func publishActivity() {
        guard let media = currentMedia, media.playing.isPlaying else {
            activitySubject.send(nil)
            return
        }
        activitySubject.send(LiveActivityState(
            priority: 100,
            accessibilityTitle: "Phone playing \(media.playing.title) by \(media.playing.artist)"
        ))
    }

    private func publishLockScreen() {
        guard let phone, let battery = phone.battery else {
            lockScreenSubject.send(nil)
            return
        }
        lockScreenSubject.send(LockScreenStatusEntry(
            id: "gossip.battery",
            systemImage: BatterySymbol.name(level: battery.level, charging: battery.charging),
            text: "\(battery.level)%",
            detail: phone.name,
            roundedCenterText: "\(battery.level)",
            roundedBottomText: "Phone"
        ))
    }
}

// MARK: - Harness sample

extension GossipDroplet {
    /// For the harness: fixed data and no connection.
    public static func sample() -> GossipDroplet {
        let droplet = GossipDroplet(sample: ())
        droplet.isConnected = true
        droplet.devices = [GossipDevice(id: "pixel", name: "Pixel 9 Pro XL", type: "androidPhone", online: true,
                                        battery: .init(level: 64, charging: false))]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        droplet.notifications = [
            PhoneNotification(deviceId: "pixel", id: "1", appPackage: "com.whatsapp", appName: "WhatsApp", title: "Ana",
                              body: "¿Llegas a las 7?", iconBase64: nil, hasReply: true, timestamp: now - 60_000, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "4", appPackage: "com.whatsapp", appName: "WhatsApp", title: "Familia",
                              body: "Mamá: ya llegamos", iconBase64: nil, hasReply: true, timestamp: now - 600_000, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "2", appPackage: "com.google.android.gm", appName: "Gmail",
                              title: "Railway", body: "Your deployment succeeded", iconBase64: nil, hasReply: false,
                              timestamp: now - 3_600_000, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "3", appPackage: "com.google.android.apps.messaging",
                              appName: "Messages", title: "+503 7000 0000", body: "Tu código es 482913", iconBase64: nil,
                              hasReply: true, timestamp: now - 7_200_000, replay: nil),
        ]
        droplet.nowPlaying = ["pixel": NowPlaying(title: "Midnight City", artist: "M83", isPlaying: true, positionMs: 60_000,
                                                  durationMs: 243_000, packageName: "com.spotify.music", artworkBase64: nil)]
        let today = Date().timeIntervalSince1970
        droplet.threads = [
            MessageThread(id: "t1", phoneId: "pixel", title: "Ana", address: "+50370000001", snippet: "¿Llegas a las 7?",
                          date: today - 60, outgoing: false, unread: 1),
            MessageThread(id: "t2", phoneId: "pixel", title: "Banco", address: "2222", snippet: "Tu código es 482913",
                          date: today - 7200, outgoing: false, unread: 0),
            MessageThread(id: "t3", phoneId: "pixel", title: "Carlos", address: "+50370000002", snippet: "Va, nos vemos",
                          date: today - 90_000, outgoing: true, unread: 0),
        ]
        return droplet
    }
}

// MARK: - Surfaces

extension GossipDroplet: HUDPresenting {}

extension GossipDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.phoneWidgetID,
                title: "Phone",
                systemImage: "iphone",
                layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 210,
                                                      contentHeight: .fixed(180)),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["gossip", "android", "notifications", "battery"]
            ),
            ShelfWidgetDescriptor(
                id: Self.mediaWidgetID,
                title: "Phone media",
                systemImage: "music.note",
                layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 380, preferredPairedWidth: 210,
                                                      contentHeight: .fixed(76)),
                searchKeywords: ["gossip", "android", "music", "now playing"]
            ),
            ShelfWidgetDescriptor(
                id: Self.messagesWidgetID,
                title: "Phone messages",
                systemImage: "message",
                layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 210,
                                                      contentHeight: .fixed(300)),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["gossip", "android", "sms", "messages"]
            ),
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        switch id {
        case Self.mediaWidgetID: AnyView(MediaWidget(droplet: self, context: context))
        case Self.messagesWidgetID: AnyView(MessagesWidget(droplet: self, context: context))
        default: AnyView(PhoneWidget(droplet: self, context: context))
        }
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension GossipDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {}

    public func makeCompactLeading() -> AnyView {
        AnyView(MediaArtwork(image: currentMedia.flatMap { artwork(for: $0.deviceID) },
                             size: DroppyLiveActivityMetrics.iconSize + 5))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(
            Image(systemName: "waveform")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }

    /// Droppy does not mount it: hovering the activity opens the shelf, where the media widget has the controls.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(
            Text(currentMedia?.playing.title ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: context.availableWidth, height: DroppyLiveActivityMetrics.cardContentHeight)
        )
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView { makeCompactTrailing() }

    public func makeCompanionDetail(context: LiveActivityContext) -> AnyView? { nil }
}

extension GossipDroplet: LockScreenStatusProviding {
    public var lockScreenStatus: AnyPublisher<LockScreenStatusEntry?, Never> {
        lockScreenSubject.eraseToAnyPublisher()
    }
}

extension GossipDroplet: MenuBarExtraProviding {
    public func makeMenuBarExtra() -> MenuBarExtraDescriptor? {
        MenuBarExtraDescriptor(title: "Phone", systemImage: "iphone") { [weak self] in
            AnyView(Group { if let self { PhoneMenu(droplet: self) } })
        }
    }
}

extension GossipDroplet: DropletURLHandling {
    /// `droppy://droplet/gossip/ring`, `/mirror`, `/messages` and `/pair`, for Shortcuts, Raycast or a hotkey app.
    public func handle(_ request: DropletURLRequest) {
        switch request.path {
        case "ring": ringPhone()
        case "mirror": openInGossip("mirror")
        case "pair": openInGossip("pair")
        case "messages": host?.shelf.open(revealing: Self.messagesWidgetID)
        default: host?.log.info("unknown URL path \(request.path)")
        }
    }
}

extension GossipDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(GossipSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Phone notifications", keywords: ["gossip", "android", "mute", "hud"])]
    }
}
