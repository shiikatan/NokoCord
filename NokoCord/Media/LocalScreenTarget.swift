import Foundation
import ScreenCaptureKit

/// A real ScreenCaptureKit source offered by the current discovery result.
enum LocalScreenTarget: Identifiable {
    case display(SCDisplay, number: Int)
    case window(SCWindow)

    var id: String {
        switch self {
        case .display(let display, _): "display-\(display.displayID)"
        case .window(let window): "window-\(window.windowID)"
        }
    }

    var title: String {
        switch self {
        case .display(_, let number): String(localized: "Display \(number)")
        case .window(let window): window.title ?? String(localized: "Untitled window")
        }
    }

    var symbol: String {
        switch self { case .display: "display"; case .window: "macwindow" }
    }

    var frame: CGRect {
        switch self {
        case .display(let display, _): display.frame
        case .window(let window): window.frame
        }
    }

    var filter: SCContentFilter {
        switch self {
        case .display(let display, _): SCContentFilter(display: display, excludingWindows: [])
        case .window(let window): SCContentFilter(desktopIndependentWindow: window)
        }
    }
}
