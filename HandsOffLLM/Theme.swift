//
//  Theme.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 05.05.25.
//

import SwiftUI

enum Theme {
  // Rose Pine colors
  static let background = Color(hex: "17141D")
  static let overlayMask = Color(hex: "1f1d2e")
  static let menuAccent = Color(hex: "21202e")
  static let secondaryAccent = Color(hex: "9ccfd8")

  static let primaryText = Color(hex: "fffafa")
  static let secondaryText = primaryText.opacity(0.75)

  static let accent = Color(red: 250/255, green: 170/255, blue: 170/255)

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
