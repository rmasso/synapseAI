const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { test } = require("node:test");
const assert = require("node:assert");

function send(child, obj) {
  child.stdin.write(JSON.stringify(obj) + "\n");
}

function receive(child) {
  return new Promise((resolve) => {
    let buffer = "";
    const onData = (data) => {
      buffer += data.toString();
      const line = buffer.split("\n")[0];
      if (line) {
        child.stdout.off("data", onData);
        resolve(JSON.parse(line));
      }
    };
    child.stdout.on("data", onData);
  });
}

test("getAllConnections returns nodes and connections after indexAll", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-test-"));
  const script = path.join(__dirname, "..", "index.js");
  const child = spawn("node", [script], {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: path.join(__dirname, ".."),
  });

  send(child, { jsonrpc: "2.0", id: 1, method: "setProject", params: tmpDir });
  await receive(child);

  send(child, { jsonrpc: "2.0", id: 2, method: "indexAll" });
  const indexRes = await receive(child);
  assert.strictEqual(indexRes.result?.ok, true);

  send(child, { jsonrpc: "2.0", id: 3, method: "getAllConnections" });
  const connRes = await receive(child);
  assert.ok(connRes.result);
  assert.ok(Array.isArray(connRes.result.nodes));
  assert.ok(Array.isArray(connRes.result.connections));
  assert.ok(connRes.result.nodes.length >= 6); // projectbrief, activeContext, progress, thoughts, learnings, codebase
  const fileNodes = connRes.result.nodes.filter((n) => n.type === "file");
  const chunkNodes = connRes.result.nodes.filter((n) => n.type === "chunk");
  assert.ok(fileNodes.length >= 6, "expected at least 6 file nodes");
  assert.ok(chunkNodes.length >= 1, "expected at least 1 chunk node");
  for (const n of connRes.result.nodes) {
    assert.ok(n.id);
    assert.ok(n.path);
    assert.ok(n.type === "file" || n.type === "chunk");
  }
  for (const c of connRes.result.connections) {
    assert.ok(c.fromId);
    assert.ok(c.toId);
    assert.ok(typeof c.type === "string");
    assert.ok(typeof c.label === "string");
  }

  child.kill();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});
