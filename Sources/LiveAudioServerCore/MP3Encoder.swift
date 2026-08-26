// Real-time MP3 encoder backed by libmp3lame.

import Foundation
import CLame

final class MP3Encoder {
    private let config: AudioEncoderConfig
    private let onEncoded: (Data) -> Void
    private var lame: lame_t?
    private var mp3Buf: [UInt8]

    // LAME recommends output buffer = 1.25 * samples + 7200
    private var mp3BufSize: Int { Int(Double(config.chunkFrames) * 1.25) + 7200 }

    init(config: AudioEncoderConfig, onEncoded: @escaping (Data) -> Void) {
        self.config = config
        self.onEncoded = onEncoded
        self.mp3Buf = [UInt8](repeating: 0, count: Int(Double(config.chunkFrames) * 1.25) + 7200)
    }

    // MARK: - Lifecycle

    func start() throws {
        lame = lame_init()
        guard lame != nil else { throw AudioEncoderError.initFailed("lame_init returned nil") }

        lame_set_in_samplerate(lame, Int32(config.sampleRate))
        lame_set_out_samplerate(lame, Int32(config.sampleRate))
        lame_set_num_channels(lame, Int32(config.channels))
        lame_set_brate(lame, Int32(config.mp3Bitrate))
        lame_set_quality(lame, 5)          // 2=highest, 7=fastest; 5 is a good balance
        lame_set_mode(lame, config.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(lame, vbr_off)

        let ret = lame_init_params(lame)
        guard ret == 0 else { throw AudioEncoderError.initFailed("lame_init_params returned \(ret)") }

        encoderLog("MP3 encoder ready: \(config.mp3Bitrate)kbps, \(config.channels)ch, \(config.sampleRate)Hz", config: config)
    }

    func stop() {
        flush()
        if lame != nil {
            lame_close(lame)
            lame = nil
        }
    }

    // MARK: - Encoding

    /// Called with each PCM chunk. count==0 signals EOF/flush.
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
            onEncoded(chunk)
        } else if encoded < 0 {
            encoderLog("⚠ lame_encode_buffer error: \(encoded)", config: config)
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
            onEncoded(Data(bytes: flushBuf, count: Int(n)))
        }
    }
}
