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

struct OTPCodeTests {
    @Test func findsCodesTheTextCallsCodes() {
        #expect(OTPCode.find(in: "Tu código es 482913") == "482913")
        #expect(OTPCode.find(in: "Your verification code: 123-456") == "123456")
        #expect(OTPCode.find(in: "G-735201 is your Google verification code") == "735201")
        #expect(OTPCode.find(in: "Clave de acceso 8841. No la compartas.") == "8841")
    }

    @Test func ignoresNumbersThatAreNotCodes() {
        #expect(OTPCode.find(in: "Compra por $1,250.00 con tarjeta 4321") == nil)
        #expect(OTPCode.find(in: "Pedido 12345678 en camino") == nil)
        #expect(OTPCode.find(in: "Your code is 12") == nil)
        #expect(OTPCode.find(in: "Shopping list: 4 items, order 99881") == nil)
        #expect(OTPCode.find(in: "Código de descuento: total 1250.50") == nil)
    }
}

struct LiveInfoTests {
    @Test func fractionClampsAndNeedsAMax() {
        let live = { (progress: Int?, max: Int?) in
            LiveInfo(category: nil, progress: progress, progressMax: max, indeterminate: nil,
                     chronometerBaseMs: nil, countDown: nil, promoted: nil)
        }
        #expect(live(30, 120).fraction == 0.25)
        #expect(live(150, 100).fraction == 1)
        #expect(live(5, 0).fraction == nil)
        #expect(live(nil, nil).fraction == nil)
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
