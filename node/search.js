"use strict";

const { getDb } = require("./db.js");

const DEFAULT_LIMIT = 10;

/** FTS5 MATCH rejects ? * - ( ) and other syntax. Keep only token-safe chars and spaces. */
function toFts5SafeQuery(q) {
  const tokens = q
    .split(/\s+/)
    .map((s) => s.replace(/[^\w\u0080-\uFFFF]/g, "").toLowerCase())
    .filter(Boolean);
  return tokens.join(" ").trim();
}

const MAX_TOTAL_CHARS = 8000;

/**
 * Search FTS5 and return snippets with path and line range.
 * Uses bm25 for ranking. Caps total size.
 */
function search(query, options = {}) {
  const database = getDb();
  if (!database) return { ok: false, error: "No database", snippets: [] };
  const limit = options.limit ?? DEFAULT_LIMIT;
  const maxChars = options.maxChars ?? MAX_TOTAL_CHARS;
  const trimmed = query.trim();
  if (!trimmed) return { ok: true, snippets: [] };
  const safeQuery = toFts5SafeQuery(trimmed);
  if (!safeQuery) return { ok: true, snippets: [] };
  let stmt;
  try {
    stmt = database.prepare(`
      SELECT c.id, c.content, c.start_line, c.end_line, c.file_path,
             bm25(chunks_fts) AS rank
      FROM chunks_fts
      JOIN chunks c ON c.id = chunks_fts.rowid
      WHERE chunks_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `);
  } catch (e) {
    return { ok: false, error: e.message, snippets: [] };
  }
  let rows;
  try {
    rows = stmt.all(safeQuery, limit * 2);
  } catch (e) {
    return { ok: false, error: e.message, snippets: [] };
  }
  // If FTS query matched nothing but we have chunks, return first chunks by id so user gets something.
  if (rows.length === 0) {
    const fallbackStmt = database.prepare(`
      SELECT c.id, c.content, c.start_line, c.end_line, c.file_path
      FROM chunks c
      ORDER BY c.id
      LIMIT ?
    `);
    rows = fallbackStmt.all(limit * 2);
  }
  const snippets = [];
  let totalChars = 0;
  for (const row of rows) {
    if (totalChars >= maxChars) break;
    const len = (row.content || "").length;
    if (totalChars + len > maxChars && snippets.length > 0) break;
    snippets.push({
      id: row.id,
      path: row.file_path,
      startLine: row.start_line,
      endLine: row.end_line,
      content: row.content,
      rank: row.rank || 0,
    });
    totalChars += len;
  }
  return { ok: true, snippets };
}

module.exports = { search };
