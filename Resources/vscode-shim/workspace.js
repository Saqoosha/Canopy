"use strict";

const fs = require("node:fs");
const fsPromises = require("node:fs/promises");
const path = require("node:path");
const { Uri, Disposable, EventEmitter, RelativePattern } = require("./types.js");

// ---------------------------------------------------------------------------
// Glob matching (simple implementation)
// ---------------------------------------------------------------------------

/**
 * Convert a simple glob pattern to a RegExp.
 * Supports: ** (any path), * (any filename chars), ? (single char)
 */
function globToRegExp(pattern) {
  let re = "";
  let i = 0;
  while (i < pattern.length) {
    const ch = pattern[i];
    if (ch === "*" && pattern[i + 1] === "*") {
      // ** matches any path segments
      re += ".*";
      i += 2;
      // Skip trailing /
      if (pattern[i] === "/") i++;
    } else if (ch === "*") {
      // * matches anything except /
      re += "[^/]*";
      i++;
    } else if (ch === "?") {
      // ? matches single char except /
      re += "[^/]";
      i++;
    } else if (ch === "[") {
      // Character class — convert to regex (! becomes ^ for negation)
      // Find closing ] first; if missing, treat [ as literal
      let j = i + 1;
      if (j < pattern.length && pattern[j] === "!") j++;
      while (j < pattern.length && pattern[j] !== "]") j++;
      if (j >= pattern.length) {
        // No closing ] — treat [ as literal
        re += "\\[";
        i++;
      } else {
        i++; // skip [
        if (i < pattern.length && pattern[i] === "!") {
          re += "[^";
          i++;
        } else {
          re += "[";
        }
        while (i < pattern.length && pattern[i] !== "]") {
          re += pattern[i];
          i++;
        }
        re += "]";
        i++; // skip ]
      }
    } else if (ch === "{") {
      // Brace expansion {a,b} → (a|b)
      i++; // skip {
      let alternatives = "";
      while (i < pattern.length && pattern[i] !== "}") {
        if (pattern[i] === ",") {
          alternatives += "|";
        } else {
          alternatives += pattern[i].replace(/[.+^$()[\]\\]/g, "\\$&");
        }
        i++;
      }
      if (i < pattern.length) i++; // skip }
      re += "(" + alternatives + ")";
    } else {
      // Escape any RegExp metacharacter
      re += ch.replace(/[.+^${}()|[\]\\]/g, "\\$&");
      i++;
    }
  }
  return new RegExp("^" + re + "$");
}

// ---------------------------------------------------------------------------
// findFiles — recursive directory walk with glob matching
// ---------------------------------------------------------------------------

/**
 * Parse a .gitignore file and return an array of {pattern, negated} rules.
 * Handles common patterns including **, *, ?, character classes, and negation.
 * Does not handle nested .gitignore files or complex anchoring edge cases.
 */
function parseGitignore(filePath) {
  let content;
  try {
    content = fs.readFileSync(filePath, "utf-8");
  } catch {
    return [];
  }
  const rules = [];
  for (let line of content.split("\n")) {
    line = line.trim();
    if (!line || line.startsWith("#")) continue;
    let negated = false;
    if (line.startsWith("!")) {
      negated = true;
      line = line.slice(1);
    }
    // Remove trailing spaces (unless escaped)
    line = line.replace(/(?<!\\)\s+$/, "");
    if (!line) continue;
    rules.push({ pattern: line, negated });
  }
  return rules;
}

/**
 * Test whether a relative path is ignored by a list of gitignore rules.
 * @param {string} relPath - relative path (forward slashes)
 * @param {boolean} isDir - true if the entry is a directory
 * @param {Array<{pattern:string, negated:boolean}>} rules
 */
