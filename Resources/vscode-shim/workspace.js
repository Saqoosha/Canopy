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
// openTextDocument
// ---------------------------------------------------------------------------

function openTextDocument(uriOrOptions) {
  if (uriOrOptions && typeof uriOrOptions === "object" && !(uriOrOptions instanceof Uri)) {
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
  // URI form — not implemented
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

module.exports = { createWorkspace };
