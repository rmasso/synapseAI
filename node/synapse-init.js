"use strict";

const fs = require("fs");
const path = require("path");

const TEMPLATES = {
  "projectbrief.md": `# Project Brief

Describe your project goals, scope, and key requirements here.
`,
  "activeContext.md": `# Active Context

**Current Focus**
(What you're working on right now.)

**Key Decisions**
(Recent decisions that affect the codebase.)

**Open Questions**
(Unresolved questions.)
`,
  "progress.md": `# Progress

## Phase 0
Planned / In progress.

## Next
(Milestones and next steps.)
`,
  "thoughts.md": `# Thoughts

(Agent internal monologue – append-only log.)
`,
  "learnings.md": `# Learnings

(Per-project learnings extracted from memory — conventions, decisions, gotchas. Use "Update learnings" in Dashboard to append from projectbrief, activeContext, progress, thoughts.)
`,
  "codebase.md": `# Codebase map

Describe key files and symbols here so Synapse can suggest accurate skills (correct types and names) without indexing raw source. Run Index All so this file is searchable. Keep entries concise: file path, control/type names, one-line notes.

## Files
- \`path/to/MainView.swift\` — One-line description.

## UI / Views
- \`MainView\` — Summary of role (e.g. main screen, prompt input bar).
- For layout fixes: note the control type and binding (e.g. TextField, \`$viewModel.promptForContext\`) and minimal fix (e.g. \`.frame(maxWidth: .infinity)\`).

## Services / API
- \`ServiceName\` — One-line description.

(Add more sections as needed: Backend, Models, etc.)
`,
  "ui-ux-memory.md": `# UI/UX Memory

(Human experience, design decisions, and UX guidance. Fill out per project.)

**User** — Who, emotional state, primary goal, context.

**Problem space** — What exists today, conventions, constraints.

**UX decisions** — Key decisions and rationale.

**Design tokens** — Spacing, typography, colors, component specs (60-30-10; WCAG AA).

**Accessibility** — Touch targets (min 44pt), contrast, labels, keyboard, screen reader.
`,
};

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function initSynapseFolder(rootPath) {
  if (!rootPath || typeof rootPath !== "string") return { ok: false, error: "Invalid path" };
  const synapseDir = path.join(rootPath, ".synapse");
  ensureDir(synapseDir);
  const skillsDir = path.join(synapseDir, "skills");
  ensureDir(skillsDir);
  for (const [name, content] of Object.entries(TEMPLATES)) {
    const filePath = path.join(synapseDir, name);
    if (!fs.existsSync(filePath)) {
      fs.writeFileSync(filePath, content, "utf8");
    }
  }
  return { ok: true, path: synapseDir };
}

module.exports = { initSynapseFolder, TEMPLATES };
