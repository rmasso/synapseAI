# Synapse – Neural Memory Injection for Cursor Agents

**Inject structured memory straight into your Cursor agent's brain — no bloat, no context rot, just smarter code.**

Synapse is a macOS menu-bar app that turns your project knowledge into high-quality, Cursor-ready "skill" blocks (YAML frontmatter + Instructions + Examples) and auto-injects them into Cursor Composer via ⌘⇧P. It maintains a `.synapse/` memory folder per project (projectbrief, activeContext, progress, learnings, skills), indexes everything with SQLite + BM25, and surfaces only the relevant slice when you need it.

---

### Why it matters in 2026

- **Context window stays lean** — Enriched prompts stay under 2 KB while packing domain knowledge, code snippets, and defensive process. Sessions run 2–4× longer before degradation.
- **Higher agent success rate** — Structured format (YAML triggers, tags, numbered steps) guides agents to precise, first-try execution with built-in pitfall avoidance.
- **Zero repo pollution** — Ephemeral prompts copy to clipboard or auto-inject via Accessibility API. No files left behind unless you choose to save.
- **Per-project memory** — `.synapse/` lives in your workspace: projectbrief, activeContext, progress, learnings.md, codebase.md, and skills/.

---

### Key Features

| Feature | Description |
|---|---|
| ⌘⇧P Injection | Captures focused Cursor window, pastes skill block at caret (AX + clipboard fallback) |
| Skill prompt builder | Grok generates YAML + Instructions + Examples block from your prompt + indexed memory |
| Subagent context | Memory-heavy context package for parallel agent runs |
| Multi-project tabs | Switch projects; each has isolated chat history and `.synapse/` index |
| Learnings updater | One click: Grok reads memory and appends dated bullets to `learnings.md` |
| Stale index banner | Orange warning when memory >20 min old; prompts you to re-index or ask AI to update |
| Additional index folder | Index `.cursor/`, `.Cursor/`, or any folder alongside `.synapse/` |
| Shift+Return | Refines your prompt via Grok before sending |

---

### Quick Start

1. Requires **macOS 15.1+**, **Xcode 16+**, **Node.js 18+**
2. Clone the repo and open `SynapseAI/SynapseAI.xcodeproj` in Xcode
3. `cd node && npm install`
4. Edit Scheme → Run → Options → set **Working Directory** to the repo root (so Xcode finds `node/index.js`)
5. Build and run — the app appears in the menu bar (no dock icon)
6. Click the icon → **Open Dashboard** → add your project → **Index All**
7. Type a prompt → get a structured skill block → ⌘⇧P injects it into Cursor

> Alternatively, set `SYNAPSE_NODE_SCRIPT` env var to the full path of `node/index.js`.

---

### How the memory layer works

```
Your project workspace/
└── .synapse/
    ├── projectbrief.md       ← scope, goals, decisions
    ├── activeContext.md      ← current focus, recent changes
    ├── progress.md           ← what works, what's left
    ├── learnings.md          ← conventions, gotchas (Grok-maintained)
    ├── codebase.md           ← key files and symbols map
    ├── thoughts.md           ← agent internal monologue
    ├── skills/               ← generated skill-*.md files
    └── synapse.db            ← SQLite + FTS5 index
```

You (or your AI in Cursor) maintain the `.synapse/` files. Synapse indexes them and injects the right slice into Cursor when you hit ⌘⇧P or use the Dashboard.

---

### Project Structure

```
Synapse/
├── SynapseAI/          SwiftUI macOS app (menu-bar, MVVM)
│   └── SynapseAI/
│       ├── Features/   Dashboard, Injection, Hotkey
│       ├── Services/   FolderService, NodeBridge, Accessibility
│       └── Models/     SynapseProject, ChatMessage
├── node/               Node.js bridge (JSON-RPC over stdio)
│   ├── index.js        RPC dispatcher
│   ├── db.js           SQLite + FTS5
│   ├── chunk.js        ~1200 char chunking
│   ├── grok.js         Grok API (skill builder, subagent, learnings)
│   ├── search.js       BM25 search
│   └── synapse-init.js Template scaffolding
├── .synapse/           Synapse's own memory (dogfooded)
└── Synapse_PRD.md      Full product spec
```

---

### Requirements

- macOS 15.1+
- Xcode 16+
- Node.js 18+
- [Grok API key](https://console.x.ai) (xAI) for skill generation and learnings

---

### Roadmap

- **Phase 1 (done)** — Menu-bar app, injection, multi-project, learnings, skills, subagent context
- **Phase 2** — Domain subfolders, local LLM (Qwen/Ollama), Cursor token tracking, PDF/txt ingestion
- **Phase 3** — Multi-agent conflict resolution, voice commands, brain snapshot export

---

Open source under MIT. Contributions welcome — fork, PR, build the future of agentic coding.

Star if you're done fighting context rot in Cursor.
