# Progress

## Phases (MVP Plan)
| Phase | Status | Notes |
|-------|--------|--------|
| 0 – Skeleton | Done | Menu bar, Node bridge, ping/setProject; Jest + Swift tests |
| 1 – Project + .synapse | Done | FolderService, security-scoped bookmark; Node init + chokidar; 4 .md templates |
| 2 – Indexing | Done | db.js, chunk.js, search.js; indexFile, indexAll, search RPC; Dashboard Index All + Search |
| 3 – Drag & Query | Done | Drop .md → ingest + index; query box → prompt block + Copy |
| 4 – Injection | Done | ⌘⇧P, HotkeyService, AccessibilityService; paste or clipboard |
| 5 – Grok skills | Done | suggestSkill RPC, grok.js; Dashboard API key + Suggest skill + token count |
| 6 – Dashboard polish | Done | Last injection, memory files list, thoughts preview, Form + Sections UI |

## What Works
- Menu bar app (no dock); Open Dashboard opens single window; New Project creates .synapse/ and templates (incl. learnings.md).
- Node bridge: ping, setProject, indexAll, indexFile, search, suggestSkill, suggestLearnings, **buildContextForPrompt** (skill-format), **buildSubagentContext**; fileChanged notifications.
- **Send (skill-format):** FTS → hit bubbles → Grok builds single skill.md (userPrompt + dbSnippets + memorySnippets); block bubble "Skill prompt · X of Y chunks"; legacy @file block fallback if Grok fails.
- **Subagent context:** Second prompt-bar button; memory-heavy Grok output for parallel agent; orange bubble, token counts, Copy.
- ⌘⇧P uses last Dashboard prompt; pastes into Cursor or clipboard; "Paste into [App]" when target app known.
- Grok suggests/creates skill .md in .synapse/skills/; Update learnings appends to learnings.md from memory.
- UI: Chat-style Dashboard (user/hit/block/subagentContext/error), collapsible Tools & Settings, token usage.

## What’s Left / Known Issues
- **node/index.js not found** – User must set Working Directory or SYNAPSE_NODE_SCRIPT when running from Xcode.
- **MetalTools / DetachedSignatures** – Console noise from system; harmless.
- **Multiple Dashboard windows** – Fixed by reusing window with title "Dashboard" before openWindow.
- Phase 2 (post-MVP): domain subfolders, local LLM toggle, Cursor token tracking, etc. (see PRD).

## Current Status
MVP feature-complete. Skill-format prompt and subagent context shipped. Memory bank at `memory-bank/`; .synapse/ per project. Next: UX/stability polish; Phase 2 scope when ready.
