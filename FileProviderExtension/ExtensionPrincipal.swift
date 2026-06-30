@preconcurrency import FileProvider
import StratusCore

/// Bundle principal class for the Stratus File Provider extension target.
///
/// The production implementation lives in `StratusCore` so it can be shared by
/// tests and the main app. This thin subclass gives the extension bundle its own
/// runtime principal class name for Info.plist.
@objc(FileProviderExtension)
public final class FileProviderExtension: StratusFileProviderExtension {}
