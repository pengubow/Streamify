import Foundation
import Compression

// MARK: - Zlib-compressed JSON helper
// Reads/writes JSON files with standard zlib compression (RFC 1950) for minimal storage.
// Read: tries .json.zlib (compressed), then .json (plain).
// Write: always writes .json.zlib with standard zlib compression.
// Uses Apple's Compression framework (available on all Apple platforms).

enum CompressedJSON {
    
    /// Maximum decompressed data size (100 MB) to prevent memory exhaustion
    private static let maxDecompressedSize = 100_000_000
    
    // MARK: - Encode + compress
    
    /// Encode a Codable value to compressed JSON data
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(value)
        return try compress(jsonData)
    }
    
    /// Encode and write to file (always compressed)
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encode(value)
        try data.write(to: url, options: .atomic)
    }
    
    // MARK: - Decompress + decode
    
    /// Decode a Codable value from data (tries decompression first, then plain JSON)
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let jsonData: Data
        if let decompressed = try? decompress(data) {
            jsonData = decompressed
        } else {
            // Data wasn't compressed - try as plain JSON
            jsonData = data
        }
        return try JSONDecoder().decode(type, from: jsonData)
    }
    
    /// Read and decode from file
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decode(type, from: data)
    }
    
    /// Try to read from compressed .zlib path first, fall back to plain JSON path
    static func readWithFallback<T: Decodable>(_ type: T.Type, compressedURL: URL, plainURL: URL) throws -> T {
        if FileManager.default.fileExists(atPath: compressedURL.path) {
            return try read(type, from: compressedURL)
        }
        // Fall back to plain JSON
        if FileManager.default.fileExists(atPath: plainURL.path) {
            let data = try Data(contentsOf: plainURL)
            return try JSONDecoder().decode(type, from: data)
        }
        throw CompressedJSONError.fileNotFound
    }
    
    /// Check if a file exists (checking compressed and plain)
    static func fileExists(compressedURL: URL, plainURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: compressedURL.path) ||
        FileManager.default.fileExists(atPath: plainURL.path)
    }
    
    // MARK: - Migration from .json.gz to .json.zlib
    
    /// Rename all .json.gz files to .json.zlib in the given directory (non-recursive).
    static func migrateGzToZlib(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".json.gz") {
            let oldURL = directory.appendingPathComponent(file)
            let newName = String(file.dropLast(8)) + ".json.zlib" // drop ".json.gz", add ".json.zlib"
            let newURL = directory.appendingPathComponent(newName)
            try? fm.moveItem(at: oldURL, to: newURL)
        }
    }
    
    /// Rename a single .json.gz to .json.zlib if it exists.
    static func migrateGzToZlib(at gzURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: gzURL.path) else { return }
        let path = gzURL.path
        guard path.hasSuffix(".json.gz") else { return }
        let newPath = String(path.dropLast(8)) + ".json.zlib"
        try? fm.moveItem(atPath: path, toPath: newPath)
    }
    
    /// One-time migration of all legacy .json.gz files across the app's Documents directory.
    /// Call once on app launch before any data is loaded.
    static func migrateAllGzToZlib() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 1. Documents root: sources.json.gz, library.json.gz, downloads.json.gz
        migrateGzToZlib(in: docs)
        
        // 2. Sources directory: <id>.json.gz files
        let sourcesDir = docs.appendingPathComponent("Sources")
        migrateGzToZlib(in: sourcesDir)
        
        // 3. Content subdirectories: progress.json.gz, metadata.json.gz in each subfolder (and nested season folders)
        let contentDir = docs.appendingPathComponent("Content")
        guard let contentFolders = try? fm.contentsOfDirectory(atPath: contentDir.path) else { return }
        for folder in contentFolders {
            let folderURL = contentDir.appendingPathComponent(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            migrateGzToZlib(in: folderURL)
            // Also check nested subdirectories (e.g. season folders with episode metadata)
            if let subfolders = try? fm.contentsOfDirectory(atPath: folderURL.path) {
                for sub in subfolders {
                    let subURL = folderURL.appendingPathComponent(sub)
                    var subIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: subURL.path, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
                    migrateGzToZlib(in: subURL)
                }
            }
        }
    }
    
    // MARK: - Standard zlib compression (RFC 1950)
    
    /// Compress data using standard zlib format: 2-byte header + raw deflate + 4-byte Adler-32
    private static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        
        let destinationBufferSize = max(data.count, 64)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destinationBuffer.deallocate() }
        
        let compressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, destinationBufferSize,
                baseAddress, data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        
        guard compressedSize > 0 else {
            throw CompressedJSONError.compressionFailed
        }
        
        // Standard zlib framing (RFC 1950):
        // [CMF=0x78][FLG=0xDA] + raw deflate + [Adler-32 big-endian]
        var result = Data()
        result.reserveCapacity(2 + compressedSize + 4)
        result.append(contentsOf: [0x78, 0xDA] as [UInt8])
        result.append(destinationBuffer, count: compressedSize)
        var adler32Checksum = adler32(data).bigEndian
        result.append(Data(bytes: &adler32Checksum, count: 4))
        return result
    }
    
    /// Decompress data, auto-detecting format:
    /// 1. Standard zlib (starts with 0x78) — new format
    /// 2. Legacy 8-byte size prefix + raw deflate — old format (auto-migrated on next write)
    private static func decompress(_ data: Data) throws -> Data {
        guard data.count > 2 else {
            throw CompressedJSONError.decompressionFailed
        }
        
        let rawDeflate: Data
        
        if data[data.startIndex] == 0x78 {
            // Standard zlib (RFC 1950): 2-byte header + deflate + 4-byte Adler-32
            guard data.count > 6 else { throw CompressedJSONError.decompressionFailed }
            rawDeflate = data[(data.startIndex + 2)..<(data.endIndex - 4)]
        } else if data.count > 8 {
            // Legacy format: 8-byte LE original-size prefix + raw deflate
            rawDeflate = data[(data.startIndex + 8)...]
        } else {
            throw CompressedJSONError.decompressionFailed
        }
        
        return try decompressRawDeflate(rawDeflate)
    }
    
    /// Stream-decompress raw deflate data (no size prefix needed)
    private static func decompressRawDeflate(_ data: Data) throws -> Data {
        var result = Data()
        let chunkSize = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        
        try data.withUnsafeBytes { sourcePtr in
            guard let base = sourcePtr.bindMemory(to: UInt8.self).baseAddress else {
                throw CompressedJSONError.decompressionFailed
            }
            
            var stream = compression_stream(dst_ptr: buffer, dst_size: chunkSize, src_ptr: base, src_size: data.count, state: nil)
            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard initStatus == COMPRESSION_STATUS_OK else {
                throw CompressedJSONError.decompressionFailed
            }
            defer { compression_stream_destroy(&stream) }
            
            stream.src_ptr = base
            stream.src_size = data.count
            
            var status: compression_status
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = chunkSize
                
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                
                let written = chunkSize - stream.dst_size
                if written > 0 {
                    result.append(buffer, count: written)
                }
                
                guard result.count <= maxDecompressedSize else {
                    throw CompressedJSONError.decompressionFailed
                }
            } while status == COMPRESSION_STATUS_OK
            
            guard status == COMPRESSION_STATUS_END else {
                throw CompressedJSONError.decompressionFailed
            }
        }
        
        return result
    }
    
    /// Compute Adler-32 checksum (RFC 1950) — batches modulo ops for performance
    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65521
        // Defer modulo every 5552 bytes (proven safe against UInt32 overflow)
        let batchSize = 5552
        var remaining = data.count
        var offset = data.startIndex
        while remaining > 0 {
            let count = min(remaining, batchSize)
            for i in offset..<(offset + count) {
                a += UInt32(data[i])
                b += a
            }
            a %= mod
            b %= mod
            offset += count
            remaining -= count
        }
        return (b << 16) | a
    }
}

enum CompressedJSONError: LocalizedError {
    case fileNotFound
    case compressionFailed
    case decompressionFailed
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "File not found"
        case .compressionFailed: return "Failed to compress data"
        case .decompressionFailed: return "Failed to decompress data"
        }
    }
}
