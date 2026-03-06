# Tech Context

## Technologies Used
| Layer | Choice |
|-------|--------|
| App | SwiftUI (macOS 15.1+); AppKit where needed (NSOpenPanel, NSPasteboard, NSApp, AX API) |
| Node bridge | Node.js 18+; stdio JSON-RPC; chokidar, better-sqlite3 |
| DB | SQLite + FTS5 (one DB per project: `.synapse/synapse.db`) |
| AI | Grok API (xAI chat completions) for skill generation |
| Cursor paste | macOS Accessibility API (AXUIElement); clipboard fallback |
| Hotkey | NSEvent.addGlobalMonitorForEvents (global ⌘⇧P) |

## Repo Layout
```
Synapse/
├── memory-bank/           # This folder – project-level context
│   ├── projectbrief.md
│   ├── productContext.md
│   ├── activeContext.md
│   ├── systemPatterns.md
│   ├── techContext.md
│   └── progress.md
├── Synapse_PRD.md
├── README.md
├── HITL_TEST_INSTRUCTIONS.md
├── SynapseAI/             # SwiftUI app
│   ├── SynapseAI.xcodeproj/
│   ├── SynapseAI/         # App, Core, Features, Services, Models, Resources
│   ├── SynapseAITests/
│   └── SynapseAIUITests/
└── node/                  # Node bridge
    ├── package.json
    ├── index.js
    ├── synapse-init.js
    ├── watch.js
    ├── db.js
    ├── chunk.js
    ├── search.js
    ├── grok.js
    └── test/
```

## Development Setup
- **Xcode** – Open `SynapseAI/SynapseAI.xcodeproj`. Set **Run → Options → Working Directory** to `Synapse` (repo root) so the app finds `node/index.js`. Or set env **SYNAPSE_NODE_SCRIPT** to full path of `node/index.js`.
- **Node** – `cd node && npm install && npm test`.
- **Sandbox** – App uses App Sandbox + security-scoped bookmarks and user-selected read-write; Node runs as subprocess (may not have scope; Swift creates `.synapse/` and templates).

## Technical Constraints
- Menu-bar app: no dock icon (LSUIElement); Dashboard only via menu “Open Dashboard”.
- Global hotkey and AX paste require user to grant Accessibility permission to Synapse.
- Node must be on PATH (e.g. `/opt/homebrew/bin/node`) and script path must be resolvable (Working Directory or SYNAPSE_NODE_SCRIPT).

## Dependencies (Key)
- **Swift** – System frameworks only.
- **Node** – chokidar, better-sqlite3; native fetch for Grok.
