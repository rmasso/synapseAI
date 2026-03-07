"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const MAX_CHUNK_CHARS = 1200;
const OVERLAP_LINES = 2;

/** Extensions treated as code: use generic code chunker. */
const CODE_EXTENSIONS = new Set([".swift", ".js", ".ts", ".m", ".c", ".h", ".cpp", ".py", ".rb", ".go", ".rs", ".java", ".kt"]);

/** Extensions stored as a single chunk (e.g. small config). */
const SINGLE_CHUNK_EXTENSIONS = new Set([".json"]);

/**
 * Chunk markdown by ## headings and by size. Preserve line ranges for @file refs.
 * Returns [{ content, startLine, endLine }].
 */
function chunkMarkdown(content, filePath) {
  const lines = content.split("\n");
  const chunks = [];
  let start = 0;
  while (start < lines.length) {
    let end = start;
    let block = [];
    const blockStart = start + 1;
    while (end < lines.length) {
      const line = lines[end];
      const isHeading = /^#{1,6}\s/.test(line);
      if (block.length > 0 && isHeading && block.join("\n").length >= MAX_CHUNK_CHARS * 0.5) {
        break;
      }
      block.push(line);
      end++;
      if (block.join("\n").length >= MAX_CHUNK_CHARS) break;
    }
    const text = block.join("\n").trim();
    if (text) {
      chunks.push({
        content: text,
        startLine: blockStart,
        endLine: start + block.length,
      });
    }
    start = end;
    if (block.length === 0) start++;
  }
  return chunks;
}

/**
 * Chunk code by line boundaries and size cap. Language-agnostic: same for .swift, .js, .ts, etc.
 * Does not break mid-line. Returns [{ content, startLine, endLine }].
 */
function chunkCode(content, filePath) {
  const lines = content.split("\n");
  const chunks = [];
  let start = 0;
  while (start < lines.length) {
    let end = start;
    let block = [];
    const blockStart = start + 1;
    while (end < lines.length) {
      block.push(lines[end]);
      end++;
      const text = block.join("\n");
      if (text.length >= MAX_CHUNK_CHARS) break;
    }
    const text = block.join("\n").trim();
    if (text) {
      chunks.push({
        content: text,
        startLine: blockStart,
        endLine: start + block.length,
      });
    }
    start = end;
    if (block.length === 0) start++;
  }
  return chunks;
}

/**
 * Single chunk for the whole file (e.g. .json). Line range 1 to last line.
 */
function chunkSingle(content, filePath) {
  const lines = content.split("\n");
  const trimmed = content.trim();
  if (!trimmed) return [];
  return [
    {
      content: trimmed,
      startLine: 1,
      endLine: lines.length,
    },
  ];
}

function digest(content) {
  return crypto.createHash("sha256").update(content, "utf8").digest("hex");
}

function getExtension(filePath) {
  const ext = path.extname(filePath);
  return ext ? ext.toLowerCase() : "";
}

function chunkFile(filePath) {
  const fullPath = path.isAbsolute(filePath) ? filePath : filePath;
  if (!fs.existsSync(fullPath)) return { ok: false, error: "File not found" };
  const content = fs.readFileSync(fullPath, "utf8");
  const ext = getExtension(fullPath);
  let chunks;
  if (ext === ".md") {
    chunks = chunkMarkdown(content, fullPath);
  } else if (SINGLE_CHUNK_EXTENSIONS.has(ext)) {
    chunks = chunkSingle(content, fullPath);
  } else if (CODE_EXTENSIONS.has(ext)) {
    chunks = chunkCode(content, fullPath);
  } else {
    // Unknown extension: treat as code for consistency
    chunks = chunkCode(content, fullPath);
  }
  return { ok: true, digest: digest(content), chunks };
}

module.exports = { chunkMarkdown, chunkCode, chunkFile, digest };
