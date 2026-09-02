//
//  SplashView.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI

/// The Earth as vector geometry on a rotating sphere.
///
/// Coastlines are coarse lat/lon polygons — stylised, as befits 112 points —
/// projected orthographically with the axis tilted toward the viewer.
/// Driving the longitude continuously turns the sphere for real: land
/// foreshortens toward the limb and slides behind it, which is the same
/// motion the wireframe globe had, now with a planet on it. Vertices on the
/// far side are pushed out to the horizon so a continent straddling the
/// limb is cut cleanly rather than folding across the face.
struct EarthShape: Shape {
    enum Layer { case land, graticule }

    var layer: Layer
    /// One full turn per unit.
    var phase: Double
    /// Axis tilt toward the viewer, radians. ~23°, the real obliquity.
    var tilt = 0.40

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    // (longitude, latitude) in degrees, one polygon per landmass.
    private static let land: [[(Double, Double)]] = [
        // North America
        [(-168,66),(-140,70),(-95,72),(-80,62),(-60,47),(-70,42),(-76,35),(-80,26),
         (-90,30),(-97,26),(-105,20),(-88,15),(-77,8),(-84,10),(-105,23),(-115,30),
         (-124,40),(-130,55),(-150,60),(-165,58)],
        // Greenland
        [(-55,60),(-42,60),(-20,70),(-25,82),(-60,82),(-70,76)],
        // South America
        [(-77,8),(-60,10),(-50,0),(-35,-5),(-38,-15),(-42,-23),(-48,-28),(-53,-34),
         (-58,-39),(-65,-45),(-68,-52),(-72,-53),(-75,-45),(-71,-30),(-70,-18),(-81,-5)],
        // Africa
        [(-17,15),(-6,36),(10,37),(20,32),(32,31),(43,12),(51,12),(40,-2),(40,-15),
         (35,-25),(30,-34),(18,-34),(12,-17),(9,-2),(9,5),(-8,5)],
        // Eurasia, with Arabia and India as bumps on the south coast
        [(-10,36),(0,44),(5,58),(20,71),(60,72),(100,78),(140,72),(180,68),(158,58),
         (140,48),(122,40),(122,30),(110,20),(100,5),(90,22),(80,15),(77,8),(72,20),
         (60,25),(58,15),(45,13),(43,25),(35,36),(28,37),(20,38),(10,44)],
        // Australia
        [(114,-22),(122,-17),(135,-12),(142,-11),(146,-19),(153,-27),(150,-37),
         (140,-38),(130,-32),(116,-35)],
        // Antarctica — a cap ringing the pole
        [(-180,-70),(-150,-72),(-120,-74),(-90,-72),(-60,-68),(-30,-72),(0,-70),
         (30,-68),(60,-67),(90,-66),(120,-66),(150,-70),(180,-70),(180,-90),(-180,-90)],
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let spin = phase * 2 * .pi

        // Sphere point for a lon/lat after spin and tilt: screen x, y and
        // depth z (positive = toward the viewer).
        func place(_ lonDeg: Double, _ latDeg: Double) -> (x: Double, y: Double, z: Double) {
            let lon = lonDeg * .pi / 180 + spin
            let lat = latDeg * .pi / 180
            let x = cos(lat) * sin(lon)
            let y = sin(lat)
            let z = cos(lat) * cos(lon)
            return (x, y * cos(tilt) - z * sin(tilt), y * sin(tilt) + z * cos(tilt))
        }
        func screen(_ p: (x: Double, y: Double, z: Double)) -> CGPoint {
            var (x, y) = (p.x, p.y)
            if p.z < 0 {                       // behind: clamp to the horizon
                let len = max(sqrt(x * x + y * y), 1e-6)
                x /= len; y /= len
            }
            return CGPoint(x: c.x + CGFloat(x) * r, y: c.y - CGFloat(y) * r)
        }

        switch layer {
        case .land:
            for polygon in Self.land {
                let placed = polygon.map { place($0.0, $0.1) }
                guard placed.contains(where: { $0.z > 0 }) else { continue }
                for (i, p) in placed.enumerated() {
                    i == 0 ? path.move(to: screen(p)) : path.addLine(to: screen(p))
                }
                path.closeSubpath()
            }

        case .graticule:
            // Meridians every 30°, parallels every 30°: only the near side.
            for lonDeg in stride(from: -180.0, to: 180.0, by: 30.0) {
                var drawing = false
                for latDeg in stride(from: -90.0, through: 90.0, by: 5.0) {
                    let p = place(lonDeg, latDeg)
                    if p.z <= 0 { drawing = false; continue }
                    let q = screen(p)
                    drawing ? path.addLine(to: q) : path.move(to: q)
                    drawing = true
                }
            }
            for latDeg in stride(from: -60.0, through: 60.0, by: 30.0) {
                var drawing = false
                for lonDeg in stride(from: -180.0, through: 180.0, by: 5.0) {
                    let p = place(lonDeg, latDeg)
                    if p.z <= 0 { drawing = false; continue }
                    let q = screen(p)
                    drawing ? path.addLine(to: q) : path.move(to: q)
                    drawing = true
                }
            }
        }
        return path
    }
}

