//
//  InsiderGeofenceApp.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI
import UIKit
import CoreLocation

// Location is requested by OriginalLocationTracker in ContentView, which asks
// for when-in-use access and stops as soon as it has one fix. The fake
// location itself is injected by the Mac helper (simctl / pymobiledevice3),
// so the app never needs Always authorization or background updates.
class InsiderGeofenceAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
}

@main
struct InsiderGeofenceApp: App {
    @UIApplicationDelegateAdaptor(InsiderGeofenceAppDelegate.self) var delegate

    /// True only for the life of the cold-start sequence. The App struct is
    /// created once per process, so this runs on launch and not on every
    /// return from the background.
    @State private var showingSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if showingSplash {
                    SplashView { showingSplash = false }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
    }
}
