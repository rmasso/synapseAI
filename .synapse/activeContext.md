# Active Context

## Current Focus
- **Synapse MVP** – Neural memory injection for Cursor; SwiftUI menu-bar app + Node bridge.
- **Memory** – Project-level context lives in `.synapse/` (this folder); per-workspace runtime memory in each project's `.synapse/`.

## Key Decisions (Locked In)
- **No local LLM in MVP** – Grok API for skill creation / context building; Qwen/Ollama in Phase 2.
- **BM25 via better-sqlite3 + FTS5** – No embeddings in MVP.
- **Injection** – macOS Accessibility API into Cursor; clipboard + targeted ⌘V fallback (CGEvent.postToPid).
- **.synapse/ per project** – projectbrief, activeContext, progress, thoughts, learnings.md, skills/; one SQLite DB per project (`.synapse/synapse.db`).
- **MVVM** – Swift: Views → ViewModels → Services (NodeBridge, Folder, Accessibility, Hotkey).
- **Node bridge** – JSON-RPC over stdio; one Node process per app lifecycle; script path via Working Directory or `SYNAPSE_NODE_SCRIPT`.
- **Swift ↔ Node** – Single process; request/response by `id`; notifications (e.g. fileChanged) no `id`. Chunking ~1200 chars; FTS5 + bm25 search; Dashboard reuses one window (title "Dashboard").
- **Grok selection** – MAX_CHUNKS_FOR_PROMPT user-configurable (default 5, slider 1–10 in Dashboard); strict relevance rules; AVG_TOKENS_PER_CHUNK = 300; reply max_tokens = 512.

## Open Questions
- Cursor Composer AX element stability across Cursor updates (kAXSelectedTextAttribute may also break on Electron updates).
- Optimal chunk size; currently ~1200 chars (~300 tokens) in `chunk.js`.
- Phase 2 scope: local LLM, domain subfolders, Cursor token tracking.

## Recent Changes

### Dashboard UX polish (Mar 2026)
- **ProcessAnimationView:** Full-screen centered loading animation during API calls; clears chat area and shows large, prominent step-by-step process (memory search, codebase scan, skill checks, etc.). Cycles every 1.5 s with distinct steps for buildContext, subagent, and optimizePrompt flows.
- **Chat only user + final:** After API response, chat shows only the user's original prompt and the final result (skill block, subagent context, or optimized prompt). FTS hit bubbles no longer added; `buildContextForPrompt` skips appending hits. `optimizePrompt` on success clears chat and shows [user, optimized].
- **Button feedback:** `AnimatedCopyButton` and `AnimatedActionButton` — Copy/Done/Paste/Clear show "Copied", checkmark, etc. with spring animations.
- **Delete confirmation:** Remove button shows `.alert` "Delete Project?" with destructive/cancel before `removeProject`.
- **Add project flow:** + icon as sentinel tab (right of project tabs); 2-step `addProjectSheet` (project folder + skills folder); Done triggers Index All.
- **Chat empty state marketing:** When project set, shows feature descriptions with icons: Generate Skill Prompt (arrow.up), Subagent Context (person.2), Refine Prompt (wand.and.stars + Shift+Return).

### Grok senior engineer prompts + MAX_CHUNKS_FOR_PROMPT slider (Mar 2026)
- **Senior engineer directives:** `buildSkillFormatPrompt` and `buildSubagentContext` system prompts rewritten with 7 explicit directives: address AI as senior engineer, clarity/conciseness, exact context preservation, flawless execution, ambiguity elimination, risk mitigation, domain isolation.
- **Configurable MAX_CHUNKS_FOR_PROMPT:** `suggestChunksForPrompt(apiKey, userPrompt, descriptions, maxChunks?)` now accepts an optional cap. `buildContextForPrompt` and `buildSubagentContext` RPCs accept `params[2]` as `maxChunks`. `NodeBridgeService` forwards it. `DashboardViewModel` stores `@AppStorage("synapse.maxChunksForPrompt") var maxChunksForPrompt: Int = 5`. `DashboardView` adds a slider (1–10, step 1) in a new "Context Settings" section inside Tools & Settings.

