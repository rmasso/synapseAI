# Active Context

## Current Focus
- **Synapse MVP** – Neural memory injection for Cursor; SwiftUI menu-bar app + Node bridge.
- **Memory Bank** – This `memory-bank/` folder at repo root holds project-level context for AI and humans; per-project runtime memory lives in each workspace’s `.synapse/`.

## Key Decisions (Locked In)
- **No local LLM in MVP** – Grok API for skill creation; add Qwen/Ollama in Phase 2.
- **BM25 via better-sqlite3 + FTS5** – No embeddings in MVP.
- **Injection** – macOS Accessibility API into Cursor; clipboard fallback if AX fails.
- **.synapse/ per project** – `projectbrief.md`, `activeContext.md`, `progress.md`, `thoughts.md`, `skills/`; one SQLite DB per project (`.synapse/synapse.db`).
- **MVVM** – Swift: Views → ViewModels → Services (NodeBridge, Folder, Accessibility, Hotkey).
- **Node bridge** – JSON-RPC over stdio; one Node process per app lifecycle; path to script via Working Directory or `SYNAPSE_NODE_SCRIPT`.

## Open Questions
- Cursor Composer AX element stability across Cursor updates (test on current versions).
- Optimal .md chunk size (e.g. 300–800 tokens); currently ~1200 chars in `chunk.js`.
- Grok token estimation formula for cost display.

## Recent Changes
- **Skill-format prompt & subagent context:** (1) Main Send returns a single **skill.md** from Grok (YAML + Instructions/Examples/Troubleshooting, 800–1800 chars); inputs: user prompt + DB chunks + memory snippets. Legacy @file block fallback if Grok fails. (2) **Subagent context:** second button in prompt bar; memory-heavy context for parallel agent; Node buildSubagentContext RPC; ChatMessage.subagentContext; orange bubble.
- Dashboard and Menu Bar UI modernized (Form + Sections, SF Symbols, Apple-style layout).
- Window title fixed: `WindowGroup("Dashboard", id: "dashboard")` so “Open Dashboard” reuses one window.
- Memory bank created at `memory-bank/` with projectbrief, productContext, activeContext, systemPatterns, techContext, progress.

## Last Injection
⌘⇧P uses last Dashboard prompt; skill-format block or legacy block on clipboard; Paste into [App] when target app known. Subagent context via second prompt-bar button.
