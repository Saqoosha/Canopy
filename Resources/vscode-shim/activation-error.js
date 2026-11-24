"use strict";

const LOG_PREFIX = "Activation failed:";
const MAX_LOGGED = 4096;

/** First `max` characters. Half an emoji at the cut would make Swift reject the whole frame. */
function cut(text, max) {
  return text.slice(0, max).replace(/[\uD800-\uDBFF]$/, "");
}

/** The part of an output-channel error worth keeping, or undefined when it is not an activation failure. */
function activationLogText(text) {
  return text.startsWith(LOG_PREFIX) ? cut(text, MAX_LOGGED) : undefined;
}

/**
 * The error frame's `message` and `stack`. The extension logs the real activation error to its
 * output channel and throws a `CodeExpectedError` with a fixed sentence in its place; the logged
 * text stands in for that sentence.
 */
function describeActivationError(err, logged) {
  const asThrown = { message: `Extension activation failed: ${err.message}`, stack: err.stack };
  if (err.name !== "CodeExpectedError" || !logged) return asThrown;
  const outermost = logged.slice(LOG_PREFIX.length).split("\nCaused by: ", 1)[0];
  const type = cut(
    outermost
      .split("\n", 1)[0]
      .replace(/\s*\(<string\(\d+\)>\)/, "") // the extension's redaction of the error text
      .trim(),
    160,
  );
  if (!type) return asThrown;
  const position = outermost.match(/[^/\\(\s]{1,60}\.js:\d{1,9}:\d{1,9}/)?.[0];
  return {
    message: `Extension activation failed: ${type}${position ? ` (${position})` : ""}`,
    stack: logged,
  };
}

module.exports = { activationLogText, describeActivationError };
