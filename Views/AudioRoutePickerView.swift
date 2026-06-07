import SwiftUI
import AVKit

/// Wraps `AVRoutePickerView` so SwiftUI can embed the system AirPlay/audio-route picker.
///
/// Tapping the view presents the system picker sheet — no extra code needed.
struct AudioRoutePickerView: UIViewRepresentable {

    var tintColor: UIColor = .systemPurple

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        view.activeTintColor = tintColor
        // Remove the background so it blends with the player row.
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = tintColor
    }
}
