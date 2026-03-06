# Codebase map

Describe key files and symbols here so Synapse can suggest accurate skills (correct types and names) without indexing raw source. Run Index All so this file is searchable. Keep entries concise: file path, control/type names, one-line notes.

## Files
- `SynapseAI/SynapseAI/Models/SynapseProject.swift` — `Identifiable, Codable, Equatable`; `id: UUID`, `name`, `path`, `bookmarkData: Data`. Persisted as JSON array in UserDefaults `"synapse.projects"`.
- `SynapseAI/SynapseAI/App/SynapseAIApp.swift` — App entry; `restoreProjectInNodeIfNeeded()`, `runInjection()`, hotkey registration, `lastChatPrompt`.
- `SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift` — Outer `DashboardView`: thin `TabView` shell; `selectedProjectId: UUID?`; `onChange` activates project + calls `nodeBridge.setProject`. Inner `ProjectDashboardContent` (private): owns `@StateObject DashboardViewModel`; compactStatusBar, chatArea, promptInputBar, settingsToggleBar, settingsForm, onboardingSheet; "Remove" button; refreshes on `folderService.activeProjectId` change.
- `SynapseAI/SynapseAI/Features/Dashboard/DashboardViewModel.swift` — Chat state, `promptForContext`, `buildContextForPrompt`, `buildSubagentContext`, `optimizePrompt`, learnings, `indexAll(nodeBridge:folderService:)`, onboarding state (`onboardingCompleted` @AppStorage, `showOnboarding`), `selectAdditionalFolder`, `clearAdditionalFolder`, `@AppStorage("synapse.maxChunksForPrompt")`, `isOptimizingPrompt`.
- `SynapseAI/SynapseAI/Services/NodeBridgeService.swift` — JSON-RPC to node; all RPCs including `optimizePrompt`; `lastInjectedBlock`, `lastTargetApp`.
- `SynapseAI/SynapseAI/Services/FolderService.swift` — Multi-project: `projects: [SynapseProject]`, `activeProjectId: UUID?`; `addProject(url:)`, `removeProject(id:)`, `activateProject(_:)`, `persistProjects()`, `loadPersistedProjects()`, migration from legacy bookmark. Index staleness: `lastIndexTimes: [UUID: Date]`, `recordIndexTime(for:)`, `isIndexStale(for:threshold:)` (20 min default). Active-project props: `projectPath`, `synapsePath`, `additionalIndexFolderPath`; `openAdditionalIndexFolderPicker()` (`showsHiddenFiles = true`); `writeAdditionalIndexFolder(_:)`, `config.json` (indexFolders).
- `node/index.js` — JSON-RPC dispatch; `indexAll` reads `config.json` and indexes extra folders; calls `initSynapseFolder` before indexing. RPCs: buildContextForPrompt, buildSubagentContext, optimizePrompt (params: projectPath, apiKey, userPrompt).
- `node/synapse-init.js` — `initSynapseFolder(rootPath)`: creates `.synapse/`, `skills/`, and all template files if missing (projectbrief, activeContext, progress, thoughts, learnings, codebase).
- `node/grok.js` — `buildSkillFormatPrompt`, `buildSubagentContext`, `suggestChunksForPrompt(maxChunks?)`, `optimizePrompt(apiKey, userPrompt, memorySnippets)`; senior-engineer system prompts.

## UI / Views
- `DashboardView` — SwiftUI; `compactStatusBar` (project name, chunk count, "Set up…" when no project), `chatArea` (ScrollView + bubbles), `promptInputBar`, `settingsToggleBar`, `settingsForm`. + tab as sentinel for add-project; `addProjectSheet` 2-step (project root + skills folder). Stale tab icon (`exclamationmark.triangle`) when index >20 min old.
- `ProcessAnimationView` — Full-screen centered loading during API calls; step-by-step process display.
- `AnimatedCopyButton`, `AnimatedActionButton` — Copy/Done/Paste/Clear with feedback ("Copied", checkmark).
- Prompt input: `TextField("Ask about your project…", text: $viewModel.promptForContext, axis: .vertical)` inside an HStack in `promptInputBar`. `.frame(maxWidth: .infinity, alignment: .leading)` on the TextField for full-width text wrapping.
- Onboarding sheet: `onboardingSheet` private var; `@State private var showOnboardingSheet = false`; triggered by "Set up…" in `compactStatusBar` or "Set up project…" in chat empty state.
- Tools & Settings: "Additional index folder" section shows `folderService.additionalIndexFolderPath`, "Select folder…" and "Clear" buttons.

## Services / API
- `NodeBridgeService` — RPCs: ping, setProject, indexAll, indexFile, search, buildContextForPrompt, buildSubagentContext, suggestSkill, suggestLearnings, getStats; `lastInjectedBlock`, `lastTargetApp`, `lastInjectionDate`.
- `FolderService` — project root, security-scoped bookmark; `createSynapseFolderIfNeeded` (called from `setProject(url:)` AND `loadStoredBookmark`); `additionalIndexFolderPath` (from `.synapse/config.json` `indexFolders[0]`); `memoryFilesList()`, `thoughtsPreview()`, `learningsPreview()`.

(Add more sections as needed.)
