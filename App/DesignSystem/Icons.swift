import SwiftUI

// MARK: - StratusIcons
// Centralised SF Symbol name constants for the Stratus design system.
//
// All values are plain String constants — no force-casting, no SFSymbol wrapper
// types — keeping them usable as:
//   Image(systemName: StratusIcons.upload)
//   Label("Upload", systemImage: StratusIcons.upload)
//   Image(systemName: StratusIcons.Provider.s3)
//
// Symbol availability: all symbols below are available on macOS 13+.
// Where a symbol requires macOS 14+ or 15+, the minimum availability is
// documented inline.

public enum StratusIcons {

    // MARK: - File Transfer

    /// Arrow pointing up into cloud — primary upload action.
    public static let upload         = "icloud.and.arrow.up"
    /// Arrow pointing down from cloud — primary download action.
    public static let download       = "icloud.and.arrow.down"
    /// Two circular arrows — sync / refresh operation.
    public static let sync           = "arrow.triangle.2.circlepath"
    /// Sync with clock badge — sync scheduled or running.
    public static let syncRunning    = "arrow.triangle.2.circlepath.circle"
    /// Sync paused indicator.
    public static let syncPaused     = "pause.circle"
    /// Checkmark in cloud — upload complete.
    public static let uploadComplete = "checkmark.icloud"
    /// X in cloud — upload failed.
    public static let uploadFailed   = "xmark.icloud"

    // MARK: - Cloud & Storage

    /// Generic cloud shape.
    public static let cloud          = "cloud"
    /// Cloud fill — connected / active state.
    public static let cloudFill      = "cloud.fill"
    /// Cloud with lightning — sync conflict.
    public static let conflict       = "exclamationmark.icloud"
    /// Server rack — object-storage / S3-style provider.
    public static let serverRack     = "server.rack"
    /// External drive — local storage reference.
    public static let externalDrive  = "externaldrive"
    /// Network globe — WebDAV / remote connection.
    public static let network        = "network"

    // MARK: - File System

    /// Folder — directory / collection.
    public static let folder         = "folder"
    /// Folder fill — selected or open directory.
    public static let folderFill     = "folder.fill"
    /// Document — generic file.
    public static let file           = "doc"
    /// Document fill — selected file.
    public static let fileFill       = "doc.fill"
    /// Stack of documents — multiple files / batch.
    public static let files          = "doc.on.doc"
    /// Magnifying glass over document — file browser search.
    public static let fileSearch     = "doc.text.magnifyingglass"
    /// Trash — delete / remove.
    public static let trash          = "trash"
    /// Trash fill — confirm delete state.
    public static let trashFill      = "trash.fill"

    // MARK: - Account & Security

    /// Person circle — account / user.
    public static let account        = "person.circle"
    /// Person circle fill — active / selected account.
    public static let accountFill    = "person.circle.fill"
    /// Person crop circle badge plus — add account.
    public static let addAccount     = "person.crop.circle.badge.plus"
    /// Lock — encryption / secured.
    public static let lock           = "lock"
    /// Lock fill — locked / encrypting.
    public static let lockFill       = "lock.fill"
    /// Lock open — decrypted / unlocked.
    public static let lockOpen       = "lock.open"
    /// Key — authentication / credentials.
    public static let key            = "key"
    /// Touch ID / fingerprint — biometric authentication.
    public static let biometric      = "touchid"

    // MARK: - UI Actions & Controls

    /// Gear — settings / configuration.
    public static let settings       = "gearshape"
    /// Two gears — advanced settings.
    public static let settingsAdvanced = "gearshape.2"
    /// Sliders — filter / sort controls.
    public static let filter         = "slider.horizontal.3"
    /// Plus circle — add item.
    public static let add            = "plus.circle"
    /// Plus circle fill — prominent add.
    public static let addFill        = "plus.circle.fill"
    /// Minus circle — remove item.
    public static let remove         = "minus.circle"
    /// Ellipsis circle — overflow / more options.
    public static let more           = "ellipsis.circle"
    /// Pencil — edit / rename.
    public static let edit           = "pencil"
    /// Square and arrow up — share / export.
    public static let share          = "square.and.arrow.up"
    /// Square and arrow down — import.
    public static let `import`       = "square.and.arrow.down"
    /// Info circle — details / help.
    public static let info           = "info.circle"
    /// Exclamation mark triangle — warning.
    public static let warning        = "exclamationmark.triangle"
    /// Exclamation mark circle — error.
    public static let error          = "exclamationmark.circle"
    /// Checkmark circle — success.
    public static let success        = "checkmark.circle"
    /// X circle — dismiss / clear.
    public static let dismiss        = "xmark.circle"
    /// Arrow clockwise — retry.
    public static let retry          = "arrow.clockwise"
    /// Pause fill — pause transfer.
    public static let pause          = "pause.fill"
    /// Play fill — resume transfer.
    public static let play           = "play.fill"
    /// Stop fill — cancel transfer.
    public static let stop           = "stop.fill"

    // MARK: - Status / Diagnostics

    /// WiFi — network connected.
    public static let wifi           = "wifi"
    /// WiFi with slash — network offline.
    public static let wifiOff        = "wifi.slash"
    /// Waveform — bandwidth / speed graph.
    public static let bandwidth      = "waveform.path.ecg"
    /// Speedometer — throughput indicator.
    public static let speed          = "gauge.medium"
    /// Chart bar — analytics / statistics.
    public static let chart          = "chart.bar"
    /// Clock — scheduled / queued.
    public static let clock          = "clock"
    /// Bell — notifications.
    public static let notifications  = "bell"
    /// Bell slash — notifications muted.
    public static let notificationsMuted = "bell.slash"

    // MARK: - Provider-Specific Symbols

    /// Symbols associated with each supported cloud provider.
    /// These map to the same icon used in `ProviderIcon` for visual consistency.
    public enum Provider {
        public static let s3         = "server.rack"
        public static let wasabi     = "server.rack"
        public static let backblaze  = "server.rack"
        public static let r2         = "server.rack"
        public static let minio      = "server.rack"
        public static let gdrive     = "doc.on.doc"
        public static let dropbox    = "shippingbox"
        public static let oneDrive   = "icloud"
        public static let sftp       = "network"
        public static let webdav     = "globe"
        public static let generic    = "cloud"
    }
}

// MARK: - Image Extension

public extension Image {
    /// Convenience initialiser for StratusIcons string constants.
    /// Equivalent to `Image(systemName: symbolName)`.
    static func stratus(_ symbolName: String) -> Image {
        Image(systemName: symbolName)
    }
}
