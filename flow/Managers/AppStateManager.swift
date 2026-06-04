//
//  AppStateManager.swift
//  flow
//
//  The global state machine for Penlo. Tracks the overall system status
//  and keeps it in lock-step with network reachability (NWPathMonitor),
//  Bluetooth connectivity, and the audio transcription pipeline.
//
//  The "liquid glass" indicator binds to `isLiveActivity` — it only
//  animates during recording, transcribing, or syncing.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppStateManager {

    // MARK: System State

    enum SystemState: String {
        case idle
        case recording
        case transcribing
        case syncing
        case offline
        case fault
    }

    private(set) var state: SystemState = .idle

    /// Live network reachability.
    private(set) var isOnline: Bool = true

    /// Whether the Penlo wearable is connected over BLE.
    private(set) var isWearableConnected: Bool = false

    /// Human-readable description when state == .fault.
    private(set) var faultMessage: String?

    /// True while actively recording, transcribing, or syncing — gates
    /// the liquid-glass animation so it never runs when idle.
    var isLiveActivity: Bool {
        state == .recording || state == .transcribing || state == .syncing
    }

    // MARK: Private

    private var stateBeforeOffline: SystemState = .idle

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(
        label: "com.getflow.flow.network-monitor",
        qos: .utility
    )

    // MARK: Lifecycle

    init() {
        startNetworkMonitoring()
    }

    func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                self?.applyConnectivity(isOnline: online)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    func stopNetworkMonitoring() {
        pathMonitor.cancel()
    }

    // MARK: State Intents

    func beginRecording()     { faultMessage = nil; transition(to: .recording) }
    func beginTranscribing()  { faultMessage = nil; transition(to: .transcribing) }
    func beginSyncing()       { faultMessage = nil; transition(to: .syncing) }
    func goIdle()             { faultMessage = nil; transition(to: .idle) }

    /// Transition to a non-recoverable fault state. The UI should display
    /// `faultMessage` and stop the liquid-glass animation.
    func enterFault(message: String) {
        faultMessage = message
        state = .fault
    }

    /// Clear a fault and return to idle (or restore pre-offline state when back online).
    func clearFault() {
        faultMessage = nil
        if isOnline {
            state = stateBeforeOffline == .fault ? .idle : stateBeforeOffline
        } else {
            state = .offline
        }
    }

    // MARK: Bluetooth Integration

    func handleWearableStateChange(_ wearableState: WearableState) {
        switch wearableState {
        case .recording:
            isWearableConnected = true
            transition(to: .recording)
        case .connected:
            isWearableConnected = true
            if state != .syncing && state != .transcribing { transition(to: .idle) }
        case .searching:
            isWearableConnected = false
        case .disconnected:
            isWearableConnected = false
            if state == .recording { transition(to: .idle) }
        }
    }

    // MARK: Audio / Transcription Integration

    /// Called by `AudioEngineManager.onTranscribingChange`.
    func handleTranscribingChange(_ isActive: Bool) {
        if isActive {
            transition(to: .transcribing)
        } else if state == .transcribing {
            transition(to: isWearableConnected ? .recording : .idle)
        }
    }

    // MARK: Internals

    private func transition(to newState: SystemState) {
        guard newState != .fault else { return }
        guard isOnline else {
            stateBeforeOffline = newState
            return
        }
        state = newState
    }

    private func applyConnectivity(isOnline online: Bool) {
        guard online != isOnline else { return }
        isOnline = online

        if online {
            if state == .offline { state = stateBeforeOffline }
        } else {
            if state != .offline { stateBeforeOffline = state }
            state = .offline
        }
    }
}
