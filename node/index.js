#!/usr/bin/env node
"use strict";

/**
 * Synapse Node bridge – stdio JSON-RPC server.
 * Methods: ping, setProject(root)
 */

const readline = require("readline");
const path = require("path");
const fs = require("fs");
const { initSynapseFolder } = require("./synapse-init.js");
const { startWatching, stopWatching } = require("./watch.js");
const db = require("./db.js");
const { chunkFile } = require("./chunk.js");
const { search } = require("./search.js");
const grok = require("./grok.js");

const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });

let projectRoot = null;

/** Read file from projectRoot + relativePath, return lines startLine–endLine (1-based inclusive). Path must be under projectRoot. */
function getSnippetContentByPath(root, relativePath, startLine, endLine) {
  if (!root || !relativePath || !Number.isInteger(startLine) || !Number.isInteger(endLine) || startLine < 1 || endLine < startLine) return null;
  const resolved = path.resolve(root, relativePath);
  const relative = path.relative(root, resolved);
  if (relative.startsWith("..") || path.isAbsolute(relative)) return null;
  try {
    const content = fs.readFileSync(resolved, "utf8");
    const lines = content.split("\n");
    const start = Math.max(0, startLine - 1);
    const end = Math.min(lines.length, endLine);
    if (start >= end) return null;
    return lines.slice(start, end).join("\n");
  } catch (_) {
    return null;
  }
}

/** Max snippets to collect from keywordSearches (avoids token explosion). */
const MAX_SNIPPETS_FROM_KEYWORD_SEARCHES = 15;

/** Extract PascalCase type-like names (View, Content, Service, ViewModel, etc.) from prompt for targeted chunk surfacing. */
function extractTypeNamesFromPrompt(prompt) {
  const trimmed = (prompt || "").trim();
  if (!trimmed) return [];
  const matches = trimmed.match(/\b([A-Z][a-zA-Z]*(?:View|Content|Service|ViewModel|Controller)\b)/g);
  return matches ? [...new Set(matches)].slice(0, 5) : [];
}

/** Build a short FTS-friendly query to surface source code chunks (types, functions, keywords from the prompt). */
function buildCodeBoostQuery(prompt) {
  const trimmed = (prompt || "").trim();
  if (!trimmed) return "";
  const lower = trimmed.toLowerCase();
  const tokens = trimmed.split(/\s+/).filter(Boolean);
  const camelCase = tokens.filter((t) => /^[A-Z][a-z]+(?:[A-Z][a-z]*)*$/.test(t) || /^[a-z]+[A-Z][a-zA-Z]*$/.test(t));
  const keywords = tokens
    .map((s) => s.replace(/[^\w\u0080-\uFFFF]/g, "").toLowerCase())
    .filter((w) => w.length > 3 && !/^(that|this|with|from|when|then|have|need|should|will|your|about|into|only|some|more|other)$/.test(w));
  let parts = [...new Set([...camelCase, ...keywords.slice(0, 5)])].slice(0, 6);
  // When prompt is about animation/loading/UI, add terms that appear in Swift UI code so FTS surfaces .swift chunks.
  if (/\b(animation|loading|view|ui|swift)\b/.test(lower)) {
    parts = [...new Set([...parts, "ProcessAnimationView", "View", "animation"])].slice(0, 8);
  }
  return parts.length > 0 ? parts.join(" ") : "View animation index recordIndexTime";
}

/**
 * Retrieve snippet text from parsed spec: chunkIds, snippetSpecs, keywordSearches.
 * Returns a single string formatted as "path (Lstart-end)\ncontent" per snippet for buildSkillFormatPrompt.
 */
