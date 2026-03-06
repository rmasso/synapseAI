const { spawn } = require("child_process");
const path = require("path");
const { test } = require("node:test");
const assert = require("node:assert");

test("Node bridge responds to ping", async () => {
  const script = path.join(__dirname, "..", "index.js");
  const child = spawn("node", [script], {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: path.join(__dirname, ".."),
  });

  const send = (obj) => {
    child.stdin.write(JSON.stringify(obj) + "\n");
  };

  const receive = () => {
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
  };

  send({ jsonrpc: "2.0", id: 1, method: "ping" });
  const response = await receive();
  assert.strictEqual(response.result?.pong, true);
  assert.strictEqual(response.id, 1);

  child.kill();
});
