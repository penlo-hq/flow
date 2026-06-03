//
//  BluetoothManager.swift
//  flow
//
//  CoreBluetooth wrapper for the Penlo wearable. Handles discovery,
//  connection, aggressive auto-reconnect, background state restoration
//  (`willRestoreState`), and characteristic subscription.
//
//  All CB delegate callbacks arrive on `bleQueue` (non-main) and hop to
//  `@MainActor` to mutate @Observable / @Published state.
//

import Foundation
import Combine
import CoreBluetooth
import Observation
import UIKit

// MARK: - Penlo BLE Constants

/// Placeholder UUIDs — replace with the real Penlo hardware values.
enum PenloBLE: Sendable {
    nonisolated(unsafe) static let serviceUUID   = CBUUID(string: "00010000-7365-6E6C-6F2D-70656E6C6F00")
    nonisolated(unsafe) static let audioCharUUID = CBUUID(string: "00010001-7365-6E6C-6F2D-70656E6C6F00")
    nonisolated(unsafe) static let dataCharUUID  = CBUUID(string: "00010002-7365-6E6C-6F2D-70656E6C6F00")
    nonisolated(unsafe) static let buttonCharUUID = CBUUID(string: "00010003-7365-6E6C-6F2D-70656E6C6F00")
    /// Passed to `CBCentralManager(delegate:queue:options:)` so iOS can
    /// wake the app in the background and call `willRestoreState`.
    static let restoreID = "com.getflow.flow.ble-central"
}

// MARK: - BluetoothManager

@MainActor
final class BluetoothManager: NSObject, ObservableObject {

    /// Explicit nonisolated conformance required because
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise
    /// synthesize a MainActor-isolated `objectWillChange`, breaking
    /// Combine's `ObservableObject` protocol requirement.
    nonisolated let objectWillChange = ObservableObjectPublisher()

    // MARK: Published State (drives UI)

    @Published private(set) var state: WearableState = .disconnected
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isSyncing: Bool = false

    /// Callback the owner can set so `AppStateManager` gets notified.
    var onStateChange: ((WearableState) -> Void)?

    /// Invoked on `bleQueue` when PCM audio packets arrive — must not block.
    nonisolated(unsafe) var onHardwareAudio: (@Sendable (Data) -> Void)?

    /// Invoked on the main actor when the wearable button characteristic fires.
    nonisolated(unsafe) var onHardwareAction: (@Sendable () -> Void)?

    // MARK: Private BLE

    private let bleQueue = DispatchQueue(
        label: "com.getflow.flow.ble",
        qos: .userInitiated
    )
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    /// Remember the peripheral's identifier so we can attempt a direct
    /// reconnect without a full scan (faster, quieter).
    private var knownPeripheralID: UUID?

    /// True when we intentionally disconnected — suppresses auto-reconnect.
    private var userRequestedDisconnect = false

    // MARK: Init

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: PenloBLE.restoreID,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    // MARK: Public API

    func connect() {
        guard state == .disconnected else { return }
        userRequestedDisconnect = false
        applyState(.searching)

        if let id = knownPeripheralID,
           let cached = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = cached
            peripheral?.delegate = self
            central.connect(cached, options: nil)
            log("Direct reconnect to known peripheral")
        } else {
            startScan()
        }
    }

    func disconnect() {
        userRequestedDisconnect = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        applyState(.disconnected)
    }

    /// Marks all unsynced transcripts as synced using SwiftData.
    func syncAll(using context: @Sendable @escaping () async throws -> Void) {
        guard !isSyncing else { return }
        isSyncing = true
        Task { [weak self] in
            do {
                try await context()
            } catch {
                #if DEBUG
                print("[Penlo BLE] Sync failed: \(error.localizedDescription)")
                #endif
            }
            await MainActor.run {
                self?.isSyncing = false
                Haptics.success()
            }
        }
    }

    // MARK: Scan

    private func startScan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [PenloBLE.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("Scanning for Penlo service…")
    }

    private func stopScan() {
        if central.isScanning { central.stopScan() }
    }

    // MARK: Auto-Reconnect

    /// Called after an unexpected disconnect. Tries the fast path first
    /// (retrieve by ID), then falls back to a full scan.
    private func attemptAutoReconnect() {
        guard !userRequestedDisconnect else { return }
        applyState(.searching)

        if let id = knownPeripheralID,
           let cached = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = cached
            peripheral?.delegate = self
            central.connect(cached, options: nil)
            log("Auto-reconnect: direct connect to cached peripheral")
        } else {
            startScan()
        }
    }

    // MARK: State Helpers

    private func applyState(_ newState: WearableState) {
        let fire = { [weak self] in
            guard let self else { return }
            self.state = newState
            self.onStateChange?(newState)
            switch newState {
            case .connected:  Haptics.medium()
            case .recording:  Haptics.medium()
            case .disconnected where !self.userRequestedDisconnect: break
            case .disconnected: Haptics.light()
            default: break
            }
        }

        if Thread.isMainThread {
            fire()
        } else {
            Task { @MainActor in fire() }
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[Penlo BLE] \(message)")
        #endif
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch central.state {
            case .poweredOn:
                self.log("Bluetooth powered on")
                if self.state == .searching { self.startScan() }
            case .poweredOff:
                self.log("Bluetooth powered off")
                self.applyState(.disconnected)
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stopScan()
            self.peripheral = peripheral
            self.knownPeripheralID = peripheral.identifier
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            self.log("Discovered \(peripheral.name ?? "Penlo"), connecting…")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyState(.connected)
            peripheral.discoverServices([PenloBLE.serviceUUID])
            self.log("Connected")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("Failed to connect: \(error?.localizedDescription ?? "unknown")")
            self.attemptAutoReconnect()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("Disconnected: \(error?.localizedDescription ?? "clean")")
            if self.userRequestedDisconnect {
                self.applyState(.disconnected)
            } else {
                self.attemptAutoReconnect()
            }
        }
    }

    // MARK: Background State Restoration

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peripheral = restored
                self.knownPeripheralID = restored.identifier
                restored.delegate = self
                self.log("Restored peripheral from background: \(restored.name ?? "Penlo")")
                if restored.state == .connected {
                    self.applyState(.connected)
                    restored.discoverServices([PenloBLE.serviceUUID])
                } else {
                    self.attemptAutoReconnect()
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: (any Error)?
    ) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PenloBLE.serviceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [PenloBLE.audioCharUUID, PenloBLE.dataCharUUID, PenloBLE.buttonCharUUID],
            for: service
        )
        Task { @MainActor [weak self] in
            self?.log("Discovered Penlo service, looking for characteristics…")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyState(.recording)
            self.log("Subscribed to characteristics — now streaming")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }

        switch characteristic.uuid {
        case PenloBLE.audioCharUUID:
            onHardwareAudio?(data)
        case PenloBLE.buttonCharUUID:
            Task { @MainActor in
                onHardwareAction?()
            }
        case PenloBLE.dataCharUUID:
            let level = data.first.map { Int($0) }
            Task { @MainActor [weak self] in
                guard let self, let level else { return }
                self.batteryLevel = level
                self.log("Battery update: \(level)%")
            }
        default:
            break
        }
    }
}
