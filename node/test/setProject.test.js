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
  return new Promise((resolve, reject) => {
    let buffer = "";
    const onData = (data) => {
      buffer += data.toString();
      const line = buffer.split("\n")[0];
      if (line) {
        child.stdout.off("data", onData);
        try {
          resolve(JSON.parse(line));
        } catch (e) {
          reject(e);
        }
      }
    };
    child.stdout.on("data", onData);
  });
}

test("setProject creates .synapse and template files", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-test-"));
  const script = path.join(__dirname, "..", "index.js");
  const child = spawn("node", [script], {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: path.join(__dirname, ".."),
  });

  send(child, { jsonrpc: "2.0", id: 1, method: "setProject", params: tmpDir });
  const response = await receive(child);
  assert.strictEqual(response.result?.ok, true);
  assert.strictEqual(response.result?.path, tmpDir);

  const synapseDir = path.join(tmpDir, ".synapse");
  assert.ok(fs.existsSync(synapseDir));
  const files = ["projectbrief.md", "activeContext.md", "progress.md", "thoughts.md", "learnings.md", "codebase.md", "ui-ux-memory.md"];
  for (const f of files) {
    assert.ok(fs.existsSync(path.join(synapseDir, f)), f + " should exist");
  }
  assert.ok(fs.existsSync(path.join(synapseDir, "skills")));

  child.kill();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});