### Skill-format prompt and subagent context (Feature 1 & 2)
- **Feature 1 – Main Send:** `buildContextForPrompt` now uses Grok to produce a **single skill.md-format** document (YAML frontmatter + ## Instructions, ## Examples, ## Troubleshooting, 800–1800 chars). Inputs: user prompt + DB snippets (selected chunks) + **memory snippets** (projectbrief, activeContext, progress, thoughts, learnings via `readSynapseFilesAsContext`). Node: `dbSnippets` from chunks + `memorySnippets` from grok; `grok.buildSkillFormatPrompt`; on failure, legacy @file block fallback. Block bubble label: "Skill prompt · X of Y chunks selected · copied to clipboard".
- **Feature 2 – Subagent context:** New flow for parallel subagent: memory-heavy context package. Node: `buildSubagentContext` RPC; loads full memory (incl. learnings.md), smaller DB set (limit 10, 8K chars); `grok.buildSubagentContext` with primary=.synapse memory, secondary=code snippets. Swift: `NodeBridgeService.buildSubagentContext(apiKey:userPrompt:)`; ViewModel `buildSubagentContext(apiKey:nodeBridge:)`; `ChatMessage.Kind.subagentContext(inputTokens, outputTokens)`. Dashboard: second button (person.2 icon) "Subagent context" in prompt bar; orange bubble "Subagent context · copied to clipboard" with token counts. Same prompt field; two actions: Send (skill prompt) vs Subagent context.
- **Grok (node/grok.js):** `readSynapseFilesAsContext` now includes `learnings.md`; exported. `buildSkillFormatPrompt(apiKey, userPrompt, dbSnippets, memorySnippets)`; `buildSubagentContext(...)` same args, memory-first system prompt.

### Chat-style Dashboard (DashboardView + DashboardViewModel rewrite)
- `ChatMessage` struct with 5 kinds: `.user`, `.hit(path, startLine, endLine)`, `.block(chunkCount, totalAvailable, estimatedSavedTokens)`, `.subagentContext(inputTokens, outputTokens)`, `.error`.
- Layout: compact status bar | scrollable chat (ScrollViewReader + VStack) | sticky prompt input | collapsible "Tools & Settings" Form.
- **Root cause fix for search results not displaying:** was a `List` nested inside `Section` inside `Form`; replaced with chat bubbles in a plain `ScrollView` — no nested scrollable containers.
- `buildContextForPrompt` now: (1) FTS search (hits not shown), (2) Grok block if key present → block bubble, (3) FTS fallback block otherwise. Chat shows only [user, block]. Always copies block to clipboard.
- "Clear" button (trash capsule, top-right of chat area); `clearChatHistory()` in ViewModel.
- "Paste into [App]" button above input bar, shown when `lastInjectedBlock` + `lastTargetApp` are both set.

### Token savings display
- `node/index.js` `buildContextForPrompt` reply now includes `totalDescriptions` and `estimatedSavedTokens = (total − selected) × 300`.
- `NodeBridgeService.buildContextForPrompt` return tuple extended with both fields.
- Block chat bubble shows "X of Y chunks selected · ~N tokens saved vs. full context" in green when savings > 0.

### Grok system prompt hardened
- New system prompt: 5 strict numbered rules — direct/certain relevance only, aim 1–3 chunks, ~300 token cost per chunk, explicit exclusion list, domain isolation (UI→UI, backend→backend).
- `MAX_CHUNKS_FOR_PROMPT` 6 → 5; Grok reply `max_tokens` 1024 → 512.

### ⌘⇧P hotkey fix (two root causes)
- **Bug 1 – wrong query:** was reading clipboard as search query; now uses `SynapseAIApp.lastChatPrompt` (set when user sends prompt in Dashboard chat), fallback `"context"`.
- **Bug 2 – timing of ⌘V target:** was posting to `cghidEventTap` after async await (focus may have shifted); now captures `NSWorkspace.shared.frontmostApplication.processIdentifier` *synchronously before* the first `await`, then uses `CGEvent.postToPid(_:)` to deliver ⌘V to that specific process.
- Removed `window.makeKeyAndOrderFront(nil)` on failure (was stealing focus before ⌘V).

### AccessibilityService overhaul
- `pasteIntoApp(text:targetPid:)` — new primary API: activates target app, 80 ms wait, tries AX insert, falls back to `postToPid` ⌘V.
- AX insert tries `kAXSelectedTextAttribute` first (inserts at caret; works in more Electron builds), then `kAXValueAttribute`.
- `simulateCmdV(targetPid:)` — uses `postToPid` when pid available; `cghidEventTap` as legacy fallback.

### NodeBridgeService additions
- `@Published lastInjectedBlock: String` — updated on every injection (⌘⇧P and Dashboard chat).
- `@Published lastTargetApp: (name, pid)?` — tracks last non-Synapse frontmost app via `NSWorkspace.didActivateApplicationNotification`.

### Learnings (per-project from memory)
- **learnings.md** — New template in `.synapse/` (Node synapse-init + Swift FolderService). Stores per-project learnings (conventions, decisions, gotchas) extracted from memory.
- **Update learnings** — Dashboard section "Learnings": button calls `suggestLearnings` RPC. Grok reads projectbrief, activeContext, progress, thoughts (and existing learnings to avoid duplicates), returns 5–12 bullets, appended to learnings.md with date header; file re-indexed.
- **Node:** `grok.suggestLearnings(apiKey, projectRoot)`; `index.js` RPC `suggestLearnings`; Swift `NodeBridgeService.suggestLearnings(apiKey:)`, ViewModel `updateLearnings(apiKey:nodeBridge:folderService:)`, FolderService `learningsPreview(maxLines:)`. Cursor instructions updated to mention learnings.md.

### Codebase map (codebase.md)
- Added `codebase.md` to `TEMPLATES` in `node/synapse-init.js` and to `createSynapseFolderIfNeeded` in `FolderService.swift`.
- `.synapse/codebase.md` filled in with Synapse's key files, UI controls (prompt TextField, `$viewModel.promptForContext`, `.frame(maxWidth:.infinity)`), and services.
- `DashboardView.swift` Cursor instructions updated to list `codebase.md`.
- `node/grok.js` system prompt hardened: skill builder scoped to user's specific task only (not a generic overview).
- `node/index.js` `buildContextForPrompt` passes `optimizedPrompt` to `buildSkillFormatPrompt` when available.

### Additional index folder + Onboarding
- `FolderService.swift`: `additionalIndexFolderPath` (@Published), `loadAdditionalIndexFolder()`, `readAdditionalIndexFolder()`, `writeAdditionalIndexFolder(_:)`, `openAdditionalIndexFolderPicker()` — reads/writes `.synapse/config.json` (`indexFolders` array, relative paths only, must be inside project root).
- `DashboardViewModel.swift`: `extraFolderSuccess/Error`, `onboardingCompleted` (@AppStorage), `showOnboarding`, `selectAdditionalFolder(folderService:)`, `clearAdditionalFolder(folderService:)`. Added `import SwiftUI` (required for `@AppStorage`).
- `DashboardView.swift`: 4-step `onboardingSheet` (Select Project → Add Optional Folder → Index All → Grok Key); "Set up…" button in status bar when no project; "Additional index folder" section in Tools & Settings.
- `node/index.js` `indexAll`: after indexing `.synapse/`, reads `config.json`, walks extra folder(s) for `.md` files, indexes them alongside `.synapse/`.
- `node/synapse-init.js` `initSynapseFolder`: now called at start of `indexAll` (creates any missing templates before indexing).

### Bug fixes (Mar 2026)
- `FolderService.loadStoredBookmark()` now calls `createSynapseFolderIfNeeded` immediately after security-scoped access — existing projects get missing template files (e.g. `codebase.md`) on app open, without waiting for the Node bridge.
- `DashboardViewModel.indexAll(nodeBridge:folderService:)` now calls `refreshFolderContent` on success so the memory files list updates in the UI immediately after indexing.
- `DashboardViewModel.swift` added `import SwiftUI` — fixes build error from `@AppStorage` with only `Foundation`/`AppKit` imported.

### Multi-project tab interface (Mar 2026)
- **`SynapseProject.swift`** (new model): `Identifiable, Codable, Equatable` struct with `id: UUID`, `name: String`, `path: String`, `bookmarkData: Data`. Stored in `Models/`.
- **`FolderService.swift`** extended to multi-project: `@Published projects: [SynapseProject]`, `activeProjectId: UUID?`; `addProject(url:)` (creates .synapse, deduplicates, persists, activates); `removeProject(id:)` (clears active state, activates next); `activateProject(_:)` (resolves bookmark, starts security scope, sets projectPath/synapsePath, refreshes additional folder); `persistProjects()` / `loadPersistedProjects()` to `UserDefaults "synapse.projects"`; one-time migration from legacy single-project bookmark on first launch. `openProjectPicker()` now calls `addProject(url:)`.
- **`DashboardView.swift`** refactored: outer `DashboardView` is now a thin `TabView` shell (one tab per `SynapseProject`; fallback "Synapse" tab when empty); `onChange(of: selectedProjectId)` activates project + calls `nodeBridge.setProject`; `onChange(of: folderService.activeProjectId)` syncs tab selection when project added. All content moved to `ProjectDashboardContent` (private struct, `@StateObject DashboardViewModel` per instance = isolated chat history per tab); refreshes ViewModel when its project becomes active via `onChange(of: folderService.activeProjectId)`. "Remove" button in status bar removes current project.
- `SynapseAIApp.restoreProjectInNodeIfNeeded` unchanged — reads `folderService.projectPath` which `activateProject` still sets correctly. ✓
- **NSOpenPanel hidden files:** `openAdditionalIndexFolderPicker()` now sets `panel.showsHiddenFiles = true` — dotfolders (`.cursor`, `.Cursor`, etc.) now visible in picker.

### Skill format + UX polish (Mar 2026)
- **`buildSkillFormatPrompt` output format:** changed from `## Steps / ## Context / ## If Blocked` to `## Instructions` + `## Examples` only. YAML frontmatter keys updated to `name`/`description`. `## Troubleshooting` explicitly excluded in both system prompt and user message. 800–1800 char limit retained.
- **`suggestSkillOnNoTags`:** `DashboardViewModel` gains `@Published var suggestSkillOnNoTags: Bool = false`. After `indexAll` succeeds, if `additionalIndexFolderPath != nil`, searches `"tags:"` via FTS; if empty → sets flag. `clearAdditionalFolder` and `suggestSkill` (on success) reset it to `false`. UI: conditional `VStack` in "Additional index folder" section showing an orange sparkles label + "Generate Skill" button (disabled if no API key).
- **Stale index banner:** `FolderService.isIndexStale` now returns `true` when no index time is recorded (was `false` — banner never showed on fresh sessions). `ProjectDashboardContent` gains `@State private var now = Date()` updated every 60 s via `Timer.publish` — banner re-evaluates without user interaction. Banner is a two-line `VStack`: warning line + "Index Now" button + dimmer hint line `"Ask your AI: 'Update my .synapse memory folder (projectbrief, activeContext, progress, codebase).'"`. Shown between status bar and chat Divider when `isStale`.
- **`recordIndexTime` coverage fix:** `openProject()` and the "Done" button in the add-project sheet called `nodeBridge.indexAll()` directly — now both call `folderService.recordIndexTime(for: activeProjectId)` after success.
- **Shift+Return → `optimizePrompt`:** `.onKeyPress` on prompt TextField: Shift+Return refines prompt via Grok (`optimizePrompt`); same guard conditions as Send (non-empty, no in-flight). Normal Return inserts newline.

### GitHub repo + README (Mar 6, 2026)
- **Git repo initialized:** First commit — 55 files across `SynapseAI/`, `node/`, `.synapse/`, `memory-bank/`.
- **`.gitignore` updated:** Added `.cursor/` (separate git repo — `rmasso/cursorFolder`), `.synapse/*.db`, `.synapse/config.json`.
- **README rewritten:** Marketing front page with hero tagline, "Why it matters in 2026" section, feature table, Quick Start, `.synapse/` memory structure diagram, project structure tree, roadmap (Phase 1 done / Phase 2-3 ahead).
- **GitHub:** Public repo at `https://github.com/rmasso/Synapse`; user also has `rmasso/synapseAI` repo (target for future pushes).

### Stale banner AI hint (planned, Mar 6, 2026)
- **Plan created:** Strengthen primary stale warning line to mention asking AI to update `.synapse/`; add AI prompt hint to Index All button tooltip when stale.
- **File:** `DashboardView.swift` — two edits: primary `staleBanner` text + `.help()` tooltip on Index All.
- **Status:** Plan confirmed, not yet implemented.

## Last Injection
⌘⇧P hotkey injection fixed (see above). "Paste into [App]" button in Dashboard provides manual trigger when hotkey is unreliable.
