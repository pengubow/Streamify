import Foundation

// MARK: - VidLink Service
// Handles encryption and API communication with vidlink.pro
// Uses XSalsa20-Poly1305 (NaCl secretbox) implemented in pure Swift

enum VidLinkService {

    // MARK: - Response types

    struct VidLinkResponse: Codable {
        let stream: VidLinkStream?
    }

    struct VidLinkStream: Codable {
        let playlist: String?
        let captions: [VidLinkCaption]?
    }

    struct VidLinkCaption: Codable {
        let url: String?
        let language: String?
    }
    
    struct VidLinkResult {
        let hlsUrl: String
        let subtitles: [SubtitleTrack]
    }
    
    // MARK: - VidLink Request Helpers
    
    /// The standard Referer header value for all VidLink proxy requests.
    /// All VidLink-proxied URLs (playlists, segments, etc.) require this same Referer.
    static let vidLinkReferer = "https://vidlink.pro/"
    
    /// Creates a URLRequest for a VidLink-proxied URL with the correct headers.
    /// VidLink proxy URLs always need `Referer: https://vidlink.pro/` — the embedded
    /// `?headers=` query parameter in the URL is for the proxy's upstream, not for us.
    static func makeRequest(for urlString: String, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        request.setValue(vidLinkReferer, forHTTPHeaderField: "Referer")
        
        return request
    }
    
    /// Checks if a URL is a VidLink proxy URL (hosted on vodvidl.site or similar proxy domains).
    /// NOTE: For downloads, prefer checking `download.tmdbId != nil` instead of this method,
    /// since the proxy domain may change in the future.
    static func isVidLinkProxyURL(_ urlString: String) -> Bool {
        return urlString.contains("vodvidl.site") || urlString.contains("vidlink.pro")
    }
    
    // MARK: - Public API
    
    /// Fetch a playable stream for a movie
    static func fetchMovieStream(tmdbId: Int) async -> VidLinkResult? {
        let token = encryptToken(mediaId: "\(tmdbId)")
        let urlString = "https://vidlink.pro/api/b/movie/\(token)?multiLang=1"
        return await fetchStream(from: urlString)
    }
    
    /// Fetch a playable stream for a TV episode
    static func fetchEpisodeStream(tmdbId: Int, season: Int, episode: Int) async -> VidLinkResult? {
        let token = encryptToken(mediaId: "\(tmdbId)")
        let urlString = "https://vidlink.pro/api/b/tv/\(token)/\(season)/\(episode)?multiLang=1"
        return await fetchStream(from: urlString)
    }
    
    /// Resolve a TMDB ID to a playable URL + subtitles
    /// For movies: pass season=nil, episode=nil
    /// For episodes: pass season and episode numbers
    static func resolveStream(tmdbId: Int, type: ContentType, season: Int? = nil, episode: Int? = nil) async -> VidLinkResult? {
        if type == .series, let season = season, let episode = episode {
            return await fetchEpisodeStream(tmdbId: tmdbId, season: season, episode: episode)
        } else {
            return await fetchMovieStream(tmdbId: tmdbId)
        }
    }
    
    // MARK: - Private Implementation
    
