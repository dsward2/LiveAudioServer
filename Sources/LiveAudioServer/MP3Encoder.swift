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

// Sources/LiveAudioServer/MP3Encoder.swift
// Real-time MP3 encoder backed by libmp3lame.
// Receives PCM Int16 frames from PCMBroadcaster and pushes encoded MP3 chunks
// to a ChunkBroadcaster for delivery to HTTP clients.

import Foundation
import CLame

// MARK: - MP3 Encoder

final class MP3Encoder {
    private let config: ServerConfig
    private let output: ChunkBroadcaster
    private var lame: lame_t?
    private var mp3Buf: [UInt8]

    // LAME recommends output buffer = 1.25 * samples + 7200
    private var mp3BufSize: Int { Int(Double(config.stdinChunkFrames) * 1.25) + 7200 }

    init(config: ServerConfig, output: ChunkBroadcaster) {
        self.config = config
        self.output = output
        self.mp3Buf = [UInt8](repeating: 0, count: Int(Double(config.stdinChunkFrames) * 1.25) + 7200)
    }

    // MARK: - Lifecycle

    func start() throws {
        lame = lame_init()
        guard lame != nil else { throw EncoderError.initFailed("lame_init returned nil") }

        lame_set_in_samplerate(lame, Int32(config.sampleRate))
        lame_set_out_samplerate(lame, Int32(config.sampleRate))
        lame_set_num_channels(lame, Int32(config.channels))
        lame_set_brate(lame, Int32(config.mp3Bitrate))
        lame_set_quality(lame, 5)          // 2=highest, 7=fastest; 5 is a good balance
        lame_set_mode(lame, config.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(lame, vbr_off)

        let ret = lame_init_params(lame)
        guard ret == 0 else { throw EncoderError.initFailed("lame_init_params returned \(ret)") }

        log("MP3 encoder ready: \(config.mp3Bitrate)kbps, \(config.channels)ch, \(config.sampleRate)Hz")
    }

    func stop() {
        flush()
        if lame != nil {
            lame_close(lame)
            lame = nil
        }
    }

    // MARK: - Encoding

    /// Called by PCMBroadcaster with each PCM chunk. count==0 signals EOF/flush.
    func encode(samples: UnsafeBufferPointer<Int16>) {
        guard let lame = lame else { return }

        if samples.count == 0 {
            flush()
            return
        }

        let framesPerChannel = samples.count / config.channels

        // Resize output buffer if needed
        let needed = Int(Double(framesPerChannel) * 1.25) + 7200
        if mp3Buf.count < needed { mp3Buf = [UInt8](repeating: 0, count: needed) }
        let mp3BufCount = Int32(mp3Buf.count)

        let encoded: Int32
        if config.channels == 1 {
            encoded = samples.baseAddress!.withMemoryRebound(to: Int16.self, capacity: samples.count) { ptr in
                mp3Buf.withUnsafeMutableBytes { outPtr in
                    lame_encode_buffer(lame, ptr, ptr, Int32(framesPerChannel),
                                       outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                       mp3BufCount)
                }
            }
        } else {
            // Interleaved stereo → LAME wants separate L/R pointers
            // Build deinterleaved arrays only when necessary
            var left  = [Int16](repeating: 0, count: framesPerChannel)
            var right = [Int16](repeating: 0, count: framesPerChannel)
            for i in 0..<framesPerChannel {
                left[i]  = samples[i * 2]
                right[i] = samples[i * 2 + 1]
            }
            encoded = left.withUnsafeBufferPointer { lPtr in
                right.withUnsafeBufferPointer { rPtr in
                    mp3Buf.withUnsafeMutableBytes { outPtr in
                        lame_encode_buffer(lame,
                                           lPtr.baseAddress!,
                                           rPtr.baseAddress!,
                                           Int32(framesPerChannel),
                                           outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                           mp3BufCount)
                    }
                }
            }
        }

        if encoded > 0 {
            let chunk = Data(bytes: mp3Buf, count: Int(encoded))
            output.broadcast(chunk)
        } else if encoded < 0 {
            log("⚠ lame_encode_buffer error: \(encoded)")
        }
    }

    // MARK: - Private

    private func flush() {
        guard let lame = lame else { return }
        var flushBuf = [UInt8](repeating: 0, count: 7200)
        let n = flushBuf.withUnsafeMutableBytes { ptr in
            lame_encode_flush(lame,
                              ptr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                              7200)
        }
        if n > 0 {
            output.broadcast(Data(bytes: flushBuf, count: Int(n)))
        }
    }
}

// MARK: - Errors

enum EncoderError: Error, CustomStringConvertible {
    case initFailed(String)
    case encodeFailed(String)
    var description: String {
        switch self {
        case .initFailed(let s):  return "Encoder init failed: \(s)"
        case .encodeFailed(let s): return "Encode failed: \(s)"
        }
    }
}
