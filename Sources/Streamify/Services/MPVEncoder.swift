import Foundation

// MARK: - libmpv C bindings (encode-mode subset)
// These are file-private bindings into the statically linked libmpv supplied by
// MPVKit.  They use distinct Swift names (suffix `_enc`) so they don't collide
// with the Swift-level symbol names in MPVDirectPlayerEngine.swift, but the
// parameter types and optionality must exactly match the canonical declarations
// in that file (the Swift compiler enforces one type per @_silgen_name symbol
// across the whole module).
//
// NOTE: mpv_terminate_destroy, mpv_request_log_messages, mpv_error_string, and
// mpv_wait_event / c_mpv_wait_event and the mpv_event struct are shared
// with MPVDirectPlayerEngine.swift (declared there as internal) and must NOT be
// re-declared here to avoid duplicate @_silgen_name type conflicts.

@_silgen_name("mpv_create")
private func mpv_create_enc() -> OpaquePointer?

@_silgen_name("mpv_initialize")
private func mpv_initialize_enc(_ ctx: OpaquePointer?) -> CInt

@_silgen_name("mpv_set_option_string")
private func mpv_set_option_string_enc(
  _ ctx: OpaquePointer?,
  _ name: UnsafePointer<CChar>,
  _ data: UnsafePointer<CChar>?
) -> CInt

