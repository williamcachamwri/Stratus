import SwiftUI
import StratusCore
import AppKit

// MARK: - Accessibility View Modifiers

public extension View {
    /// Applies a standard accessibility label + hint for upload row items.
    func uploadRowAccessibility(fileName: String, progress: Double, state: String) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(fileName), \(state)"))
            .accessibilityValue(Text(String(format: "%.0f%%", progress * 100)))
            .accessibilityHint(Text("Double-tap to view upload details"))
    }

    /// Reduces or disables an animation when Reduce Motion is enabled.
    func reducedMotionAnimation<V: Equatable>(
        _ animation: Animation?,
        value: V
    ) -> some View {
        modifier(ReducedMotionModifier(animation: animation, value: value))
    }
}

// MARK: - ReducedMotionModifier

private struct ReducedMotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.animation(nil, value: value)
        } else {
            content.animation(animation, value: value)
        }
    }
}

// MARK: - AccessibleProgressRing

/// A ProgressRing that announces its value to VoiceOver.
public struct AccessibleProgressRing: View {
    let progress: Double
    let label: String
    var size: CGFloat = 24
    var color: Color = .accentColor

    public var body: some View {
        ProgressRing(progress: progress, size: size, color: color)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(String(format: "%.0f%%", progress * 100)))
    }
}

// MARK: - Keyboard Navigation Shortcuts

extension View {
    /// Attaches a keyboard shortcut that applies only when the view is focused.
    func onReturnKey(perform action: @escaping () -> Void) -> some View {
        self.onKeyPress(.return) {
            action()
            return .handled
        }
    }

    func onDeleteKey(perform action: @escaping () -> Void) -> some View {
        self.onKeyPress(.delete) {
            action()
            return .handled
        }
    }
}

// MARK: - Focus Management

/// Wraps a list to restore focus after async data reload.
public struct FocusRestoringList<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let data: Data
    @Binding var selection: Data.Element.ID?
    let content: (Data.Element) -> Content

    public var body: some View {
        List(data, selection: $selection, rowContent: content)
            .onChange(of: data.count) { _, newCount in
                // If selection is no longer valid after reload, clear it
                if let sel = selection, !data.contains(where: { $0.id == sel }) {
                    selection = nil
                }
            }
    }
}
