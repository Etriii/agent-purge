# Codex and Claude Cleanup CLI

## Summary

Create a standalone Windows PowerShell tool at `D:\ACollectionOfDevelopedSystems\ActiveDevelopment\agent-purge`. It will let users inspect global Codex and Claude storage or scan a project, drill into categories and sessions, select multiple items, and review a second confirmation before cleanup. Scanning will be read only.

## Implementation

- Ship one `agent-purge.ps1` script with a README. `install` copies it to a user-local directory, adds an `agent-purge` launcher to the user PATH, and `uninstall` removes only those installed files and that PATH entry. No administrator access is required. Document every command, key, install step, and uninstall step.
- Provide `agent-purge` for the interactive scope picker, `agent-purge scan --global`, `agent-purge scan --project <path>`, and `agent-purge --help`. Project scans include sessions whose working directory is the selected folder or a descendant.
- Use arrow keys to navigate, Enter to drill in, Space to select multiple items, and Backspace to go back. Keep selections while navigating. Show provider, project, category, session date, size, path, title, and a copyable resume command. Use stored titles when available; label titles derived from a first prompt. If Python is installed, use it read only to obtain Codex titles from SQLite; the CLI must still work without Python.
- Inventory known provider storage, including sessions, caches, logs, retained runtime versions, and protected state. Show credentials, settings, skills, plugins, current binaries, and worktrees for size inspection, but never make them selectable. An explicit advanced mode may unlock only verified old runtimes and provider caches.
- Before cleanup, show exact paths, item count, estimated logical size, and each item’s removal method. Let the user choose Recycle Bin or permanent removal for eligible files. Split selected Codex sessions into a separate permanent step using `codex delete <session-id>` and its own confirmation. Require the relevant app to be closed; recheck paths and active runtime targets immediately before removal. Report each success or failure and measure free space afterward.

## Verification

- Test global and project matching, nested projects, title fallbacks, resume commands, navigation, multiselection, cancellation, both removal methods, and the separate Codex session confirmation using disposable fixtures.
- Test that unknown paths, reparse points, active runtimes, worktrees, and protected state cannot be removed. Verify install and uninstall against a temporary user PATH and directory.
- Run a read-only scan against this PC and compare reported categories and sizes with the inspected storage. **Do not test deletion on live Codex or Claude data.**

## Assumptions

This is a Windows-first, locally installed release. The README will explain local installation and how to download the script from a GitHub release once one exists; publishing a repository is outside this implementation. Sizes are estimates because hard links and active files can make reclaimed space differ from the displayed total.
