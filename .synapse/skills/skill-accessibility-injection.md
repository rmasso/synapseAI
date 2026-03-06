---
name: Accessibility Injection Mechanisms
tags: [macos, accessibility, cursor, injection, swiftui]
---

## Overview
This skill covers mechanisms for injecting text snippets into the Cursor application on macOS, prioritizing the Accessibility API (AX) for direct pasting into the Composer, with clipboard fallback for compatibility. It ensures reliable context injection during long agentic sessions, handling element stability and error cases.

## Rules
- Always attempt AX injection first: Locate Cursor's main window, focus the Composer text area (role "AXTextArea" or similar), and set its value with the snippet.
- Fall back to clipboard if AX fails: Copy snippet to clipboard and simulate ⌘V via AX or notify user to paste manually.
- Chunk snippets to 4-8 KB (approx. 300-800 tokens) to avoid truncation; reference full files with @file syntax.
- Log debug info for hotkey trigger, AX element search, paste result, and fallback actions.
- Handle Cursor updates by checking element roles dynamically; if unstable, prioritize clipboard.
- Ensure app has Accessibility permissions; prompt user if denied.

## Examples
### AX Injection Success
```swift
// In AccessibilityService
func injectSnippet(_ snippet: String) {
    guard let cursorApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.402126102").first else { return }
    let axApp = AXUIElementCreateApplication(cursorApp.processIdentifier)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value)
    // Assume focused element is Composer textarea
    if AXUIElementSetAttributeValue(value as! AXUIElement, kAXValueAttribute as CFString, snippet as CFTypeRef) == .success {
        print("AX paste successful")
    } else {
        fallbackToClipboard(snippet)
    }
}
```

### Clipboard Fallback
```swift
func fallbackToClipboard(_ snippet: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(snippet, forType: .string)
    // Simulate ⌘V or notify user
    print("Snippet copied to clipboard; paste manually if needed")
}
```

### Hotkey Trigger with Debug
```swift
// In HotkeyService
@objc func onHotkey() {
    print("Hotkey fired: ⌘⇧P")
    runInjection()
}
func runInjection() {
    // Search Node for snippet, then inject
    print("Searching Node for context...")
    // ... inject via AX or clipboard
}
```