function isGitignored(relPath, isDir, rules) {
  let ignored = false;
  for (const { pattern, negated } of rules) {
    let p = pattern;
    let dirOnly = false;
    if (p.endsWith("/")) {
      dirOnly = true;
      p = p.slice(0, -1);
    }
    if (dirOnly && !isDir) continue;

    // If pattern contains /, prefer full relative path; otherwise prefer basename.
    // Both basename and full path are tested as fallback.
    const matchAgainst = p.includes("/") ? relPath : path.basename(relPath);
    const target = p.startsWith("/") ? p.slice(1) : p;

    try {
      if (!target.includes("/") && !target.includes("*")) {
        // Simple name pattern (e.g. "dist", "build") — match against basename exactly
        if (path.basename(relPath) === target) {
          ignored = !negated;
        }
      } else {
        const re = globToRegExp(target);
        if (re.test(matchAgainst) || re.test(relPath)) {
          ignored = !negated;
        }
      }
    } catch {
      // Skip malformed patterns
    }
  }
  return ignored;
}

/**
 * Load gitignore rules from the workspace root.
 * Only reads the top-level .gitignore (subdirectory .gitignore files are not loaded).
 */
function loadGitignoreRules(baseDir) {
  const rules = [];
  // Root .gitignore
  rules.push(...parseGitignore(path.join(baseDir, ".gitignore")));
  return rules;
}

async function findFilesImpl(baseDir, pattern, exclude, maxResults, maxDepth) {
  const regex = globToRegExp(pattern);
  const excludeRegex = exclude ? globToRegExp(exclude) : null;
  const results = [];

  // Load gitignore rules from workspace root
  const gitignoreRules = loadGitignoreRules(baseDir);

  async function walk(dir, depth) {
    if (depth > maxDepth) return;
    if (results.length >= maxResults) return;

    let entries;
    try {
      entries = await fsPromises.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (results.length >= maxResults) return;

      // Skip dot dirs and node_modules
      if (entry.isDirectory() && (entry.name.startsWith(".") || entry.name === "node_modules")) {
        continue;
      }

      const fullPath = path.join(dir, entry.name);
      const relativePath = path.relative(baseDir, fullPath);

      // Check gitignore
      if (gitignoreRules.length > 0 && isGitignored(relativePath, entry.isDirectory(), gitignoreRules)) {
        continue;
      }

      if (entry.isDirectory()) {
        await walk(fullPath, depth + 1);
      } else {
        if (excludeRegex && excludeRegex.test(relativePath)) continue;
        if (regex.test(relativePath)) {
          results.push(Uri.file(fullPath));
        }
      }
    }
  }

  await walk(baseDir, 0);
  return results;
}

// ---------------------------------------------------------------------------
// getConfiguration
// ---------------------------------------------------------------------------

function loadJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf-8"));
  } catch {
    return {};
  }
}

function saveJson(filePath, data) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2), "utf-8");
}

// VSCode built-in defaults that aren't in any extension's package.json.
// The CC extension reads these to build ripgrep exclude globs for @-mention file listing.
const VSCODE_BUILTIN_DEFAULTS = {
  "files.exclude": {
    "**/.git": true,
    "**/.svn": true,
    "**/.hg": true,
    "**/CVS": true,
    "**/.DS_Store": true,
    "**/Thumbs.db": true,
  },
  "search.exclude": {
    "**/node_modules": true,
    "**/bower_components": true,
    "**/*.code-search": true,
  },
  "search.useIgnoreFiles": true,
};

