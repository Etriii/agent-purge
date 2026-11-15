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

To check for a newer published version on `main`, run:

```powershell
agent-purge update
```

This works without an interactive terminal. It verifies the installed files and downloaded PowerShell syntax, then installs the download only when its embedded version is newer than the installed version. An older, equal, or unversioned published script leaves the installed copy intact, even when its hash differs. A failed download or check also leaves the installed version in place. Restart `agent-purge` after an update. The command does not update a Git checkout or downloaded source file. Run `agent-purge --version` to see the installed version.

Launching `agent-purge` does not contact GitHub. `update` checks published `main` only when you run it. The embedded version must increase for each published change; republishing changed code with the same version will not update existing installations.

To update a Git checkout as well, pull the latest `main` branch in that checkout and run `install` again:

```powershell
Set-Location path\to\agent-purge
git pull --ff-only origin main
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 install
```

`install` explicitly replaces the installed script and launcher and does not add a duplicate PATH entry. Unlike `update`, manual `install` can replace a newer installed version with an older checkout, so check `--version` first. If `git pull` fails, stop and resolve that before running `install`.

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

Uninstall preserves other files in the install directory and refuses to remove an installed script or launcher that was modified after installation. It leaves the Git checkout or downloaded source file, `%LOCALAPPDATA%\agent-purge\config.json`, and any Agent Purge undo folders in place; those can be removed separately when no longer needed.

## Commands

| Command | Action |
| --- | --- |
| `agent-purge` | Choose current project or global scope, then open the guided menu. |
| `agent-purge scan` | Inspect the selected scope. |
| `agent-purge clean` | Choose eligible items in the selected scope, then review cleanup. |
| `agent-purge clean --all` | Preselect eligible items in the selected scope; review before removal. |
| `agent-purge clean --all --advanced` | In global scope, also preselect verified old runtimes and known cache entries. |
| `agent-purge clean --project <path>` | Choose session history for a folder and its descendants. |
| `agent-purge scan --global` | Inspect known global Codex and Claude storage. |
| `agent-purge scan --global --advanced` | Also make verified old runtimes and provider cache entries selectable. |
| `agent-purge scan --project <path>` | Inspect sessions whose recorded working directory is the path or a descendant. |
| `agent-purge scope show` | Show this Git project's saved scope preference. |
| `agent-purge scope project` | Remember current project as the scope for this Git project. |
| `agent-purge scope global` | Remember global as the scope for this Git project. |
| `agent-purge scope ask` or `agent-purge scope reset` | Clear this project's preference so the next interactive run asks again. |
| `agent-purge install` | Install the user-local launcher and PATH entry. |
| `agent-purge update` | Update the installed command from published `main`. |
| `agent-purge --version` | Print the installed script version. |
| `agent-purge uninstall` | Remove the installed files and PATH entry. |
| `agent-purge restore <run-id> <hash>` | Restore files saved by one undo-folder cleanup run. |
| `agent-purge settings` | Change undo retention or location, or clean saved undo data. |
| `agent-purge settings show` | Display the saved retention and undo location. |
| `agent-purge settings set retention-days <1-365>` | Set retention for future undo runs. |
| `agent-purge settings set undo-dir <absolute-path>` | Move existing undo data and store future runs in that folder. |
| `agent-purge undo clean` | Inspect, select, and clean saved undo runs. |
| `agent-purge undo compress` | Retry NTFS compression on files already stored in undo folders. |
| `agent-purge --help` | Print command and key help. |

Both `scan` and `clean` require an interactive terminal to select or remove items. Redirected input always prints a **read-only** inventory, even with `clean --all`; there is no unattended deletion option. The global scan may take time because it measures logical file sizes. Inaccessible entries are marked **incomplete**, and affected totals are lower bounds.

## Current project scope

For the guided menu or a bare `scan` or `clean` inside a Git project or one of its subfolders, Agent Purge asks whether to use **Current project (recommended)** or **Global agent storage**. Press Up/Down to choose and Enter to continue. Press Space on **Do not ask again for this project** before Enter to save that choice for later runs in the same project. Without a saved choice, each interactive run asks again. A redirected, noninteractive `scan` or `clean` defaults to the current project without a prompt. Outside a Git project, the scope is global.

Current project scope matches Codex and Claude sessions whose recorded working directory is the Git project folder or a descendant. It excludes sessions from other projects, shared logs, caches, and runtimes. The scope applies to `scan`, `clean`, `clean --all`, and their menu actions. Explicit `scan --global`, `scan --project <path>`, or `clean --project <path>` overrides the saved choice for that command. Switching scope in the menu changes only the current run; `scope project` and `scope global` save the choice for that Git project. `scope show`, `scope ask`, and `scope reset` work from anywhere inside the project. Scope preferences are stored in `%LOCALAPPDATA%\agent-purge\config.json` and remain after uninstall.

