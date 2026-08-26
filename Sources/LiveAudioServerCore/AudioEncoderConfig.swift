import Foundation

struct AudioEncoderConfig {
    var sampleRate: Int
    var channels: Int
    var mp3Bitrate: Int      // kbps
    var aacBitrate: Int      // bps (AudioToolbox uses bps, not kbps)
    var chunkFrames: Int     // frames per input chunk; sizes the MP3 scratch buffer
    var verbose: Bool

    init(sampleRate: Int = 48000, channels: Int = 2, mp3Bitrate: Int = 128,
         aacBitrate: Int = 128_000, chunkFrames: Int = 4096, verbose: Bool = false) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.mp3Bitrate = mp3Bitrate
        self.aacBitrate = aacBitrate
        self.chunkFrames = chunkFrames
        self.verbose = verbose
    }
}

enum AudioEncoderError: Error, CustomStringConvertible {
    case initFailed(String)

    var description: String {
        switch self {
        case .initFailed(let s): return "Encoder init failed: \(s)"
        }
    }
}

func encoderLog(_ msg: String, verbose: Bool = false, config: AudioEncoderConfig? = nil) {
    if verbose, let cfg = config, !cfg.verbose { return }
    FileHandle.standardError.write(Data("[Encoders] \(msg)\n".utf8))
}
