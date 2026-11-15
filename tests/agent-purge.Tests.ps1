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
    $ctx = New-AgentPurgeContext -CodexRoot $codexRoot -ClaudeRoot $claudeRoot -CodexPackages $packages -ClaudeVersions $versions -ClaudeBinary (Join-Path $fixture 'claude.exe') -CodexBinary (Join-Path $fixture 'codex.exe') -ConfigPath (Join-Path $fixture 'settings\config.json')
    Assert ((Get-AgentPurgeConfig $ctx).RetentionDays -eq 30 -and -not (Test-Path $ctx.ConfigPath)) 'Default retention is read without creating a config file'
    Set-AgentPurgeRetention $ctx 45
    Assert ((Get-AgentPurgeConfig $ctx).RetentionDays -eq 45) 'Retention setting persists in fixture config'
    $invalidRetention = $false
    try { Set-AgentPurgeRetention $ctx 0 } catch { $invalidRetention = $true }
    Assert $invalidRetention 'Retention rejects zero days'
    Set-Content -LiteralPath $ctx.ConfigPath -Value '{"retentionDays":"30"}'
    $invalidConfig = $false
    try { [void](Get-AgentPurgeConfig $ctx) } catch { $invalidConfig = $true }
    Assert $invalidConfig 'Invalid saved config is rejected instead of using an unsafe retention'
    Set-AgentPurgeRetention $ctx 45
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
    $manyRows = @(1..40)
    $state = Update-NavState $state 'Home' $manyRows
    $state = Update-NavState $state 'PageDown' $manyRows
    Assert ($state.Index -eq (Get-PageSize 11)) 'Inspector PageDown moves one visible screen'
    $state = Update-NavState $state 'End' $manyRows
    Assert ($state.Index -eq 39) 'Inspector End moves to the last row'
    $state = Update-NavState $state 'PageUp' $manyRows
    Assert ($state.Index -eq (39 - (Get-PageSize 11))) 'Inspector PageUp moves one visible screen'
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
    $script:keys = New-Object 'System.Collections.Generic.Queue[string]'
    $script:deletedIds = @()
    function Read-Host { param([string]$Prompt) return $script:answers.Dequeue() }
    function Read-MenuKey { if (-not $script:keys.Count) { throw 'Unexpected cleanup key prompt' }; return $script:keys.Dequeue() }
    function Test-AppClosed { param([string]$Provider) return $true }
    function Invoke-CodexDeletion { param([string]$Id) $script:deletedIds += $Id }
    foreach ($key in @('Enter', 'Enter', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-Cleanup @($confirmLog) $ctx | Out-Null
    Assert ((Test-Path $confirmFile) -and $script:keys.Count -eq 0) 'Enter on the default file confirmation cancels cleanup'
    foreach ($key in @('Enter', 'DownArrow', 'DownArrow', 'Enter', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-Cleanup @($confirmLog) $ctx | Out-Null
    Assert ((Test-Path $confirmFile) -and $script:keys.Count -eq 0) 'Permanent file warning defaults to cancel'
    foreach ($reviewKeys in @(
        @('B'),
        @('Enter', 'B'),
        @('Enter', 'DownArrow', 'DownArrow', 'Enter', 'DownArrow', 'Spacebar', 'B'),
        @('Enter', 'DownArrow', 'DownArrow', 'Enter', 'DownArrow', 'Spacebar', 'DownArrow', 'Enter', 'B')
    )) {
        foreach ($key in $reviewKeys) { $script:keys.Enqueue($key) }
        Invoke-Cleanup @($confirmLog, ($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
        Assert ((Test-Path $confirmFile) -and $script:deletedIds.Count -eq 0) 'Back at any review prompt must leave both batches intact'
        Assert ($script:keys.Count -eq 0) 'Back consumes only the current review keys'
    }
    foreach ($key in @('Enter', 'DownArrow', 'DownArrow', 'DownArrow', 'Enter', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-Cleanup @($confirmLog, ($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
    Assert ((Test-Path $confirmFile) -and $script:deletedIds.Count -eq 0) 'Cancellation leaves both batches intact'
    foreach ($key in @('Enter', 'DownArrow', 'DownArrow', 'Enter', 'DownArrow', 'Spacebar', 'DownArrow', 'Enter', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-Cleanup @($confirmLog, ($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
    Assert (-not (Test-Path $confirmFile)) 'Confirmed file batch removed'
    Assert ($script:deletedIds.Count -eq 0) 'File confirmation does not authorize Codex'
    foreach ($key in @('Enter', 'DownArrow', 'Spacebar', 'DownArrow', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-Cleanup @(($matched | Where-Object Id -eq $cid)) $ctx | Out-Null
    Assert ($script:deletedIds.Count -eq 1 -and $script:deletedIds[0] -eq $cid) 'Separate Codex confirmation'
    $undoFile = Join-Path $claudeRoot 'debug\undo.txt'
    $undoContent = 'undo content' * 12000
    [IO.File]::WriteAllText($undoFile, $undoContent)
    $undoCache = Join-Path $claudeRoot 'cache\undo-folder'
    New-Item -ItemType Directory -Path $undoCache | Out-Null
    [IO.File]::WriteAllText((Join-Path $undoCache 'child.txt'), ('cache content' * 12000))
    $undoLogItem = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $undoFile '' '' '' '' '' '' $true
    $undoCacheItem = New-InventoryItem $ctx 'Claude' 'Caches' 'Cache' $undoCache '' '' '' '' '' '' $true
    foreach ($key in @('Enter', 'Enter', 'DownArrow', 'Enter')) { $script:keys.Enqueue($key) }
    $undoOutput = @(Invoke-Cleanup @($undoLogItem, $undoCacheItem) $ctx $true 6>&1)
    $undoRoot = Join-Path $fixture '.agent-purge-undo'
    $manifestFile = @(Get-ChildItem -LiteralPath (Join-Path $undoRoot 'runs') -Filter '*.json')[0].FullName
    $run = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    Assert (-not (Test-Path $undoFile) -and -not (Test-Path $undoCache) -and $run.Entries.Count -eq 2) 'Undo run archives selected file and directory only'
    if (([IO.DriveInfo]::new([IO.Path]::GetPathRoot($undoFile))).DriveFormat -eq 'NTFS' -and (Get-Command compact.exe -ErrorAction SilentlyContinue)) {
        Assert (((Get-Item -LiteralPath $run.Entries[0].Archived -Force).Attributes -band [IO.FileAttributes]::Compressed) -ne 0) 'Undo file uses NTFS compression'
        Assert (((Get-Item -LiteralPath (Join-Path $run.Entries[1].Archived 'child.txt') -Force).Attributes -band [IO.FileAttributes]::Compressed) -ne 0) 'Undo directory contents use NTFS compression'
    }
    Assert (($undoOutput -join "`n") -match 'Undo folder:' -and ($undoOutput -join "`n") -match "This run's stored files:") 'Cleanup shows the undo location'
    Assert ($run.ExpiresAtUtc -and ([datetime]$run.ExpiresAtUtc - [datetime]$run.CreatedAtUtc).Days -eq 45) 'New run captures configured retention deadline'
    Assert ($script:keys.Count -eq 0 -and $run.Hash -eq (Get-UndoHash $run)) 'Keyboard confirmation creates a matching undo manifest'
    $badHashRejected = $false
    try { Invoke-UndoRestore $ctx $run.RunId ('0' * 64) | Out-Null } catch { $badHashRejected = $true }
    Assert $badHashRejected 'Incorrect restore hash is rejected before moving files'
    $tampered = Get-Content -LiteralPath $manifestFile -Raw
    $changed = $tampered.Replace('undo.txt', 'other.txt')
    Set-Content -LiteralPath $manifestFile -Value $changed
    $tamperedRejected = $false
    try { Invoke-UndoRestore $ctx $run.RunId $run.Hash | Out-Null } catch { $tamperedRejected = $true }
    Assert $tamperedRejected 'Changed undo manifest is rejected before moving files'
    [IO.File]::WriteAllText($manifestFile, $tampered, [Text.Encoding]::UTF8)
    Set-Content -LiteralPath $undoFile -Value 'new data'
    Invoke-UndoRestore $ctx $run.RunId $run.Hash | Out-Null
    Assert ((Get-Content $undoFile -Raw) -match 'new data' -and (Test-Path $undoCache)) 'Restore does not overwrite an occupied original path and continues other entries'
    Remove-Item -LiteralPath $undoFile -Force
    Invoke-UndoRestore $ctx $run.RunId $run.Hash | Out-Null
    Assert ((Get-Content $undoFile -Raw) -eq $undoContent -and (Get-Content (Join-Path $undoCache 'child.txt') -Raw) -eq ('cache content' * 12000)) 'Restore recovers compressed file and directory contents'
    $recycleConfirmFile = Join-Path $claudeRoot 'debug\recycle-confirm.txt'
    Set-Content -LiteralPath $recycleConfirmFile -Value 'recycle content'
    $recycleConfirmItem = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $recycleConfirmFile '' '' '' '' '' '' $true
    foreach ($key in @('Enter', 'Enter', 'DownArrow', 'DownArrow', 'Enter', 'DownArrow', 'Enter', 'DownArrow', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-Cleanup @($recycleConfirmItem) $ctx | Out-Null
    Assert (-not (Test-Path $recycleConfirmFile)) 'File method changes without restarting review and Recycle Bin uses keyboard confirmation'
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
        $script:updateSource = $updatedSource
        $script:updateRequests = 0
        function Invoke-WebRequest {
            param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, [int]$TimeoutSec, $ErrorAction)
            $script:updateRequests++
            if ($script:updateSource -eq 'offline') { throw 'Network unavailable' }
            Copy-Item -LiteralPath $script:updateSource -Destination $OutFile
        }
        Assert (-not (Update-AgentPurge -InstallRoot $installRoot -PathScope Process)) 'Matching published script needs no update'
        $remoteUpdate = Join-Path $fixture 'remote-agent-purge.ps1'
        Set-Content -LiteralPath $remoteUpdate -Value '# newer fixture'
        $script:updateSource = $remoteUpdate
        Assert (Update-AgentPurge -InstallRoot $installRoot -PathScope Process) 'Explicit update installs published script'
        $installedHash = (Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash
        $markerHash = (Get-Content -LiteralPath (Join-Path $installRoot 'install.json') -Raw | ConvertFrom-Json).scriptHash
        Assert ($installedHash -eq $markerHash -and $installedHash -eq (Get-FileHash -LiteralPath $remoteUpdate -Algorithm SHA256).Hash) 'Update refreshes script and install marker'
        Assert (-not (Update-AgentPurge -InstallRoot $installRoot -PathScope Process)) 'Explicit update reports already current'
        $directUpdate = Join-Path $fixture 'direct-agent-purge.ps1'
        Set-Content -LiteralPath $directUpdate -Value '# direct update fixture'
        $script:updateSource = $directUpdate
        function Test-InteractiveTerminal { return $false }
        Assert (Update-AgentPurge -InstallRoot $installRoot -PathScope Process) 'Explicit update works without an interactive terminal'
        $installedHash = (Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash
        $markerHash = (Get-Content -LiteralPath (Join-Path $installRoot 'install.json') -Raw | ConvertFrom-Json).scriptHash
        Assert ($installedHash -eq $markerHash -and $installedHash -eq (Get-FileHash -LiteralPath $directUpdate -Algorithm SHA256).Hash) 'Explicit update refreshes script and marker'
        $invalidUpdate = Join-Path $fixture 'invalid-agent-purge.ps1'
        Set-Content -LiteralPath $invalidUpdate -Value '{'
        $script:updateSource = $invalidUpdate
        $rejected = $false
        try { [void](Update-AgentPurge -InstallRoot $installRoot -PathScope Process) } catch { $rejected = $true }
        Assert ($rejected -and (Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash -eq $installedHash) 'Explicit update rejects invalid script without changing installation'
        $script:updateSource = 'offline'
        $rejected = $false
        try { [void](Update-AgentPurge -InstallRoot $installRoot -PathScope Process) } catch { $rejected = $true }
        Assert ($rejected -and (Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash -eq $installedHash) 'Explicit update reports download failure without changing installation'
        $requests = $script:updateRequests
        Add-Content -LiteralPath $installedScript -Value '# local edit'
        $rejected = $false
        try { [void](Update-AgentPurge -InstallRoot $installRoot -PathScope Process) } catch { $rejected = $true }
        Assert ($rejected -and $script:updateRequests -eq $requests) 'Explicit update refuses changed installed script before download'
        Copy-Item -LiteralPath $directUpdate -Destination $installedScript -Force
        $script:AgentPurgeScript = $originalSource
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
    foreach ($key in @('Spacebar', 'I', 'Enter', 'Enter', 'Enter', 'B', 'B', 'B', 'B', 'Enter', 'B', 'B')) { $script:keys.Enqueue($key) }
    # The largest fixture project has a Codex session; leave its review and return.
    Assert ((Invoke-ProjectPicker $ui) -eq 'Back') 'Project picker supports inspect, nested back, review, and back to home'
    Assert ($ui.Selected.Count -eq 1) 'Selection persists through nested inspector and cancelled review'
    Assert ($script:screen -match 'Which projects' -and $script:screen -match 'Selected:' -and $script:screen -match '100%') 'Picker shows context, selected size, and distributions'
    Assert ($script:keys.Count -eq 0 -and $script:answers.Count -eq 0) 'Menu flow consumes the expected input only'
    foreach ($key in @('LeftArrow', 'DownArrow', 'UpArrow', 'Escape')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $ui) -eq 'Exit' -and $script:keys.Count -eq 0) 'Picker arrows stay in selection until Escape'
    $jumpUI = [pscustomobject]@{Items=$all;Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    $orderedGroups = @(Get-ProjectGroups $all)
    foreach ($key in @('End', 'Spacebar', 'Home', 'Spacebar', 'B')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $jumpUI) -eq 'Back') 'Home and End navigate the project checklist'
    foreach ($item in @($orderedGroups[0].Items) + @($orderedGroups[-1].Items)) {
        if ($item.Eligible) { Assert ($jumpUI.Selected.ContainsKey($item.Key)) 'Home and End select the intended projects' }
    }
    foreach ($key in @('PageDown', 'PageUp', 'B')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $jumpUI) -eq 'Back' -and $script:keys.Count -eq 0) 'Page keys move through the project checklist'
    $findUI = [pscustomobject]@{Items=$all;Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    $script:answers.Enqueue($orderedGroups[-1].Label)
    foreach ($key in @('F', 'Spacebar', 'B')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $findUI) -eq 'Back' -and $script:answers.Count -eq 0) 'Project search consumes a path query'
    foreach ($item in $orderedGroups[-1].Items) {
        if ($item.Eligible) { Assert ($findUI.Selected.ContainsKey($item.Key)) 'Project search focuses the matching project' }
    }
    foreach ($key in @('A', 'Escape')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $ui) -eq 'Exit') 'Escape exits the picker'
    Assert ($ui.Selected.Count -eq 3) 'A selects all eligible projects from partial selection'
    $emptyUI = [pscustomobject]@{Items=@();Selected=@{};Context=$ctx;Advanced=$false;ProjectPath=''}
    foreach ($key in @('Enter', 'A', 'Spacebar', 'B')) { $script:keys.Enqueue($key) }
    Assert ((Invoke-ProjectPicker $emptyUI) -eq 'Back') 'Empty inventory remains navigable without cleanup'
    Assert ($script:screen -match 'Nothing selected') 'Enter with no selection explains how to proceed'
    foreach ($key in @('DownArrow', 'Enter')) { $script:keys.Enqueue($key) }
    Assert (((Show-StartMenu) -join ' ') -eq 'scan --global') 'Home menu arrow navigation chooses inspection'
    foreach ($key in @('DownArrow', 'DownArrow', 'DownArrow', 'DownArrow', 'Enter')) { $script:keys.Enqueue($key) }
    Assert (((Show-StartMenu) -join ' ') -eq 'settings') 'Home menu opens settings with arrow keys'
    foreach ($key in @('UpArrow', 'Spacebar')) { $script:keys.Enqueue($key) }
    Assert ((Show-SettingsMenu $ctx) -eq 'Back' -and (Get-AgentPurgeConfig $ctx).RetentionDays -eq 46) 'Keyboard settings save the adjusted retention'
    foreach ($key in @('DownArrow', 'B')) { $script:keys.Enqueue($key) }
    Assert ((Show-SettingsMenu $ctx) -eq 'Back' -and (Get-AgentPurgeConfig $ctx).RetentionDays -eq 46) 'Back leaves settings unchanged'
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
    foreach ($key in @('Enter', 'DownArrow', 'DownArrow', 'Enter', 'DownArrow', 'Spacebar', 'DownArrow', 'Enter', 'Enter')) { $script:keys.Enqueue($key) }
    Invoke-SelectionCleanup $refreshUI
    Assert (-not (Test-Path -LiteralPath $refreshFile) -and $refreshUI.Selected.Count -eq 0) 'Cleanup refresh drops removed selections'
    Assert ($refreshFile -notin $refreshUI.Items.Path -and $claudeFile -in $refreshUI.Items.Path) 'Refresh measures remaining inventory without deleting unselected history'
    function Get-TerminalSize { return [pscustomobject]@{Width=80;Height=24} }
    $script:screen.Clear()
    $script:keys.Enqueue('Escape')
    [void](Invoke-ProjectPicker $ui)
    Assert (@($script:screen | Where-Object Length -ge 80).Count -eq 0 -and $script:screen.Count -lt 24) 'Project picker fits an 80x24 terminal with controls visible'
    Assert (($script:screen -join "`n") -match 'Enter review cleanup' -and ($script:screen -join "`n") -match 'Esc/Ctrl\+C twice quit') 'Narrow terminal keeps review and exit controls visible'
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
    function New-AgentPurgeContext { return $ctx }
    function Invoke-ProjectPicker { param($Session) $script:capturedSession = $Session; return 'Back' }
    function Invoke-InventoryUI { param($Session) $script:capturedSession = $Session; return 'Back' }
    $script:homeMenuCount = 0
    function Show-StartMenu { $script:homeMenuCount++; return @() }
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
    Assert ($script:homeMenuCount -eq 5) 'Back from direct commands returns to home instead of quitting'
    $script:explicitUpdateRequests = 0
    function Update-AgentPurge { $script:explicitUpdateRequests++ }
    Invoke-AgentPurge @('update')
    Assert ($script:explicitUpdateRequests -eq 1) 'Update command dispatches without scanning or a terminal'
    $requestCount = $script:scanRequests.Count
    foreach ($invalid in @(@('clean', '--all', '--yes'), @('clean', '--project'), @('clean', '--all', '--project', $project), @('scan'), @('scan', '--global', '--wrong'))) {
        $rejected = $false
        try { Invoke-AgentPurge $invalid } catch { $rejected = $true }
        Assert $rejected ('Reject unsupported or conflicting arguments: ' + ($invalid -join ' '))
    }
    Assert ($script:scanRequests.Count -eq $requestCount) 'Invalid commands fail before scanning'
    Invoke-AgentPurge @('restore', $run.RunId, $run.Hash) | Out-Null
    Assert ((Test-Path $undoFile) -and (Test-Path $undoCache)) 'Restore command dispatch accepts a completed fixture run'
    Assert (((Invoke-AgentPurge @('settings', 'show')) -join ' ') -match '46 days') 'Settings show command reads the saved value'
    Invoke-AgentPurge @('settings', 'set', 'retention-days', '14') | Out-Null
    Assert ((Get-AgentPurgeConfig $ctx).RetentionDays -eq 14 -and ([datetime]$run.ExpiresAtUtc - [datetime]$run.CreatedAtUtc).Days -eq 45) 'CLI setting changes future runs without altering an existing deadline'
    $invalidSettingCommand = $false
    try { Invoke-AgentPurge @('settings', 'set', 'retention-days', 'many') | Out-Null } catch { $invalidSettingCommand = $true }
    Assert ($invalidSettingCommand -and (Get-AgentPurgeConfig $ctx).RetentionDays -eq 14) 'Settings command rejects nonnumeric retention without changing the file'
    Invoke-AgentPurge @()
    Assert ($script:homeMenuCount -eq 6 -and $script:updateRequests -eq $requests) 'Opening the home menu does not contact GitHub'
    function Test-InteractiveTerminal { return $false }
    $script:capturedSession = $null
    $readOnly = (Invoke-AgentPurge @('clean', '--all')) -join "`n"
    Assert ($null -eq $script:capturedSession -and $readOnly -match 'Read-only inventory' -and $readOnly -match 'By project' -and $readOnly -match 'incomplete') 'Redirected clean-all only prints inventory including incomplete-size context'
    Assert ($script:deletedIds.Count -eq 1 -and (Test-Path -LiteralPath $claudeFile)) 'UI and command tests never delete provider sessions'
    $expiryFile = Join-Path $claudeRoot 'debug\expire.txt'
    Set-Content -LiteralPath $expiryFile -Value 'expires'
    $expiryItem = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $expiryFile '' '' '' '' '' '' $true
    $expiryRun = New-UndoRun @($expiryItem) $ctx
    Invoke-UndoMove $expiryFile $expiryRun.Entries[0].Archived
    $expiryRun.ExpiresAtUtc = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')
    $expiryRun.Hash = Get-UndoHash $expiryRun
    $expiryManifest = Join-Path (Join-Path $undoRoot 'runs') ($expiryRun.RunId + '.json')
    [IO.File]::WriteAllText($expiryManifest, ($expiryRun | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    $script:recycled = New-Object 'System.Collections.Generic.List[string]'
    $script:failRecycle = $true
    function Invoke-FileRemoval {
        param([string]$Path, [string]$Method)
        Assert ($Method -eq 'Recycle Bin' -and (Split-Path -Leaf $Path) -match '^agent-purge-.+-[0-9A-F]{12}$') 'Expiry sends a named run folder to Recycle Bin'
        if ($script:failRecycle) { $script:failRecycle = $false; throw 'Simulated Recycle Bin failure' }
        $target = Join-Path (Join-Path $fixture 'recycled') (Split-Path -Leaf $Path)
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.Directory]::Move($Path, $target)
        $script:recycled.Add($target)
    }
    [void](Invoke-ExpiredUndoRuns $ctx)
    $named = Join-Path (Join-Path $undoRoot 'expired') ('agent-purge-' + $expiryRun.RunId + '-' + $expiryRun.Hash.Substring(0, 12))
    Assert ((Test-Path $named) -and $script:recycled.Count -eq 0) 'Failed Recycle Bin move retains the named undo folder for retry'
    [void](Invoke-ExpiredUndoRuns $ctx)
    Assert ($script:recycled.Count -eq 1 -and -not (Test-Path $named) -and (Test-Path (Join-Path $script:recycled[0] 'agent-purge-manifest.json'))) 'Expiry retries and recycles one folder with its manifest'
    $expiredRestoreRejected = $false
    try { Invoke-UndoRestore $ctx $expiryRun.RunId $expiryRun.Hash | Out-Null } catch { $expiredRestoreRejected = $true }
    Assert ($expiredRestoreRejected -and -not (Test-Path $expiryFile)) 'Expired restore command refuses the run'
    $legacyFile = Join-Path $claudeRoot 'debug\legacy.txt'
    Set-Content -LiteralPath $legacyFile -Value 'legacy'
    $legacyItem = New-InventoryItem $ctx 'Claude' 'Logs' 'Log' $legacyFile '' '' '' '' '' '' $true
    $legacyRun = New-UndoRun @($legacyItem) $ctx
    Invoke-UndoMove $legacyFile $legacyRun.Entries[0].Archived
    $legacyRun.PSObject.Properties.Remove('CreatedAtUtc'); $legacyRun.PSObject.Properties.Remove('ExpiresAtUtc')
    $legacyRun.Hash = Get-UndoHash $legacyRun
    $legacyManifest = Join-Path (Join-Path $undoRoot 'runs') ($legacyRun.RunId + '.json')
    [IO.File]::WriteAllText($legacyManifest, ($legacyRun | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    [void](Invoke-ExpiredUndoRuns $ctx ([datetimeoffset]::UtcNow.AddYears(2)))
    Assert ($script:recycled.Count -eq 1 -and (Test-Path $legacyRun.Entries[0].Archived)) 'Legacy runs without a deadline are not expired'
    Invoke-UndoRestore $ctx $legacyRun.RunId $legacyRun.Hash | Out-Null
    Assert (Test-Path $legacyFile) 'Legacy run remains restorable'
    $multiCtx = $ctx.PSObject.Copy()
    $multiCtx.ClaudeVersions = Join-Path $fixture 'version-area\versions'
    New-Item -ItemType Directory -Path $multiCtx.ClaudeVersions -Force | Out-Null
    $multiLog = Join-Path $claudeRoot 'debug\multi.txt'
    $multiRuntime = Join-Path $multiCtx.ClaudeVersions '1.9.0'
    Set-Content -LiteralPath $multiLog -Value 'log'
    Set-Content -LiteralPath $multiRuntime -Value 'runtime'
    $multiItems = @(
        (New-InventoryItem $multiCtx 'Claude' 'Logs' 'Log' $multiLog '' '' '' '' '' '' $true),
        (New-InventoryItem $multiCtx 'Claude' 'Runtimes' 'ClaudeRuntime' $multiRuntime '' '' '' '' '' '' $true)
    )
    $multiRun = New-UndoRun $multiItems $multiCtx
    foreach ($entry in $multiRun.Entries) { Invoke-UndoMove $entry.Original $entry.Archived }
    $multiRun.ExpiresAtUtc = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')
    $multiRun.Hash = Get-UndoHash $multiRun
    $multiManifest = Join-Path (Join-Path $undoRoot 'runs') ($multiRun.RunId + '.json')
    [IO.File]::WriteAllText($multiManifest, ($multiRun | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    [void](Invoke-ExpiredUndoRuns $multiCtx)
    $bundleFiles = @(Get-ChildItem -LiteralPath $script:recycled[-1] -Recurse -File | Where-Object { $_.Name -in @('0', '1') })
    Assert ($script:recycled.Count -eq 2 -and $bundleFiles.Count -eq 2) 'One Recycle Bin folder combines same-volume payloads from two undo locations'
    $script:expiryChecks = 0
    function Invoke-ExpiredUndoRuns { param($Context) $script:expiryChecks++ }
    function Test-InteractiveTerminal { return $true }
    Invoke-AgentPurge @()
    Assert ($script:expiryChecks -eq 1) 'Interactive launch checks expired runs once before the menu'
    Invoke-AgentPurge @('settings', 'show') | Out-Null
    Assert ($script:expiryChecks -eq 1) 'Read-only settings command does not run expiry cleanup'
    function Invoke-ExpiredUndoRuns { param($Context) return [pscustomobject]@{ Moved = 1; Skipped = 0 } }
    $script:keys.Enqueue('Enter')
    Assert ((Show-ExpiryCheck $ctx) -eq 'Continue' -and $script:keys.Count -eq 0 -and $script:screen -match 'Undo expiry: 1 folder') 'Expiry result stays visible until acknowledged before the menu redraws'
    Write-Output 'PASS: fixtures, keyboard cleanup, retention settings, per-volume expiry and retry, legacy undo, restore, command dispatch, install/update/uninstall.'
} finally {
    $full = Get-FullPath $fixture
    $tempRoot = Get-FullPath $env:TEMP
    if ((Test-Within $full $tempRoot) -and $full -ne $tempRoot -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force }
}
