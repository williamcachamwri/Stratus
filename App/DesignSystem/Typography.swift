import SwiftUI

public extension Font {
    // MARK: - Stratus Semantic Typography Scale
    static let stratusLargeTitle  = Font.largeTitle.weight(.semibold)
    static let stratusTitle       = Font.title2.weight(.semibold)
    static let stratusHeadline    = Font.headline
    static let stratusBody        = Font.body
    static let stratusCallout     = Font.callout
    static let stratusCaption     = Font.caption.weight(.medium)
    static let stratusMonospace   = Font.system(.body, design: .monospaced)
    static let stratusSmallMono   = Font.system(.caption, design: .monospaced)
}

public extension View {
    func stratusTitle() -> some View { font(.stratusTitle) }
    func stratusHeadline() -> some View { font(.stratusHeadline) }
    func stratusBody() -> some View { font(.stratusBody) }
    func stratusCaption() -> some View { font(.stratusCaption).foregroundColor(.textSecondary) }
    func stratusMonospace() -> some View { font(.stratusMonospace) }
}
