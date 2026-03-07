//
//  FolderService.swift
//  SynapseAI
//
//  Project root, security-scoped bookmarks, .synapse path.
//  Supports multiple projects; "active" project drives projectPath/synapsePath.
//

import Foundation
import AppKit

@MainActor
final class FolderService: ObservableObject {
    static let shared = FolderService()

    // MARK: - UserDefaults keys

    /// Legacy single-project keys (kept for migration).
    private let legacyBookmarkKey = "synapse.projectBookmark"
    private let legacyPathKey = "synapse.projectPath"
    /// Multi-project list.
    private let projectsKey = "synapse.projects"

    // MARK: - Published state

    /// All managed projects (persisted across launches).
    @Published private(set) var projects: [SynapseProject] = []
    /// ID of the currently active project.
    @Published private(set) var activeProjectId: UUID?

    // MARK: - Active-project convenience properties (used throughout existing views)

    /// Absolute path to the active project root. nil when no project is active.
    @Published private(set) var projectPath: String?
    /// Absolute path to the active project's .synapse folder.
    @Published private(set) var synapsePath: String? {
        didSet { objectWillChange.send() }
    }
    /// Relative path of the optional extra index folder (e.g. ".Cursor"). nil when not set.
    @Published private(set) var additionalIndexFolderPath: String?
    /// When true, Index All also indexes the full project (source files by extension), not just .synapse and indexFolders.
    @Published private(set) var indexFullProject: Bool = false
    /// Last successful indexAll timestamp per project UUID.
    @Published private(set) var lastIndexTimes: [UUID: Date] = [:]

    // MARK: - Init

    private init() {
        loadPersistedProjects()   // must run before migration
        migrateLegacyBookmarkIfNeeded()
        // Activate the first project (or the one that was active last session if we add that later).
        if let first = projects.first {
            activateProject(first)
        }
    }

    // MARK: - Computed

    var currentProjectPath: String? { projectPath }

    var currentSynapsePath: String? {
        guard let root = projectPath else { return nil }
        return (root as NSString).appendingPathComponent(".synapse")
    }

    // MARK: - Multi-project API

