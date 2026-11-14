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
    Assert ($state.Level -eq 0) 'Back navigation'
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
    try {
        Install-AgentPurge -InstallRoot $installRoot -PathScope Process | Out-Null
        Assert ((Test-Path (Join-Path $installRoot 'agent-purge.cmd')) -and ([Environment]::GetEnvironmentVariable('Path', 'Process') -match [regex]::Escape($installRoot))) 'Install files/PATH'
        Uninstall-AgentPurge -InstallRoot $installRoot -PathScope Process | Out-Null
        Assert (-not (Test-Path $installRoot)) 'Uninstall files'
        Assert (-not ([Environment]::GetEnvironmentVariable('Path', 'Process') -match [regex]::Escape($installRoot))) 'Uninstall PATH'
    } finally { [Environment]::SetEnvironmentVariable('Path', $oldPath, 'Process') }
    Write-Host 'PASS: fixtures, navigation, safety, both file methods, install/uninstall.'
} finally {
    $full = Get-FullPath $fixture
    $tempRoot = Get-FullPath $env:TEMP
    if ((Test-Within $full $tempRoot) -and $full -ne $tempRoot -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force }
}
