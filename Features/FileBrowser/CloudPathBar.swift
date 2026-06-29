import SwiftUI
import StratusCore

public struct CloudPathBar: View {
    public let path: CloudPath
    public var onNavigate: (CloudPath) -> Void

    private var components: [PathComponent] {
        let parts = path.path.split(separator: "/").map(String.init)
        var result = [PathComponent(title: "Root", path: CloudPath("/"))]
        var current = ""
        for part in parts {
            current += "/\(part)"
            result.append(PathComponent(title: part, path: CloudPath(current)))
        }
        return result
    }

    public init(path: CloudPath, onNavigate: @escaping (CloudPath) -> Void) {
        self.path = path
        self.onNavigate = onNavigate
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                    Button {
                        onNavigate(component.path)
                    } label: {
                        Text(component.title)
                            .font(.stratusCallout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)

                    if index < components.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
        .background(Color.surfacePrimary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cloud path")
    }
}

private struct PathComponent: Identifiable, Equatable {
    let title: String
    let path: CloudPath

    var id: String { path.path }
}
