//
//  SynapseAIApp.swift
//  SynapseAI
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring app to front so the Dashboard window (opened by WindowGroup-first) is visible.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.unregister()
    }
}

@main
struct SynapseAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var nodeBridge = NodeBridgeService.shared
    @StateObject private var folderService = FolderService.shared

    init() {
        print("[Synapse App] init — registering hotkey on main queue")
        DispatchQueue.main.async {
            HotkeyService.shared.registerHotkey {
                print("[Synapse App] Hotkey triggered — scheduling runInjection")
                Task { @MainActor in
                    await SynapseAIApp.runInjection()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                await SynapseAIApp.restoreProjectInNodeIfNeeded()
            }
        }
    }

    /// Restore the saved project into the Node bridge so the DB is opened (persistent .synapse/synapse.db).
    static func restoreProjectInNodeIfNeeded() async {
        let folderService = FolderService.shared
        let nodeBridge = NodeBridgeService.shared
        guard let path = folderService.projectPath, nodeBridge.isConnected else { return }
        _ = await nodeBridge.setProject(path)
    }

    var body: some Scene {
        WindowGroup("Dashboard", id: "dashboard") {
            DashboardView()
                .environmentObject(nodeBridge)
                .environmentObject(folderService)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 400)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(nodeBridge)
                .environmentObject(folderService)
        } label: {
            Image(systemName: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }

    // Last prompt entered in the Dashboard chat — reused as ⌘⇧P search query.
    static var lastChatPrompt: String = "context"

    static func runInjection() async {
        print("[Synapse Injection] runInjection started")
        let nodeBridge = NodeBridgeService.shared
        print("[Synapse Injection] Node connected: \(nodeBridge.isConnected)")

        // ── Capture the target app BEFORE any async work ──────────────────────
        // At this point the user is still in Cursor (or whichever app they hotkeyed from).
        let targetApp = NSWorkspace.shared.frontmostApplication
        let targetPid: pid_t? = targetApp?.processIdentifier
        let targetName = targetApp?.localizedName ?? "last app"
        print("[Synapse Injection] Target app: \(targetName) pid=\(targetPid.map { "\($0)" } ?? "nil")")

        // ── Choose a search query ──────────────────────────────────────────────
        // Use the last prompt typed in the Dashboard chat; fall back to "context".
        let searchQuery = lastChatPrompt.isEmpty ? "context" : lastChatPrompt
        print("[Synapse Injection] Search query: '\(searchQuery)'")

        // ── Search the index ───────────────────────────────────────────────────
        let results: [SearchResult]
        switch await nodeBridge.search(query: searchQuery, limit: 15) {
        case .success(let list):
            results = list
            print("[Synapse Injection] Search success — \(list.count) snippets")
        case .failure(let err):
            print("[Synapse Injection] Search failed: \(err.localizedDescription)")
            let msg = "Synapse: search failed — \(err.localizedDescription). Is Node connected? Run Index All in Dashboard."
            copyToClipboard(msg)
            if let pid = targetPid {
                AccessibilityService.shared.simulateCmdV(targetPid: pid)
            }
            return
        }

        // ── Build block ────────────────────────────────────────────────────────
        var lines: [String] = []
        var total = 0
        let maxChars = 6000
        for r in results {
            if total + r.content.count > maxChars { break }
            lines.append("@\(r.path) (lines \(r.startLine)-\(r.endLine))")
            lines.append(r.content)
            lines.append("")
            total += r.content.count
        }
        let block = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Synapse Injection] Block: \(block.count) chars, empty: \(block.isEmpty)")

        if block.isEmpty {
            let msg = "Synapse: no snippets found for '\(searchQuery)'. Drop .md files in Dashboard and run Index All."
            copyToClipboard(msg)
            if let pid = targetPid {
                AccessibilityService.shared.simulateCmdV(targetPid: pid)
            }
            return
        }

        // ── Inject ─────────────────────────────────────────────────────────────
        nodeBridge.setLastInjectedBlock(block)
        if let pid = targetPid {
            let result = AccessibilityService.shared.pasteIntoApp(text: block, targetPid: pid)
            print("[Synapse Injection] \(result)")
        } else {
            // No known pid — copy to clipboard and let the user ⌘V manually.
            copyToClipboard(block)
            print("[Synapse Injection] No target pid; block copied to clipboard — press ⌘V in Cursor.")
        }
        nodeBridge.setLastInjectionDate(Date())
        print("[Synapse Injection] Done")
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
