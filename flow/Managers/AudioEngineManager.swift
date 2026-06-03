//
//  AudioEngineManager.swift
//  flow
//
//  Receives audio from the Penlo wearable (simulated via AVAudioEngine
//  microphone tap for development), pipes it through Apple's on-device
//  SFSpeechRecognizer for battery-efficient, offline-capable
//  transcription, and uses silence-detection segmentation to save
//  completed transcript blocks to SwiftData.
//
//  Segmentation rule: if 5 seconds pass with no new speech, the current
//  block is finalized and persisted. The silence timer resets on every
//  new partial result, so mid-sentence audio is never cut off.
//

import AVFoundation
import Speech
import SwiftData

enum AudioSource: Sendable {
    case internalMic
    case hardwareBLE
}

@MainActor
final class AudioEngineManager {

    // MARK: - Configuration

    /// Duration of silence (no new recognized speech) before the current
    /// transcription block is finalized and saved.
    private static let silenceThreshold: TimeInterval = 5.0

    /// Maximum continuous listening duration (battery protection).
    /// After this many seconds with no speech at all, the pipeline auto-stops.
    private static let maxIdleDuration: TimeInterval = 120.0

    private nonisolated(unsafe) static let hardwareFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    static let hardwareActionFlag = " [HARDWARE_ACTION_FLAG] "

    // MARK: - Callbacks

    /// Fires on the main actor whenever a live partial transcription
    /// arrives — the UI can show this text in real time.
    var onPartialResult: ((String) -> Void)?

    /// Fires when a segment is finalized and saved to SwiftData.
    var onSegmentSaved: ((UUID) -> Void)?

    /// Fires when the pipeline auto-stops due to extended inactivity.
    var onAutoStopped: (() -> Void)?

    /// Fires when the recognizer encounters a non-recoverable error.
    /// The owner should transition AppStateManager to `.fault`.
    var onFault: ((String) -> Void)?

    /// Fires when the pipeline transitions between transcribing and idle.
    var onTranscribingChange: ((Bool) -> Void)?

    // MARK: - Public Read-Only State

    private(set) var isTranscribing = false
    private(set) var currentSource: AudioSource = .internalMic

    /// Whether the AVAudioEngine input tap is active (internal mic path only).
    var isInputEngineRunning: Bool { audioEngine.isRunning }

    // MARK: - Private Audio

    private let audioEngine = AVAudioEngine()
    private nonisolated(unsafe) let hardwareAudioQueue = DispatchQueue(
        label: "com.getflow.flow.ble-audio",
        qos: .userInitiated
    )
    private nonisolated(unsafe) var activeRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var inputTapInstalled = false

    // MARK: - Private Segmentation

    /// Accumulates the latest best transcription for the current block.
    private var currentBlockText = ""

    /// The most recent partial result — compared against the next partial
    /// to detect whether speech is still flowing.
    private var lastPartialText = ""

    /// Fires `silenceThreshold` seconds after the last new partial.
    private var silenceTimer: Task<Void, Never>?

    /// Auto-stop timer for battery protection — fires if no speech detected
    /// for `maxIdleDuration` seconds continuously.
    private var idleTimer: Task<Void, Never>?

    /// Tracks whether any speech has been detected in this session.
    private var hasDetectedSpeech = false

    // MARK: - Private Persistence

    private var persistenceActor: PersistenceActor?

    // MARK: - Lifecycle

    /// Call once during app startup to hand in the shared container.
    func configure(modelContainer: ModelContainer) {
        persistenceActor = PersistenceActor(modelContainer: modelContainer)
    }

    // MARK: - Permissions

