
### Full PRD for Developer – Synapse (MVP)

**Product**  
**Synapse** – Neural Memory Injection for Cursor Agents  
**Version** 1.0 MVP  
**Target Launch** June 2026  
**Goal**  
Build the first Mac app that turns Cursor into a truly agentic system by **injecting persistent, structured .md memory** directly into the AI’s working context — instead of relying on MCP tools or manual prompting.

**Vision (one-liner)**  
Synapse is the Neuralink for Cursor: it reads your project, watches and creates .md memory files, injects only the exact snippets the agent needs, and gives you a live dashboard of the AI’s brain health.

**Target User**  
Solo devs / small teams running long agentic sessions in Cursor (refactors, multi-platform projects, multi-week features).

**MVP Scope – What MUST be in v1.0**

1. **Project Folder Access**  
   - On “New Project” → macOS permission dialog: “Grant access to your Cursor workspace folder”  
   - App watches the entire folder (and any subfolders you choose) with FSEvents.

2. **Markdown Memory Layer (the core)**  
   - Auto-creates and maintains the following files in a `.synapse/` folder inside the project:  
     - `projectbrief.md`  
     - `activeContext.md`  
     - `skill-*.md` (auto-generated when needed)  
     - `progress.md`  
     - `thoughts.md` (agent internal monologue)  
   - Supports the domain layout you showed (domains/ios/, domains/android/, etc.).

3. **Drag & Drop Ingestion**  
   - Drag any .md (or .txt, .pdf converted to md) onto the menu-bar icon or dashboard → instantly chunks, indexes, and adds to SQLite.  
   - First version: only .md files (easy to extend later).

4. **Snippet Injection (not full files)**  
   - When you type `/prep` or use hotkey ⌘⇧P in Cursor, Synapse:  
     - Searches its SQLite (BM25 + tags)  
     - Returns **one concise prompt block** (max 4–8 KB) containing only the highest-relevance snippets + @file references.  
     - Auto-pastes the block directly into Cursor Composer/Chat.

5. **Skill File Creation**  
   - Internal Grok-powered agent detects missing knowledge → asks “Create skill-supabase-auth.md?” → generates it from project files + dragged knowledge → writes it to `.synapse/skills/` → immediately indexes it.

6. **Live Dashboard (Command Center)**  
   - Menu-bar popover + optional full window.  
   - Shows:  
     - Current project health (context fill %, last injection)  
     - List of active .md memory files with last-modified time  
     - “Agent thoughts” feed (real-time from thoughts.md)  
     - Simple agent tracking: “iOS sub-agent last wrote to progress 11 min ago”  
     - Token usage estimate (Grok calls only)

7. **Query Interface**  
   - In the dashboard you can type natural questions:  
     “What did the agent decide about JWT refresh?”  
     → Synapse instantly returns a concise prompt-ready block with snippets from the relevant .md files.

**Tech Stack (MVP – keep it simple)**

- **Language**: SwiftUI (Mac app) + embedded Node.js (for BM25 + file watching)  
- **Database**: SQLite + FTS5 (one DB per project)  
- **Internal AI**: Grok API (tool-calling) – default, fast, cheap  
- **Folder watching**: FSEvents  
- **Cursor injection**: macOS Accessibility API (same as Cursor’s own extensions)  
- **MCP**: Optional/minimal – only a simple `synapse_search` tool for users who want it  
- **No local LLM in MVP** (add Qwen/Ollama in Phase 2)

**MVP Deliverables (what the developer must ship)**

- Clean menu-bar app with project switcher  
- Folder permission + indexing pipeline  
- Drag & drop → chunk → SQLite  
- Auto-creation of skill-*.md files via Grok  
- `/prep` → concise snippet injection (auto-paste)  
- Live dashboard with health + thoughts feed  
- Simple query box that returns ready-to-paste blocks  
- Basic token usage tracking (Grok only)

**Phased Roadmap (put this in the job post)**

**Phase 1 – MVP (6–8 weeks)**  
→ Everything listed above

**Phase 2 (next 4–6 weeks)**  
- Domain subfolders + sub-agent monitoring  
- Local Qwen/Ollama toggle  
- Full memory-bank layout auto-detection  
- Thought logging from Cursor agents  
- Token tracking for Cursor itself (tokscale style)

**Phase 3**  
- Multi-project parallel agents  
- Conflict resolution between .md files  
- Voice commands  
- Export / share “brain snapshot”

**Development Job Description (copy-paste ready)**

**Title:** Mac App Developer – Synapse (Neural Memory for Cursor)  
**Type:** Contract → possible full-time  
**Budget:** $12k–18k for MVP (6–8 weeks)  
**Location:** Remote (must be Mac-first developer)

**You will build** the first version of Synapse — a macOS menu-bar app that injects structured .md memory directly into Cursor agents.

**Required**  
- Strong SwiftUI + macOS Accessibility API experience  
- Comfortable with Node.js subprocesses or Swift + SQLite  
- Experience with file watching (FSEvents) and drag-and-drop  
- Understanding of Cursor / Claude agent workflows (you should be a heavy user)  
- Can ship a clean, fast, polished app in 6–8 weeks

**Nice-to-have**  
- Prior work on Cursor extensions or MCP servers  
- Experience with Grok API / tool calling  
- Knowledge of BM25 or simple RAG

**Deliverables**  
See MVP scope above. You will own the entire first version end-to-end.

**Why this project is exciting**  
You are literally building the “Neuralink for Cursor” — injecting memory straight into the AI brain so agents become dramatically more autonomous and coherent.

If you’re interested, reply with:
1. Your best Mac app you’ve shipped (or GitHub)  
2. How many weeks you estimate for the MVP above  
3. One idea you would add to make the injection even more powerful

Let’s make Cursor agents actually remember.
