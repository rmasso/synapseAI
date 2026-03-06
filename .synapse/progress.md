# Progress

## Phases (MVP)
| Phase | Status | Notes |
|-------|--------|--------|
| 0 – Skeleton | Done | Menu bar, Node bridge, ping/setProject; Jest + Swift tests |
| 1 – Project + .synapse | Done | FolderService, security-scoped bookmark; Node init + chokidar; 4 .md templates |
| 2 – Indexing | Done | db.js, chunk.js, search.js; indexFile, indexAll, search RPC; Dashboard Index All + Search |
| 3 – Drag & Query | Done | Drop .md → ingest + index; query box → prompt block + Copy |
| 4 – Injection | Done | ⌘⇧P fixed (postToPid, lastChatPrompt query); AX kAXSelectedTextAttribute; "Paste into [App]" button |
| 5 – Grok skills | Done | suggestSkill RPC, grok.js; Dashboard API key + Suggest skill + token count |
| 6 – Dashboard polish | Done | Chat-style UI, token savings, learnings, clear history, collapsible settings |

## What Works
- Menu bar app (no dock); Open Dashboard = single window; New Project creates .synapse/ and templates (including learnings.md, codebase.md).
- Node bridge: ping, setProject, indexAll, indexFile, search, suggestSkill, suggestLearnings, buildContextForPrompt, **buildSubagentContext**, getStats; fileChanged notifications.
- **Chat-style Dashboard:** type a prompt → full-screen ProcessAnimationView during API call → chat shows only **user prompt + final block** (skill-format or subagent). No FTS hit bubbles. Block automatically on clipboard. Fallback: legacy @file block if Grok fails.
- **Subagent context:** Second button in prompt bar (person.2) builds memory-heavy context for a parallel agent; primary=.synapse memory, secondary=code snippets; result in orange bubble, copied to clipboard.
- Token savings: block bubble shows "Skill prompt · X of Y chunks · ~N tokens saved" when Grok filtered chunks.
- **⌘⇧P injection fixed:** captures target app pid before async work; uses `CGEvent.postToPid` for reliable ⌘V delivery; uses last Dashboard chat prompt as search query.
- **"Paste into [App]" button:** appears in Dashboard input bar when a block + target app are known; one-tap re-paste.
- **Clear history button:** trash capsule in chat area clears all messages; shows "Cleared" feedback.
- **ProcessAnimationView:** Full-screen centered loading with step-by-step process (memory search, codebase scan, skill checks); clears chat during API call.
- **Button feedback:** Copy/Done/Paste/Clear show animated "Copied", checkmark, etc.
- **Delete confirmation:** Remove project shows "Delete Project?" alert before removal.
- **Add project + tab:** + icon as rightmost tab; 2-step sheet (project + skills folder).
- **Chat empty state:** Feature descriptions with icons (Generate Skill, Subagent, Refine).
- Grok strict selection: 1–3 chunks preferred, domain isolation, ~300 token cost awareness.
- Grok suggests/creates skill .md in .synapse/skills/; indexed; token count in Dashboard.
- **Learnings:** .synapse/learnings.md template; "Update learnings" in Dashboard (Tools & Settings) runs Grok over project memory and appends dated bullets to learnings.md; preview in Dashboard; Cursor instructions mention learnings.md.
- **Codebase map:** `.synapse/codebase.md` template (key files, UI controls, services); Grok gets correct types/names without indexing raw source; filled in for Synapse project itself.
- **Additional index folder:** select any folder inside project (e.g. `.Cursor`) in Tools & Settings; stored in `.synapse/config.json`; indexed by Index All alongside `.synapse/`.
- **Onboarding:** 4-step guided sheet (project, extra folder, index, API key); "Set up…" button in status bar when no project set.
- **Index All creates missing templates:** `initSynapseFolder` called in Node's `indexAll`; `loadStoredBookmark` calls Swift `createSynapseFolderIfNeeded` — existing projects get new templates on app open.
- **Dashboard memory list refreshes after Index All** (was missing; `refreshFolderContent` now called on success).
- Drag & drop .md → ingest + index; success/error feedback; DB size in status bar.
- DB persistence across restarts via `restoreProjectInNodeIfNeeded`.

## What's Left / Known Issues
- **AX stability:** `kAXSelectedTextAttribute` may break on future Cursor/Electron updates; monitor and adjust roles as needed.
- **node/index.js not found** – Set Working Directory in Xcode Run scheme (Options → Working Directory = repo root) or use `SYNAPSE_NODE_SCRIPT` env var, or "Locate node/index.js…" button in Dashboard settings.
- **MetalTools / DetachedSignatures** – Console noise; harmless.
- **ViewBridge to RemoteViewService Terminated** (Code=18) – System message; benign.
- **Grok model** – Uses `grok-code-fast-1`; if 404, verify API key and endpoint at console.x.ai.
- **`@AppStorage` in ViewModel** – Works but is SwiftUI-only; move to `UserDefaults` direct read/write if class needs to run off-main-actor in future.
- **Phase 2:** domain subfolders, local LLM, Cursor token tracking, PDF/.txt ingestion, auto-write .synapse memory.

- **Multi-project tabs:** `SynapseProject` model; `FolderService` manages list + migration from single-project; `DashboardView` = `TabView` shell + `ProjectDashboardContent` per tab (isolated `DashboardViewModel`); tab switch activates project + calls `nodeBridge.setProject`; "Remove" button per project; hidden files enabled in folder picker.

- **Skill format cleaned:** `buildSkillFormatPrompt` outputs YAML + `## Instructions` + `## Examples` only; no `## Troubleshooting`.
- **Stale index banner:** orange two-line banner appears when project not indexed (or 20+ min since last index); fires without user interaction via 60 s timer; includes AI prompt hint; `isIndexStale` now correctly returns `true` on never-indexed projects.
- **Suggest skill on no tags:** after `indexAll`, if additional folder has no tag-bearing chunks → surfaces "Generate Skill" prompt in Tools & Settings.
- **Shift+Return → Send:** keyboard shortcut now triggers `buildContextForPrompt` (was `optimizePrompt`).
- **`recordIndexTime` fixed:** `openProject()` and add-project sheet "Done" button now record index time so stale banner clears correctly after those flows.

- **GitHub repo:** Initialized git, wrote marketing README, pushed to `https://github.com/rmasso/Synapse` (55 files). `.gitignore` excludes `.cursor/`, `.synapse/*.db`, `.synapse/config.json`. Target repo: `rmasso/synapseAI`.
- **Stale banner AI hint (planned):** Strengthen primary line to say "ask your AI to update the .synapse memory folder"; add same hint to Index All tooltip when stale. Pending implementation in `DashboardView.swift`.

## Next
- Push to `rmasso/synapseAI` GitHub repo (switch remote or re-push).
- Implement stale banner AI hint in `DashboardView.swift` (two edits: `staleBanner` text + Index All `.help()` tooltip).
- Phase 2 scope definition when ready.
