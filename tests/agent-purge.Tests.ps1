$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'agent-purge.ps1')

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-JsonLine([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Add-Content -LiteralPath $Path -Value ($Value | ConvertTo-Json -Compress -Depth 10)
}

$fixture = Join-Path $env:TEMP ('agent-purge-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $codexRoot = Join-Path $fixture 'codex'
    $claudeRoot = Join-Path $fixture 'claude'
    $packages = Join-Path $codexRoot 'packages'
    $versions = Join-Path $fixture 'versions'
    $ctx = New-AgentPurgeContext -CodexRoot $codexRoot -ClaudeRoot $claudeRoot -CodexPackages $packages -ClaudeVersions $versions -ClaudeBinary (Join-Path $fixture 'claude.exe') -CodexBinary (Join-Path $fixture 'codex.exe')
    $ctx | Add-Member -NotePropertyName CurrentClaudeVersion -NotePropertyValue '2.1.319'
    $project = Join-Path $fixture 'work'
    $child = Join-Path $project 'nested'
    $other = Join-Path $fixture 'work-other'
    New-Item -ItemType Directory -Path $child, $other -Force | Out-Null
    $cid = '11111111-1111-4111-8111-111111111111'
    $codexFile = Join-Path $codexRoot "sessions\2026\11\14\rollout-2026-11-14T12-00-00-$cid.jsonl"
    Write-JsonLine $codexFile @{type='session_meta';payload=@{id=$cid;cwd=$child;timestamp='2026-11-14T12:00:00Z'}}
    Write-JsonLine $codexFile @{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text='First Codex prompt'})}}
    $aid = '22222222-2222-4222-8222-222222222222'
    $claudeFile = Join-Path $claudeRoot "projects\fixture\$aid.jsonl"
    Write-JsonLine $claudeFile @{type='user';sessionId=$aid;cwd=$project;timestamp='2026-11-14T12:00:00Z';message=@{content='First Claude prompt'}}
    $sidecar = Join-Path (Split-Path -Parent $claudeFile) $aid
    New-Item -ItemType Directory -Path $sidecar | Out-Null
    Set-Content -LiteralPath (Join-Path $sidecar 'tool.txt') -Value 'data'
    $otherId = '33333333-3333-4333-8333-333333333333'
    $otherFile = Join-Path $claudeRoot "projects\other\$otherId.jsonl"
    Write-JsonLine $otherFile @{type='user';sessionId=$otherId;cwd=$other;timestamp='2026-11-14T12:00:00Z';message=@{content='Other prompt'}}
    $all = @(Get-SessionInventory $ctx)
    Assert ($all.Count -eq 3) 'Global session count'
    $matched = @(Get-SessionInventory $ctx $project)
    Assert ($matched.Count -eq 2) 'Project/descendant matching or path boundary'
    Assert ((@($matched | Where-Object { $_.Id -eq $cid })[0].Resume) -eq "codex resume $cid") 'Codex resume command'
    Assert ((@($matched | Where-Object { $_.Id -eq $cid })[0].Title) -eq 'First Codex prompt') 'Codex first-prompt title fallback'
    Assert ((@($matched | Where-Object { $_.Id -eq $aid })[0].TitleSource) -eq 'derived from first prompt') 'Claude title fallback'
    Assert ((@($matched | Where-Object { $_.Id -eq $aid })[0].Bytes) -gt (Get-Item $claudeFile).Length) 'Claude sidecar size'
    Assert (-not (Test-ProjectMatch $other $project)) 'Sibling project must not match'
    Assert ((Format-Bytes 1536) -eq '1.5 KB') 'Fractional sizes must not round to whole units'
    Assert ((Format-Bytes 1610612736) -eq '1.5 GB') 'Large sizes must retain precision'
    $projectGroups = @(Get-ProjectGroups $all)
    Assert ($projectGroups.Count -eq 3) 'Projects use exact recorded directories without merging descendants or siblings'
    $groupTotal = [long]0
    foreach ($group in $projectGroups) { $groupTotal += $group.Summary.Bytes }
    Assert ($groupTotal -eq (Get-InventorySummary $all).Bytes) 'Project totals must partition inventory without double counting sidecars'
    $sameProject = $all[0].PSObject.Copy()
    $sameProject.Project = $all[0].Project.ToUpperInvariant() + '\'
    $sameProject.Key = 'case-fixture'
    Assert (@(Get-ProjectGroups @($all[0], $sameProject)).Count -eq 1) 'Project grouping normalizes casing and trailing separators'
    $distribution = @(Format-SizeDistribution @($all[0], $sameProject) Provider)
    Assert ($distribution.Count -eq 1 -and $distribution[0] -match '100%') 'Distribution percentages use measured storage total'
    $sameProject.Bytes = 0
    Assert ((Format-SizeDistribution @($sameProject) Provider) -match '0%') 'Empty byte totals do not divide by zero'
    $sameProject.Incomplete = $true; $sameProject.Eligible = $false
    Assert ((Get-InventorySummary @($sameProject)).Incomplete) 'Incomplete measurements propagate to summaries'
    $sameProject.Project = ''; $sameProject.Category = 'Sessions'
    $shared = $sameProject.PSObject.Copy(); $shared.Key = 'shared-fixture'; $shared.Category = 'Logs'
    $buckets = @(Get-ProjectGroups @($all[0], $sameProject, $shared))
    Assert ($buckets.Count -eq 3 -and 'shared' -in $buckets.Key -and 'unknown' -in $buckets.Key) 'Shared files and unavailable project metadata stay separate'
    $selection = @{}
    Switch-ItemSelection @($all[0], $sameProject) $selection
    Assert ($selection.Count -eq 1 -and -not $selection.ContainsKey($sameProject.Key)) 'Bulk selection excludes protected entries'
    Assert ((Get-SelectionMark @($all[0], $sameProject) $selection) -eq '[x]') 'Group selection applies to eligible entries only'
    Assert ((Get-SelectionMark $all $selection) -eq '[~]') 'Partial group selection is visible'
    Assert ((Get-SelectionMark @($sameProject) $selection) -eq '[-]') 'Protected-only groups cannot be selected'
    Switch-ItemSelection $all $selection
    Assert ($selection.Count -eq 3) 'Select all fills partial selection'
    Assert ((Get-InventorySummary $all $selection).SelectedBytes -eq $groupTotal) 'Selected size matches the selected items'
    Switch-ItemSelection $all $selection
    Assert ($selection.Count -eq 0) 'Select all toggles back to clear'
    $selection[$sameProject.Key] = $true
    Assert (@(Get-SelectedItems @($sameProject) $selection).Count -eq 0) 'Stale selections cannot include protected items'
    $unassignedId = '44444444-4444-4444-8444-444444444444'
    $unassignedFile = Join-Path $codexRoot "sessions\rollout-unknown-$unassignedId.jsonl"
    Write-JsonLine $unassignedFile @{type='session_meta';payload=@{id=$unassignedId;timestamp='2026-11-14T12:00:00Z'}}
    $unassigned = @(Get-SessionInventory $ctx | Where-Object Path -eq $unassignedFile)[0]
    Assert (-not $unassigned.Eligible -and $unassigned.Reason -match 'metadata') 'Missing Codex project metadata remains inspection only in clean-all'
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $db = Join-Path $codexRoot 'state_5.sqlite'
        $dbCode = @'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('create table threads (id text, title text)')
