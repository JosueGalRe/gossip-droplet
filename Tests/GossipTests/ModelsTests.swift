import Foundation
import Testing
@testable import Gossip

struct LowBatteryLatchTests {
    /// Feeds readings in order and returns which ones raised the alert.
    private func alerts(_ readings: [(level: Int, charging: Bool)]) -> [Bool] {
        var latch = LowBatteryLatch()
        return readings.map { latch.update(level: $0.level, charging: $0.charging) }
    }

    @Test func alertsOnceWhenDroppingToThreshold() {
        #expect(alerts([(40, false), (20, false), (18, false), (10, false)]) == [false, true, false, false])
    }

    @Test func rearmsAfterChargingOrClimbingAboveRearmLevel() {
        let readings: [(level: Int, charging: Bool)] = [(15, false), (16, true), (15, false), (26, false), (19, false)]
        #expect(alerts(readings) == [true, false, true, false, true])
    }

    @Test func neverAlertsWhileCharging() {
        #expect(alerts([(5, true)]) == [false])
    }
}

struct RelativeTimeTests {
    @Test func formatsShortUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RelativeTime.short(now.addingTimeInterval(-10), now: now) == "now")
        #expect(RelativeTime.short(now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(RelativeTime.short(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
        #expect(RelativeTime.short(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
        #expect(RelativeTime.short(now.addingTimeInterval(60), now: now) == "now")
    }
}
