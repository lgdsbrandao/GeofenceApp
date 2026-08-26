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
        VStack(spacing: 10) {
            header
            ZoneMapView(zone: selectedZone,
                        startCoordinate: selectedZone?.startCoordinate)
                .frame(minHeight: 120, maxHeight: .infinity)
                .cornerRadius(16)
            zoneCard
            progressCard
            actionButtons
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .zones: zoneList
            case .settings: settingsSheet
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Geofence Panel")
                    .font(.headline)
                Text(selectedZone == nil
                     ? "Pick a zone to test"
                     : "Walk in and back out to fire enter + exit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { activeSheet = .settings }) {
                Image(systemName: "gearshape")
                    .foregroundColor(authFailed ? .red : .secondary)
            }
        }
    }

    // MARK: - Zone

    private var zoneCard: some View {
        Button(action: fetchZones) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 38, height: 38)
                    if isLoadingZones {
                        ProgressView()
                    } else {
                        Image(systemName: selectedZone == nil
                              ? "mappin.and.ellipse" : "scope")
                            .foregroundColor(.blue)
                    }
                }

                if let zone = selectedZone {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zone.identifier)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(String(format: "r %.0f m · start %.0f m out · in and back",
                                    zone.radius, zone.startDistance))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a geofence")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                        Text("Loads the zones configured for \(insiderPartner)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
        .disabled(isLoadingZones)
    }

    // MARK: - Progress

    private var progressCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                eventPill(title: "ENTER", done: entered, tint: .green)
                eventPill(title: "EXIT", done: exited, tint: .blue)
            }
            HStack(spacing: 6) {
                if !statusMessage.isEmpty {
                    Image(systemName: statusIsError
                          ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption2)
                    Text(statusMessage)
                        .font(.caption2)
                        .lineLimit(2)
                } else if let metres = metresFromCentre {
                    Text(String(format: "%.0f m from centre · heading %@",
                                metres, leg == "back" ? "out" : "in"))
                        .font(.caption2)
                } else {
                    Text("Idle").font(.caption2)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(statusIsError ? .red : .secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
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
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background((done ? tint : Color.secondary).opacity(done ? 0.15 : 0.08))
        .cornerRadius(10)
    }

    // MARK: - Settings

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Connection"),
                        footer: Text("The token is printed by geofence_panel.py "
                                     + "when it starts.")) {
                    labelledField("Mac helper", systemImage: "desktopcomputer",
                                  binding: $helperHost,
                                  placeholder: "192.168.x.x", keyboard: .URL)
                    labelledField("Token", systemImage: "key.fill",
                                  binding: $helperToken,
                                  placeholder: "from helper startup",
                                  keyboard: .asciiCapable,
                                  tint: authFailed ? .red : .primary)
                }

                Section(header: Text("Partner app"),
                        footer: Text("iOS monitors at most 20 regions per app and "
                                     + "keeps them across launches, so a zone added "
                                     + "later is refused until the app is "
                                     + "reinstalled. This reinstalls it from its own "
                                     + "binary — no source needed — and clears its "
                                     + "local data.")) {
                    labelledField("Bundle id", systemImage: "app.badge",
                                  binding: $partnerBundleID,
                                  placeholder: "com.example.app", keyboard: .URL)
                    Button(action: resetPartnerApp) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Reset its geofence registrations")
                        }
                        .foregroundColor(.orange)
                    }
                    .disabled(isSending)
                }
            }
            .navigationBarTitle(Text("Settings"), displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { activeSheet = nil })
        }
    }

    private func labelledField(_ title: String, systemImage: String,
                               binding: Binding<String>, placeholder: String,
                               keyboard: UIKeyboardType,
                               tint: Color = .primary) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundColor(tint)
            Spacer()
            TextField(placeholder, text: binding)
                .keyboardType(keyboard)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                paceButton(title: "Walk", icon: "figure.walk", color: .blue, isRun: false)
                paceButton(title: "Run", icon: "figure.run", color: .orange, isRun: true)
                if isRunning {
                    Button(action: togglePause) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 44)
                            .padding(.vertical, 12)
                    }
                    .background(isPaused ? Color.green : Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                    .disabled(isSending)
                }
            }
            Button(action: goToOriginalLocation) {
                HStack {
                    Image(systemName: "location.circle")
                    Text(tracker.original == nil
                         ? "Go to original location (waiting for GPS…)"
                         : "Go to original location")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(Color.green.opacity(0.15))
            .foregroundColor(.green)
            .cornerRadius(14)
            .disabled(isSending || tracker.original == nil)
        }
    }

    private func paceButton(title: String, icon: String,
                            color: Color, isRun: Bool) -> some View {
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
        .background(color)
        .foregroundColor(.white)
        .cornerRadius(14)
        .disabled(isSending || selectedZone == nil)
    }

    // MARK: - Zone list

    private var zoneList: some View {
        NavigationView {
            List(zones) { zone in
                Button(action: { select(zone) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(zone.identifier)
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            Text(String(format: "%.5f, %.5f  ·  r %.0f m",
                                        zone.latitude, zone.longitude, zone.radius))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: selectedZone?.id == zone.id
                              ? "checkmark.circle.fill" : "arrow.right.circle")
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationBarTitle(Text("\(zones.count) geofences"), displayMode: .inline)
        }
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
        // Search from where the device is now. Falling back to 0,0 silently
        // returns zones near the Gulf of Guinea, which looks like the API
        // ignoring proximity rather than a missing fix.
        guard let here = tracker.current ?? tracker.original ?? selectedZone?.coordinate else {
            showStatus("Waiting for a location fix — the zone list is ordered by distance from you.",
                       isError: true)
            return
        }
        guard let url = URL(string: insiderZonesURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "partner_name": insiderPartner,
            "user_location": ["latitude": String(here.latitude),
                              "longitude": String(here.longitude)],
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
