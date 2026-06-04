//
//  TypingRichTextView.swift
//  flow
//
//  ChatGPT-style fast typewriter reveal for Penlo / Brain answers.
//

import SwiftUI

struct TypingRichTextView: View {
    let text: String
    let isUser: Bool
    var enabled: Bool = true
    var charsPerSecond: Double = 130
    var onProgress: (() -> Void)? = nil
    var onComplete: (() -> Void)? = nil

    @State private var visibleCount = 0
    @State private var finished = false

    private var visibleText: String {
        if !enabled || finished { return text }
        return String(text.prefix(visibleCount))
    }

    private var isTyping: Bool {
        enabled && !finished && visibleCount < text.count
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            RichTextView(text: visibleText, isUser: isUser)
            if isTyping {
                TypingCursorView()
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isTyping { skipToEnd() }
        }
        .task(id: taskKey) {
            await runTyping()
        }
    }

    private var taskKey: String {
        "\(text.hashValue)-\(enabled)"
    }

    @MainActor
    private func runTyping() async {
        guard enabled, !text.isEmpty else {
            visibleCount = text.count
            finished = true
            onComplete?()
            return
        }

        visibleCount = 0
        finished = false

        let tickNs: UInt64 = 28_000_000
        let chunk = max(1, Int(charsPerSecond * 0.028))

        while visibleCount < text.count {
            try? await Task.sleep(nanoseconds: tickNs)
            if Task.isCancelled { return }
            visibleCount = min(text.count, visibleCount + chunk)
            onProgress?()
        }

        finished = true
        onComplete?()
    }

    @MainActor
    private func skipToEnd() {
        visibleCount = text.count
        finished = true
        onComplete?()
    }
}

// MARK: - Cursor

private struct TypingCursorView: View {
    @State private var opaque = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.royalBlue)
            .frame(width: 2, height: 16)
            .opacity(opaque ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    opaque = false
                }
            }
    }
}