Settings, restore, and undo-folder cleanup operate on the user-wide Agent Purge data regardless of the selected scan scope. Use `agent-purge settings show` to see the undo folder; cleaning that folder affects saved undo runs from all projects.

## Settings

Choose **Settings** from the main menu, or run `agent-purge settings`. Use **Up/Down** to focus undo retention, move undo folder, clean undo folder, compress saved undo files, or **Back to main menu**; **Enter/Space** opens the focused action. On undo retention, **Left/Right** changes the value by one day, **PgUp/PgDn** by ten days, and **Home** resets the draft to 30 days. Enter/Space saves the draft. The screen marks an edited value **unsaved** and shows the saved value separately. The **Move undo folder** action prompts for an absolute path; **Clean undo folder** opens the saved-run browser. **Compress saved undo files** retries NTFS compression on existing saved data without deleting it. **U** and **C** remain shortcuts for the move and clean actions. **B/Backspace** leaves without saving an edited retention value. The default retention is 30 days; the allowed range is 1–365. `settings show` prints both saved values.

To use another drive, run `agent-purge settings set undo-dir D:\AgentPurgeUndo`, replacing that path with a new or empty folder you control. Agent Purge copies and verifies existing undo data, switches the saved location, removes the verified old folders, then retries NTFS compression at the new location. Existing restore commands keep their original run IDs and hashes. Future undo runs use the new folder; a later location change moves it again. If a copy or check fails before the switch, the previous location remains active and its data stays in place. A failed cleanup after the switch leaves the old folder for inspection. The new folder must not overlap provider storage, the config file, or an existing undo folder.

Run `agent-purge undo clean` to browse saved undo runs. Each row shows its logical saved size and the number of stored paths; expired runs are labeled. Press **Enter** or **I** on a run to inspect its original paths and, for an unexpired run, its restore command. Press **Space** to select a run, or **A** to select or clear all eligible runs. The select-all row is above the run list; **Enter** on it selects any remaining runs and proceeds to review. **D** reviews the current selection. Choose **Recycle Bin** or **Permanent**, then confirm. Back and cancel choices appear last. Permanent deletion needs an acknowledgement and final confirmation; the safe default on destructive confirmation screens remains cancel. Cleanup removes only the selected runs' saved payloads and manifests. Other runs, the undo location, and its marker remain. Invalid manifests and payload folders without a matching manifest are reported; press **W** to view their exact paths. They are left untouched because Agent Purge cannot verify an automatic restore for them. Recycled payload folders carry a manifest copy for manual recovery until the Recycle Bin is emptied, but `agent-purge restore` no longer works for removed runs. Moving them to the Recycle Bin does not free disk space until it is emptied.

Settings are stored in `%LOCALAPPDATA%\agent-purge\config.json`. Each new undo run records its creation time and deadline from the current setting; changing the setting does not rewrite existing runs. A missing config uses the default, while an invalid config prevents new undo runs until corrected. The config is user-local and is not removed by `uninstall`.

## Choose projects and clean

In global scope, run `agent-purge clean` or choose **Choose projects to clean** from the main menu:

1. Read the question and storage summary above the checklist. Projects are sorted largest first.
2. Move with **Up/Down**. The focused project shows item count, eligible size, and size distributions by provider and category, including percentages.
3. The **Select all eligible items** row above the projects selects or clears the full current scope with **Space**. **Enter** selects any remaining eligible items and proceeds to review; pressing Enter again after returning to this row reviews the selection without clearing it. **A** toggles all from any project row. Press **Space** on a project to select or deselect only its eligible items. The selected item count and size update as you choose.
4. Press **I** to inspect the focused group. You can narrow the selection by provider, category, or individual session. **B** or **Backspace** returns with your selection intact.
5. Press **Enter** in the project checklist to review exact paths, choose a method with **Up/Down**, and confirm with **Enter** or **Space**. **B** returns to selection without removing anything.

For a head start with everything eligible selected, run:

```powershell
agent-purge clean --all
```

This opens the same checklist, with eligible items selected. Deselect any projects you want to keep, then press **Enter**. “All” covers recognized eligible agent storage in the current scope; it does not include protected files, source-project folders, or unrecognized storage. In global scope, caches and verified old runtimes require `--advanced`.

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
| PgUp / PgDn, Home / End | Jump through project and inspector lists by a screen or to either end. |
| F | Find a project in the checklist by part of its name or path. |
| Enter | Review selected cleanup, including from the select-all row; open other rows in the inspector. |
| B / Backspace | Go back, preserving selection. From a top-level view, return to the main menu. |
| Left | Go back one level in the inspector; stays in the project checklist. |
| Space | Select or deselect eligible items in the focused project, provider, category, or item. |
| A | Select all eligible items in the current view; press again to clear them. |
| I / Right | Inspect the focused project or shared-storage group. |
| C | Copy a session's resume command from its detail view. |
| D | Review selected items and cleanup methods. |
| Esc / Ctrl+C twice | Exit without further changes. One Ctrl+C waits for another key; any other key continues. |

