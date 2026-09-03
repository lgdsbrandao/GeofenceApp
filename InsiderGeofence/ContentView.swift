//
//  ContentView.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI
import MapKit
import CoreLocation
import Security

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

    /// A geofence cannot sensibly be larger than the planet. Capping the radius
    /// also keeps `startDistance` — and therefore `Int(startDistance)` — far
    /// inside Int's range, so the conversion can never trap.
    static let maxRadiusMeters = 40_075_000.0   // Earth's equatorial circumference

    /// Whether this zone decoded to usable geometry.
    ///
    /// `latitude`, `longitude` and `radius` come verbatim from the remote API
    /// with no bounds checking at decode, yet they flow into arithmetic such as
    /// `Int(startDistance)` that traps (fatal, uncatchable) on a non-finite or
    /// out-of-range value. A remote value must not be able to crash the app, so
    /// a zone that fails this check is dropped before it can reach any sink or
    /// linger in the selectable list.
    var isValid: Bool {
        latitude.isFinite && (-90.0...90.0).contains(latitude)
            && longitude.isFinite && (-180.0...180.0).contains(longitude)
            && radius.isFinite && radius > 0 && radius <= Self.maxRadiusMeters
    }

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

private let defaultPartner = "oxttest"
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
    var style: UIBlurEffect.Style = .systemThickMaterial

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
                    BlurView()
                    Color.insiderPanelTint
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

