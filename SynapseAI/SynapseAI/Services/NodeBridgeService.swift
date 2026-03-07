//
//  NodeBridgeService.swift
//  SynapseAI
//
//  Spawns Node subprocess, sends/receives JSON-RPC over stdin/stdout.
//

import Foundation
import AppKit
import Combine

@MainActor
final class NodeBridgeService: ObservableObject {
    static let shared = NodeBridgeService()

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    /// Debug: script path we tried to use (when disconnected).
    @Published private(set) var debugScriptPath: String?
    /// Debug: node executable path we tried (when disconnected).
    @Published private(set) var debugNodePath: String?
    /// Debug: full error when run() failed (when disconnected).
    @Published private(set) var debugRunError: String?
    /// Last file change path from Node watcher (for Phase 1 HITL)
    @Published private(set) var lastFileChange: String?
    /// Last time snippet injection (⌘⇧P) succeeded
    @Published private(set) var lastInjectionDate: Date?
    /// The most recently built context block (from chat or ⌘⇧P).
    @Published private(set) var lastInjectedBlock: String = ""
    /// Last non-Synapse app that was frontmost — target for the "Paste" button.
    @Published private(set) var lastTargetApp: (name: String, pid: pid_t)?

    func setLastInjectionDate(_ date: Date?) {
        lastInjectionDate = date
    }

