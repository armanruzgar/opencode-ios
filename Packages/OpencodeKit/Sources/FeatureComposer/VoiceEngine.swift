#if os(iOS)
import AVFoundation
import Foundation
import Speech
import OCSync

enum VoiceError: LocalizedError {
    case unsupportedLocale, noAudioFormat
    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: localized("On-device speech recognition does not support this device’s language.")
        case .noAudioFormat: localized("The microphone’s audio format is not supported.")
        }
    }
}

/// SpeechAnalyzer and SpeechTranscriber on the device: no network recognizer, and the audio is never stored or sent.
@MainActor final class DeviceSpeechRecognizer: SpeechRecognizing {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var tapped = false

    func authorize() async -> VoiceAuthorization {
        guard await AVAudioApplication.requestRecordPermission() else {
            return .denied(localized("Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."))
        }
        // The answer arrives on a background queue. A handler that inherited the main actor would trap there, so it
        // is @Sendable: it only resumes the continuation.
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        guard speech == .authorized else {
            return .denied(localized("Speech recognition is off. Turn it on in Settings › Privacy & Security › Speech Recognition."))
        }
        return .granted
    }

    func start(contextualStrings: [String]) async throws -> AsyncThrowingStream<VoiceTranscript, any Error> {
        // A session that ended without stop() must not leave its tap: a second tap on bus 0 raises an exception.
        if tapped || analyzer != nil { await stop() }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw VoiceError.unsupportedLocale }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        // The language model is a system asset, installed once by iOS.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural),
              let converter = TapConverter(from: natural, to: format) else { throw VoiceError.noAudioFormat }
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        Self.install(on: engine.inputNode, format: natural, converter: converter, continuation: continuation)
        tapped = true; input = continuation; self.analyzer = analyzer
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: sequence)
        return AsyncThrowingStream { output in
            let task = Task {
                do {
                    for try await result in transcriber.results {
                        output.yield(VoiceTranscript(text: String(result.text.characters), isFinal: result.isFinal))
                    }
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        input?.finish(); input = nil
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The tap runs on the audio thread, outside the main actor.
    private nonisolated static func install(on node: AVAudioInputNode, format: AVAudioFormat, converter: TapConverter,
                                            continuation: AsyncStream<AnalyzerInput>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
    }
}

/// AVAudioConverter is used only from the audio thread's tap callback.
private nonisolated final class TapConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    init?(from source: AVAudioFormat, to format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        self.converter = converter; self.format = format
    }
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        return error == nil ? output : nil
    }
}

/// Reads replies aloud with the system voice for the device's language.
@MainActor final class DeviceSpeaker: NSObject, SpeechSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String) async {
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier(.bcp47))
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        finished?.resume(); finished = nil
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
}
#endif
