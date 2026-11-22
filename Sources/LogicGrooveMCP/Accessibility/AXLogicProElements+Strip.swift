import ApplicationServices
import CoreGraphics
import Foundation

/// Which "list" / empty-slot button to press in the selected track's channel strip.
enum PluginSlotKind: Sendable, Equatable {
    case instrument
    /// n-th existing effect (1-based, top to bottom): its menu REPLACES that effect.
    case effect(Int)
    /// The empty "audio plug-in" slot under the last effect: ADDS an effect.
    case newEffect
}

/// State of a plug-in's bypass checkbox before and after a press. Sendable only.
struct BypassOutcome: Sendable {
    let found: Bool
    let name: String
    /// nil when the checkbox value could not be read.
    let before: Bool?
    let pressed: Bool
    let note: String
}

/// Fader facts of the selected track (or of Stereo Out). Sendable only.
struct FaderInfo: Sendable {
    let min: Double
    let max: Double
    let raw: Double
    let levelText: String?
    let settable: Bool
}

/// Structural reader of the Inspector channel strip: the selected track's layout item and the
/// Stereo Out item. Everything is found again by structure (roles and AX descriptions), never by
/// position among all buttons. All synchronous; AX elements never leave these functions.
extension AXLogicProElements {
    // MARK: - Internal structure

    private struct PluginGroup {
        let element: AXUIElement
        let name: String
        let y: CGFloat
        let bypassBox: AXUIElement?
        let listButton: AXUIElement?
    }

    private struct StripLayout {
        let all: [AXUIElement]
        let instrument: PluginGroup?
        let effects: [PluginGroup]
        let hasMidiPluginButton: Bool
        let emptyInstrumentButton: AXUIElement?
        let emptyEffectButton: AXUIElement?
    }

