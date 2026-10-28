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

    /// Home first: the phone at a glance, what is going on and what is playing. Then the notification history and the
    /// SMS conversations.
    enum Page: String, Codable, CaseIterable {
        case home, notifications, messages
    }

    @Published private(set) var page: Page = .home

    /// The page's height, so the shelf is only as tall as the page showing. Home grows a tile for something in progress
    /// and one for what is playing, and shows the latest notification when it has neither.
    var contentHeight: CGFloat {
        switch page {
        case .home:
            let tiles = (homeShowsLive ? 1 : 0) + (homeShowsMedia ? 1 : 0)
            return 16 + 24 + 8 + 62 + (tiles == 0 ? 8 + 44 : CGFloat(tiles) * 8 + (homeShowsLive ? 46 : 0) + (homeShowsMedia ? 70 : 0))
        case .notifications: return 196
        case .messages: return 280
        }
    }

    var homeShowsLive: Bool { !liveNotifications.isEmpty }
    var homeShowsMedia: Bool { currentMedia != nil }
    /// What home's height was last measured for, so the shelf is re-measured only when a tile comes or goes.
    private var measuredHome: (live: Bool, media: Bool) = (false, false)
    @Published private(set) var isConnected = false
    @Published private(set) var devices: [GossipDevice] = []
    @Published private(set) var ringing: Set<String> = []
    /// Newest first.
    @Published private(set) var notifications: [PhoneNotification] = []
    @Published private(set) var nowPlaying: [String: NowPlaying] = [:]
    @Published var replyingTo: String?
    @Published var replyText = ""
    /// The notification row opened to show its picture, buttons and suggested replies.
    @Published var expandedKey: String?

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
            publishActivity()
            publishLockScreen()
            if let first = notifications.first {
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
        // Gossip resends everything on the next connect.
        devices = []
        ringing = []
        notifications = []
        nowPlaying = [:]
        images = [:]
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
            if replyingTo == key { replyingTo = nil }
            if expandedKey == key { expandedKey = nil }
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

    // MARK: Pages

    func select(_ page: Page) {
        guard page != self.page else { return }
        self.page = page
        host?.preferences.setValue(page, forKey: "page")
        host?.shelf.invalidateLayout(for: Self.widgetID)
    }

    /// Opens the shelf on one page of the widget, alone, so it shows its full composition.
    func reveal(_ page: Page) {
        select(page)
        host?.shelf.open(revealing: Self.widgetID)
    }

    /// From the narrow card: the full widget, on the notification history with this one open.
    func open(_ notification: PhoneNotification) {
        expandedKey = notification.key
        reveal(.notifications)
    }

    /// From the narrow card: the full widget, in this conversation.
    func open(_ thread: MessageThread) {
        reveal(.messages)
        openThread(thread)
    }

    /// Home's tiles come and go with what is in progress and what is playing; re-measure the shelf when they do.
    private func homeCompositionChanged() {
        let now = (homeShowsLive, homeShowsMedia)
        guard now != measuredHome else { return }
        measuredHome = now
        if page == .home { host?.shelf.invalidateLayout(for: Self.widgetID) }
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

    func toggleExpanded(_ notification: PhoneNotification) {
        expandedKey = expandedKey == notification.key ? nil : notification.key
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

    /// Master switch: off hides the phone's notifications everywhere in the droplet.
    var showsNotifications: Bool {
        host?.preferences.value(forKey: "show", default: true) ?? true
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
        homeCompositionChanged()
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
                                        battery: .init(level: 64, charging: false))]
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

extension GossipDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(GossipSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Phone notifications", keywords: ["gossip", "android", "mute", "hud"])]
    }
}