    func setLastInjectedBlock(_ block: String) {
        lastInjectedBlock = block
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let queue = DispatchQueue(label: "synapse.nodebridge")
    private var requestId = 0
    private var pending: [Int: CheckedContinuation<Result<Any, Error>, Never>] = [:]
    private var stdoutBuffer = ""
    private var workspaceObserver: NSObjectProtocol?

    private init() {
        startNode()
        observeActiveApp()
    }

    private func observeActiveApp() {
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != ownBundleId,
                let name = app.localizedName
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.lastTargetApp = (name: name, pid: pid)
            }
        }
    }

    private static let nodeScriptPathKey = "synapse.nodeScriptPath"

    /// Resolve full path to the Node.js executable. Tries hardcoded paths, then nvm/fnm dirs, then `which node`.
    private func resolveNodeExecutable() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        var candidates: [String] = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for base in ["\(home)/.nvm/versions/node", "\(home)/.fnm/node-versions", "\(home)/.volta"] {
            if fm.fileExists(atPath: base) {
                if let sub = try? fm.contentsOfDirectory(atPath: base) {
                    for name in sub.sorted().reversed() {
                        let nodePath = ((base as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("bin/node")
                        if fm.fileExists(atPath: nodePath) { candidates.insert(nodePath, at: 0) }
                    }
                }
            }
        }
        for p in candidates {
            if p.hasSuffix("node"), fm.fileExists(atPath: p) { return p }
            if !p.hasSuffix("node") {
                let nodePath = (p as NSString).appendingPathComponent("node")
                if fm.fileExists(atPath: nodePath) { return nodePath }
            }
        }
        return runWhichNode()
    }

    /// Run `which node` via login shell to pick up nvm/fnm PATH.
    private func runWhichNode() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which node 2>/dev/null"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .first
                .map(String.init)
            guard let path = path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }

    private func fullErrorDescription(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [ns.localizedDescription]
        if ns.domain != "NSErrorCocoaErrorDomain" { parts.append("domain: \(ns.domain)") }
        parts.append("code: \(ns.code)")
        if !ns.userInfo.isEmpty, let desc = ns.userInfo[NSDebugDescriptionErrorKey] as? String {
            parts.append("debug: \(desc)")
        }
        return parts.joined(separator: " · ")
    }

    /// Path to node/index.js. Order: UserDefaults override → SYNAPSE_NODE_SCRIPT env → bundle/cwd discovery.
    private var nodeScriptURL: URL? {
        let fileManager = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: Self.nodeScriptPathKey), !saved.isEmpty {
            let url = URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        if let envPath = ProcessInfo.processInfo.environment["SYNAPSE_NODE_SCRIPT"],
           !envPath.isEmpty {
            let url = URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        if let resourcePath = Bundle.main.resourcePath {
            let nodeInBundle = URL(fileURLWithPath: resourcePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("node/index.js")
            if fileManager.fileExists(atPath: nodeInBundle.path) {
                return nodeInBundle
            }
        }
        let cwd = fileManager.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("node/index.js"),
            URL(fileURLWithPath: cwd).appendingPathComponent("../node/index.js"),
        ]
        for url in candidates {
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<10 {
            let nodeIndex = dir.appendingPathComponent("node/index.js")
            if fileManager.fileExists(atPath: nodeIndex.path) { return nodeIndex }
            dir = dir.deletingLastPathComponent()
            if dir.path == "/" { break }
        }
        return nil
    }

    /// Set a custom path to node/index.js (e.g. from file picker). Pass nil to clear. Call restartNode() after.
    func setNodeScriptPath(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: Self.nodeScriptPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.nodeScriptPathKey)
        }
    }

    /// Restart the Node process (e.g. after changing the script path).
    func restartNode() {
        stopNode()
        startNode()
    }

    func startNode() {
        debugScriptPath = nil
        debugNodePath = nil
        debugRunError = nil

        guard let scriptURL = nodeScriptURL else {
            lastError = "node/index.js not found — set Working Directory in Xcode (Run → Options) or use Locate below"
            isConnected = false
            return
        }
        debugScriptPath = scriptURL.path

        let nodePath = resolveNodeExecutable()
        guard let nodePath = nodePath else {
            lastError = "Node.js not found. Install with: brew install node (or use nvm/fnm and ensure 'node' is in PATH)"
            debugNodePath = nil
            isConnected = false
            return
        }
        debugNodePath = nodePath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = extraPath + ":" + existing
        } else {
            env["PATH"] = extraPath
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        do {
            try process.run()
        } catch {
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            lastError = error.localizedDescription
            debugRunError = fullErrorDescription(error)
            isConnected = false
            return
        }

        isConnected = true
        lastError = nil
        debugScriptPath = nil
        debugNodePath = nil
        debugRunError = nil

        let handle = stdoutPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                Task { @MainActor in
                    self?.isConnected = false
                }
                return
            }
            guard let self = self else { return }
            let str = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                self.stdoutBuffer += str
                let parts = self.stdoutBuffer.components(separatedBy: .newlines)
                self.stdoutBuffer = parts.last ?? ""
                let lines = parts.dropLast()
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    if let lineData = trimmed.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        if let id = json["id"] as? Int {
                            if let cont = self.pending.removeValue(forKey: id) {
                                if let result = json["result"] {
                                    cont.resume(returning: .success(result))
                                } else if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                                    cont.resume(returning: .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])))
                                } else {
                                    cont.resume(returning: .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown response"])))
                                }
                            }
                        } else if let method = json["method"] as? String, method == "fileChanged",
                                  let params = json["params"] as? [String: Any], let path = params["path"] as? String {
                            self.lastFileChange = path
                        }
                    }
                }
            }
        }
    }

    func stopNode() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isConnected = false
    }

    func ping() async -> Bool {
        let result: Result<Any, Error> = await call("ping")
        switch result {
        case .success(let any):
            if let dict = any as? [String: Any], dict["pong"] as? Bool == true {
                return true
            }
            return false
        case .failure:
            return false
        }
    }

    func setProject(_ path: String?) async -> Bool {
        let result: Result<Any, Error> = await call("setProject", params: path as Any)
        switch result {
        case .success(let any):
            if let dict = any as? [String: Any], dict["ok"] as? Bool == true {
                return true
            }
            return false
        case .failure:
            return false
        }
    }

    func indexFile(path: String) async -> Result<Int, Error> {
        let result: Result<Any, Error> = await call("indexFile", params: path)
        switch result {
        case .success(let any):
            if let dict = any as? [String: Any], let count = dict["chunksCount"] as? Int {
                return .success(count)
            }
            return .success(0)
        case .failure(let err):
            return .failure(err)
        }
    }

    func indexAll() async -> Result<Int, Error> {
        let result: Result<Any, Error> = await call("indexAll")
        switch result {
        case .success(let any):
            if let dict = any as? [String: Any], let indexed = dict["indexed"] as? Int {
                return .success(indexed)
            }
            return .success(0)
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Returns document count, chunk count, and DB file size in bytes. Failure returns nil stats.
    func getStats() async -> (documentCount: Int, chunkCount: Int, dbSizeBytes: Int64)? {
        let result: Result<Any, Error> = await call("getStats")
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let docs = dict["documentCount"] as? Int,
                  let chunks = dict["chunkCount"] as? Int else { return nil }
            let bytes = (dict["dbSizeBytes"] as? NSNumber)?.int64Value ?? 0
            return (documentCount: docs, chunkCount: chunks, dbSizeBytes: bytes)
        case .failure:
            return nil
        }
    }

    func search(query: String, limit: Int = 10) async -> Result<[SearchResult], Error> {
        print("[Synapse NodeBridge] search(query: '\(query)', limit: \(limit))")
        let result: Result<Any, Error> = await call("search", params: [query, ["limit": limit]])
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any] else {
                print("[Synapse NodeBridge] search response not a dict")
                return .success([])
            }
            if let errMsg = dict["error"] as? String, (dict["ok"] as? Bool) == false {
                print("[Synapse NodeBridge] search error from Node: \(errMsg)")
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
            }
            guard let snippets = dict["snippets"] as? [[String: Any]] else {
                print("[Synapse NodeBridge] search response missing 'snippets'")
                return .success([])
            }
            print("[Synapse NodeBridge] search returned \(snippets.count) snippets")
            let out = snippets.compactMap { s -> SearchResult? in
                guard let path = s["path"] as? String,
                      let content = s["content"] as? String else { return nil }
                let start = s["startLine"] as? Int ?? 0
                let end = s["endLine"] as? Int ?? 0
                return SearchResult(path: path, startLine: start, endLine: end, content: content)
            }
            return .success(out)
        case .failure(let err):
            print("[Synapse NodeBridge] search RPC failure: \(err.localizedDescription)")
            return .failure(err)
        }
    }

    func suggestSkill(apiKey: String) async -> Result<(path: String, inputTokens: Int, outputTokens: Int), Error> {
        let snippetsResult = await search(query: "context overview", limit: 5)
        let snippets: [[String: Any]]
        switch snippetsResult {
        case .success(let list):
            snippets = list.map { ["content": $0.content] }
        case .failure:
            snippets = []
        }
        let result: Result<Any, Error> = await call("suggestSkill", params: [apiKey, snippets])
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let path = dict["path"] as? String,
                  let inT = dict["inputTokens"] as? Int,
                  let outT = dict["outputTokens"] as? Int else {
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }
            return .success((path: path, inputTokens: inT, outputTokens: outT))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Extract learnings from project memory (projectbrief, activeContext, progress, thoughts) and append to .synapse/learnings.md.
    func suggestLearnings(apiKey: String) async -> Result<(path: String, appendedLines: Int, inputTokens: Int, outputTokens: Int), Error> {
        let result: Result<Any, Error> = await call("suggestLearnings", params: [apiKey])
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let path = dict["path"] as? String,
                  let appended = dict["appendedLines"] as? Int,
                  let inT = dict["inputTokens"] as? Int,
                  let outT = dict["outputTokens"] as? Int else {
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }
            return .success((path: path, appendedLines: appended, inputTokens: inT, outputTokens: outT))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// User enters vague prompt; Grok gets index descriptions and suggests chunks; returns block (skill-format markdown or legacy) for clipboard.
    /// maxChunks: user-configurable cap forwarded to Node (1–10; default 5).
    /// memoryFirstMode: when true, prioritize memory chunks (.synapse/) in chunk selection.
    func buildContextForPrompt(apiKey: String, userPrompt: String, maxChunks: Int = 5, memoryFirstMode: Bool = false) async -> Result<(block: String, optimizedPrompt: String?, chunkCount: Int, totalDescriptions: Int, estimatedSavedTokens: Int, inputTokens: Int, outputTokens: Int), Error> {
        let result: Result<Any, Error> = await call("buildContextForPrompt", params: [apiKey, userPrompt, maxChunks, memoryFirstMode])
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let block = dict["block"] as? String else {
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }
            let optimizedPrompt = dict["optimizedPrompt"] as? String
            let chunkCount = dict["chunkCount"] as? Int ?? 0
            let totalDescriptions = dict["totalDescriptions"] as? Int ?? chunkCount
            let estimatedSavedTokens = dict["estimatedSavedTokens"] as? Int ?? 0
            let inputTokens = dict["inputTokens"] as? Int ?? 0
            let outputTokens = dict["outputTokens"] as? Int ?? 0
            return .success((block: block, optimizedPrompt: optimizedPrompt, chunkCount: chunkCount, totalDescriptions: totalDescriptions, estimatedSavedTokens: estimatedSavedTokens, inputTokens: inputTokens, outputTokens: outputTokens))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Build context package for a parallel subagent (memory-heavy). Returns block + token counts.
    /// maxChunks: user-configurable cap for supplemental DB snippets (1–10; default 5).
    func buildSubagentContext(apiKey: String, userPrompt: String, maxChunks: Int = 5) async -> Result<(block: String, inputTokens: Int, outputTokens: Int), Error> {
        let result: Result<Any, Error> = await call("buildSubagentContext", params: [apiKey, userPrompt, maxChunks])
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let block = dict["block"] as? String else {
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }
            let inputTokens = dict["inputTokens"] as? Int ?? 0
            let outputTokens = dict["outputTokens"] as? Int ?? 0
            return .success((block: block, inputTokens: inputTokens, outputTokens: outputTokens))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Sharpen a rough prompt using Grok + project memory. Returns the refined prompt text + token counts.
    /// Returns nodes (indexed files) and connections (fromId, toId, type, label) for memory map visualization.
    func getAllConnections() async -> Result<(nodes: [MemoryMapNode], connections: [MemoryMapConnection]), Error> {
        let result: Result<Any, Error> = await call("getAllConnections")
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let nodesArr = dict["nodes"] as? [[String: Any]],
                  let connArr = dict["connections"] as? [[String: Any]] else {
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid getAllConnections response"]))
            }
            let nodes = nodesArr.compactMap { n -> MemoryMapNode? in
                guard let id = n["id"] as? String, let path = n["path"] as? String else { return nil }
                let typeStr = n["type"] as? String ?? "file"
                let type: MemoryMapNodeType = typeStr == "chunk" ? .chunk : .file
                let docPath = n["documentPath"] as? String
                return MemoryMapNode(id: id, path: path, type: type, documentPath: docPath)
            }
            let connections = connArr.compactMap { c -> MemoryMapConnection? in
                guard let fromId = c["fromId"] as? String, let toId = c["toId"] as? String else { return nil }
                let type = c["type"] as? String ?? "reference"
                let label = c["label"] as? String ?? type
                return MemoryMapConnection(fromId: fromId, toId: toId, type: type, label: label)
            }
            return .success((nodes: nodes, connections: connections))
        case .failure(let err):
            return .failure(err)
        }
    }

    func optimizePrompt(apiKey: String, userPrompt: String) async -> Result<(optimizedPrompt: String, inputTokens: Int, outputTokens: Int), Error> {
        let result: Result<Any, Error> = await call("optimizePrompt", params: [apiKey, userPrompt])
        switch result {
        case .success(let any):
            guard let dict = any as? [String: Any],
                  let optimized = dict["optimizedPrompt"] as? String else {
                return .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }
            let inputTokens = dict["inputTokens"] as? Int ?? 0
            let outputTokens = dict["outputTokens"] as? Int ?? 0
            return .success((optimizedPrompt: optimized, inputTokens: inputTokens, outputTokens: outputTokens))
        case .failure(let err):
            return .failure(err)
        }
    }

    private func call(_ method: String, params: Any? = nil) async -> Result<Any, Error> {
        let id = requestId
        requestId += 1
        var req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let p = params {
            req["params"] = p
        }

        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            return .failure(NSError(domain: "NodeBridge", code: -32700, userInfo: [NSLocalizedDescriptionKey: "Serialize error"]))
        }

        return await withCheckedContinuation { cont in
            queue.sync {
                pending[id] = cont
            }
            if let pipe = stdinPipe {
                pipe.fileHandleForWriting.write((str + "\n").data(using: .utf8)!)
            } else {
                queue.sync {
                    _ = pending.removeValue(forKey: id)
                }
                cont.resume(returning: .failure(NSError(domain: "NodeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Node not running"])))
            }
        }
    }
}
