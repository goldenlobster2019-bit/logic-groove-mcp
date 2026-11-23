import ApplicationServices
import Foundation

/// Accessibility part of `logic_sounds set_preset`: make sure the wanted track is selected (read back)
/// and that its instrument is the expected plug-in, before a Program Change is sent.
extension AccessibilityChannel {
    /// params: `track_index` (0-based; absent or -1 = the currently selected track), `plugin` (name
    /// substring the instrument must contain, case-insensitive). `.success` only when the selection
    /// was read back and the strip's instrument matches; nothing is changed in Logic apart from the
    /// track selection.
    func prepareInstrumentForSound(params: [String: String]) async -> ChannelResult {
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let plugin = (params["plugin"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plugin.isEmpty else {
            return .error("Missing 'plugin' parameter")
        }
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: true)
        if let error = prep.error { return .error(error) }
        guard let model = AXLogicProElements.stripModel() else {
            return .error("Could not read the selected track's channel strip. Trace: \(prep.trace.joined(separator: "; "))")
        }
        guard let instrument = model.instrument else {
            return .error("The selected track has no instrument plug-in (chain: \(model.chainText)). Run logic_mixer insert_plugin with slot \"instrument\" and name \"\(plugin)\" first. Trace: \(prep.trace.joined(separator: "; "))")
        }
        guard instrument.name.lowercased().contains(plugin.lowercased()) else {
            return .error("The instrument of the selected track is '\(instrument.name)', not \(plugin). Run logic_mixer insert_plugin with slot \"instrument\" and name \"\(plugin)\" first. Trace: \(prep.trace.joined(separator: "; "))")
        }
        let index = AXLogicProElements.selectedTrackIndex().map { String($0) } ?? "?"
        return .success("track \(index) '\(model.trackName)' has instrument '\(instrument.name)'. Trace: \(prep.trace.joined(separator: "; "))")
    }

    /// params: `track_index` (0-based; absent or -1 = the currently selected track). Selects the track with
    /// read-back and returns a small JSON object { "track": Int, "track_name": String, "trace": [String] }
    /// with the live name of the track header (after a bank program loaded it reads "0/29 029 HS Stabz").
    func verifyTrackName(params: [String: String]) async -> ChannelResult {
        let trackIndex = Int(params["track_index"] ?? "-1") ?? -1
        let prep = await prepareStrip(trackIndex: trackIndex, requireTrack: true)
        if let error = prep.error { return .error(error) }
        guard let index = AXLogicProElements.selectedTrackIndex() else {
            return .error("The selected track cannot be read. Trace: \(prep.trace.joined(separator: "; "))")
        }
        let headerName = AXLogicProElements.trackHeaderName(index: index) ?? ""
        let stripName = AXLogicProElements.stripModel()?.trackName ?? ""
        let object: [String: Any] = [
            "track": index,
            "track_name": headerName.isEmpty ? stripName : headerName,
            "strip_name": stripName,
            "trace": prep.trace,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return .error("Failed to encode the result")
        }
        return .success(text)
    }
}