/// The turning planet: ocean, land, a faint graticule for the spin cue, limb
/// shading and a highlight so the disc reads as a sphere.
struct EarthView: View {
    var phase: Double

    private let ocean = RadialGradient(
        colors: [Color(red: 0.36, green: 0.68, blue: 0.93), Color(red: 0.06, green: 0.25, blue: 0.52)],
        center: UnitPoint(x: 0.40, y: 0.36), startRadius: 4, endRadius: 80)
    private let land = LinearGradient(
        colors: [Color(red: 0.52, green: 0.80, blue: 0.45), Color(red: 0.19, green: 0.55, blue: 0.32)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(ocean)
                EarthShape(layer: .land, phase: phase).fill(land)
                EarthShape(layer: .graticule, phase: phase)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                Circle().fill(RadialGradient(
                    colors: [.clear, Color.black.opacity(0.55)],
                    center: UnitPoint(x: 0.40, y: 0.36),
                    startRadius: side * 0.20, endRadius: side * 0.60))
                    .blendMode(.multiply)
                Circle().fill(RadialGradient(
                    colors: [Color.white.opacity(0.35), .clear],
                    center: UnitPoint(x: 0.32, y: 0.26),
                    startRadius: 0, endRadius: side * 0.28))
                    .blendMode(.screen)
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// Cold-start screen: a spinning globe that resolves into the Insider One
/// mark, with the app's name settling in beneath it.
struct SplashView: View {
    /// Called once the sequence has finished and the splash has faded out.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase = 0.0
    @State private var spinning = true
    /// Drives `phase` by hand at 60 Hz for a steady, continuous turn.
    private let ticker = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
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
                    globe
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

                VStack(spacing: 6) {
                    Text("Insider One")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(.white)
                    Text("Geofence Health Check")
                        .font(.system(size: 15, weight: .medium))
                        .tracking(0.3)
                        .foregroundColor(.insiderHitPink)
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)
            }
            .offset(y: -30)
        }
        .opacity(screenOpacity)
        .onAppear(perform: run)
        .onReceive(ticker) { _ in
            guard spinning else { return }
            phase += 1.0 / 60 / 2.4   // one full turn every 2.4 s, as the wireframe had
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Insider One, Geofence Health Check")
    }

    private var globe: some View {
        EarthView(phase: phase)
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

        // 2. It resolves into the mark: the globe tightens and fades as the
        //    mark springs up through it.
        after(1.9) {
            withAnimation(.easeIn(duration: 0.45)) {
                globeOpacity = 0
                globeScale = 0.62
            }
            after(0.5) { spinning = false }
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
