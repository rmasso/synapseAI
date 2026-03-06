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

test("indexAll and search return snippets", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-search-"));
  const synapseDir = path.join(tmpDir, ".synapse");
  fs.mkdirSync(synapseDir, { recursive: true });
  fs.writeFileSync(
    path.join(synapseDir, "progress.md"),
    "# Progress\n\nPhase 0 done. JWT refresh decided.\n",
    "utf8"
  );
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
  assert.ok(indexRes.result?.indexed >= 1);

  send(child, { jsonrpc: "2.0", id: 3, method: "search", params: ["JWT refresh"] });
  const searchRes = await receive(child);
  assert.strictEqual(searchRes.result?.ok, true);
  assert.ok(Array.isArray(searchRes.result?.snippets));
  assert.ok(searchRes.result.snippets.length >= 1);
  assert.ok(searchRes.result.snippets[0].content.includes("JWT"));

  child.kill();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});
