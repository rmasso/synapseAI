//
//  DashboardViewModel.swift
//  SynapseAI
//

import Foundation
import AppKit
import SwiftUI

// MARK: - Memory map cache (persist map across tab/chat changes)

struct MemoryMapCache {
    let projectPath: String
    let nodes: [MemoryMapNode]
    let connections: [MemoryMapConnection]
    let nodePositions: [String: CGPoint]
}

/// Shared cache store keyed by project path. Survives tab switches so each project's map is cached and not reloaded.
@MainActor
final class MemoryMapCacheStore: ObservableObject {
    @Published private(set) var caches: [String: MemoryMapCache] = [:]
    private var indexAllObserver: NSObjectProtocol?

    init() {
        indexAllObserver = NotificationCenter.default.addObserver(forName: .indexAllCompleted, object: nil, queue: .main) { [weak self] notification in
            guard let path = notification.object as? String else { return }
            self?.caches.removeValue(forKey: path)
        }
    }

    func cache(for path: String) -> MemoryMapCache? { caches[path] }
    func setCache(_ cache: MemoryMapCache) { caches[cache.projectPath] = cache }
}

// MARK: - Chat message model

struct ChatMessage: Identifiable {
    enum Kind {
        case user
        case hit(path: String, startLine: Int, endLine: Int)
        /// chunkCount: selected, totalAvailable: fed to Grok, estimatedSavedTokens: from Node, inputTokens/outputTokens: Grok API usage
        case block(chunkCount: Int, totalAvailable: Int, estimatedSavedTokens: Int, inputTokens: Int, outputTokens: Int)
        /// Subagent context (memory-heavy package for parallel agent)
        case subagentContext(inputTokens: Int, outputTokens: Int)
        /// Chat mode: natural-language reply from Grok (can search project)
        case assistant(inputTokens: Int, outputTokens: Int)
        /// Shift+Return refined prompt
        case optimized(inputTokens: Int, outputTokens: Int)
        case error
    }
    let id = UUID()
    let kind: Kind
    let text: String
}