    /// Request Microphone + Speech Recognition authorization.
    /// Returns `true` only if both are granted.
    func requestPermissions() async -> Bool {
        let micGranted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }

        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }

        let speechGranted = (speechStatus == .authorized)

        if !micGranted {
            log("Microphone permission denied")
            onFault?("Microphone permission denied. Penlo cannot transcribe without audio access.")
        }
        if !speechGranted {
            log("Speech recognition permission denied (status: \(speechStatus.rawValue))")
            onFault?("Speech recognition permission denied.")
        }

        return micGranted && speechGranted
    }

    /// Speech recognition only — used for the Penlo wearable BLE path.
    func requestSpeechPermission() async -> Bool {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        let speechGranted = (speechStatus == .authorized)
        if !speechGranted {
            log("Speech recognition permission denied (status: \(speechStatus.rawValue))")
            onFault?("Speech recognition permission denied.")
        }
        return speechGranted
    }

    // MARK: - Start / Stop

    /// Begin the transcription pipeline from the iPhone mic or Penlo wearable BLE stream.
    func startTranscribing(source: AudioSource = .internalMic) {
        guard !isTranscribing else { return }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            log("SFSpeechRecognizer unavailable for current locale")
            onFault?("On-device speech recognition is not available on this device.")
            return
        }
        speechRecognizer = recognizer
        recognizer.supportsOnDeviceRecognition = true
        currentSource = source

        do {
            try configureAudioSession(for: source)
            if source == .internalMic {
                try startAudioEngine()
            }
            startRecognitionTask(with: recognizer)
            hasDetectedSpeech = false
            startIdleTimer()
            setTranscribing(true)
            log("Pipeline started — source: \(source == .internalMic ? "iPhone mic" : "Penlo wearable BLE")")
        } catch {
            log("Failed to start audio pipeline: \(error.localizedDescription)")
            onFault?("Audio pipeline failed: \(error.localizedDescription)")
            cleanUp()
        }
    }

    /// Stop transcription. Finalizes whatever partial text exists.
    func stopTranscribing() {
        guard isTranscribing else { return }
        finalizeCurrentBlock(reason: "manual stop")
        cleanUp()
        setTranscribing(false)
        log("Pipeline stopped")
    }

    // MARK: - Hardware BLE Audio

    /// Append raw 16-bit PCM (16 kHz mono) from the wearable into the STT pipeline.
    nonisolated func appendHardwareAudio(data: Data) {
        hardwareAudioQueue.async {
            guard let buffer = Self.convertToPCMBuffer(data: data) else { return }
            self.activeRecognitionRequest?.append(buffer)
        }
    }

    /// Inject a physical button bookmark into the live transcript for Claude extraction.
    func injectHardwareActionFlag() {
        guard isTranscribing else { return }
        currentBlockText += Self.hardwareActionFlag
        lastPartialText += Self.hardwareActionFlag
        onPartialResult?(currentBlockText)
    }

    /// Convert wearable PCM bytes into an `AVAudioPCMBuffer` for Speech framework ingestion.
    nonisolated static func convertToPCMBuffer(data: Data) -> AVAudioPCMBuffer? {
        let format = hardwareFormat
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frameCapacity = UInt32(data.count) / bytesPerFrame
        guard frameCapacity > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        guard let channelData = buffer.int16ChannelData else { return nil }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channelData[0], base, Int(frameCapacity) * Int(bytesPerFrame))
        }
        buffer.frameLength = frameCapacity
        return buffer
    }

    /// For development/simulators: feed a pre-built buffer into the recognition pipeline.
    func feedAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        activeRecognitionRequest?.append(buffer)
        recognitionRequest?.append(buffer)
    }

    // MARK: - Audio Session

    private func configureAudioSession(for source: AudioSource) throws {
        let session = AVAudioSession.sharedInstance()
        if source == .internalMic {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        } else {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio Engine

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.activeRecognitionRequest?.append(buffer)
        }
        inputTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Recognition Task

    private func startRecognitionTask(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        recognitionRequest = request
        activeRecognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.handlePartialResult(text, isFinal: result.isFinal)
                }

                if let error {
                    let nsError = error as NSError
                    // Code 1101 = "no speech detected", not a real fault.
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
                        self.log("No speech detected — restarting listener")
                        self.restartPipeline()
                    } else if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        // Task cancelled — expected during cleanup.
                    } else {
                        self.log("Recognition error: \(error.localizedDescription)")
                        self.onFault?(error.localizedDescription)
                        self.cleanUp()
                        self.setTranscribing(false)
                    }
                }
            }
        }
    }

    // MARK: - Silence Detection / Segmentation

    /// Called every time a new partial transcription arrives.
    private func handlePartialResult(_ text: String, isFinal: Bool) {
        currentBlockText = text
        onPartialResult?(text)

        if text != lastPartialText {
            // New speech detected — reset the silence timer and cancel idle auto-stop.
            lastPartialText = text
            if !hasDetectedSpeech {
                hasDetectedSpeech = true
                idleTimer?.cancel()
                idleTimer = nil
            }
            resetSilenceTimer()
        }

        if isFinal {
            finalizeCurrentBlock(reason: "recognizer marked final")
            restartPipeline()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AudioEngineManager.silenceThreshold))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finalizeCurrentBlock(reason: "5s silence")
                self?.restartPipeline()
            }
        }
    }

    /// Battery protection: if no speech is detected for maxIdleDuration,
    /// automatically stop the pipeline to preserve power.
    private func startIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AudioEngineManager.maxIdleDuration))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isTranscribing, !self.hasDetectedSpeech else { return }
                self.log("Auto-stopping: no speech detected for \(Self.maxIdleDuration)s")
                self.stopTranscribing()
                self.onAutoStopped?()
            }
        }
    }

    /// Save the accumulated text as a Transcript and reset for the next block.
    private func finalizeCurrentBlock(reason: String) {
        silenceTimer?.cancel()
        silenceTimer = nil

        let text = currentBlockText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let capturedAt = Date.now
        log("Segment finalized (\(reason)): \"\(text.prefix(60))…\"")

        currentBlockText = ""
        lastPartialText = ""

        guard let actor = persistenceActor else {
            log("PersistenceActor not configured — transcript lost!")
            return
        }

        Task {
            do {
                let id = try await actor.insertTranscript(rawText: text, capturedAt: capturedAt)
                await MainActor.run { [weak self] in
                    self?.onSegmentSaved?(id)
                    Haptics.success()
                }
                // Run Claude extraction in the background to populate MemoryPayload (v1.1)
                if ClaudeService.hasAPIKey {
                    await Self.extractAndAttachPayload(rawText: text, transcriptID: id, capturedAt: capturedAt, actor: actor)
                }
            } catch {
                self.log("Failed to save transcript: \(error.localizedDescription)")
            }
        }
    }

    /// Tear down the current recognition task and start a fresh one so
    /// the recognizer doesn't hit the ~60-second limit.
    private func restartPipeline() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        activeRecognitionRequest = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable, isTranscribing else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request
        activeRecognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.handlePartialResult(result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
                        self.restartPipeline()
                    } else if !(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216) {
                        self.log("Recognition error on restart: \(error.localizedDescription)")
                        self.onFault?(error.localizedDescription)
                        self.cleanUp()
                        self.setTranscribing(false)
                    }
                }
            }
        }
    }

    // MARK: - Cleanup

    private func cleanUp() {
        silenceTimer?.cancel()
        silenceTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        activeRecognitionRequest = nil

        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Helpers

    private func setTranscribing(_ value: Bool) {
        isTranscribing = value
        onTranscribingChange?(value)
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[Penlo Audio] \(message)")
        #endif
    }

    // MARK: - Claude Extraction (Penlo Contract v1.1)

    /// Sends raw transcript text to Claude for structured extraction using
    /// the full Penlo v1.1 pipeline prompt. Validates the result, attaches
    /// to the Transcript, and enqueues for Enterprise Brain sync.
    private static func extractAndAttachPayload(
        rawText: String,
        transcriptID: UUID,
        capturedAt: Date,
        actor: PersistenceActor
    ) async {
        do {
            let rawPayload = try await ClaudeService.shared.extractPayload(from: rawText, capturedAt: capturedAt)
            let validated = PayloadValidator.validate(rawPayload)

            guard PayloadValidator.isUsable(validated) else {
                log_static("Extraction produced no usable entities for \(transcriptID.uuidString.prefix(8))")
                return
            }

            let data = try JSONEncoder().encode(validated)
            try await actor.attachPayload(transcriptID: transcriptID, payloadData: data)

            log_static("Extraction complete for \(transcriptID.uuidString.prefix(8)): \(validated.title) (\(validated.facts.count) facts, \(validated.people.count) people)")
        } catch {
            log_static("Extraction failed: \(error.localizedDescription)")
        }
    }

    private static func log_static(_ message: String) {
        #if DEBUG
        print("[Penlo Audio] \(message)")
        #endif
    }
}
