//
//  HotkeyService.swift
//  SynapseAI
//
//  Global hotkey ⌘⇧P for snippet injection. Requires Accessibility permission for global monitor.
//

import AppKit

final class HotkeyService {
    static let shared = HotkeyService()
    private var globalMonitor: Any?
    private var onTrigger: (() -> Void)?

    private init() {}

    func registerHotkey(trigger: @escaping () -> Void) {
        print("[Synapse Hotkey] registerHotkey called")
        onTrigger = trigger
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let char = event.charactersIgnoringModifiers ?? ""
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let isCmdShiftP = cmd && shift && (char == "p" || char == "P")
            if isCmdShiftP {
                print("[Synapse Hotkey] ⌘⇧P detected — firing trigger")
                self?.onTrigger?()
            }
        }
        if globalMonitor != nil {
            print("[Synapse Hotkey] Global monitor installed. If ⌘⇧P does nothing, check: System Settings → Privacy & Security → Accessibility → Synapse enabled.")
        } else {
            print("[Synapse Hotkey] ERROR: addGlobalMonitorForEvents returned nil — Accessibility permission likely missing.")
        }
    }

    func unregister() {
        print("[Synapse Hotkey] unregister called")
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        onTrigger = nil
    }
}
