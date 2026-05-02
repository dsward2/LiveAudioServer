// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License.

// Sources/LiveAudioServer/IPACL.swift
// Allow-list filter for inbound HTTP/HTTPS client connections. Each entry is
// either a single IP literal or a CIDR range (v4 or v6). An empty list (or a
// nil IPAllowList) allows everything — the default.

import Foundation
import Network

/// A single allow-list entry.
enum IPMatcher: Equatable {
    case ipv4(IPv4Address, prefixLength: Int)   // prefixLength==32 → exact host
    case ipv6(IPv6Address, prefixLength: Int)   // prefixLength==128 → exact host

    /// Parse a token like "192.168.1.5", "192.168.0.0/24", "::1", or
    /// "2001:db8::/32". Returns nil for malformed input.
    init?(parsing token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addrStr = String(parts[0])
        let prefixStr: String? = (parts.count == 2) ? String(parts[1]) : nil

        if let v4 = IPv4Address(addrStr) {
            let prefix: Int
            if let s = prefixStr {
                guard let n = Int(s), (0...32).contains(n) else { return nil }
                prefix = n
            } else {
                prefix = 32
            }
            self = .ipv4(v4, prefixLength: prefix)
            return
        }

        if let v6 = IPv6Address(addrStr) {
            let prefix: Int
            if let s = prefixStr {
                guard let n = Int(s), (0...128).contains(n) else { return nil }
                prefix = n
            } else {
                prefix = 128
            }
            self = .ipv6(v6, prefixLength: prefix)
            return
        }

        return nil
    }

    /// Does this matcher cover `host`? IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`)
    /// are normalized to their underlying IPv4 representation before matching.
    func matches(_ host: NWEndpoint.Host) -> Bool {
        let normalized = IPMatcher.normalizeMappedHost(host)
        switch (self, normalized) {
        case (.ipv4(let target, let prefix), .ipv4(let v4)):
            return IPMatcher.prefixMatch(v4.rawValue, target.rawValue, bits: prefix)
        case (.ipv6(let target, let prefix), .ipv6(let v6)):
            return IPMatcher.prefixMatch(v6.rawValue, target.rawValue, bits: prefix)
        default:
            return false
        }
    }

    /// If `host` is an IPv6 address that's a v4-mapped form (`::ffff:a.b.c.d`),
    /// return the equivalent IPv4 host. Otherwise return the input unchanged.
    static func normalizeMappedHost(_ host: NWEndpoint.Host) -> NWEndpoint.Host {
        if case .ipv6(let v6) = host {
            let bytes = v6.rawValue
            if bytes.count == 16,
               bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[bytes.startIndex + 10] == 0xFF,
               bytes[bytes.startIndex + 11] == 0xFF {
                let v4Bytes = Data(bytes.suffix(4))
                if let v4 = IPv4Address(v4Bytes) {
                    return .ipv4(v4)
                }
            }
        }
        return host
    }

    /// Compare `bits` most-significant bits of `a` and `b`. Both buffers must
    /// be long enough to cover `bits` bits.
    static func prefixMatch(_ a: Data, _ b: Data, bits: Int) -> Bool {
        var remaining = bits
        var idx = 0
        while remaining >= 8 {
            guard idx < a.count, idx < b.count else { return false }
            if a[a.startIndex + idx] != b[b.startIndex + idx] { return false }
            idx += 1
            remaining -= 8
        }
        if remaining == 0 { return true }
        guard idx < a.count, idx < b.count else { return false }
        let mask: UInt8 = 0xFF << UInt8(8 - remaining)
        return (a[a.startIndex + idx] & mask) == (b[b.startIndex + idx] & mask)
    }
}

/// Ordered list of allow-list matchers. A connection is allowed iff at least
/// one matcher matches the source host.
struct IPAllowList: Equatable {
    let matchers: [IPMatcher]
    /// `true` for the unrestricted default — kept as a separate flag so a
    /// caller passing an empty `--allow-ip` value gets the desired "block all
    /// except listed" semantics rather than accidentally being unrestricted.
    let allowAll: Bool

    static let allowAll = IPAllowList(matchers: [], allowAll: true)

    func allows(_ host: NWEndpoint.Host) -> Bool {
        if allowAll { return true }
        return matchers.contains { $0.matches(host) }
    }
}

enum IPACLParseError: Error, CustomStringConvertible {
    case invalidToken(String)

    var description: String {
        switch self {
        case .invalidToken(let t): return "Invalid --allow-ip value '\(t)'. Use a single IP or CIDR (e.g. 192.168.0.0/24)."
        }
    }
}

/// Parse a comma-separated list like "127.0.0.1,192.168.0.0/24,::1".
func parseAllowList(_ list: String) throws -> IPAllowList {
    let tokens = list
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    var matchers: [IPMatcher] = []
    for t in tokens {
        guard let m = IPMatcher(parsing: t) else {
            throw IPACLParseError.invalidToken(t)
        }
        matchers.append(m)
    }
    return IPAllowList(matchers: matchers, allowAll: false)
}
