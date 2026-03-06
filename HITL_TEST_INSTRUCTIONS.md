# HITL Test Instructions (per phase)

Run these at each **HARD STOP** before proceeding. Reply "Phase N passed" or describe failures.

---

## Phase 0 – App shell + Node bridge

1. **Build and run** the app (Xcode: Run SynapseAI). Confirm **menu bar icon** only (no dock icon). Click the icon; click "Open Dashboard" to open the window.
2. Confirm **Node connected**: In the Dashboard you should see "Status: Connected" (or "Node not connected" / error if `node/index.js` not found). If not found: set **Working Directory** in scheme to the `Synapse` folder, or set env **SYNAPSE_NODE_SCRIPT** to full path of `node/index.js`.
3. Click **"Ping Node"** in the Dashboard; you should see "Pong received".
4. Run **SynapseAITests** in Xcode (Cmd+U or Product → Test). Run **Node tests**: `cd node && npm test`.
5. **Sign-off**: Reply "Phase 0 passed" or report what failed.

---

## Phase 1 – Project + folder + .synapse

1. Click **"New Project"** (menu bar or Dashboard). Choose a test folder and grant access.
2. Confirm **`.synapse/`** is created with `projectbrief.md`, `activeContext.md`, `progress.md`, `thoughts.md`.
3. Edit one of these .md files on disk; confirm the app sees the change (e.g. "Last change: ..." in Dashboard).
4. **Sign-off**: "Phase 1 passed" or describe what failed.

---

## Phase 2 – Indexing & search

1. Open a project; click **Index All**. Run **Search** for a phrase from your .md files; confirm snippets appear.
2. Run `cd node && npm test` and Swift unit tests.
3. **Sign-off**: "Phase 2 passed" or describe failures.

---

## Phase 3 – Drag & query

1. **Drag** a .md file onto the dashboard drop zone; confirm "Ingested: …" and that search finds it.
2. Type a question in the **Query** box; confirm a prompt-ready block and **Copy** works.
3. **Sign-off**: "Phase 3 passed" or describe failures.

---

## Phase 4 – Injection

1. Enable **Accessibility** for Synapse (System Settings → Privacy & Security → Accessibility).
2. Open **Cursor**, focus Composer, press **⌘⇧P**. Confirm text is pasted (or copied to clipboard with message).
3. **Sign-off**: "Phase 4 passed" or describe failures.

---

## Phase 5 – Grok skill

1. Set **Grok API key** in the dashboard; click **Suggest skill**. Confirm a skill file is created under `.synapse/skills/`.
2. Run a search that hits the new skill; confirm token count updates.
3. **Sign-off**: "Phase 5 passed" or describe failures.

---

## Phase 6 – Dashboard polish

1. Open the **Dashboard**; confirm **project**, **last injection**, **memory files** list, **thoughts** preview, and **Grok token** count.
2. Edit `thoughts.md` on disk; confirm the thoughts section updates (e.g. after a change or refresh).
3. Trigger one **injection** (⌘⇧P); confirm "Last injection" updates.
4. **Sign-off**: "Phase 6 passed". MVP complete.