function createConfiguration(settingsPath, extensionPackageJson, canopySettingsPath) {
  // Extract extension defaults from package.json contributes.configuration.properties
  const extDefaults = {};
  const configs = extensionPackageJson?.contributes?.configuration;
  if (configs) {
    // configuration can be an object or array of objects
    const configArray = Array.isArray(configs) ? configs : [configs];
    for (const config of configArray) {
      const props = config.properties;
      if (props) {
        for (const [fullKey, def] of Object.entries(props)) {
          if (def && "default" in def) {
            extDefaults[fullKey] = def.default;
          }
        }
      }
    }
  }

  // Per-shim overrides from env vars — highest priority. Used for per-session
  // settings that must NOT be written to the shared Canopy settings file
  // (e.g. SSH wrapper, which would otherwise leak across concurrent windows
  // and survive across /resume re-spawns when cleared eagerly).
  const envOverrides = {};
  if (process.env.CANOPY_SSH_WRAPPER_PATH) {
    envOverrides["claudeCode.claudeProcessWrapper"] = process.env.CANOPY_SSH_WRAPPER_PATH;
    process.stderr.write(
      `[vscode-shim] env override: claudeCode.claudeProcessWrapper=${process.env.CANOPY_SSH_WRAPPER_PATH}\n`,
    );
  }

  return function getConfiguration(section) {
    const userSettings = loadJson(settingsPath);
    const canopySettings = canopySettingsPath ? loadJson(canopySettingsPath) : {};

    return {
      get(key, defaultValue) {
        const fullKey = section ? `${section}.${key}` : key;

        // 0. Per-shim env overrides (highest priority)
        if (Object.prototype.hasOwnProperty.call(envOverrides, fullKey)) {
          return envOverrides[fullKey];
        }
        // 1. Canopy global settings
        if (Object.prototype.hasOwnProperty.call(canopySettings, fullKey)) {
          return canopySettings[fullKey];
        }
        // 2. User settings (.vscode/settings.json)
        if (Object.prototype.hasOwnProperty.call(userSettings, fullKey)) {
          return userSettings[fullKey];
        }
        // 3. Extension package.json defaults
        if (Object.prototype.hasOwnProperty.call(extDefaults, fullKey)) {
          return extDefaults[fullKey];
        }
        // 4. VSCode built-in defaults (files.exclude, search.exclude, etc.)
        if (Object.prototype.hasOwnProperty.call(VSCODE_BUILTIN_DEFAULTS, fullKey)) {
          return VSCODE_BUILTIN_DEFAULTS[fullKey];
        }
        // 5. Provided default
        return defaultValue;
      },

      has(key) {
        const fullKey = section ? `${section}.${key}` : key;
        return (
          Object.prototype.hasOwnProperty.call(envOverrides, fullKey) ||
          Object.prototype.hasOwnProperty.call(canopySettings, fullKey) ||
          Object.prototype.hasOwnProperty.call(userSettings, fullKey) ||
          Object.prototype.hasOwnProperty.call(extDefaults, fullKey) ||
          Object.prototype.hasOwnProperty.call(VSCODE_BUILTIN_DEFAULTS, fullKey)
        );
      },

      update(key, value, _target) {
        const fullKey = section ? `${section}.${key}` : key;
        const current = loadJson(settingsPath);
        if (value === undefined) {
          delete current[fullKey];
        } else {
          current[fullKey] = value;
        }
        saveJson(settingsPath, current);
      },

      inspect(key) {
        const fullKey = section ? `${section}.${key}` : key;
        const currentSettings = loadJson(settingsPath);
        const defVal = Object.prototype.hasOwnProperty.call(extDefaults, fullKey)
          ? extDefaults[fullKey]
          : Object.prototype.hasOwnProperty.call(VSCODE_BUILTIN_DEFAULTS, fullKey)
            ? VSCODE_BUILTIN_DEFAULTS[fullKey]
            : undefined;
        const envVal = Object.prototype.hasOwnProperty.call(envOverrides, fullKey)
          ? envOverrides[fullKey]
          : undefined;
        const canopyVal = Object.prototype.hasOwnProperty.call(canopySettings, fullKey)
          ? canopySettings[fullKey]
          : undefined;
        const workspaceVal = Object.prototype.hasOwnProperty.call(currentSettings, fullKey)
          ? currentSettings[fullKey]
          : undefined;
        // Env overrides and Canopy settings both present as globalValue (CC
        // extension expects user-managed config there). Env > Canopy > workspace.
        const globalValue =
          envVal !== undefined ? envVal : canopyVal !== undefined ? canopyVal : workspaceVal;
        const hasGlobalShadow = envVal !== undefined || canopyVal !== undefined;
        return {
          key: fullKey,
          defaultValue: defVal,
          globalValue: globalValue ?? undefined,
          workspaceValue: hasGlobalShadow ? workspaceVal ?? undefined : undefined,
          workspaceFolderValue: undefined,
        };
      },
    };
  };
}

// ---------------------------------------------------------------------------
// openTextDocument / file-backed documents
// ---------------------------------------------------------------------------