    private static func lowerDescription(_ element: AXUIElement) -> String {
        (AXHelpers.getDescription(element) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The selected track's item and the Stereo Out item of the strip (direct AXLayoutItem children).
    private static func stripItems() -> (selected: AXUIElement?, master: AXUIElement?) {
        guard let strip = inspectorChannelStrip() else { return (nil, nil) }
        var items = AXHelpers.getChildren(strip).filter { AXHelpers.getRole($0) == "AXLayoutItem" }
        if items.isEmpty {
            items = AXHelpers.findAllDescendants(of: strip, role: "AXLayoutItem", maxDepth: 3)
        }
        var selected: AXUIElement?
        var master: AXUIElement?
        for item in items {
            if lowerDescription(item) == "stereo out" {
                if master == nil { master = item }
            } else if selected == nil {
                selected = item
            }
        }
        return (selected, master)
    }

    private static func firstElement(in all: [AXUIElement], role: String?, description: String) -> AXUIElement? {
        for element in all {
            if let role, AXHelpers.getRole(element) != role { continue }
            if lowerDescription(element) == description { return element }
        }
        return nil
    }

    private static func layout(of item: AXUIElement) -> StripLayout {
        let all = AXHelpers.findAllDescendants(of: item, role: nil, maxDepth: 8)
        var groups: [PluginGroup] = []
        for element in all where AXHelpers.getRole(element) == kAXGroupRole {
            let children = AXHelpers.getChildren(element)
            let box = children.first { child in
                let role = AXHelpers.getRole(child)
                return (role == kAXCheckBoxRole || role == kAXButtonRole) && lowerDescription(child) == "bypass"
            }
            guard let box else { continue }
            let list = children.first { AXHelpers.getRole($0) == kAXButtonRole && lowerDescription($0) == "list" }
            let name = (AXHelpers.getDescription(element) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let y = frame(of: element)?.minY ?? frame(of: box)?.minY ?? 0
            groups.append(PluginGroup(element: element, name: name, y: y, bypassBox: box, listButton: list))
        }
        groups.sort { $0.y < $1.y }
        let midi = firstElement(in: all, role: kAXButtonRole, description: "midi plug-in")
        let emptyInstrument = firstElement(in: all, role: kAXButtonRole, description: "instrument plug-in")
        let emptyEffect = firstElement(in: all, role: kAXButtonRole, description: "audio plug-in")
        var instrument: PluginGroup?
        var effects = groups
        if midi != nil, emptyInstrument == nil, let first = groups.first {
            instrument = first
            effects = Array(groups.dropFirst())
        }
        return StripLayout(
            all: all, instrument: instrument, effects: effects, hasMidiPluginButton: midi != nil,
            emptyInstrumentButton: emptyInstrument, emptyEffectButton: emptyEffect)
    }

    private static func plugin(from group: PluginGroup) -> StripPlugin {
        let state = group.bypassBox.flatMap { checkboxState($0) } ?? 0
        return StripPlugin(name: group.name, bypassed: state == 1, y: Double(group.y))
    }

    private static func number(_ element: AXUIElement?) -> Double? {
        guard let element, let value = AXHelpers.getValue(element) else { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    /// "volume fader level, 0,0 dB" -> "0,0 dB" (title first, then the value as a fallback).
    private static func levelText(in all: [AXUIElement]) -> String? {
        guard let field = firstElement(in: all, role: nil, description: "volume fader level") else { return nil }
        if let title = AXHelpers.getTitle(field), let text = ComposeSupport.textAfterFirstComma(title) {
            return text
        }
        if let value = stringValue(of: field), !value.isEmpty { return value }
        return nil
    }

    private struct PeakReading {
        let text: String?
        let value: String?
        let clipping: Bool
    }

    private static func peak(in all: [AXUIElement]) -> PeakReading {
        guard let meter = firstElement(in: all, role: nil, description: "peak level meter") else {
            return PeakReading(text: nil, value: nil, clipping: false)
        }
        let text = AXHelpers.getTitle(meter).flatMap { ComposeSupport.textAfterFirstComma($0) }
        let value = stringValue(of: meter)
        let lower = (value ?? "").lowercased()
        let clipping = lower.contains("mixed") || (!lower.isEmpty && !lower.contains("off"))
        return PeakReading(text: text, value: value, clipping: clipping)
    }

    // MARK: - Model

    /// Snapshot of the selected track's strip and Stereo Out. nil when the Inspector strip or the
    /// selected track's item cannot be found.
    static func stripModel() -> StripModel? {
        let items = stripItems()
        guard let selected = items.selected else { return nil }
        let strip = layout(of: selected)
        let all = strip.all
        let nameField = firstElement(in: all, role: kAXTextFieldRole, description: "name")
        let trackName = nameField.flatMap { stringValue(of: $0) } ?? AXHelpers.getDescription(selected) ?? ""
        let reading = peak(in: all)
        var master: StripMaster?
        if let masterItem = items.master {
            let masterAll = AXHelpers.findAllDescendants(of: masterItem, role: nil, maxDepth: 8)
            let masterPeak = peak(in: masterAll)
            master = StripMaster(
                volumeText: levelText(in: masterAll), peakText: masterPeak.text,
                peakValue: masterPeak.value, clipping: masterPeak.clipping)
        }
        return StripModel(
            trackName: trackName,
            volumeRaw: number(firstElement(in: all, role: kAXSliderRole, description: "volume fader")),
            volumeText: levelText(in: all),
            peakText: reading.text,
            peakValue: reading.value,
            clipping: reading.clipping,
            pan: number(firstElement(in: all, role: kAXSliderRole, description: "pan")),
            instrument: strip.instrument.map { plugin(from: $0) },
            effects: strip.effects.map { plugin(from: $0) },
            hasMidiPluginButton: strip.hasMidiPluginButton,
            hasEmptyInstrumentSlot: strip.emptyInstrumentButton != nil,
            hasEmptyEffectSlot: strip.emptyEffectButton != nil,
            master: master)
    }

    // MARK: - Pressing slots

    /// Press the plug-in menu button of a slot found by structure. The press call may block while the
    /// pop-up menu is tracking and then report an error after the messaging timeout with the menu
    /// open (observed: -25204), so a short timeout is set and the code is only recorded.
    static func pressPluginList(slotKind: PluginSlotKind) -> SlotPressOutcome {
        let items = stripItems()
        guard let selected = items.selected else {
            return SlotPressOutcome(found: false, candidateCount: 0, chosen: "none", method: "none", resultCode: 0,
                                    actions: "", diagnostic: "no selected-track item in the Inspector strip")
        }
        let strip = layout(of: selected)
        let groupCount = strip.effects.count + (strip.instrument == nil ? 0 : 1)
        var target: AXUIElement?
        switch slotKind {
        case .instrument:
            target = strip.instrument?.listButton ?? strip.emptyInstrumentButton
        case .effect(let n):
            if n >= 1, strip.effects.indices.contains(n - 1) { target = strip.effects[n - 1].listButton }
        case .newEffect:
            target = strip.emptyEffectButton
        }
        guard let element = target else {
            return SlotPressOutcome(found: false, candidateCount: groupCount, chosen: "none", method: "none",
                                    resultCode: 0, actions: "",
                                    diagnostic: "no button for \(slotKind) (plug-ins: \(groupCount), empty effect slot: \(strip.emptyEffectButton != nil))")
        }
        var names: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] {
            actions = list
        }
        _ = AXUIElementSetMessagingTimeout(element, 0.7)
        let code = AXUIElementPerformAction(element, kAXPressAction as CFString)
        _ = AXUIElementSetMessagingTimeout(element, 0) // back to the global default
        return SlotPressOutcome(
            found: true, candidateCount: groupCount, chosen: describe(element), method: "AXPress",
            resultCode: code.rawValue, actions: actions.joined(separator: ","), diagnostic: "")
    }

    // MARK: - Bypass

    private static func resolve(_ target: PluginTarget, in strip: StripLayout) -> PluginGroup? {
        switch target {
        case .instrument:
            return strip.instrument
        case .effect(let n):
            return n >= 1 && strip.effects.indices.contains(n - 1) ? strip.effects[n - 1] : nil
        case .named(let name):
            let all = (strip.instrument.map { [$0] } ?? []) + strip.effects
            return all.first { ComposeSupport.pluginNameMatches($0.name, name) }
        }
    }

    /// Press the bypass checkbox of `target` only when its current state differs from `wanted`.
    static func pressBypassIfNeeded(target: PluginTarget, wanted: Bool) -> BypassOutcome {
        guard let selected = stripItems().selected else {
            return BypassOutcome(found: false, name: "", before: nil, pressed: false, note: "no selected-track item in the Inspector strip")
        }
        let strip = layout(of: selected)
        guard let group = resolve(target, in: strip), let box = group.bypassBox else {
            return BypassOutcome(found: false, name: "", before: nil, pressed: false, note: "plug-in not found in the strip")
        }
        guard let state = checkboxState(box) else {
            return BypassOutcome(found: true, name: group.name, before: nil, pressed: false, note: "bypass state unreadable")
        }
        let current = state == 1
        if current == wanted {
            return BypassOutcome(found: true, name: group.name, before: current, pressed: false, note: "already in the wanted state")
        }
        _ = AXUIElementSetMessagingTimeout(box, 0.7)
        let ok = AXHelpers.performAction(box, kAXPressAction)
        _ = AXUIElementSetMessagingTimeout(box, 0)
        return BypassOutcome(found: true, name: group.name, before: current, pressed: ok, note: ok ? "pressed" : "AXPress failed")
    }

    /// Current bypass state of `target` (name, bypassed), nil when it cannot be found or read.
    static func bypassState(target: PluginTarget) -> (name: String, bypassed: Bool)? {
        guard let selected = stripItems().selected else { return nil }
        let strip = layout(of: selected)
        guard let group = resolve(target, in: strip), let box = group.bypassBox, let state = checkboxState(box) else {
            return nil
        }
        return (group.name, state == 1)
    }

    // MARK: - Faders

    private static func faderItem(master: Bool) -> AXUIElement? {
        let items = stripItems()
        return master ? items.master : items.selected
    }

    private static func faderSlider(master: Bool) -> (slider: AXUIElement, all: [AXUIElement])? {
        guard let item = faderItem(master: master) else { return nil }
        let all = AXHelpers.findAllDescendants(of: item, role: nil, maxDepth: 8)
        guard let slider = firstElement(in: all, role: kAXSliderRole, description: "volume fader") else { return nil }
        return (slider, all)
    }

    /// Range, raw value, level text and settability of the volume fader. nil when not found.
    static func faderInfo(master: Bool) -> FaderInfo? {
        guard let found = faderSlider(master: master) else { return nil }
        let minValue: NSNumber? = AXHelpers.getAttribute(found.slider, kAXMinValueAttribute)
        let maxValue: NSNumber? = AXHelpers.getAttribute(found.slider, kAXMaxValueAttribute)
        var low = minValue?.doubleValue ?? 0
        var high = maxValue?.doubleValue ?? 233
        if !(high > low) { low = 0; high = 233 }
        return FaderInfo(
            min: low, max: high, raw: number(found.slider) ?? 0, levelText: levelText(in: found.all),
            settable: isSettable(found.slider, kAXValueAttribute))
    }

    /// Set the fader's AXValue. False when the fader is not found or the write failed.
    static func setFaderRaw(master: Bool, raw: Double) -> Bool {
        guard let found = faderSlider(master: master) else { return false }
        return AXHelpers.setAttribute(found.slider, kAXValueAttribute, NSNumber(value: raw))
    }

    /// Current level text of the fader ("-6,0 dB"), nil when unreadable.
    static func faderLevelText(master: Bool) -> String? {
        guard let found = faderSlider(master: master) else { return nil }
        return levelText(in: found.all)
    }
}
