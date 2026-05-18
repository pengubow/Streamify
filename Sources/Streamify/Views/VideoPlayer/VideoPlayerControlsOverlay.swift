import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import QuartzCore

extension VideoPlayerView {
    // MARK: - Controls overlay
    var controlsOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
                }

            // Center controls - always perfectly centered
            centerControls

            GeometryReader { safeGeo in
                let safeInsets = StreamifySafeArea.insets(fallback: safeGeo.safeAreaInsets)
                ZStack {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.top, StreamifySafeArea.playerControlTopPadding(size: safeGeo.size, safeInsets: safeInsets))

                        Spacer()

                        bottomBar
                            .padding(.bottom, StreamifySafeArea.playerControlBottomPadding(size: safeGeo.size, safeInsets: safeInsets))
                    }

                    brightnessSlider
                }
                .padding(.horizontal, StreamifySafeArea.playerControlHorizontalPadding(size: safeGeo.size, safeInsets: safeInsets))
            }
        }
    }

    // MARK: - Top bar
    var topBar: some View {
        HStack(spacing: 12) {
            Button {
                guard !hasCalledDismiss else { return }
                hasCalledDismiss = true
                saveProgress()
                // Animate the player view rotating from landscape to portrait.
                isAnimatingExit = true
                // After the visual rotation completes, switch to portrait and dismiss.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    OrientationManager.shared.rotate(to: .portrait)
                    self.onDismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(content.metadata.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let ep = currentEpisodeInfo {
                    Text(ep.title.isEmpty
                        ? "S\(ep.season) E\(ep.episode)"
                        : "S\(ep.season) E\(ep.episode): \(ep.title)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            // PiP button
            if viewModel.isPiPSupported {
                Button {
                    viewModel.togglePiP()
                } label: {
                    Image(systemName: viewModel.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
            }

            // HDR active indicator
            if viewModel.isPlayingHDR {
                hdrIndicator(color: .blue)
            }

            if viewModel.isLocalFile {
                Button {
                    showQualitySheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Downloaded")
                            .font(.caption)
                        if let quality = activePlayingQualityName ?? currentEpisodeInfo?.qualityName ?? content.metadata.downloadedQuality, !quality.isEmpty {
                            Text("•")
                                .font(.caption)
                            Text(quality)
                                .font(.caption)
                        } else if !viewModel.localFileResolution.isEmpty {
                            Text("•")
                                .font(.caption)
                            Text(viewModel.localFileResolution)
                                .font(.caption)
                        }
                        // Show source name badge for the currently playing downloaded quality
                        if let sn = currentDownloadedSourceName, !sn.isEmpty {
                            Text(sn)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else if viewModel.isHLS {
                Button {
                    showQualitySheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape.fill")
                        if viewModel.selectedQualityName == "Auto" && !viewModel.autoQualityLabel.isEmpty {
                            Text("Auto (\(viewModel.autoQualityLabel))")
                                .font(.caption)
                        } else {
                            Text(viewModel.selectedQualityName)
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else if !viewModel.availableQualities.isEmpty {
                Button {
                    showQualitySheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape.fill")
                        if viewModel.selectedQualityName == "Auto", !viewModel.autoQualityLabel.isEmpty {
                            Text(viewModel.autoQualityLabel)
                                .font(.caption)
                        } else if viewModel.selectedQualityName != "Auto" {
                            Text(viewModel.selectedQualityName)
                                .font(.caption)
                        } else {
                            Text("Quality")
                                .font(.caption)
                        }
                        if let sourceName = viewModel.autoQualitySourceName, !sourceName.isEmpty {
                            SourceBadge(sourceName: sourceName)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Center controls
    var centerControls: some View {
        HStack(spacing: 48) {
            // Skip backward button with animated accumulated text
            Button {
                let wasPlaying = isVideoPlaybackRequestedOrActive || skipBurstShouldResume
                let hasSeparateAudio = hasSeparateAudioPlayer
                // Pause separate audio while seeking. For separate audio, only the final
                // debounced seek resumes both video and audio so bursts stay coherent.
                cancelSkipAudioSyncTasks()
                skipBurstShouldResume = wasPlaying
                if hasSeparateAudio {
                    cancelPendingAudioSync()
                    pauseSeparateAudio(cancelSync: false)
                }
                viewModel.skip(by: -Self.skipInterval, resumeAfterSeek: false) { finished in
                    guard finished else { return }
                    markSeekedPlaybackNeedsVideoGate()
                    if hasSeparateAudio {
                        scheduleSkipAudioSync(shouldResume: skipBurstShouldResume)
                    } else {
                        if wasPlaying {
                            playWithSyncedAudio()
                        }
                        skipBurstShouldResume = false
                    }
                }
                skipBackwardFadeInTask?.cancel()
                skipBackwardFadeOutTask?.cancel()
                skipBackwardRestoreTask?.cancel()
                if !skipBackwardActive {
                    skipBackwardAccumulated = 0
                }
                skipBackwardActive = true
                skipBackwardAccumulated += Self.skipInterval
                // Hide static "10" text
                withAnimation(.easeOut(duration: 0.1)) {
                    skipBackwardStaticOpacity = 0
                }
                // Reset animation state immediately
                var resetTransaction = Transaction()
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) {
                    skipBackwardTextOpacity = 0
                    skipBackwardTextOffset = 0
                }
                // Animate text moving right-to-left
                withAnimation(.easeOut(duration: 0.5)) {
                    skipBackwardTextOffset = -35
                }
                // Fade in after 0.15s
                let fadeIn = DispatchWorkItem {
                    withAnimation(.easeIn(duration: 0.1)) {
                        self.skipBackwardTextOpacity = 1
                    }
                }
                skipBackwardFadeInTask = fadeIn
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: fadeIn)
                // Fade out starting at 0.5s, restore static text after animation
                let fadeOut = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.skipBackwardTextOpacity = 0
                    }
                    let restore = DispatchWorkItem {
                        self.skipBackwardActive = false
                        withAnimation(.easeIn(duration: 0.15)) {
                            self.skipBackwardStaticOpacity = 1
                        }
                    }
                    self.skipBackwardRestoreTask = restore
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: restore)
                }
                skipBackwardFadeOutTask = fadeOut
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fadeOut)
                cancelHideControls()
                scheduleHideControls()
            } label: {
                ZStack {
                    Image(systemName: "gobackward")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                    Text("10")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .offset(y: 1)
                        .opacity(skipBackwardStaticOpacity)
                    Text("\(Int(skipBackwardAccumulated))s")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .opacity(skipBackwardTextOpacity)
                        .offset(x: skipBackwardTextOffset)
                }
                .frame(width: 56, height: 64)
            }

            Button {
                let wasPlaying = viewModel.isPlaying
                if wasPlaying {
                    // Pause: stop both players immediately
                    pausePlayback()
                } else {
                    playWithSyncedAudio()
                }
                cancelHideControls()
                scheduleHideControls()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
            }

            // Skip forward button with animated accumulated text
            Button {
                let wasPlaying = isVideoPlaybackRequestedOrActive || skipBurstShouldResume
                let hasSeparateAudio = hasSeparateAudioPlayer
                // Pause separate audio while seeking. For separate audio, only the final
                // debounced seek resumes both video and audio so bursts stay coherent.
                cancelSkipAudioSyncTasks()
                skipBurstShouldResume = wasPlaying
                if hasSeparateAudio {
                    cancelPendingAudioSync()
                    pauseSeparateAudio(cancelSync: false)
                }
                viewModel.skip(by: Self.skipInterval, resumeAfterSeek: false) { finished in
                    guard finished else { return }
                    markSeekedPlaybackNeedsVideoGate()
                    if hasSeparateAudio {
                        scheduleSkipAudioSync(shouldResume: skipBurstShouldResume)
                    } else {
                        if wasPlaying {
                            playWithSyncedAudio()
                        }
                        skipBurstShouldResume = false
                    }
                }
                skipForwardFadeInTask?.cancel()
                skipForwardFadeOutTask?.cancel()
                skipForwardRestoreTask?.cancel()
                if !skipForwardActive {
                    skipForwardAccumulated = 0
                }
                skipForwardActive = true
                skipForwardAccumulated += Self.skipInterval
                // Hide static "10" text
                withAnimation(.easeOut(duration: 0.1)) {
                    skipForwardStaticOpacity = 0
                }
                // Reset animation state immediately
                var resetTransaction = Transaction()
                resetTransaction.disablesAnimations = true
                withTransaction(resetTransaction) {
                    skipForwardTextOpacity = 0
                    skipForwardTextOffset = 0
                }
                // Animate text moving left-to-right
                withAnimation(.easeOut(duration: 0.5)) {
                    skipForwardTextOffset = 35
                }
                // Fade in after 0.15s
                let fadeIn = DispatchWorkItem {
                    withAnimation(.easeIn(duration: 0.1)) {
                        self.skipForwardTextOpacity = 1
                    }
                }
                skipForwardFadeInTask = fadeIn
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: fadeIn)
                // Fade out starting at 0.5s, restore static text after animation
                let fadeOut = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.skipForwardTextOpacity = 0
                    }
                    let restore = DispatchWorkItem {
                        self.skipForwardActive = false
                        withAnimation(.easeIn(duration: 0.15)) {
                            self.skipForwardStaticOpacity = 1
                        }
                    }
                    self.skipForwardRestoreTask = restore
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: restore)
                }
                skipForwardFadeOutTask = fadeOut
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fadeOut)
                cancelHideControls()
                scheduleHideControls()
            } label: {
                ZStack {
                    Image(systemName: "goforward")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                    Text("10")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .offset(y: 1)
                        .opacity(skipForwardStaticOpacity)
                    Text("\(Int(skipForwardAccumulated))s")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .opacity(skipForwardTextOpacity)
                        .offset(x: skipForwardTextOffset)
                }
                .frame(width: 56, height: 64)
            }
        }
    }

    // MARK: - Bottom bar
    var bottomBar: some View {
        VStack(spacing: 4) {
            SeekBarView(
                progress: Binding(
                    get: {
                        viewModel.duration > 0
                            ? viewModel.currentTime / viewModel.duration : 0
                    },
                    set: { newValue in
                        // Seek to raw position; onSeekEnded performs the actual player seek.
                        viewModel.seek(to: newValue * viewModel.duration)
                    }
                ),
                currentTime: $viewModel.currentTime,
                duration: viewModel.duration,
                previewTime: $previewTime,
                loadedRanges: viewModel.loadedTimeRanges,
                onSeekStarted: { 
                    cancelHideControls()
                    isUserSeeking = true
                    pausePlayback()
                },
                onSeekEnded: { 
                    isUserSeeking = false
                    // Use completion-based seek so resume runs AFTER the seek finishes.
                    let target = previewTime
                    viewModel.seek(to: target) {
                        markSeekedPlaybackNeedsVideoGate()
                        playWithSyncedAudio()
                    }
                    scheduleHideControls() 
                }
            )

            ZStack {
                HStack {
                    Text(formatTime(isUserSeeking ? previewTime : viewModel.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(minWidth: 54, alignment: .leading)

                    Spacer()

                    Text(formatTime(viewModel.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(minWidth: 54, alignment: .trailing)
                }

                // Audio and Subtitle buttons sit in the center of the time row.
                HStack(spacing: 12) {
                    // Subtitle button - only shown when usable subtitles exist.
                    // During local playback, only locally downloaded subtitles count.
                    if hasUsableSubtitles {
                        Button {
                            showSubtitleSheet = true
                            cancelHideControls()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "captions.bubble")
                                    .font(.subheadline.weight(.semibold))
                                Text("Subtitles")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.92))
                    }

                    // Audio button - only shown when usable audio tracks exist.
                    // During local playback, only locally downloaded audio tracks count.
                    if hasUsableAudioTracks {
                        Button {
                            showAudioSheet = true
                            cancelHideControls()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "speaker.wave.2")
                                    .font(.subheadline.weight(.semibold))
                                Text("Audio")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StreamifyPressScaleButtonStyle(scale: 0.92))
                    }
                }
            }
            .frame(height: 28)

            // Sheets and alerts (always present for state binding)
            Color.clear.frame(height: 0)
                .streamifyAlert(
                    title: "Subtitle Error",
                    message: "Local subtitle file not found and re-downloading failed.",
                    isPresented: $showSubtitleErrorAlert
                )
                .streamifyAlert(
                    title: "Audio Error",
                    message: "Failed to load audio track. The file may be unavailable.",
                    isPresented: $showAudioErrorAlert
                )
                .streamifyAlert(
                    title: "Audio Fallback",
                    message: audioFallbackMessage ?? "",
                    isPresented: Binding(
                        get: { audioFallbackMessage != nil },
                        set: { if !$0 { audioFallbackMessage = nil } }
                    ),
                    primaryAction: { audioFallbackMessage = nil }
                )
        }
    }

    func hdrIndicator(color: Color) -> some View {
        Text("HDR")
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Brightness slider
    var brightnessSlider: some View {
        HStack {
            VStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))

                // Custom vertical slider without knob
                GeometryReader { geo in
                    let height = geo.size.height
                    ZStack(alignment: .bottom) {
                        // Track background
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 6)
                        // Active fill — plain rectangle, clipped by the track shape below
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 6, height: height * brightness)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // Relative drag: adjust from where user started, not jump to finger position
                                if dragStartBrightness == nil {
                                    dragStartBrightness = brightness
                                }
                                let delta = (value.startLocation.y - value.location.y) / height
                                let newBrightness = min(max((dragStartBrightness ?? brightness) + delta, 0), 1)
                                brightness = newBrightness
                                UIScreen.main.brightness = CGFloat(newBrightness)
                            }
                            .onEnded { _ in
                                dragStartBrightness = nil
                            }
                    )
                }
                .frame(width: 36, height: 140)

                Image(systemName: "sun.min.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.leading, 4)

            Spacer()
        }
    }
}