// `MirrorUIFrame.maxInlineContentBytes` (2 MiB). JSON escaping can grow a
// stdout line up to 6×, and both NDJSON buffers cut the connection at 16 MiB,
// so a file opened through `showTextDocument` has to be cut before it is
// stringified. The note sits after the cap; it is short and ASCII.
const SHOW_DOCUMENT_MAX_BYTES = 2 << 20;
const SHOW_DOCUMENT_TRUNCATION_NOTE =
  "\n\n… truncated (file is larger than the viewer will send)";

function languageIdForPath(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
    case ".json":
      return "json";
    case ".md":
    case ".markdown":
      return "markdown";
    case ".js":
    case ".mjs":
    case ".cjs":
      return "javascript";
    case ".jsx":
      return "javascriptreact";
    case ".ts":
    case ".mts":
    case ".cts":
      return "typescript";
    case ".tsx":
      return "typescriptreact";
    case ".py":
      return "python";
    case ".swift":
      return "swift";
    case ".html":
      return "html";
    case ".css":
      return "css";
    case ".sh":
      return "shellscript";
    case ".yml":
    case ".yaml":
      return "yaml";
    case ".toml":
      return "toml";
    default:
      return "plaintext";
  }
}

// Longest prefix of `text` whose UTF-8 length is at most `maxBytes`.
// `Buffer.byteLength` counts a lone surrogate as U+FFFD (3 bytes), so a
// prefix that fits only by ending on the leading half of an emoji is one
// byte-length check away from being "short enough". Drop that half:
// `JSON.stringify` would emit `\ud83d`, and a later reader can reject it.
function headUtf8(text, maxBytes) {
  if (Buffer.byteLength(text) <= maxBytes) return text;
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (Buffer.byteLength(text.slice(0, mid)) <= maxBytes) lo = mid;
    else hi = mid - 1;
  }
  if (lo > 0) {
    const unit = text.charCodeAt(lo - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) lo -= 1;
  }
  return text.slice(0, lo);
}

function positionAt(content, offset) {
  const clamped = Math.max(0, Math.min(offset | 0, content.length));
  const head = content.slice(0, clamped);
  const lineBreak = head.lastIndexOf("\n");
  return { line: head.split("\n").length - 1, character: clamped - (lineBreak + 1) };
}

/**
 * A TextDocument for a file on disk.
 *
 * Claude Code's `openFile` (extension 2.1.329) calls
 * `showTextDocument(Uri.file(path))` and, on success, reads
 * `editor.document.getText()` / `positionAt`. A `Uri` has neither, which is
 * how a click used to open an empty "untitled". A NUL byte is refused rather
 * than shown: `openFile` then falls through to `vscode.open`, and a binary
 * dump is not a document.
 */
function readFileTextDocument(filePath) {
  const buf = fs.readFileSync(filePath);
  if (buf.includes(0)) {
    const err = new Error(`file is not UTF-8 text: ${filePath}`);
    err.code = "EUTF8";
    throw err;
  }
  let content = buf.toString("utf8");
  if (Buffer.byteLength(content) > SHOW_DOCUMENT_MAX_BYTES) {
    content = headUtf8(content, SHOW_DOCUMENT_MAX_BYTES) + SHOW_DOCUMENT_TRUNCATION_NOTE;
  }
  const uri = Uri.file(filePath);
  return {
    getText() {
      return content;
    },
    languageId: languageIdForPath(filePath),
    uri,
    fileName: uri.fsPath,
    isUntitled: false,
    version: 1,
    lineCount: content.split("\n").length,
    positionAt(offset) {
      return positionAt(content, offset);
    },
  };
}

function openFileTextDocument(filePath) {
  try {
    return Promise.resolve(readFileTextDocument(filePath));
  } catch (err) {
    return Promise.reject(err);
  }
}

