//
//  ContentView.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI
import MapKit
import CoreLocation

/// Tracks two different things, and the difference matters.
///
/// `original` is the first fix after launch — the real position to return to,
/// captured before any spoofing, and never overwritten. `current` is wherever
/// the device is *now*, including a spoofed position, which is what the zone
/// search needs: looking for nearby geofences from a launch-time coordinate
/// returns the wrong ones once the device has been moved.
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var original: CLLocationCoordinate2D?
    @Published var current: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()   // stays on, so `current` keeps up
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        current = latest.coordinate
        if original == nil { original = latest.coordinate }
    }
}

/// One zone as returned by Insider's geofence API.
struct InsiderZone: Decodable, Identifiable {
    let id: Int
    let identifier: String
    let latitude: Double
    let longitude: Double
    let radius: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Where a test run begins and ends.
    ///
    /// Entry fires as soon as the boundary is crossed, but iOS only confirms
    /// an *exit* well beyond it: measured at 417 m leaving a 200 m fence,
    /// roughly twice the radius. Starting — and returning to — 2.5x the radius
    /// clears that hysteresis so the exit actually fires. The 300 m floor
    /// covers small zones, where the buffer does not scale down.
    var startDistance: Double { max(radius * 2.5, radius + 300) }

    var startCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: latitude + startDistance / 111_320.0,
            longitude: longitude)
    }
}

private struct ZoneListResponse: Decodable {
    let geofences: [InsiderZone]
}

private let insiderPartner = "oxttest"
private let insiderZonesURL = "https://mobile.useinsider.com/api/v1/geofences"
/// Which modal is up. A single sheet driver avoids the iOS 14 behaviour
/// where only the last `.sheet(isPresented:)` on a view actually presents.
private enum PanelSheet: Int, Identifiable {
    case zones, settings
    var id: Int { rawValue }
}

private let walkSpeedMps = 1.4
private let runSpeedMps = 10.0

/// Translucent chrome for the panels floating over the map.
///
/// SwiftUI's `.ultraThinMaterial` is iOS 15+, and this app still targets 14,
/// so the blur comes from UIKit.
struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemThickMaterialDark

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: style)
    }
}

extension View {
    /// A panel sitting on top of the map: blurred, rounded, with a hairline
    /// and a soft shadow so it separates from whatever is underneath.
    func floating(cornerRadius: CGFloat) -> some View {
        self
            .background(
                ZStack {
                    BlurView(style: .systemThickMaterialDark)
                    Color.insiderBackground.opacity(0.55)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.insiderPrimary.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 14, y: 5)
    }
}

struct ContentView: View {
    @StateObject private var tracker = LocationTracker()

    #if targetEnvironment(simulator)
    @AppStorage("helperHost") private var helperHost: String = "localhost"
    #else
    @AppStorage("helperHost") private var helperHost: String = ""
    #endif
    @AppStorage("helperToken") private var helperToken: String = ""
    @AppStorage("partnerBundleID") private var partnerBundleID: String = "com.useinsider.mobile-ios"

    @State private var zones: [InsiderZone] = []
    @State private var selectedZone: InsiderZone?
    @State private var isLoadingZones = false
    @State private var activeSheet: PanelSheet?

    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isSending = false
    @State private var isRunning = false
    @State private var isPaused = false
    @State private var runMode = false
    @State private var entered = false
    @State private var exited = false
    @State private var leg = "out"
    @State private var metresFromCentre: Double?

    @State private var authFailed = false

