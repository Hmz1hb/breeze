import Darwin
import Foundation
import Testing
@testable import FanCore

@Test func uptimeIncludesSleepAndAgreesWithTheBootTimestamp() {
    let awake = ProcessInfo.processInfo.systemUptime
    let elapsed = SystemUptime.sinceBoot
    #expect(elapsed > 0)
    #expect(elapsed >= awake)
    // Compare with an independent wall-clock source when the environment permits it.
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
        let bootDate = TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
        let sinceBoot = Date().timeIntervalSince1970 - bootDate
        #expect(abs(elapsed - sinceBoot) < 5)
    }
    print("Uptime including sleep: \(Int(elapsed / 86400)) days, \(Int(elapsed / 3600) % 24) hours; awake only: \(Int(awake / 86400)) days, \(Int(awake / 3600) % 24) hours")
}
