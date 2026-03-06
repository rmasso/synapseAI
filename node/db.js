"use strict";

const Database = require("better-sqlite3");
const path = require("path");
const fs = require("fs");

let db = null;
let projectRoot = null;

function getDbPath() {
  if (!projectRoot) return null;
  const synapseDir = path.join(projectRoot, ".synapse");
  if (!fs.existsSync(synapseDir)) return null;
  return path.join(synapseDir, "synapse.db");
}

function open(root) {
  if (db) {
    db.close();
    db = null;
  }
  projectRoot = root || null;
  if (!projectRoot) return null;
  const dbPath = getDbPath();
  if (!dbPath) return null;
  db = new Database(dbPath);
  initSchema(db);
  return db;
}

function initSchema(database) {
  database.exec(`
    CREATE TABLE IF NOT EXISTS documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL UNIQUE,
      digest TEXT,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      document_id INTEGER NOT NULL,
      content TEXT NOT NULL,
      start_line INTEGER NOT NULL,
      end_line INTEGER NOT NULL,
      file_path TEXT NOT NULL,
      FOREIGN KEY (document_id) REFERENCES documents(id)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
      content,
      file_path,
      content=chunks,
      content_rowid=id,
      tokenize='porter unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
      INSERT INTO chunks_fts(rowid, content, file_path) VALUES (new.id, new.content, new.file_path);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, content, file_path) VALUES('delete', old.id, old.content, old.file_path);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, content, file_path) VALUES('delete', old.id, old.content, old.file_path);
      INSERT INTO chunks_fts(rowid, content, file_path) VALUES (new.id, new.content, new.file_path);
    END;
  `);
}

function getDb() {
  return db;
}

function close() {
  if (db) {
    db.close();
    db = null;
  }
  projectRoot = null;
}

function upsertDocument(filePath, digest, chunks) {
  if (!db) return { ok: false, error: "No database" };
  const relativePath = projectRoot ? path.relative(projectRoot, filePath) : filePath;
  const now = Math.floor(Date.now() / 1000);
  const ins = db.prepare(
    "INSERT INTO documents (path, digest, updated_at) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET digest = excluded.digest, updated_at = excluded.updated_at"
  );
  ins.run(relativePath, digest, now);
  const row = db.prepare("SELECT id FROM documents WHERE path = ?").get(relativePath);
  const docId = row.id;
  db.prepare("DELETE FROM chunks WHERE document_id = ?").run(docId);
  const insertChunk = db.prepare(
    "INSERT INTO chunks (document_id, content, start_line, end_line, file_path) VALUES (?, ?, ?, ?, ?)"
  );
  for (const c of chunks) {
    insertChunk.run(docId, c.content, c.startLine, c.endLine, relativePath);
  }
  return { ok: true, documentId: docId, chunksCount: chunks.length };
}

function getStats() {
  if (!db) {
    const dbPath = getDbPath();
    return {
      documentCount: 0,
      chunkCount: 0,
      dbSizeBytes: dbPath && fs.existsSync(dbPath) ? fs.statSync(dbPath).size : 0,
    };
  }
  const docRow = db.prepare("SELECT COUNT(*) as c FROM documents").get();
  const chunkRow = db.prepare("SELECT COUNT(*) as c FROM chunks").get();
  const dbPath = getDbPath();
  const dbSizeBytes = dbPath && fs.existsSync(dbPath) ? fs.statSync(dbPath).size : 0;
  return {
    documentCount: docRow ? docRow.c : 0,
    chunkCount: chunkRow ? chunkRow.c : 0,
    dbSizeBytes,
  };
}

const PREVIEW_LENGTH = 180;

/** Returns chunk metadata for Grok: id, path, line range, short preview. */
function getChunkDescriptions() {
  if (!db) return [];
  const rows = db.prepare(
    "SELECT id, file_path, start_line, end_line, content FROM chunks ORDER BY id"
  ).all();
  return rows.map((r) => ({
    id: r.id,
    path: r.file_path,
    startLine: r.start_line,
    endLine: r.end_line,
    preview: (r.content || "").substring(0, PREVIEW_LENGTH).replace(/\n/g, " ").trim(),
  }));
}

/** Returns full chunks for given ids (order preserved). */
function getChunksById(ids) {
  if (!db || !ids || ids.length === 0) return [];
  const placeholders = ids.map(() => "?").join(",");
  const rows = db.prepare(
    `SELECT id, file_path, start_line, end_line, content FROM chunks WHERE id IN (${placeholders})`
  ).all(...ids);
  const byId = new Map(rows.map((r) => [r.id, r]));
  return ids.filter((id) => byId.has(id)).map((id) => byId.get(id));
}

module.exports = { open, getDb, getDbPath, close, upsertDocument, initSchema, getStats, getChunkDescriptions, getChunksById };
