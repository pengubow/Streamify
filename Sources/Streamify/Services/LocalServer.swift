import Foundation
import Network

// MARK: - Local HTTP Server for serving HLS content
final class LocalServer: ObservableObject, @unchecked Sendable {
    static let shared = LocalServer()
    
    @Published var isRunning = false
    @Published var port: UInt16 = 0
    @Published var baseURL: String = ""
    @Published var statusMessage: String = "Not started"
    /// True when the user explicitly stopped the server via the UI.
    /// Used to prevent the Settings health-check loop from auto-restarting
    /// a server the user intentionally shut down.
    @Published var isManuallyStopped: Bool = false
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()
    private let contentDirectory: URL
    private let transientDirectory: URL
    private let queue = DispatchQueue(label: "com.streamify.localserver", qos: .utility)
    /// Maximum concurrent open connections. HLS playback needs ~3-6 at most;
    /// capping at 64 prevents unbounded accumulation under pathological clients.
    private let maxConnections = 64
    /// Seconds to wait for the first byte of an HTTP request before closing an idle connection.
    private let readIdleTimeout: TimeInterval = 30
    
    // Thread-safe storage for server info (different names to avoid @Published conflict)
    private let lock = NSLock()
    private var runningStatus: Bool = false
    private var serverURL: String = ""
    
