import Foundation

// Logic Pro drops the leading empty bars of an imported MIDI file: the region starts at the
// bar of the first note and that bar lands at the playhead. These helpers let the server
// compensate (shift the clip so its first note is in bar 1 and place it at the right bar).

public extension Clip {
    /// Number of whole empty bars before the first NOTE (4/4). 0 when there are no notes.
    var leadingEmptyBars: Int {
        guard let first = notes.map({ $0.start }).min() else { return 0 }
        return max(0, first) / MusicCore.ticksPerBar()
    }

    /// Returns the clip shifted left by `leadingEmptyBars` bars so its first note lies in bar 1,
    /// plus that bar count. Controller state before the shift is preserved at the new tick 0.
    func trimmingLeadingEmptyBars() -> (clip: Clip, leadingBars: Int) {
        let bars = leadingEmptyBars
        guard bars > 0 else { return (self, 0) }
        let shift = bars * MusicCore.ticksPerBar()

        var newNotes = notes
        for i in newNotes.indices { newNotes[i].start -= shift }

        let sorted = controls.enumerated().sorted {
            ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset)
        }.map { $0.element }

        struct Key: Hashable { var controller: Int; var channel: Int }
        var lastBefore: [Key: ControlEvent] = [:]
        var atBoundary = Set<Key>()
        var kept: [ControlEvent] = []
        for event in sorted {
            let key = Key(controller: event.controller, channel: event.channel)
            if event.tick >= shift {
                if event.tick == shift { atBoundary.insert(key) }
                var moved = event
                moved.tick -= shift
                kept.append(moved)
            } else {
                lastBefore[key] = event
            }
        }
        var carried: [ControlEvent] = []
        for (key, event) in lastBefore where !atBoundary.contains(key) {
            var moved = event
            moved.tick = 0
            carried.append(moved)
        }
        carried.sort { ($0.channel, $0.controller) < ($1.channel, $1.controller) }
        let newControls = carried + kept  // carried ones sit at tick 0, kept are already >= 0 and sorted

        let newLength = max(MusicCore.ticksPerBar(), lengthTicks - shift)
        var result = Clip(name: name, notes: newNotes, lengthTicks: newLength, program: program, controls: newControls)
        result.controls = newControls.enumerated().sorted {
            ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset)
        }.map { $0.element }
        return (result, bars)
    }
}

public extension MIDIFileContents {
    /// Minimum `leadingEmptyBars` over all clips that have notes; 0 when no clip has notes.
    var leadingEmptyBars: Int {
        clips.filter { !$0.notes.isEmpty }.map { $0.leadingEmptyBars }.min() ?? 0
    }
}
