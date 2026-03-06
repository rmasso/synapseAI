//
//  AccessibilityService.swift
//  SynapseAI
//
//  Paste text into any app via AX or clipboard + targeted ⌘V.
//  See .synapse/skills/skill-accessibility-injection.md
//

import AppKit
import CoreGraphics

final class AccessibilityService {
    static let shared = AccessibilityService()

    private init() {}

    // MARK: - Public API

    /// Copy `text` to clipboard and paste into `targetPid` via AX → clipboard+⌘V.
    /// Returns a human-readable result string for logging/UI.
    @discardableResult
    func pasteIntoApp(text: String, targetPid: pid_t) -> String {
        // 1. Always write clipboard first so ⌘V works even if AX fails.
        copyToClipboard(text)

        // 2. Activate the target app so it receives events.
        if let app = NSRunningApplication(processIdentifier: targetPid) {
            app.activate()
        }

        // 3. Brief pause to let the app come to front before posting events.
        Thread.sleep(forTimeInterval: 0.08)

        // 4. Try AX insert.
        let axResult = tryAXInsert(text: text, targetPid: targetPid)
        if axResult {
            print("[Synapse AX] AX insert succeeded for pid=\(targetPid)")
            return "AX insert succeeded"
        }

        // 5. Fallback: ⌘V targeted at the specific pid.
        print("[Synapse AX] AX failed — sending ⌘V to pid=\(targetPid)")
        simulateCmdV(targetPid: targetPid)
        return "clipboard + ⌘V sent to pid=\(targetPid)"
    }

    /// Legacy helper kept for callers that don't have a pid.
    /// Pastes into whatever app is currently frontmost.
    @discardableResult
    func paste(_ text: String) -> Bool {
        copyToClipboard(text)
        if tryAXInsert(text: text, targetPid: nil) { return true }
        simulateCmdV(targetPid: nil)
        return false
    }

    /// Simulate ⌘V, optionally targeted at a specific process.
    /// Prefer `targetPid` when available — it is reliable even after a brief focus change.
    func simulateCmdV(targetPid: pid_t?) {
        let keyCodeV: CGKeyCode = 9
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("[Synapse AX] CGEventSource unavailable")
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand

        if let pid = targetPid {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
            print("[Synapse AX] ⌘V posted to pid=\(pid)")
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            print("[Synapse AX] ⌘V posted to cghidEventTap (frontmost)")
        }
    }

    // MARK: - Private helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Try to insert `text` into the focused element of the given pid (or the system-focused element).
    /// Tries three AX strategies in order of reliability for Electron / web apps.
    private func tryAXInsert(text: String, targetPid: pid_t?) -> Bool {
        // Resolve the focused element.
        let focusElement: AXUIElement?
        if let pid = targetPid {
            focusElement = focusedElement(forPid: pid)
        } else {
            focusElement = systemFocusedElement()
        }
        guard let element = focusElement else {
            print("[Synapse AX] No focused element found")
            return false
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        print("[Synapse AX] Focused element role: '\(role)'")

        // Strategy A: kAXSelectedTextAttribute — replaces selection / inserts at caret.
        // Works well in Electron when kAXValueAttribute doesn't.
        let selResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        print("[Synapse AX] kAXSelectedTextAttribute result: \(selResult.rawValue)")
        if selResult == .success { return true }

        // Strategy B: kAXValueAttribute — full text replacement; works in native text fields.
        let valResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        print("[Synapse AX] kAXValueAttribute result: \(valResult.rawValue)")
        if valResult == .success { return true }

        return false
    }

    private func focusedElement(forPid pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if rc == .success, let ref = focused {
            return (ref as! AXUIElement)
        }
        print("[Synapse AX] kAXFocusedUIElement for pid=\(pid) failed: \(rc.rawValue)")
        if rc.rawValue == -25212 {
            print("[Synapse AX] -25212 = kAXErrorAPIDisabled. Grant Synapse Accessibility access in System Settings → Privacy & Security → Accessibility.")
        }
        return nil
    }

    private func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard rc == .success, let ref = focused else { return nil }
        return (ref as! AXUIElement)
    }
}
