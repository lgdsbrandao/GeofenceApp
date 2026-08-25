//
//  ContentView.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI
import MapKit
import CoreLocation

final class OriginalLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var original: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard original == nil, let first = locations.first else { return }
        original = first.coordinate
        manager.stopUpdatingLocation()
    }
}

private let walkSpeedMps = 1.4
private let runSpeedMps = walkSpeedMps * 2

struct ContentView: View {
    @StateObject private var originalTracker = OriginalLocationTracker()
    @State private var startLatitude: String = "-23.639772"
    @State private var startLongitude: String = "-46.722718"
    @State private var endLatitude: String = "-23.533976"
    @State private var endLongitude: String = "-46.578507"
    @State private var zoneRadius: String = "100"
    #if targetEnvironment(simulator)
    @AppStorage("helperHost") private var helperHost: String = "localhost"
    #else
    @AppStorage("helperHost") private var helperHost: String = ""
    #endif
    @AppStorage("helperToken") private var helperToken: String = ""
    @State private var statusMessage: String = ""
    @State private var statusIsError: Bool = false
    @State private var isSending: Bool = false
    @State private var isWalking: Bool = false
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -23.533976, longitude: -46.573602),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @State private var mapTrackingMode: MapUserTrackingMode = .follow
    @State private var showSettings: Bool = false
    /// Which pace the in-flight or active route is using.
    @State private var runMode: Bool = false
    @State private var authFailed: Bool = false

    /// The token is a set-once value, so it stays hidden unless it is still
    /// missing, the helper rejected it, or you open settings to change it.
    private var showsTokenField: Bool {
        showSettings || authFailed || helperToken.isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            mapCard
            routeCard
            settingsCard
            actionButtons
            statusCard
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Sections

    private var header: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 2) {
                Text("Geofence Panel")
                    .font(.headline)
                Text("Walk 1.4 m/s or run 2.8 m/s from start to end; reports zone entry.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button(action: { withAnimation { showSettings.toggle() } }) {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
            }
        }
    }

    private var mapCard: some View {
        Map(coordinateRegion: $mapRegion,
            showsUserLocation: true,
            userTrackingMode: $mapTrackingMode)
            .frame(minHeight: 90, maxHeight: .infinity)
            .cornerRadius(16)
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "circle.circle.fill")
                    .foregroundColor(.green)
                Text("Start").font(.subheadline.bold())
            }
            coordinatePair($startLatitude, $startLongitude)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.red)
                Text("End").font(.subheadline.bold())
            }
            coordinatePair($endLatitude, $endLongitude)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var settingsCard: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                        .foregroundColor(.blue)
                    Text("Zone radius").font(.subheadline.bold())
                }
                Spacer()
                fieldBox($zoneRadius, placeholder: "100", keyboard: .numbersAndPunctuation)
                    .frame(width: 100)
                Text("m").foregroundColor(.secondary)
            }
            Divider()
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(.blue)
                    Text("Mac helper").font(.subheadline.bold())
                }
                Spacer()
                fieldBox($helperHost, placeholder: "192.168.x.x", keyboard: .URL)
                    .frame(width: 180)
            }
            if showsTokenField {
                Divider()
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundColor(authFailed ? .red : .blue)
                        Text("Token").font(.subheadline.bold())
                    }
                    Spacer()
                    fieldBox($helperToken, placeholder: "from helper startup", keyboard: .asciiCapable)
                        .frame(width: 180)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                paceButton(title: "Walk", icon: "figure.walk",
                           color: .blue, isRun: false)
                paceButton(title: "Run", icon: "figure.run",
                           color: .orange, isRun: true)
            }

            Button(action: goToOriginalLocation) {
                HStack {
                    Image(systemName: "location.circle")
                    Text(originalTracker.original == nil
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
            .disabled(isSending || originalTracker.original == nil)
        }
    }

    private func paceButton(title: String, icon: String,
                            color: Color, isRun: Bool) -> some View {
        let active = isWalking && runMode == isRun
        return Button(action: { updateGeofence(running: isRun) }) {
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
        .disabled(isSending)
    }

    @ViewBuilder
    private var statusCard: some View {
        if !statusMessage.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIsError
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.circle.fill")
                Text(statusMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundColor(statusIsError ? .red : .green)
            .padding(12)
            .background((statusIsError ? Color.red : Color.green).opacity(0.12))
            .cornerRadius(12)
        }
    }

    // MARK: - Field helpers

    private func coordinatePair(_ lat: Binding<String>, _ lon: Binding<String>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latitude").font(.caption2).foregroundColor(.secondary)
                fieldBox(lat, placeholder: "0.0", keyboard: .numbersAndPunctuation)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Longitude").font(.caption2).foregroundColor(.secondary)
                fieldBox(lon, placeholder: "0.0", keyboard: .numbersAndPunctuation)
            }
        }
    }

    private func fieldBox(_ binding: Binding<String>, placeholder: String,
                          keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: binding)
            .keyboardType(keyboard)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill))
            .cornerRadius(8)
    }

    // MARK: - Actions

    private func updateGeofence(running: Bool) {
        guard let startLat = parse(startLatitude, range: -90.0...90.0),
              let endLat = parse(endLatitude, range: -90.0...90.0) else {
            showStatus("Latitudes must be numbers between -90 and 90.", isError: true)
            return
        }
        guard let startLon = parse(startLongitude, range: -180.0...180.0),
              let endLon = parse(endLongitude, range: -180.0...180.0) else {
            showStatus("Longitudes must be numbers between -180 and 180.", isError: true)
            return
        }
        guard let radius = parse(zoneRadius, range: 0.001...1_000_000) else {
            showStatus("Radius must be a positive number of meters.", isError: true)
            return
        }
        runMode = running
        sendRoute(startLat: startLat, startLon: startLon,
                  endLat: endLat, endLon: endLon, radius: radius,
                  speed: running ? runSpeedMps : walkSpeedMps) { distance, duration in
            isWalking = true
            let verb = running ? "Run" : "Walk"
            showStatus("\(verb) started: \(distance)m, ~\(duration)s. Zone radius \(Int(radius))m.", isError: false)
            pollStatus(host: helperHost.trimmingCharacters(in: .whitespaces))
        }
    }

    private func goToOriginalLocation() {
        guard let original = originalTracker.original else { return }
        let radius = parse(zoneRadius, range: 0.001...1_000_000) ?? 100
        isWalking = false
        sendRoute(startLat: original.latitude, startLon: original.longitude,
                  endLat: original.latitude, endLon: original.longitude,
                  radius: radius, speed: walkSpeedMps) { _, _ in
            showStatus(String(format: "Back at original location (%.6f, %.6f).",
                              original.latitude, original.longitude), isError: false)
        }
    }

    private func sendRoute(startLat: Double, startLon: Double,
                           endLat: Double, endLon: Double, radius: Double,
                           speed: Double,
                           onSuccess: @escaping (Int, Int) -> Void) {
        let host = helperHost.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "http://\(host):8766/update") else {
            showStatus("Invalid helper host.", isError: true)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(helperToken, forHTTPHeaderField: "X-Geofence-Token")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "start_lat": startLat, "start_lon": startLon,
            "end_lat": endLat, "end_lon": endLon,
            "radius": radius, "speed": speed,
        ])

        isSending = true
        statusMessage = ""
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isSending = false
                if let error = error {
                    showStatus("Could not reach helper on \(host):8766 — is geofence_panel.py running? (\(error.localizedDescription))", isError: true)
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    showStatus("Unexpected response from helper.", isError: true)
                    return
                }
                if json["ok"] as? Bool == true {
                    authFailed = false
                    onSuccess(json["distance_m"] as? Int ?? 0,
                              json["duration_s"] as? Int ?? 0)
                } else {
                    noteAuthFailure(response)
                    showStatus(json["error"] as? String ?? "Helper reported an error.", isError: true)
                }
            }
        }.resume()
    }

    private func pollStatus(host: String) {
        guard isWalking, let url = URL(string: "http://\(host):8766/status") else { return }
        var request = URLRequest(url: url)
        request.setValue(helperToken, forHTTPHeaderField: "X-Geofence-Token")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                guard isWalking else { return }
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    guard json["ok"] as? Bool == true else {
                        isWalking = false
                        noteAuthFailure(response)
                        showStatus(json["error"] as? String ?? "Helper rejected the status request.",
                                   isError: true)
                        return
                    }
                    let walking = json["walking"] as? Bool ?? false
                    let entered = json["entered"] as? Bool ?? false
                    let remaining = json["remaining_m"] as? Double ?? 0
                    let device = (json["device"] as? String).map { "\niPhone: \($0)" } ?? ""
                    if walking {
                        if entered {
                            showStatus("🎯 Entered the geofence zone! Still walking — \(Int(remaining))m to destination.\(device)", isError: false)
                        } else {
                            showStatus("\(runMode ? "Running" : "Walking")… \(Int(remaining))m to destination.\(device)", isError: false)
                        }
                    } else {
                        isWalking = false
                        showStatus(entered
                                   ? "🎯 Arrived — geofence zone entered."
                                   : "Walk finished (zone never entered).", isError: false)
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    pollStatus(host: host)
                }
            }
        }.resume()
    }

    /// Reveal the token field again when the helper says the token is wrong.
    private func noteAuthFailure(_ response: URLResponse?) {
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            withAnimation { authFailed = true }
        }
    }

    private func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              range.contains(value) else { return nil }
        return value
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
