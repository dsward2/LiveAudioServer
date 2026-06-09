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

// Sources/LiveAudioServer/TLSIdentity.swift
// Loads a PKCS#12 (.p12) file from disk and returns a Network.framework-ready
// sec_identity_t for use as the local identity of an NWListener.

import Foundation
import Network
import Security

public enum TLSIdentityError: Error, CustomStringConvertible {
    case fileNotReadable(String)
    case importFailed(OSStatus)
    case emptyIdentity
    case secIdentityCreateFailed

    public var description: String {
        switch self {
        case .fileNotReadable(let p):
            return "TLS identity file not readable: \(p)"
        case .importFailed(let s):
            let detail: String
            switch s {
            case errSecAuthFailed: detail = "wrong passphrase or unreadable PKCS#12"
            case errSecDecode:     detail = "PKCS#12 decode failed (corrupt or wrong format)"
            default:               detail = "SecPKCS12Import status \(s)"
            }
            return "TLS identity import failed: \(detail)"
        case .emptyIdentity:
            return "TLS identity file contained no identity entry"
        case .secIdentityCreateFailed:
            return "Failed to wrap SecIdentity for Network.framework"
        }
    }
}

/// Loads a PKCS#12 file from disk and returns a `sec_identity_t` suitable for
/// `sec_protocol_options_set_local_identity`. No keychain side effects: the
/// identity is returned in-memory only.
public func loadTLSIdentity(p12Path: String, password: String?) throws -> sec_identity_t {
    let url = URL(fileURLWithPath: p12Path)
    guard let data = try? Data(contentsOf: url) else {
        throw TLSIdentityError.fileNotReadable(p12Path)
    }

    var options: [String: Any] = [:]
    if let pw = password {
        options[kSecImportExportPassphrase as String] = pw
    }

    var items: CFArray?
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess else {
        throw TLSIdentityError.importFailed(status)
    }
    guard let array = items as? [[String: Any]],
          let entry = array.first,
          let identityAny = entry[kSecImportItemIdentity as String] else {
        throw TLSIdentityError.emptyIdentity
    }
    let secIdentity = identityAny as! SecIdentity

    guard let netIdentity = sec_identity_create(secIdentity) else {
        throw TLSIdentityError.secIdentityCreateFailed
    }
    return netIdentity
}
