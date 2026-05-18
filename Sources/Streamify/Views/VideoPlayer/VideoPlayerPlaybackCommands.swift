import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Audio Session / Remote Controls
    var isVideoActuallyPlaying: Bool {
        viewModel.playbackRate > 0 && !viewModel.isBuffering
    }

    var isVideoPlaybackRequestedOrActive: Bool {
        viewModel.isPlaying || viewModel.playbackRate > 0
    }

    var isPickerOrSwitchAlertPresented: Bool {
        showQualitySheet || showSubtitleSheet || showAudioSheet ||
        showSubtitleVariantSheet || showAudioVariantSheet || showSwitchToOnlineAlert
    }

    func handlePickerPresentationChange() {
        if isPickerOrSwitchAlertPresented {
            pauseForPickerIfNeeded()
        } else {
            resumeAfterPickerIfNeeded()
        }
    }

    func pauseForPickerIfNeeded() {
        guard !viewModel.hasAccessDeniedPlayback else { return }
        guard isPlaybackRequestedOrActive else { return }
        pausedPlaybackForPicker = true
        shouldResumeAfterPicker = true
        pausePlayback()
    }

    func resumeAfterPickerIfNeeded() {
        guard pausedPlaybackForPicker else { return }
        let shouldResume = shouldResumeAfterPicker
        clearPickerPauseState()
        guard shouldResume, !isTransitioningToNext, switchToOnlineTask == nil, nextEpisodeTask == nil else { return }
        playWithSyncedAudio()
    }

    func consumePickerResumeIntent() -> Bool {
        let shouldResume = shouldResumeAfterPicker
        clearPickerPauseState()
        return shouldResume
    }

    func clearPickerPauseState() {
        pausedPlaybackForPicker = false
        shouldResumeAfterPicker = false
    }

    @discardableResult
    func pausePlaybackForPresentedPicker(rememberResumeIntent: Bool = true) -> Bool {
        guard isPickerOrSwitchAlertPresented else { return false }
        pausedPlaybackForPicker = true
        if rememberResumeIntent {
            shouldResumeAfterPicker = true
        }
        pausePlayback()
        return true
    }

    var isPlaybackRequestedOrActive: Bool {
        isVideoPlaybackRequestedOrActive ||
            (externalAudioPlayer?.rate ?? 0) > 0 ||
            (embeddedAudioPlayer?.rate ?? 0) > 0
    }

    var isSkipAudioSyncPending: Bool {
        skipForwardSyncTask != nil || skipBackwardSyncTask != nil
    }

    var isDeferredAudioSyncPending: Bool {
        isSkipAudioSyncPending || pipSeekAudioSyncTask != nil
    }

    var shouldHandlePiPPlaybackEvent: Bool {
        viewModel.isPiPActive && UIApplication.shared.applicationState != .active
    }

    func setupRemoteCommandHandlers() {
        guard remoteCommandTargets.isEmpty else { return }
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let center = MPRemoteCommandCenter.shared()

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        let skipForwardTarget = center.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in
                handleRemoteSkip(by: interval)
            }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        let skipBackwardTarget = center.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in
                handleRemoteSkip(by: -interval)
            }
            return .success
        }

        let pauseTarget = center.pauseCommand.addTarget { _ in
            Task { @MainActor in
                pausePlayback()
                StreamifyLogger.log("Audio: Remote pause received — pausing video and separate audio")
            }
            return .success
        }
        let playTarget = center.playCommand.addTarget { _ in
            Task { @MainActor in
                playWithSyncedAudio()
                StreamifyLogger.log("Audio: Remote play received — resuming with sync")
            }
            return .success
        }
        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                if isPlaybackRequestedOrActive {
                    pausePlayback()
                    StreamifyLogger.log("Audio: Remote toggle received — pausing")
                } else {
                    playWithSyncedAudio()
                    StreamifyLogger.log("Audio: Remote toggle received — resuming with sync")
                }
            }
            return .success
        }

        remoteCommandTargets = [
            RemoteCommandTarget(command: center.skipForwardCommand, target: skipForwardTarget),
            RemoteCommandTarget(command: center.skipBackwardCommand, target: skipBackwardTarget),
            RemoteCommandTarget(command: center.pauseCommand, target: pauseTarget),
            RemoteCommandTarget(command: center.playCommand, target: playTarget),
            RemoteCommandTarget(command: center.togglePlayPauseCommand, target: toggleTarget)
        ]
    }

    func teardownRemoteCommandHandlers() {
        let targets = remoteCommandTargets
        remoteCommandTargets.removeAll()
        for target in targets {
            target.command.removeTarget(target.target)
        }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    func handleRemoteSkip(by seconds: Double) {
        let wasPlaying = isVideoPlaybackRequestedOrActive || skipBurstShouldResume
        let hasSeparateAudio = hasSeparateAudioPlayer

        cancelSkipAudioSyncTasks()
        skipBurstShouldResume = wasPlaying
        if hasSeparateAudio {
            cancelPendingAudioSync()
            pauseSeparateAudio(cancelSync: false)
        }

        viewModel.skip(by: seconds, resumeAfterSeek: false) { finished in
            guard finished else { return }
            markSeekedPlaybackNeedsVideoGate()
            if hasSeparateAudio {
                if skipBurstShouldResume {
                    scheduleSkipAudioSync(shouldResume: true)
                } else {
                    syncSeparateAudio(shouldResume: false)
                    skipBurstShouldResume = false
                }
            } else {
                if wasPlaying {
                    playWithSyncedAudio()
                }
                skipBurstShouldResume = false
            }
            StreamifyLogger.log("Audio: Remote skip \(String(format: "%.0f", seconds))s handled")
        }
    }

    func cancelSkipAudioSyncTasks() {
        skipAudioSyncGeneration += 1
        skipForwardSyncTask?.cancel()
        skipForwardSyncTask = nil
        skipBackwardSyncTask?.cancel()
        skipBackwardSyncTask = nil
    }

    func scheduleSkipAudioSync(shouldResume: Bool, delay: TimeInterval = Self.skipButtonDebounceDelay) {
        cancelSkipAudioSyncTasks()
        let generation = skipAudioSyncGeneration
        skipBurstShouldResume = skipBurstShouldResume || shouldResume
        let work = DispatchWorkItem {
            guard self.skipAudioSyncGeneration == generation else { return }
            let shouldResumeAfterBurst = self.skipBurstShouldResume || shouldResume
            self.skipBurstShouldResume = false
            self.skipForwardSyncTask = nil
            self.skipBackwardSyncTask = nil
            if shouldResumeAfterBurst {
                self.playWithSyncedAudio()
            } else {
                self.syncSeparateAudio(shouldResume: false)
            }
        }
        skipForwardSyncTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelPiPSeekAudioSyncTask() {
        pipSeekAudioSyncTask?.cancel()
        pipSeekAudioSyncTask = nil
    }

    func schedulePiPSeekAudioSync(shouldResume: Bool, delay: TimeInterval = Self.skipButtonDebounceDelay) {
        cancelPiPSeekAudioSyncTask()
        let work = DispatchWorkItem {
            self.pipSeekAudioSyncTask = nil
            guard self.viewModel.isPiPActive, self.hasSeparateAudioPlayer else { return }
            if shouldResume || self.isVideoPlaybackRequestedOrActive {
                self.playWithSyncedAudio()
            } else {
                self.syncSeparateAudio(shouldResume: false)
            }
        }
        pipSeekAudioSyncTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func handleAudioRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            guard isVideoActuallyPlaying else { return }
            pausePlayback()
            StreamifyLogger.log("Audio: Output device unavailable — pausing playback")
        case .routeConfigurationChange:
            guard isVideoActuallyPlaying else { return }
            pausePlayback()
            StreamifyLogger.log("Audio: Output route changed — pausing playback")
        default:
            break
        }
    }

    func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              type == .began else { return }
        guard isVideoActuallyPlaying else { return }
        pausePlayback()
        StreamifyLogger.log("Audio: Session interrupted — pausing playback")
    }

    func resetPiPSeekObservation() {
        lastPiPObservedVideoTime = nil
        lastPiPObservationDate = nil
        cancelPiPSeekAudioSyncTask()
    }

    func observePiPVideoSeekAndSyncSeparateAudioIfNeeded() {
        guard viewModel.isPiPActive, hasSeparateAudioPlayer else {
            resetPiPSeekObservation()
            return
        }

        let now = Date()
        let videoSeconds = viewModel.realPlaybackTime
        guard videoSeconds.isFinite else { return }
        defer {
            lastPiPObservedVideoTime = videoSeconds
            lastPiPObservationDate = now
        }

        guard let previousVideoSeconds = lastPiPObservedVideoTime,
              let previousDate = lastPiPObservationDate,
              !skipBurstShouldResume,
              !isSkipAudioSyncPending else { return }

        let elapsed = max(now.timeIntervalSince(previousDate), 0)
        let rate = max(Double(viewModel.playbackRate), viewModel.isPlaying ? 1.0 : 0.0)
        let expectedDelta = rate > 0 ? elapsed * rate : 0
        let actualDelta = videoSeconds - previousVideoSeconds
        let seekJump = abs(actualDelta - expectedDelta)
        guard seekJump >= Self.pipSeekJumpThreshold else { return }

        cancelPendingAudioSync()
        pauseSeparateAudio(cancelSync: false)
        markSeekedPlaybackNeedsVideoGate()
        schedulePiPSeekAudioSync(shouldResume: isVideoPlaybackRequestedOrActive)
        StreamifyLogger.log("Audio: PiP seek jump \(String(format: "%.2f", actualDelta))s detected — scheduling separate audio sync")
    }

    // MARK: - Volume Overlay
    var volumeChangeOverlay: some View {
        GeometryReader { proxy in
            let width = min(max(proxy.size.width * 0.58, 220), 520)
            let displayedFraction = CGFloat(clampedVolume(displayedOutputVolume))

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: volumeIconName(for: displayedOutputVolume))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 18, height: 18)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.18))
                            .frame(width: width, height: 6)

                        Rectangle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: width * displayedFraction, height: 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: width, height: 18, alignment: .leading)
                }
                .frame(height: 18)
                .padding(.top, max(proxy.safeAreaInsets.top, 0))
                .opacity(isVolumeOverlayVisible ? 1 : 0)
                .scaleEffect(y: isVolumeOverlayVisible ? 1 : 0.82, anchor: .top)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.08), value: isVolumeOverlayVisible)
    }

    func prepareVolumeMonitoring() {
        let volume = displayVolume(AVAudioSession.sharedInstance().outputVolume)
        lastOutputVolume = volume
        displayedOutputVolume = volume
    }

    func clampedVolume(_ volume: Float) -> Float {
        min(max(volume, 0), 1)
    }

    func displayVolume(_ volume: Float) -> Float {
        let clamped = clampedVolume(volume)
        guard clamped > 0, clamped < 1 else { return clamped }
        return (clamped * Self.outputVolumeStepCount).rounded() / Self.outputVolumeStepCount
    }

    func handleOutputVolumeChange(_ rawVolume: Float) {
        let newVolume = displayVolume(rawVolume)
        guard let oldVolume = lastOutputVolume else {
            lastOutputVolume = newVolume
            displayedOutputVolume = newVolume
            return
        }
        guard abs(newVolume - oldVolume) > 0.002 else { return }

        hideVolumeOverlayTask?.cancel()
        lastOutputVolume = newVolume
        if !isVolumeOverlayVisible {
            displayedOutputVolume = oldVolume
        }

        withAnimation(.easeOut(duration: 0.04)) {
            isVolumeOverlayVisible = true
        }
        withAnimation(.easeOut(duration: 0.08)) {
            displayedOutputVolume = newVolume
        }

        let hideTask = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.1)) {
                self.isVolumeOverlayVisible = false
            }
        }
        hideVolumeOverlayTask = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.volumeOverlayVisibleDuration, execute: hideTask)
    }

    func volumeIconName(for volume: Float) -> String {
        if volume <= 0.01 {
            return "speaker.slash.fill"
        }
        if volume < 0.35 {
            return "speaker.wave.1.fill"
        }
        if volume < 0.7 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }
}