function retrieveSnippetsFromSpec(root, parsed) {
  const parts = [];
  const seenChunkIds = new Set();

  if (Array.isArray(parsed.chunkIds) && parsed.chunkIds.length > 0) {
    const chunks = db.getChunksById(parsed.chunkIds);
    for (const c of chunks) {
      parts.push(`${c.file_path} (L${c.start_line}-${c.end_line})\n${c.content || ""}`);
      seenChunkIds.add(c.id);
    }
  }

  if (Array.isArray(parsed.snippetSpecs) && parsed.snippetSpecs.length > 0) {
    for (const spec of parsed.snippetSpecs) {
      const content = getSnippetContentByPath(root, spec.path, spec.startLine, spec.endLine);
      if (content != null) parts.push(`${spec.path} (L${spec.startLine}-${spec.endLine})\n${content}`);
    }
  }

  if (Array.isArray(parsed.keywordSearches) && parsed.keywordSearches.length > 0) {
    const keywordSnippets = [];
    for (const q of parsed.keywordSearches) {
      const res = search(q, { limit: 5, maxChars: 10000 });
      if (res.ok && Array.isArray(res.snippets)) {
        for (const s of res.snippets) {
          if (seenChunkIds.has(s.id)) continue;
          if (keywordSnippets.length >= MAX_SNIPPETS_FROM_KEYWORD_SEARCHES) break;
          seenChunkIds.add(s.id);
          keywordSnippets.push(`${s.path} (L${s.startLine}-${s.endLine})\n${s.content || ""}`);
        }
      }
      if (keywordSnippets.length >= MAX_SNIPPETS_FROM_KEYWORD_SEARCHES) break;
    }
    parts.push(...keywordSnippets);
  }

  return parts.join("\n\n");
}

function send(obj) {
  console.log(JSON.stringify(obj));
}