// MARK: - ViewModel

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var statusText: String = ""
    @Published var nodeConnected: Bool = false
    @Published var lastPingSuccess: Bool = false
    @Published var indexCount: Int?
    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchResult] = []
    @Published var searchError: String?
    @Published var lastIngestedFile: String?
    @Published var promptBlock: String = ""
    @Published var lastSkillCreated: String?
    @Published var skillError: String?
    @Published var isUpdatingLearnings = false
    @Published var learningsError: String?
    @Published var learningsSuccess: String?
    @Published var isSelfSynapsing = false
    @Published var selfSynapseSuccess: String?
    @Published var selfSynapseError: String?
    @Published var grokTokensInput: Int = 0
    @Published var grokTokensOutput: Int = 0
    @Published var memoryFiles: [(name: String, modified: Date)] = []
    @Published var thoughtsPreview: String = ""
    @Published var learningsPreview: String = ""
    @Published var lastInjectionDate: Date?
    @Published var dbStats: (documentCount: Int, chunkCount: Int, dbSizeBytes: Int64)?
    /// True while indexAll is in progress (show loader near chunk count).
    @Published var isIndexing = false
    /// After indexAll: positive = chunks grew (green), negative = reduced (red). Cleared after ~3s.
    @Published var chunkCountDelta: Int? = nil
    @Published var isIngesting = false
    @Published var ingestSuccessMessage: String?
    @Published var ingestError: String?
    @Published var isDropTargeted = false
    @Published var promptForContext: String = ""
    @Published var isBuildingContext = false
    @Published var buildContextError: String?
    @Published var buildContextSuccess: String?
    @Published var isBuildingSubagentContext = false
    @Published var subagentContextError: String?
    @Published var subagentContextSuccess: String?
    @Published var isOptimizingPrompt = false
    @Published var isBuildingChat = false

    // Additional index folder
    @Published var extraFolderSuccess: String?
    @Published var extraFolderError: String?
    /// True after indexAll when additional folder is configured but contains no tag-bearing chunks.
    @Published var suggestSkillOnNoTags: Bool = false

    // Onboarding
    @AppStorage("synapse.onboardingCompleted") var onboardingCompleted: Bool = false
    @Published var showOnboarding: Bool = false

    // Context chunk limit (user-configurable via slider; 1–10; default 5)
    @AppStorage("synapse.maxChunksForPrompt") var maxChunksForPrompt: Int = 10
    /// When true, prioritize memory chunks (.synapse/) in chunk selection for buildContextForPrompt.
    @AppStorage("synapse.memoryFirstMode") var memoryFirstMode: Bool = false

    // Chat history
    @Published var chatMessages: [ChatMessage] = []

    /// Cached memory map data keyed by project path; avoids reload when switching tabs or chat view.
    @Published var memoryMapCache: MemoryMapCache?

    func refresh(from nodeBridge: NodeBridgeService) {
        nodeConnected = nodeBridge.isConnected
        statusText = nodeBridge.isConnected ? "Node bridge connected" : (nodeBridge.lastError ?? "Node not connected")
        lastInjectionDate = nodeBridge.lastInjectionDate
    }

    func refreshFolderContent(folderService: FolderService) {
        memoryFiles = folderService.memoryFilesList()
        thoughtsPreview = folderService.thoughtsPreview(maxLines: 15)
        learningsPreview = folderService.learningsPreview(maxLines: 20)
    }

    func refreshStats(nodeBridge: NodeBridgeService) async {
        if let stats = await nodeBridge.getStats() {
            dbStats = (stats.documentCount, stats.chunkCount, stats.dbSizeBytes)
        } else {
            dbStats = nil
        }
    }

    func ping(nodeBridge: NodeBridgeService) async {
        lastPingSuccess = await nodeBridge.ping()
    }

    func indexAll(nodeBridge: NodeBridgeService, folderService: FolderService? = nil, projectId: UUID? = nil) async {
        let previousChunkCount = dbStats?.chunkCount
        isIndexing = true
        chunkCountDelta = nil
        defer { isIndexing = false }
        switch await nodeBridge.indexAll() {
        case .success(let count):
            indexCount = count
            await refreshStats(nodeBridge: nodeBridge)
            memoryMapCache = nil
            if let path = folderService?.projectPath {
                NotificationCenter.default.post(name: .indexAllCompleted, object: path)
            }
            let newChunkCount = dbStats?.chunkCount ?? 0
            chunkCountDelta = newChunkCount - (previousChunkCount ?? 0)
            Task {
                try? await Task.sleep(for: .seconds(3))
                chunkCountDelta = nil
            }
            if let folderService {
                refreshFolderContent(folderService: folderService)
                if let pid = projectId { folderService.recordIndexTime(for: pid) }
                if folderService.additionalIndexFolderPath != nil {
                    await checkAdditionalFolderTags(nodeBridge: nodeBridge)
                } else {
                    suggestSkillOnNoTags = false
                }
            }
        case .failure:
            indexCount = nil
            chunkCountDelta = nil
        }
    }

    /// After indexAll, search for tag-bearing chunks; if none found, surface the skill suggestion.
    private func checkAdditionalFolderTags(nodeBridge: NodeBridgeService) async {
        switch await nodeBridge.search(query: "tags:") {
        case .success(let results):
            suggestSkillOnNoTags = results.isEmpty
        case .failure:
            suggestSkillOnNoTags = false
        }
    }

    func runSearch(nodeBridge: NodeBridgeService) async {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            promptBlock = ""
            return
        }
        switch await nodeBridge.search(query: searchQuery) {
        case .success(let list):
            searchResults = list
            searchError = nil
            promptBlock = buildPromptBlock(from: list)
        case .failure(let err):
            searchResults = []
            promptBlock = ""
            searchError = err.localizedDescription
        }
    }

    private func buildPromptBlock(from results: [SearchResult]) -> String {
        var lines: [String] = []
        for r in results {
            lines.append("@\(r.path) (lines \(r.startLine)-\(r.endLine))")
            lines.append(r.content)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func suggestSkill(apiKey: String, nodeBridge: NodeBridgeService) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            skillError = "Enter Grok API key"
            return
        }
        skillError = nil
        lastSkillCreated = nil
        switch await nodeBridge.suggestSkill(apiKey: apiKey) {
        case .success(let out):
            lastSkillCreated = (out.path as NSString).lastPathComponent
            grokTokensInput += out.inputTokens
            grokTokensOutput += out.outputTokens
            suggestSkillOnNoTags = false
        case .failure(let err):
            skillError = err.localizedDescription
        }
    }

    func updateLearnings(apiKey: String, nodeBridge: NodeBridgeService, folderService: FolderService) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            learningsError = "Enter Grok API key"
            return
        }
        learningsError = nil
        learningsSuccess = nil
        isUpdatingLearnings = true
        defer { isUpdatingLearnings = false }
        switch await nodeBridge.suggestLearnings(apiKey: apiKey) {
        case .success(let out):
            grokTokensInput += out.inputTokens
            grokTokensOutput += out.outputTokens
            learningsSuccess = "Appended \(out.appendedLines) learnings to learnings.md"
            refreshFolderContent(folderService: folderService)
        case .failure(let err):
            learningsError = err.localizedDescription
        }
    }

    func runSelfSynapse(apiKey: String, nodeBridge: NodeBridgeService, folderService: FolderService) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selfSynapseError = "Enter Grok API key"
            return
        }
        selfSynapseError = nil
        selfSynapseSuccess = nil
        isSelfSynapsing = true
        nodeBridge.clearSelfSynapseProgress()
        defer { isSelfSynapsing = false }
        switch await nodeBridge.selfSynapse(apiKey: apiKey) {
        case .success(let out):
            grokTokensInput += out.inputTokens
            grokTokensOutput += out.outputTokens
            let count = out.filesUpdated.count
            selfSynapseSuccess = "Updated \(count) file\(count == 1 ? "" : "s")"
            refreshFolderContent(folderService: folderService)
        case .failure(let err):
            selfSynapseError = err.localizedDescription
        }
    }

    func selectAdditionalFolder(folderService: FolderService) {
        extraFolderError = nil
        extraFolderSuccess = nil
        if folderService.projectPath == nil {
            extraFolderError = "Select a project first (New Project…)."
            return
        }
        if let rel = folderService.openAdditionalIndexFolderPicker() {
            extraFolderSuccess = "Added: \(rel). Run Index All to index it."
        } else {
            extraFolderError = "Folder must be inside the project folder."
        }
    }

    func clearAdditionalFolder(folderService: FolderService) {
        extraFolderError = nil
        extraFolderSuccess = nil
        suggestSkillOnNoTags = false
        folderService.writeAdditionalIndexFolder(nil)
        extraFolderSuccess = "Extra folder cleared."
    }

    func clearChatHistory() {
        chatMessages = []
        buildContextError = nil
        buildContextSuccess = nil
        subagentContextError = nil
        subagentContextSuccess = nil
    }

    /// Shift+Return: use Grok to sharpen the current prompt using project memory.
    /// On success, replaces promptForContext with the refined text and adds an .optimized bubble.
    func optimizePrompt(apiKey: String, nodeBridge: NodeBridgeService) async {
        let prompt = promptForContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chatMessages.append(ChatMessage(kind: .error, text: "Grok API key required to refine prompts. Add it in Tools & Settings."))
            return
        }
        isOptimizingPrompt = true
        defer { isOptimizingPrompt = false }
        switch await nodeBridge.optimizePrompt(apiKey: apiKey, userPrompt: prompt) {
        case .success(let out):
            promptForContext = out.optimizedPrompt
            grokTokensInput += out.inputTokens
            grokTokensOutput += out.outputTokens
            clearChatHistory()
            chatMessages.append(ChatMessage(kind: .user, text: prompt))
            chatMessages.append(ChatMessage(
                kind: .optimized(inputTokens: out.inputTokens, outputTokens: out.outputTokens),
                text: out.optimizedPrompt
            ))
        case .failure:
            // Silent fallback: keep the original prompt; no bubble on failure
            break
        }
    }

    /// Build subagent context (memory-heavy) using same prompt bar text. Appends .subagentContext message and copies to clipboard.
    func buildSubagentContext(apiKey: String, nodeBridge: NodeBridgeService) async {
        let prompt = promptForContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        subagentContextError = nil
        subagentContextSuccess = nil
        isBuildingSubagentContext = true
        defer { isBuildingSubagentContext = false }

        clearChatHistory()
        chatMessages.append(ChatMessage(kind: .user, text: prompt))
        promptForContext = ""

        let hasGrok = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasGrok else {
            chatMessages.append(ChatMessage(kind: .error, text: "Enter Grok API key in Tools & Settings to generate subagent context."))
            subagentContextError = "Grok API key required"
            return
        }

        switch await nodeBridge.buildSubagentContext(apiKey: apiKey, userPrompt: prompt, maxChunks: maxChunksForPrompt) {
        case .success(let out):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(out.block, forType: .string)
            grokTokensInput += out.inputTokens
            grokTokensOutput += out.outputTokens
            nodeBridge.setLastInjectedBlock(out.block)
            chatMessages.append(ChatMessage(
                kind: .subagentContext(inputTokens: out.inputTokens, outputTokens: out.outputTokens),
                text: out.block
            ))
            subagentContextSuccess = "Subagent context · copied to clipboard"
        case .failure(let err):
            chatMessages.append(ChatMessage(kind: .error, text: "Subagent context failed: \(err.localizedDescription)"))
            subagentContextError = err.localizedDescription
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Subagent context error: \(err.localizedDescription)", forType: .string)
        }
    }

    /// Chat mode: multi-turn conversation. Does NOT clear chat; appends user + assistant.
    func sendChatMessage(apiKey: String, nodeBridge: NodeBridgeService) async {
        let prompt = promptForContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !isBuildingContext, !isBuildingSubagentContext, !isOptimizingPrompt, !isBuildingChat else { return }

        let hasGrok = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasGrok else {
            chatMessages.append(ChatMessage(kind: .error, text: "Enter Grok API key in Tools & Settings to use Chat mode."))
            return
        }

        chatMessages.append(ChatMessage(kind: .user, text: prompt))
        promptForContext = ""

        isBuildingChat = true
        defer { isBuildingChat = false }

        let messages: [[String: Any]] = chatMessages.compactMap { msg in
            switch msg.kind {
            case .user: return ["role": "user", "content": msg.text]
            case .assistant: return ["role": "assistant", "content": msg.text]
            default: return nil
            }
        }

        switch await nodeBridge.chatTurn(apiKey: apiKey, messages: messages) {
        case .success(let out):
            grokTokensInput += out.inputTokens
            grokTokensOutput += out.outputTokens
            chatMessages.append(ChatMessage(
                kind: .assistant(inputTokens: out.inputTokens, outputTokens: out.outputTokens),
                text: out.content
            ))
        case .failure(let err):
            chatMessages.append(ChatMessage(kind: .error, text: "Chat failed: \(err.localizedDescription)"))
        }
    }

    /// Step 1: immediate FTS search → add hit messages.
    /// Step 2: if Grok key present, build enriched block → add block message.
    /// Step 3: if no Grok key, build plain FTS block → add block message.
    /// Always copies the resulting block to the clipboard.
    func buildContextForPrompt(apiKey: String, nodeBridge: NodeBridgeService) async {
        let prompt = promptForContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        buildContextError = nil
        buildContextSuccess = nil
        isBuildingContext = true
        defer { isBuildingContext = false }

        // Persist so ⌘⇧P hotkey can reuse the last typed prompt.
        SynapseAIApp.lastChatPrompt = prompt

        clearChatHistory()
        chatMessages.append(ChatMessage(kind: .user, text: prompt))
        promptForContext = ""

        // Step 1: FTS search (hits not shown in chat — only user + final block)
        var hits: [SearchResult] = []
        switch await nodeBridge.search(query: prompt) {
        case .success(let results):
            hits = results
            searchResults = results
            searchError = nil
            if results.isEmpty {
                chatMessages.append(ChatMessage(
                    kind: .error,
                    text: "No matching chunks found. Try indexing more files or rephrasing your prompt."
                ))
                return
            }
        case .failure(let err):
            chatMessages.append(ChatMessage(kind: .error, text: "Search error: \(err.localizedDescription)"))
            buildContextError = err.localizedDescription
            return
        }

        // Step 2: Build context block — on success, chat shows only [user, block]
        let hasGrok = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasGrok {
            switch await nodeBridge.buildContextForPrompt(apiKey: apiKey, userPrompt: prompt, maxChunks: maxChunksForPrompt, memoryFirstMode: memoryFirstMode) {
            case .success(let out):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(out.block, forType: .string)
                grokTokensInput += out.inputTokens
                grokTokensOutput += out.outputTokens
                promptBlock = out.block
                nodeBridge.setLastInjectedBlock(out.block)
                chatMessages.append(ChatMessage(
                    kind: .block(chunkCount: out.chunkCount,
                                 totalAvailable: out.totalDescriptions,
                                 estimatedSavedTokens: out.estimatedSavedTokens,
                                 inputTokens: out.inputTokens,
                                 outputTokens: out.outputTokens),
                    text: out.block
                ))
                buildContextSuccess = "Copied · paste with ⌘V"
                NotificationCenter.default.post(name: .lastContextUpdated, object: nil)
            case .failure(let err):
                // Grok failed – fall back to plain FTS block
                let block = buildPromptBlock(from: hits)
                promptBlock = block
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block, forType: .string)
                nodeBridge.setLastInjectedBlock(block)
                chatMessages.append(ChatMessage(
                    kind: .block(chunkCount: hits.count, totalAvailable: hits.count, estimatedSavedTokens: 0, inputTokens: 0, outputTokens: 0),
                    text: block
                ))
                buildContextSuccess = "Copied (Grok unavailable, used FTS) · paste with ⌘V"
                buildContextError = "Grok: \(err.localizedDescription)"
            }
        } else {
            // No Grok key: use FTS results directly
            let block = buildPromptBlock(from: hits)
            promptBlock = block
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(block, forType: .string)
            nodeBridge.setLastInjectedBlock(block)
            chatMessages.append(ChatMessage(
                kind: .block(chunkCount: hits.count, totalAvailable: hits.count, estimatedSavedTokens: 0, inputTokens: 0, outputTokens: 0),
                text: block
            ))
            buildContextSuccess = "Copied · paste with ⌘V"
        }
    }
}

extension Notification.Name {
    static let lastContextUpdated = Notification.Name("lastContextUpdated")
    /// Posted when indexAll succeeds; object = project path (String). Invalidates MemoryMapView cache for that project.
    static let indexAllCompleted = Notification.Name("indexAllCompleted")
}