    private static func fetchStream(from urlString: String) async -> VidLinkResult? {
        guard let url = URL(string: urlString) else {
            StreamifyLogger.log("VidLinkService: Invalid URL: \(urlString)")
            return nil
        }
        
        StreamifyLogger.log("VidLinkService: Fetching stream from \(urlString)")
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("https://vidlink.pro", forHTTPHeaderField: "Origin")
            request.setValue("https://vidlink.pro/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                StreamifyLogger.log("VidLinkService: HTTP error \(statusCode)")
                return nil
            }
            
            let decoded = try JSONDecoder().decode(VidLinkResponse.self, from: data)
            
            guard let playlist = decoded.stream?.playlist, !playlist.isEmpty else {
                StreamifyLogger.log("VidLinkService: No playlist in response")
                return nil
            }
            
            // Convert captions to SubtitleTrack array
            let subtitles: [SubtitleTrack] = (decoded.stream?.captions ?? []).compactMap { caption in
                guard let captionUrl = caption.url, !captionUrl.isEmpty,
                      let language = caption.language, !language.isEmpty else { return nil }
                return SubtitleTrack(
                    language: language,
                    source: captionUrl,
                    languageId: language.lowercased().replacingOccurrences(of: " ", with: "_"),
                    name: language,
                    trackId: TrackIdentity.stableTrackId(
                        type: "subtitle",
                        source: captionUrl,
                        languageId: language,
                        name: language,
                        sourceName: "VidLink"
                    ),
                    sourceName: "VidLink"
                )
            }
            
            StreamifyLogger.log("VidLinkService: Got playlist with \(subtitles.count) subtitle(s)")
            return VidLinkResult(hlsUrl: playlist, subtitles: subtitles)
        } catch {
            StreamifyLogger.log("VidLinkService: Error fetching stream: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Token Encryption
    
    static func encryptToken(mediaId: String) -> String {
        // Public API key for vidlink.pro token generation (not a secret/credential)
        let keyHex = "c75136c5668bbfe65a7ecad431a745db68b5f381555b38d8f6c699449cf11fcd"
        let key = StreamifyHex.bytes(from: keyHex)
        let nonce = [UInt8](repeating: 0, count: 24)
        
        let timestamp = UInt64(Date().timeIntervalSince1970) + 480
        let idBytes = [UInt8](mediaId.utf8)
        
        // Encode timestamp as 8 bytes big-endian
        var tsBuf = [UInt8](repeating: 0, count: 8)
        tsBuf[0] = UInt8((timestamp >> 56) & 0xFF)
        tsBuf[1] = UInt8((timestamp >> 48) & 0xFF)
        tsBuf[2] = UInt8((timestamp >> 40) & 0xFF)
        tsBuf[3] = UInt8((timestamp >> 32) & 0xFF)
        tsBuf[4] = UInt8((timestamp >> 24) & 0xFF)
        tsBuf[5] = UInt8((timestamp >> 16) & 0xFF)
        tsBuf[6] = UInt8((timestamp >> 8) & 0xFF)
        tsBuf[7] = UInt8(timestamp & 0xFF)
        
        // message = mediaId bytes + timestamp bytes
        var message = idBytes
        message.append(contentsOf: tsBuf)
        
        // NaCl secretbox encryption
        let encrypted = NaClSecretBox.seal(message: message, nonce: nonce, key: key)
        
        // payload = nonce + encrypted (tag + ciphertext)
        var payload = nonce
        payload.append(contentsOf: encrypted)
        
        // Base64url encode (no padding)
        let b64 = Data(payload).base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - NaCl SecretBox (XSalsa20-Poly1305)
// Pure Swift implementation of the NaCl crypto_secretbox construct

private enum NaClSecretBox {
    
    /// Encrypt message using XSalsa20-Poly1305
    /// Returns: Poly1305 tag (16 bytes) + ciphertext
    static func seal(message: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        // Pad message with 32 zero bytes (crypto_secretbox_ZEROBYTES)
        let m = [UInt8](repeating: 0, count: 32) + message
        var c = [UInt8](repeating: 0, count: m.count)
        
        // XSalsa20 XOR
        xsalsa20Xor(&c, m, nonce, key)
        
        // Poly1305 authenticate (c[32:] using key c[0:32])
        let tag = poly1305(message: Array(c[32...]), key: Array(c[0..<32]))
        
        // Place tag at c[16..32], zero c[0..16]
        for i in 0..<16 { c[i] = 0 }
        for i in 0..<16 { c[16 + i] = tag[i] }
        
        // Return c[16:] = tag(16) + ciphertext(message.count)
        return Array(c[16...])
    }
    
    // MARK: - XSalsa20
    
    private static func xsalsa20Xor(_ c: inout [UInt8], _ m: [UInt8], _ n: [UInt8], _ k: [UInt8]) {
        // HSalsa20 to derive subkey from first 16 bytes of nonce
        let subkey = hsalsa20(input: Array(n[0..<16]), key: k)
        // Salsa20 uses the last 8 bytes of the XSalsa20 nonce.
        salsa20Xor(&c, m, Array(n[16..<24]), subkey)
    }
    
    // MARK: - Salsa20 stream XOR
    
    private static func salsa20Xor(_ c: inout [UInt8], _ m: [UInt8], _ n: [UInt8], _ k: [UInt8]) {
        let len = m.count
        if len == 0 { return }
        
        // sigma = "expand 32-byte k"
        let sigma: [UInt8] = [101, 120, 112, 97, 110, 100, 32, 51, 50, 45, 98, 121, 116, 101, 32, 107]
        
        var counter: UInt64 = 0
        var offset = 0
        
        while offset < len {
            // Build 16-byte input for core: 8 bytes nonce + 8 bytes counter
            var input = [UInt8](repeating: 0, count: 16)
            for i in 0..<min(8, n.count) { input[i] = n[i] }
            input[8]  = UInt8(counter & 0xFF)
            input[9]  = UInt8((counter >> 8) & 0xFF)
            input[10] = UInt8((counter >> 16) & 0xFF)
            input[11] = UInt8((counter >> 24) & 0xFF)
            input[12] = UInt8((counter >> 32) & 0xFF)
            input[13] = UInt8((counter >> 40) & 0xFF)
            input[14] = UInt8((counter >> 48) & 0xFF)
            input[15] = UInt8((counter >> 56) & 0xFF)
            
            let block = coreSalsa20(input: input, key: k, constant: sigma)
            
            let blockLen = min(64, len - offset)
            for i in 0..<blockLen {
                c[offset + i] = m[offset + i] ^ block[i]
            }
            
            offset += 64
            counter += 1
        }
    }
    
    // MARK: - HSalsa20 (key derivation)
    
    private static func hsalsa20(input: [UInt8], key: [UInt8]) -> [UInt8] {
        let sigma: [UInt8] = [101, 120, 112, 97, 110, 100, 32, 51, 50, 45, 98, 121, 116, 101, 32, 107]
        
        var x0  = ld32(sigma, 0)
        var x1  = ld32(key, 0)
        var x2  = ld32(key, 4)
        var x3  = ld32(key, 8)
        var x4  = ld32(key, 12)
        var x5  = ld32(sigma, 4)
        var x6  = ld32(input, 0)
        var x7  = ld32(input, 4)
        var x8  = ld32(input, 8)
        var x9  = ld32(input, 12)
        var x10 = ld32(sigma, 8)
        var x11 = ld32(key, 16)
        var x12 = ld32(key, 20)
        var x13 = ld32(key, 24)
        var x14 = ld32(key, 28)
        var x15 = ld32(sigma, 12)
        
        for _ in stride(from: 20, to: 0, by: -2) {
            // Column round
            x4  ^= rotl(x0  &+ x12, 7);  x8  ^= rotl(x4  &+ x0,  9)
            x12 ^= rotl(x8  &+ x4, 13);  x0  ^= rotl(x12 &+ x8, 18)
            x9  ^= rotl(x5  &+ x1,  7);  x13 ^= rotl(x9  &+ x5,  9)
            x1  ^= rotl(x13 &+ x9, 13);  x5  ^= rotl(x1  &+ x13,18)
            x14 ^= rotl(x10 &+ x6,  7);  x2  ^= rotl(x14 &+ x10, 9)
            x6  ^= rotl(x2  &+ x14,13);  x10 ^= rotl(x6  &+ x2, 18)
            x3  ^= rotl(x15 &+ x11, 7);  x7  ^= rotl(x3  &+ x15, 9)
            x11 ^= rotl(x7  &+ x3, 13);  x15 ^= rotl(x11 &+ x7, 18)
            // Row round
            x1  ^= rotl(x0  &+ x3,  7);  x2  ^= rotl(x1  &+ x0,  9)
            x3  ^= rotl(x2  &+ x1, 13);  x0  ^= rotl(x3  &+ x2, 18)
            x6  ^= rotl(x5  &+ x4,  7);  x7  ^= rotl(x6  &+ x5,  9)
            x4  ^= rotl(x7  &+ x6, 13);  x5  ^= rotl(x4  &+ x7, 18)
            x11 ^= rotl(x10 &+ x9,  7);  x8  ^= rotl(x11 &+ x10, 9)
            x9  ^= rotl(x8  &+ x11,13);  x10 ^= rotl(x9  &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7);  x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12,13);  x15 ^= rotl(x14 &+ x13,18)
        }
        
        // HSalsa20 output: specific words WITHOUT final addition
        var out = [UInt8](repeating: 0, count: 32)
        st32(&out, 0, x0)
        st32(&out, 4, x5)
        st32(&out, 8, x10)
        st32(&out, 12, x15)
        st32(&out, 16, x6)
        st32(&out, 20, x7)
        st32(&out, 24, x8)
        st32(&out, 28, x9)
        return out
    }
    
    // MARK: - Salsa20 Core
    
    private static func coreSalsa20(input: [UInt8], key: [UInt8], constant: [UInt8]) -> [UInt8] {
        var x0  = ld32(constant, 0)
        var x1  = ld32(key, 0)
        var x2  = ld32(key, 4)
        var x3  = ld32(key, 8)
        var x4  = ld32(key, 12)
        var x5  = ld32(constant, 4)
        var x6  = ld32(input, 0)
        var x7  = ld32(input, 4)
        var x8  = ld32(input, 8)
        var x9  = ld32(input, 12)
        var x10 = ld32(constant, 8)
        var x11 = ld32(key, 16)
        var x12 = ld32(key, 20)
        var x13 = ld32(key, 24)
        var x14 = ld32(key, 28)
        var x15 = ld32(constant, 12)
        
        let j0 = x0, j1 = x1, j2 = x2, j3 = x3, j4 = x4, j5 = x5, j6 = x6, j7 = x7
        let j8 = x8, j9 = x9, j10 = x10, j11 = x11, j12 = x12, j13 = x13, j14 = x14, j15 = x15
        
        for _ in stride(from: 20, to: 0, by: -2) {
            // Column round
            x4  ^= rotl(x0  &+ x12, 7);  x8  ^= rotl(x4  &+ x0,  9)
            x12 ^= rotl(x8  &+ x4, 13);  x0  ^= rotl(x12 &+ x8, 18)
            x9  ^= rotl(x5  &+ x1,  7);  x13 ^= rotl(x9  &+ x5,  9)
            x1  ^= rotl(x13 &+ x9, 13);  x5  ^= rotl(x1  &+ x13,18)
            x14 ^= rotl(x10 &+ x6,  7);  x2  ^= rotl(x14 &+ x10, 9)
            x6  ^= rotl(x2  &+ x14,13);  x10 ^= rotl(x6  &+ x2, 18)
            x3  ^= rotl(x15 &+ x11, 7);  x7  ^= rotl(x3  &+ x15, 9)
            x11 ^= rotl(x7  &+ x3, 13);  x15 ^= rotl(x11 &+ x7, 18)
            // Row round
            x1  ^= rotl(x0  &+ x3,  7);  x2  ^= rotl(x1  &+ x0,  9)
            x3  ^= rotl(x2  &+ x1, 13);  x0  ^= rotl(x3  &+ x2, 18)
            x6  ^= rotl(x5  &+ x4,  7);  x7  ^= rotl(x6  &+ x5,  9)
            x4  ^= rotl(x7  &+ x6, 13);  x5  ^= rotl(x4  &+ x7, 18)
            x11 ^= rotl(x10 &+ x9,  7);  x8  ^= rotl(x11 &+ x10, 9)
            x9  ^= rotl(x8  &+ x11,13);  x10 ^= rotl(x9  &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7);  x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12,13);  x15 ^= rotl(x14 &+ x13,18)
        }
        
        // Add back original state
        x0 = x0 &+ j0; x1 = x1 &+ j1; x2 = x2 &+ j2; x3 = x3 &+ j3
        x4 = x4 &+ j4; x5 = x5 &+ j5; x6 = x6 &+ j6; x7 = x7 &+ j7
        x8 = x8 &+ j8; x9 = x9 &+ j9; x10 = x10 &+ j10; x11 = x11 &+ j11
        x12 = x12 &+ j12; x13 = x13 &+ j13; x14 = x14 &+ j14; x15 = x15 &+ j15
        
        var out = [UInt8](repeating: 0, count: 64)
        st32(&out, 0, x0);   st32(&out, 4, x1);   st32(&out, 8, x2);   st32(&out, 12, x3)
        st32(&out, 16, x4);  st32(&out, 20, x5);  st32(&out, 24, x6);  st32(&out, 28, x7)
        st32(&out, 32, x8);  st32(&out, 36, x9);  st32(&out, 40, x10); st32(&out, 44, x11)
        st32(&out, 48, x12); st32(&out, 52, x13); st32(&out, 56, x14); st32(&out, 60, x15)
        return out
    }
    
    // MARK: - Poly1305 one-time authenticator
    
    private static func poly1305(message: [UInt8], key: [UInt8]) -> [UInt8] {
        // Clamp r (first 16 bytes of key)
        var r = [UInt32](repeating: 0, count: 5)
        r[0] = (ld32(key, 0)) & 0x3ffffff
        r[1] = (ld32(key, 3) >> 2) & 0x3ffff03
        r[2] = (ld32(key, 6) >> 4) & 0x3ffc0ff
        r[3] = (ld32(key, 9) >> 6) & 0x3f03fff
        r[4] = (ld32(key, 12) >> 8) & 0x00fffff
        
        // s = last 16 bytes of key
        let s0 = ld32(key, 16)
        let s1 = ld32(key, 20)
        let s2 = ld32(key, 24)
        let s3 = ld32(key, 28)
        
        // Accumulator
        var h = [UInt32](repeating: 0, count: 5)
        
        // Precompute 5*r[i] for reduction
        let r1_5 = UInt64(r[1]) * 5
        let r2_5 = UInt64(r[2]) * 5
        let r3_5 = UInt64(r[3]) * 5
        let r4_5 = UInt64(r[4]) * 5
        
        var offset = 0
        while offset < message.count {
            let blockLen = min(16, message.count - offset)
            
            // Read block and add to accumulator
            var n = [UInt32](repeating: 0, count: 5)
            if blockLen >= 16 {
                n[0] = ld32(message, offset) & 0x3ffffff
                n[1] = (ld32(message, offset + 3) >> 2) & 0x3ffffff
                n[2] = (ld32(message, offset + 6) >> 4) & 0x3ffffff
                n[3] = (ld32(message, offset + 9) >> 6) & 0x3ffffff
                n[4] = (ld32(message, offset + 12) >> 8) | (1 << 24)  // hibit
            } else {
                // Partial block
                var buf = [UInt8](repeating: 0, count: 17)
                for i in 0..<blockLen { buf[i] = message[offset + i] }
                buf[blockLen] = 1  // padding
                n[0] = (UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24) & 0x3ffffff
                n[1] = ((UInt32(buf[3]) | UInt32(buf[4]) << 8 | UInt32(buf[5]) << 16 | UInt32(buf[6]) << 24) >> 2) & 0x3ffffff
                n[2] = ((UInt32(buf[6]) | UInt32(buf[7]) << 8 | UInt32(buf[8]) << 16 | UInt32(buf[9]) << 24) >> 4) & 0x3ffffff
                n[3] = ((UInt32(buf[9]) | UInt32(buf[10]) << 8 | UInt32(buf[11]) << 16 | UInt32(buf[12]) << 24) >> 6) & 0x3ffffff
                n[4] = (UInt32(buf[12]) | UInt32(buf[13]) << 8 | UInt32(buf[14]) << 16 | UInt32(buf[15]) << 24) >> 8
                // No hibit for partial blocks (already added via padding byte)
            }
            
            h[0] = h[0] &+ n[0]
            h[1] = h[1] &+ n[1]
            h[2] = h[2] &+ n[2]
            h[3] = h[3] &+ n[3]
            h[4] = h[4] &+ n[4]
            
            // Multiply h by r mod p
            let d0 = UInt64(h[0]) * UInt64(r[0]) + UInt64(h[1]) * r4_5 + UInt64(h[2]) * r3_5 + UInt64(h[3]) * r2_5 + UInt64(h[4]) * r1_5
            let d1 = UInt64(h[0]) * UInt64(r[1]) + UInt64(h[1]) * UInt64(r[0]) + UInt64(h[2]) * r4_5 + UInt64(h[3]) * r3_5 + UInt64(h[4]) * r2_5
            let d2 = UInt64(h[0]) * UInt64(r[2]) + UInt64(h[1]) * UInt64(r[1]) + UInt64(h[2]) * UInt64(r[0]) + UInt64(h[3]) * r4_5 + UInt64(h[4]) * r3_5
            let d3 = UInt64(h[0]) * UInt64(r[3]) + UInt64(h[1]) * UInt64(r[2]) + UInt64(h[2]) * UInt64(r[1]) + UInt64(h[3]) * UInt64(r[0]) + UInt64(h[4]) * r4_5
            let d4 = UInt64(h[0]) * UInt64(r[4]) + UInt64(h[1]) * UInt64(r[3]) + UInt64(h[2]) * UInt64(r[2]) + UInt64(h[3]) * UInt64(r[1]) + UInt64(h[4]) * UInt64(r[0])
            
            // Carry propagation
            var c0 = d0 >> 26; h[0] = UInt32(d0 & 0x3ffffff)
            let c1 = (d1 + c0) >> 26; h[1] = UInt32((d1 + c0) & 0x3ffffff)
            let c2 = (d2 + c1) >> 26; h[2] = UInt32((d2 + c1) & 0x3ffffff)
            let c3 = (d3 + c2) >> 26; h[3] = UInt32((d3 + c2) & 0x3ffffff)
            let c4 = (d4 + c3) >> 26; h[4] = UInt32((d4 + c3) & 0x3ffffff)
            h[0] = h[0] &+ UInt32(c4) * 5
            c0 = UInt64(h[0]) >> 26; h[0] = h[0] & 0x3ffffff
            h[1] = h[1] &+ UInt32(c0)
            
            offset += blockLen
        }
        
        // Final carry propagation
        var carry: UInt32 = 0
        carry = h[1] >> 26; h[1] &= 0x3ffffff; h[2] = h[2] &+ carry
        carry = h[2] >> 26; h[2] &= 0x3ffffff; h[3] = h[3] &+ carry
        carry = h[3] >> 26; h[3] &= 0x3ffffff; h[4] = h[4] &+ carry
        carry = h[4] >> 26; h[4] &= 0x3ffffff; h[0] = h[0] &+ carry * 5
        carry = h[0] >> 26; h[0] &= 0x3ffffff; h[1] = h[1] &+ carry
        
        // Compute h - p (p = 2^130 - 5)
        var g = [UInt32](repeating: 0, count: 5)
        g[0] = h[0] &+ 5
        carry = g[0] >> 26; g[0] &= 0x3ffffff
        g[1] = h[1] &+ carry; carry = g[1] >> 26; g[1] &= 0x3ffffff
        g[2] = h[2] &+ carry; carry = g[2] >> 26; g[2] &= 0x3ffffff
        g[3] = h[3] &+ carry; carry = g[3] >> 26; g[3] &= 0x3ffffff
        g[4] = h[4] &+ carry &- (1 << 26)
        
        // Select h or g based on carry (constant-time)
        let mask = (g[4] >> 31) &- 1  // 0xFFFFFFFF if h >= p (use g), 0 if h < p (use h)
        h[0] = (g[0] & mask) | (h[0] & ~mask)
        h[1] = (g[1] & mask) | (h[1] & ~mask)
        h[2] = (g[2] & mask) | (h[2] & ~mask)
        h[3] = (g[3] & mask) | (h[3] & ~mask)
        h[4] = (g[4] & mask) | (h[4] & ~mask)
        
        // Flatten h to 4 x UInt32 (must mask to 32 bits; 26-bit limbs overlap)
        let f0 = (UInt64(h[0]) | (UInt64(h[1]) << 26)) & 0xFFFFFFFF
        let f1 = ((UInt64(h[1]) >> 6) | (UInt64(h[2]) << 20)) & 0xFFFFFFFF
        let f2 = ((UInt64(h[2]) >> 12) | (UInt64(h[3]) << 14)) & 0xFFFFFFFF
        let f3 = ((UInt64(h[3]) >> 18) | (UInt64(h[4]) << 8)) & 0xFFFFFFFF
        
        // Add s
        let t0 = f0 + UInt64(s0)
        let t1 = f1 + UInt64(s1) + (t0 >> 32)
        let t2 = f2 + UInt64(s2) + (t1 >> 32)
        let t3 = f3 + UInt64(s3) + (t2 >> 32)
        
        // Output 16 bytes little-endian
        var tag = [UInt8](repeating: 0, count: 16)
        st32(&tag, 0, UInt32(t0 & 0xFFFFFFFF))
        st32(&tag, 4, UInt32(t1 & 0xFFFFFFFF))
        st32(&tag, 8, UInt32(t2 & 0xFFFFFFFF))
        st32(&tag, 12, UInt32(t3 & 0xFFFFFFFF))
        return tag
    }
    
    // MARK: - Helpers
    
    private static func ld32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < buf.count else {
            var result: UInt32 = 0
            for i in 0..<min(4, buf.count - offset) {
                result |= UInt32(buf[offset + i]) << (i * 8)
            }
            return result
        }
        return UInt32(buf[offset]) | (UInt32(buf[offset + 1]) << 8) |
               (UInt32(buf[offset + 2]) << 16) | (UInt32(buf[offset + 3]) << 24)
    }
    
    private static func st32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buf[offset]     = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
    
    private static func rotl(_ v: UInt32, _ c: Int) -> UInt32 {
        (v << c) | (v >> (32 - c))
    }
}
