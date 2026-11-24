"use strict";

const LOG_PREFIX = "Activation failed:";
const MAX_LOGGED = 4096;

/** The part of an output-channel error worth keeping, or undefined when it is not an activation failure. */
function activationLogText(args) {
  const first = String(args[0]);
  return first.startsWith(LOG_PREFIX) ? first.slice(0, MAX_LOGGED) : undefined;
}

/**
 * The error frame's `message` and `stack`. The extension logs the real activation error to its
 * output channel and throws a `CodeExpectedError` with a fixed sentence in its place; the logged
 * text stands in for that sentence.
 */
function describeActivationError(err, logged) {
  if (err?.name !== "CodeExpectedError" || !logged) {
    return { message: `Extension activation failed: ${err.message}`, stack: err.stack };
  }
  const type = logged
    .slice(LOG_PREFIX.length)
    .split("\n", 1)[0]
    .replace(/\s*\(<string\(\d+\)>\)/, "") // the extension's redaction of the error text
    .trim()
    .slice(0, 160);
  const position = logged.match(/[^/\\(\s]{1,60}\.js:\d{1,9}:\d{1,9}/)?.[0];
  return {
    message: `Extension activation failed: ${type}${position ? ` (${position})` : ""}`,
    stack: logged,
  };
}

module.exports = { activationLogText, describeActivationError };
