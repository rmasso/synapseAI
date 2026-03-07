"use strict";

const fs = require("fs");
const path = require("path");
const { search } = require("./search.js");
const db = require("./db.js");

// Endpoint and models: see .cursor/knowledge/grok_api.md
// Debug: logs request/response to stderr (stdout is used for JSON-RPC).
async function chatCompletion(apiKey, messages, options = {}) {
  const model = options.model || "grok-code-fast-1";
  const maxTokens = options.max_tokens ?? 2048;
  const body = { model, messages, max_tokens: maxTokens };
  if (options.tools && options.tools.length > 0) {
    body.tools = options.tools;
    body.tool_choice = options.tool_choice ?? "auto";
  }
  const url = "https://api.x.ai/v1/chat/completions";
  console.error("[Grok API] Request:", JSON.stringify({
    url,
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer ***" },
    body: { ...body, messages: messages.map((m) => ({ role: m.role, contentLength: (m.content || "").length })) },
  }, null, 2));
  console.error("[Grok API] Request body (full messages):", JSON.stringify(body, null, 2));

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
  });

  const resText = await res.text();
  console.error("[Grok API] Response status:", res.status, res.statusText);
  console.error("[Grok API] Response body:", resText);

  if (!res.ok) {
    throw new Error(`Grok API ${res.status}: ${resText}`);
  }
  const data = JSON.parse(resText);
  const msg = data.choices?.[0]?.message ?? {};
  const content = msg.content ?? "";
  const toolCalls = msg.tool_calls ?? [];
  const usage = data.usage ?? {};
  const inputTokens = usage.input_tokens ?? usage.prompt_tokens ?? 0;
  const outputTokens = usage.output_tokens ?? usage.completion_tokens ?? 0;
  return {
    content,
    message: msg,
    toolCalls,
    inputTokens,
    outputTokens,
  };
}

function readSynapseFilesAsContext(projectRoot) {
  const synapseDir = path.join(projectRoot, ".synapse");
  const names = ["projectbrief.md", "activeContext.md", "progress.md", "thoughts.md", "learnings.md", "codebase.md"];
  const parts = [];
  for (const name of names) {
    const filePath = path.join(synapseDir, name);
    if (fs.existsSync(filePath)) {
      try {
        const text = fs.readFileSync(filePath, "utf8").trim();
        if (text.length > 0) parts.push(`--- ${name} ---\n${text}`);
      } catch (_) {}
    }
  }
  return parts.join("\n\n");
}

