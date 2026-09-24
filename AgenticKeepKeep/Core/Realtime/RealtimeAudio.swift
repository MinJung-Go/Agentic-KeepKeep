import AVFoundation
import Foundation

@MainActor
final class RealtimeAudio {
    private var tapInstalled = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var captureMixer: AVAudioMixerNode?
    private var outputFormat: AVAudioFormat?
    private var queuedFrames = 0
    private var playbackGeneration = UUID()

    func start(onInput: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable () -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), captureMixer = AVAudioMixerNode()
        self.engine = engine; self.player = player; self.captureMixer = captureMixer
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.inputNode.isVoiceProcessingInputMuted = false
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false) else {
            throw AudioError.unavailable
        }
        outputFormat = output
        engine.attach(player)
        engine.attach(captureMixer)
        // Keep an explicit render path for capture even before playback is scheduled.
        // Only the monitor branch is muted; the input tap still receives microphone audio.
        captureMixer.outputVolume = 0
        engine.connect(engine.inputNode, to: captureMixer, format: input)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: input)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        let converter = RealtimeInputConverter()
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            do {
                if let pcm = try converter.convert(buffer) { onInput(RealtimeWire.wav(pcm)) }
            } catch { onFailure() }
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
        engine = nil; player = nil; captureMixer = nil; outputFormat = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    enum AudioError: Error { case unavailable, backpressure }
}
