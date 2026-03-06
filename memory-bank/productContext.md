# Product Context

## Why This Project Exists
Cursor agents are powerful but lack persistent, structured memory. Users repeat context manually or rely on MCP tools that don’t integrate “brain state” (brief, progress, thoughts). Synapse fills that gap by owning a `.synapse/` memory layer and injecting only the right snippets when the user hits ⌘⇧P or asks a question.

## Problems It Solves
- **Context loss** – Agent forgets project decisions and progress between sessions.
- **Manual prep** – Users copy-paste files or prompts into Composer.
- **No single “brain”** – Memory is scattered across chat, files, and tools.
- **No visibility** – No dashboard of what the agent “knows” or last did.

## How It Should Work (User Journey)
1. User opens Synapse (menu bar), selects **New Project** → picks Cursor workspace folder.
2. Synapse creates `.synapse/` and core .md files; starts watching and indexing.
3. User (or agent) can edit `activeContext.md`, `progress.md`, `thoughts.md`; drag extra .md into the app to ingest.
4. In Cursor, user focuses Composer and presses **⌘⇧P** → Synapse pastes a concise, relevant block (snippets + @file refs).
5. User can open **Dashboard** to search (“What did we decide about JWT?”), see memory files, thoughts feed, and Grok token usage; trigger “Suggest skill” when needed.

## UX Goals
- Menu-bar only: no dock clutter; Dashboard on demand.
- One project at a time for MVP; clear “Connected” / “Disconnected” and “node/index.js not found” when Node isn’t available.
- Apple-style UI: Form + Sections, Labels, SF Symbols, grouped layout (see `DashboardView`, `MenuBarView`).
