# Project Brief — Synapse

## Product
**Synapse** – Neural Memory Injection for Cursor Agents. **Version** 1.0 MVP. **Target** June 2026.

## Goal
Build the first Mac app that turns Cursor into a truly agentic system by **injecting persistent, structured .md memory** into the AI’s working context (no MCP/manual prep).

## Vision
Synapse is the Neuralink for Cursor: reads your project, watches/creates .md memory, injects only the snippets the agent needs, and gives a live dashboard of the AI’s brain health.

## Target User
Solo devs / small teams running long agentic sessions in Cursor (refactors, multi-platform, multi-week features).

## MVP Scope (Must Ship)
1. **Project Folder** – New Project → macOS permission → create/watch `.synapse/` (FSEvents).
2. **Markdown Memory** – Auto-maintain `projectbrief.md`, `activeContext.md`, `progress.md`, `thoughts.md`, `learnings.md`, `skill-*.md` in `.synapse/`.
3. **Drag & Drop** – .md onto menu-bar or dashboard → chunk → SQLite (MVP: .md only).
4. **Snippet Injection** – ⌘⇧P (or `/prep`) → search → 4–8 KB block + @file refs → paste into Cursor (AX; clipboard fallback).
5. **Skill Files** – Grok suggests/creates `skill-*.md` in `.synapse/skills/`; index immediately.
6. **Live Dashboard** – Menu-bar popover + window: health, last injection, memory files, thoughts feed, Grok token usage.
7. **Query** – NL query in dashboard → prompt-ready block; Copy.

## Success Criteria
Menu-bar app (no dock), folder permission + indexing, drag-drop → SQLite, ⌘⇧P injects into Cursor (or clipboard), dashboard shows status/files/thoughts/tokens.

## Out of Scope (MVP)
Local LLM, Cursor token tracking, MCP beyond optional minimal; PDF/.txt ingestion — later.

## Why / Problems Solved
- Context loss between sessions; manual copy-paste into Composer; no single “brain”; no visibility into what the agent knows or last did.

## How Synapse helps you develop
- **You (or the AI in Cursor) maintain** `.synapse/` memory (projectbrief, activeContext, progress, thoughts). Synapse does not auto-write them; they are your shared context.
- **Index** — Run Index All after changing memory; Synapse searches this for injection and Dashboard.
- **Injection (⌘⇧P or menu "Inject context")** — Builds a block from the index, **copies to clipboard**, then tries AX paste or simulate ⌘V into Cursor. Indexed files feed Composer with relevant snippets.
- **Dashboard Search + Copy** — Same index; query → prompt block → Copy.
- **Suggest skill** — One-click: uses .synapse context so Grok suggests a skill for this project; creates and indexes it.
- **Update learnings** — One-click: Grok reads project memory (projectbrief, activeContext, progress, thoughts) and appends concise learnings to `learnings.md` (conventions, decisions, gotchas); indexed for search and injection.
- **In short:** You keep the memory; Synapse injects the right slice into Cursor when you hit ⌘⇧P or use the Dashboard.

## Tech (Summary)
SwiftUI (macOS 15.1+), Node bridge (stdio JSON-RPC), SQLite + FTS5 per project (`.synapse/synapse.db`), Grok for skills, AX paste + clipboard + ⌘V fallback. **Setup:** Xcode Working Directory = repo root (or `SYNAPSE_NODE_SCRIPT`); Node: `cd node && npm install && npm test`. See README for full layout.
