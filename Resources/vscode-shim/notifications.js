"use strict";

const { writeStdout } = require("./protocol.js");
const crypto = require("node:crypto");

// ---------------------------------------------------------------------------
// Notification handler — show messages with buttons, resolve on response
// ---------------------------------------------------------------------------

function createNotificationHandler() {
  const pending = new Map(); // requestId → { resolve, timer }

  function show(severity, message, ...rest) {
    const buttons = rest.filter((r) => typeof r === "string");
    const requestId = crypto.randomUUID();

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        pending.delete(requestId);
        resolve(undefined); // 60s timeout = cancel
      }, 60_000);
      // Don't let a pending notification hold the event loop open. This
      // cannot affect the shim itself: while stdin is open its reader
      // refs the loop, and on EOF index.js calls process.exit(0) outright.
      // It matters only to in-process consumers of these modules — the
      // motivation was `node --test`, where one notification nobody
      // answers kept the whole suite alive for the full 60s after the
      // last assertion.
      timer.unref();

      pending.set(requestId, { resolve, timer });

      writeStdout({
        type: "show_notification",
        severity,
        message: String(message),
        buttons,
        requestId,
      });
    });
  }

  function handleResponse(requestId, buttonValue) {
    const entry = pending.get(requestId);
    if (!entry) return;
    pending.delete(requestId);
    clearTimeout(entry.timer);
    entry.resolve(buttonValue ?? undefined);
  }

  function rejectAll() {
    for (const [id, entry] of pending) {
      clearTimeout(entry.timer);
      entry.resolve(undefined);
    }
    pending.clear();
  }

  return { show, handleResponse, rejectAll };
}

module.exports = { createNotificationHandler };