function handleRequest(msg) {
  let id = null;
  let method = "";
  let params = [];
  try {
    const req = typeof msg === "string" ? JSON.parse(msg) : msg;
    id = req.id;
    method = req.method || "";
    params = Array.isArray(req.params) ? req.params : req.params != null ? [req.params] : [];
  } catch (_) {
    send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }

  function reply(result) {
    send({ jsonrpc: "2.0", id, result });
  }
  function replyError(code, message) {
    send({ jsonrpc: "2.0", id, error: { code, message } });
  }

  if (method === "ping") {
    reply({ pong: true });
    return;
  }
  if (method === "setProject") {
    const root = params[0] == null ? null : String(params[0]);
    stopWatching();
    db.close();
    projectRoot = root || null;
    if (projectRoot) {
      const initResult = initSynapseFolder(projectRoot);
      if (!initResult.ok) {
        replyError(-32000, initResult.error || "Init failed");
        return;
      }
      db.open(projectRoot);
      startWatching(projectRoot, (notification) => {
        send({ jsonrpc: "2.0", method: notification.method, params: notification.params });
      });
    }
    reply({ ok: true, path: projectRoot });
    return;
  }

  if (method === "indexFile") {
    const fileParam = params[0];
    const filePath = fileParam == null ? null : path.resolve(projectRoot || ".", String(fileParam));
    if (!filePath || !fs.existsSync(filePath)) {
      replyError(-32000, "File not found: " + fileParam);
      return;
    }
    const chunkResult = chunkFile(filePath);
    if (!chunkResult.ok) {
      replyError(-32000, chunkResult.error || "Chunk failed");
      return;
    }
    const relPath = projectRoot ? path.relative(projectRoot, filePath) : filePath;
    const upsert = db.upsertDocument(filePath, chunkResult.digest, chunkResult.chunks);
    reply({ ok: true, path: relPath, chunksCount: upsert.chunksCount });
    return;
  }

  if (method === "indexAll") {
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    const indexStartMs = Date.now();
    // Ensure .synapse and all memory templates exist before indexing (missing files are created, not overwritten).
    initSynapseFolder(projectRoot);
    const synapseDir = path.join(projectRoot, ".synapse");
    if (!fs.existsSync(synapseDir)) {
      reply({ ok: true, indexed: 0, indexTimeMs: 0 });
      return;
    }

    // Walk that collects only .md files (for .synapse and indexFolders).
    const walk = (dir) => {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      const files = [];
      for (const e of entries) {
        const full = path.join(dir, e.name);
        if (e.isDirectory() && e.name !== ".." && e.name !== ".") {
          files.push(...walk(full));
        } else if (e.isFile() && /\.md$/i.test(e.name)) {
          files.push(full);
        }
      }
      return files;
    };

    // Walk with extension filter and excluded directory names (e.g. node_modules, .git).
    const DEFAULT_EXCLUDE_DIRS = ["node_modules", ".git", "build", "DerivedData", ".build"];
    const DEFAULT_INDEX_EXTENSIONS = [".md", ".swift", ".js", ".ts", ".json"];
    function walkWithExtensions(dir, extensions, excludeDirs) {
      const extSet = new Set(extensions.map((e) => e.toLowerCase()));
      const excludeSet = new Set((excludeDirs || DEFAULT_EXCLUDE_DIRS).map((d) => d.toLowerCase()));
      const out = [];
      function rec(d) {
        let entries;
        try {
          entries = fs.readdirSync(d, { withFileTypes: true });
        } catch (_) {
          return;
        }
        for (const e of entries) {
          const full = path.join(d, e.name);
          if (e.isDirectory() && e.name !== ".." && e.name !== ".") {
            if (!excludeSet.has(e.name.toLowerCase())) rec(full);
          } else if (e.isFile()) {
            const ext = path.extname(e.name).toLowerCase();
            if (extSet.has(ext)) out.push(full);
          }
        }
      }
      rec(dir);
      return out;
    }

    const configPath = path.join(synapseDir, "config.json");
    let indexFolders = [];
    let indexFullProject = false;
    let indexExtensions = DEFAULT_INDEX_EXTENSIONS;
    let indexDirs = null;
    if (fs.existsSync(configPath)) {
      try {
        const raw = fs.readFileSync(configPath, "utf8");
        const cfg = JSON.parse(raw);
        if (Array.isArray(cfg.indexFolders)) {
          indexFolders = cfg.indexFolders.filter((f) => typeof f === "string" && f.trim().length > 0);
        }
        if (cfg.indexFullProject === true) {
          indexFullProject = true;
          if (Array.isArray(cfg.indexExtensions) && cfg.indexExtensions.length > 0) {
            indexExtensions = cfg.indexExtensions.filter((e) => typeof e === "string" && e.startsWith("."));
          }
          if (Array.isArray(cfg.indexDirs) && cfg.indexDirs.length > 0) {
            indexDirs = cfg.indexDirs.filter((d) => typeof d === "string" && d.trim().length > 0);
          }
        }
      } catch (_) {}
    }

    let indexed = 0;

    // 1) Index .synapse/*.md (chunkFile now handles .md via chunkMarkdown).
    const mdFiles = walk(synapseDir);
    for (const f of mdFiles) {
      const result = chunkFile(f);
      if (result.ok) {
        db.upsertDocument(f, result.digest, result.chunks);
        indexed++;
      }
    }

    // 2) Index additional folders from config (indexFolders) — .md only for backward compatibility.
    for (const rel of indexFolders) {
      const resolved = path.resolve(projectRoot, rel);
      const relative = path.relative(projectRoot, resolved);
      if (relative.startsWith("..") || path.isAbsolute(relative)) continue;
      if (!fs.existsSync(resolved)) continue;
      let stat;
      try {
        stat = fs.statSync(resolved);
      } catch (_) {
        continue;
      }
      if (!stat.isDirectory()) continue;
      const extraFiles = walk(resolved);
      for (const f of extraFiles) {
        const result = chunkFile(f);
        if (result.ok) {
          db.upsertDocument(f, result.digest, result.chunks);
          indexed++;
        }
      }
    }

    // 3) Full-project index: walk project (or indexDirs) with indexExtensions and exclusions.
    // When walking from projectRoot, exclude .synapse so we don't double-index (already done in step 1).
    if (indexFullProject) {
      const roots = indexDirs && indexDirs.length > 0
        ? indexDirs.map((rel) => path.resolve(projectRoot, rel)).filter((p) => fs.existsSync(p))
        : [projectRoot];
      const seen = new Set();
      for (const root of roots) {
        const relRoot = path.relative(projectRoot, root);
        if (relRoot.startsWith("..") || path.isAbsolute(relRoot)) continue;
        const excludeDirs = root === projectRoot
          ? [...DEFAULT_EXCLUDE_DIRS, ".synapse"]
          : DEFAULT_EXCLUDE_DIRS;
        const files = walkWithExtensions(root, indexExtensions, excludeDirs);
        for (const f of files) {
          const rel = path.relative(projectRoot, f);
          if (rel.startsWith("..") || path.isAbsolute(rel)) continue;
          if (seen.has(rel)) continue;
          seen.add(rel);
          const result = chunkFile(f);
          if (result.ok) {
            db.upsertDocument(f, result.digest, result.chunks);
            indexed++;
          }
        }
      }
    }

    const indexTimeMs = Date.now() - indexStartMs;
    const stats = db.getStats();
    reply({ ok: true, indexed, indexTimeMs, stats });
    return;
  }

  if (method === "search") {
    const query = params[0] != null ? String(params[0]) : "";
    const opts = params[1] && typeof params[1] === "object" ? params[1] : {};
    const result = search(query, opts);
    reply(result);
    return;
  }

  if (method === "getStats") {
    reply(db.getStats());
    return;
  }

  if (method === "getAllConnections") {
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    try {
      reply(db.getAllConnections());
    } catch (err) {
      replyError(-32000, err.message || "getAllConnections failed");
    }
    return;
  }

  if (method === "getLastContextChunkIds") {
    if (!projectRoot) {
      reply({ chunkIds: [], filePaths: [] });
      return;
    }
    try {
      reply(db.getLastContextChunkIds());
    } catch (err) {
      reply({ chunkIds: [], filePaths: [] });
    }
    return;
  }

  if (method === "buildContextForPrompt") {
    const apiKey = params[0];
    const userPrompt = params[1];
    const maxChunks = (Number.isInteger(params[2]) && params[2] >= 1) ? params[2] : undefined;
    const memoryFirstMode = params[3] === true;
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }

    const promptStr = String(userPrompt || "").trim() || "context";

    // Build candidate list so code is guaranteed: search + code-boost search + explicit code chunks from DB, then memory.
    const searchRes = search(userPrompt || "context", { limit: 40, maxChars: 50000 });
    const searchDescriptions = (searchRes.snippets || []).map(s => ({
      id: s.id,
      path: s.path,
      startLine: s.startLine,
      endLine: s.endLine,
      preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
    }));
    const codeBoostQuery = buildCodeBoostQuery(promptStr);
    const codeRes = codeBoostQuery ? search(codeBoostQuery, { limit: 40, maxChars: 50000 }) : { ok: false, snippets: [] };
    const codeDescriptions = (codeRes.snippets || []).map(s => ({
      id: s.id,
      path: s.path,
      startLine: s.startLine,
      endLine: s.endLine,
      preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
    }));
    // Explicit code chunks from DB: FTS often ranks .md higher (e.g. "animation" in prose); adding code by path guarantees Grok sees .swift/.js/.ts.
    const allDescriptions = db.getChunkDescriptions();
    const codeChunkDescriptions = allDescriptions
      .filter((c) => c.path && /\.(swift|js|ts)$/i.test(c.path))
      .slice(0, 60);
    const memoryChunks = allDescriptions.filter((c) => c.path && c.path.includes(".synapse/"));
    // When prompt mentions a type (e.g. ProjectDashboardContent), surface chunks that contain it so the skill can reference that code.
    const typeNames = extractTypeNamesFromPrompt(promptStr);
    const typeChunkDescriptions = [];
    for (const name of typeNames) {
      const res = search(name, { limit: 5, maxChars: 50000 });
      if (res.ok && res.snippets) {
        for (const s of res.snippets) {
          typeChunkDescriptions.push({
            id: s.id,
            path: s.path,
            startLine: s.startLine,
            endLine: s.endLine,
            preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
          });
        }
      }
    }
    const combined = [...typeChunkDescriptions, ...searchDescriptions, ...codeDescriptions, ...codeChunkDescriptions, ...memoryChunks];
    const uniqueMap = new Map();
    for (const c of combined) {
      if (!uniqueMap.has(c.id)) uniqueMap.set(c.id, c);
    }
    const descriptions = Array.from(uniqueMap.values());

    if (descriptions.length === 0) {
      replyError(-32000, "No chunks in index. Run Index All first.");
      return;
    }

    const memorySnippets = grok.readSynapseFilesAsContext(projectRoot);

    grok
      .suggestChunksForPrompt(apiKey, promptStr, descriptions, maxChunks, memoryFirstMode)
      .then((out) => {
        const ids = out.chunkIds.filter((id) => Number.isInteger(id) && id > 0);
        const chunks = db.getChunksById(ids);
        const dbSnippets = chunks
          .map((c) => `${c.file_path} (L${c.start_line}-${c.end_line})\n${c.content || ""}`)
          .join("\n\n");
        const AVG_TOKENS_PER_CHUNK = 300;
        const savedChunks = descriptions.length - chunks.length;
        const estimatedSavedTokens = Math.max(0, savedChunks) * AVG_TOKENS_PER_CHUNK;
        // Use optimized prompt when present so skill is task-focused even when 0 chunks selected
        const skillPrompt = (out.optimizedPrompt && out.optimizedPrompt.trim()) ? out.optimizedPrompt.trim() : promptStr;

        return grok
          .buildSkillFormatPrompt(apiKey, skillPrompt, dbSnippets, memorySnippets)
          .then((skillOut) => {
            db.saveLastContext(ids);
            reply({
              ok: true,
              block: skillOut.content,
              optimizedPrompt: out.optimizedPrompt || null,
              chunkCount: chunks.length,
              totalDescriptions: descriptions.length,
              estimatedSavedTokens,
              inputTokens: out.inputTokens + skillOut.inputTokens,
              outputTokens: out.outputTokens + skillOut.outputTokens,
            });
          })
          .catch((err) => {
            // Fallback: legacy block when Grok skill-format fails
            db.saveLastContext(ids);
            const optimizedPrompt = out.optimizedPrompt || promptStr;
            const lines = [optimizedPrompt, ""];
            for (const c of chunks) {
              lines.push(`@${c.file_path} (lines ${c.start_line}-${c.end_line})`);
              lines.push(c.content || "");
              lines.push("");
            }
            const block = lines.join("\n").trim();
            reply({
              ok: true,
              block,
              optimizedPrompt: out.optimizedPrompt || null,
              chunkCount: chunks.length,
              totalDescriptions: descriptions.length,
              estimatedSavedTokens,
              inputTokens: out.inputTokens,
              outputTokens: out.outputTokens,
            });
          });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Grok failed");
      });
    return;
  }

  if (method === "buildContextForPromptV2") {
    const apiKey = params[0];
    const userPrompt = params[1];
    const maxChunks = (Number.isInteger(params[2]) && params[2] >= 1) ? params[2] : undefined;
    const memoryFirstMode = params[3] === true;
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }

    const promptStr = String(userPrompt || "").trim() || "context";
    const searchRes = search(userPrompt || "context", { limit: 40, maxChars: 50000 });
    const searchDescriptions = (searchRes.snippets || []).map(s => ({
      id: s.id,
      path: s.path,
      startLine: s.startLine,
      endLine: s.endLine,
      preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
    }));
    const codeBoostQuery = buildCodeBoostQuery(promptStr);
    const codeRes = codeBoostQuery ? search(codeBoostQuery, { limit: 40, maxChars: 50000 }) : { ok: false, snippets: [] };
    const codeDescriptions = (codeRes.snippets || []).map(s => ({
      id: s.id,
      path: s.path,
      startLine: s.startLine,
      endLine: s.endLine,
      preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
    }));
    const allDescriptions = db.getChunkDescriptions();
    const codeChunkDescriptions = allDescriptions
      .filter((c) => c.path && /\.(swift|js|ts)$/i.test(c.path))
      .slice(0, 60);
    const memoryChunks = allDescriptions.filter((c) => c.path && c.path.includes(".synapse/"));
    const typeNames = extractTypeNamesFromPrompt(promptStr);
    const typeChunkDescriptions = [];
    for (const name of typeNames) {
      const res = search(name, { limit: 5, maxChars: 50000 });
      if (res.ok && res.snippets) {
        for (const s of res.snippets) {
          typeChunkDescriptions.push({
            id: s.id,
            path: s.path,
            startLine: s.startLine,
            endLine: s.endLine,
            preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
          });
        }
      }
    }
    const combined = [...typeChunkDescriptions, ...searchDescriptions, ...codeDescriptions, ...codeChunkDescriptions, ...memoryChunks];
    const uniqueMap = new Map();
    for (const c of combined) {
      if (!uniqueMap.has(c.id)) uniqueMap.set(c.id, c);
    }
    const descriptions = Array.from(uniqueMap.values());

    if (descriptions.length === 0) {
      replyError(-32000, "No chunks in index. Run Index All first.");
      return;
    }

    const memorySnippets = grok.readSynapseFilesAsContext(projectRoot);

    grok
      .suggestSnippetSpecs(apiKey, promptStr, descriptions)
      .then((out) => {
        const dbSnippets = retrieveSnippetsFromSpec(projectRoot, {
          chunkIds: out.chunkIds,
          snippetSpecs: out.snippetSpecs,
          keywordSearches: out.keywordSearches,
        });
        const isEmpty = !dbSnippets || dbSnippets.trim().length === 0;

        if (isEmpty) {
          return grok
            .suggestChunksForPrompt(apiKey, promptStr, descriptions, maxChunks, memoryFirstMode)
            .then((fallbackOut) => {
              const ids = fallbackOut.chunkIds.filter((id) => Number.isInteger(id) && id > 0);
              const chunks = db.getChunksById(ids);
              const fallbackDbSnippets = chunks
                .map((c) => `${c.file_path} (L${c.start_line}-${c.end_line})\n${c.content || ""}`)
                .join("\n\n");
              const skillPrompt = (fallbackOut.optimizedPrompt && fallbackOut.optimizedPrompt.trim()) ? fallbackOut.optimizedPrompt.trim() : promptStr;
              return grok.buildSkillFormatPrompt(apiKey, skillPrompt, fallbackDbSnippets, memorySnippets).then((skillOut) => {
                reply({
                  ok: true,
                  block: skillOut.content,
                  optimizedPrompt: fallbackOut.optimizedPrompt || null,
                  chunkCount: chunks.length,
                  totalDescriptions: descriptions.length,
                  estimatedSavedTokens: Math.max(0, descriptions.length - chunks.length) * grok.AVG_TOKENS_PER_CHUNK,
                  inputTokens: fallbackOut.inputTokens + skillOut.inputTokens,
                  outputTokens: fallbackOut.outputTokens + skillOut.outputTokens,
                  usedFallback: true,
                });
              });
            });
        }

        const skillPrompt = (out.optimizedPrompt && out.optimizedPrompt.trim()) ? out.optimizedPrompt.trim() : promptStr;
        return grok
          .buildSkillFormatPrompt(apiKey, skillPrompt, dbSnippets, memorySnippets)
          .then((skillOut) => {
            const snippetCount = dbSnippets.trim().length > 0 ? (dbSnippets.match(/\n\n/g) || []).length + 1 : 0;
            reply({
              ok: true,
              block: skillOut.content,
              optimizedPrompt: out.optimizedPrompt || null,
              chunkCount: snippetCount,
              totalDescriptions: descriptions.length,
              estimatedSavedTokens: Math.max(0, descriptions.length - snippetCount) * grok.AVG_TOKENS_PER_CHUNK,
              inputTokens: out.inputTokens + skillOut.inputTokens,
              outputTokens: out.outputTokens + skillOut.outputTokens,
              usedFallback: false,
            });
          })
          .catch((err) => {
            const optimizedPrompt = out.optimizedPrompt || promptStr;
            const lines = [optimizedPrompt, ""];
            const blocks = dbSnippets.split(/\n\n/);
            for (const block of blocks) {
              if (block.trim()) lines.push(block.trim(), "");
            }
            reply({
              ok: true,
              block: lines.join("\n").trim(),
              optimizedPrompt: out.optimizedPrompt || null,
              chunkCount: blocks.filter((b) => b.trim()).length,
              totalDescriptions: descriptions.length,
              estimatedSavedTokens: 0,
              inputTokens: out.inputTokens,
              outputTokens: out.outputTokens,
              usedFallback: false,
            });
          });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Grok failed");
      });
    return;
  }

  if (method === "buildSubagentContext") {
    const apiKey = params[0];
    const userPrompt = params[1];
    const maxChunks = (Number.isInteger(params[2]) && params[2] >= 1) ? params[2] : 10;
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }

    const memorySnippets = grok.readSynapseFilesAsContext(projectRoot);

    // Optional: load a smaller set of DB snippets (memory-heavy flow); capped at maxChunks
    const searchRes = search(userPrompt || "context", { limit: maxChunks, maxChars: 8000 });
    const snippets = searchRes.snippets || [];
    const dbSnippets = snippets
      .map((s) => `${s.path} (L${s.startLine}-${s.endLine})\n${s.content || ""}`)
      .join("\n\n");

    grok
      .buildSubagentContext(apiKey, String(userPrompt || "").trim() || "Prepare context for a parallel subagent.", dbSnippets, memorySnippets)
      .then((out) => {
        reply({
          ok: true,
          block: out.content,
          inputTokens: out.inputTokens,
          outputTokens: out.outputTokens,
        });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Grok failed");
      });
    return;
  }

  if (method === "chatTurn") {
    const apiKey = params[0];
    const messages = params[1];
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    if (!Array.isArray(messages)) {
      replyError(-32000, "messages must be an array");
      return;
    }
    grok
      .chatTurn(apiKey, projectRoot, messages)
      .then((out) => {
        reply({
          ok: true,
          content: out.content,
          inputTokens: out.inputTokens,
          outputTokens: out.outputTokens,
        });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Chat failed");
      });
    return;
  }

  if (method === "suggestSkill") {
    const apiKey = params[0];
    const snippets = params[1];
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    grok
      .suggestAndCreateSkill(apiKey, projectRoot, snippets || [])
      .then((out) => {
        const relPath = path.relative(projectRoot, out.path);
        const chunkResult = chunkFile(out.path);
        if (chunkResult.ok) {
          db.upsertDocument(out.path, chunkResult.digest, chunkResult.chunks);
        }
        reply({
          ok: true,
          path: out.path,
          filename: out.filename,
          inputTokens: out.inputTokens,
          outputTokens: out.outputTokens,
        });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Grok failed");
      });
    return;
  }

  if (method === "suggestLearnings") {
    const apiKey = params[0];
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    grok
      .suggestLearnings(apiKey, projectRoot)
      .then((out) => {
        const relPath = path.relative(projectRoot, out.path);
        const chunkResult = chunkFile(out.path);
        if (chunkResult.ok) {
          db.upsertDocument(out.path, chunkResult.digest, chunkResult.chunks);
        }
        reply({
          ok: true,
          path: out.path,
          relPath,
          appendedLines: out.appendedLines,
          inputTokens: out.inputTokens,
          outputTokens: out.outputTokens,
        });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Grok failed");
      });
    return;
  }

  if (method === "selfSynapse") {
    const apiKey = params[0];
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    const onProgress = (msg) => {
      send({ jsonrpc: "2.0", method: "selfSynapseProgress", params: [{ message: msg }] });
    };
    grok
      .selfSynapse(apiKey, projectRoot, onProgress)
      .then((out) => {
        for (const name of out.filesUpdated || []) {
          const filePath = path.join(projectRoot, ".synapse", name);
          if (fs.existsSync(filePath)) {
            const chunkResult = chunkFile(filePath);
            if (chunkResult.ok) {
              db.upsertDocument(filePath, chunkResult.digest, chunkResult.chunks);
            }
          }
        }
        reply({
          ok: true,
          filesUpdated: out.filesUpdated || [],
          chunksProcessed: out.chunksProcessed || 0,
          inputTokens: out.inputTokens || 0,
          outputTokens: out.outputTokens || 0,
        });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Self Synapse failed");
      });
    return;
  }

  if (method === "optimizePrompt") {
    const apiKey = params[0];
    const userPrompt = params[1];
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }
    const memorySnippets = grok.readSynapseFilesAsContext(projectRoot);
    grok
      .optimizePrompt(apiKey, String(userPrompt || "").trim() || "context", memorySnippets)
      .then((out) => {
        reply({
          ok: true,
          optimizedPrompt: out.optimizedPrompt,
          inputTokens: out.inputTokens,
          outputTokens: out.outputTokens,
        });
      })
      .catch((err) => {
        replyError(-32000, err.message || "Grok optimizePrompt failed");
      });
    return;
  }

  replyError(-32601, "Method not found: " + method);
}

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  handleRequest(trimmed);
});

rl.on("close", () => {
  stopWatching();
  process.exit(0);
});
