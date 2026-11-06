import Foundation

public enum WriteVerification {
    /// Firmware may acknowledge a write before it applies it. Retry only during activation/restoration.
    /// Once active, the watchdog relinquishes control rather than reasserting a contested target.
    public static func apply(attempts: Int, write: () throws -> Void,
                             matches: () -> Bool, pause: () -> Void) throws {
        guard attempts > 0 else { throw FanError("No write attempts were allowed.") }
        var failure: (any Error)?
        for _ in 0..<attempts {
            do { try write(); failure = nil }
            catch { failure = error }
            pause()
            if matches() { return }
        }
        throw failure ?? FanError("macOS did not retain the requested fan setting.")
    }
}
