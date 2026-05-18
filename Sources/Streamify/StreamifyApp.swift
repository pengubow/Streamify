import SwiftUI

@main
struct StreamifyApp: App {
    @UIApplicationDelegateAdaptor(StreamifyAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        StreamifyLogger.clear()
        MatroskaPlaybackSupport.cleanupTransientCacheOnLaunch()
        CompressedJSON.migrateAllGzToZlib()
        LocalServer.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                // Persist download state so progress isn't lost on app exit
                DownloadManager.shared.saveDownloadsOnBackground()
            } else if newPhase == .active {
                // iOS can suspend or kill the NWListener while the app is in
                // the background. Ensure the local HTTP server is running again
                // so local HLS playback continues working after a background trip.
                Task {
                    if !LocalServer.shared.isManuallyStopped {
                        await LocalServer.shared.ensureRunningAsync()
                    }
                }
            }
        }
    }
}
