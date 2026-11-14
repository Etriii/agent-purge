# Agent Purge

Agent Purge is a Windows PowerShell 5.1 CLI for inspecting local Codex and Claude storage and selectively removing recognized items. Scans do not change provider data. It has no required dependencies; Python is optional for reading Codex session titles from SQLite.

## Run and install

From this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 --help
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 install
```

`install` copies the script and creates `agent-purge.cmd` under `%LOCALAPPDATA%\Programs\agent-purge`, then adds that directory to the **user** PATH. It does not require administrator access. Open a new terminal after installing. Re-running `install` updates the installed copy. If that directory already exists without an Agent Purge install marker, installation stops rather than overwriting it.

To remove the installed script, launcher, marker, and only its PATH entry:

```powershell
agent-purge uninstall
```

Uninstall preserves other files in the install directory and refuses to remove an installed script or launcher that was modified after installation.

When a GitHub release is published, download `agent-purge.ps1` from that release into a local directory, review it, and run the same `install` command from that directory. No release URL is available yet.

## Commands

| Command | Action |
| --- | --- |
| `agent-purge` | Choose global or project scan interactively. |
| `agent-purge scan --global` | Inspect known global Codex and Claude storage. |
| `agent-purge scan --global --advanced` | Also make verified old runtimes and provider cache entries selectable. |
| `agent-purge scan --project <path>` | Inspect sessions whose recorded working directory is the path or a descendant. |
| `agent-purge install` | Install the user-local launcher and PATH entry. |
| `agent-purge uninstall` | Remove the installed files and PATH entry. |
| `agent-purge --help` | Print command and key help. |

`scan` requires an interactive terminal to select or remove items. Redirected input prints a read-only text inventory. The global scan may take time because it measures logical file sizes. Inaccessible entries are marked **incomplete**.

## Interactive keys

| Key | Action |
| --- | --- |
| Up / Down | Move through providers, categories, or items. |
| Enter | Open the highlighted provider, category, or item details. |
| Backspace | Return to the previous level. |
| Space | Select or deselect an eligible item; selections persist while browsing. |
| C | Copy a session's resume command from its detail view. |
| D | Review selected items and cleanup methods. |
| Esc | Exit without further changes. |

An item detail shows provider, recorded project, category, session date, logical size, exact path, title and its source, resume command, and eligibility. `[-]` marks inspection-only items. A stored title is labeled **stored**; a title taken from a first prompt is labeled **derived from first prompt**. Missing metadata leaves a session visible for inspection but not deletion.

## Cleanup safeguards

Recognized Claude session transcripts and matching session sidecar directories, plus known Claude logs, are selectable in normal mode. Advanced mode adds direct entries under known provider cache directories and runtime versions verified against current runtime targets. Credentials, settings, skills, plugins, worktrees, current binaries, active runtimes, and unknown paths are inspection only. A Claude session's project `memory` directory and global `history.jsonl` are never selected with its transcript; Claude may still show history references after transcript removal.

For eligible files and directories, choose **Recycle Bin** or **permanent** removal for the batch. The preview lists every exact path, method, item count, and estimated logical size. Type `DELETE FILES` to confirm. Codex sessions are handled in a separate **permanent** step through `codex delete <session-id>`; type `DELETE CODEX` for that step. Cancelling either step does not authorize the other.

Close the relevant provider app before cleanup. Agent Purge rechecks paths, metadata, reparse points, and active runtime targets immediately before removal. It reports each success, skip, or failure, then remeasures free space. Logical sizes can differ from reclaimed space because of hard links, Recycle Bin behavior, and provider database changes. The app-closed check can prevent deletion while running Agent Purge from within Codex or Claude itself; use a separate terminal after closing the app.

## Verify locally

The fixture test uses only a disposable temporary directory; it does not delete live provider data:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\agent-purge.Tests.ps1
```

To inspect the live inventory without cleanup, redirect input or run a scan and exit with Esc:

```powershell
'' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 scan --global
```
