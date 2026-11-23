import ApplicationServices
import Foundation

/// Transport play / stop through the control bar controls (verified live: AXPress on the "Play" checkbox
/// and on the "Stop" button works while Logic is in the background; MMC is ignored by Logic here).
/// Straight-line async code; no AX element is held across an `await`.
extension AccessibilityChannel {
    func playTransportAX() async -> ChannelResult {
        guard let control = AXLogicProElements.transportPlayControl() else {
            return .error("Cannot find the Play control in the control bar")
        }
        guard let before = AXLogicProElements.toggleState(control) else {
            return .error("The Play state cannot be read (AXValue), so nothing was pressed")
        }
        if before {
            return .success("already playing")
        }
        guard AXHelpers.performAction(control, kAXPressAction) else {
            return .error("AXPress on the Play control failed")
        }
        var waited = 0
        while waited < 600 {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            if AXLogicProElements.transportIsPlaying() == true {
                return .success("playing (AXPress on Play, confirmed after \(waited) ms)")
            }
        }
        return .error("Pressed Play but Logic does not report playback after 600 ms")
    }

    func stopTransportAX() async -> ChannelResult {
        guard let state = AXLogicProElements.transportIsPlaying() else {
            return .error("The Play state cannot be read, so nothing was pressed")
        }
        if !state {
            return .success("already stopped")
        }
        guard let button = AXLogicProElements.transportStopButton() else {
            return .error("Cannot find the Stop button in the control bar")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("AXPress on the Stop button failed")
        }
        var waited = 0
        while waited < 600 {
            guard await FilePanelAutomation.pause(ms: 100) else { return .error("Cancelled") }
            waited += 100
            if AXLogicProElements.transportIsPlaying() == false {
                return .success("stopped (AXPress on Stop, confirmed after \(waited) ms)")
            }
        }
        return .error("Pressed Stop but Logic still reports playback after 600 ms")
    }
}
