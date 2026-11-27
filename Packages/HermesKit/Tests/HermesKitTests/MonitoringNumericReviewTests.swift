import Foundation
import Testing
@testable import HermesKit

// Run these separately on the baseline: a vulnerable conversion must not kill other regressions.
@Suite("Monitoring numeric review")
struct MonitoringNumericReviewTests {
    @Test func extremeNumericIDsNeverTrap() throws {
        for number in ["1e300", "-1e300", "9223372036854775808", "-9223372036854777856", "1.5"] {
            let value = try #require(JSONValue.parse("{\"id\":\(number)}"))
            #expect(MonitoringFlight(value).id == "?")
        }
        #expect(MonitoringFlight(.object(["id": .number(42)])).id == "42")
        #expect(MonitoringFlight(.object(["id": .number(.infinity)])).id == "?")
        #expect(MonitoringFlight(.object(["id": .number(.nan)])).id == "?")
    }

    @Test func extremeTimezoneNeverTraps() {
        #expect(MonitoringTime.timeZone(offset: "+9223372036854775807:00").secondsFromGMT() == 0)
        #expect(MonitoringTime.timeZone(offset: "-9223372036854775808:59").secondsFromGMT() == 0)
    }
}