c.execute('insert into threads values (?, ?)', (sys.argv[2], 'Stored Codex title'))
c.commit()
c.close()
'@
        $dbCode | python - $db $cid
        $stored = @(Get-SessionInventory $ctx $project | Where-Object Id -eq $cid)[0]
        Assert ($stored.Title -eq 'Stored Codex title' -and $stored.TitleSource -eq 'stored') 'SQLite stored title'
    }
    $state = [pscustomobject]@{Level=0;Provider='';Category='';Index=0;DetailKey=''}
    $state = Update-NavState $state 'DownArrow' @('Claude','Codex')
    Assert ($state.Index -eq 1) 'Arrow navigation'
    $state = Update-NavState $state 'Enter' @('Claude','Codex')
    Assert ($state.Provider -eq 'Codex' -and $state.Level -eq 1) 'Drill-down navigation'
    $state = Update-NavState $state 'Backspace' @('Sessions')
    Assert ($state.Level -eq 0 -and $state.Index -eq 1) 'Back navigation restores the previous cursor'
    $state = Update-NavState $state 'Enter' @('Claude','Codex')
    $state = Update-NavState $state 'B' @('Sessions')
    Assert ($state.Level -eq 0 -and $state.Index -eq 1) 'B is a back shortcut'
    $selected = @{}; $selected[$matched[0].Key] = $true; $selected[$matched[1].Key] = $true
    Assert (@(Get-SelectedItems $matched $selected).Count -eq 2) 'Multiselection persists'
    Assert (-not (Test-SafeItem $matched[0] $ctx)) 'Session safety check'
    $unknown = New-InventoryItem $ctx 'Claude' 'Other' 'Inspection' $otherFile
    Assert ((Test-SafeItem $unknown $ctx) -ne '') 'Unknown path must be refused'
    New-Item -ItemType Directory -Path (Join-Path $claudeRoot 'cache') -Force | Out-Null
    $cacheFile = Join-Path $claudeRoot 'cache\item.txt'
    Set-Content -LiteralPath $cacheFile -Value 'cache'
    $cache = New-InventoryItem $ctx 'Claude' 'Caches' 'Cache' $cacheFile '' '' '' '' '' '' $true
    Assert ((Test-SafeItem $cache $ctx $false) -ne '') 'Cache requires advanced mode'
    Assert (-not (Test-SafeItem $cache $ctx $true)) 'Known cache is eligible in advanced mode'
    $protected = Join-Path $claudeRoot 'settings.json'
    Set-Content -LiteralPath $protected -Value '{}'
    Assert ((Test-SafeItem (New-InventoryItem $ctx 'Claude' 'Other' 'Inspection' $protected) $ctx $true) -ne '') 'Settings protected'
    $worktree = Join-Path $codexRoot 'worktrees\one'
    New-Item -ItemType Directory -Path $worktree -Force | Out-Null
    Assert ((Test-SafeItem (New-InventoryItem $ctx 'Codex' 'Other' 'Inspection' $worktree) $ctx $true) -ne '') 'Worktrees protected'
    New-Item -ItemType Directory -Path $versions -Force | Out-Null
    $currentRuntime = Join-Path $versions '2.1.319'
    $oldRuntime = Join-Path $versions '2.1.299'
    Set-Content -LiteralPath $currentRuntime -Value 'current'
    Set-Content -LiteralPath $oldRuntime -Value 'old'
    Assert ((Test-SafeItem (New-InventoryItem $ctx 'Claude' 'Runtimes' 'ClaudeRuntime' $currentRuntime '' '' '' '' '' '' $true) $ctx $true) -ne '') 'Active runtime protected'
    Assert (-not (Test-SafeItem (New-InventoryItem $ctx 'Claude' 'Runtimes' 'ClaudeRuntime' $oldRuntime '' '' '' '' '' '' $true) $ctx $true)) 'Old runtime eligible'
    $releaseRoot = Join-Path $packages 'standalone\releases'
    $activeRelease = Join-Path $releaseRoot '0.169.0-x86_64-pc-windows-msvc'
    $oldRelease = Join-Path $releaseRoot '0.168.0-x86_64-pc-windows-msvc'
    New-Item -ItemType Directory -Path $activeRelease, $oldRelease -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $packages 'standalone\auto-update-version') -Value '0.169.0-x86_64-pc-windows-msvc'
    try {
        New-Item -ItemType Junction -Path (Join-Path $packages 'standalone\current') -Target $activeRelease -ErrorAction Stop | Out-Null
        Assert ((Test-SafeItem (New-InventoryItem $ctx 'Codex' 'Runtimes' 'CodexRuntime' $activeRelease '' '' '' '' '' '' $true) $ctx $true) -ne '') 'Current Codex runtime protected'
        Assert (-not (Test-SafeItem (New-InventoryItem $ctx 'Codex' 'Runtimes' 'CodexRuntime' $oldRelease '' '' '' '' '' '' $true) $ctx $true)) 'Old Codex runtime eligible'
    } catch [System.UnauthorizedAccessException] { Write-Host 'Junction fixture unavailable on this host.' }
    $recycleFile = Join-Path $claudeRoot 'debug\recycle.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $recycleFile) -Force | Out-Null
    Set-Content -LiteralPath $recycleFile -Value 'trash'
    $log = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $recycleFile '' '' '' '' '' '' $true
    Assert (-not (Test-SafeItem $log $ctx)) 'Known log eligible'
    Invoke-FileRemoval $recycleFile 'Recycle Bin'
    Assert (-not (Test-Path -LiteralPath $recycleFile)) 'Recycle Bin removal'
    Invoke-FileRemoval $cacheFile 'Permanent'
    Assert (-not (Test-Path -LiteralPath $cacheFile)) 'Permanent removal'
    $cacheDir = Join-Path $claudeRoot 'cache\folder'
    New-Item -ItemType Directory -Path $cacheDir | Out-Null
    Set-Content -LiteralPath (Join-Path $cacheDir 'child.txt') -Value 'data'
    Invoke-FileRemoval $cacheDir 'Recycle Bin'
    Assert (-not (Test-Path -LiteralPath $cacheDir)) 'Recycle Bin directory removal'
    $codexLog = Join-Path $codexRoot 'sandbox.2026-11-14.log'
    Set-Content -LiteralPath $codexLog -Value 'log'
    Assert (-not (Test-SafeItem (New-InventoryItem $ctx 'Codex' 'Logs' 'Log' $codexLog '' '' '' '' '' '' $true) $ctx)) 'Known Codex log eligible'
    $link = Join-Path $claudeRoot 'cache\link'
    try {
        New-Item -ItemType Junction -Path $link -Target $sidecar -ErrorAction Stop | Out-Null
        $linked = New-InventoryItem $ctx 'Claude' 'Caches' 'Cache' $link '' '' '' '' '' '' $true
        Assert ((Test-SafeItem $linked $ctx $true) -ne '') 'Reparse point protected'
    } catch [System.UnauthorizedAccessException] { Write-Host 'Reparse fixture unavailable on this host.' }
    $confirmFile = Join-Path $claudeRoot 'debug\confirmation.txt'
    Set-Content -LiteralPath $confirmFile -Value 'confirmation'
    $confirmLog = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $confirmFile '' '' '' '' '' '' $true
    $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
    $script:deletedIds = @()
    function Read-Host { param([string]$Prompt) return $script:answers.Dequeue() }
    function Test-AppClosed { param([string]$Provider) return $true }
    function Invoke-CodexDeletion { param([string]$Id) $script:deletedIds += $Id }
    foreach ($reviewAnswers in @(@('B'), @('P', 'B'), @('P', 'DELETE FILES', 'B'))) {
        foreach ($answer in $reviewAnswers) { $script:answers.Enqueue($answer) }
        Invoke-Cleanup @($confirmLog, ($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
        Assert ((Test-Path $confirmFile) -and $script:deletedIds.Count -eq 0) 'Back at any review prompt must leave both batches intact'
        Assert ($script:answers.Count -eq 0) 'Back consumes only the current review prompts'
    }
    $script:answers.Enqueue('C')
    $script:answers.Enqueue('CANCEL')
    Invoke-Cleanup @($confirmLog, ($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
    Assert ((Test-Path $confirmFile) -and $script:deletedIds.Count -eq 0) 'Cancellation leaves both batches intact'
    $script:answers.Enqueue('P')
    $script:answers.Enqueue('DELETE FILES')
    $script:answers.Enqueue('CANCEL')
    Invoke-Cleanup @($confirmLog, ($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
    Assert (-not (Test-Path $confirmFile)) 'Confirmed file batch removed'
    Assert ($script:deletedIds.Count -eq 0) 'File confirmation does not authorize Codex'
    $script:answers.Enqueue('DELETE CODEX')
    Invoke-Cleanup @(($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
    Assert ($script:deletedIds.Count -eq 1 -and $script:deletedIds[0] -eq $cid) 'Separate Codex confirmation'
    $installRoot = Join-Path $fixture 'install'
    $oldPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
    $originalSource = $script:AgentPurgeScript
    try {
        Install-AgentPurge -InstallRoot $installRoot -PathScope Process | Out-Null
        Assert ((Test-Path (Join-Path $installRoot 'agent-purge.cmd')) -and ([Environment]::GetEnvironmentVariable('Path', 'Process') -match [regex]::Escape($installRoot))) 'Install files/PATH'
        $updatedSource = Join-Path $fixture 'updated-agent-purge.ps1'
        Set-Content -LiteralPath $updatedSource -Value '# update fixture'
        $script:AgentPurgeScript = $updatedSource
        Install-AgentPurge -InstallRoot $installRoot -PathScope Process | Out-Null
        Assert ((Get-Content -LiteralPath (Join-Path $installRoot 'agent-purge.ps1') -Raw) -match 'update fixture') 'Update replaces installed script'
        $pathEntries = @([Environment]::GetEnvironmentVariable('Path', 'Process') -split ';' | Where-Object { $_ -eq $installRoot })
        Assert ($pathEntries.Count -eq 1) 'Update keeps one PATH entry'
        $installedScript = Join-Path $installRoot 'agent-purge.ps1'
        $script:AgentPurgeScript = $installedScript
        $script:updateSource = $updatedSource
        $script:updateRequests = 0
        $script:updateKeys = New-Object 'System.Collections.Generic.Queue[string]'
        function Test-InteractiveTerminal { return $true }
        function Read-MenuKey { return $script:updateKeys.Dequeue() }
        function Invoke-WebRequest {
            param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, [int]$TimeoutSec, $ErrorAction)
            $script:updateRequests++
            if ($script:updateSource -eq 'offline') { throw 'Network unavailable' }
            Copy-Item -LiteralPath $script:updateSource -Destination $OutFile
        }
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Matching remote script needs no update'
        $remoteUpdate = Join-Path $fixture 'remote-agent-purge.ps1'
        Set-Content -LiteralPath $remoteUpdate -Value '# newer fixture'
        $script:updateSource = $remoteUpdate
        $script:updateKeys.Enqueue('S')
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Skip continues without updating'
        Assert ((Get-Content -LiteralPath $installedScript -Raw) -match 'update fixture') 'Skip preserves installed script'
        $script:updateKeys.Enqueue('U')
        Assert (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process) 'Update choice installs downloaded script'
        $installedHash = (Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash
        $markerHash = (Get-Content -LiteralPath (Join-Path $installRoot 'install.json') -Raw | ConvertFrom-Json).scriptHash
        Assert ($installedHash -eq $markerHash -and $installedHash -eq (Get-FileHash -LiteralPath $remoteUpdate -Algorithm SHA256).Hash) 'Update refreshes script and install marker'
        $invalidUpdate = Join-Path $fixture 'invalid-agent-purge.ps1'
        Set-Content -LiteralPath $invalidUpdate -Value '{'
        $script:updateSource = $invalidUpdate
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Invalid downloaded script is rejected'
        Assert ((Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash -eq $installedHash) 'Invalid update preserves installed script'
        $script:updateSource = 'offline'
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Network failure continues with installed version'
        Assert ((Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash -eq $installedHash) 'Network failure preserves installed script'
        $requests = $script:updateRequests
        Add-Content -LiteralPath $installedScript -Value '# local edit'
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Changed installed script is not overwritten'
        Assert ($script:updateRequests -eq $requests) 'Changed installed script is checked before download'
        Copy-Item -LiteralPath $remoteUpdate -Destination $installedScript -Force
        function Test-InteractiveTerminal { return $false }
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Redirected input skips update check'
        $script:AgentPurgeScript = $originalSource
        function Test-InteractiveTerminal { return $true }
        Assert (-not (Invoke-StartupUpdateCheck -InstallRoot $installRoot -PathScope Process)) 'Source checkout skips installed update check'
        Assert ($script:updateRequests -eq $requests) 'Skipped checks do not contact GitHub'
        Uninstall-AgentPurge -InstallRoot $installRoot -PathScope Process | Out-Null
        Assert (-not (Test-Path $installRoot)) 'Uninstall files'
        Assert (-not ([Environment]::GetEnvironmentVariable('Path', 'Process') -match [regex]::Escape($installRoot))) 'Uninstall PATH'
    } finally { $script:AgentPurgeScript = $originalSource; [Environment]::SetEnvironmentVariable('Path', $oldPath, 'Process') }
    # Drive the real menus with fixture keys and capture their rendered text.
    $script:keys = New-Object 'System.Collections.Generic.Queue[string]'
    $script:screen = New-Object 'System.Collections.Generic.List[string]'
    function Read-MenuKey {
        if (-not $script:keys.Count) { throw 'Unexpected extra keyboard prompt' }
        return $script:keys.Dequeue()
    }
    function Clear-Host { }
    function Write-Host { param([object]$Object, $ForegroundColor) $script:screen.Add([string]$Object) }
    function Test-InteractiveTerminal { return $true }
    $ui = [pscustomobject]@{Items=$all;Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    foreach ($key in @('Spacebar', 'I', 'Enter', 'Enter', 'Enter', 'B', 'B', 'B', 'B', 'Enter', 'B')) { $script:keys.Enqueue($key) }
    # The largest fixture project has a Codex session; cancel its review and return.
    $script:answers.Enqueue('B')
    Assert ((Invoke-ProjectPicker $ui) -eq 'Back') 'Project picker supports inspect, nested back, review, and back to home'
    Assert ($ui.Selected.Count -eq 1) 'Selection persists through nested inspector and cancelled review'
    Assert ($script:screen -match 'Which projects' -and $script:screen -match 'Selected:' -and $script:screen -match '100%') 'Picker shows context, selected size, and distributions'
    Assert ($script:keys.Count -eq 0 -and $script:answers.Count -eq 0) 'Menu flow consumes the expected input only'
    foreach ($key in @('A', 'Escape')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $ui) -eq 'Exit') 'Escape exits the picker'
    Assert ($ui.Selected.Count -eq 3) 'A selects all eligible projects from partial selection'
    $emptyUI = [pscustomobject]@{Items=@();Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    foreach ($key in @('Enter', 'A', 'Spacebar', 'B')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $emptyUI) -eq 'Back') 'Empty inventory remains navigable without cleanup'
    Assert ($script:screen -match 'Nothing selected') 'Enter with no selection explains how to proceed'
    foreach ($key in @('DownArrow', 'Enter')) { $script:keys.Enqueue($key) }
    Assert (((Show-StartMenu) -join ' ') -eq 'scan --global') 'Home menu arrow navigation chooses inspection'
    foreach ($key in @('P', 'Escape')) { $script:keys.Enqueue($key) }
    $script:answers.Enqueue('')
    Assert (@(Show-StartMenu).Count -eq 0) 'Empty project path returns to home; Escape exits'
    $protectedUI = [pscustomobject]@{Items=@($sameProject);Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    foreach ($key in @('Spacebar', 'A', 'B')) { $script:keys.Enqueue($key) }
    [void](Invoke-ProjectPicker $protectedUI)
    Assert ($protectedUI.Selected.Count -eq 0) 'Menu cannot select protected-only groups'
    $refreshFile = Join-Path $claudeRoot 'debug\refresh.txt'
    Set-Content -LiteralPath $refreshFile -Value 'refresh fixture'
    $refreshItem = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $refreshFile '' '' '' '' '' '' $true
    $refreshUI = [pscustomobject]@{Items=@($refreshItem);Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    $refreshUI.Selected[$refreshItem.Key] = $true
    $script:answers.Enqueue('P'); $script:answers.Enqueue('DELETE FILES'); $script:keys.Enqueue('Enter')
    Invoke-SelectionCleanup $refreshUI
    Assert (-not (Test-Path -LiteralPath $refreshFile) -and $refreshUI.Selected.Count -eq 0) 'Cleanup refresh drops removed selections'
    Assert ($refreshFile -notin $refreshUI.Items.Path -and $claudeFile -in $refreshUI.Items.Path) 'Refresh measures remaining inventory without deleting unselected history'
    function Get-TerminalSize { return [pscustomobject]@{Width=80;Height=24} }
    $script:screen.Clear()
    $script:keys.Enqueue('Escape')
    [void](Invoke-ProjectPicker $ui)
    Assert (@($script:screen | Where-Object Length -ge 80).Count -eq 0 -and $script:screen.Count -lt 24) 'Project picker fits an 80x24 terminal with controls visible'
    Assert (($script:screen -join "`n") -match 'Enter review cleanup' -and ($script:screen -join "`n") -match 'Esc quit') 'Narrow terminal keeps review and exit controls visible'
    $longLabel = 'D:\ACollectionOfDevelopedSystems\ActiveDevelopment\a-very-long-project-name'
    $shortLabel = Format-ProjectLabel $longLabel 50
    Assert ($shortLabel.Length -eq 50 -and $shortLabel.EndsWith('a-very-long-project-name')) 'Clipped paths retain the identifying project name'
    Write-ScreenLine ("unsafe" + [char]27 + '[2J' + "`ntext")
    Assert ($script:screen[-1] -notmatch '[\x00-\x1f]') 'Menu metadata cannot inject terminal control characters'

    # Command dispatch uses fixture inventory, never the live provider directories.
    $script:scanRequests = @()
    $script:capturedSession = $null
    $script:scanItems = @($all) + @($sameProject)
    function Get-ScanInventory {
        param($Context, [bool]$Advanced, [string]$ProjectPath = '')
        $script:scanRequests += [pscustomobject]@{Advanced=$Advanced;ProjectPath=$ProjectPath}
        return $script:scanItems
    }
    function Invoke-ProjectPicker { param($Session) $script:capturedSession = $Session; return 'Back' }
    function Invoke-InventoryUI { param($Session) $script:capturedSession = $Session; return 'Back' }
    Invoke-AgentPurge @('clean', '--all')
    Assert ($script:capturedSession.Selected.Count -eq 3 -and -not $script:capturedSession.Advanced) 'Clean-all preselects only eligible items in standard mode'
    Invoke-AgentPurge @('clean', '--all', '--advanced')
    Assert ($script:capturedSession.Advanced -and $script:scanRequests[-1].Advanced) 'Advanced clean-all is explicitly passed to the scanner'
    Invoke-AgentPurge @('clean')
    Assert ($script:capturedSession.Selected.Count -eq 0) 'Clean starts with no selected projects'
    Invoke-AgentPurge @('clean', '--project', $project)
    Assert ($script:capturedSession.ProjectPath -eq $project -and $script:scanRequests[-1].ProjectPath -eq $project) 'Project cleanup preserves its scan scope for refresh'
    Invoke-AgentPurge @('scan', '--global')
    Assert ($script:capturedSession.Selected.Count -eq 0) 'Scan never preselects items'
    $requestCount = $script:scanRequests.Count
    foreach ($invalid in @(@('clean', '--all', '--yes'), @('clean', '--project'), @('clean', '--all', '--project', $project), @('scan'), @('scan', '--global', '--wrong'))) {
        $rejected = $false
        try { Invoke-AgentPurge $invalid } catch { $rejected = $true }
        Assert $rejected ('Reject unsupported or conflicting arguments: ' + ($invalid -join ' '))
    }
    Assert ($script:scanRequests.Count -eq $requestCount) 'Invalid commands fail before scanning'
    foreach ($key in @('Enter', 'Escape')) { $script:keys.Enqueue($key) }
    Invoke-AgentPurge @()
    Assert ($script:keys.Count -eq 0) 'Back from selection returns to the home menu'
    function Test-InteractiveTerminal { return $false }
    $script:capturedSession = $null
    $readOnly = (Invoke-AgentPurge @('clean', '--all')) -join "`n"
    Assert ($null -eq $script:capturedSession -and $readOnly -match 'Read-only inventory' -and $readOnly -match 'By project' -and $readOnly -match 'incomplete') 'Redirected clean-all only prints inventory including incomplete-size context'
    Assert ($script:deletedIds.Count -eq 1 -and (Test-Path -LiteralPath $claudeFile)) 'UI and command tests never delete provider sessions'
    Write-Output 'PASS: fixtures, sizes, project selection, keyboard flows, cleanup/back safety, command dispatch, both file methods, install/update/uninstall.'
} finally {
    $full = Get-FullPath $fixture
    $tempRoot = Get-FullPath $env:TEMP
    if ((Test-Within $full $tempRoot) -and $full -ne $tempRoot -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force }
}