    // Port persistence
    private let portDefaultsKey = "com.streamify.serverPort"
    var preferredPort: UInt16 {
        get {
            let saved = UserDefaults.standard.integer(forKey: portDefaultsKey)
            return saved > 0 ? UInt16(saved) : 8080
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: portDefaultsKey)
            StreamifyLogger.log("Server: Preferred port saved: \(newValue)")
        }
    }
    
    private init() {
        contentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Content")
        transientDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamifyTranscodes")
        StreamifyLogger.log("Server: Initialized with content directory: \(contentDirectory.path)")
        StreamifyLogger.log("Server: Preferred port: \(preferredPort)")
    }
    
    // MARK: - Start Server
    
    func start() {
        guard !isRunning else {
            StreamifyLogger.log("Server: Already running on port \(port)")
            return
        }
        
        StreamifyLogger.log("Server: Starting... (preferred port: \(preferredPort))")
        
        DispatchQueue.main.async {
            self.statusMessage = "Starting..."
        }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        // Try preferred port first
        do {
            if let port = NWEndpoint.Port(rawValue: preferredPort) {
                listener = try NWListener(using: parameters, on: port)
                StreamifyLogger.log("Server: Created listener on preferred port \(preferredPort)")
            } else {
                listener = try NWListener(using: parameters)
                StreamifyLogger.log("Server: Created listener with random port")
            }
        } catch {
            StreamifyLogger.log("Server: Failed to create listener on port \(preferredPort): \(error)")
            cancelListenerAndConnections()
            if let port = NWEndpoint.Port(rawValue: preferredPort) {
                do {
                    listener = try NWListener(using: parameters, on: port)
                    StreamifyLogger.log("Server: Recovered preferred port \(preferredPort) after cancelling stale listener")
                } catch {
                    StreamifyLogger.log("Server: Preferred port still unavailable after cleanup: \(error)")
                    if adoptExistingServerIfHealthy(on: preferredPort) {
                        return
                    }
                }
            }

            // Try with random port as fallback
            if listener == nil {
                do {
                    listener = try NWListener(using: parameters)
                    StreamifyLogger.log("Server: Created listener with random port as fallback")
                } catch {
                    StreamifyLogger.log("Server: Failed to create listener even with random port: \(error)")
                    DispatchQueue.main.async {
                        self.statusMessage = "Failed to start: \(error.localizedDescription)"
                    }
                    return
                }
            }
        }
        
        let weakSelf = WeakRef(self)
        
        listener?.stateUpdateHandler = { state in
            guard let self = weakSelf.value else { return }
            switch state {
            case .ready:
                if let port = self.listener?.port?.rawValue {
                    self.lock.lock()
                    self.runningStatus = true
                    self.serverURL = "http://localhost:\(port)"
                    self.lock.unlock()
                    
                    DispatchQueue.main.async {
                        self.port = port
                        self.baseURL = self.serverURL
                        self.isRunning = true
                        self.isManuallyStopped = false
                        self.statusMessage = "Running on port \(port)"
                    }
                    StreamifyLogger.log("Server: Started successfully on port \(port)")
                    StreamifyLogger.log("Server: Base URL: \(self.serverURL)")
                }
            case .failed(let error):
                StreamifyLogger.log("Server: Failed - \(error)")
                self.lock.lock()
                self.runningStatus = false
                self.serverURL = ""
                self.lock.unlock()
                
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.statusMessage = "Failed: \(error.localizedDescription)"
                }
            case .waiting(let error):
                StreamifyLogger.log("Server: Waiting - \(error)")
                DispatchQueue.main.async {
                    self.statusMessage = "Waiting..."
                }
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { connection in
            weakSelf.value?.handleConnection(connection)
        }
        
        listener?.start(queue: queue)
        StreamifyLogger.log("Server: Listener started on queue")
    }
    
    // MARK: - Stop Server
    
    func stop() {
        StreamifyLogger.log("Server: Stopping...")
        cancelListenerAndConnections()

        lock.lock()
        runningStatus = false
        serverURL = ""
        lock.unlock()
        
        DispatchQueue.main.async {
            self.isRunning = false
            self.isManuallyStopped = true
            self.port = 0
            self.baseURL = ""
            self.statusMessage = "Stopped"
        }

        StreamifyLogger.log("Server: Stopped")
    }

    private func cancelListenerAndConnections() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let conns = connections
        connections.removeAll()
        connectionsLock.unlock()
        conns.forEach { $0.cancel() }
    }

    private func adoptExistingServerIfHealthy(on port: UInt16) -> Bool {
        guard isServerHealthy(on: port) else { return false }
        let url = "http://localhost:\(port)"
        lock.lock()
        runningStatus = true
        serverURL = url
        lock.unlock()

        DispatchQueue.main.async {
            self.port = port
            self.baseURL = url
            self.isRunning = true
            self.isManuallyStopped = false
            self.statusMessage = "Running on port \(port)"
        }
        StreamifyLogger.log("Server: Adopted existing healthy listener on port \(port)")
        return true
    }

    private func isServerHealthy(on port: UInt16) -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0

        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            healthy = response is HTTPURLResponse
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.2)
        return healthy
    }

    // MARK: - Restart Server (with new port if changed)

    /// Synchronous restart - for backwards compatibility
    func restart() {
        StreamifyLogger.log("Server: Restarting (sync)...")
        Task {
            await restartAsync()
        }
    }

    /// Async restart - preferred for modern Swift concurrency
    func restartAsync() async {
        StreamifyLogger.log("Server: Restarting (async)...")
        stop()
        try? await Task.sleep(nanoseconds: 120_000_000)
        _ = await ensureRunningAsync()
    }
    
    // MARK: - Handle Connection
    
    private func handleConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        // Drop the oldest connection if we are at the cap to bound memory usage.
        if connections.count >= maxConnections {
            let oldest = connections.removeFirst()
            connectionsLock.unlock()
            oldest.cancel()
        } else {
            connectionsLock.unlock()
        }

        connectionsLock.lock()
        connections.append(connection)
        connectionsLock.unlock()
        
        let weakSelf = WeakRef(self)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                weakSelf.value?.receiveRequest(on: connection)
            case .failed(let error):
                StreamifyLogger.log("Connection failed: \(error)")
                weakSelf.value?.removeConnection(connection)
            case .cancelled:
                weakSelf.value?.removeConnection(connection)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func removeConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === connection }
        connectionsLock.unlock()
    }
    
    // MARK: - Receive Request
    
    private func receiveRequest(on connection: NWConnection) {
        let weakSelf = WeakRef(self)
        
        // Cancel the connection if no request data arrives within the idle timeout.
        // This prevents stalled connections from piling up under memory pressure.
        let timeoutWork = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + readIdleTimeout, execute: timeoutWork)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            timeoutWork.cancel()
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }
            
            if let requestString = String(data: data, encoding: .utf8) {
                weakSelf.value?.handleRequest(requestString, on: connection)
            }
        }
    }
    
    // MARK: - Handle Request
    
    private func handleRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(connection, statusCode: 400, message: "Bad Request")
            return
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            sendErrorResponse(connection, statusCode: 400, message: "Bad Request")
            return
        }
        
        let method = components[0]
        let requestTarget = components[1]
        let headers = parseHeaders(from: lines.dropFirst())
        
        guard method == "GET" || method == "HEAD" else {
            sendErrorResponse(connection, statusCode: 405, message: "Method Not Allowed")
            return
        }
        
        guard let fileURL = fileURL(forRequestTarget: requestTarget),
              isInsideAllowedDirectory(fileURL) else {
            sendErrorResponse(connection, statusCode: 403, message: "Forbidden")
            return
        }
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            sendErrorResponse(connection, statusCode: 404, message: "Not Found")
            return
        }
        
        serveFile(
            fileURL,
            headOnly: method == "HEAD",
            rangeHeader: headers["range"],
            on: connection
        )
    }
    
    private func parseHeaders(from lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }
    
    private func fileURL(forRequestTarget requestTarget: String) -> URL? {
        var path = requestTarget
        if let endOfPath = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<endOfPath])
        }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        
        guard !path.isEmpty else { return contentDirectory }
        
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return contentDirectory }

        let root: URL
        let pathSegments: ArraySlice<String>
        if segments.first == "__streamify_cache__" {
            root = transientDirectory
            pathSegments = segments.dropFirst()
        } else {
            root = contentDirectory
            pathSegments = segments[...]
        }

        var fileURL = root
        
        for segment in pathSegments {
            guard !segment.isEmpty,
                  segment != ".",
                  segment != ".." else { return nil }
            if let decoded = segment.removingPercentEncoding,
               decoded == "." || decoded == ".." || decoded.contains("/") {
                return nil
            }
            // Keep the raw percent-encoded segment. Content folders on disk
            // intentionally use names like "My%20Show".
            fileURL.appendPathComponent(segment)
        }
        return fileURL
    }
    
    private func isInsideAllowedDirectory(_ fileURL: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return isInside(filePath: filePath, root: contentDirectory) ||
            isInside(filePath: filePath, root: transientDirectory)
    }

    private func isInside(filePath: String, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }
    
    // MARK: - Serve File
    
    private struct ByteRange {
        let start: Int64
        let end: Int64
        
        var length: Int64 { end - start + 1 }
    }
    
    private func parseRangeHeader(_ header: String?, fileSize: Int64) -> ByteRange? {
        guard let header,
              fileSize > 0,
              header.lowercased().hasPrefix("bytes=") else { return nil }
        
        let rawSpec = header.dropFirst("bytes=".count)
        guard let firstSpec = rawSpec.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        let parts = firstSpec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        
        if parts[0].isEmpty {
            guard let suffixLength = Int64(parts[1]), suffixLength > 0 else { return nil }
            let start = max(fileSize - suffixLength, 0)
            return ByteRange(start: start, end: fileSize - 1)
        }
        
        guard let start = Int64(parts[0]), start >= 0, start < fileSize else { return nil }
        let end: Int64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else {
            guard let requestedEnd = Int64(parts[1]), requestedEnd >= start else { return nil }
            end = min(requestedEnd, fileSize - 1)
        }
        return ByteRange(start: start, end: end)
    }
    
    private func serveFile(_ fileURL: URL, headOnly: Bool = false, rangeHeader: String? = nil, on connection: NWConnection) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            sendErrorResponse(connection, statusCode: 500, message: "Internal Server Error")
            return
        }
        
        let fileSize = sizeNumber.int64Value
        let requestedRange = parseRangeHeader(rangeHeader, fileSize: fileSize)
        if rangeHeader != nil && requestedRange == nil {
            sendRangeNotSatisfiable(connection, fileSize: fileSize)
            return
        }
        
        let byteRange = requestedRange ?? ByteRange(
            start: 0,
            end: max(fileSize - 1, 0)
        )
        let mimeType = self.mimeType(for: fileURL)
        var headers = [
            requestedRange == nil ? "HTTP/1.1 200 OK" : "HTTP/1.1 206 Partial Content",
            "Content-Type: \(mimeType)",
            "Content-Length: \(fileSize == 0 ? 0 : byteRange.length)",
            "Accept-Ranges: bytes",
            "Connection: close",
            "Access-Control-Allow-Origin: *"
        ]
        if requestedRange != nil {
            headers.append("Content-Range: bytes \(byteRange.start)-\(byteRange.end)/\(fileSize)")
        }
        headers.append("")
        let headerString = headers.joined(separator: "\r\n")
        
        guard var headerData = headerString.data(using: .utf8) else {
            connection.cancel()
            return
        }
        headerData.append(contentsOf: "\r\n".utf8)
        
        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                StreamifyLogger.log("Error sending response: \(error)")
                connection.cancel()
                return
            }
            guard !headOnly, fileSize > 0 else {
                connection.cancel()
                return
            }
            guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
                connection.cancel()
                return
            }
            do {
                try fileHandle.seek(toOffset: UInt64(byteRange.start))
            } catch {
                fileHandle.closeFile()
                connection.cancel()
                return
            }
            self?.sendFileChunk(
                from: fileHandle,
                remainingBytes: byteRange.length,
                on: connection
            )
        })
    }
    
    private func sendFileChunk(from fileHandle: FileHandle, remainingBytes: Int64, on connection: NWConnection) {
        guard remainingBytes > 0 else {
            fileHandle.closeFile()
            connection.cancel()
            return
        }
        
        let chunkSize = Int(min(remainingBytes, 256 * 1024))
        let data = fileHandle.readData(ofLength: chunkSize)
        guard !data.isEmpty else {
            fileHandle.closeFile()
            connection.cancel()
            return
        }
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                StreamifyLogger.log("Error sending file chunk: \(error)")
                fileHandle.closeFile()
                connection.cancel()
                return
            }
            self?.sendFileChunk(
                from: fileHandle,
                remainingBytes: remainingBytes - Int64(data.count),
                on: connection
            )
        })
    }
    
    // MARK: - Error Response
    
    private func sendErrorResponse(_ connection: NWConnection, statusCode: Int, message: String) {
        let body = "<html><body><h1>\(statusCode) \(message)</h1></body></html>"
        let headers = [
            "HTTP/1.1 \(statusCode) \(message)",
            "Content-Type: text/html",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            ""
        ].joined(separator: "\r\n")
        
        guard var responseData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        responseData.append(contentsOf: "\r\n".utf8)
        responseData.append(contentsOf: body.utf8)
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendRangeNotSatisfiable(_ connection: NWConnection, fileSize: Int64) {
        let headers = [
            "HTTP/1.1 416 Range Not Satisfiable",
            "Content-Range: bytes */\(fileSize)",
            "Content-Length: 0",
            "Connection: close",
            ""
        ].joined(separator: "\r\n")
        
        guard var responseData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        responseData.append(contentsOf: "\r\n".utf8)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    // MARK: - MIME Types
    
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        case "mp4":
            return "video/mp4"
        case "m4s":
            return "video/iso.segment"
        case "m4v":
            return "video/mp4"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "json":
            return "application/json"
        case "xml":
            return "application/xml"
        case "vtt":
            return "text/vtt"
        case "srt":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }
    
    // MARK: - Get URL for content
    
    func url(for path: String) -> URL? {
        guard isRunning else { return nil }
        return URL(string: "\(baseURL)/\(path)")
    }

    func urlForContentFile(_ fileURL: URL) -> URL? {
        urlForFile(fileURL, root: contentDirectory, prefix: nil)
    }

    func urlForTransientFile(_ fileURL: URL) -> URL? {
        urlForFile(fileURL, root: transientDirectory, prefix: "__streamify_cache__")
    }

    private func urlForFile(_ fileURL: URL, root: URL, prefix: String?) -> URL? {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        if !ensureRunning() { return nil }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let path = [prefix, relative].compactMap { $0 }.joined(separator: "/")
        let info = getServerInfo()
        return URL(string: "\(info.baseURL)/\(path)")
    }
    
    // MARK: - Ensure server is running
    
    /// Ensures the server is running, starting it if necessary
    /// Synchronous version - uses RunLoop to wait without blocking the thread
    /// Returns true if server is running (either already running or just started)
    @discardableResult
    func ensureRunning() -> Bool {
        // Check if we have a valid listener and it's actually running
        if isRunning && runningStatus {
            // Flags say running — do a quick synchronous health probe to catch broken state
            if let url = URL(string: baseURL) {
                var request = URLRequest(url: url)
                request.timeoutInterval = 1.5
                let semaphore = DispatchSemaphore(value: 0)
                var healthy = false
                let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                    healthy = response is HTTPURLResponse
                    semaphore.signal()
                }
                task.resume()
                semaphore.wait()
                if healthy {
                    StreamifyLogger.log("Server: Already running and healthy")
                    return true
                }
                StreamifyLogger.log("Server: Running but NOT healthy, restarting...")
                stop()
            } else {
                StreamifyLogger.log("Server: Already running, no need to restart")
                return true
            }
        } else {
            // Server not actually running, need to restart
            StreamifyLogger.log("Server: Not actually running (listener=\(listener != nil), isRunning=\(isRunning), runningStatus=\(runningStatus)), starting...")
        }
        
        // Reset state
        lock.lock()
        runningStatus = false
        serverURL = ""
        lock.unlock()
        
        // Clear old listener
        listener?.cancel()
        listener = nil
        
        DispatchQueue.main.async {
            self.isRunning = false
            self.statusMessage = "Restarting..."
        }
        
        // Start the server
        start()
        
        // Use RunLoop to wait for server to start (non-blocking)
        // This processes events while waiting, unlike Thread.sleep
        let timeout = Date().addingTimeInterval(2.0)
        let runLoop = RunLoop.current
        while !isRunning && Date() < timeout {
            runLoop.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        
        // Check if started successfully
        let success = isRunning && runningStatus
        StreamifyLogger.log("Server: ensureRunning result: \(success)")
        return success
    }
    
    /// Async version that doesn't block the calling thread
    /// Returns true if server is running after the operation
    @discardableResult
    func ensureRunningAsync() async -> Bool {
        // Check if we have a valid listener and it's actually running
        if isRunning && runningStatus {
            // Flags say running — do an actual health check to catch broken state
            let healthy = await checkServerHealth()
            if healthy {
                StreamifyLogger.log("Server: Already running and healthy")
                return true
            }
            StreamifyLogger.log("Server: Running but NOT healthy, restarting...")
            stop()
        } else {
            StreamifyLogger.log("Server: Not actually running, starting asynchronously...")
        }
        
        // Reset state on the queue (thread-safe)
        queue.sync {
            runningStatus = false
            serverURL = ""
        }
        
        // Clear old listener
        listener?.cancel()
        listener = nil
        
        await MainActor.run {
            self.isRunning = false
            self.statusMessage = "Starting..."
        }
        
        // Start the server
        start()
        
        // Wait for server to start (with timeout)
        let maxWait: TimeInterval = 3.0
        let startTime = Date()
        
        while !isRunning && Date().timeIntervalSince(startTime) < maxWait {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        let success = isRunning && runningStatus
        StreamifyLogger.log("Server: ensureRunningAsync result: \(success)")
        return success
    }
    
    // MARK: - Health Check
    
    /// Check if server is actually responding to requests
    /// Returns true if server responds successfully, false otherwise
    func checkServerHealth() async -> Bool {
        guard isRunning, !baseURL.isEmpty, let url = URL(string: baseURL) else {
            return false
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2.0
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
    
    // MARK: - Thread-safe accessor for nonisolated contexts
    
    /// Get server info synchronously (thread-safe)
    func getServerInfo() -> (isRunning: Bool, baseURL: String) {
        lock.lock()
        defer { lock.unlock() }
        return (runningStatus, serverURL)
    }
}

// MARK: - Weak Reference Helper
private final class WeakRef: @unchecked Sendable {
    weak var value: LocalServer?
    init(_ value: LocalServer?) {
        self.value = value
    }
}
