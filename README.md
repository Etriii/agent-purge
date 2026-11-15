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

To update the installed command from published `main`, run:

```powershell
agent-purge update
```

This works without an interactive terminal. It verifies the installed files and downloaded PowerShell syntax before replacing the installed script. A failed download or check leaves the installed version in place and returns an error. Restart `agent-purge` to use the update. The command does not update a Git checkout or downloaded source file. Published `main` can be older than unpublished local work; `update` installs the published copy.

Each interactive launch of the installed `agent-purge` also checks published `main`. If it differs from the installed copy, press **U** to install it or **S** to skip and continue. **U** replaces the installed copy with published `main`, including when the current copy came from newer unpublished local work. If GitHub cannot be reached, the installed version continues to work. The check does not run for redirected input, `--help`, `install`, `update`, `uninstall`, or when running a source checkout directly.

To update a Git checkout as well, pull the latest `main` branch in that checkout and run `install` again:

```powershell
Set-Location path\to\agent-purge
git pull --ff-only origin main
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-purge.ps1 install
```

`install` replaces the installed script and launcher and does not add a duplicate PATH entry. If `git pull` fails, stop and resolve that before running `install`. Manual updates also work when you want to update the checkout itself.

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
| `agent-purge` | Open the guided menu with explanations for each choice. |
| `agent-purge clean` | Choose projects in a size-sorted checklist, then review cleanup. |
| `agent-purge clean --all` | Preselect all eligible sessions and logs; review and confirm before removal. |
| `agent-purge clean --all --advanced` | Also preselect verified old runtimes and known cache entries. |
| `agent-purge clean --project <path>` | Choose session history for a folder and its descendants. |
| `agent-purge scan --global` | Inspect known global Codex and Claude storage. |
| `agent-purge scan --global --advanced` | Also make verified old runtimes and provider cache entries selectable. |
| `agent-purge scan --project <path>` | Inspect sessions whose recorded working directory is the path or a descendant. |
| `agent-purge install` | Install the user-local launcher and PATH entry. |
| `agent-purge update` | Update the installed command from published `main`. |
| `agent-purge uninstall` | Remove the installed files and PATH entry. |
| `agent-purge restore <run-id> <hash>` | Restore files saved by one undo-folder cleanup run. |
| `agent-purge settings` | Change undo retention with arrow keys. |
| `agent-purge settings show` | Display the saved retention value. |
| `agent-purge settings set retention-days <1-365>` | Set retention for future undo runs. |
| `agent-purge --help` | Print command and key help. |

Both `scan` and `clean` require an interactive terminal to select or remove items. Redirected input always prints a **read-only** inventory, even with `clean --all`; there is no unattended deletion option. The global scan may take time because it measures logical file sizes. Inaccessible entries are marked **incomplete**, and affected totals are lower bounds.

## Settings

Choose **Settings** from the main menu, or run `agent-purge settings`. Use arrows to change the undo retention by one day, PgUp/PgDn by ten days, Home to return to 30 days, and Enter/Space to save. B/Backspace leaves without saving. The default is 30 days; the allowed range is 1–365. The optional `settings show` and `settings set retention-days <days>` commands provide the same value without the menu.

Settings are stored in `%LOCALAPPDATA%\agent-purge\config.json`. Each new undo run records its creation time and deadline from the current setting; changing the setting does not rewrite existing runs. A missing config uses the default, while an invalid config prevents new undo runs until corrected. The config is user-local and is not removed by `uninstall`.

## Choose projects and clean

Run `agent-purge clean`, or choose **Choose projects to clean** from the main menu:

1. Read the question and storage summary above the checklist. Projects are sorted largest first.
2. Move with **Up/Down**. The focused project shows item count, eligible size, and size distributions by provider and category, including percentages.
3. Press **Space** to select or deselect a project's eligible items. **A** selects all eligible items; press it again to clear them. The selected item count and size update as you choose.
4. Press **I** to inspect the focused group. You can narrow the selection by provider, category, or individual session. **B** or **Backspace** returns with your selection intact.
5. Press **Enter** in the project checklist to review exact paths, choose a method with **Up/Down**, and confirm with **Enter** or **Space**. **B** returns to selection without removing anything.

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
| B / Backspace | Go back, preserving selection. From a top-level view, return to the main menu. |
| Left | Go back one level in the inspector; stays in the project checklist. |
| Space | Select or deselect eligible items in the focused project, provider, category, or item. |
| A | Select all eligible items in the current view; press again to clear them. |
| I / Right | Inspect the focused project or shared-storage group. |
| C | Copy a session's resume command from its detail view. |
| D | Review selected items and cleanup methods. |
| Esc / Ctrl+C twice | Exit without further changes. One Ctrl+C waits for another key; any other key continues. |

`[ ]` means eligible but unselected, `[x]` means all eligible items selected, `[~]` means partly selected, and `[-]` means inspection only. Protected items are excluded from group selection and select-all. An item detail shows provider, recorded project, category, session date, logical size, exact path, title and its source, resume command, and eligibility. A stored title is labeled **stored**; a title taken from a first prompt is labeled **derived from first prompt**. Missing metadata leaves a session visible for inspection but not deletion.

## Cleanup safeguards

Recognized Claude session transcripts and matching session sidecar directories, plus known Claude logs, are selectable in normal mode. Advanced mode adds direct entries under known provider cache directories and runtime versions verified against current runtime targets. Credentials, settings, skills, plugins, worktrees, current binaries, active runtimes, and unknown paths are inspection only. A Claude session's project `memory` directory and global `history.jsonl` are never selected with its transcript; Claude may still show history references after transcript removal.

For eligible files and directories, use **Up/Down** and **Enter/Space** to choose the Agent Purge undo folder, the Windows Recycle Bin, permanent removal, or skip. The review shows the selected item count, size, and paths; **PgUp/PgDn** browses path pages and **I** shows full paths. Each confirmation defaults to **Cancel**. Change file method from its confirmation screen without restarting the whole review. Permanent file and Codex deletion each require a separate acknowledgement screen followed by a final confirmation. No phrase must be typed.

The undo folder is the recommended method when you may need to reverse a cleanup. Each run prints a copy-paste command such as `agent-purge restore <run-id> <hash>` before and after moving files. Restore checks the run hash, skips occupied original paths rather than overwriting them, and reports each result. Close the provider app before restoring. Saved files remain on their original volume in `.agent-purge-undo` beside the relevant provider storage root. The run manifest is in `.agent-purge-undo\runs` beside the Codex home directory. These folders are not removed automatically or by `uninstall`; they continue using disk space until you remove them manually after you no longer need the restore option.

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
