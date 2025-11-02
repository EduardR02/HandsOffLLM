//
//  Theme.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 05.05.25.
//

import SwiftUI

enum Theme {
  // Rose Pine colors (background adjusted to be slightly less blue than official Rose Pine)
  private static let rosePineBackground = Color(hex: "17141D")     // Main background in darker mode
  private static let rosePineSurface = Color(hex: "1f1d2e")        // Hamburger menu background in darker mode
  private static let rosePineHighlightLow = Color(hex: "21202e")   // Menu items/buttons in darker mode
  private static let rosePineTeal = Color(hex: "9ccfd8")           // Secondary accent in darker mode
  private static let snow = Color(hex: "fffafa")                   // Text color for all themes

  // Original theme colors
  private static let originalBackground = Color(red: 29/255, green: 28/255, blue: 34/255)
  private static let originalMenuAccent = Color(red: 40/255, green: 44/255, blue: 52/255)
  private static let originalOverlayMask = Color(red: 30/255, green: 34/255, blue: 42/255)

  private static var isDarkerMode: Bool {
    UserDefaults.standard.bool(forKey: "darkerMode")
  }

  static var background: Color {
    isDarkerMode ? rosePineBackground : originalBackground
  }

  static var menuAccent: Color {
    isDarkerMode ? rosePineHighlightLow : originalMenuAccent
  }

  static var overlayMask: Color {
    isDarkerMode ? rosePineSurface : originalOverlayMask
  }

  static let primaryText = snow
  static let secondaryText = snow.opacity(0.75)

  static let accent = Color(red: 250/255, green: 170/255, blue: 170/255)

  static var secondaryAccent: Color {
    isDarkerMode ? rosePineTeal : Color(red: 100/255, green: 180/255, blue: 255/255)
  }

  static let errorText = Color(red: 255/255, green: 100/255, blue: 100/255)
  static let warningText = Color(red: 255/255, green: 179/255, blue: 0/255)
  static let successText = Color(red: 50/255, green: 205/255, blue: 50/255)
  static let borderColor = Color(white: 0.25)
}

// Helper extension for hex colors
extension Color {
  init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let r, g, b: UInt64
    switch hex.count {
    case 6: // RGB (24-bit)
      (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
    default:
      (r, g, b) = (0, 0, 0)
    }
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255
    )
  }
}
