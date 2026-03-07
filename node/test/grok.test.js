const path = require("path");
const fs = require("fs");
const os = require("os");
const { test } = require("node:test");
const assert = require("node:assert");

// Mock fetch before requiring grok so chatCompletion uses our fake
const originalFetch = globalThis.fetch;
globalThis.fetch = async (url, opts) => {
  const body = opts?.body ? JSON.parse(opts.body) : {};
  const messages = body.messages || [];
  const userContent = messages.find((m) => m.role === "user")?.content || "";

  // Simulate Grok returning content with ## Context section when memory is provided
  const hasMemory =
    userContent.includes("projectbrief") ||
    userContent.includes("Project memory") ||
    userContent.includes("Memory snippets");
  const contextSection = hasMemory
    ? `## Context
Project: Synapse MVP for Cursor agent memory injection. Goals: Inject persistent .md memory into AI context. MVP Scope: Project folder setup, markdown memory maintenance, drag-drop ingestion, snippet injection via ⌘⇧P. Codebase Map: DashboardView handles UI; NodeBridgeService bridges to Grok API.`
    : "";

  const skillContent = `---
name: Test Skill
description: A test skill for verification.
---

${contextSection}

## Instructions
1. Follow the user's prompt precisely.
2. Verify the implementation meets the stated requirements.
3. Ensure domain isolation: UI tasks in UI files, backend in service files.

## Examples
- Example 1: Input A → Output B.
- Example 2: Invalid input → show error alert.

## Verification
- Create unit tests asserting the behavior matches the examples.
- Ask the human to run the app, open the relevant screen, confirm the behavior, and report back.`;

  const content = skillContent.trim();
  const charCount = content.length;

  return {
    ok: true,
    text: async () =>
      JSON.stringify({
        choices: [{ message: { content } }],
        usage: { input_tokens: 100, output_tokens: 200 },
      }),
  };
};

const grok = require("../grok.js");

test("buildSkillFormatPrompt returns content with ## Context when memory provided", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-grok-"));
  const synapseDir = path.join(tmpDir, ".synapse");
  fs.mkdirSync(synapseDir, { recursive: true });
  fs.writeFileSync(
    path.join(synapseDir, "projectbrief.md"),
    "# Project\n\nSynapse MVP for Cursor agent memory injection.",
    "utf8"
  );
  fs.writeFileSync(
    path.join(synapseDir, "activeContext.md"),
    "Current focus: Grok integration.",
    "utf8"
  );

  const memorySnippets = grok.readSynapseFilesAsContext(tmpDir);
  const result = await grok.buildSkillFormatPrompt(
    "fake-api-key",
    "Add a button",
    "file.swift (L1-10)\ncode here",
    memorySnippets
  );

  assert.ok(result.content.includes("## Context"), "Output must include ## Context section");
  assert.ok(
    result.content.length >= 800 && result.content.length <= 1800,
    `Output length must be 800-1800 chars, got ${result.content.length}`
  );
  assert.strictEqual(typeof result.inputTokens, "number");
  assert.strictEqual(typeof result.outputTokens, "number");

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

test("buildSubagentContext returns content with ## Context when memory provided", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-grok-sub-"));
  const synapseDir = path.join(tmpDir, ".synapse");
  fs.mkdirSync(synapseDir, { recursive: true });
  fs.writeFileSync(
    path.join(synapseDir, "projectbrief.md"),
    "# Project\n\nSynapse: neural memory for Cursor.",
    "utf8"
  );

  const memorySnippets = grok.readSynapseFilesAsContext(tmpDir);
  const result = await grok.buildSubagentContext(
    "fake-api-key",
    "Refactor the dashboard",
    "DashboardView.swift\ncode",
    memorySnippets
  );

  assert.ok(result.content.includes("## Context"), "Output must include ## Context section");
  assert.strictEqual(typeof result.inputTokens, "number");
  assert.strictEqual(typeof result.outputTokens, "number");

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

test("readSynapseFilesAsContext includes codebase.md when present", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-read-"));
  const synapseDir = path.join(tmpDir, ".synapse");
  fs.mkdirSync(synapseDir, { recursive: true });
  fs.writeFileSync(path.join(synapseDir, "codebase.md"), "# Codebase\n\nDashboardView handles UI.", "utf8");

  const result = grok.readSynapseFilesAsContext(tmpDir);
  assert.ok(result.includes("--- codebase.md ---"), "Should include codebase.md");
  assert.ok(result.includes("DashboardView handles UI"), "Should include codebase content");

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

// Restore fetch after tests
test.after(() => {
  globalThis.fetch = originalFetch;
});
