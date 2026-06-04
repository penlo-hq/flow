//
//  WearableStatusPill.swift
//  flow
//
//  Dynamic Island-style hardware pill that doubles as the entry
//  point to the Privacy Staging Vault. When unsynced local data
//  exists, the status dot morphs into a slow-pulsing Royal Blue
//  liquid-glass orb and a "N Pending" badge appears.
//

import SwiftUI

struct WearableStatusPill: View {
    @ObservedObject var bluetooth: BluetoothManager
    let unsyncedCount: Int
    var isPhoneListening: Bool = false
    var appStateManager: AppStateManager? = nil
    let onTap: () -> Void

    private var hasPending: Bool { unsyncedCount > 0 }
    private var isActive: Bool { bluetooth.state.isLive || isPhoneListening }

    // MARK: - Derived system status

    private var systemState: AppStateManager.SystemState? {
        appStateManager?.state
    }

    private var pillLabel: String {
        if isPhoneListening { return "Listening" }
        if systemState == .fault { return "Error" }
        if systemState == .offline { return "Offline" }
        if systemState == .syncing { return "Syncing" }
        if let battery = bluetooth.batteryLevel { return "\(battery)%" }
        return bluetooth.state.label
    }

    private var pillLabelColor: Color {
        if isPhoneListening { return .red }
        if systemState == .fault { return .orange }
        if systemState == .offline { return Color.textSecondary }
        return Color.textSecondary
    }

    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            HStack(spacing: 8) {
                leadingIcon
                    .font(.system(size: 10, weight: .bold))

                Text(pillLabel)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pillLabelColor)

                statusIndicator

                if hasPending {
                    Text("\(unsyncedCount) Pending")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.royalBlue)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isPhoneListening
                    ? AnyShapeStyle(Color.red.opacity(0.06))
                    : systemState == .fault
                        ? AnyShapeStyle(Color.orange.opacity(0.08))
                        : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isPhoneListening
                        ? Color.red.opacity(0.3)
                        : systemState == .fault
                            ? Color.orange.opacity(0.3)
                            : Color.textPrimary.opacity(0.06),
                    lineWidth: (isPhoneListening || systemState == .fault) ? 1 : 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.3), value: hasPending)
        .animation(.snappy(duration: 0.3), value: isPhoneListening)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isPhoneListening {
            Image(systemName: "mic.fill").foregroundStyle(Color.red)
                .symbolEffect(.pulse, isActive: true)
        } else if systemState == .fault {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if systemState == .offline {
            Image(systemName: "wifi.slash").foregroundStyle(Color.textSecondary)
        } else if systemState == .syncing {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.royalBlue)
                .symbolEffect(.rotate, isActive: true)
        } else {
            Image(systemName: isActive ? "waveform" : "bolt.horizontal.fill")
                .foregroundStyle(Color.textPrimary)
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        if systemState == .fault {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        } else if systemState == .offline {
            Circle().fill(Color.textSecondary.opacity(0.5)).frame(width: 6, height: 6)
        } else if hasPending {
            VaultPulse()
        } else {
            Circle().fill(Color.textSecondary.opacity(0.3)).frame(width: 6, height: 6)
        }
    }

    private var accessibilityDescription: String {
        if isPhoneListening { return "Phone listening. \(unsyncedCount) pending." }
        if systemState == .fault { return "System error. Tap for details." }
        if systemState == .offline { return "Offline." }
        return "Penlo. \(bluetooth.state.label). \(unsyncedCount) pending."
    }
}

// MARK: - Vault Pulse

/// Slow-pulsing Royal Blue liquid-glass dot indicating unsynced local data.
private struct VaultPulse: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.royalBlue)
                .frame(width: 6, height: 6)
            Circle()
                .fill(Color.royalBlue.opacity(0.4))
                .frame(width: 6, height: 6)
                .blur(radius: 2)
                .scaleEffect(pulse ? 2.4 : 1.0)
                .opacity(pulse ? 0 : 0.8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

#Preview {
    ZStack {
        Color.canvas.ignoresSafeArea()
        VStack(spacing: 30) {
            WearableStatusPill(bluetooth: BluetoothManager(), unsyncedCount: 3) {}
            WearableStatusPill(bluetooth: BluetoothManager(), unsyncedCount: 0) {}
        }
    }
    .preferredColorScheme(.dark)
}
