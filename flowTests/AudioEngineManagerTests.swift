//
//  AudioEngineManagerTests.swift
//  flowTests
//

import AVFoundation
import Testing
@testable import flow

struct AudioEngineManagerTests {

    @Test func convertToPCMBuffer_validPacket() {
        var samples = [Int16](repeating: 0, count: 160)
        samples[0] = 1000
        let data = samples.withUnsafeBytes { Data($0) }
        let buffer = AudioEngineManager.convertToPCMBuffer(data: data)
        #expect(buffer != nil)
        #expect(buffer?.frameLength == 160)
        #expect(buffer?.format.sampleRate == 16_000)
        #expect(buffer?.format.channelCount == 1)
    }

    @Test func convertToPCMBuffer_emptyDataReturnsNil() {
        #expect(AudioEngineManager.convertToPCMBuffer(data: Data()) == nil)
    }

    @Test @MainActor func injectHardwareActionFlag_appendsBookmark() async {
        let engine = AudioEngineManager()
        var partial = ""
        engine.onPartialResult = { partial = $0 }

        guard await engine.requestSpeechPermission() else { return }
        engine.startTranscribing(source: .hardwareBLE)
        guard engine.isTranscribing else { return }

        engine.injectHardwareActionFlag()
        #expect(partial.contains("HARDWARE_ACTION_FLAG"))

        engine.stopTranscribing()
    }

    @Test @MainActor func hardwareBLEDoesNotStartInputEngine() async {
        let engine = AudioEngineManager()
        guard await engine.requestSpeechPermission() else { return }

        engine.startTranscribing(source: .hardwareBLE)
        guard engine.isTranscribing else { return }

        #expect(engine.isInputEngineRunning == false)
        #expect(engine.currentSource == .hardwareBLE)

        engine.stopTranscribing()
    }
}