    /// Open a system folder picker and add the chosen folder as a new project.
    /// Activates it immediately. Returns the new project or nil on cancel/failure.
    @discardableResult
    func openProjectPicker() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your Cursor workspace folder"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return addProject(url: url)?.path
    }

    /// Add a project from a URL. Creates .synapse + templates, persists bookmark,
    /// appends to the projects list, and activates it. Returns the project or nil on failure.
    @discardableResult
    func addProject(url: URL) -> SynapseProject? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        let path = url.path
        let name = url.lastPathComponent
        // Avoid duplicates: if project with same path exists, just activate it.
        if let existing = projects.first(where: { $0.path == path }) {
            activateProject(existing)
            return existing
        }
        let project = SynapseProject(name: name, path: path, bookmarkData: bookmark)
        createSynapseFolderIfNeeded(at: url.appendingPathComponent(".synapse", isDirectory: true))
        projects.append(project)
        persistProjects()
        activateProject(project)
        return project
    }

    /// Remove a project by ID. If it was active, clears active state.
    func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        persistProjects()
        if activeProjectId == id {
            activeProjectId = nil
            projectPath = nil
            synapsePath = nil
            additionalIndexFolderPath = nil
            // Activate the next available project if any.
            if let next = projects.first {
                activateProject(next)
            }
        }
    }

    /// Activate a project: resolve its bookmark, start security scope, set active published properties.
    func activateProject(_ project: SynapseProject) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: project.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        // If stale, refresh the bookmark and re-persist.
        if isStale {
            if url.startAccessingSecurityScopedResource(),
               let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                if let idx = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[idx].bookmarkData = fresh
                    persistProjects()
                }
            }
        } else {
            guard url.startAccessingSecurityScopedResource() else { return }
        }

        activeProjectId = project.id
        projectPath = project.path
        synapsePath = (project.path as NSString).appendingPathComponent(".synapse")
        createSynapseFolderIfNeeded(at: url.appendingPathComponent(".synapse", isDirectory: true))
        loadAdditionalIndexFolder()
        loadIndexFullProject()
    }

    // MARK: - Persistence

    private func persistProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: projectsKey)
    }

    private func loadPersistedProjects() {
        guard let data = UserDefaults.standard.data(forKey: projectsKey),
              let decoded = try? JSONDecoder().decode([SynapseProject].self, from: data) else {
            return
        }
        projects = decoded
    }

    // MARK: - Legacy migration

    /// One-time migration: if no projects are saved yet but a legacy single-project bookmark exists,
    /// wrap it into a SynapseProject and save it.
    private func migrateLegacyBookmarkIfNeeded() {
        guard projects.isEmpty,
              let bookmark = UserDefaults.standard.data(forKey: legacyBookmarkKey),
              let path = UserDefaults.standard.string(forKey: legacyPathKey) else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            // Stale or invalid — drop it.
            UserDefaults.standard.removeObject(forKey: legacyBookmarkKey)
            UserDefaults.standard.removeObject(forKey: legacyPathKey)
            return
        }

        let project = SynapseProject(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            bookmarkData: bookmark
        )
        projects = [project]
        persistProjects()
        // Remove legacy keys now that we've migrated.
        UserDefaults.standard.removeObject(forKey: legacyBookmarkKey)
        UserDefaults.standard.removeObject(forKey: legacyPathKey)

        _ = url  // accessed during resolution; no explicit stop needed here
    }

    // MARK: - .synapse folder + templates

    func createSynapseFolderIfNeeded(at synapseURL: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: synapseURL.path) {
            try? fm.createDirectory(at: synapseURL, withIntermediateDirectories: true)
        }
        let skillsURL = synapseURL.appendingPathComponent("skills", isDirectory: true)
        if !fm.fileExists(atPath: skillsURL.path) {
            try? fm.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        }
        let templates: [(String, String)] = [
            ("projectbrief.md", "# Project Brief\n\nDescribe your project goals, scope, and key requirements here.\n"),
            ("activeContext.md", "# Active Context\n\n**Current Focus**\n(What you're working on right now.)\n\n**Key Decisions**\n(Recent decisions.)\n\n**Open Questions**\n(Unresolved questions.)\n"),
            ("progress.md", "# Progress\n\n## Phase 0\nPlanned / In progress.\n\n## Next\n(Milestones.)\n"),
            ("thoughts.md", "# Thoughts\n\n(Agent internal monologue – append-only log.)\n"),
            ("learnings.md", "# Learnings\n\n(Per-project learnings from memory — conventions, decisions, gotchas. Use \"Update learnings\" in Dashboard to append.)\n"),
            ("codebase.md", "# Codebase map\n\nDescribe key files and symbols here so Synapse can suggest accurate skills (correct types and names) without indexing raw source. Run Index All so this file is searchable. Keep entries concise: file path, control/type names, one-line notes.\n\n## Files\n- `path/to/MainView.swift` — One-line description.\n\n## UI / Views\n- `MainView` — Summary of role (e.g. main screen, prompt input bar).\n- For layout fixes: note the control type and binding (e.g. TextField, `$viewModel.promptForContext`) and minimal fix (e.g. `.frame(maxWidth: .infinity)`).\n\n## Services / API\n- `ServiceName` — One-line description.\n\n(Add more sections as needed: Backend, Models, etc.)\n"),
        ]
        for (name, content) in templates {
            let fileURL = synapseURL.appendingPathComponent(name)
            if !fm.fileExists(atPath: fileURL.path) {
                try? content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Additional index folder (config.json)

    func loadAdditionalIndexFolder() {
        additionalIndexFolderPath = readAdditionalIndexFolder()
    }

    /// Load indexFullProject from .synapse/config.json (call when activating a project or after writing config).
    func loadIndexFullProject() {
        indexFullProject = readIndexFullProject()
    }

    private func readAdditionalIndexFolder() -> String? {
        guard let config = readSynapseConfig() else { return nil }
        guard let folders = config["indexFolders"] as? [String],
              let first = folders.first, !first.isEmpty
        else { return nil }
        return first
    }

    private func readIndexFullProject() -> Bool {
        guard let config = readSynapseConfig() else { return false }
        return (config["indexFullProject"] as? Bool) == true
    }

    /// Read full .synapse/config.json. Returns nil if file missing or invalid.
    private func readSynapseConfig() -> [String: Any]? {
        guard let synapse = synapsePath else { return nil }
        let configPath = (synapse as NSString).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Write config merging with existing keys so indexFolders and indexFullProject are preserved.
    private func writeSynapseConfig(merging updates: [String: Any]) -> Bool {
        guard let synapse = synapsePath else { return false }
        let configPath = (synapse as NSString).appendingPathComponent("config.json")
        var dict = readSynapseConfig() ?? [:]
        for (k, v) in updates { dict[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func writeAdditionalIndexFolder(_ rel: String?) -> Bool {
        let folders: [String] = rel.map { [$0] } ?? []
        guard writeSynapseConfig(merging: ["indexFolders": folders]) else { return false }
        additionalIndexFolderPath = rel
        return true
    }

    @discardableResult
    func setIndexFullProject(_ value: Bool) -> Bool {
        guard writeSynapseConfig(merging: ["indexFullProject": value]) else { return false }
        indexFullProject = value
        return true
    }

    @discardableResult
    func openAdditionalIndexFolderPicker() -> String? {
        guard let root = projectPath else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select an additional folder to index (e.g. .Cursor). Must be inside the project folder."
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let chosen = url.standardizedFileURL.path
        let rootStd = URL(fileURLWithPath: root).standardizedFileURL.path
        guard chosen.hasPrefix(rootStd + "/") else { return nil }
        let rel = String(chosen.dropFirst(rootStd.count + 1))
        guard !rel.isEmpty, !rel.hasPrefix("..") else { return nil }
        writeAdditionalIndexFolder(rel)
        return rel
    }

    // MARK: - File ingestion

    func ingestFile(at sourceURL: URL) -> String? {
        guard let synapse = synapsePath else { return nil }
        let ingestedDir = (synapse as NSString).appendingPathComponent("ingested")
        let fm = FileManager.default
        if !fm.fileExists(atPath: ingestedDir) {
            try? fm.createDirectory(atPath: ingestedDir, withIntermediateDirectories: true)
        }
        let name = sourceURL.lastPathComponent
        let destPath = (ingestedDir as NSString).appendingPathComponent(name)
        let destURL = URL(fileURLWithPath: destPath)
        do {
            if fm.fileExists(atPath: destPath) { try fm.removeItem(at: destURL) }
            try fm.copyItem(at: sourceURL, to: destURL)
            return destPath
        } catch {
            return nil
        }
    }

    // MARK: - Memory file helpers

    func memoryFilesList() -> [(name: String, modified: Date)] {
        guard let synapse = synapsePath else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: synapse) else { return [] }
        var list: [(name: String, modified: Date)] = []
        for name in contents where (name as NSString).pathExtension.lowercased() == "md" {
            let path = (synapse as NSString).appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date {
                list.append((name: name, modified: date))
            }
        }
        let skillsDir = (synapse as NSString).appendingPathComponent("skills")
        if let skillNames = try? fm.contentsOfDirectory(atPath: skillsDir) {
            for name in skillNames where (name as NSString).pathExtension.lowercased() == "md" {
                let path = (skillsDir as NSString).appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date {
                    list.append((name: name, modified: date))
                }
            }
        }
        return list.sorted { $0.modified > $1.modified }
    }

    func thoughtsPreview(maxLines: Int = 15) -> String {
        guard let synapse = synapsePath else { return "" }
        let path = (synapse as NSString).appendingPathComponent("thoughts.md")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.components(separatedBy: .newlines).suffix(maxLines).joined(separator: "\n")
    }

    func learningsPreview(maxLines: Int = 20) -> String {
        guard let synapse = synapsePath else { return "" }
        let path = (synapse as NSString).appendingPathComponent("learnings.md")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.components(separatedBy: .newlines).suffix(maxLines).joined(separator: "\n")
    }

    /// Returns first `maxChars` of file content for a path relative to project root (e.g. ".synapse/projectbrief.md").
    func filePreview(relativePath: String, maxChars: Int = 200) -> String? {
        guard let root = projectPath else { return nil }
        var url = URL(fileURLWithPath: root)
        for component in relativePath.split(separator: "/").map(String.init) {
            url = url.appendingPathComponent(component)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = String(text.prefix(maxChars))
        if text.count > maxChars { return trimmed + "…" }
        return trimmed
    }

    // MARK: - Index staleness tracking

    func lastIndexTime(for projectId: UUID?) -> Date? {
        let key = "synapse.lastIndexTime.\(projectId?.uuidString ?? "none")"
        let interval = UserDefaults.standard.double(forKey: key)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// Record that indexAll just succeeded for a given project.
    func recordIndexTime(for projectId: UUID) {
        let date = Date()
        lastIndexTimes[projectId] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "synapse.lastIndexTime.\(projectId.uuidString)")
    }

    /// Returns true when no index has been recorded for this project, or the last index is older than `threshold`.
    func isIndexStale(for projectId: UUID, threshold: TimeInterval = 20 * 60) -> Bool {
        guard let last = lastIndexTime(for: projectId) ?? lastIndexTimes[projectId] else { return true }
        return Date().timeIntervalSince(last) > threshold
    }

    // MARK: - Project removal (legacy clear kept for compatibility)

    func clearProject() {
        if let id = activeProjectId {
            removeProject(id: id)
        } else {
            projectPath = nil
            synapsePath = nil
        }
    }
}
