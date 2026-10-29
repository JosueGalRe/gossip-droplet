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
    /// The one widget, with a page per part of the phone, switched from its header like OpenChamber's.
    static let widgetID: ShelfWidgetID = "gossip"
    static let notificationHUDID = "gossip.notification"
    static let batteryHUDID = "gossip.battery"
    static let noticeHUDID = "gossip.notice"

    /// Home first: the phone at a glance, what is going on and what is playing. Then the notification history and the
    /// SMS conversations.
    enum Page: String, Codable, CaseIterable {
        case home, notifications, messages
    }

    @Published private(set) var page: Page = .home

    /// One height for every page, the height of the shelf's other tall widgets (OpenChamber's), so switching pages
    /// never resizes the shelf and the phone never stretches its neighbours. A focused notification and an open
    /// conversation are the exceptions: they grow to show what they hold.
    nonisolated static let pageHeight: CGFloat = 176
    /// The list rows (33 tall, 2 apart) that fit in `height`.
    nonisolated static func rows(fitting height: CGFloat) -> Int { max(0, Int((height + 2) / 35)) }

    /// A narrow list's rows in `height`: all of them when they fit, else as many as leave room for See all (18).
    nonisolated static func listRows(_ count: Int, fitting height: CGFloat) -> (rows: Int, seeAll: Bool) {
        if count <= rows(fitting: height) { return (count, false) }
        return (max(1, rows(fitting: height - 18)), true)
    }
    static let conversationHeight: CGFloat = 280

    var contentHeight: CGFloat {
        if page == .notifications, let focused = focusedNotification {
            return max(Self.pageHeight, FocusedNotification.height(for: focused, picture: picture(for: focused)))
        }
        return page == .messages && openThreadID != nil ? Self.conversationHeight : Self.pageHeight
    }

    var homeShowsLive: Bool { !liveNotifications.isEmpty }
    var homeShowsMedia: Bool { currentMedia != nil }
    @Published private(set) var isConnected = false
    @Published private(set) var devices: [GossipDevice] = []
    @Published private(set) var ringing: Set<String> = []
    /// Newest first.
    @Published private(set) var notifications: [PhoneNotification] = []
    @Published private(set) var nowPlaying: [String: NowPlaying] = [:]
    @Published var replyText = ""
    /// The notification shown on its own, in place of the list: all of it, its picture, its buttons, a reply field.
    @Published private(set) var focusedKey: String?

    var focusedNotification: PhoneNotification? {
        focusedKey.flatMap { key in notifications.first { $0.key == key } }
    }

    @Published private(set) var threads: [MessageThread] = []
    @Published private(set) var openThreadID: String?
    @Published private(set) var conversation: [ChatMessage] = []
    @Published private(set) var messagesError: String?
    @Published private(set) var messagesLoading = false
    @Published var composeText = ""

    private var host: DropletHost?
    private var client: BridgeClient?
    /// Decoded icons, avatars and pictures, by notification key and kind.
    private var images: [String: [String: NSImage]] = [:]
    private var artwork: [String: NSImage] = [:]
    /// When each device's now-playing state arrived, to advance its position while it plays.
    private var mediaReceivedAt: [String: Date] = [:]
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
        if !isSample { page = host.preferences.value(forKey: "page", default: Page.home) }
        registerShortcuts()
        guard !isSample else {
            // So the harness's surfaces have something to draw.
            setMuted("com.zhiliaoapp.musically", true)
            setMuted("com.pizzahut.sv", true)
            setHidden("com.pizzahut.sv", true)
            publishActivity()
            publishLockScreen()
            if ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_HUD"] == "clipboard" {
                presentNotice(symbol: "doc.on.clipboard", title: "Copied from Pixel 9 Pro XL",
                              detail: "https://maps.app.goo.gl/x7Yq2 — nos vemos en la entrada de Multiplaza a las 7",
                              image: nil, duration: nil)
            } else if let first = notifications.first {
                announce(first)
                if ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_HUD_OPEN"] != nil { toggleHUDExpanded() }
            }
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
        if hudNotification != nil { host?.hud.dismiss(id: Self.notificationHUDID) }
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
        appsRequested = false
        hotspotRequested = nil
        // Gossip resends everything on the next connect.
        devices = []
        ringing = []
        notifications = []
        nowPlaying = [:]
        images = [:]
        artwork = [:]
        focusedKey = nil
        publishActivity()
        publishLockScreen()
    }

    private struct Kind: Decodable { let type: String }
    private struct State: Decodable {
        let devices: [GossipDevice]
        let ringing: [String]?
    }
    private struct ClipboardCopy: Decodable {
        let deviceId: String
        let text: String?
        let image: String?
    }
    private struct BridgeError: Decodable { let message: String }
    private struct HotspotResult: Decodable { let ok: Bool }
    private struct Removed: Decodable {
        let deviceId: String
        let id: String
    }
    private struct Media: Decodable {
        let deviceId: String
        let nowPlaying: NowPlaying?
    }
    private struct Threads: Decodable { let threads: [MessageThread] }
    private struct Apps: Decodable {
        let apps: [PhoneApp]
        let error: String?
    }
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
            // The phone's apps once per connection, for "Open on Mac" and the app menu; Gossip has them cached.
            if !appsRequested, let phone {
                appsRequested = true
                client?.send(["type": "apps", "deviceId": phone.id])
            }
            checkBattery()
            publishLockScreen()
        case "notification.posted":
            guard let posted = try? decoder.decode(PhoneNotification.self, from: line) else { return }
            let previous = notifications.first { $0.key == posted.key }
            notifications.removeAll { $0.key == posted.key }
            notifications.append(posted)
            notifications.sort { $0.timestamp > $1.timestamp }
            images[posted.key] = nil
            rememberApp(package: posted.appPackage, name: posted.appName)
            publishActivity()
            guard posted.replay != true else { return }
            if let live = posted.live {
                // A call rings in the notch until answered or gone; other live updates only move the live activity.
                if live.isCall, previous == nil || previous?.live?.chronometerBaseMs != live.chronometerBaseMs { announceCall(posted) }
            } else if previous == nil || previous?.title != posted.title || previous?.body != posted.body {
                // An update that only adds suggestions or changes nothing visible is not news.
                announce(posted)
            } else if hudNotification?.key == posted.key {
                // Same text, new suggestions or buttons: refresh the card in place without announcing again.
                hudNotification = posted
                presentNotificationHUD()
            }
        case "notification.removed":
            guard let removed = try? decoder.decode(Removed.self, from: line) else { return }
            let key = "\(removed.deviceId)|\(removed.id)"
            notifications.removeAll { $0.key == key }
            images[key] = nil
            // Gone from the phone (read or dismissed there): back to the list.
            if focusedKey == key { unfocus() }
            // Gone from the phone (read or dismissed there): the card goes too, held or not.
            if hudNotification?.key == key { closeHUD() }
            if callHUDKey == key {
                callHUDKey = nil
                host?.hud.dismiss(id: Self.callHUDID)
            }
            publishActivity()
        case "media":
            guard let media = try? decoder.decode(Media.self, from: line) else { return }
            if let playing = media.nowPlaying {
                // Gossip sends artwork only when it changed; keep the last one otherwise.
                if let base64 = playing.artworkBase64, let data = Data(base64Encoded: base64) {
                    artwork[media.deviceId] = NSImage(data: data)
                }
                nowPlaying[media.deviceId] = playing
                mediaReceivedAt[media.deviceId] = Date()
            } else {
                nowPlaying[media.deviceId] = nil
                artwork[media.deviceId] = nil
                mediaReceivedAt[media.deviceId] = nil
            }
            publishActivity()
        case "messages.threads":
            if let list = try? decoder.decode(Threads.self, from: line) { threads = list.threads }
        case "apps":
            guard let list = try? decoder.decode(Apps.self, from: line) else { return }
            // Icons follow the list in batches; each one is decoded once.
            for app in list.apps where appIcons[app.package] == nil {
                if let base64 = app.icon, let data = Data(base64Encoded: base64) { appIcons[app.package] = NSImage(data: data) }
            }
            phoneAppsError = list.error
            if list.error == nil { phoneApps = list.apps }
        case "messages.history":
            guard let history = try? decoder.decode(History.self, from: line), history.threadId == openThreadID else { return }
            conversation = history.messages
        case "clipboard":
            guard alertsClipboard, let copy = try? decoder.decode(ClipboardCopy.self, from: line) else { return }
            let name = devices.first { $0.id == copy.deviceId }?.name ?? "phone"
            let image = copy.image.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            presentNotice(symbol: "doc.on.clipboard", title: "Copied from \(name)", detail: copy.text, image: image)
        case "error":
            guard let error = try? decoder.decode(BridgeError.self, from: line) else { return }
            host?.feedback.play(.failure)
            presentNotice(symbol: "exclamationmark.triangle", title: "Gossip", detail: error.message, image: nil)
        case "hotspot.result":
            guard let result = try? decoder.decode(HotspotResult.self, from: line) else { return }
            hotspotRequested = nil
            host?.feedback.play(result.ok ? .success : .failure)
        case "messages.status":
            guard let status = try? decoder.decode(MessagesStatus.self, from: line) else { return }
            messagesLoading = status.loading
            messagesError = status.error
        default:
            break
        }
    }

    // MARK: Pages

    func select(_ page: Page) {
        guard page != self.page else { return }
        if focusedKey != nil { unfocus() }
        let height = contentHeight
        self.page = page
        host?.preferences.setValue(page, forKey: "page")
        // Away from or back to an open conversation.
        if contentHeight != height { host?.shelf.invalidateLayout(for: Self.widgetID) }
    }

    /// Opens the shelf on one page of the widget, alone, so it shows its full composition.
    func reveal(_ page: Page) {
        select(page)
        host?.shelf.open(revealing: Self.widgetID)
    }

    /// The full widget with this notification on its own (from the list, the narrow card, home or the notch).
    func open(_ notification: PhoneNotification) {
        replyText = ""
        select(.notifications)
        focusedKey = notification.key
        host?.shelf.invalidateLayout(for: Self.widgetID)
        host?.shelf.open(revealing: Self.widgetID)
        if notification.hasReply { host?.shelf.requestKeyboardFocus() }
    }

    /// Back to the list, at the page's usual height.
    func unfocus() {
        focusedKey = nil
        replyText = ""
        host?.shelf.invalidateLayout(for: Self.widgetID)
    }

    /// From the narrow card: the full widget, in this conversation.
    func open(_ thread: MessageThread) {
        reveal(.messages)
        openThread(thread)
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

    /// What the widget lists: every notification of an app the user shows, the live ones apart.
    var visibleNotifications: [PhoneNotification] {
        guard showsNotifications else { return [] }
        let hidden = hiddenApps
        return notifications.filter { !hidden.contains($0.appPackage) }
    }

    var liveNotifications: [PhoneNotification] {
        visibleNotifications.filter { $0.live != nil }.sorted { ($0.live?.isCall == true ? 0 : 1) < ($1.live?.isCall == true ? 0 : 1) }
    }

    /// Grouped by app, the app with the newest notification first.
    var notificationGroups: [NotificationGroup] {
        var order: [String] = []
        var byApp: [String: [PhoneNotification]] = [:]
        for notification in visibleNotifications where notification.live == nil {
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
        open(notification)
    }

    /// Sends what is in the focused notification's reply field, then goes back to the list.
    func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let notification = focusedNotification else { return }
        client?.send(["type": "reply", "deviceId": notification.deviceId, "id": notification.id, "text": text])
        host?.feedback.play(.success)
        unfocus()
    }

    func revealNotifications() {
        closeHUD()
        reveal(.notifications)
    }

    func icon(for notification: PhoneNotification) -> NSImage? { image(notification, "icon", notification.iconBase64) }
    func avatar(for notification: PhoneNotification) -> NSImage? { image(notification, "avatar", notification.avatarBase64) }
    func picture(for notification: PhoneNotification) -> NSImage? { image(notification, "picture", notification.pictureBase64) }

    private func image(_ notification: PhoneNotification, _ kind: String, _ base64: String?) -> NSImage? {
        if let cached = images[notification.key]?[kind] { return cached }
        guard let base64, let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        images[notification.key, default: [:]][kind] = image
        return image
    }

    func perform(_ action: NotificationAction, on notification: PhoneNotification) {
        client?.send(["type": "action", "deviceId": notification.deviceId, "id": notification.id, "index": action.index])
        host?.feedback.play(.success)
        if hudNotification?.key == notification.key { closeHUD() }
    }

    /// Sends a suggested reply as it is.
    func quickReply(_ text: String, to notification: PhoneNotification) {
        client?.send(["type": "reply", "deviceId": notification.deviceId, "id": notification.id, "text": text])
        host?.feedback.play(.success)
        if hudNotification?.key == notification.key { closeHUD() }
    }

    func copyCode(_ code: String) {
        if host?.workspace.copyToPasteboard(code) == true { host?.feedback.play(.success) }
    }



    // MARK: Media

    /// The phone's session, playing ones first.
    var currentMedia: (deviceID: String, playing: NowPlaying)? {
        // An app that keeps its media session open after it stops has no song to show: no tile, no player, no activity.
        let sessions = nowPlaying.filter { !$0.value.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.key < $1.key }
        let pick = sessions.first { $0.value.isPlaying } ?? sessions.first
        return pick.map { ($0.key, $0.value) }
    }

    func artwork(for deviceID: String) -> NSImage? { artwork[deviceID] }

    func media(_ action: String) {
        client?.send(["type": "media", "action": action])
    }

    /// Where playback is now: the last reported position, advanced by the time since while it plays.
    func mediaPosition(at date: Date = Date()) -> Int {
        guard let media = currentMedia else { return 0 }
        var position = media.playing.positionMs
        if media.playing.isPlaying, let received = mediaReceivedAt[media.deviceID] {
            position += Int(date.timeIntervalSince(received) * 1000)
        }
        return media.playing.durationMs > 0 ? min(position, media.playing.durationMs) : position
    }

    func seek(toFraction fraction: Double) {
        guard let media = currentMedia, media.playing.durationMs > 0 else { return }
        let ms = Int(Double(media.playing.durationMs) * min(1, max(0, fraction)))
        client?.send(["type": "media", "action": media.playing.isPlaying ? "play" : "pause", "seekMs": ms])
    }

    func volume(up: Bool) {
        client?.send(["type": "volume", "direction": up ? "up" : "down"])
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
        let height = contentHeight
        openThreadID = thread?.id
        conversation = []
        composeText = ""
        if contentHeight != height { host?.shelf.invalidateLayout(for: Self.widgetID) }
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

    /// Master switch: off hides the phone's notifications everywhere in the droplet.
    var showsNotifications: Bool {
        host?.preferences.value(forKey: "show", default: true) ?? true
    }

    // MARK: Phone controls

    /// Opens one of the phone's apps in its own Mac window (Gossip, over Shizuku), and gets the shelf out of its way.
    func openOnMac(_ package: String) {
        guard let phone else { return }
        client?.send(["type": "app.open", "deviceId": phone.id, "package": package])
        host?.shelf.close()
    }

    /// Whether the app has a launcher icon on the phone, so it can open as a window.
    func canOpenOnMac(_ package: String) -> Bool {
        phoneApps?.contains { $0.package == package } ?? false
    }

    /// The phone's apps that have notified most recently, for the top of the app menu.
    var recentApps: [PhoneApp] {
        var seen = Set<String>()
        return notifications.compactMap { notification in
            guard seen.insert(notification.appPackage).inserted else { return nil }
            return phoneApps?.first { $0.package == notification.appPackage }
        }
        .prefix(6).map { $0 }
    }

    /// An app's icon at menu size.
    func menuIcon(_ package: String) -> NSImage? {
        if let cached = menuIcons[package] { return cached }
        guard let icon = appIcons[package] else { return nil }
        let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        menuIcons[package] = small
        return small
    }

    private var menuIcons: [String: NSImage] = [:]
    private var appsRequested = false

    func setPhoneDND(_ enabled: Bool) {
        guard let phone else { return }
        client?.send(["type": "dnd", "deviceId": phone.id, "enabled": enabled])
    }

    /// The hotspot state asked for and not yet confirmed; the button waits on it.
    @Published private(set) var hotspotRequested: Bool?

    func toggleHotspot() {
        guard let phone, let hotspot = phone.hotspot, hotspotRequested == nil else { return }
        let enable = !hotspot.enabled
        hotspotRequested = enable
        client?.send(["type": "hotspot", "deviceId": phone.id, "enabled": enable])
        // Bluetooth can fail without an answer; the button comes back either way.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            if self?.hotspotRequested == enable { self?.hotspotRequested = nil }
        }
    }

    /// A short card in the notch: what happened, a line or two of detail, a picture.
    private func presentNotice(symbol: String, title: String, detail: String?, image: NSImage?, duration: TimeInterval? = 4) {
        guard let host else { return }
        host.hud.present(DropletHUDRequest(
            id: Self.noticeHUDID, duration: duration,
            accessibilityLabel: [title, detail].compactMap { $0 }.joined(separator: ": "),
            isExpanded: true, expandedContentHeight: NoticeCard.height(detail: detail, image: image)
        ) {
            NoticeStrip(symbol: symbol)
        } expanded: {
            NoticeCard(symbol: symbol, title: title, detail: detail, image: image)
        })
    }

    // MARK: Apps

    /// The phone's launchable apps, `nil` until Gossip answers.
    @Published private(set) var phoneApps: [PhoneApp]?
    @Published private(set) var phoneAppsError: String?
    private(set) var appIcons: [String: NSImage] = [:]
    @Published var appQuery = ""
    private var appsViewers = 0

    /// The settings and the apps page ask the phone for a fresh list when they open; Gossip keeps sending changes
    /// (new icons, apps installed or removed) for the rest of the connection.
    func appsVisible(_ visible: Bool) {
        appsViewers = max(0, appsViewers + (visible ? 1 : -1))
        if visible, appsViewers == 1, let phone {
            client?.send(["type": "apps", "deviceId": phone.id])
        } else if !visible, appsViewers == 0 {
            appQuery = ""
        }
    }

    /// Every app the settings can name: the phone's launchable ones, and those without a launcher icon (system apps)
    /// that have shown a notification.
    var allApps: [(package: String, name: String)] {
        var names = knownApps
        for app in phoneApps ?? [] { names[app.package] = app.label }
        return names.map { (package: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func appName(_ package: String) -> String {
        phoneApps?.first { $0.package == package }?.label ?? knownApps[package] ?? package
    }

    /// The apps that do not announce: quiet in the widget only, or hidden from it too. Every other app announces.
    var appExceptions: [String] {
        mutedApps.union(hiddenApps).sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    var mutedApps: Set<String> {
        Set(host?.preferences.value(forKey: "mutedApps", as: [String].self) ?? [])
    }

    var hiddenApps: Set<String> {
        Set(host?.preferences.value(forKey: "hiddenApps", as: [String].self) ?? [])
    }

    func isHidden(_ package: String) -> Bool { hiddenApps.contains(package) }

    func setHidden(_ package: String, _ hidden: Bool) {
        var list = hiddenApps
        if hidden { list.insert(package) } else { list.remove(package) }
        setPreference(list.sorted(), forKey: "hiddenApps")
    }

    /// Announcements stay quiet until this moment.
    var announcementsPausedUntil: Date? {
        let seconds = host?.preferences.value(forKey: "pausedUntil", default: 0.0) ?? 0
        let date = Date(timeIntervalSince1970: seconds)
        return date > Date() ? date : nil
    }

    func pauseAnnouncements(for interval: TimeInterval?) {
        setPreference(interval.map { Date().addingTimeInterval($0).timeIntervalSince1970 } ?? 0, forKey: "pausedUntil")
    }

    var hudDuration: Double {
        host?.preferences.value(forKey: "hudDuration", default: 6.0) ?? 6
    }

    /// A HUD each time the phone's clipboard lands on the Mac.
    var alertsClipboard: Bool {
        host?.preferences.value(forKey: "clipboardAlerts", default: true) ?? true
    }

    var alertsLowBattery: Bool {
        host?.preferences.value(forKey: "lowBattery", default: true) ?? true
    }

    /// Apps the phone has shown notifications from, package to name, so the settings can mute each one.
    var knownApps: [String: String] {
        host?.preferences.value(forKey: "knownApps", as: [String: String].self) ?? [:]
    }

    func isMuted(_ package: String) -> Bool { mutedApps.contains(package) }

    func setMuted(_ package: String, _ muted: Bool) {
        var list = mutedApps
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

    /// The notification on the card in the notch, and whether the user holds it there: clicked open, or under the
    /// pointer. A held card is never replaced by a newer notification; those go to the widget and are counted on it.
    private var hudNotification: PhoneNotification?
    @Published private(set) var hudExpanded = false
    @Published private(set) var hudHovered = false
    @Published private(set) var arrivedWhileHeld = 0
    /// When the hold last changed. The host can take the card away (another surface claims the notch) without the
    /// hover ever ending, so a hold this old no longer holds back announcements.
    private var heldSince = Date.distantPast

    private var hudHeld: Bool {
        guard hudNotification != nil, hudExpanded || hudHovered else { return false }
        return Date().timeIntervalSince(heldSince) < (hudExpanded ? 30 * 60 : 2 * 60)
    }

    private func announce(_ notification: PhoneNotification) {
        guard host != nil, showsNotifications, announcesNotifications, announcementsPausedUntil == nil,
              !isMuted(notification.appPackage), !isHidden(notification.appPackage) else { return }
        if hudHeld, hudNotification?.key != notification.key {
            arrivedWhileHeld += 1
            return
        }
        if hudNotification?.key != notification.key {
            hudExpanded = false
            hudHovered = false
            arrivedWhileHeld = 0
        }
        hudNotification = notification
        presentNotificationHUD()
    }

    /// Presents, or updates in place, the card for the current notification in its current shape: compact with a
    /// timer, or open (clicked, or under the pointer) until closed.
    private func presentNotificationHUD(timer: TimeInterval? = nil) {
        guard let host, let notification = hudNotification else { return }
        let expanded = hudExpanded
        let layout = NotificationCard.layout(for: notification, geometry: host.environment.notchGeometry,
                                             picture: picture(for: notification), expanded: expanded)
        // A longer message stays up a little longer: a second more per line past two, at most six.
        let duration: TimeInterval? = expanded || hudHovered
            ? nil : timer ?? hudDuration + Double(min(6, max(0, layout.measuredLines - 2)))
        let presented = host.hud.present(DropletHUDRequest(
            id: Self.notificationHUDID, duration: duration,
            accessibilityLabel: "\(notification.appName): \(notification.headline)",
            isExpanded: true, expandedContentHeight: layout.height
        ) { [weak self] in
            if let self { NotificationStrip(droplet: self, notification: notification) }
        } expanded: { [weak self] in
            if let self { NotificationCard(droplet: self, notification: notification, layout: layout, expanded: expanded) }
        })
        if !presented { clearHUD() }
    }

    /// A click on the card opens it (all the text, the picture large, every button) and keeps it until closed; a click
    /// on the open card folds it back with a few seconds left.
    func toggleHUDExpanded() {
        guard hudNotification != nil else { return }
        hudExpanded.toggle()
        heldSince = Date()
        if !hudExpanded { arrivedWhileHeld = 0 }
        presentNotificationHUD(timer: 4)
    }

    /// Under the pointer the card does not time out; leaving gives it a few more seconds.
    func hudHover(_ inside: Bool) {
        guard hudNotification != nil, hudHovered != inside else { return }
        hudHovered = inside
        heldSince = Date()
        if !hudExpanded { presentNotificationHUD(timer: 3) }
    }

    /// Takes the card down and leaves the notification on the phone.
    func closeHUD() {
        if hudNotification != nil { host?.hud.dismiss(id: Self.notificationHUDID) }
        clearHUD()
    }

    private func clearHUD() {
        hudNotification = nil
        hudExpanded = false
        hudHovered = false
        arrivedWhileHeld = 0
    }

    static let callHUDID = "gossip.call"
    private var callHUDKey: String?

    /// A ringing call stays in the notch until it is answered, declined or gone; one in progress shows its duration.
    private func announceCall(_ notification: PhoneNotification) {
        guard let host, showsNotifications, !isHidden(notification.appPackage) else { return }
        callHUDKey = notification.key
        let ringing = notification.live?.chronometerDate == nil
        host.hud.present(DropletHUDRequest(
            id: Self.callHUDID, duration: ringing ? nil : 4, priority: .high,
            accessibilityLabel: "Call: \(notification.headline)",
            isExpanded: true, expandedContentHeight: 66
        ) { [weak self] in
            if let self { NotificationStrip(droplet: self, notification: notification) }
        } expanded: { [weak self] in
            if let self { CallCard(droplet: self, notification: notification) }
        })
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
            self?.reveal(.messages)
        }
    }

    // MARK: Live activity and lock screen

    /// What the compact activity shows: a call or another live notification first, else the playing media.
    enum ActivitySubject {
        case live(PhoneNotification)
        case media(deviceID: String, playing: NowPlaying)
    }

    var activityFocus: ActivitySubject? {
        if let live = liveNotifications.first { return .live(live) }
        if let media = currentMedia, media.playing.isPlaying { return .media(deviceID: media.deviceID, playing: media.playing) }
        return nil
    }

    private func publishActivity() {
        switch activityFocus {
        case .live(let notification):
            activitySubject.send(LiveActivityState(
                priority: notification.live?.isCall == true ? 300 : 200,
                accessibilityTitle: "\(notification.appName): \(notification.headline)"
            ))
        case .media(_, let playing):
            activitySubject.send(LiveActivityState(
                priority: 100,
                accessibilityTitle: "Phone playing \(playing.title) by \(playing.artist)"
            ))
        case nil:
            activitySubject.send(nil)
        }
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
        // `GOSSIP_SAMPLE_PAGE=messages droppykit run …` shoots another page.
        droplet.page = ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_PAGE"].flatMap(Page.init(rawValue:)) ?? .home
        let sampleHUD = ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_HUD"]
        let hudFirst = sampleHUD == "link" || sampleHUD == "long"
        let sampleBody = sampleHUD == "long"
            ? "Oigan, para el sábado: llego a las 3 con las sillas y el proyector. Alguien puede llevar el HDMI largo? "
                + "Diego dijo que traía las bocinas pero no confirmó. Si no, uso las mías. También falta definir quién "
                + "trae comida, yo puedo pasar por pupusas de camino si me dicen cuántas."
            : "🔗 Bill Fanter on Instagram (www.instagram.com/reel/DQx4abcdEfGhIjk/?igsh=MTRmZ2x0)"
        droplet.devices = [GossipDevice(id: "pixel", name: "Pixel 9 Pro XL", type: "androidPhone", online: true,
                                        battery: .init(level: 64, charging: false), dnd: true,
                                        hotspot: .init(enabled: false, ssid: nil))]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        droplet.notifications = [
            PhoneNotification(deviceId: "pixel", id: "1", appPackage: "com.whatsapp", appName: "WhatsApp", title: "Ana",
                              body: "¿Llegas a las 7?", iconBase64: nil, hasReply: true, timestamp: now - 60_000, replay: nil,
                              actions: [NotificationAction(index: 1, title: "Mark as read")],
                              smartReplies: ["Sí, ahí estaré", "Voy tarde", "👍"]),
            PhoneNotification(deviceId: "pixel", id: "5", appPackage: "com.ubercab.eats", appName: "Uber Eats",
                              title: "Tu pedido va en camino", body: "Llega en 8 min", iconBase64: nil, hasReply: false,
                              timestamp: now - 120_000, replay: nil,
                              live: LiveInfo(category: "progress", progress: 60, progressMax: 100, indeterminate: false,
                                             chronometerBaseMs: nil, countDown: false, promoted: true)),
            PhoneNotification(deviceId: "pixel", id: "4", appPackage: "com.whatsapp", appName: "WhatsApp", title: "Familia",
                              body: "Mamá: ya llegamos", iconBase64: nil, hasReply: true, timestamp: now - 600_000, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "2", appPackage: "com.google.android.gm", appName: "Gmail",
                              title: "Railway", body: "Your deployment succeeded", iconBase64: nil, hasReply: false,
                              timestamp: now - 3_600_000, replay: nil),
            PhoneNotification(deviceId: "pixel", id: "3", appPackage: "com.google.android.apps.messaging",
                              appName: "Messages", title: "+503 7000 0000", body: "Tu código es 482913", iconBase64: nil,
                              hasReply: true, timestamp: now - 7_200_000, replay: nil),
        ]
        if hudFirst {
            droplet.notifications.insert(PhoneNotification(
                deviceId: "pixel", id: "6", appPackage: "com.whatsapp", appName: "WhatsApp", title: "Grupo del viernes: Diego Hernández",
                body: sampleBody, iconBase64: nil,
                hasReply: true, timestamp: now, replay: nil, actions: [NotificationAction(index: 1, title: "Mark as read"),
                                                                     NotificationAction(index: 2, title: "Mute")]), at: 0)
        }
        droplet.nowPlaying = ["pixel": NowPlaying(title: "Midnight City", artist: "M83", isPlaying: true, positionMs: 60_000,
                                                  durationMs: 243_000, packageName: "com.spotify.music", artworkBase64: nil)]
        if ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_NOSONG"] != nil {
            // A media session left open with no song: home shows no player.
            droplet.nowPlaying = ["pixel": NowPlaying(title: "", artist: "", isPlaying: false, positionMs: 0,
                                                      durationMs: 0, packageName: "com.spotify.music", artworkBase64: nil)]
        }
        if ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_FOCUS"] != nil, !droplet.notifications.isEmpty {
            // A portrait picture, like a sticker, on the first notification, shown on its own.
            let image = NSImage(size: NSSize(width: 300, height: 380), flipped: false) { rect in
                NSGradient(starting: .systemPink, ending: .systemIndigo)?.draw(in: rect, angle: 60)
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                droplet.notifications[0].pictureBase64 = png.base64EncodedString()
            }
            droplet.page = .notifications
            droplet.focusedKey = droplet.notifications[0].key
        }
        let apps = [("com.anthropic.claude", "Claude", NSColor.systemOrange), ("com.google.android.gm", "Gmail", .systemRed),
                    ("com.pizzahut.sv", "Pizza Hut El Salvador", .systemRed), ("com.Slack", "Slack", .systemPurple),
                    ("org.telegram.messenger", "Telegram", .systemBlue), ("com.zhiliaoapp.musically", "TikTok", .black),
                    ("com.whatsapp", "WhatsApp", .systemGreen)]
        droplet.phoneApps = apps.map { PhoneApp(package: $0.0, label: $0.1, icon: nil) }
        for (package, _, color) in apps {
            droplet.appIcons[package] = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
        }
        if ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_QUIET"] != nil {
            // Nothing in progress and nothing playing: home fills with the latest notifications.
            droplet.notifications.removeAll { $0.live != nil }
            droplet.nowPlaying = [:]
        }
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
                id: Self.widgetID,
                title: "Phone",
                systemImage: "iphone",
                layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 220,
                                                      contentHeight: .fixed(contentHeight)),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["gossip", "android", "notifications", "battery", "sms", "messages", "music"]
            ),
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(PhoneWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension GossipDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {}

    public func makeCompactLeading() -> AnyView { AnyView(ActivityLeading(droplet: self)) }

    public func makeCompactTrailing() -> AnyView { AnyView(ActivityTrailing(droplet: self)) }

    /// Droppy does not mount it: hovering the activity opens the shelf, where the media widget has the controls.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(
            Text(activityTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(width: context.availableWidth, height: DroppyLiveActivityMetrics.cardContentHeight)
        )
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView { makeCompactTrailing() }

    private var activityTitle: String {
        switch activityFocus {
        case .live(let notification): notification.headline
        case .media(_, let playing): playing.title
        case nil: ""
        }
    }

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
        case "messages": reveal(.messages)
        default: host?.log.info("unknown URL path \(request.path)")
        }
    }
}

extension GossipDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        // The harness draws no pages of a pane: GOSSIP_SAMPLE_SETTINGS=apps draws the apps page in its place.
        if isSample, ProcessInfo.processInfo.environment["GOSSIP_SAMPLE_SETTINGS"] == AppsPage.id {
            return AnyView(AppsPage(droplet: self))
        }
        return AnyView(GossipSettings(droplet: self))
    }

    public func makeSettingsPage(id: String, context: SettingsPaneContext) -> AnyView? {
        id == AppsPage.id ? AnyView(AppsPage(droplet: self)) : nil
    }

    public func makeSettingsPageToolbar(id: String, context: SettingsPaneContext) -> AnyView? {
        id == AppsPage.id ? AnyView(AppsPage.Toolbar(droplet: self)) : nil
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Phone notifications", keywords: ["gossip", "android", "mute", "hud"])]
    }
}

/// What a page has under the widget's header, as measured in [PhoneWidget]: the room the lists and home fill.
private struct PageBodyHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = GossipDroplet.pageHeight - 48
}

extension EnvironmentValues {
    var pageBodyHeight: CGFloat {
        get { self[PageBodyHeightKey.self] }
        set { self[PageBodyHeightKey.self] = newValue }
    }
}
