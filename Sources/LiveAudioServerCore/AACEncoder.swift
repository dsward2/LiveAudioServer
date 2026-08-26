// Real-time AAC encoder using macOS AudioToolbox (AudioConverter).
// Produces a raw ADTS-framed AAC bitstream.

import Foundation
import AudioToolbox

// MARK: - ADTS Framing Helper

func adtsHeader(frameLength: Int, sampleRate: Int, channels: Int) -> [UInt8] {
    let aacProfile: UInt8 = 2
    let freqIndex: UInt8  = sampleRateIndex(sampleRate)
    let chanConf: UInt8   = UInt8(channels)
    let fullLen = frameLength + 7

    var header = [UInt8](repeating: 0, count: 7)
    header[0] = 0xFF
    header[1] = 0xF1
    header[2] = ((aacProfile - 1) << 6) | (freqIndex << 2) | (chanConf >> 2)
    header[3] = ((chanConf & 0x3) << 6) | UInt8((fullLen >> 11) & 0x3)
    header[4] = UInt8((fullLen >> 3) & 0xFF)
    header[5] = UInt8((fullLen & 0x7) << 5) | 0x1F
    header[6] = 0xFC
    return header
}

private func sampleRateIndex(_ rate: Int) -> UInt8 {
    let table = [96000, 88200, 64000, 48000, 44100, 32000,
                 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    return UInt8(table.firstIndex(of: rate) ?? 4)
}

// MARK: - Input Buffer (PCM accumulator)

private final class PCMQueue {
    private var buffer = [Int16]()
    private let lock  = NSLock()

    func push(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    func pull(count: Int) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        guard buffer.count >= count else { return nil }
        let chunk = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return chunk
    }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }
}

// MARK: - AACEncoder

final class AACEncoder {
    private let config: AudioEncoderConfig
    private let onEncoded: (Data) -> Void

    private var converter: AudioConverterRef?
    private let pcmQueue = PCMQueue()

    private var inputFormat  = AudioStreamBasicDescription()
    private var outputFormat = AudioStreamBasicDescription()

    private let framesPerPacket: Int = 1024

    private var outputBuf: [UInt8]

    init(config: AudioEncoderConfig, onEncoded: @escaping (Data) -> Void) {
        self.config = config
        self.onEncoded = onEncoded
        self.outputBuf = [UInt8](repeating: 0, count: 8192)
    }

    // MARK: - Lifecycle

    func start() throws {
        inputFormat.mSampleRate       = Float64(config.sampleRate)
        inputFormat.mFormatID         = kAudioFormatLinearPCM
        inputFormat.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger |
                                        kLinearPCMFormatFlagIsPacked
        inputFormat.mBitsPerChannel   = 16
        inputFormat.mChannelsPerFrame = UInt32(config.channels)
        inputFormat.mBytesPerFrame    = UInt32(config.channels * 2)
        inputFormat.mFramesPerPacket  = 1
        inputFormat.mBytesPerPacket   = UInt32(config.channels * 2)

        outputFormat.mSampleRate       = Float64(config.sampleRate)
        outputFormat.mFormatID         = kAudioFormatMPEG4AAC
        outputFormat.mChannelsPerFrame = UInt32(config.channels)
        outputFormat.mFormatFlags      = 0
        outputFormat.mFramesPerPacket  = UInt32(framesPerPacket)

        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converterRef)
        guard status == noErr, let conv = converterRef else {
            throw AudioEncoderError.initFailed("AudioConverterNew failed: \(status)")
        }
        converter = conv

