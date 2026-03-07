"use strict";

const fs = require("fs");
const path = require("path");

// Endpoint and models: see .cursor/knowledge/grok_api.md
// Debug: logs request/response to stderr (stdout is used for JSON-RPC).
async function chatCompletion(apiKey, messages, options = {}) {
  const model = options.model || "grok-code-fast-1";
  const maxTokens = options.max_tokens ?? 2048;
  const body = { model, messages, max_tokens: maxTokens };
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
  const content = data.choices?.[0]?.message?.content ?? "";
  const usage = data.usage ?? {};
  const inputTokens = usage.input_tokens ?? usage.prompt_tokens ?? 0;
  const outputTokens = usage.output_tokens ?? usage.completion_tokens ?? 0;
  return {
    content,
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

const DEFAULT_MAX_CHUNKS_FOR_PROMPT = 5;
const MAX_DESCRIPTIONS_IN_PROMPT = 80;
/** Rough chars-per-chunk (MAX_CHUNK_CHARS in chunk.js) divided by ~4 chars/token. */
const AVG_TOKENS_PER_CHUNK = 300;

/**
 * Ask Grok which chunks to include for a user prompt. API response must be JSON only.
 * chunkDescriptions: [{ id, path, startLine, endLine, preview }]
 * maxChunks: user-configurable cap (default DEFAULT_MAX_CHUNKS_FOR_PROMPT).
 * memoryFirstMode: when true, prioritize memory chunks (paths containing .synapse/) in selection.
 * Returns { chunkIds: number[], optimizedPrompt?: string }. chunkIds capped at maxChunks.
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

Selection rules — follow strictly:
1. Include a chunk ONLY when it is DIRECTLY and CERTAINLY relevant. Vague relevance → exclude. Hard cap: ${cap}.
2. Fewer precise chunks beat more; each costs ~${AVG_TOKENS_PER_CHUNK} tokens. Treat inclusion as budget.
3. EXCLUDE: boilerplate, unrelated logs, duplicates, anything not explicitly asked.
4. Domain matching: UI questions → UI/View/Dashboard/Form chunks only. Backend questions → service/API/DB only. Do NOT mix unless the question spans both.${memoryFirstRule ? "\n" + memoryFirstRule : ""}

Return only valid JSON.`;

  const limited = chunkDescriptions.slice(0, MAX_DESCRIPTIONS_IN_PROMPT);
  const userMessage = `Use ONLY the chunks listed below. Do not reference any other files or ids.

User prompt: "${userPrompt}"

--- Available chunks (id, path, startLine, endLine, preview) ---
${JSON.stringify(limited)}

Select only chunks DIRECTLY and CERTAINLY relevant (max ${cap}). When in doubt, exclude. Return JSON only: { "chunkIds": [1, 2, ...], "optimizedPrompt": "optional sharper prompt" }`;

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
  chunkIds = chunkIds.filter((id) => Number.isInteger(id) && id > 0).slice(0, cap);
  const optimizedPrompt = typeof parsed.optimizedPrompt === "string" ? parsed.optimizedPrompt.trim() : null;
  return { chunkIds, optimizedPrompt, inputTokens: result.inputTokens, outputTokens: result.outputTokens };
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

Output rules (total length 800–1800 chars; if it would exceed, trim to essentials):
- Structure: YAML frontmatter (name, description, optional tags), then ## Context, then ## Instructions, then ## Examples, then ## Verification. No other sections. Do NOT include ## Troubleshooting, ## Steps, ## If Blocked, or any other section.
- ## Context (mandatory, immediately after frontmatter): Open with "You have all needed context. Do not perform file reads, greps, or directory listings — work only from this skill." Then concise, task-relevant excerpts from the provided memory only. Focus on: project purpose, goals, MVP scope, key decisions, learnings, codebase map. Keep ## Context under 400 characters. Do not instruct the agent to open or read any file; everything needed must be in this skill.
- ## Verification: exactly 1–2 bullets — one for text-based test criteria the agent should create, one for what the agent should ask the human to verify (e.g. "Ask the human to run the app, open X screen, confirm Y, and report back."). Phrase as the agent speaking to the human, not as commands. Be concrete.
- The description value must be an imperative sentence (e.g. "Add tabbed navigation to DashboardView"). Never "A guide to…" or "Step-by-step guide to…".
- Address ONLY the user's stated task. Do not expand scope. Output must not reference non-inline items; no file paths as instructions to read.
- Output ONLY the skill markdown. No \`\`\`markdown fences, no surrounding text.`;

  const userMessage = `Use ONLY the three blocks below. Do not reference external files or DBs.

User prompt:
${userPrompt || "(no prompt)"}

--- Database/code snippets (selected chunks) ---
${dbSnippets || "(none)"}

--- Memory snippets (.synapse) ---
${memorySnippets || "(none)"}

Produce a skill.md (800–1800 chars) using ONLY the blocks above: YAML frontmatter, ## Context (mandatory — open with "You have all needed context. Do not read files outside this skill." then excerpts from memory; under 400 chars), ## Instructions, ## Examples, ## Verification. Do not instruct the agent to open or read any file. Do NOT add ## Troubleshooting or other sections. Output ONLY the markdown.`;

  const result = await chatCompletion(apiKey, [
    { role: "system", content: systemPrompt },
    { role: "user", content: userMessage },
  ], { max_tokens: 1536 });

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
- ## Context (mandatory, first section): Open with "You have all needed context. Do not perform file reads, greps, or directory listings — work only from this package." Then concise, task-relevant excerpts from the provided memory. Focus on: project purpose, goals, MVP scope, key decisions, learnings, codebase map. Keep Context under 400 characters.
- ## Instructions: The subagent's specific task and any directly-relevant code snippets. Do not instruct the subagent to open or read any file; everything needed is in this package.
- End with a brief "Do not change" list and fallback instructions if blocked.

Secondary: DB/code snippets only where directly needed. Avoid bloat — every included snippet must earn its token cost.`;

  const userMessage = `User request (what the subagent should do):
${userPrompt || "(no prompt)"}

--- PRIMARY: Project memory (.synapse) ---
${memorySnippets || "(no memory files)"}

--- SECONDARY: Code/DB snippets (include only if directly relevant) ---
${dbSnippets || "(none)"}

Produce the subagent context package using ONLY the PRIMARY and SECONDARY blocks above. Do not reference external files or DBs. Start with ## Context (mandatory — open with "You have all needed context. Do not read files outside this package." then excerpts from memory; under 400 chars). Then ## Instructions with the task and code. Total output under 8K chars; if over, trim or output "Error: Exceeds 8K chars; trim to essentials." Add "Do not change" and fallback if blocked.`;

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
async function optimizePrompt(apiKey, userPrompt, memorySnippets) {
  const systemPrompt = `You are sharpening a Cursor task prompt. Use ONLY the project context provided below. Forbidden: referencing files, paths, or symbols not mentioned in that context. If context is missing, make the prompt precise without inventing file names. Output ONLY the improved prompt text — no preamble, no quotes, no explanation.

Rules:
1. Preserve the user's intent exactly — only make it more precise.
2. Reference specific files, functions, or patterns only from the provided context.
3. Keep it concise: 1–4 sentences or a tight bullet list.
4. Output ONLY the improved prompt.`;

  const userMessage = `Use ONLY the project context below. Do not reference external files.

Original prompt: ${userPrompt}

--- Project context ---
${memorySnippets || "(none)"}

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

module.exports = {
  chatCompletion,
  readSynapseFilesAsContext,
  suggestAndCreateSkill,
  suggestChunksForPrompt,
  suggestLearnings,
  buildSkillFormatPrompt,
  buildSubagentContext,
  optimizePrompt,
  DEFAULT_MAX_CHUNKS_FOR_PROMPT,
  AVG_TOKENS_PER_CHUNK,
};