/// A tiny wrapper over the Keychain for a single string secret.
///
/// The helper bearer token is a credential, so it is kept in the Keychain
/// rather than the app's cleartext UserDefaults plist. Items are stored
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: readable only while the
/// device is unlocked and never carried off the device in a backup or to a
/// new device.
private enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "InsiderGeofence"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func write(_ value: String, for key: String) {
        // An empty value means "no token set" — remove the item rather than
        // storing a blank secret, mirroring how a cleared field used to leave
        // an empty string in UserDefaults.
        guard !value.isEmpty else {
            SecItemDelete(baseQuery(key) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary,
                                   attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(key)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// One-time move of a secret an earlier build wrote to cleartext
    /// UserDefaults: copy it into the Keychain and delete the plaintext copy so
    /// it no longer sits at rest in the app container.
    static func migrateFromDefaults(_ key: String) -> String? {
        guard let legacy = UserDefaults.standard.string(forKey: key),
              !legacy.isEmpty else { return nil }
        write(legacy, for: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }
}

/// Keychain-backed drop-in for `@AppStorage` for a single secret string.
///
/// Exposes the same surface the settings field relies on — a plain `String`
/// wrapped value and a `Binding<String>` projected value — and, being a
/// `DynamicProperty` backed by `@State`, refreshes the view on change just as
/// `@AppStorage` does. The value lives only in the Keychain, never in
/// UserDefaults.
@propertyWrapper
private struct KeychainStorage: DynamicProperty {
    private let key: String
    @State private var value: String

    init(wrappedValue defaultValue: String, _ key: String) {
        self.key = key
        let stored = KeychainStore.read(key)
            ?? KeychainStore.migrateFromDefaults(key)
        _value = State(initialValue: stored ?? defaultValue)
    }

    var wrappedValue: String {
        get { value }
        nonmutating set {
            value = newValue
            KeychainStore.write(newValue, for: key)
        }
    }

    var projectedValue: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

struct ContentView: View {
    @StateObject private var tracker = LocationTracker()

    #if targetEnvironment(simulator)
    @AppStorage("helperHost") private var helperHost: String = "localhost"
    #else
    @AppStorage("helperHost") private var helperHost: String = ""
    #endif
    // The helper bearer token is a credential, so it lives in the Keychain
    // rather than the cleartext UserDefaults plist that backs @AppStorage.
    // Same read/write surface as before: `helperToken` and `$helperToken`.
    @KeychainStorage("helperToken") private var helperToken: String = ""
    @AppStorage("partnerBundleID") private var partnerBundleID: String = "com.useinsider.mobile-ios"
    /// Which Insider panel the zones are pulled from. Typed in the picker.
    @AppStorage("insiderPartner") private var partnerName: String = defaultPartner

    @State private var zones: [InsiderZone] = []
    @State private var selectedZone: InsiderZone?
    @State private var isLoadingZones = false
    /// The panel the zones on screen actually came from.
    @State private var loadedPartner = ""
    @State private var copiedCoordinates = false
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
                Text("Geofence Health Check")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(.primary)
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
                        .foregroundColor(authFailed ? .insiderPrimary : .primary.opacity(0.85))
                        .frame(width: 30, height: 30)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floating(cornerRadius: 18)
    }

    private var brandMark: some View {
        Image("InsiderMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 26, height: 26)
            .accessibilityLabel("Insider One")
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
        Button(action: { activeSheet = .zones }) {
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
                         } ?? "Zones from \(partnerName.isEmpty ? defaultPartner : partnerName)")
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
                                      tint: authFailed ? .insiderPrimary : .primary)
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
            .background(Color.insiderGround.ignoresSafeArea())
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
            .background(Color.insiderCard)
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
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.5)
    }

    private func settingsField(_ title: String, icon: String,
                               binding: Binding<String>, placeholder: String,
                               keyboard: UIKeyboardType,
                               tint: Color = .primary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(tint == Color.primary ? .insiderPrimary : tint)
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
                    panelField
                    myLocationCard

                    if isLoadingZones {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else if zones.isEmpty {
                        Text("No zones came back for that panel. Check the name and load again.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        Text("\(zones.count) zones · nearest first, from where the device is now")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)

                        ForEach(zones) { zone in
                            zoneListRow(zone)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onAppear {
                // Load on open, and reload if the panel was changed since.
                if zones.isEmpty || loadedPartner != partnerName.trimmingCharacters(in: .whitespaces) {
                    fetchZones()
                }
            }
            .background(Color.insiderGround.ignoresSafeArea())
            .navigationBarTitle(Text("Geofences"), displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { activeSheet = nil })
        }
    }

    /// The Insider panel the zones come from. Editable here so a different
    /// partner can be inspected without rebuilding.
    private var panelField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PANEL")
                .font(.caption2.bold())
                .tracking(1.1)
                .foregroundColor(.insiderPrimary)
                .padding(.leading, 4)

            HStack(spacing: 10) {
                Image(systemName: "building.2")
                    .font(.system(size: 14))
                    .foregroundColor(.insiderPrimary)
                    .frame(width: 20)

                TextField(defaultPartner, text: $partnerName, onCommit: fetchZones)
                    .font(.subheadline)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundColor(.primary)

                Button(action: fetchZones) {
                    Text("Load")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(insiderGradient)
                        .clipShape(Capsule())
                }
                .disabled(isLoadingZones
                          || partnerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(Color.insiderCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.insiderPrimary.opacity(0.14), lineWidth: 0.5)
            )
        }
        .padding(.bottom, 4)
    }

    /// The device-only route: rather than moving the phone to a zone, put a
    /// zone where the phone already is. iOS has no way for an app to spoof
    /// location for other apps, so on real hardware this is the only test that
    /// needs no Mac attached — create a zone at these coordinates in the
    /// panel, then walk across its edge for real.
    @ViewBuilder
    private var myLocationCard: some View {
        if let here = tracker.current ?? tracker.original {
            let text = String(format: "%.6f, %.6f", here.latitude, here.longitude)
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR LOCATION")
                    .font(.caption2.bold())
                    .tracking(1.1)
                    .foregroundColor(.insiderPrimary)
                    .padding(.leading, 4)

                HStack(spacing: 10) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.insiderPrimary)
                        .frame(width: 20)
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    Button(action: {
                        UIPasteboard.general.string = text
                        withAnimation { copiedCoordinates = true }
                    }) {
                        Text(copiedCoordinates ? "Copied" : "Copy")
                            .font(.caption.bold())
                            .foregroundColor(copiedCoordinates ? .insiderHitPink : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(copiedCoordinates
                                        ? AnyView(Color.insiderFaluRed)
                                        : AnyView(insiderGradient))
                            .clipShape(Capsule())
                    }
                }
                .padding(12)
                .background(Color.insiderCard)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.insiderPrimary.opacity(0.14), lineWidth: 0.5)
                )

                Text("Create a zone here in the panel and walk across its edge — "
                     + "the only test that needs no Mac attached.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.bottom, 6)
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
                        .foregroundColor(.primary)
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
            .background(isSelected ? Color.insiderCardSelected : Color.insiderCard)
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
        let partner = partnerName.trimmingCharacters(in: .whitespaces)
        guard !partner.isEmpty else {
            showStatus("Enter a panel name to load its geofences.", isError: true)
            return
        }
        guard let url = URL(string: insiderZonesURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "partner_name": partner,
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
                // Drop any zone whose coordinates or radius are non-finite or
                // out of range before it enters the list: such values are
                // decoded verbatim from the API and would otherwise trap when
                // force-converted (e.g. `Int(zone.startDistance)`) on selection.
                zones = decoded.geofences.filter { $0.isValid }
                loadedPartner = partner
                if zones.isEmpty {
                    showStatus("No geofences configured for \(partner).", isError: false)
                } else if !sortedByDistance {
                    showStatus("No location fix yet, so the list is not sorted by distance. "
                               + "Give the device a location to sort by proximity.",
                               isError: false)
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

    /// Whether `host` names a loopback destination (localhost / 127.0.0.0/8 /
    /// ::1). The helper speaks only plain HTTP and authenticates with a static
    /// token it compares verbatim, so that credential cannot be transmitted
    /// safely to any non-loopback address: an on-path attacker on the LAN would
    /// read the X-Geofence-Token straight off the cleartext request and could
    /// then drive privileged helper actions (reset-app, update). On loopback
    /// the request never leaves the machine, so there is nothing on the wire to
    /// capture. We therefore only ever attach the credential to loopback hosts.
    private func isLoopbackHelperHost(_ host: String) -> Bool {
        var bare = host.trimmingCharacters(in: .whitespaces).lowercased()
        if bare.hasPrefix("[") && bare.hasSuffix("]") {
            bare = String(bare.dropFirst().dropLast())   // strip IPv6 brackets
        }
        if bare == "localhost" || bare == "::1" { return true }
        // 127.0.0.0/8 is reserved entirely for loopback.
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && String(octets[0]) == "127"
            && octets.allSatisfy { UInt8($0) != nil }
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
        // The helper token is a static shared secret sent in the clear over
        // HTTP. Only a loopback destination keeps it off the wire, so refuse to
        // send it — and thus the whole privileged request — to any other
        // address rather than leak a replayable credential to an on-path
        // attacker. The helper itself only binds loopback unless it is started
        // with an explicit --lan opt-in.
        guard isLoopbackHelperHost(host) else {
            showStatus("The Mac helper can only be reached on this device "
                       + "(localhost). A LAN address would send the helper "
                       + "token in the clear — run the app in the Simulator "
                       + "alongside geofence_panel.py.", isError: true)
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
        // Trimmed: pasting a token easily carries a trailing space or
        // newline, and the helper compares it exactly — that lands as a
        // 401 that looks like a wrong token rather than a stray character.
        request.setValue(helperToken.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "X-Geofence-Token")
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
        // Same rule as send(): never put the token on the wire to a non-loopback
        // host, where it could be sniffed and replayed against the helper.
        guard isRunning, isLoopbackHelperHost(host),
              let url = URL(string: "http://\(host):8766/status") else { return }
        var request = URLRequest(url: url)
        // Trimmed: pasting a token easily carries a trailing space or
        // newline, and the helper compares it exactly — that lands as a
        // 401 that looks like a wrong token rather than a stray character.
        request.setValue(helperToken.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "X-Geofence-Token")
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