        var bitrate = UInt32(config.aacBitrate)
        AudioConverterSetProperty(conv,
                                  kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size),
                                  &bitrate)

        encoderLog("AAC encoder ready: \(config.aacBitrate/1000)kbps, \(config.channels)ch, \(config.sampleRate)Hz", config: config)
    }

    func stop() {
        flush()
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
    }

    // MARK: - Encoding

    func encode(samples: UnsafeBufferPointer<Int16>) {
        if samples.count == 0 {
            flush()
            return
        }
        pcmQueue.push(samples)
        drainQueue()
    }

    // MARK: - Internal

    private func drainQueue() {
        guard let converter = converter else { return }
        let samplesNeeded = framesPerPacket * config.channels

        while pcmQueue.available >= samplesNeeded {
            guard let pcmChunk = pcmQueue.pull(count: samplesNeeded) else { break }

            var inputData = pcmChunk
            let bytesAvailable = samplesNeeded * 2

            inputData.withUnsafeMutableBufferPointer { pcmPtr in
                var ctx = ConverterContext(
                    samplesPtr: UnsafeMutableRawPointer(pcmPtr.baseAddress!),
                    bytesAvailable: UInt32(bytesAvailable),
                    channels: UInt32(config.channels),
                    packetsAvailable: UInt32(framesPerPacket)
                )

                var outPacketDesc = AudioStreamPacketDescription()
                var ioOutputDataPacketSize: UInt32 = 1
                var outputABL = AudioBufferList()
                outputABL.mNumberBuffers = 1

                let outputBufSize: Int = 8192
                var rawOutputBuf = [UInt8](repeating: 0, count: outputBufSize)
                rawOutputBuf.withUnsafeMutableBytes { outBufPtr in
                    withUnsafeMutableBytes(of: &outputABL.mBuffers) { ablPtr in
                        let buf = ablPtr.bindMemory(to: AudioBuffer.self).baseAddress!
                        buf.pointee.mNumberChannels = UInt32(config.channels)
                        buf.pointee.mDataByteSize   = UInt32(outputBufSize)
                        buf.pointee.mData           = outBufPtr.baseAddress
                    }

                    let fillStatus = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                        AudioConverterFillComplexBuffer(
                            converter,
                            converterInputDataProc,
                            ctxPtr,
                            &ioOutputDataPacketSize,
                            &outputABL,
                            &outPacketDesc
                        )
                    }

                    if fillStatus == noErr || fillStatus == kAudioConverterErr_InvalidInputSize {
                        withUnsafeBytes(of: outputABL.mBuffers) { ablPtr in
                            let audioBuf = ablPtr.bindMemory(to: AudioBuffer.self).baseAddress!
                            let frameBytes = Int(audioBuf.pointee.mDataByteSize)
                            if frameBytes > 0 {
                                let adts = adtsHeader(frameLength: frameBytes,
                                                      sampleRate: config.sampleRate,
                                                      channels: config.channels)
                                var frameData = Data(adts)
                                if let dataPtr = audioBuf.pointee.mData {
                                    frameData.append(Data(bytes: dataPtr, count: frameBytes))
                                }
                                self.onEncoded(frameData)
                            }
                        }
                    } else if fillStatus != noErr {
                        encoderLog("⚠ AudioConverterFillComplexBuffer error: \(fillStatus)", config: config)
                    }
                }
            }
        }
    }

    private func flush() {
        if let conv = converter {
            AudioConverterReset(conv)
        }
        encoderLog("AAC encoder flushed", config: config)
    }
}

// MARK: - AudioConverter Input Callback

private struct ConverterContext {
    var samplesPtr: UnsafeMutableRawPointer
    var bytesAvailable: UInt32
    var channels: UInt32
    var packetsAvailable: UInt32
    var consumed: Bool = false
}

private let converterInputDataProc: AudioConverterComplexInputDataProc = {
    (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in

    guard let ctxPtr = inUserData?.assumingMemoryBound(to: ConverterContext.self) else {
        return kAudioConverterErr_UnspecifiedError
    }

    if ctxPtr.pointee.consumed {
        ioNumberDataPackets.pointee = 0
        return kAudioConverterErr_InvalidInputSize
    }

    withUnsafeMutableBytes(of: &ioData.pointee.mBuffers) { ablPtr in
        let buf = ablPtr.bindMemory(to: AudioBuffer.self).baseAddress!
        buf.pointee.mNumberChannels = ctxPtr.pointee.channels
        buf.pointee.mDataByteSize   = ctxPtr.pointee.bytesAvailable
        buf.pointee.mData           = ctxPtr.pointee.samplesPtr
    }

    ioNumberDataPackets.pointee = ctxPtr.pointee.packetsAvailable
    ctxPtr.pointee.consumed = true
    return noErr
}
