"use strict";

const chokidar = require("chokidar");
const path = require("path");

let watcher = null;
let sendNotification = null;

function startWatching(rootPath, send) {
  if (watcher) {
    watcher.close();
    watcher = null;
  }
  if (!rootPath) return;
  sendNotification = send;
  const synapsePath = path.join(rootPath, ".synapse");
  watcher = chokidar.watch(synapsePath, {
    ignored: /(^|[\/\\])\../,
    persistent: true,
    ignoreInitial: true,
  });
  watcher.on("change", (p) => {
    if (sendNotification) {
      sendNotification({ method: "fileChanged", params: { path: p } });
    }
  });
  watcher.on("add", (p) => {
    if (sendNotification) {
      sendNotification({ method: "fileChanged", params: { path: p, type: "add" } });
    }
  });
}

function stopWatching() {
  if (watcher) {
    watcher.close();
    watcher = null;
  }
  sendNotification = null;
}

module.exports = { startWatching, stopWatching };
