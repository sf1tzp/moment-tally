import Foundation

/// Cross-device identity for spans that converged through a self-hosted
/// server (#241).
///
/// Span UUIDs never travel through the self-hosted transport: the v7
/// migration minted one per store, and a span pulled from the server is
/// inserted with a fresh one. So two Macs that share a span via a server
/// hold it under different UUIDs — and when both switch to iCloud, each
/// uploads its own copy and the dataset doubles. What they *do* share is
/// the span's id on that server, which `sync_map` remembers even after a
/// disconnect. Deriving the CloudKit identity from (server URL, server id)
/// — a name-based UUID, RFC 4122 v5 — makes every Mac in the fleet mint the
/// same record name without talking to each other: the first upload
/// creates the record, the second conflicts against it and merges by
/// last-writer-wins like any other fetched copy.
///
/// The derivation is a compatibility contract: once shipped, the namespace,
/// the name spelling, and the hash must never change, or two builds of the
/// app would disagree about a span's identity. SHA-1 is implemented here
/// rather than imported because MomentTallyCore builds on Linux (#85),
/// where CryptoKit does not exist.
package enum SpanIdentity {

    /// The namespace UUID for self-hosted span identities. Minted once
    /// (2026-09-20) and fixed forever — see the contract above.
    static let selfHostedNamespace = UUID(uuidString: "8EF3587C-BF8E-4A23-8A86-5999E7745CC1")!

    /// The CloudKit record name for a span known to the self-hosted server
    /// at `serverURL` as `serverId`. Deterministic across stores and builds.
    package static func cloudUUID(serverURL: String, serverId: Int) -> String {
        let name = "\(normalizedServerURL(serverURL))\u{1F}\(serverId)"
        return uuidV5(namespace: selfHostedNamespace, name: name).uuidString
    }

    /// The URL as the fleet must agree on it. `AppModel.connectSyncServer`
    /// already trims and strips trailing slashes before storing; repeating
    /// that here (plus case-folding, since hosts are case-insensitive)
    /// keeps two Macs that typed the server differently on the same name.
    static func normalizedServerURL(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized.lowercased()
    }

    // MARK: RFC 4122 name-based UUID (version 5)

    static func uuidV5(namespace: UUID, name: String) -> UUID {
        let ns = namespace.uuid
        var input: [UInt8] = [ns.0, ns.1, ns.2, ns.3, ns.4, ns.5, ns.6, ns.7,
                              ns.8, ns.9, ns.10, ns.11, ns.12, ns.13, ns.14, ns.15]
        input.append(contentsOf: Array(name.utf8))
        var b = SHA1.hash(input)
        b[6] = (b[6] & 0x0F) | 0x50    // version 5
        b[8] = (b[8] & 0x3F) | 0x80    // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// A minimal SHA-1 (FIPS 180-4), used only for name-based UUIDs — nothing
/// here is a security boundary; the algorithm is what RFC 4122 v5 fixes.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = UInt32(padded[o]) << 24 | UInt32(padded[o + 1]) << 16
                    | UInt32(padded[o + 2]) << 8 | UInt32(padded[o + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20:  f = (b & c) | (~b & d);            k = 0x5A827999
                case 20..<40: f = b ^ c ^ d;                     k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d);   k = 0x8F1BBCDC
                default:      f = b ^ c ^ d;                     k = 0xCA62C1D6
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = t
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c
            h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { v in
            [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
