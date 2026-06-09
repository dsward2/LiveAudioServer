// LiveAudioServer — https://github.com/dsward2/LiveAudioServer
//
// Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
// Licensed under the Apache License, Version 2.0.

import Testing
import Foundation
import Network
@testable import LiveAudioServerCore

@Suite("IPACL parsing and matching")
struct IPACLTests {

    private func host(_ literal: String) -> NWEndpoint.Host {
        return NWEndpoint.Host(literal)
    }

    // MARK: - Parser

    @Test("IPv4 single host parses")
    func parseV4Single() {
        let m = IPMatcher(parsing: "127.0.0.1")
        #expect(m != nil)
        if case .ipv4(_, let prefix) = m! { #expect(prefix == 32) }
        else { Issue.record("Expected .ipv4 case") }
    }

    @Test("IPv4 CIDR parses")
    func parseV4CIDR() {
        let m = IPMatcher(parsing: "192.168.0.0/24")
        #expect(m != nil)
        if case .ipv4(_, let prefix) = m! { #expect(prefix == 24) }
        else { Issue.record("Expected .ipv4 case") }
    }

    @Test("IPv6 single host parses")
    func parseV6Single() {
        let m = IPMatcher(parsing: "::1")
        #expect(m != nil)
        if case .ipv6(_, let prefix) = m! { #expect(prefix == 128) }
        else { Issue.record("Expected .ipv6 case") }
    }

    @Test("IPv6 CIDR parses")
    func parseV6CIDR() {
        let m = IPMatcher(parsing: "2001:db8::/32")
        #expect(m != nil)
        if case .ipv6(_, let prefix) = m! { #expect(prefix == 32) }
        else { Issue.record("Expected .ipv6 case") }
    }

    @Test("Garbage rejected")
    func parseGarbage() {
        #expect(IPMatcher(parsing: "not an ip") == nil)
        #expect(IPMatcher(parsing: "192.168.1.1/40") == nil)   // bad prefix
        #expect(IPMatcher(parsing: "::1/200") == nil)
        #expect(IPMatcher(parsing: "") == nil)
    }

    // MARK: - Matching

    @Test("IPv4 single host matches only itself")
    func v4SingleMatch() {
        let m = IPMatcher(parsing: "127.0.0.1")!
        #expect(m.matches(host("127.0.0.1")) == true)
        #expect(m.matches(host("127.0.0.2")) == false)
        #expect(m.matches(host("::1")) == false)
    }

    @Test("IPv4 CIDR /24 covers the right subnet")
    func v4CIDRMatch() {
        let m = IPMatcher(parsing: "192.168.1.0/24")!
        #expect(m.matches(host("192.168.1.0"))   == true)
        #expect(m.matches(host("192.168.1.42"))  == true)
        #expect(m.matches(host("192.168.1.255")) == true)
        #expect(m.matches(host("192.168.2.0"))   == false)
        #expect(m.matches(host("10.0.0.1"))      == false)
    }

    @Test("IPv4 CIDR /16 covers the wider range")
    func v4CIDR16() {
        let m = IPMatcher(parsing: "10.0.0.0/16")!
        #expect(m.matches(host("10.0.255.42")) == true)
        #expect(m.matches(host("10.1.0.0"))    == false)
    }

    @Test("IPv6 ::/0 matches everything IPv6")
    func v6CIDRZero() {
        let m = IPMatcher(parsing: "::/0")!
        #expect(m.matches(host("::1")) == true)
        #expect(m.matches(host("2001:db8::dead:beef")) == true)
    }

    @Test("IPv6 /32 boundary")
    func v6CIDR32() {
        let m = IPMatcher(parsing: "2001:db8::/32")!
        #expect(m.matches(host("2001:db8::1"))      == true)
        #expect(m.matches(host("2001:db8:ffff::1")) == true)
        #expect(m.matches(host("2001:db9::1"))      == false)
        #expect(m.matches(host("::1"))              == false)
    }

    @Test("IPv4 matcher recognizes IPv4-mapped IPv6 addresses")
    func v4MatcherMapped() {
        let m = IPMatcher(parsing: "127.0.0.1")!
        // ::ffff:127.0.0.1 (the v4-mapped form) should match.
        #expect(m.matches(host("::ffff:127.0.0.1")) == true)
        #expect(m.matches(host("::ffff:127.0.0.2")) == false)
    }

    // MARK: - Allow list

    @Test("parseAllowList builds matchers from comma list")
    func parseList() throws {
        let acl = try parseAllowList("127.0.0.1, 192.168.0.0/24,::1")
        #expect(acl.matchers.count == 3)
        #expect(acl.allowAll == false)
        #expect(acl.allows(host("127.0.0.1")))
        #expect(acl.allows(host("192.168.0.99")))
        #expect(acl.allows(host("::1")))
        #expect(!acl.allows(host("10.0.0.1")))
    }

    @Test("parseAllowList rejects invalid tokens")
    func parseListInvalid() {
        #expect(throws: IPACLParseError.self) {
            _ = try parseAllowList("127.0.0.1, gibberish")
        }
    }

    @Test("Empty list yields a non-allow-all empty allow list")
    func parseEmptyList() throws {
        let acl = try parseAllowList("")
        #expect(acl.matchers.isEmpty)
        #expect(acl.allowAll == false)
        #expect(!acl.allows(host("127.0.0.1")))
    }

    @Test("allowAll sentinel matches anything")
    func allowAllMatchesAll() {
        let acl = IPAllowList.allowAll
        #expect(acl.allows(host("127.0.0.1")))
        #expect(acl.allows(host("8.8.8.8")))
        #expect(acl.allows(host("::1")))
    }

    // MARK: - CLI

    @Test("--allow-ip is parsed into config")
    func cliAllowIP() {
        if case .run(let cfg) = parseCLI(["--allow-ip", "127.0.0.1,10.0.0.0/8"]) {
            #expect(cfg.allowedClientIPs?.allowAll == false)
            #expect(cfg.allowedClientIPs?.matchers.count == 2)
        } else {
            Issue.record("Expected .run")
        }
    }

    @Test("--allow-ip with invalid token is rejected")
    func cliAllowIPInvalid() {
        if case .error(let msg) = parseCLI(["--allow-ip", "not-an-ip"]) {
            #expect(msg.contains("--allow-ip"))
        } else {
            Issue.record("Expected .error")
        }
    }
}
