import SwiftUI

// MARK: - StratusAnimation

// Centralised animation constants for the Stratus design system.
//
// All values automatically degrade to `.default` (a minimal, near-instant
// animation) when the user has enabled Reduce Motion either via macOS
// System Settings → Accessibility or via the in-app override stored in
// @AppStorage("reduceMotion").
//
// Usage in a View:
//   .animation(StratusAnimation.rowAppear, value: isVisible)
//   // or via the reducedMotionAnimation helper from Accessibility.swift:
//   .reducedMotionAnimation(StratusAnimation.progressSmooth, value: progress)

public enum StratusAnimation {
    // MARK: - Token Definitions

    /// Fade + slide for list row insertion (150 ms ease-out).
    public static let rowAppear: Animation = reduced(
        full: .easeOut(duration: 0.15),
        reduced: .default
    )

    /// Fade + slide for list row removal (120 ms ease-in).
    public static let rowDisappear: Animation = reduced(
        full: .easeIn(duration: 0.12),
        reduced: .default
    )

    /// Smooth linear interpolation for progress bars / rings (200 ms ease-in-out).
    public static let progressSmooth: Animation = reduced(
        full: .easeInOut(duration: 0.20),
        reduced: .linear(duration: 0.05)
    )

    /// Spring animation for panel slide-in / slide-out.
    /// Response 0.38 s, damping fraction 0.82 – feels snappy without bouncing.
    public static let panelToggle: Animation = reduced(
        full: .spring(response: 0.38, dampingFraction: 0.82),
        reduced: .default
    )

    /// Horizontal shake for error states (uses a spring with low damping).
    /// Apply with a `Bool` toggle value; caller drives the shake by flipping
    /// the value true then back to false after a short delay.
    public static let errorShake: Animation = reduced(
        full: .spring(response: 0.25, dampingFraction: 0.35),
        reduced: .default
    )

    // MARK: - Private Helpers

    /// Returns `full` unless Reduce Motion is active (system or in-app override),
    /// in which case it returns `fallback`.
    ///
    /// Checked at call-site rather than at animation runtime, so the returned
    /// `Animation` value is stable for a given app launch / accessibility state.
    /// Views that need per-render checking should use `reducedMotionAnimation(_:value:)`
    /// from `Accessibility.swift` instead.
    private static func reduced(full: Animation, reduced fallback: Animation) -> Animation {
        isReduceMotionEnabled ? fallback : full
    }

    /// Reads the current Reduce Motion preference from both the system
    /// accessibility flag and the in-app @AppStorage override.
    ///
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is the
    /// authoritative system value. The user-facing toggle in Preferences writes
    /// to UserDefaults under the key "reduceMotion".
    private static var isReduceMotionEnabled: Bool {
        let systemPreference = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let appOverride = UserDefaults.standard.bool(forKey: "reduceMotion")
        return systemPreference || appOverride
    }
}

// MARK: - ViewModifier: ShakeEffect

// Drives the errorShake animation. Usage:
//   .modifier(ShakeEffect(trigger: hasError))

public struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 6
    var shakes: CGFloat = 3
    var trigger: Bool

    /// GeometryEffect requires an animatable data value to drive the shake.
    public var animatableData: CGFloat {
        get { trigger ? 1 : 0 }
        set { _ = newValue }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        guard animatableData > 0 else { return .init() }
        let phase = sin(animatableData * .pi * shakes)
        return .init(CGAffineTransform(translationX: phase * amount, y: 0))
    }
}

public extension View {
    /// Applies the standard Stratus error-shake animation when `trigger` is `true`.
    func stratusErrorShake(trigger: Bool) -> some View {
        modifier(ShakeEffect(trigger: trigger))
            .animation(StratusAnimation.errorShake, value: trigger)
    }
}
