//
//  LiquidGlassOrb.swift
//  flow
//
//  The "liquid glass" visual: a subtly morphing, blurred Royal Blue
//  gradient. Used for active listening / syncing states and the
//  empty-state pulse.
//
//  POWER NOTE: the continuous morphing animation only runs when
//  `isActive == true`. When idle the orb does a slow gentle pulse.
//

import SwiftUI

struct LiquidGlassOrb: View {
    var size: CGFloat = 120
    var isActive: Bool = false

    @State private var animate = false

    private var outerBlur: CGFloat { isActive ? 18 : 8 }
    private var innerBlur: CGFloat { isActive ? 22 : 6 }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.royalBlue.opacity(isActive ? 0.9 : 0.55),
                            Color.royalBlue.opacity(isActive ? 0.25 : 0.15),
                            Color.royalBlue.opacity(0.0)
                        ],
                        center: animate ? .topLeading : .bottomTrailing,
                        startRadius: 4,
                        endRadius: size * 0.9
                    )
                )
                .blur(radius: outerBlur)

            Circle()
                .fill(Color.royalBlue.opacity(isActive ? 0.6 : 0.45))
                .frame(width: size * 0.55, height: size * 0.55)
                .offset(
                    x: animate ? size * 0.12 : -size * 0.12,
                    y: animate ? -size * 0.1 : size * 0.1
                )
                .blur(radius: innerBlur)
        }
        .frame(width: size, height: size)
        .scaleEffect(isActive ? (animate ? 1.08 : 0.96) : (animate ? 1.02 : 0.98))
        .opacity(isActive ? 1.0 : 1.0)
        .onAppear { startAnimation() }
        .onChange(of: isActive) { _, _ in startAnimation() }
        .accessibilityHidden(true)
    }

    private func startAnimation() {
        let duration: Double = isActive ? 2.2 : 3.6
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}

#Preview {
    ZStack {
        Color.canvas.ignoresSafeArea()
        VStack(spacing: 60) {
            LiquidGlassOrb(size: 140, isActive: false)
            LiquidGlassOrb(size: 140, isActive: true)
        }
    }
}