`[ ]` means eligible but unselected, `[x]` means all eligible items selected, `[~]` means partly selected, and `[-]` means inspection only. The inspector also shows **Select all eligible items in this view** above its provider, category, and item lists; **Space** toggles only the items in that view, while **Enter** selects the remaining eligible items and opens review. Protected items are excluded from group selection and select-all. An item detail shows provider, recorded project, category, session date, logical size, exact path, title and its source, resume command, and eligibility. A stored title is labeled **stored**; a title taken from a first prompt is labeled **derived from first prompt**. Missing metadata leaves a session visible for inspection but not deletion.

## Cleanup safeguards

Recognized Claude session transcripts and matching session sidecar directories, plus known Claude logs, are selectable in normal mode. Advanced mode adds direct entries under known provider cache directories and runtime versions verified against current runtime targets. Credentials, settings, skills, plugins, worktrees, current binaries, active runtimes, and unknown paths are inspection only. A Claude session's project `memory` directory and global `history.jsonl` are never selected with its transcript; Claude may still show history references after transcript removal.

For eligible files and directories, use **Up/Down** and **Enter/Space** to choose the compressed Agent Purge undo folder, the Windows Recycle Bin, permanent removal, or skip. The review shows the selected item count, size, and paths; **PgUp/PgDn** browses path pages and **I** shows full paths. Recommended or next actions appear first; back and cancel choices appear last. **Keep files (cancel this batch)** remains the default focused confirmation choice and leaves the selected files untouched. If Codex sessions were also selected, they still need their own separate confirmation. Change file method from its confirmation screen without restarting the whole review. Permanent file and Codex deletion each require a separate acknowledgement screen followed by a final confirmation. No phrase must be typed.

The undo folder is the recommended method when you may need to reverse a cleanup. It moves eligible files, including Claude session transcripts, to the configured location and, on NTFS, asks Windows to compress them in place. A move across drives copies and verifies file contents before removing the original. This is transparent NTFS compression, not a ZIP archive. Text logs and transcripts may shrink substantially; tiny files, already compressed data, and other volume formats may save little or nothing. If compression fails, the moved files remain available for restore without compression. The displayed size is logical size, which does not shrink when a file is compressed. The files still occupy space in the undo folder. Check the final **Free space** change on the same drive, or Windows folder Properties > **Size on disk**, to see physical savings. The free-space measurement is a point-in-time value and may include other disk activity. Codex sessions are handled separately by Codex itself and are never included in this undo-folder move.

When the undo folder is on another drive, cleanup reports free space on both the source and destination drives. The source drive gains space while the destination uses space; compare both before judging overall savings. Run `agent-purge undo compress` to retry compression of existing saved files, including files copied by an earlier undo-folder move. The command reports how many files Windows marks compressed; that count does not measure bytes saved. Check **Size on disk** for the physical size. Compression does not make Codex session deletion restorable.

Each run prints a copy-paste command such as `agent-purge restore <run-id> <hash>` before and after moving files. Restore checks the run hash, skips occupied original paths rather than overwriting them, and reports each result. Close the provider app before restoring. The confirmation and result show each undo folder's full path. With default provider locations, it is `%USERPROFILE%\.agent-purge-undo`; the files for a run are in `payload\<run-id>`, and its manifest is in `runs\<run-id>.json`. Other provider storage volumes have their own `.agent-purge-undo` beside the relevant provider root. A configured folder keeps manifests in `runs` and payloads in `locations\<location-id>\payload\<run-id>`. You can inspect these folders directly. Deleting a run's payload ends its restore option; if you intentionally remove all payload copies for a run, also remove its matching manifest to avoid a stale restore record. `uninstall` leaves undo data in place.

At the saved deadline, `agent-purge restore` stops offering automatic restore for that run. On the next interactive Agent Purge launch, expired payloads move to the Windows Recycle Bin as one folder per volume named `agent-purge-<run-id>-<12-character-hash>`; a copy of the manifest travels with each folder. Runs spanning volumes create one folder on each volume. A restore attempt after expiry also triggers that run's move. This is launch-based, not a background timer: opening the app after day 30 performs the move then. The result stays visible until you press a key before the menu opens. Existing runs created before deadlines were recorded remain untouched. Recycle Bin recovery is manual and depends on the folder still being there; restore the named folder through Windows and use its manifest to identify the original paths. Moving it to the bin does not immediately free disk space; Windows or the user may empty the bin at any time. Failed moves leave the named bundle in an undo location for retry on a later launch. `uninstall` leaves settings, manifests, and any remaining undo data in place.

Recycle Bin items can be restored manually through Windows until the bin is emptied; Agent Purge cannot reliably target them by run ID. Permanent file removal has no restore command. Codex sessions use a separate permanent `codex delete <session-id>` operation to update provider records; they cannot use the undo folder or Recycle Bin. Confirm those sessions on their own warning and confirmation screens. Cancelling either batch does not authorize the other, and all prompts finish before either batch executes.

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