    var body: some View {
        ZStack {
            ZoneMapView(zone: selectedZone,
                        startCoordinate: selectedZone?.startCoordinate)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    locateButton
                }
                controlPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .accentColor(.insiderPrimary)
        .preferredColorScheme(.dark)   // the brand is a dark ground
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .zones: zoneList
            case .settings: settingsSheet
            }
        }
    }

    // MARK: - Floating chrome

    /// The title sits dead centre and stays there: the mark and the gear are
    /// overlaid rather than laid out beside it, so the heading does not drift
    /// as the subtitle changes length.
    private var topBar: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("Geofence Test")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(.white)
                Text(selectedZone == nil
                     ? "Pick a zone to test"
                     : "In and back out to fire enter + exit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            HStack {
                brandMark
                Spacer()
                Button(action: { activeSheet = .settings }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(authFailed ? .insiderPrimary : .white.opacity(0.85))
                        .frame(width: 30, height: 30)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floating(cornerRadius: 18)
    }

    /// A nod to the Insider One mark — the logo's gradient ring, not a copy of
    /// the glyph itself.
    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(insiderGradient)
                .frame(width: 26, height: 26)
            Circle()
                .fill(Color.insiderBackground)
                .frame(width: 9, height: 9)
                .offset(x: 3, y: -3)
        }
    }

    /// Apple Maps puts the locate control on the map, not in a form — so does
    /// this, which frees the panel below for the test itself.
    private var locateButton: some View {
        Button(action: goToOriginalLocation) {
            Image(systemName: "location")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(tracker.original == nil ? .secondary : .insiderHitPink)
                .frame(width: 44, height: 44)
        }
        .floating(cornerRadius: 22)
        .disabled(isSending || tracker.original == nil)
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(spacing: 12) {
            zoneRow
            Divider()
            HStack(spacing: 10) {
                eventPill(title: "ENTER", done: entered, tint: .insiderPrimary)
                eventPill(title: "EXIT", done: exited, tint: .insiderHitPink)
            }
            statusLine
            paceButtons
        }
        .padding(14)
        .floating(cornerRadius: 22)
    }

    private var zoneRow: some View {
        Button(action: fetchZones) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.insiderPrimary.opacity(0.18))
                        .frame(width: 36, height: 36)
                    if isLoadingZones {
                        ProgressView()
                    } else {
                        Image(systemName: selectedZone == nil
                              ? "mappin.and.ellipse" : "scope")
                            .foregroundColor(.insiderPrimary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedZone?.identifier ?? "Choose a geofence")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(selectedZone.map {
                            String(format: "r %.0f m · start %.0f m out · in and back",
                                   $0.radius, $0.startDistance)
                         } ?? "Loads the zones configured for \(insiderPartner)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(isLoadingZones)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if !statusMessage.isEmpty {
                Image(systemName: statusIsError
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption2)
                Text(statusMessage).font(.caption2).lineLimit(2)
            } else if let metres = metresFromCentre {
                Text(String(format: "%.0f m from centre · heading %@",
                            metres, leg == "back" ? "out" : "in"))
                    .font(.caption2)
            } else {
                Text("Idle").font(.caption2)
            }
            Spacer(minLength: 0)   // paired with the leading one, so it centres
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .foregroundColor(statusIsError ? .insiderPrimary : .secondary)
    }

    private func eventPill(title: String, done: Bool, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? tint : Color.secondary.opacity(0.5))
            Text(title)
                .font(.caption.bold())
                .foregroundColor(done ? tint : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background((done ? tint : Color.secondary).opacity(done ? 0.16 : 0.09))
        .cornerRadius(10)
    }


    // MARK: - Settings

    private var settingsSheet: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    settingsCard(
                        title: "Connection",
                        footer: "The token is printed by geofence_panel.py when it starts."
                    ) {
                        settingsField("Mac helper", icon: "desktopcomputer",
                                      binding: $helperHost,
                                      placeholder: "192.168.x.x", keyboard: .URL)
                        settingsDivider
                        settingsField("Token", icon: "key.fill",
                                      binding: $helperToken,
                                      placeholder: "from helper startup",
                                      keyboard: .asciiCapable,
                                      tint: authFailed ? .insiderPrimary : .white)
                    }

                    settingsCard(
                        title: "Partner app",
                        footer: "iOS monitors at most 20 regions per app and keeps them "
                              + "across launches, so a zone added later is refused until "
                              + "the app is reinstalled. This reinstalls it from its own "
                              + "binary — no source needed — and clears its local data."
                    ) {
                        settingsField("Bundle id", icon: "app.badge",
                                      binding: $partnerBundleID,
                                      placeholder: "com.example.app", keyboard: .URL)
                        settingsDivider
                        Button(action: resetPartnerApp) {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Reset its geofence registrations")
                                    .font(.subheadline.bold())
                                Spacer(minLength: 0)
                            }
                            .foregroundColor(.insiderHitPink)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(Color.insiderFaluRed.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .disabled(isSending)
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .background(Color.insiderBackground.ignoresSafeArea())
            .navigationBarTitle(Text("Settings"), displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { activeSheet = nil })
        }
    }

    /// A settings group on the brand ground, matching the panels over the map.
    private func settingsCard<Content: View>(
        title: String, footer: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .tracking(1.1)
                .foregroundColor(.insiderPrimary)
                .padding(.leading, 4)

            VStack(spacing: 10) {
                content()
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.insiderPrimary.opacity(0.14), lineWidth: 0.5)
            )

            Text(footer)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
    }

    private func settingsField(_ title: String, icon: String,
                               binding: Binding<String>, placeholder: String,
                               keyboard: UIKeyboardType,
                               tint: Color = .white) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(tint == .white ? .insiderPrimary : tint)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
                .foregroundColor(tint)
            Spacer(minLength: 8)
            TextField(placeholder, text: binding)
                .keyboardType(keyboard)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private var paceButtons: some View {
        HStack(spacing: 8) {
            paceButton(title: "Walk", icon: "figure.walk", isRun: false)
            paceButton(title: "Run", icon: "figure.run", isRun: true)
            if isRunning {
                Button(action: togglePause) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 42)
                        .padding(.vertical, 12)
                }
                .background(isPaused ? Color.insiderPrimary : Color.insiderFaluRed)
                .foregroundColor(.white)
                .cornerRadius(13)
                .disabled(isSending)
            }
        }
    }

    /// Walk carries the logo gradient as the primary action; Run is the deep
    /// falu red beneath it, so they read as a hierarchy rather than a pair.
    private func paceButton(title: String, icon: String, isRun: Bool) -> some View {
        let active = isRunning && runMode == isRun
        return Button(action: { startTest(running: isRun) }) {
            HStack(spacing: 6) {
                if isSending && runMode == isRun {
                    ProgressView()
                } else {
                    Image(systemName: icon)
                    Text(active ? (isRun ? "Running…" : "Walking…") : title)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(
            Group {
                if isRun {
                    Color.insiderFaluRed
                } else {
                    insiderGradient
                }
            }
        )
        .foregroundColor(isRun ? Color.insiderHitPink : .white)
        .cornerRadius(13)
        .opacity(selectedZone == nil ? 0.45 : 1)
        .disabled(isSending || selectedZone == nil)
    }


    // MARK: - Zone list

    /// Cards on the brand ground rather than a stock List, so the sheet reads
    /// as the same surface as the panels over the map.
    private var zoneList: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 8) {
                    Text("Nearest first, from where the device is now")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)

                    ForEach(zones) { zone in
                        zoneListRow(zone)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.insiderBackground.ignoresSafeArea())
            .navigationBarTitle(Text("\(zones.count) geofences"), displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { activeSheet = nil })
        }
    }

    private func zoneListRow(_ zone: InsiderZone) -> some View {
        let isSelected = selectedZone?.id == zone.id
        return Button(action: { select(zone) }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.insiderPrimary.opacity(isSelected ? 0.28 : 0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: isSelected ? "scope" : "mappin.and.ellipse")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.insiderPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(zone.identifier)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(String(format: "%.5f, %.5f · r %.0f m",
                                zone.latitude, zone.longitude, zone.radius))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 3) {
                    if let away = distanceAway(from: zone) {
                        Text(away)
                            .font(.caption2.bold())
                            .foregroundColor(.insiderHitPink)
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(isSelected ? .insiderPrimary : .secondary)
                }
            }
            .padding(12)
            .background(Color.white.opacity(isSelected ? 0.10 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.insiderPrimary.opacity(isSelected ? 0.55 : 0.12),
                                  lineWidth: isSelected ? 1.2 : 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// How far the zone is from the device — the same measure the API sorted
    /// by, so the ordering stops looking arbitrary.
    private func distanceAway(from zone: InsiderZone) -> String? {
        guard let here = tracker.current ?? tracker.original else { return nil }
        let metres = CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: zone.latitude, longitude: zone.longitude))
        if metres < 1000 { return String(format: "%.0f m", metres) }
        if metres < 100_000 { return String(format: "%.1f km", metres / 1000) }
        return String(format: "%.0f km", metres / 1000)
    }

    private func select(_ zone: InsiderZone) {
        selectedZone = zone
        entered = false
        exited = false
        metresFromCentre = nil
        activeSheet = nil
        showStatus("\(zone.identifier) ready — \(Int(zone.startDistance)) m out, in and back.",
                   isError: false)
    }

    // MARK: - Networking

    /// Zones are searched around wherever the device currently is.
    private func fetchZones() {
        // The API returns every zone whatever we send; user_location only sets
        // the order. A missing fix is therefore not a reason to refuse the
        // list — it only means the order is not meaningful, so say that
        // instead of blocking. A device with no location set at all (a
        // simulator that has never been given one, or had it cleared) never
        // calls didUpdateLocations, so this is a normal state to land in.
        let here = tracker.current ?? tracker.original ?? selectedZone?.coordinate
        let sortedByDistance = here != nil
        let search = here ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        guard let url = URL(string: insiderZonesURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "partner_name": insiderPartner,
            "user_location": ["latitude": String(search.latitude),
                              "longitude": String(search.longitude)],
        ])

        isLoadingZones = true
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                isLoadingZones = false
                if let error = error {
                    showStatus("Could not load geofences: \(error.localizedDescription)",
                               isError: true)
                    return
                }
                guard let data = data,
                      let decoded = try? JSONDecoder().decode(ZoneListResponse.self,
                                                              from: data) else {
                    showStatus("Unexpected response from the geofence API.", isError: true)
                    return
                }
                zones = decoded.geofences
                if zones.isEmpty {
                    showStatus("No geofences configured for \(insiderPartner).", isError: false)
                } else {
                    if !sortedByDistance {
                        showStatus("No location fix yet, so the list is not sorted by distance. "
                                   + "Give the device a location to sort by proximity.",
                                   isError: false)
                    }
                    activeSheet = .zones
                }
            }
        }.resume()
    }

    private func startTest(running: Bool) {
        guard let zone = selectedZone else { return }
        runMode = running
        entered = false
        exited = false
        let start = zone.startCoordinate

        send(path: "update", body: [
            "start_lat": start.latitude, "start_lon": start.longitude,
            "end_lat": zone.latitude, "end_lon": zone.longitude,
            "radius": zone.radius,
            "speed": running ? runSpeedMps : walkSpeedMps,
            "return_to_start": true,
        ]) { json in
            isRunning = true
            isPaused = false
            let seconds = json["duration_s"] as? Int ?? 0
            showStatus("\(running ? "Running" : "Walking") the round trip, ~\(seconds)s.",
                       isError: false)
            pollStatus()
        }
    }

    private func goToOriginalLocation() {
        guard let original = tracker.original else { return }
        isRunning = false
        send(path: "update", body: [
            "start_lat": original.latitude, "start_lon": original.longitude,
            "end_lat": original.latitude, "end_lon": original.longitude,
            "radius": selectedZone?.radius ?? 100,
            "speed": walkSpeedMps, "return_to_start": false,
        ]) { _ in
            entered = false
            exited = false
            metresFromCentre = nil
            showStatus(String(format: "Back at original location (%.5f, %.5f).",
                              original.latitude, original.longitude), isError: false)
        }
    }

    /// iOS caps monitored regions at 20 per app and keeps them across
    /// launches. When a partner SDK re-registers without releasing the old
    /// ones, newly added geofences are refused forever. We cannot clear
    /// another app's regions from outside it, so the helper reinstalls the app
    /// from its own installed binary — no source access needed.
    private func resetPartnerApp() {
        let bundle = partnerBundleID.trimmingCharacters(in: .whitespaces)
        guard !bundle.isEmpty else {
            showStatus("Enter the partner app's bundle id first.", isError: true)
            return
        }
        send(path: "reset-app", body: ["bundle_id": bundle]) { json in
            let detail = json["detail"] as? String ?? "done"
            showStatus("\(bundle) reset — \(detail). Its geofences re-register "
                       + "on this launch.", isError: false)
        }
    }

    private func togglePause() {
        send(path: isPaused ? "resume" : "pause", body: nil) { json in
            withAnimation { isPaused = json["paused"] as? Bool ?? false }
            if isPaused {
                showStatus("Paused — tap ▶ to continue.", isError: false)
            } else {
                statusMessage = ""
                pollStatus()
            }
        }
    }

    /// One place that talks to the helper, so auth and errors behave the same
    /// for every action.
    private func send(path: String, body: [String: Any]?,
                      onSuccess: @escaping ([String: Any]) -> Void) {
        let host = helperHost.trimmingCharacters(in: .whitespaces)
        // An empty host still forms a URL ("http://:8766/…"), which fails later
        // as a connection error and reads as "the helper is down" when really
        // nothing was ever configured. Catch it here and open Settings.
        guard !host.isEmpty else {
            showStatus("No Mac helper address set — enter your Mac's IP in Settings.",
                       isError: true)
            activeSheet = .settings
            return
        }
        guard let url = URL(string: "http://\(host):8766/\(path)") else {
            showStatus("\(host) is not a valid address.", isError: true)
            activeSheet = .settings
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(helperToken, forHTTPHeaderField: "X-Geofence-Token")
        request.timeoutInterval = 15
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        isSending = true
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isSending = false
                if let error = error {
                    showStatus("Cannot reach the helper on \(host):8766 — is "
                               + "geofence_panel.py running? (\(error.localizedDescription))",
                               isError: true)
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    showStatus("Unexpected response from the helper.", isError: true)
                    return
                }
                if json["ok"] as? Bool == true {
                    authFailed = false
                    onSuccess(json)
                } else {
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        authFailed = true
                        activeSheet = .settings   // the token needs fixing
                    }
                    showStatus(json["error"] as? String ?? "The helper reported an error.",
                               isError: true)
                }
            }
        }.resume()
    }

    private func pollStatus() {
        let host = helperHost.trimmingCharacters(in: .whitespaces)
        guard isRunning, let url = URL(string: "http://\(host):8766/status") else { return }
        var request = URLRequest(url: url)
        request.setValue(helperToken, forHTTPHeaderField: "X-Geofence-Token")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                guard isRunning else { return }
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                   json["ok"] as? Bool == true {
                    entered = json["entered"] as? Bool ?? false
                    exited = json["exited"] as? Bool ?? false
                    leg = json["leg"] as? String ?? "out"
                    isPaused = json["paused"] as? Bool ?? false
                    metresFromCentre = json["remaining_m"] as? Double

                    if json["walking"] as? Bool == false {
                        isRunning = false
                        showStatus(entered
                                   ? (exited ? "Done — entered and exited the zone."
                                             : "Entered the zone, but no exit was recorded.")
                                   : "Finished without entering the zone.",
                                   isError: !entered)
                        return
                    }
                    if !isPaused { statusMessage = "" }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pollStatus() }
            }
        }.resume()
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