async function suggestAndCreateSkill(apiKey, projectRoot, contextSnippets) {
  const synapseDir = path.join(projectRoot, ".synapse");
  const skillsDir = path.join(synapseDir, "skills");
  if (!fs.existsSync(skillsDir)) {
    fs.mkdirSync(skillsDir, { recursive: true });
  }
  let contextText = (contextSnippets || []).slice(0, 5).map((s) => s.content || s).join("\n\n").trim();
  if (!contextText) {
    contextText = readSynapseFilesAsContext(projectRoot);
    if (contextText) console.error("[Grok] No search snippets; using .synapse/*.md files as context.");
  }
  if (!contextText) {
    contextText = "(No project context available. Run Index All in the Dashboard, or add content to .synapse/projectbrief.md and other memory files.)";
    console.error("[Grok] No snippets and no .synapse files; sending fallback message.");
  }
  const prompt = `You are a technical writer. Use ONLY the project context provided below. Forbidden: referencing files, paths, or code not in the context. Suggest ONE skill file. Reply with exactly two lines:
Line 1: the filename only (e.g. skill-project-conventions.md). Choose a name that fits the project described in the context.
Line 2: the markdown content (YAML frontmatter with name, tags; sections: Overview, Rules, Examples). Under 150 lines. Base content only on the context below.

--- Project context ---
${contextText}`;
  const result = await chatCompletion(apiKey, [{ role: "user", content: prompt }]);
  const lines = result.content.trim().split("\n");
  const firstLine = lines[0]?.trim() || "skill-generated.md";
  const safeName = firstLine.endsWith(".md") ? firstLine : firstLine + ".md";
  const content = lines.slice(1).join("\n").trim() || result.content;
  const filePath = path.join(skillsDir, safeName);
  fs.writeFileSync(filePath, content, "utf8");
  return {
    ok: true,
    path: filePath,
    filename: safeName,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/** Strip markdown code fence around JSON for reliable parse. */
function stripJsonFence(text) {
  const s = (text || "").trim();
  const match = s.match(/^```(?:json)?\s*([\s\S]*?)```$/);
  return match ? match[1].trim() : s;
}

/** Default max chunks selected for the skill; goal is a rich skill for the executing agent, not to save Grok tokens. */
const DEFAULT_MAX_CHUNKS_FOR_PROMPT = 10;
/** Max chunks per file in prompt selection (animation/context limit). */
const MAX_CHUNKS_PER_FILE = 5;
/** Max total nodes/chunks for prompt selection when managing large indexes. */
const MAX_NODES_FOR_PROMPT = 700;
/** Max chunk descriptions sent to Grok (id, path, startLine, endLine, preview ~180 chars each). ~250 chars/chunk in JSON → 200 ≈ 50 KB user message. */
const MAX_DESCRIPTIONS_IN_PROMPT = 200;
/** Rough chars-per-chunk (MAX_CHUNK_CHARS in chunk.js) divided by ~4 chars/token. */
const AVG_TOKENS_PER_CHUNK = 300;

/** Max chars of DB/code snippets sent to Grok for skill prompt. Generous so the skill can embed full code for the next agent. */
const MAX_DB_SNIPPETS_CHARS_SKILL = 12000;
/** Max chars of memory snippets sent to Grok for skill prompt. */
const MAX_MEMORY_SNIPPETS_CHARS_SKILL = 6000;
/** Max chars of DB snippets for subagent context; memory can be larger. */
const MAX_DB_SNIPPETS_CHARS_SUBAGENT = 4000;
const MAX_MEMORY_SNIPPETS_CHARS_SUBAGENT = 6000;

function truncateToMaxChars(str, maxChars) {
  if (typeof str !== "string" || maxChars <= 0) return str || "";
  const s = str.trim();
  if (s.length <= maxChars) return s;
  return s.slice(0, maxChars) + "\n\n[... truncated to reduce context size ...]";
}

/**
 * Enforce 5 chunks per file and total node cap on selected chunk ids.
 * Preserves order of first occurrence. idToPath: Map(id -> path).
 */
function capChunkIdsByFileAndTotal(chunkIds, idToPath, maxChunks, maxPerFile, maxTotal) {
  const totalCap = Math.min(maxChunks, maxTotal);
  const perPathCount = new Map();
  const result = [];
  for (const id of chunkIds) {
    if (result.length >= totalCap) break;
    const p = idToPath.get(id);
    const pathKey = p != null ? p : String(id);
    const n = (perPathCount.get(pathKey) || 0) + 1;
    if (n > maxPerFile) continue;
    perPathCount.set(pathKey, n);
    result.push(id);
  }
  return result;
}

/**
 * Ask Grok which chunks to include for a user prompt. API response must be JSON only.
 * chunkDescriptions: [{ id, path, startLine, endLine, preview }]
 * maxChunks: user-configurable cap (default DEFAULT_MAX_CHUNKS_FOR_PROMPT).
 * memoryFirstMode: when true, prioritize memory chunks (paths containing .synapse/) in selection.
 * Returns { chunkIds: number[], optimizedPrompt?: string }. chunkIds capped at maxChunks, max 5 per file, max MAX_NODES_FOR_PROMPT total.
 */
async function suggestChunksForPrompt(apiKey, userPrompt, chunkDescriptions, maxChunks, memoryFirstMode) {
  const cap = (Number.isInteger(maxChunks) && maxChunks >= 1) ? maxChunks : DEFAULT_MAX_CHUNKS_FOR_PROMPT;
  const memoryFirstRule = memoryFirstMode
    ? `6. MEMORY-FIRST MODE: Prioritize memory chunks (paths containing .synapse/) first; fill remaining slots with code chunks only when memory chunks are insufficient or not relevant.`
    : "";
  const systemPrompt = `You respond only with a single JSON object. Use ONLY the chunk list provided below — do not reference or assume any chunks not in that list. Forbidden: inventing chunk ids, referencing external files, or adding paths not in the list. No markdown, no code fences, no explanation.

Valid keys:
  "chunkIds": array of chunk id integers from the provided list only, at most ${cap}, most relevant first.
  "optimizedPrompt": optional string — a sharper rewrite using only the user prompt and the listed chunks.

Selection rules — goal is the best prompt for the executing agent (so it does not need to read files); include all relevant touchpoints:
1. Include every chunk that is DIRECTLY relevant to the task so the resulting skill is self-contained. Use up to ${cap} chunks. Do not skimp: the next agent should have all code it needs in the skill.
2. Include a chunk when it contains code or context the implementing agent will need (touchpoints, types, call sites). When in doubt about relevance, include it.
3. EXCLUDE only: boilerplate, unrelated logs, clear duplicates, anything not related to the task.
4. Domain matching: UI questions → UI/View/Dashboard/Form chunks. Backend → service/API/DB. Mix when the question spans both.
5. For implementation or code-change tasks: prefer chunks whose path ends in .swift, .js, or .ts (source code) over .md when both are relevant, so the skill can embed exact code.${memoryFirstRule ? "\n6. " + memoryFirstRule.replace(/^6\.\s*/, "") : ""}

Return only valid JSON.`;

  const limited = chunkDescriptions.slice(0, MAX_DESCRIPTIONS_IN_PROMPT);
  const userMessage = `Use ONLY the chunks listed below. Do not reference any other files or ids.

User prompt: "${userPrompt}"

--- Available chunks (id, path, startLine, endLine, preview) ---
${JSON.stringify(limited)}

Include every chunk directly relevant to the task (max ${cap}) so the skill is self-contained for the executing agent. Return JSON only: { "chunkIds": [1, 2, ...], "optimizedPrompt": "optional sharper prompt" }`;

  const result = await chatCompletion(apiKey, [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ], { max_tokens: 512 });
  const raw = result.content.trim();
  const jsonStr = stripJsonFence(raw);
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    throw new Error(`Grok did not return valid JSON: ${e.message}. Raw: ${raw.substring(0, 200)}`);
  }
  let chunkIds = Array.isArray(parsed.chunkIds) ? parsed.chunkIds : [];
  chunkIds = chunkIds.filter((id) => Number.isInteger(id) && id > 0);
  const idToPath = new Map((chunkDescriptions || []).map((c) => [c.id, c.path]));
  chunkIds = capChunkIdsByFileAndTotal(chunkIds, idToPath, cap, MAX_CHUNKS_PER_FILE, MAX_NODES_FOR_PROMPT);
  const optimizedPrompt = typeof parsed.optimizedPrompt === "string" ? parsed.optimizedPrompt.trim() : null;
  return { chunkIds, optimizedPrompt, inputTokens: result.inputTokens, outputTokens: result.outputTokens };
}

/** Max tokens for snippet-spec response (room for multiple snippetSpecs + keywordSearches). */
const MAX_TOKENS_SNIPPET_SPECS = 1536;

/**
 * Ask Grok to return a JSON spec of what snippets to retrieve: chunkIds, snippetSpecs (path + line range), and/or keywordSearches.
 * chunkDescriptions: optional [{ id, path, startLine, endLine, preview }]. When provided, Grok may return chunkIds and snippetSpecs (only from this list). When missing/empty, Grok must return only keywordSearches (and optional optimizedPrompt).
 * Returns { chunkIds, snippetSpecs, keywordSearches, optimizedPrompt, inputTokens, outputTokens }. On parse failure returns safe default (empty arrays).
 */
async function suggestSnippetSpecs(apiKey, userPrompt, chunkDescriptions, options = {}) {
  const hasChunkList = Array.isArray(chunkDescriptions) && chunkDescriptions.length > 0;
  const limited = hasChunkList ? chunkDescriptions.slice(0, MAX_DESCRIPTIONS_IN_PROMPT) : [];

  const systemPrompt = hasChunkList
    ? `You respond only with a single JSON object. Use ONLY the chunk list provided below when returning chunkIds or snippetSpecs. No markdown, no code fences, no explanation.

Valid keys:
  "chunkIds": array of chunk id integers from the provided list only. Do not invent ids.
  "snippetSpecs": array of { "path": string, "startLine": number, "endLine": number } — ONLY for chunks that appear in the provided list; copy path and line range from the list. Do not invent paths or line ranges for code not in the list.
  "keywordSearches": array of search query strings — use when the needed code is NOT in the provided list (e.g. different file or region). Each string will be run against the project index; keep queries short (e.g. "ProcessAnimationView animation", "suggestChunksForPrompt").
  "optimizedPrompt": optional string — a sharper rewrite of the user prompt.

Rules:
1. Prefer chunkIds when chunks in the list are directly relevant.
2. Use snippetSpecs only when you need to narrow to a subset of lines from a chunk in the list (path, startLine, endLine must match an entry in the list).
3. Use keywordSearches when the relevant code is not in the list. Fewer, precise queries are better.
4. Include every directly relevant chunk/snippet so the resulting skill is self-contained for the executing agent; do not skimp.
5. For implementation or code-change tasks: prefer chunks whose path ends in .swift, .js, or .ts (source code) over .md when both are relevant, so the skill can embed exact code. Return only valid JSON.`
    : `You respond only with a single JSON object. You do NOT have a chunk list. Return only search queries so the app can find the right code. No markdown, no code fences, no explanation.

Valid keys:
  "keywordSearches": array of search query strings (e.g. "DashboardView", "buildContextForPrompt", "animation limits"). Required.
  "optimizedPrompt": optional string — a sharper rewrite of the user prompt.

Do NOT return chunkIds or snippetSpecs. Return only valid JSON.`;

  const userMessage = hasChunkList
    ? `User prompt: "${userPrompt}"

--- Available chunks (id, path, startLine, endLine, preview) ---
${JSON.stringify(limited)}

Return JSON only: { "chunkIds": [...], "snippetSpecs": [{ "path": "...", "startLine": n, "endLine": n }], "keywordSearches": ["query1", ...], "optimizedPrompt": "optional" }`
    : `User prompt: "${userPrompt}"

No chunk list provided. Return only keywordSearches (and optional optimizedPrompt). Example: { "keywordSearches": ["DashboardView", "skill format"], "optimizedPrompt": "optional" }`;

  const result = await chatCompletion(apiKey, [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ], { max_tokens: MAX_TOKENS_SNIPPET_SPECS });

  const raw = result.content.trim();
  const jsonStr = stripJsonFence(raw);
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    console.error("[Grok] suggestSnippetSpecs parse failed:", e.message, "Raw:", raw.substring(0, 200));
    return {
      chunkIds: [],
      snippetSpecs: [],
      keywordSearches: [],
      optimizedPrompt: null,
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
    };
  }

  const chunkIds = Array.isArray(parsed.chunkIds) ? parsed.chunkIds.filter((id) => Number.isInteger(id) && id > 0) : [];
  const snippetSpecs = Array.isArray(parsed.snippetSpecs)
    ? parsed.snippetSpecs.filter(
        (s) =>
          s && typeof s.path === "string" && Number.isInteger(s.startLine) && Number.isInteger(s.endLine) && s.startLine >= 1 && s.endLine >= s.startLine
      )
    : [];
  const keywordSearches = Array.isArray(parsed.keywordSearches)
    ? parsed.keywordSearches.filter((q) => typeof q === "string" && q.trim().length > 0).map((q) => q.trim())
    : [];
  const optimizedPrompt = typeof parsed.optimizedPrompt === "string" ? parsed.optimizedPrompt.trim() || null : null;

  return {
    chunkIds,
    snippetSpecs,
    keywordSearches,
    optimizedPrompt,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/**
 * Read memory files + existing learnings, ask Grok for new learnings, append to .synapse/learnings.md.
 * Returns { ok, path, appendedLines, inputTokens, outputTokens }.
 */
async function suggestLearnings(apiKey, projectRoot) {
  const synapseDir = path.join(projectRoot, ".synapse");
  const learningsPath = path.join(synapseDir, "learnings.md");
  const memoryContext = readSynapseFilesAsContext(projectRoot);
  if (!memoryContext || memoryContext.trim().length < 20) {
    throw new Error("Not enough content in project memory (projectbrief, activeContext, progress, thoughts). Add content and try again.");
  }
  let existingLearnings = "";
  if (fs.existsSync(learningsPath)) {
    try {
      existingLearnings = fs.readFileSync(learningsPath, "utf8").trim();
      if (existingLearnings.length > 4000) existingLearnings = existingLearnings.slice(-4000);
    } catch (_) {}
  }
  const prompt = `You are summarizing project memory into learnings. Use ONLY the project memory and existing learnings provided below. Forbidden: referencing external files, paths, or content not in the blocks. If something is missing, extract only from what is given. Output ONLY a markdown bullet list (each line "- "). No headers, no preamble. One learning per bullet.

--- Project memory (projectbrief, activeContext, progress, thoughts) ---
${memoryContext}

${existingLearnings ? `--- Existing learnings (do not duplicate) ---\n${existingLearnings}\n\n` : ""}
Extract 5–12 concise learnings: conventions, key decisions, gotchas, patterns, or facts for the next session. Output ONLY the bullet list.`;

  const result = await chatCompletion(apiKey, [{ role: "user", content: prompt }], { max_tokens: 1024 });
  const bullets = result.content
    .trim()
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- ") && line.length > 3);
  if (bullets.length === 0) {
    throw new Error("Grok returned no learnings. Try again or add more content to memory.");
  }
  const section = `\n\n## ${new Date().toISOString().slice(0, 10)}\n\n${bullets.join("\n")}\n`;
  const existing = fs.existsSync(learningsPath) ? fs.readFileSync(learningsPath, "utf8") : "# Learnings\n\n(Per-project learnings from memory.)\n";
  fs.writeFileSync(learningsPath, existing.trimEnd() + section, "utf8");
  return {
    ok: true,
    path: learningsPath,
    appendedLines: bullets.length,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/**
 * Build a single skill.md-format markdown document from user prompt + DB snippets + memory snippets.
 * Returns { content, inputTokens, outputTokens }. Content is trimmed skill markdown only (no fences).
 * Fallback: if Grok fails to generate ## Context, omit the section and proceed with the rest of the skill.md.
 */
async function buildSkillFormatPrompt(apiKey, userPrompt, dbSnippets, memorySnippets) {
  const dbTrimmed = truncateToMaxChars(dbSnippets || "", MAX_DB_SNIPPETS_CHARS_SKILL);
  const memoryTrimmed = truncateToMaxChars(memorySnippets || "", MAX_MEMORY_SNIPPETS_CHARS_SKILL);

  const systemPrompt = `You are preparing a skill.md for an agent that will execute ONLY from this package. Process ONLY the inline context provided below. Forbidden: referencing external files, DBs, or paths; instructing the agent to read, grep, or list directories. If data is missing, produce a minimal valid skill and note the gap; do not tell the agent to seek more.

You are a senior software engineer. Your output must be ONLY a structured task prompt — no preamble, no explanation, no pleasantries.

Directives:
1. Address the implementing engineer directly; assume full technical competency — no hand-holding.
2. Be clear and concise — every sentence must carry information. No filler, no hedging, no padding.
3. Preserve original context exactly — do not invent requirements, rename symbols, or change scope. Use only the memory and code snippets provided.
4. Ensure flawless execution — every step must be unambiguous with no implicit assumptions left for the implementer to guess.
5. Eliminate ambiguity — if a step could be misinterpreted, state the intent explicitly.
6. Mitigate risk — flag destructive operations, state what must NOT be changed, and specify fallback behavior where relevant.
7. Domain isolation — UI tasks stay in UI files; service/backend tasks stay in service files. Do not bleed scope across domains.

Output rules (total length 2500–4000 chars so the executing agent has a complete, self-contained prompt; if it would exceed, trim Context only, keep Current snippets, Instructions, Examples, Verification complete):
- Structure: YAML frontmatter (name, description, optional tags), then ## Context, then ## Current snippets (see below), then ## Instructions, then ## Examples, then ## Verification. No other sections. Do NOT include ## Troubleshooting, ## Steps, ## If Blocked, or any other section.
- ## Context (mandatory, immediately after frontmatter): Open with "You have all needed context. Do not perform file reads, greps, or directory listings — work only from this skill." Add: "All code you need is in the Current snippets section below. If something is missing, list it and ask the human to add it; do not grep or read files." Then concise, task-relevant excerpts from the provided memory only (project purpose, goals, MVP scope, key decisions). When the task reuses existing behavior (e.g. moving a button or reusing an alert), add one line stating what already exists and that it should be preserved or moved (e.g. "The existing remove flow uses .alert with Delete and removeCurrentProject(); keep that behavior."). Keep ## Context under 500 characters.
- ## Current snippets (mandatory when code/memory snippets were provided): Embed the exact code or config excerpts the agent must use, labeled by file or touchpoint (e.g. "File.swift — WindowGroup:", then the snippet). Paste from the blocks below so the executing agent never has to read files or grep. If a snippet contains mixed UI (e.g. alert and toolbar in one block), add one sentence in the label or right after it clarifying which part is which (e.g. "In this block, the delete alert is the .alert(...) with primaryButton: .destructive; the rest is the toolbar."). If no snippets were provided, omit this section.
- ## Instructions: Use numbered steps (1. 2. 3.) when there are multiple distinct implementation steps. Each step must be unambiguous. The final step must always be: "Update .synapse: add a brief entry to activeContext.md or progress.md (and optionally thoughts.md) reflecting what was done, so the next session and ⌘⇧P have up-to-date context."
- ## Examples: Keep concise and complete; do not cut mid-line or mid-word. If showing code, end at a complete statement.
- ## Verification: exactly 1–2 bullets — one for text-based test criteria the agent should create, one for what the agent should ask the human to verify. Phrase as the agent speaking to the human, not as commands. Be concrete.
- The description value must be an imperative sentence (e.g. "Add tabbed navigation to DashboardView"). Never "A guide to…" or "Step-by-step guide to…".
- The generated skill must be self-contained: any file or symbol mentioned in Instructions must have its relevant code in ## Current snippets or ## Context. Do not instruct the agent to open or read any file.
- Output ONLY the skill markdown. No \`\`\`markdown fences, no surrounding text.`;

  const userMessage = `Use ONLY the three blocks below. Do not reference external files or DBs.

User prompt:
${userPrompt || "(no prompt)"}

--- Database/code snippets (selected chunks) ---
${dbTrimmed || "(none)"}

--- Memory snippets (.synapse) ---
${memoryTrimmed || "(none)"}

Produce a skill.md (2500–4000 chars) using ONLY the blocks above so the executing agent has a complete prompt: YAML frontmatter, ## Context (mandatory — open with "You have all needed context. Do not read files outside this skill. All code you need is in Current snippets below." then memory excerpts; add one line for existing behavior to preserve when relevant; under 500 chars), ## Current snippets (embed all relevant exact code from the blocks; if a block mixes alert and toolbar, clarify which part is which in the label), ## Instructions (use numbered steps 1. 2. 3.; the last step must be "Update .synapse: add a brief entry to activeContext.md or progress.md reflecting what was done"), ## Examples (complete, no mid-line cut), ## Verification. Do NOT add ## Troubleshooting or other sections. Output ONLY the markdown.`;

  const result = await chatCompletion(apiKey, [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ], { max_tokens: 3072 });

  let content = (result.content || "").trim();
  const fenceMatch = content.match(/^```(?:markdown|md)?\s*([\s\S]*?)```$/);
  if (fenceMatch) content = fenceMatch[1].trim();
  return {
    content,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/**
 * Build a context package for a parallel subagent. Heavy on .synapse memory; DB snippets only where needed.
 * Returns { content, inputTokens, outputTokens }.
 * Fallback: if Grok fails to generate ## Context, omit the section and proceed with the rest.
 */
async function buildSubagentContext(apiKey, userPrompt, dbSnippets, memorySnippets) {
  const dbTrimmed = truncateToMaxChars(dbSnippets || "", MAX_DB_SNIPPETS_CHARS_SUBAGENT);
  const memoryTrimmed = truncateToMaxChars(memorySnippets || "", MAX_MEMORY_SNIPPETS_CHARS_SUBAGENT);

  const systemPrompt = `You are preparing a context package for an isolated subagent. Process ONLY the inline context provided below. Forbidden: file reads, greps, directory listings, external RPC simulations, or memory expansions. If data is missing, produce a minimal valid package and note the gap; do not instruct the subagent to seek more.

You are a senior software engineer. Your output gives the subagent everything it needs to execute without asking questions.

Directives:
1. Address the subagent as a senior engineer — be direct, technical, and assume full competency.
2. Be clear and concise — distill to what matters. No padding, no repetition.
3. Preserve original context faithfully — summarize from the provided memory only; do not invent or omit key facts.
4. Ensure flawless execution — leave no gaps; the subagent must not need to infer unstated context.
5. Eliminate ambiguity — make current state, active conventions, and task scope explicit.
6. Mitigate risk — state what must NOT be changed, known gotchas, and what to do if blocked.

Structure your output (total package under 8K characters; if it would exceed, trim to essentials or end with "Error: Exceeds 8K chars; trim to essentials."):
- ## Context (mandatory, first section): Open with "You have all needed context. Do not perform file reads, greps, or directory listings — work only from this package." Add: "All code you need is in the Snippets section below. If something is missing, list it; do not grep or read files." Then concise, task-relevant excerpts from the provided memory (project purpose, goals, MVP scope, key decisions). Keep Context under 400 characters.
- ## Snippets (mandatory when code was provided): Embed the exact code or config excerpts the subagent must use, labeled by file or touchpoint. Paste from the blocks below so the subagent never has to read files or grep. If no code snippets were provided, omit this section.
- ## Instructions: The subagent's specific task. Reference only what is already in Context or Snippets. Do not instruct the subagent to open or read any file. The final instruction must be: "Update .synapse: add a brief entry to activeContext.md or progress.md (and optionally thoughts.md) reflecting what was done, so the next session has up-to-date context."
- End with a brief "Do not change" list and fallback instructions if blocked.

Avoid bloat — every included snippet must earn its token cost. The package must be self-contained so the subagent does not need to read the repo.`;

  const userMessage = `User request (what the subagent should do):
${userPrompt || "(no prompt)"}

--- PRIMARY: Project memory (.synapse) ---
${memoryTrimmed || "(no memory files)"}

--- SECONDARY: Code/DB snippets (include only if directly relevant) ---
${dbTrimmed || "(none)"}

Produce the subagent context package using ONLY the PRIMARY and SECONDARY blocks above. Do not reference external files or DBs. Start with ## Context (mandatory — open with "You have all needed context. Do not read files outside this package. All code you need is in Snippets below." then memory excerpts; under 400 chars). Then ## Snippets (embed the exact code excerpts from the blocks above so the subagent does not read files or grep). Then ## Instructions (the last instruction must be: "Update .synapse: add a brief entry to activeContext.md or progress.md reflecting what was done"). Total output under 8K chars; if over, trim or output "Error: Exceeds 8K chars; trim to essentials." Add "Do not change" and fallback if blocked.`;

  const result = await chatCompletion(apiKey, [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ], { max_tokens: 2048 });

  const content = (result.content || "").trim();
  return {
    content,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/**
 * Sharpen a rough user prompt using project memory context.
 * Returns { optimizedPrompt, inputTokens, outputTokens }.
 */
const MAX_MEMORY_SNIPPETS_CHARS_OPTIMIZE = 2500;

async function optimizePrompt(apiKey, userPrompt, memorySnippets) {
  const memoryTrimmed = truncateToMaxChars(memorySnippets || "", MAX_MEMORY_SNIPPETS_CHARS_OPTIMIZE);

  const systemPrompt = `You are sharpening a Cursor task prompt. Use ONLY the project context provided below. Forbidden: referencing files, paths, or symbols not mentioned in that context. If context is missing, make the prompt precise without inventing file names. Output ONLY the improved prompt text — no preamble, no quotes, no explanation.

Rules:
1. Preserve the user's intent exactly — only make it more precise.
2. Reference specific files, functions, or patterns only from the provided context.
3. Keep it concise: 1–4 sentences or a tight bullet list.
4. Output ONLY the improved prompt.`;

  const userMessage = `Use ONLY the project context below. Do not reference external files.

Original prompt: ${userPrompt}

--- Project context ---
${memoryTrimmed || "(none)"}

Return ONLY the improved prompt.`;

  const result = await chatCompletion(apiKey, [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ], { max_tokens: 256 });

  return {
    optimizedPrompt: result.content.trim(),
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/** search_project tool definition for xAI function calling. API expects nested "function" object. */
const SEARCH_PROJECT_TOOL = {
  type: "function",
  function: {
    name: "search_project",
    description:
      "Search the indexed project codebase and .synapse memory. Use when the user asks about files, code, implementation, or when you need specific snippets to answer. Query can be keywords, type names, or file paths.",
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "FTS search query: keywords, type names (e.g. DashboardView), or file path fragments",
        },
      },
      required: ["query"],
    },
  },
};

const MAX_CHAT_TURN_ITERATIONS = 5;

/**
 * Multi-turn chat with Grok. Grok can call search_project to fetch DB snippets.
 * Returns final natural-language reply. Uses full chat history.
 */
async function chatTurn(apiKey, projectRoot, messages) {
  const memoryContext = projectRoot ? readSynapseFilesAsContext(projectRoot) : "";
  const systemPrompt = `You are a helpful assistant for a developer working on their project. You have access to the project's .synapse memory (goals, context, progress) and can search the indexed codebase when you need specific files or code.

${memoryContext ? `--- Project memory (.synapse) ---\n${memoryContext}\n\n` : ""}Use the search_project tool when the user asks about implementation, file structure, or when you need code snippets to answer. Reply naturally and concisely.`;

  const fullMessages = [
    { role: "system", content: systemPrompt },
    ...messages,
  ];

  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let iter = 0;

  while (iter < MAX_CHAT_TURN_ITERATIONS) {
    iter++;
    const result = await chatCompletion(apiKey, fullMessages, {
      tools: [SEARCH_PROJECT_TOOL],
      tool_choice: "auto",
      max_tokens: 4096,
    });

    totalInputTokens += result.inputTokens;
    totalOutputTokens += result.outputTokens;

    if (!result.toolCalls || result.toolCalls.length === 0) {
      return {
        content: result.content || "(No response)",
        inputTokens: totalInputTokens,
        outputTokens: totalOutputTokens,
      };
    }

    // Append assistant message with tool_calls
    fullMessages.push({
      role: "assistant",
      content: result.content || null,
      tool_calls: result.toolCalls,
    });

    // Execute each tool call and append results
    for (const tc of result.toolCalls) {
      const fn = tc.function;
      if (!fn || fn.name !== "search_project") continue;
      let args;
      try {
        args = typeof fn.arguments === "string" ? JSON.parse(fn.arguments) : fn.arguments || {};
      } catch (_) {
        args = {};
      }
      const query = String(args.query || "").trim() || "context";
      const searchRes = search(query, { limit: 10, maxChars: 8000 });
      const snippets = (searchRes.snippets || []).map(
        (s) => `${s.path} (L${s.startLine}-${s.endLine})\n${s.content || ""}`
      );
      const content = snippets.length > 0 ? snippets.join("\n\n") : `(No results for query: ${query})`;
      fullMessages.push({
        role: "tool",
        tool_call_id: tc.id,
        name: "search_project",
        content,
      });
    }
  }

  // Max iterations reached; return last content if any
  const lastAssistant = [...fullMessages].reverse().find((m) => m.role === "assistant");
  return {
    content: lastAssistant?.content || "(Max iterations reached)",
    inputTokens: totalInputTokens,
    outputTokens: totalOutputTokens,
  };
}

const SELF_SYNAPSE_CHARS_PER_BATCH = 15000;
const SELF_SYNAPSE_MAX_ITERATIONS = 8;
const MEMORY_FILE_NAMES = ["projectbrief.md", "activeContext.md", "progress.md", "thoughts.md", "learnings.md", "codebase.md"];

/**
 * Parse Grok output with --- filename --- delimiters. Returns Map<filename, content>.
 */
function parseMemoryFileOutput(text) {
  const result = new Map();
  const re = /---\s+([a-zA-Z0-9_.-]+\.md)\s+---\s*([\s\S]*?)(?=---\s+[a-zA-Z0-9_.-]+\.md\s+---|$)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const name = m[1].trim();
    const content = (m[2] || "").trim();
    if (MEMORY_FILE_NAMES.includes(name)) result.set(name, content);
  }
  return result;
}

/**
 * Fill out .synapse memory files from project context. Chunked iteration for large folders.
 * Returns { ok, filesUpdated, chunksProcessed, inputTokens, outputTokens }.
 */
async function selfSynapse(apiKey, projectRoot, onProgress) {
  const report = (msg) => { if (onProgress) onProgress(msg); };

  report("Gathering project context...");
  const synapseDir = path.join(projectRoot, ".synapse");
  const { TEMPLATES } = require("./synapse-init.js");

  const memoryContext = readSynapseFilesAsContext(projectRoot);

  // Gather indexed snippets: search + getChunksBatch
  const seenIds = new Set();
  const snippetList = [];

  function addSnippet(s) {
    const id = s.id;
    if (seenIds.has(id)) return;
    seenIds.add(id);
    const content = (s.content || "").trim();
    if (!content) return;
    snippetList.push(`${s.path || s.file_path} (L${s.start_line || s.startLine}-${s.end_line || s.endLine})\n${content}`);
  }

  for (const q of ["project readme overview", "context"]) {
    const res = search(q, { limit: 25, maxChars: 8000 });
    if (res.ok && Array.isArray(res.snippets)) {
      for (const s of res.snippets) addSnippet(s);
    }
  }

  let offset = 0;
  const batchSize = 100;
  const maxChunks = 500;
  report("Reading indexed files...");
  while (snippetList.length < maxChunks) {
    const rows = db.getChunksBatch ? db.getChunksBatch(batchSize, offset) : [];
    if (rows.length === 0) break;
    for (const r of rows) addSnippet(r);
    offset += batchSize;
  }

  const indexedText = snippetList.join("\n\n");
  const totalContext = (memoryContext || "").trim() + "\n\n" + indexedText.trim();
  if (totalContext.trim().length < 50) {
    throw new Error("Add content first (run Index All or add .md files to .synapse).");
  }

  // Split indexed content into batches of ~15K chars
  const batches = [];
  let remaining = indexedText.trim();
  while (remaining.length > 0 && batches.length < SELF_SYNAPSE_MAX_ITERATIONS) {
    const chunk = remaining.length <= SELF_SYNAPSE_CHARS_PER_BATCH
      ? remaining
      : remaining.slice(0, SELF_SYNAPSE_CHARS_PER_BATCH) + "\n\n[... batch continues ...]";
    batches.push(chunk);
    remaining = remaining.slice(SELF_SYNAPSE_CHARS_PER_BATCH);
  }
  if (batches.length === 0) batches.push(indexedText.trim() || "(No indexed content)");
  
  report(`Created ${batches.length} context batch(es)...`);

  const templateBlock = MEMORY_FILE_NAMES.map((n) => `--- ${n} ---\n${TEMPLATES[n] || ""}`).join("\n\n");

  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let currentMemory = memoryContext || "";
  const filesUpdated = new Set();

  for (let i = 0; i < batches.length && i < SELF_SYNAPSE_MAX_ITERATIONS; i++) {
    report(`Analyzing batch ${i + 1} of ${batches.length} with Grok...`);
    const batch = batches[i];
    const isFirst = i === 0;

    const systemPrompt = `You are filling out a project's .synapse memory. The project may be code, design, docs, writing, or mixed — adapt the structure accordingly. Use ONLY the context below. Preserve section structure (## Headers); replace placeholders with real content. For codebase.md: if no code, produce "Key files / assets / structure" instead. Output each file in this exact format: --- filename --- then the content. No other text.`;

    const userContent = isFirst
      ? `Fill out the memory files from this context. Follow the template structure. Output format: --- filename --- then content for each of: ${MEMORY_FILE_NAMES.join(", ")}.

--- Templates (structure to follow) ---
${templateBlock}

--- Project context ---
${currentMemory}

--- Indexed content (batch ${i + 1}/${batches.length}) ---
${batch}

Output each file as --- filename --- followed by its content.`
      : `Update the memory files to incorporate this additional context. Preserve and refine existing content; add new insights. Output format: --- filename --- then content.

--- Current memory ---
${currentMemory}

--- Additional indexed content (batch ${i + 1}/${batches.length}) ---
${batch}

Output each file as --- filename --- followed by its content.`;

    const result = await chatCompletion(apiKey, [
      { role: "system", content: systemPrompt },
      { role: "user", content: userContent },
    ], { max_tokens: 4096 });

    totalInputTokens += result.inputTokens;
    totalOutputTokens += result.outputTokens;

    const parsed = parseMemoryFileOutput(result.content || "");
    if (parsed.size === 0) {
      throw new Error("Grok output could not be parsed. Expected --- filename --- delimiters.");
    }

    report(`Writing ${parsed.size} updated memory files...`);
    for (const [name, content] of parsed) {
      const filePath = path.join(synapseDir, name);
      fs.writeFileSync(filePath, content, "utf8");
      filesUpdated.add(name);
    }

    currentMemory = readSynapseFilesAsContext(projectRoot);
  }

  report("Self Synapse complete.");
  return {
    ok: true,
    filesUpdated: Array.from(filesUpdated),
    chunksProcessed: batches.length,
    inputTokens: totalInputTokens,
    outputTokens: totalOutputTokens,
  };
}

module.exports = {
  chatCompletion,
  readSynapseFilesAsContext,
  suggestAndCreateSkill,
  suggestChunksForPrompt,
  suggestSnippetSpecs,
  suggestLearnings,
  selfSynapse,
  buildSkillFormatPrompt,
  buildSubagentContext,
  optimizePrompt,
  chatTurn,
  DEFAULT_MAX_CHUNKS_FOR_PROMPT,
  AVG_TOKENS_PER_CHUNK,
};
