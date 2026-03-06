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
    // Ensure .synapse and all memory templates exist before indexing (missing files are created, not overwritten).
    initSynapseFolder(projectRoot);
    const synapseDir = path.join(projectRoot, ".synapse");
    if (!fs.existsSync(synapseDir)) {
      reply({ ok: true, indexed: 0 });
      return;
    }
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
    const mdFiles = walk(synapseDir);
    let indexed = 0;
    for (const f of mdFiles) {
      const result = chunkFile(f);
      if (result.ok) {
        db.upsertDocument(f, result.digest, result.chunks);
        indexed++;
      }
    }

    // Read .synapse/config.json and index any additional folders.
    const configPath = path.join(synapseDir, "config.json");
    let indexFolders = [];
    if (fs.existsSync(configPath)) {
      try {
        const raw = fs.readFileSync(configPath, "utf8");
        const cfg = JSON.parse(raw);
        if (Array.isArray(cfg.indexFolders)) {
          indexFolders = cfg.indexFolders.filter(f => typeof f === "string" && f.trim().length > 0);
        }
      } catch (_) {}
    }
    for (const rel of indexFolders) {
      const resolved = path.resolve(projectRoot, rel);
      // Safety: only allow paths inside projectRoot.
      const relative = path.relative(projectRoot, resolved);
      if (relative.startsWith("..") || path.isAbsolute(relative)) continue;
      if (!fs.existsSync(resolved)) continue;
      let stat;
      try { stat = fs.statSync(resolved); } catch (_) { continue; }
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

    reply({ ok: true, indexed });
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

  if (method === "buildContextForPrompt") {
    const apiKey = params[0];
    const userPrompt = params[1];
    const maxChunks = (Number.isInteger(params[2]) && params[2] >= 1) ? params[2] : undefined;
    if (!apiKey || typeof apiKey !== "string") {
      replyError(-32000, "Missing or invalid apiKey");
      return;
    }
    if (!projectRoot) {
      replyError(-32000, "No project set");
      return;
    }

    const promptStr = String(userPrompt || "").trim() || "context";

    // Get all chunks from .synapse folder
    const memoryChunks = db.getChunkDescriptions().filter(c => c.path && c.path.includes(".synapse/"));
    // Get search results for the user prompt
    const searchRes = search(userPrompt || "context", { limit: 30, maxChars: 50000 });
    const searchDescriptions = (searchRes.snippets || []).map(s => ({
      id: s.id,
      path: s.path,
      startLine: s.startLine,
      endLine: s.endLine,
      preview: (s.content || "").substring(0, 180).replace(/\n/g, " ").trim(),
    }));
    const combined = [...memoryChunks, ...searchDescriptions];
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
      .suggestChunksForPrompt(apiKey, promptStr, descriptions, maxChunks)
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
