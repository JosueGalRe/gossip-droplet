import Foundation

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
    /// Online through the internet relay rather than the local network.
    var relayed: Bool? = nil

    var isPhone: Bool { type != "mac" }
}

/// One of a notification's own buttons ("Mark as read", "Archive", "Answer"), by its index on the phone.
struct NotificationAction: Decodable, Equatable, Hashable {
    let index: Int
    let title: String
}

/// The live state of an ongoing notification: a call, a timer, a delivery or a download.
struct LiveInfo: Decodable, Equatable {
    let category: String?
    let progress: Int?
    let progressMax: Int?
    let indeterminate: Bool?
    /// Milliseconds since 1970 the chronometer counts from (or down to).
    let chronometerBaseMs: Int64?
    let countDown: Bool?
    let promoted: Bool?

    var isCall: Bool { category == "call" }

    /// 0...1 when the notification shows determinate progress.
    var fraction: Double? {
        guard let progress, let progressMax, progressMax > 0 else { return nil }
        return min(1, max(0, Double(progress) / Double(progressMax)))
    }

    var chronometerDate: Date? {
        chronometerBaseMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }
}

/// A notification a phone is mirroring.
struct PhoneNotification: Decodable, Equatable {
    let deviceId: String
    let id: String
    let appPackage: String
    let appName: String
    let title: String
    let body: String
    let iconBase64: String?
    let hasReply: Bool
    /// Android's post time, in milliseconds since 1970.
    let timestamp: Int64
    let replay: Bool?
    var avatarBase64: String? = nil
    var pictureBase64: String? = nil
    var actions: [NotificationAction]? = nil
    var smartReplies: [String]? = nil
    var live: LiveInfo? = nil

    var key: String { "\(deviceId)|\(id)" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) }
    var headline: String { title.isEmpty ? appName : title }
    var otpCode: String? { OTPCode.find(in: "\(title) \(body)") }
}

/// Finds a one-time code in a notification: 4 to 8 digits, only when the text says it is a code, so an amount, a date
/// or an order number is not offered for copying.
enum OTPCode {
    private static let keyword = #"\b(code|c[óo]digo|otp|verification|verificaci[óo]n|pin|clave|token|2fa|passcode|contrase[ñn]a)\b"#
    private static let digits = #"(?<![\d.,])(\d{3}[- ]\d{3}|\d{4,8})(?![\d.,]?\d)"#

    static func find(in text: String) -> String? {
        guard text.range(of: keyword, options: [.regularExpression, .caseInsensitive]) != nil,
              let match = text.range(of: digits, options: .regularExpression) else { return nil }
        return String(text[match]).filter(\.isNumber)
    }
}

/// One app's notifications, newest first, as the widget groups them.
struct NotificationGroup: Identifiable {
    let appPackage: String
    let appName: String
    let notifications: [PhoneNotification]

    var id: String { appPackage }
    var latest: PhoneNotification { notifications[0] }
}

/// What a phone is playing.
struct NowPlaying: Decodable, Equatable {
    let title: String
    let artist: String
    let isPlaying: Bool
    let positionMs: Int
    let durationMs: Int
    let packageName: String
    let artworkBase64: String?
}

/// A conversation in the phone's SMS app.
struct MessageThread: Decodable, Equatable, Identifiable {
    let id: String
    let phoneId: String
    let title: String
    let address: String
    let snippet: String
    /// Seconds since 1970.
    let date: Double
    let outgoing: Bool
    let unread: Int
}

/// One message in the open conversation.
struct ChatMessage: Decodable, Equatable, Identifiable {
    let id: String
    let date: Double
    let outgoing: Bool
    let body: String
    let sending: Bool
    let failed: Bool
}

enum RelativeTime {
    /// "now", "5m", "3h", "2d": short enough for a notch row.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// When the low battery HUD should show: once when the phone drops to `threshold` or below while not charging, then not
/// again until it charges or climbs back above `rearmLevel`.
struct LowBatteryLatch {
    static let threshold = 20
    static let rearmLevel = 25
    private(set) var isArmed = true

    /// Returns true when this reading should raise the alert.
    mutating func update(level: Int, charging: Bool) -> Bool {
        if charging || level > Self.rearmLevel {
            isArmed = true
            return false
        }
        guard isArmed, level <= Self.threshold else { return false }
        isArmed = false
        return true
    }
}
