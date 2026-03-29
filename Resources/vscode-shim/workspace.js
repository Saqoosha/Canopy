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

async function findFilesImpl(baseDir, pattern, exclude, maxResults, maxDepth) {
  const regex = globToRegExp(pattern);
  const excludeRegex = exclude ? globToRegExp(exclude) : null;
  const results = [];

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

function createConfiguration(settingsPath, extensionPackageJson) {
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

  return function getConfiguration(section) {
    const userSettings = loadJson(settingsPath);

    return {
      get(key, defaultValue) {
        const fullKey = section ? `${section}.${key}` : key;

        // 1. User settings
        if (Object.prototype.hasOwnProperty.call(userSettings, fullKey)) {
          return userSettings[fullKey];
        }
        // 2. Extension package.json defaults
        if (Object.prototype.hasOwnProperty.call(extDefaults, fullKey)) {
          return extDefaults[fullKey];
        }
        // 3. Provided default
        return defaultValue;
      },

      has(key) {
        const fullKey = section ? `${section}.${key}` : key;
        return (
          Object.prototype.hasOwnProperty.call(userSettings, fullKey) ||
          Object.prototype.hasOwnProperty.call(extDefaults, fullKey)
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
        return {
          key: fullKey,
          defaultValue: Object.prototype.hasOwnProperty.call(extDefaults, fullKey)
            ? extDefaults[fullKey]
            : undefined,
          globalValue: Object.prototype.hasOwnProperty.call(currentSettings, fullKey)
            ? currentSettings[fullKey]
            : undefined,
          workspaceValue: undefined,
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

function createWorkspace({ cwd, settingsPath, extensionPackageJson }) {
  const folderUri = Uri.file(cwd);
  const folderName = path.basename(cwd);
  const workspaceFolder = { uri: folderUri, name: folderName, index: 0 };
  const workspaceFolders = [workspaceFolder];

  const noopEvent = (_listener) => new Disposable(() => {});
  const noopDisposable = () => new Disposable(() => {});

  const getConfiguration = createConfiguration(
    settingsPath || path.join(cwd, ".vscode", "settings.json"),
    extensionPackageJson || {},
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