@_silgen_name("mpv_command")
private func mpv_command_enc(
  _ ctx: OpaquePointer?,
  _ args: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> CInt

// Mirror of mpv_event_end_file (only the fields we need).
private struct MPVEncEventEndFile {
  var reason: CInt
  var error: CInt
}

private struct MPVEncEventLogMessage {
  var prefix: UnsafePointer<CChar>!
  var level: UnsafePointer<CChar>!
  var text: UnsafePointer<CChar>!
  var log_level: CInt
}

private final class MPVEncodingSession: @unchecked Sendable {
  private let lock = NSLock()
  private var mpv: OpaquePointer?
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func attach(_ mpv: OpaquePointer) {
    lock.lock()
    self.mpv = mpv
    let shouldCancel = cancelled
    lock.unlock()

    if shouldCancel {
      Self.sendQuit(to: mpv)
    }
  }

  func detach(_ mpv: OpaquePointer) {
    lock.lock()
    if self.mpv == mpv {
      self.mpv = nil
    }
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let target = mpv
    lock.unlock()

    if let target {
      Self.sendQuit(to: target)
    }
  }

  private static func sendQuit(to mpv: OpaquePointer) {
    "quit".withCString { commandPointer in
      "4".withCString { codePointer in
        var args: [UnsafePointer<CChar>?] = [commandPointer, codePointer, nil]
        _ = mpv_command_enc(mpv, &args)
      }
    }
  }
}

// MARK: - MPVEncoder

/// Runs libmpv in encode mode to extract a single audio or subtitle track to a file.
///
/// Uses MPVKit's statically linked FFmpeg – no external ffmpegkit dependency
/// required, no xcframework name collision on case-insensitive APFS volumes.
enum MPVEncoder {

  /// Extracts one audio track from `inputURL` and writes it to `outputURL`.
  ///
  /// - Parameters:
  ///   - inputURL:          Source media file (e.g. a local .mkv).
  ///   - outputURL:         Destination file path.
  ///   - audioIndex:        Zero-based audio-stream index in the source file.
  ///   - outputAudioCodec:  mpv `oac` value – `"copy"` for passthrough,
  ///                        `"alac"` to transcode to Apple Lossless, etc.
  ///   - outputFormat:      mpv `of` value – FFmpeg muxer short name,
  ///                        e.g. `"mov"` (produces M4A/MP4 container).
  /// - Returns: `true` when the encode completes normally (mpv EOF reason 0).
  static func extractAudio(
    from inputURL: URL,
    to outputURL: URL,
    audioIndex: Int,
    outputAudioCodec: String,
    outputFormat: String
  ) async -> Bool {
    let session = MPVEncodingSession()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          guard !session.isCancelled else {
            continuation.resume(returning: false)
            return
          }

          try? FileManager.default.removeItem(at: outputURL)
          try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )

          guard let mpv = mpv_create_enc() else {
            continuation.resume(returning: false)
            return
          }
          session.attach(mpv)
          defer {
            session.detach(mpv)
            c_mpv_terminate_destroy(mpv)
          }

          var recentLogs: [String] = []

          // Keep logs out of the terminal, but collect warnings/errors for app logs.
          setopt(mpv, "terminal", "no")
          requestLogMessages(mpv, "warn")

          // Suppress video and subtitle track selection so mpv skips
          // their decoders entirely – encode-mode audio only.
          setopt(mpv, "vid", "no")
          setopt(mpv, "sid", "no")
          setopt(mpv, "audio-channels", "auto")

          // Setting "o" puts mpv into encode mode.
          setopt(mpv, "o", outputURL.path)
          setopt(mpv, "oac", outputAudioCodec)
          setopt(mpv, "of", outputFormat)
          setopt(mpv, "ovc", "no")  // No video track in output

          // mpv aid is 1-based; audioIndex is 0-based.
          setopt(mpv, "aid", "\(audioIndex + 1)")

          let initStatus = mpv_initialize_enc(mpv)
          guard initStatus == 0 else {
            StreamifyLogger.log("MPVEncoder: audio extraction init failed: \(mpvError(initStatus))")
            continuation.resume(returning: false)
            return
          }

          // Issue the loadfile command.
          let loaded = inputURL.absoluteString.withCString { inputCStr in
            "loadfile".withCString { cmdCStr in
              var args: [UnsafePointer<CChar>?] = [cmdCStr, inputCStr, nil]
              let status = mpv_command_enc(mpv, &args)
              if status != 0 {
                StreamifyLogger.log(
                  "MPVEncoder: audio extraction loadfile failed: \(mpvError(status))")
              }
              return status == 0
            }
          }
          guard loaded else {
            continuation.resume(returning: false)
            return
          }

          // Drive the event loop until mpv signals end-of-file or shuts down.
          var succeeded = false
          var endedWithError = false
          eventLoop: while true {
            if session.isCancelled {
              session.cancel()
              break eventLoop
            }
            guard let event = c_mpv_wait_event(mpv, 0.2) else { break eventLoop }
            switch event.pointee.event_id {
            case 7:  // MPV_EVENT_END_FILE
              if let data = event.pointee.data {
                let endFile = data.assumingMemoryBound(to: MPVEncEventEndFile.self)
                succeeded = endFile.pointee.reason == 0  // 0 = normal EOF
                endedWithError = endFile.pointee.error != 0 || endFile.pointee.reason == 4
                if !succeeded {
                  recentLogs.append(
                    "end_file reason=\(endFile.pointee.reason) error=\(mpvError(endFile.pointee.error))"
                  )
                }
              }
              break eventLoop
            case 1:  // MPV_EVENT_SHUTDOWN
              break eventLoop
            case 2:  // MPV_EVENT_LOG_MESSAGE
              appendLogMessage(from: event, to: &recentLogs)
            default:
              break
            }
          }

          let exists = FileManager.default.fileExists(atPath: outputURL.path)
          let size =
            (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
          let fileLooksUsable = exists && size > 0 && !endedWithError
          let result = !session.isCancelled && (succeeded || fileLooksUsable)
          if !result {
            try? FileManager.default.removeItem(at: outputURL)
            logFailure(kind: "audio", logs: recentLogs)
          } else if !succeeded {
            StreamifyLogger.log(
              "MPVEncoder: audio extraction wrote \(size) bytes without normal EOF; using output")
          }
          continuation.resume(returning: result)
        }
      }
    } onCancel: {
      session.cancel()
    }
  }

  /// Extracts one subtitle track from `inputURL` and writes it as WebVTT to `outputURL`.
  ///
  /// - Parameters:
  ///   - inputURL:       Source media file (e.g. a local .mkv).
  ///   - outputURL:      Destination .vtt file path.
  ///   - subtitleIndex:  Zero-based subtitle-stream index in the source file.
  /// - Returns: `true` when the encode completes normally and the output file exists.
  static func extractSubtitle(
    from inputURL: URL,
    to outputURL: URL,
    subtitleIndex: Int
  ) async -> Bool {
    let session = MPVEncodingSession()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          guard !session.isCancelled else {
            continuation.resume(returning: false)
            return
          }

          try? FileManager.default.removeItem(at: outputURL)
          try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )

          guard let mpv = mpv_create_enc() else {
            continuation.resume(returning: false)
            return
          }
          session.attach(mpv)
          defer {
            session.detach(mpv)
            c_mpv_terminate_destroy(mpv)
          }

          var recentLogs: [String] = []

          setopt(mpv, "terminal", "no")
          requestLogMessages(mpv, "warn")

          // Suppress video and audio entirely.
          setopt(mpv, "vid", "no")
          setopt(mpv, "aid", "no")

          // Select the subtitle track (mpv sid is 1-based).
          setopt(mpv, "sid", "\(subtitleIndex + 1)")

          // Encode mode: write to file in WebVTT format.
          setopt(mpv, "o", outputURL.path)
          setopt(mpv, "of", "webvtt")

          // Suppress audio/video output codecs — subtitle only.
          setopt(mpv, "ovc", "no")
          setopt(mpv, "oac", "no")

          let initStatus = mpv_initialize_enc(mpv)
          guard initStatus == 0 else {
            StreamifyLogger.log(
              "MPVEncoder: subtitle extraction init failed: \(mpvError(initStatus))")
            continuation.resume(returning: false)
            return
          }

          let loaded = inputURL.absoluteString.withCString { inputCStr in
            "loadfile".withCString { cmdCStr in
              var args: [UnsafePointer<CChar>?] = [cmdCStr, inputCStr, nil]
              let status = mpv_command_enc(mpv, &args)
              if status != 0 {
                StreamifyLogger.log(
                  "MPVEncoder: subtitle extraction loadfile failed: \(mpvError(status))")
              }
              return status == 0
            }
          }
          guard loaded else {
            continuation.resume(returning: false)
            return
          }

          var succeeded = false
          var endedWithError = false
          eventLoop: while true {
            if session.isCancelled {
              session.cancel()
              break eventLoop
            }
            guard let event = c_mpv_wait_event(mpv, 0.2) else { break eventLoop }
            switch event.pointee.event_id {
            case 7:  // MPV_EVENT_END_FILE
              if let data = event.pointee.data {
                let endFile = data.assumingMemoryBound(to: MPVEncEventEndFile.self)
                succeeded = endFile.pointee.reason == 0
                endedWithError = endFile.pointee.error != 0 || endFile.pointee.reason == 4
                if !succeeded {
                  recentLogs.append(
                    "end_file reason=\(endFile.pointee.reason) error=\(mpvError(endFile.pointee.error))"
                  )
                }
              }
              break eventLoop
            case 1:  // MPV_EVENT_SHUTDOWN
              break eventLoop
            case 2:  // MPV_EVENT_LOG_MESSAGE
              appendLogMessage(from: event, to: &recentLogs)
            default:
              break
            }
          }

          // Verify the output file was actually written with content.
          let exists = FileManager.default.fileExists(atPath: outputURL.path)
          let size =
            (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
          let result =
            !session.isCancelled && (succeeded || (exists && size > 0 && !endedWithError))
          if !result {
            try? FileManager.default.removeItem(at: outputURL)
            logFailure(kind: "subtitle", logs: recentLogs)
          }
          continuation.resume(returning: result)
        }
      }
    } onCancel: {
      session.cancel()
    }
  }

  // MARK: - Private helpers

  private static func setopt(_ mpv: OpaquePointer, _ name: String, _ value: String) {
    name.withCString { nameCStr in
      value.withCString { valueCStr in
        _ = mpv_set_option_string_enc(mpv, nameCStr, valueCStr)
      }
    }
  }

  private static func requestLogMessages(_ mpv: OpaquePointer, _ level: String) {
    level.withCString { levelPointer in
      _ = c_mpv_request_log_messages(mpv, levelPointer)
    }
  }

  private static func mpvError(_ status: CInt) -> String {
    String(cString: c_mpv_error_string(status))
  }

  private static func appendLogMessage(
    from event: UnsafeMutablePointer<mpv_event>, to logs: inout [String]
  ) {
    guard let message = event.pointee.data?.assumingMemoryBound(to: MPVEncEventLogMessage.self)
    else { return }
    let level = String(cString: message.pointee.level)
    guard level == "warn" || level == "error" || level == "fatal" else { return }
    let prefix = String(cString: message.pointee.prefix)
    let text = String(cString: message.pointee.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    logs.append("[\(prefix)] \(text)")
    if logs.count > 6 {
      logs.removeFirst(logs.count - 6)
    }
  }

  private static func logFailure(kind: String, logs: [String]) {
    let detail = logs.isEmpty ? "no mpv diagnostics" : logs.joined(separator: " | ")
    StreamifyLogger.log("MPVEncoder: \(kind) extraction failed: \(detail)")
  }
}
