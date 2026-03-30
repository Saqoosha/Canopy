# Release Canopy

Release a new version of Canopy with automatic version bump and release notes.

## Task

### 1. Get current version and changes

```bash
# Get current version from project.yml
grep 'MARKETING_VERSION:' project.yml

# Get previous tag
git tag --sort=-version:refname | head -1

# Get diff from previous tag (or initial if no tags)
git diff <previous_tag>..HEAD
```

### 2. Analyze diff and determine version bump

Based on the changes, determine the appropriate version bump:

- **Major (X.0.0)**: Breaking changes, major rewrites, incompatible API changes
- **Minor (X.Y.0)**: New features, significant improvements, new functionality
- **Patch (X.Y.Z)**: Bug fixes, small improvements, documentation, refactoring

Examples:
- New UI feature → Minor
- Bug fix → Patch
- Build/release scripts added → Patch (infrastructure)
- New command or major feature → Minor
- Complete rewrite → Major

### 3. Run release script with determined version

```bash
MODEL_NAME="<your model name>" ./scripts/release.sh <new_version>
```

Set `MODEL_NAME` to your actual model name (e.g., "Opus 4.6", "Sonnet 4.5") for the Co-Authored-By line in the commit message.

This builds, notarizes, creates DMG, commits, tags, and creates GitHub Release.

### 4. Generate release notes from diff

Analyze the actual code changes and write user-friendly release notes:

```markdown
### Features (if new features added)
- New feature description

### Changes (if improvements made)
- Change or improvement description

### Bug Fixes (if bugs fixed)
- Fixed issue description
```

**Important:**
- Do NOT include a top-level title (e.g., `## Canopy X.Y.Z`) — GitHub already shows the release title, so it would be duplicated
- Do NOT include a Requirements section — it's static and doesn't need to be repeated every release
- **Bug Fixes section should only include fixes for bugs that existed in the previous released version.** Do NOT include bug fixes that were made during the implementation of a new feature in the same release cycle (those are part of the feature development, not separate bug fixes).

### 5. Update GitHub Release

```bash
gh release edit v<new_version> --notes "<generated notes>"
```

### 6. Update Sparkle appcast

After release notes are finalized, update the appcast so Sparkle shows the correct notes:

```bash
./scripts/update_appcast.sh <new_version>
```

### 7. Show result

Display:
- New version number
- Release URL: `https://github.com/Saqoosha/Canopy/releases/tag/v<new_version>`

## Notes

- Always analyze the diff first before deciding version
- Be conservative: when in doubt, use Patch
- Release notes should describe user-visible changes, not implementation details
- **Release notes must be written in English**
