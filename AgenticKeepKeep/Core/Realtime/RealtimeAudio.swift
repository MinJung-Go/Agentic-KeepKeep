import AVFoundation
import Foundation

@MainActor
final class RealtimeAudio {
    private var tapInstalled = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var outputFormat: AVAudioFormat?
    private var queuedFrames = 0
    private var playbackGeneration = UUID()

    func start(onInput: @escaping @Sendable (Data) -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false) else {
            throw AudioError.unavailable
        }
        outputFormat = output
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: output)
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / input.sampleRate + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let samples = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            var pcm = Data(capacity: Int(converted.frameLength) * 2)
            for i in 0..<Int(converted.frameLength) {
                var value = Int16(max(-1, min(1, samples[i])) * 32767).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            onInput(RealtimeWire.wav(pcm))
        }
        tapInstalled = true
        engine.prepare(); try engine.start(); player.play()
    }

    func play(_ pcm: Data) throws {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 300000,
              let format = outputFormat, let player else { throw AudioError.unavailable }
        let count = pcm.count / 2
        guard queuedFrames + count <= 240000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { throw AudioError.backpressure }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count { samples[i] = Float(Int16(bitPattern: UInt16(bytes[i*2]) | UInt16(bytes[i*2+1]) << 8)) / 32768 }
        }
        queuedFrames += count
        let token = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == token else { return }
                self.queuedFrames = max(0, self.queuedFrames - count)
            }
        }
        if !player.isPlaying { player.play() }
    }
    func interrupt() { playbackGeneration = UUID(); player?.stop(); queuedFrames = 0; if engine?.isRunning == true { player?.play() } }
    func stop() {
        interrupt()
        if let engine { engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0) } }
        tapInstalled = false
        engine = nil; player = nil; outputFormat = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    enum AudioError: Error { case unavailable, backpressure }
}
