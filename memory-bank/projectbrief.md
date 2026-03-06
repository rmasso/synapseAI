# Synapse – Project Brief

## Product
**Synapse** – Neural Memory Injection for Cursor Agents  
**Version** 1.0 MVP  
**Target Launch** June 2026

## Goal
Build the first Mac app that turns Cursor into a truly agentic system by **injecting persistent, structured .md memory** directly into the AI’s working context — instead of relying on MCP tools or manual prompting.

## Vision (one-liner)
Synapse is the Neuralink for Cursor: it reads your project, watches and creates .md memory files, injects only the exact snippets the agent needs, and gives you a live dashboard of the AI’s brain health.

## Target User
Solo devs / small teams running long agentic sessions in Cursor (refactors, multi-platform projects, multi-week features).

## MVP Scope (Must Ship in v1.0)
1. **Project Folder Access** – New Project → macOS permission → create/watch `.synapse/` with FSEvents.
2. **Markdown Memory Layer** – Auto-create and maintain `projectbrief.md`, `activeContext.md`, `progress.md`, `thoughts.md`, `skill-*.md` in `.synapse/`.
3. **Drag & Drop Ingestion** – .md onto menu-bar or dashboard → chunk → SQLite (MVP: .md only).
4. **Snippet Injection** – ⌘⇧P (or `/prep`) → search → build 4–8 KB block + @file refs → auto-paste into Cursor (Accessibility API; clipboard fallback).
5. **Skill File Creation** – Grok suggests/create `skill-*.md` in `.synapse/skills/`; index immediately.
6. **Live Dashboard** – Menu-bar popover + full window: health, last injection, memory files list, thoughts feed, Grok token usage.
7. **Query Interface** – Natural-language query in dashboard → prompt-ready block with snippets; Copy.

## Success Criteria
- Clean menu-bar app (no dock icon) with project switcher.
- Folder permission + indexing pipeline working.
- Drag & drop → chunk → SQLite.
- ⌘⇧P injects into Cursor (or clipboard with clear message).
- Dashboard shows status, files, thoughts, tokens.

## Out of Scope for MVP
- Local LLM (Phase 2).
- Cursor token tracking (Phase 2).
- MCP beyond optional minimal `synapse_search` (later).
- PDF/.txt ingestion (later).
