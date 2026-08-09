import SwiftUI
import AVKit

// AI CONTEXT — Views/AudioRoutePickerView.swift. UIViewRepresentable wrapper
// around the system AVRoutePickerView (AirPlay/output picker), embedded in the
// Player's audio row. The SwiftUI row can be much wider than AVRoutePickerView's
// internal button, so ExpandedHitAreaRoutePickerView forwards every tap inside
// the representable's bounds to that system button. Pure UI bridge; no app state.

/// AVRoutePickerView visually expands to its SwiftUI frame, but its internal
/// UIButton can retain an icon-sized hit region. Forwarding hits from anywhere
/// inside the advertised bounds makes the whole visible player control behave
/// as one standard 44-point-or-larger tap target.
private final class ExpandedHitAreaRoutePickerView: AVRoutePickerView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled,
              !isHidden,
              alpha > 0.01,
              self.point(inside: point, with: event) else {
            return nil
        }

        return routeButton(in: self) ?? super.hitTest(point, with: event)
    }

    private func routeButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           button.isEnabled,
           !button.isHidden,
           button.alpha > 0.01 {
            return button
        }

        for subview in view.subviews {
            if let button = routeButton(in: subview) {
                return button
            }
        }
        return nil
    }
}

/// Wraps `AVRoutePickerView` so SwiftUI can embed the system AirPlay/audio-route picker.
///
/// Tapping the view presents the system picker sheet — no extra code needed.
struct AudioRoutePickerView: UIViewRepresentable {

    var tintColor: UIColor = .systemPurple

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = ExpandedHitAreaRoutePickerView()
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