function openTextDocument(uriOrOptions) {
  if (typeof uriOrOptions === "string") {
    return openFileTextDocument(uriOrOptions);
  }
  if (uriOrOptions instanceof Uri) {
    // `untitled:` is how the extension opens a save-as buffer. Reading that
    // path off disk would show whatever file happens to be there.
    if (uriOrOptions.scheme !== "file") {
      return Promise.reject(new Error("not implemented"));
    }
    return openFileTextDocument(uriOrOptions.fsPath);
  }
  if (uriOrOptions && typeof uriOrOptions === "object") {
    // { content, language } form — virtual document
    const content = uriOrOptions.content || "";
    const language = uriOrOptions.language || "plaintext";
    return Promise.resolve({
      getText() {
        return content;
      },
      languageId: language,
      uri: Uri.from({ scheme: "untitled", path: "untitled" }),
      fileName: "untitled",
      isUntitled: true,
      version: 1,
      lineCount: content.split("\n").length,
    });
  }
  return Promise.reject(new Error("not implemented"));
}

// ---------------------------------------------------------------------------
// createWorkspace
// ---------------------------------------------------------------------------

function createWorkspace({ cwd, settingsPath, extensionPackageJson, canopySettingsPath }) {
  const folderUri = Uri.file(cwd);
  const folderName = path.basename(cwd);
  const workspaceFolder = { uri: folderUri, name: folderName, index: 0 };
  const workspaceFolders = [workspaceFolder];

  const noopEvent = (_listener) => new Disposable(() => {});
  const noopDisposable = () => new Disposable(() => {});

  const getConfiguration = createConfiguration(
    settingsPath || path.join(cwd, ".vscode", "settings.json"),
    extensionPackageJson || {},
    canopySettingsPath,
  );

  return {
    workspaceFolders,

    getConfiguration,

    async findFiles(pattern, exclude, maxResults) {
      const max = maxResults != null ? maxResults : 100;
      const patternStr =
        pattern instanceof RelativePattern ? pattern.pattern : String(pattern);
      const excludeStr =
        exclude instanceof RelativePattern
          ? exclude.pattern
          : exclude
            ? String(exclude)
            : null;
      const baseDir =
        pattern instanceof RelativePattern ? pattern.base : cwd;
      return findFilesImpl(baseDir, patternStr, excludeStr, max, 10);
    },

    openTextDocument,

    asRelativePath(pathOrUri) {
      const p =
        typeof pathOrUri === "string"
          ? pathOrUri
          : pathOrUri && pathOrUri.fsPath
            ? pathOrUri.fsPath
            : String(pathOrUri);
      return path.relative(cwd, p);
    },

    getWorkspaceFolder(_uri) {
      return workspaceFolder;
    },

    applyEdit() {
      return Promise.resolve(false);
    },

    textDocuments: [],
    workspaceFile: undefined,
    rootPath: cwd,

    fs: {
      async stat(uri) {
        const p = uri instanceof Uri ? uri.fsPath : String(uri);
        const s = await fsPromises.stat(p);
        return s;
      },
      async readFile(uri) {
        const p = uri instanceof Uri ? uri.fsPath : String(uri);
        const buf = await fsPromises.readFile(p);
        return new Uint8Array(buf);
      },
      async writeFile(uri, content) {
        const p = uri instanceof Uri ? uri.fsPath : String(uri);
        await fsPromises.writeFile(p, content);
      },
    },

    registerFileSystemProvider() {
      return new Disposable(() => {});
    },

    registerTextDocumentContentProvider() {
      return new Disposable(() => {});
    },

    // onDidChange* events — all no-op
    onDidChangeConfiguration: noopEvent,
    onDidChangeWorkspaceFolders: noopEvent,
    onDidOpenTextDocument: noopEvent,
    onDidCloseTextDocument: noopEvent,
    onDidChangeTextDocument: noopEvent,
    onDidSaveTextDocument: noopEvent,
    onDidCreateFiles: noopEvent,
    onDidDeleteFiles: noopEvent,
    onDidRenameFiles: noopEvent,

    createFileSystemWatcher() {
      return {
        onDidChange: noopEvent,
        onDidCreate: noopEvent,
        onDidDelete: noopEvent,
        dispose() {},
      };
    },
  };
}

module.exports = {
  createWorkspace,
  loadJson,
  readFileTextDocument,
  SHOW_DOCUMENT_MAX_BYTES,
  SHOW_DOCUMENT_TRUNCATION_NOTE,
};
