# Agent Purge

Agent Purge is a Windows PowerShell 5.1 CLI for inspecting local Codex and Claude storage and selectively removing recognized items. Scans do not change provider data. It has no required dependencies; Python is optional for reading Codex session titles from SQLite.

## Install from GitHub

With Git for Windows installed, clone the repository and install from the checkout:

```powershell
git clone https://github.com/Etriii/agent-purge.git
Set-Location .\agent-purge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 install
```

Open a new terminal, then run `agent-purge --help`. A private repository requires GitHub access configured for Git on this machine.

To update, pull the latest `main` branch in the same checkout and run `install` again:

```powershell
Set-Location path\to\agent-purge
git pull --ff-only origin main
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 install
```

`install` replaces the installed script and launcher and does not add a duplicate PATH entry. If `git pull` fails, stop and resolve that before running `install`.

For a public repository, Git is optional. Download the script from the `main` branch with PowerShell, then run `install`; repeat these commands to update:

```powershell
$download = Join-Path $env:TEMP 'agent-purge.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/Etriii/agent-purge/main/agent-purge.ps1' -OutFile $download -ErrorAction Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $download install
```

The GitHub commands require this repository to contain the `main` branch.

## Local install and uninstall

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

Uninstall preserves other files in the install directory and refuses to remove an installed script or launcher that was modified after installation. It leaves the Git checkout or downloaded source file in place; those can be removed separately if no longer needed.

## Commands

| Command | Action |
| --- | --- |
| `agent-purge` | Open the guided menu with explanations for each choice. |
| `agent-purge clean` | Choose projects in a size-sorted checklist, then review cleanup. |
| `agent-purge clean --all` | Preselect all eligible sessions and logs; review and confirm before removal. |
| `agent-purge clean --all --advanced` | Also preselect verified old runtimes and known cache entries. |
| `agent-purge clean --project <path>` | Choose session history for a folder and its descendants. |
| `agent-purge scan --global` | Inspect known global Codex and Claude storage. |
| `agent-purge scan --global --advanced` | Also make verified old runtimes and provider cache entries selectable. |
| `agent-purge scan --project <path>` | Inspect sessions whose recorded working directory is the path or a descendant. |
| `agent-purge install` | Install the user-local launcher and PATH entry. |
| `agent-purge uninstall` | Remove the installed files and PATH entry. |
| `agent-purge --help` | Print command and key help. |

Both `scan` and `clean` require an interactive terminal to select or remove items. Redirected input always prints a **read-only** inventory, even with `clean --all`; there is no unattended deletion option. The global scan may take time because it measures logical file sizes. Inaccessible entries are marked **incomplete**, and affected totals are lower bounds.

## Choose projects and clean

Run `agent-purge clean`, or choose **Choose projects to clean** from the main menu:

1. Read the question and storage summary above the checklist. Projects are sorted largest first.
2. Move with **Up/Down**. The focused project shows item count, eligible size, and size distributions by provider and category, including percentages.
3. Press **Space** to select or deselect a project's eligible items. **A** selects all eligible items; press it again to clear them. The selected item count and size update as you choose.
4. Press **I** to inspect the focused group. You can narrow the selection by provider, category, or individual session. **B** or **Backspace** returns with your selection intact.
5. Press **Enter** in the project checklist to review cleanup methods and exact paths. Typed confirmation is still required. **B** at any review prompt returns to selection without removing anything.

For a head start with everything eligible selected, run:

```powershell
agent-purge clean --all
```

This opens the same checklist, with eligible items selected. Deselect any projects you want to keep, then press **Enter**. “All” covers recognized eligible agent storage in the scan; it does not include protected files, source-project folders, or unrecognized storage. Caches and verified old runtimes require `--advanced`.

Project rows use exact recorded working directories. A nested directory can have its own row; `--project <path>` limits the inventory to that directory and descendants. Shared logs, caches, runtimes, and other provider storage have a separate group because they cannot reliably be assigned to a project. Sessions with unavailable project metadata are inspection only.

All displayed sizes measure **inventoried agent storage**, including recognized session sidecars, rather than the source-project folder's size. Provider/category percentages describe the measured storage in the focused group. Eligible size is the portion selectable in the current mode, and selected size is the portion you chose. Logical bytes are an estimate, not guaranteed reclaimed disk space.

To run the updated source before reinstalling the launcher:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 clean
```

## Interactive keys

| Key | Action |
| --- | --- |
| Up / Down | Move through projects, providers, categories, or items. |
| Enter | Review selected cleanup in the project checklist; open a row in the inspector. |
| B / Backspace / Left | Go back, preserving selection and the inspector's previous cursor. At the top level, return to the main menu if launched there; otherwise exit. |
| Space | Select or deselect eligible items in the focused project, provider, category, or item. |
| A | Select all eligible items in the current view; press again to clear them. |
| I / Right | Inspect the focused project or shared-storage group. |
| C | Copy a session's resume command from its detail view. |
| D | Review selected items and cleanup methods. |
| Esc | Exit without further changes. |

`[ ]` means eligible but unselected, `[x]` means all eligible items selected, `[~]` means partly selected, and `[-]` means inspection only. Protected items are excluded from group selection and select-all. An item detail shows provider, recorded project, category, session date, logical size, exact path, title and its source, resume command, and eligibility. A stored title is labeled **stored**; a title taken from a first prompt is labeled **derived from first prompt**. Missing metadata leaves a session visible for inspection but not deletion.

## Cleanup safeguards

Recognized Claude session transcripts and matching session sidecar directories, plus known Claude logs, are selectable in normal mode. Advanced mode adds direct entries under known provider cache directories and runtime versions verified against current runtime targets. Credentials, settings, skills, plugins, worktrees, current binaries, active runtimes, and unknown paths are inspection only. A Claude session's project `memory` directory and global `history.jsonl` are never selected with its transcript; Claude may still show history references after transcript removal.

For eligible files and directories, choose **Recycle Bin** or **permanent** removal for the batch. Recycle Bin allows recovery until emptied and may not free disk space immediately. The preview lists every exact path, method, item count, and estimated logical size. Type `DELETE FILES` to confirm. Codex sessions use a separate **permanent** method through `codex delete <session-id>` to update provider records; type `DELETE CODEX` for that batch. Cancelling either batch does not authorize the other. All prompts finish before either batch executes: **B** returns without deleting anything, while **C** or a nonmatching confirmation skips that batch.

After cleanup, Agent Purge reports successful, skipped, and failed item counts and refreshes the inventory and sizes. Removed selections disappear; remaining eligible selections stay available for review. A failed multi-path item can be partially removed; check its per-path results before retrying.

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
