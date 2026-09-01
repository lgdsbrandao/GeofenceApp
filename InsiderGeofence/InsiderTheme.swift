//
//  InsiderTheme.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI
import UIKit

/// Insider One's palette: a near-black ground with a warm orange-to-red fall,
/// the same range the logo runs through.
extension Color {
    static let insiderPrimary    = Color(red: 244/255, green: 72/255,  blue: 43/255)
    static let insiderOrange     = Color(red: 242/255, green: 110/255, blue: 60/255)
    static let insiderRed        = Color(red: 232/255, green: 65/255,  blue: 64/255)
    static let insiderHitPink    = Color(red: 255/255, green: 168/255, blue: 136/255)
    static let insiderFaluRed    = Color(red: 134/255, green: 24/255,  blue: 25/255)
    static let insiderBackground = Color(red: 24/255,  green: 24/255,  blue: 25/255)
}

/// MapKit renderers take UIColor, so the same values are needed twice.
extension UIColor {
    static let insiderPrimary = UIColor(red: 244/255, green: 72/255,  blue: 43/255, alpha: 1)
    static let insiderHitPink = UIColor(red: 255/255, green: 168/255, blue: 136/255, alpha: 1)
    static let insiderOrange  = UIColor(red: 242/255, green: 110/255, blue: 60/255, alpha: 1)
}

/// The logo gradient. Used on the primary action only — spending it everywhere
/// would flatten the hierarchy it exists to create.
let insiderGradient = LinearGradient(
    colors: [.insiderOrange, .insiderRed],
    startPoint: .top, endPoint: .bottom)
