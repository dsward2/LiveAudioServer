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

// Sources/LiveAudioServer/Version.swift
// Build-stamped identity strings, surfaced by `--version` / `-V` and the
// startup banner.

import Foundation

let liveAudioServerVersion = "0.1.0"

/// Short git SHA stamped into the build. `"dev"` during day-to-day development;
/// updated to the actual `git rev-parse --short HEAD` value at release-tag time.
let liveAudioServerGitSHA  = "0.1.0"

/// "LiveAudioServer 0.1.0 (sha)" — used by `--version` and the startup banner.
var liveAudioServerVersionString: String {
    return "LiveAudioServer \(liveAudioServerVersion) (\(liveAudioServerGitSHA))"
}

/// Brief copyright / license / repository notice shown by `--version` and at
/// the top of `--help`. Keep it short — humans skim CLI banners.
let liveAudioServerNotice = """
Copyright (c)2026 by Douglas Ward - Conway, Arkansas US
Licensed under the Apache License, Version 2.0
https://github.com/dsward2/LiveAudioServer
"""
