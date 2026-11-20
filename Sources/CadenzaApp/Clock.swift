import AppKit

/// The app's one heartbeat: every animated surface schedules its timer here
/// instead of rolling its own.
///
/// Two things this buys, both of them on the hot path. A timer block already
/// runs on the main run loop, so a call site never has to bounce through
/// `Task { @MainActor in ... }` — that used to allocate a task on every fire,
/// thirty times a second on the endless measure alone. And the timer is added
/// in common run-loop modes, so notation keeps flowing while a menu is open or
/// a glass lens is tracking the pointer.
@MainActor
enum Clock {
    /// A repeating main-actor timer. The caller keeps it and invalidates it;
    /// nothing here retains the caller.
    static func every(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
