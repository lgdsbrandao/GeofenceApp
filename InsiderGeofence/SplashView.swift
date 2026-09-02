//
//  SplashView.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI

/// One hemisphere of a wireframe globe, orthographically projected.
///
/// A meridian at longitude λ from the viewer projects to a half-ellipse
/// bowed sideways by sin(λ); as λ advances it sweeps across the face from one
/// limb to the other, which is what reads as rotation. Only the meridians
/// with cos(λ) on this shape's side are drawn, so the near hemisphere can be
/// stroked bright and the far one dim — the depth cue that sells the turn.
///
/// (Drawing full ellipses for every meridian does not work: with even spacing
/// the set of widths is identical at every instant, so nothing visibly moves.)
struct GlobeShape: Shape {
    /// One full turn per unit.
    var phase: Double
    /// Near hemisphere when true, far when false.
    var front = true
    /// Parallels and the outline belong to the near side only.
    var withFrame = true

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)

        if withFrame {
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            for lat in [-1.0, -0.5, 0.0, 0.5, 1.0] {
                let y = c.y - CGFloat(sin(lat)) * r
                let half = r * CGFloat(cos(lat))
                path.move(to: CGPoint(x: c.x - half, y: y))
                path.addLine(to: CGPoint(x: c.x + half, y: y))
            }
        }

        let meridians = 8
        let segments = 28
        for i in 0..<meridians {
            let lon = phase * 2 * .pi + Double(i) * 2 * .pi / Double(meridians)
            let facing = cos(lon)
            guard front ? facing > 0 : facing < 0 else { continue }
            let bow = CGFloat(sin(lon)) * r
            for k in 0...segments {
                let lat = -Double.pi / 2 + Double.pi * Double(k) / Double(segments)
                let point = CGPoint(x: c.x + bow * CGFloat(cos(lat)),
                                    y: c.y - r * CGFloat(sin(lat)))
                k == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
        return path
    }
}

/// Cold-start screen: a spinning globe that resolves into the Insider One
/// mark, with the app's name settling in beneath it.
struct SplashView: View {
    /// Called once the sequence has finished and the splash has faded out.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase = 0.0
    @State private var globeOpacity = 0.0
    @State private var globeScale = 0.72
    @State private var logoOpacity = 0.0
    @State private var logoScale = 0.55
    @State private var titleOpacity = 0.0
    @State private var titleOffset: CGFloat = 12
    @State private var screenOpacity = 1.0

    private let markSize: CGFloat = 112

    var body: some View {
        ZStack {
            Color.insiderBackground.ignoresSafeArea()

            // A quiet warm halo behind the mark, so the gradient has
            // something to sit in rather than floating on flat black.
            RadialGradient(colors: [Color.insiderPrimary.opacity(0.22), .clear],
                           center: .center, startRadius: 4, endRadius: 190)
                .frame(width: 380, height: 380)
                .offset(y: -30)

            VStack(spacing: 26) {
                ZStack {
                    ZStack {
                        GlobeShape(phase: phase, front: false, withFrame: false)
                            .stroke(Color.insiderHitPink.opacity(0.28),
                                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                        GlobeShape(phase: phase, front: true)
                            .stroke(Color.insiderHitPink.opacity(0.92),
                                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    }
                    .frame(width: markSize, height: markSize)
                    .opacity(globeOpacity)
                    .scaleEffect(globeScale)

                    Image("InsiderMark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: markSize, height: markSize)
                        .opacity(logoOpacity)
                        .scaleEffect(logoScale)
                }
                .frame(width: markSize, height: markSize)

                Text("Geofence Test App")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.white)
                    .opacity(titleOpacity)
                    .offset(y: titleOffset)
            }
            .offset(y: -30)
        }
        .opacity(screenOpacity)
        .onAppear(perform: run)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Geofence Test App")
    }

    private func run() {
        if reduceMotion {
            // No spin: the mark and name simply appear, then hand over.
            logoOpacity = 1; logoScale = 1
            titleOpacity = 1; titleOffset = 0
            after(1.4) { fadeOutAndFinish() }
            return
        }

        // 1. The globe arrives and starts turning.
        withAnimation(.easeOut(duration: 0.55)) {
            globeOpacity = 1
            globeScale = 1
        }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            phase = 1
        }

        // 2. It resolves into the mark: the globe tightens and fades as the
        //    mark springs up through it.
        after(1.9) {
            withAnimation(.easeIn(duration: 0.45)) {
                globeOpacity = 0
                globeScale = 0.62
            }
            withAnimation(.interpolatingSpring(stiffness: 170, damping: 15).delay(0.08)) {
                logoOpacity = 1
                logoScale = 1
            }
        }

        // 3. The name settles in beneath it.
        after(2.45) {
            withAnimation(.easeOut(duration: 0.5)) {
                titleOpacity = 1
                titleOffset = 0
            }
        }

        // 4. Hold, then hand over to the app.
        after(3.5) { fadeOutAndFinish() }
    }

    private func fadeOutAndFinish() {
        withAnimation(.easeInOut(duration: 0.45)) { screenOpacity = 0 }
        after(0.5) { onFinished() }
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
