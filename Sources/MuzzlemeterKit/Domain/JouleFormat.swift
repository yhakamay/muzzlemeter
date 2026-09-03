import Foundation

/// Formatting for joule values.
///
/// This used to be a fixed 2 digits (`%.2f`), but in scenes like a real capture where the
/// velocity is only a few m/s, **every row collapses to `0.00 J` and the information is
/// lost** (0.25 g at 3.0 m/s = 0.0011 J). Meanwhile, in airsoft's practical range
/// (0.5-3 J) 2 digits is exactly right. So the digit count is switched based on the
/// magnitude of the value, keeping at least 2 significant digits in every range.
///
/// Round E added the Home Screen widget, Live Activity, and the Apple Watch app, and
/// **the exact same formatting** was now needed in 3 places, so it was moved into
/// `MuzzlemeterKit` (it originally lived in `App/Muzzlemeter/Features/JouleFormat.swift`).
public enum JouleFormat {
    /// The numeric part without a unit symbol.
    public static func value(_ joules: Double) -> String {
        String(format: "%.\(fractionDigits(for: joules))f", joules)
    }

    /// Returns a value with its unit, e.g. `1.03 J`.
    public static func labeled(_ joules: Double) -> String {
        value(joules) + " J"
    }

    /// The number of decimal digits that keeps at least 2 significant digits. The
    /// practical range (0.1-10 J) stays at 2 digits as before.
    public static func fractionDigits(for joules: Double) -> Int {
        let magnitude = abs(joules)
        if magnitude == 0 { return 2 }
        if magnitude >= 100 { return 0 }
        if magnitude >= 10 { return 1 }
        if magnitude >= 0.1 { return 2 }
        if magnitude >= 0.01 { return 3 }
        return 4
    }
}
