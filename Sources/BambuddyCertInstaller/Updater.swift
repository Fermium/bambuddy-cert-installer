import AppKit
import Sparkle

/// Updates with Sparkle, from the feed in Info.plist (SUFeedURL, fermium.ltd.uk/apps/bambuddy-cert-installer/
/// appcast.xml). An update is installed only when its EdDSA signature matches SUPublicEDKey, which matters for an
/// app that re-signs other apps. "Check automatically" checks once a day; "Install automatically" downloads in the
/// background and installs on quit. A found update brings its window forward, since the app has no Dock icon.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// Set at launch; nil in the snapshot mode, which never starts Sparkle.
    static var current: Updater?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        MainActor.assumeIsolated { NSApp.activate() }
    }
}
