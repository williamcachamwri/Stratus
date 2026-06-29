import SwiftUI

public extension Color {
    // MARK: - Brand
    static let stratusBlue      = Color("StratusBlue", bundle: .main)
    static let stratusTeal      = Color("StratusTeal", bundle: .main)
    static let stratusIndigo    = Color("StratusIndigo", bundle: .main)

    // MARK: - Semantic
    static let uploadActive     = Color.green
    static let uploadPaused     = Color.orange
    static let uploadFailed     = Color.red
    static let syncRunning      = Color.blue
    static let syncConflict     = Color.yellow

    // MARK: - Background / Surface
    static let surfacePrimary   = Color(NSColor.controlBackgroundColor)
    static let surfaceSecondary = Color(NSColor.windowBackgroundColor)
    static let surfaceElevated  = Color(NSColor.underPageBackgroundColor)

    // MARK: - Text
    static let textPrimary      = Color(NSColor.labelColor)
    static let textSecondary    = Color(NSColor.secondaryLabelColor)
    static let textTertiary     = Color(NSColor.tertiaryLabelColor)

    // MARK: - Provider Accent Colors
    static let s3Orange         = Color(red: 1.0, green: 0.55, blue: 0.0)
    static let googleBlue       = Color(red: 0.26, green: 0.52, blue: 0.96)
    static let dropboxBlue      = Color(red: 0.0, green: 0.39, blue: 1.0)
    static let oneDriveBlue     = Color(red: 0.0, green: 0.47, blue: 0.84)
    static let sftpGray         = Color(NSColor.systemGray)
    static let webdavPurple     = Color(red: 0.55, green: 0.27, blue: 0.83)
}
