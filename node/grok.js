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
  const names = ["projectbrief.md", "activeContext.md", "progress.md", "thoughts.md", "learnings.md"];
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
  const prompt = `You are a technical writer. Based on the following project context, suggest ONE skill file that would help an AI agent work on this codebase. Reply with exactly two lines:
Line 1: the filename only, e.g. skill-project-conventions.md or skill-api-patterns.md (choose a name that fits THIS project).
Line 2: the markdown content for that file (YAML frontmatter with name, tags, then sections: Overview, Rules, Examples). Keep it under 150 lines.

Project context:
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
 * Returns { chunkIds: number[], optimizedPrompt?: string }. chunkIds capped at maxChunks.
 */
async function suggestChunksForPrompt(apiKey, userPrompt, chunkDescriptions, maxChunks) {
  const cap = (Number.isInteger(maxChunks) && maxChunks >= 1) ? maxChunks : DEFAULT_MAX_CHUNKS_FOR_PROMPT;
  const systemPrompt = `You respond only with a single JSON object. No markdown, no code fences, no explanation.
Valid keys:
  "chunkIds": array of chunk id integers, at most ${cap}, most relevant first.
  "optimizedPrompt": optional string — a sharper, more specific rewrite of the user's prompt.

Selection rules — follow strictly:
1. Include a chunk ONLY when it is DIRECTLY and CERTAINLY relevant to the user's question. Vague or tangential relevance is NOT sufficient — exclude those chunks.
2. Fewer precise chunks beat more mediocre ones. Aim for 1–3 chunks unless more are clearly and unambiguously necessary (hard cap: ${cap}).
3. Each included chunk costs ~${AVG_TOKENS_PER_CHUNK} tokens in Cursor's context window. Treat every inclusion as a real budget cost.
4. EXCLUDE: generic boilerplate, progress logs unrelated to the question, duplicate information, anything the user did not explicitly ask about.
5. Domain matching: UI/frontend questions → UI/View/Dashboard/Form chunks only. Backend/service questions → service/API/DB chunks only. Do NOT mix domains unless the question explicitly spans both.`;

  const limited = chunkDescriptions.slice(0, MAX_DESCRIPTIONS_IN_PROMPT);
  const userMessage = `User prompt: "${userPrompt}"

Available chunks (id, path, startLine, endLine, preview):
${JSON.stringify(limited)}

Select only the chunks that are DIRECTLY and CERTAINLY relevant (max ${cap}). When in doubt, exclude. Return JSON only: { "chunkIds": [1, 2, ...], "optimizedPrompt": "optional sharper prompt" }`;

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
  const prompt = `You are summarizing project memory into persistent learnings for future sessions.

Project memory (projectbrief, activeContext, progress, thoughts):
${memoryContext}

${existingLearnings ? `Existing learnings (do not duplicate):\n${existingLearnings}\n\n` : ""}
Extract 5–12 concise learnings: conventions, key decisions, gotchas, patterns, or facts that should be remembered for the next session. Output ONLY a markdown bullet list (each line starting with "- "). No headers, no preamble. One learning per bullet.`;

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
 */
async function buildSkillFormatPrompt(apiKey, userPrompt, dbSnippets, memorySnippets) {
  const systemPrompt = `You are a senior software engineer preparing a precise, actionable task directive for another senior engineer.
Your output must be ONLY a structured task prompt — no preamble, no explanation, no pleasantries.

Directives:
1. Address the implementing engineer directly; assume full technical competency — no hand-holding.
2. Be clear and concise — every sentence must carry information. No filler, no hedging, no padding.
3. Preserve original context exactly — do not invent requirements, rename symbols, or change scope.
4. Ensure flawless execution — every step must be unambiguous with no implicit assumptions left for the implementer to guess.
5. Eliminate ambiguity — if a step could be misinterpreted, state the intent explicitly.
6. Mitigate risk — flag destructive operations, state what must NOT be changed, and specify fallback behavior where relevant.
7. Domain isolation — UI tasks stay in UI files; service/backend tasks stay in service files. Do not bleed scope across domains.

Output rules:
- Total output length: 800–1800 characters.
- Structure: YAML frontmatter (name, description, optional tags), then ## Instructions, then ## Examples. No other sections. Do NOT include ## Troubleshooting, ## Steps, ## Context, ## If Blocked, or any other section.
- The description value must be an imperative sentence stating what the agent must DO (e.g. "Add tabbed navigation to DashboardView"). Never "A guide to…", "Step-by-step guide to…", or any phrasing that describes the document rather than the action.
- Address ONLY the user's stated task or fix. Do not expand scope or add unrequested work.
- Output ONLY the skill markdown. No \`\`\`markdown fences, no surrounding text.`;

  const userMessage = `User prompt:
${userPrompt || "(no prompt)"}

Database/code snippets (selected chunks):
${dbSnippets || "(none)"}

Memory snippets (.synapse: projectbrief, activeContext, progress, thoughts, learnings):
${memorySnippets || "(none)"}

Produce a skill.md block (800–1800 chars) with ONLY: YAML frontmatter, ## Instructions, ## Examples. Do NOT add ## Troubleshooting or any other section. Output ONLY the markdown.`;

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
 */
async function buildSubagentContext(apiKey, userPrompt, dbSnippets, memorySnippets) {
  const systemPrompt = `You are a senior software engineer preparing a complete context package for a parallel subagent (another senior engineer working independently).
Your output gives the subagent everything it needs to execute without asking questions.

Directives:
1. Address the subagent as a senior engineer — be direct, technical, and assume full competency.
2. Be clear and concise — distill to what matters. No padding, no repetition.
3. Preserve original context faithfully — summarize from .synapse memory without inventing or omitting key facts.
4. Ensure flawless execution — leave no gaps; the subagent must not need to infer unstated context.
5. Eliminate ambiguity — make current state, active conventions, and task scope explicit.
6. Mitigate risk — state what must NOT be changed, known gotchas, and what to do if blocked.

Structure your output:
- Lead with a rich, distilled summary of: project goals, current focus, key decisions, progress, and learnings (from .synapse memory).
- Follow with the subagent's specific task and any directly-relevant code snippets.
- End with a brief "Do not change" list and fallback instructions if blocked.

Secondary: DB/code snippets only where directly needed. Avoid bloat — every included snippet must earn its token cost.`;

  const userMessage = `User request (what the subagent should do):
${userPrompt || "(no prompt)"}

--- PRIMARY: Project memory (.synapse) ---
${memorySnippets || "(no memory files)"}

--- SECONDARY: Code/DB snippets (include only if directly relevant) ---
${dbSnippets || "(none)"}

Produce the subagent context package. Lead with memory-derived context; add code only where necessary.`;

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
  const systemPrompt = `You are a senior software engineer sharpening a Cursor task prompt.
Given the user's rough prompt and project context, return ONLY a rewritten, more specific, and actionable version.

Rules:
1. Preserve the user's intent exactly — only make it more precise.
2. Reference specific files, functions, or patterns from the project context when relevant.
3. Keep it concise: 1–4 sentences or a tight bullet list.
4. Output ONLY the improved prompt text. No preamble, no quotes, no explanation.`;

  const userMessage = `Original prompt: ${userPrompt}

Project context:
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
