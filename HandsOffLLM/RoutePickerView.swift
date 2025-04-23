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
        // Set tint color based on environment (optional, default is usually fine)
        picker.tintColor = (colorScheme == .dark) ? .white : .black
        // You might want to set a specific activeTintColor for the selected route
        // picker.activeTintColor = .systemBlue // Example
        picker.backgroundColor = .clear // Make background transparent

        // Set delegate if you need to know when the picker is presented/dismissed
        // picker.delegate = context.coordinator

        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Update tint color if the environment changes
        uiView.tintColor = (colorScheme == .dark) ? .white : .black
    }

    // Optional: Add a Coordinator if you need delegate methods
    /*
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var parent: RoutePickerView

        init(_ parent: RoutePickerView) {
            self.parent = parent
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            // Handle event before picker appears
            print("Route picker will present")
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            // Handle event after picker dismisses
            print("Route picker did dismiss")
        }
    }
    */
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