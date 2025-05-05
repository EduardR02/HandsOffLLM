//
//  RoutePickerView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 23.04.25.
//

import SwiftUI
import AVKit // Use AVKit's route picker

struct RoutePickerView: UIViewRepresentable {
    @Environment(\.colorScheme) var colorScheme

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        // Remove the default embedded button image so only the highlight remains
        if let btn = picker.subviews.compactMap({ $0 as? UIButton }).first {
            btn.isHidden = true
        }
        // Apply tint for highlight
        picker.tintColor = (colorScheme == .dark) ? .white : .black
        // You might want to set a specific activeTintColor for the selected route
        // picker.activeTintColor = .systemBlue // Example
        picker.backgroundColor = .clear // Make background transparent

        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Update tint color if the environment changes
        uiView.tintColor = (colorScheme == .dark) ? .white : .black
    }
}

#Preview {
    RoutePickerView()
        .frame(width: 44, height: 44) // Typical button size
        .padding()
        .background(Color.gray) // Add background for visibility
        .preferredColorScheme(.dark)
}

#Preview {
    RoutePickerView()
        .frame(width: 44, height: 44)
        .padding()
        .background(Color.gray)
        .preferredColorScheme(.light)
}