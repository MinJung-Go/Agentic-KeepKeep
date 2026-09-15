import AVFoundation
import Foundation
import Speech

/// 语音输入：把说话内容转写成文字，填进记录输入框。
/// 识别在本机/系统服务完成，不经过本 App 的服务器（也没有服务器）。
@MainActor
final class SpeechRecognizer: ObservableObject {

    @Published private(set) var isRecording = false
    @Published var transcript = ""
    @Published var errorText: String?

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRecording else { return }
        errorText = nil
        transcript = ""

        guard let recognizer, recognizer.isAvailable else {
            errorText = "当前设备无法使用语音识别"
            return
        }

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorText = "未授权语音识别，请在系统设置中开启"
            return
        }

        let micGranted = await requestMicrophonePermission()
        guard micGranted else {
            errorText = "未授权麦克风，请在系统设置中开启"
            return
        }

        begin(with: recognizer)
    }

    func stop() {
        audioEngine?.stop()
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()

        audioEngine = nil
        request = nil
        task = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 内部

    private func begin(with recognizer: SFSpeechRecognizer) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let engine = AVAudioEngine()
            self.audioEngine = engine

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                errorText = "没有可用的麦克风输入"
                stop()
                return
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            engine.prepare()
            try engine.start()

            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.stop() }
                    }
                    if error != nil, self.isRecording {
                        self.stop()
                    }
                }
            }
        } catch {
            errorText = "录音启动失败：\(error.localizedDescription)"
            stop()
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
