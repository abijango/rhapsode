import AVKit
import SwiftUI

/// The system AirPlay control (`AVRoutePickerView`) as the player dock's center button. Tapping it
/// opens iOS's own route picker — HomePods, AirPlay speakers, Bluetooth — so we never reimplement
/// routing. Works on iOS and Mac Catalyst.
struct AudioRoutePickerButton: UIViewRepresentable {
    var tint: UIColor
    var activeTint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = activeTint
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = activeTint
    }
}
