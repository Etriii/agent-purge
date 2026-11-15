# Windows PowerShell 5.1 compatible. Dot-source this file to exercise its functions with fixtures.
$script:AgentPurgeScript = $PSCommandPath

function Get-FullPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd([char]'\', [char]'/')
}

function Test-Within([string]$Path, [string]$Root) {
    $pathFull = Get-FullPath $Path
    $rootFull = Get-FullPath $Root
    $prefix = if ($rootFull.EndsWith('\')) { $rootFull } else { $rootFull + '\' }
    return $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function New-AgentPurgeContext {
    param(
        [string]$CodexRoot = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
        [string]$ClaudeRoot = (Join-Path $env:USERPROFILE '.claude'),
        [string]$CodexPackages = '',
        [string]$ClaudeVersions = (Join-Path $env:USERPROFILE '.local\share\claude\versions'),
        [string]$ClaudeBinary = (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        [string]$CodexBinary = (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe')
    )
    if (-not $CodexPackages) { $CodexPackages = Join-Path $CodexRoot 'packages' }
    return [pscustomobject]@{
        CodexRoot = Get-FullPath $CodexRoot
        ClaudeRoot = Get-FullPath $ClaudeRoot
        CodexPackages = Get-FullPath $CodexPackages
        ClaudeVersions = Get-FullPath $ClaudeVersions
        ClaudeBinary = Get-FullPath $ClaudeBinary
        CodexBinary = Get-FullPath $CodexBinary
    }
}

function Get-PathSize([string]$Path) {
    [long]$total = 0
    $incomplete = $false
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        $next = $pending.Pop()
        try {
            $entry = Get-Item -LiteralPath $next -Force -ErrorAction Stop
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $incomplete = $true; continue }
            if (-not $entry.PSIsContainer) { $total += $entry.Length; continue }
            foreach ($child in (Get-ChildItem -LiteralPath $next -Force -ErrorAction Stop)) { $pending.Push($child.FullName) }
        } catch { $incomplete = $true }
    }
    return [pscustomobject]@{ Bytes = $total; Incomplete = $incomplete }
}

function Format-Title([string]$Title) {
    if (-not $Title) { return '' }
    $clean = ([regex]::Replace($Title, '[\x00-\x1f\x7f-\x9f]', ' ') -replace '\s+', ' ').Trim()
    if ($clean.Length -gt 100) { return $clean.Substring(0, 100) + '…' }
    return $clean
}

function Get-SessionHead([string]$Path, [string]$Provider, $KnownTitles = $null) {
    $result = [ordered]@{ Id = $null; Cwd = $null; Date = $null; Title = $null; TitleSource = $null }
    $reader = $null
    try {
        $reader = [IO.File]::OpenText($Path)
        for ($n = 0; $n -lt 300 -and -not $reader.EndOfStream; $n++) {
            $line = $reader.ReadLine()
            if ($Provider -eq 'Codex' -and $line -notmatch '"type":"session_meta"|"type":"user_message"|"role":"user"') { continue }
            if ($Provider -eq 'Claude' -and $line -notmatch '"type":"user"|"type":"summary"|"type":"system"') { continue }
            try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($Provider -eq 'Codex') {
                if ($row.type -eq 'session_meta') {
                    $result.Id = $row.payload.id
                    $result.Cwd = $row.payload.cwd
                    $result.Date = $row.payload.timestamp
                } elseif (-not $result.Title -and $row.type -eq 'event_msg' -and $row.payload.type -eq 'user_message') {
                    $result.Title = $row.payload.message
                    $result.TitleSource = 'derived from first prompt'
                } elseif (-not $result.Title -and $row.type -eq 'response_item' -and $row.payload.role -eq 'user') {
                    $texts = @($row.payload.content | Where-Object { $_.type -eq 'input_text' -and $_.text } | ForEach-Object { $_.text })
                    if ($texts.Count) { $result.Title = $texts[-1]; $result.TitleSource = 'derived from first prompt' }
                }
            } else {
                if (-not $result.Id -and $row.sessionId) { $result.Id = $row.sessionId }
                if (-not $result.Cwd -and $row.cwd) { $result.Cwd = $row.cwd }
                if (-not $result.Date -and $row.timestamp) { $result.Date = $row.timestamp }
                if (-not $result.Title -and $row.type -eq 'summary' -and $row.summary) {
                    $result.Title = $row.summary
                    $result.TitleSource = 'stored'
                } elseif (-not $result.Title -and $row.type -eq 'user' -and $row.message.content -is [string]) {
                    $result.Title = $row.message.content
                    $result.TitleSource = 'derived from first prompt'
                }
            }
            if ($Provider -eq 'Codex' -and $KnownTitles -and $result.Id -and $KnownTitles.ContainsKey($result.Id) -and $result.Cwd -and $result.Date) { break }
            if ($result.Id -and $result.Cwd -and $result.Date -and $result.Title) { break }
        }
    } catch { } finally { if ($reader) { $reader.Dispose() } }
    if ($result.Title) { $result.Title = Format-Title $result.Title }
    return [pscustomobject]$result
}

function Get-CodexTitles($Context) {
    $titles = @{}
    $db = Join-Path $Context.CodexRoot 'state_5.sqlite'
    $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python -or -not (Test-Path -LiteralPath $db)) { return $titles }
    $code = @'
import json, sqlite3, sys
try:
    db = sqlite3.connect('file:' + sys.argv[1].replace('\\', '/') + '?mode=ro', uri=True)
    for row in db.execute('select id, title from threads where title is not null and title != ""'):
        print(json.dumps(row, ensure_ascii=True))
    db.close()
except (sqlite3.Error, OSError):
    pass
'@
    try {
        foreach ($line in ($code | & $python.Source - $db 2>$null)) {
            try { $pair = $line | ConvertFrom-Json; if ($pair.Count -eq 2) { $titles[[string]$pair[0]] = [string]$pair[1] } } catch { }
        }
    } catch { }
    return $titles
}

function New-InventoryItem {
    param($Context, [string]$Provider, [string]$Category, [string]$Kind, [string]$Path,
        [string]$Project = '', [string]$Date = '', [string]$Title = '', [string]$TitleSource = '',
        [string]$Resume = '', [string]$Id = '', [bool]$Eligible = $false, [string]$Reason = '')
    $size = Get-PathSize $Path
    if ($Kind -eq 'ClaudeSession') {
        $sidecar = Join-Path (Split-Path -Parent $Path) $Id
        if (Test-Path -LiteralPath $sidecar) {
            $extra = Get-PathSize $sidecar
            $size.Bytes += $extra.Bytes
            $size.Incomplete = $size.Incomplete -or $extra.Incomplete
        }
    }
    if ($Eligible -and $size.Incomplete) {
        $Eligible = $false
        $Reason = 'Unreadable or reparse content'
    }
    return [pscustomobject]@{
        Key = (Get-FullPath $Path); Provider = $Provider; Project = $Project; Category = $Category
        Kind = $Kind; Path = $Path; Date = $Date; Bytes = $size.Bytes; Incomplete = $size.Incomplete
        Title = $Title; TitleSource = $TitleSource; Resume = $Resume; Id = $Id
        Eligible = $Eligible; Reason = $Reason
    }
}

function Test-ProjectMatch([string]$WorkingDirectory, [string]$ProjectPath) {
    if (-not $WorkingDirectory) { return $false }
    try { return Test-Within $WorkingDirectory $ProjectPath } catch { return $false }
}

function Get-SessionInventory($Context, [string]$ProjectPath = '') {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $titles = Get-CodexTitles $Context
    $codexSessions = Join-Path $Context.CodexRoot 'sessions'
    if (Test-Path -LiteralPath $codexSessions) {
        foreach ($f in (Get-ChildItem -LiteralPath $codexSessions -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
            if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $head = Get-SessionHead $f.FullName 'Codex' $titles
            if (-not $head.Id -or -not $head.Cwd -or $f.Name -notmatch [regex]::Escape($head.Id) + '\.jsonl$') {
                if (-not $ProjectPath) { $items.Add((New-InventoryItem $Context 'Codex' 'Sessions' 'Inspection' $f.FullName '' '' '' '' '' '' $false 'Session metadata unavailable')) }
                continue
            }
            if ($ProjectPath -and -not (Test-ProjectMatch $head.Cwd $ProjectPath)) { continue }
            $title = $head.Title
            $source = $head.TitleSource
            if ($titles.ContainsKey($head.Id)) { $title = Format-Title $titles[$head.Id]; $source = 'stored' }
            $items.Add((New-InventoryItem $Context 'Codex' 'Sessions' 'CodexSession' $f.FullName $head.Cwd $head.Date $title $source ('codex resume ' + $head.Id) $head.Id $true))
        }
    }
    $claudeProjects = Join-Path $Context.ClaudeRoot 'projects'
    if (Test-Path -LiteralPath $claudeProjects) {
        foreach ($dir in (Get-ChildItem -LiteralPath $claudeProjects -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                if ($f.BaseName -notmatch '^[0-9a-fA-F-]{36}$' -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                $head = Get-SessionHead $f.FullName 'Claude'
                if ($head.Id -ne $f.BaseName -or -not $head.Cwd) {
                    if (-not $ProjectPath) { $items.Add((New-InventoryItem $Context 'Claude' 'Sessions' 'Inspection' $f.FullName '' '' '' '' '' '' $false 'Session metadata unavailable')) }
                    continue
                }
                if ($ProjectPath -and -not (Test-ProjectMatch $head.Cwd $ProjectPath)) { continue }
                $items.Add((New-InventoryItem $Context 'Claude' 'Sessions' 'ClaudeSession' $f.FullName $head.Cwd $head.Date $head.Title $head.TitleSource ('claude --resume ' + $head.Id) $head.Id $true))
            }
        }
    }
    return $items.ToArray()
}

function Get-CurrentClaudeVersion($Context) {
    if ($Context.PSObject.Properties['CurrentClaudeVersion'] -and $Context.CurrentClaudeVersion) { return $Context.CurrentClaudeVersion }
    if (-not (Test-Path -LiteralPath $Context.ClaudeBinary)) { return '' }
    try {
        $output = & $Context.ClaudeBinary --version 2>$null | Select-Object -First 1
        if ($output -match '^([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    } catch { }
    return ''
}

function Get-CurrentCodexTarget($Context, [string]$Package) {
    $link = Join-Path (Join-Path $Context.CodexPackages $Package) 'current'
    try {
        $item = Get-Item -LiteralPath $link -Force -ErrorAction Stop
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.Target) { return '' }
        return Get-FullPath ([string]$item.Target[0])
    } catch { return '' }
}

function Test-CodexRuntimeActive($Context, [string]$Package, [string]$Path) {
    $current = Get-CurrentCodexTarget $Context $Package
    if (-not $current -or $current -eq (Get-FullPath $Path)) { return $true }
    $versionFile = Join-Path (Join-Path $Context.CodexPackages $Package) 'auto-update-version'
    if (-not (Test-Path -LiteralPath $versionFile)) { return $true }
    try { $version = (Get-Content -LiteralPath $versionFile -TotalCount 1 -ErrorAction Stop).Trim() } catch { return $true }
    return (Split-Path -Leaf $Path) -eq $version
}

function Get-GlobalInventory($Context, [bool]$Advanced = $false) {
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in (Get-SessionInventory $Context)) { $items.Add($item) }
    foreach ($spec in @(
        @('Codex', (Join-Path $Context.CodexRoot 'cache')),
        @('Claude', (Join-Path $Context.ClaudeRoot 'cache'))
    )) {
        $provider = $spec[0]; $root = $spec[1]
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($child in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            $items.Add((New-InventoryItem $Context $provider 'Caches' 'Cache' $child.FullName '' '' '' '' '' '' $Advanced $(if ($Advanced) { '' } else { 'Requires --advanced' })))
        }
    }
    $debug = Join-Path $Context.ClaudeRoot 'debug'
    if (Test-Path -LiteralPath $debug) {
        foreach ($f in (Get-ChildItem -LiteralPath $debug -File -Filter '*.txt' -ErrorAction SilentlyContinue)) {
            $items.Add((New-InventoryItem $Context 'Claude' 'Logs' 'Log' $f.FullName '' '' '' '' '' '' $true))
        }
    }
    $daemonLog = Join-Path $Context.ClaudeRoot 'daemon.log'
    if (Test-Path -LiteralPath $daemonLog) { $items.Add((New-InventoryItem $Context 'Claude' 'Logs' 'Log' $daemonLog '' '' '' '' '' '' $true)) }
    if (Test-Path -LiteralPath $Context.CodexRoot) {
        foreach ($f in (Get-ChildItem -LiteralPath $Context.CodexRoot -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '^sandbox\..+\.log$') { $items.Add((New-InventoryItem $Context 'Codex' 'Logs' 'Log' $f.FullName '' '' '' '' '' '' $true)) }
            elseif ($f.Name -match '^logs_\d+\.sqlite(?:-shm|-wal)?$') { $items.Add((New-InventoryItem $Context 'Codex' 'Logs' 'Inspection' $f.FullName '' '' '' '' '' '' $false 'Provider database; inspection only')) }
        }
    }
    $claudeVersion = Get-CurrentClaudeVersion $Context
    if (Test-Path -LiteralPath $Context.ClaudeVersions) {
        foreach ($f in (Get-ChildItem -LiteralPath $Context.ClaudeVersions -File -ErrorAction SilentlyContinue)) {
            $old = $claudeVersion -and $f.Name -match '^\d+\.\d+\.\d+$' -and $f.Name -ne $claudeVersion
            $items.Add((New-InventoryItem $Context 'Claude' 'Runtimes' 'ClaudeRuntime' $f.FullName '' '' '' '' '' '' ([bool]($Advanced -and $old)) $(if (-not $old) { 'Current or unverified version' } elseif (-not $Advanced) { 'Requires --advanced' } else { '' })))
        }
    }
    foreach ($package in @('standalone', 'app-server-daemon')) {
        $releaseRoot = Join-Path (Join-Path $Context.CodexPackages $package) 'releases'
        if (-not (Test-Path -LiteralPath $releaseRoot)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $releaseRoot -Directory -ErrorAction SilentlyContinue)) {
            $old = $dir.Name -match '^\d+\.\d+\.\d+-x86_64-pc-windows-msvc$' -and -not (Test-CodexRuntimeActive $Context $package $dir.FullName)
            $items.Add((New-InventoryItem $Context 'Codex' 'Runtimes' 'CodexRuntime' $dir.FullName '' '' '' '' '' '' ([bool]($Advanced -and $old)) $(if (-not $old) { 'Current or unverified version' } elseif (-not $Advanced) { 'Requires --advanced' } else { '' })))
        }
    }
    foreach ($spec in @(@('Codex', $Context.CodexRoot), @('Claude', $Context.ClaudeRoot))) {
        $provider = $spec[0]; $root = $spec[1]
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($child in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            $skip = if ($provider -eq 'Codex') { @('sessions', 'cache', 'packages') } else { @('projects', 'cache', 'debug', 'daemon.log') }
            if ($child.Name -in $skip -or ($provider -eq 'Codex' -and $child.Name -match '^(sandbox\..+\.log|logs_\d+\.sqlite(?:-shm|-wal)?)$')) { continue }
            $items.Add((New-InventoryItem $Context $provider 'Protected / other' 'Inspection' $child.FullName '' '' '' '' '' '' $false 'Inspection only'))
        }
    }
    foreach ($spec in @(@('Codex', $Context.CodexBinary), @('Claude', $Context.ClaudeBinary))) {
        if (Test-Path -LiteralPath $spec[1]) { $items.Add((New-InventoryItem $Context $spec[0] 'Current binaries' 'Inspection' $spec[1] '' '' '' '' '' '' $false 'Inspection only')) }
    }
    return $items.ToArray()
}

function Get-ItemPaths($Item) {
    $paths = @($Item.Path)
    if ($Item.Kind -eq 'ClaudeSession') {
        $sidecar = Join-Path (Split-Path -Parent $Item.Path) $Item.Id
        if (Test-Path -LiteralPath $sidecar) { $paths += $sidecar }
    }
    return $paths
}

function Test-NoReparse([string]$Path, [bool]$Deep = $false) {
    $full = Get-FullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length)
    $cursor = $root
    foreach ($part in ($relative -split '[\\/]')) {
        if (-not $part) { continue }
        $cursor = Join-Path $cursor $part
        try { $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop } catch { return $false }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    }
    if ($Deep) {
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($full)
        while ($pending.Count -gt 0) {
            $next = $pending.Pop()
            try {
                $entry = Get-Item -LiteralPath $next -Force -ErrorAction Stop
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                if ($entry.PSIsContainer) { foreach ($child in (Get-ChildItem -LiteralPath $next -Force -ErrorAction Stop)) { $pending.Push($child.FullName) } }
            } catch { return $false }
        }
    }
    return $true
}

function Test-SafeItem($Item, $Context, [bool]$Advanced = $false) {
    if (-not $Item.Eligible) { return 'Item is inspection only' }
    $path = Get-FullPath $Item.Path
    if (-not (Test-Path -LiteralPath $path)) { return 'Path no longer exists' }
    $parent = Split-Path -Parent $path
    switch ($Item.Kind) {
        'CodexSession' {
            if ((Get-Item -LiteralPath $path).PSIsContainer) { return 'Session is not a file' }
            $root = Join-Path $Context.CodexRoot 'sessions'
            if (-not (Test-Within $path $root) -or $Item.Id -notmatch '^[0-9a-fA-F-]{36}$' -or $path -notmatch ('rollout-.*-' + [regex]::Escape($Item.Id) + '\.jsonl$')) { return 'Unrecognized Codex session path' }
            $head = Get-SessionHead $path 'Codex'
            if ($head.Id -ne $Item.Id -or $head.Cwd -ne $Item.Project) { return 'Session metadata changed' }
        }
        'ClaudeSession' {
            if ((Get-Item -LiteralPath $path).PSIsContainer) { return 'Session is not a file' }
            $root = Join-Path $Context.ClaudeRoot 'projects'
            if (-not (Test-Within $parent $root) -or (Split-Path -Parent $parent) -ne $root -or $Item.Id -notmatch '^[0-9a-fA-F-]{36}$' -or (Split-Path -Leaf $path) -ne ($Item.Id + '.jsonl')) { return 'Unrecognized Claude session path' }
            $head = Get-SessionHead $path 'Claude'
            if ($head.Id -ne $Item.Id -or $head.Cwd -ne $Item.Project) { return 'Session metadata changed' }
            $sidecar = Join-Path $parent $Item.Id
            if ((Test-Path -LiteralPath $sidecar) -and -not (Test-Path -LiteralPath $sidecar -PathType Container)) { return 'Unrecognized session sidecar' }
        }
        'Log' {
            if ((Get-Item -LiteralPath $path).PSIsContainer) { return 'Log is not a file' }
            $debug = Join-Path $Context.ClaudeRoot 'debug'
            $claudeLog = $Item.Provider -eq 'Claude' -and (($parent -eq $debug -and $path -match '\.txt$') -or $path -eq (Join-Path $Context.ClaudeRoot 'daemon.log'))
            $codexLog = $Item.Provider -eq 'Codex' -and $parent -eq $Context.CodexRoot -and (Split-Path -Leaf $path) -match '^sandbox\..+\.log$'
            if (-not ($claudeLog -or $codexLog)) { return 'Unrecognized log path' }
        }
        'Cache' {
            if (-not $Advanced) { return 'Advanced mode required' }
            $roots = @((Join-Path $Context.CodexRoot 'cache'), (Join-Path $Context.ClaudeRoot 'cache'))
            if ($parent -notin $roots) { return 'Unrecognized cache path' }
        }
        'CodexRuntime' {
            if (-not (Get-Item -LiteralPath $path).PSIsContainer) { return 'Runtime is not a directory' }
            if (-not $Advanced) { return 'Advanced mode required' }
            $package = Split-Path -Leaf (Split-Path -Parent $parent)
            $expected = Join-Path (Join-Path $Context.CodexPackages $package) 'releases'
            if ($package -notin @('standalone', 'app-server-daemon') -or $parent -ne $expected -or (Split-Path -Leaf $path) -notmatch '^\d+\.\d+\.\d+-x86_64-pc-windows-msvc$') { return 'Unrecognized runtime path' }
            if (Test-CodexRuntimeActive $Context $package $path) { return 'Current or unverified runtime' }
        }
        'ClaudeRuntime' {
            if ((Get-Item -LiteralPath $path).PSIsContainer) { return 'Runtime is not a file' }
            if (-not $Advanced) { return 'Advanced mode required' }
            $current = Get-CurrentClaudeVersion $Context
            if ($parent -ne $Context.ClaudeVersions -or (Split-Path -Leaf $path) -notmatch '^\d+\.\d+\.\d+$' -or -not $current -or (Split-Path -Leaf $path) -eq $current) { return 'Current or unverified runtime' }
        }
        default { return 'Protected or unknown item' }
    }
    foreach ($part in (Get-ItemPaths $Item)) {
        if (-not (Test-NoReparse $part $true)) { return 'Reparse point or unreadable path' }
    }
    return ''
}

function Test-AppClosed([string]$Provider) {
    $names = if ($Provider -eq 'Codex') { @('codex', 'codex-code-mode-host') } else { @('claude', 'Claude Desktop') }
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($process.ProcessName -in $names) { return $false }
    }
    return $true
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    [double]$value = $Bytes
    foreach ($unit in @('KB', 'MB', 'GB', 'TB')) {
        $value /= 1024
        if ($value -lt 1024 -or $unit -eq 'TB') { return ('{0:0.#} {1}' -f $value, $unit) }
    }
}

function Get-InventorySummary($Items, $Selected = @{}) {
    $summary = [pscustomobject]@{ Count = 0; Bytes = [long]0; EligibleCount = 0; EligibleBytes = [long]0; SelectedCount = 0; SelectedBytes = [long]0; Incomplete = $false }
    foreach ($item in $Items) {
        $summary.Count++; $summary.Bytes += $item.Bytes
        $summary.Incomplete = $summary.Incomplete -or $item.Incomplete
        if ($item.Eligible) {
            $summary.EligibleCount++; $summary.EligibleBytes += $item.Bytes
            if ($Selected.ContainsKey($item.Key)) { $summary.SelectedCount++; $summary.SelectedBytes += $item.Bytes }
        }
    }
    return $summary
}

function Get-ProjectGroups($Items) {
    $groups = @{}
    foreach ($item in $Items) {
        $label = 'Shared provider storage (logs, caches, runtimes, other)'
        $key = 'shared'
        if ($item.Project) {
            try { $label = Get-FullPath $item.Project } catch { $label = $item.Project }
            $key = 'project:' + $label
        } elseif ($item.Category -eq 'Sessions') {
            $key = 'unknown'; $label = 'Sessions with unavailable project metadata'
        }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Key = $key; Label = $label; Items = (New-Object 'System.Collections.Generic.List[object]'); Summary = $null }
        }
        $groups[$key].Items.Add($item)
    }
    foreach ($group in $groups.Values) {
        $group.Items = $group.Items.ToArray()
        $group.Summary = Get-InventorySummary $group.Items
    }
    return @($groups.Values | Sort-Object @{Expression = { $_.Summary.Bytes }; Descending = $true}, Label)
}

function Switch-ItemSelection($Items, $Selected) {
    $eligible = @($Items | Where-Object Eligible)
    $allSelected = $eligible.Count -gt 0 -and @($eligible | Where-Object { -not $Selected.ContainsKey($_.Key) }).Count -eq 0
    foreach ($item in $eligible) {
        if ($allSelected) { $Selected.Remove($item.Key) } else { $Selected[$item.Key] = $true }
    }
}

function Get-SelectionMark($Items, $Selected) {
    $summary = Get-InventorySummary $Items $Selected
    if (-not $summary.EligibleCount) { return '[-]' }
    if ($summary.SelectedCount -eq $summary.EligibleCount) { return '[x]' }
    if ($summary.SelectedCount) { return '[~]' }
    return '[ ]'
}

function Format-SizeDistribution($Items, [string]$Property) {
    $total = (Get-InventorySummary $Items).Bytes
    foreach ($group in ($Items | Group-Object $Property | Sort-Object Name)) {
        $summary = Get-InventorySummary $group.Group
        $percent = if ($total -gt 0) { 100.0 * $summary.Bytes / $total } else { 0 }
        $partial = if ($summary.Incomplete) { ' (incomplete)' } else { '' }
        '{0}: {1} ({2:0.#}%){3}' -f $group.Name, (Format-Bytes $summary.Bytes), $percent, $partial
    }
}

function Write-InventoryText($Items) {
    if (-not @($Items).Count) { Write-Output 'No matching items.'; return }
    $summary = Get-InventorySummary $Items
    Write-Output ('Agent storage: {0} measured | {1} eligible for cleanup | {2} items' -f (Format-Bytes $summary.Bytes), (Format-Bytes $summary.EligibleBytes), $summary.Count)
    Write-Output 'Logical sizes cover inventoried agent data, not source-project folders or guaranteed freed space.'
    if ($summary.Incomplete) { Write-Output 'Some sizes are incomplete; totals are lower bounds.' }
    Write-Output 'By project / shared storage (largest first):'
    foreach ($group in (Get-ProjectGroups $Items)) {
        Write-Output ('  {0} | {1} measured | {2} eligible' -f $group.Label, (Format-Bytes $group.Summary.Bytes), (Format-Bytes $group.Summary.EligibleBytes))
        Write-Output ('    ' + ((Format-SizeDistribution $group.Items Provider) -join ' | '))
        Write-Output ('    ' + ((Format-SizeDistribution $group.Items Category) -join ' | '))
    }
    foreach ($group in ($Items | Group-Object Provider, Category | Sort-Object Name)) {
        [long]$total = 0
        foreach ($item in $group.Group) { $total += $item.Bytes }
        Write-Output ("{0}: {1} items, {2} logical" -f $group.Name, $group.Count, (Format-Bytes $total))
        foreach ($item in $group.Group) {
            $flag = if ($item.Eligible) { 'selectable' } else { 'inspect' }
            $title = if ($item.Title) { ' | ' + $item.Title } else { '' }
            $partial = if ($item.Incomplete) { ' (incomplete)' } else { '' }
            Write-Output ("  [{0}] {1}{2} | {3}{4}" -f $flag, (Format-Bytes $item.Bytes), $partial, $item.Path, $title)
        }
    }
}

function Get-ViewRows($Items, $State) {
    switch ($State.Level) {
        0 { return @($Items | Select-Object -ExpandProperty Provider -Unique | Sort-Object) }
        1 { return @($Items | Where-Object Provider -eq $State.Provider | Select-Object -ExpandProperty Category -Unique | Sort-Object) }
        2 { return @($Items | Where-Object { $_.Provider -eq $State.Provider -and $_.Category -eq $State.Category } | Sort-Object Path) }
        default { return @() }
    }
}

function Update-NavState($State, [string]$Key, $Rows) {
    if (-not $State.PSObject.Properties['History']) { $State | Add-Member -NotePropertyName History -NotePropertyValue @{} }
    if ($Key -eq 'B' -or $Key -eq 'LeftArrow') { $Key = 'Backspace' }
    $count = @($Rows).Count
    switch ($Key) {
        'UpArrow' { if ($count) { $State.Index = ($State.Index + $count - 1) % $count } }
        'DownArrow' { if ($count) { $State.Index = ($State.Index + 1) % $count } }
        'Enter' {
            if ($count -and $State.Level -lt 3) {
                $State.History[$State.Level] = $State.Index
                if ($State.Level -eq 0) { $State.Provider = [string]$Rows[$State.Index] }
                if ($State.Level -eq 1) { $State.Category = [string]$Rows[$State.Index] }
                if ($State.Level -eq 2) { $State.DetailKey = $Rows[$State.Index].Key }
                $State.Level++; $State.Index = 0
            }
        }
        'Backspace' { if ($State.Level -gt 0) { $State.Level--; $State.Index = [int]$State.History[$State.Level] } }
    }
    return $State
}

function Get-SelectedItems($Items, $Selected) {
    return @($Items | Where-Object { $_.Eligible -and $Selected.ContainsKey($_.Key) })
}

function Get-FreeSpace($Items) {
    $space = @{}
    foreach ($item in $Items) {
        try {
            $root = [IO.Path]::GetPathRoot($item.Path)
            if (-not $space.ContainsKey($root)) { $space[$root] = ([IO.DriveInfo]::new($root)).AvailableFreeSpace }
        } catch { }
    }
    return $space
}

function Invoke-FileRemoval([string]$Path, [string]$Method) {
    if ($Method -eq 'Recycle Bin') {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
        $recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $recycle)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $recycle)
        }
    } else {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
    }
}

function Get-UndoRootForPath([string]$Path, $Context, [string]$Provider) {
    $roots = if ($Provider -eq 'Codex') { @($Context.CodexRoot, $Context.CodexPackages) }
        elseif ($Provider -eq 'Claude') { @($Context.ClaudeRoot, $Context.ClaudeVersions) }
        else { throw 'Unknown undo provider' }
    foreach ($root in $roots) {
        if ((Get-FullPath $Path) -ne (Get-FullPath $root) -and (Test-Within $Path $root)) {
            return (Join-Path (Split-Path -Parent $root) '.agent-purge-undo')
        }
    }
    throw "Undo path is outside known $Provider storage: $Path"
}

function Initialize-UndoRoot([string]$Root) {
    $marker = Join-Path $Root 'agent-purge-undo-v1.marker'
    if (-not (Test-NoReparse (Split-Path -Parent $Root))) { throw "Unsafe undo parent: $Root" }
    if (Test-Path -LiteralPath $Root) {
        if (-not (Test-NoReparse $Root) -or -not (Test-Path -LiteralPath $marker -PathType Leaf) -or -not (Test-NoReparse $marker) -or
            (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim() -cne 'agent-purge-undo-v1') {
            throw "Undo folder exists without a valid Agent Purge marker: $Root"
        }
    } else {
        New-Item -ItemType Directory -Path $Root -ErrorAction Stop | Out-Null
        if (-not (Test-NoReparse $Root)) { throw "Unsafe undo folder: $Root" }
        [IO.File]::WriteAllText($marker, 'agent-purge-undo-v1', [Text.Encoding]::ASCII)
    }
}

function Get-UndoHash($Run) {
    $plan = [ordered]@{
        RunId = [string]$Run.RunId
        Entries = @($Run.Entries | ForEach-Object {
            [ordered]@{ Original = [string]$_.Original; Archived = [string]$_.Archived; Provider = [string]$_.Provider; Index = [int]$_.Index }
        })
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($plan | ConvertTo-Json -Compress -Depth 5))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function New-UndoRun($Items, $Context) {
    $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) {
        foreach ($path in (Get-ItemPaths $item)) {
            $root = Get-UndoRootForPath $path $Context $item.Provider
            $entries.Add([pscustomobject]@{
                Index = $entries.Count; Original = (Get-FullPath $path)
                Archived = (Join-Path (Join-Path (Join-Path $root 'payload') $runId) ([string]$entries.Count))
                Provider = $item.Provider
            })
        }
    }
    $run = [pscustomobject]@{ RunId = $runId; Entries = $entries.ToArray(); Hash = '' }
    $run.Hash = Get-UndoHash $run
    $manifestRoot = Join-Path (Split-Path -Parent $Context.CodexRoot) '.agent-purge-undo'
    foreach ($root in @($manifestRoot) + @($run.Entries | ForEach-Object { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $_.Archived)) } | Select-Object -Unique)) {
        Initialize-UndoRoot $root
    }
    $runs = Join-Path $manifestRoot 'runs'
    New-Item -ItemType Directory -Path $runs -Force -ErrorAction Stop | Out-Null
    $manifest = Join-Path $runs ($runId + '.json')
    [IO.File]::WriteAllText($manifest, ($run | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    return $run
}

function Invoke-UndoMove([string]$Original, [string]$Archived) {
    $parent = Split-Path -Parent $Archived
    $payload = Split-Path -Parent $parent
    $root = Split-Path -Parent $payload
    if (-not (Test-NoReparse $root) -or ((Test-Path -LiteralPath $payload) -and -not (Test-NoReparse $payload)) -or
        ((Test-Path -LiteralPath $parent) -and -not (Test-NoReparse $parent))) { throw 'Unsafe undo destination' }
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    if (-not (Test-NoReparse $parent) -or (Test-Path -LiteralPath $Archived)) { throw 'Unsafe or occupied undo destination' }
    if ([IO.Path]::GetPathRoot($Original) -ne [IO.Path]::GetPathRoot($Archived)) { throw 'Undo folder must be on the source volume' }
    $entry = Get-Item -LiteralPath $Original -Force -ErrorAction Stop
    if ($entry.PSIsContainer) { [IO.Directory]::Move($Original, $Archived) }
    else { [IO.File]::Move($Original, $Archived) }
}

function Invoke-UndoRestore($Context, [string]$RunId, [string]$Hash) {
    if ($RunId -cnotmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$' -or $Hash -cnotmatch '^[0-9A-F]{64}$') { throw 'Invalid run ID or restore hash format' }
    $root = Join-Path (Split-Path -Parent $Context.CodexRoot) '.agent-purge-undo'
    if (-not (Test-Path -LiteralPath $root)) { throw 'Undo folder not found' }
    Initialize-UndoRoot $root
    $manifest = Join-Path (Join-Path $root 'runs') ($RunId + '.json')
    if (-not (Test-NoReparse $manifest)) { throw 'Unsafe undo manifest path' }
    $run = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($run.RunId -cne $RunId -or $run.Hash -cne $Hash -or (Get-UndoHash $run) -cne $Hash) { throw 'Restore hash does not match this undo run' }
    $restored = 0; $skipped = 0
    foreach ($entry in $run.Entries) {
        try {
            $archiveRoot = Get-UndoRootForPath $entry.Original $Context $entry.Provider
            $expected = Join-Path (Join-Path (Join-Path $archiveRoot 'payload') $RunId) ([string]$entry.Index)
            if ($entry.Archived -cne $expected) { throw 'Undo manifest path mismatch' }
            Initialize-UndoRoot $archiveRoot
            if (-not (Test-Path -LiteralPath $entry.Archived)) { $skipped++; Write-Host "SKIP not archived: $($entry.Original)"; continue }
            if (Test-Path -LiteralPath $entry.Original) { throw 'Original path already exists; no overwrite' }
            if (-not (Test-AppClosed $entry.Provider)) { throw "Close $($entry.Provider) before restore" }
            if (-not (Test-NoReparse $entry.Archived $true) -or -not (Test-NoReparse (Split-Path -Parent $entry.Original))) { throw 'Reparse point, missing parent, or unreadable path' }
            $archived = Get-Item -LiteralPath $entry.Archived -Force -ErrorAction Stop
            if ($archived.PSIsContainer) { [IO.Directory]::Move($entry.Archived, $entry.Original) }
            else { [IO.File]::Move($entry.Archived, $entry.Original) }
            $restored++; Write-Host "RESTORED $($entry.Original)"
        } catch { $skipped++; Write-Host "SKIP $($entry.Original): $($_.Exception.Message)" }
    }
    Write-Host "Restore results: $restored restored, $skipped skipped. Any files still archived continue using disk space."
}

function Invoke-CodexDeletion([string]$Id) {
    $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'codex CLI unavailable' }
    & $command.Source delete --force $Id
    if ($LASTEXITCODE -ne 0) { throw "codex delete exited $LASTEXITCODE" }
}

function Invoke-Cleanup($Items, $Context, [bool]$Advanced = $false) {
    $selected = @($Items | Where-Object Eligible)
    if (-not $selected.Count) { Write-Host 'Nothing selected.'; return }
    $files = @($selected | Where-Object Kind -ne 'CodexSession')
    $codex = @($selected | Where-Object Kind -eq 'CodexSession')
    $summary = Get-InventorySummary $selected
    Write-Host "`nREVIEW CLEANUP"
    Write-Host ('{0} selected items | {1} estimated logical size' -f $summary.Count, (Format-Bytes $summary.Bytes))
    foreach ($group in (Get-ProjectGroups $selected)) {
        Write-Host ('  {0} | {1} | {2} items' -f $group.Label, (Format-Bytes $group.Summary.Bytes), $group.Summary.Count)
    }
    Write-Host 'Close the relevant provider apps before proceeding. Source-project files are not cleanup targets.'
    Write-Host 'Review both methods below. Nothing is removed until all prompts are finished.'
    Write-Host 'Choices and confirmation phrases are case sensitive. Use uppercase letters exactly as shown.'
    Write-Host 'B = back to selection without deleting anything. C = skip the current batch.'
    $confirmFiles = $false; $confirmCodex = $false
    $preview = @{}
    $before = Get-FreeSpace $selected
    if ($files.Count) {
        Write-Host "`nFile cleanup: $($files.Count) items"
        Write-Host 'Undo folder allows a run-based restore, but keeps using disk space until removed manually.'
        Write-Host 'Recycle Bin allows manual recovery until emptied; it may not free disk space immediately.'
        Write-Host 'Permanent removal cannot be undone through the Recycle Bin.'
        while ($true) {
            do {
                $choice = (Read-Host 'Method: U = Undo folder (recommended), R = Recycle Bin, P = permanent, C = skip, B = back (case sensitive)').Trim()
                if ($choice -cnotin @('U', 'R', 'P', 'C', 'B')) { Write-Host 'Use an uppercase choice exactly as shown.' -ForegroundColor Yellow }
            } while ($choice -cnotin @('U', 'R', 'P', 'C', 'B'))
            if ($choice -ceq 'B') { return }
            if ($choice -ceq 'C') { Write-Host 'File cleanup skipped.'; break }
            $method = if ($choice -ceq 'U') { 'Undo folder' } elseif ($choice -ceq 'R') { 'Recycle Bin' } else { 'Permanent' }
            [long]$bytes = 0
            foreach ($item in $files) {
                $bytes += $item.Bytes
                $preview[$item.Key] = @(Get-ItemPaths $item)
                foreach ($path in $preview[$item.Key]) { Write-Host ("  {0} | {1}" -f $method, $path) }
            }
            Write-Host ("Selected for {0}: {1} items, {2} estimated logical size." -f $method, $files.Count, (Format-Bytes $bytes))
            $phrase = if ($method -eq 'Undo folder') { 'MOVE TO UNDO' } elseif ($method -eq 'Recycle Bin') { 'MOVE TO RECYCLE BIN' } else { 'DELETE FILES' }
            Write-Host ("Confirmed items will {0}." -f $(if ($method -eq 'Permanent') { 'be removed permanently' } else { 'move to the ' + $method }))
            do {
                $answer = Read-Host "Type $phrase to confirm, M to change method, C to skip, B to go back (case sensitive)"
                if ($answer -cnotin @($phrase, 'M', 'C', 'B')) { Write-Host 'No action taken. Enter the exact uppercase phrase or choice shown.' -ForegroundColor Yellow }
            } while ($answer -cnotin @($phrase, 'M', 'C', 'B'))
            if ($answer -ceq 'B') { return }
            if ($answer -ceq 'M') { continue }
            $confirmFiles = $answer -ceq $phrase
            if (-not $confirmFiles) { Write-Host 'File cleanup skipped.' }
            break
        }
    }
    if ($codex.Count) {
        Write-Host "`nCodex sessions: $($codex.Count) permanent deletions via codex delete"
        [long]$bytes = 0
        foreach ($item in $codex) { $bytes += $item.Bytes; Write-Host ("  codex delete {0} | {1}" -f $item.Id, $item.Path) }
        Write-Host ("Selected for permanent codex delete: {0} items, {1} estimated logical size." -f $codex.Count, (Format-Bytes $bytes))
        Write-Host 'Codex uses its own deletion command to update session records. These sessions cannot use the undo folder or Recycle Bin.'
        do {
            $answer = Read-Host 'Type DELETE CODEX to confirm, C to skip this batch, B to go back (case sensitive)'
            if ($answer -cnotin @('DELETE CODEX', 'C', 'B')) { Write-Host 'No action taken. Enter the exact uppercase phrase or choice shown.' -ForegroundColor Yellow }
        } while ($answer -cnotin @('DELETE CODEX', 'C', 'B'))
        if ($answer -ceq 'B') { return }
        $confirmCodex = $answer -ceq 'DELETE CODEX'
        if (-not $confirmCodex) { Write-Host 'Codex cleanup skipped.' }
    }
    if (-not $confirmFiles -and -not $confirmCodex) { return }
    $undoRun = $null; $undoPaths = @{}
    if ($confirmFiles -and $method -eq 'Undo folder') {
        $undoRun = New-UndoRun $files $Context
        foreach ($entry in $undoRun.Entries) { $undoPaths[$entry.Original] = $entry.Archived }
        Write-Host ("Undo run: {0}" -f $undoRun.RunId)
        Write-Host ("Restore command: agent-purge restore {0} {1}" -f $undoRun.RunId, $undoRun.Hash)
    }
    $succeeded = 0; $skipped = 0; $failed = 0
    if ($confirmFiles) {
        foreach ($item in $files) {
            if (-not (Test-AppClosed $item.Provider)) { $skipped++; Write-Host "SKIP $($item.Path): close $($item.Provider) first"; continue }
            $reason = Test-SafeItem $item $Context $Advanced
            if ($reason) { $skipped++; Write-Host "SKIP $($item.Path): $reason"; continue }
            $now = @(Get-ItemPaths $item)
            $was = @($preview[$item.Key])
            if (($now -join [char]0) -cne ($was -join [char]0)) { $skipped++; Write-Host "SKIP $($item.Path): paths changed after preview"; continue }
            $itemFailed = $false
            foreach ($path in $was) {
                try {
                    if (-not (Test-NoReparse $path $true)) { throw 'Reparse point or unreadable path' }
                    if ($undoRun) { Invoke-UndoMove $path $undoPaths[(Get-FullPath $path)] }
                    else { Invoke-FileRemoval $path $method }
                    Write-Host "OK $method $path"
                } catch { $itemFailed = $true; Write-Host "FAIL $path`: $($_.Exception.Message)" }
            }
            if ($itemFailed) { $failed++ } else { $succeeded++ }
        }
    }
    if ($confirmCodex) {
        foreach ($item in $codex) {
            if (-not (Test-AppClosed 'Codex')) { $skipped++; Write-Host "SKIP $($item.Id): close Codex first"; continue }
            $reason = Test-SafeItem $item $Context $Advanced
            if ($reason) { $skipped++; Write-Host "SKIP $($item.Id): $reason"; continue }
            try {
                Invoke-CodexDeletion $item.Id
                $succeeded++; Write-Host "OK codex delete $($item.Id)"
            } catch { $failed++; Write-Host "FAIL codex delete $($item.Id): $($_.Exception.Message)" }
        }
    }
    Write-Host ("Cleanup results: {0} succeeded, {1} skipped, {2} failed items." -f $succeeded, $skipped, $failed)
    if ($undoRun) {
        Write-Host ("Restore this run: agent-purge restore {0} {1}" -f $undoRun.RunId, $undoRun.Hash)
        Write-Host 'Undo data still uses disk space. Codex deletions, if confirmed separately, are not part of this restore.'
    }
    $after = Get-FreeSpace $selected
    foreach ($root in $before.Keys) {
        if ($after.ContainsKey($root)) { Write-Host ("Free space {0}: {1} -> {2}" -f $root, (Format-Bytes $before[$root]), (Format-Bytes $after[$root])) }
    }
    return $true
}

function Test-InteractiveTerminal { return -not [Console]::IsInputRedirected }
function Read-MenuKey {
    $previous = [Console]::TreatControlCAsInput
    try {
        [Console]::TreatControlCAsInput = $true
        $controlC = $false
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if ($controlC) { return 'Escape' }
                $controlC = $true
                Write-Host 'Press Ctrl+C again to quit, or any other key to continue.' -ForegroundColor Yellow
                continue
            }
            return $key.Key.ToString()
        }
    } finally {
        [Console]::TreatControlCAsInput = $previous
    }
}

function Get-TerminalSize {
    $width = 100; $height = 25
    try {
        if ([Console]::WindowWidth -ge 20) { $width = [Console]::WindowWidth }
        if ([Console]::WindowHeight -ge 10) { $height = [Console]::WindowHeight }
    } catch { }
    return [pscustomobject]@{ Width = $width; Height = $height }
}

function Write-ScreenLine([string]$Text, [ConsoleColor]$Color = 'Gray') {
    $width = (Get-TerminalSize).Width
    $clean = [regex]::Replace($Text, '[\x00-\x1f\x7f-\x9f]', ' ')
    if ($clean.Length -ge $width) { $clean = $clean.Substring(0, $width - 4) + '...' }
    Write-Host $clean -ForegroundColor $Color
}

function Format-ProjectLabel([string]$Label, [int]$Width) {
    $clean = [regex]::Replace($Label, '[\x00-\x1f\x7f-\x9f]', ' ')
    if ($clean.Length -le $Width -or $Width -lt 8) { return $clean }
    $prefix = [math]::Min(16, [int][math]::Floor(($Width - 3) / 2))
    return $clean.Substring(0, $prefix) + '...' + $clean.Substring($clean.Length - ($Width - $prefix - 3))
}

function Get-PageSize([int]$ReservedLines) {
    $height = (Get-TerminalSize).Height
    return [math]::Max(1, $height - $ReservedLines - 1)
}

function Write-SelectionSummary($Items, $Selected) {
    $summary = Get-InventorySummary $Items $Selected
    Write-ScreenLine ('Measured: {0} | Eligible: {1} | Selected: {2} ({3} items)' -f (Format-Bytes $summary.Bytes), (Format-Bytes $summary.EligibleBytes), (Format-Bytes $summary.SelectedBytes), $summary.SelectedCount) Cyan
    if ($summary.Incomplete) { Write-ScreenLine 'Incomplete sizes: measured totals are lower bounds.' Yellow }
    else { Write-ScreenLine 'Logical agent-storage sizes; source folders are not measured or deleted.' DarkGray }
}

function Get-ScanInventory($Context, [bool]$Advanced, [string]$ProjectPath = '') {
    Write-Host 'Scanning agent storage and measuring sizes. This may take a moment...' -ForegroundColor Cyan
    if ($ProjectPath) { return @(Get-SessionInventory $Context $ProjectPath) }
    return @(Get-GlobalInventory $Context $Advanced)
}

function Invoke-SelectionCleanup($Session) {
    $selectedItems = @(Get-SelectedItems $Session.Items $Session.Selected)
    if (-not $selectedItems.Count) { return }
    Clear-Host
    $attempted = Invoke-Cleanup $selectedItems $Session.Context $Session.Advanced
    if ($attempted) {
        $Session.Items = @(Get-ScanInventory $Session.Context $Session.Advanced $Session.ProjectPath)
        $remaining = @{}
        foreach ($item in $Session.Items) { if ($item.Eligible) { $remaining[$item.Key] = $true } }
        foreach ($key in @($Session.Selected.Keys)) { if (-not $remaining.ContainsKey($key)) { $Session.Selected.Remove($key) } }
        Write-Host 'Inventory refreshed. Press any key to return to selection.'
        [void](Read-MenuKey)
    }
}

function Invoke-ProjectPicker($Session) {
    $index = 0
    $notice = ''
    while ($true) {
        $groups = @(Get-ProjectGroups $Session.Items)
        $index = [math]::Min($index, [math]::Max(0, $groups.Count - 1))
        Clear-Host
        $mode = if ($Session.Advanced) { ' / ADVANCED' } else { '' }
        Write-ScreenLine ('AGENT PURGE / CHOOSE PROJECTS TO CLEAN' + $mode) Cyan
        Write-ScreenLine 'Which projects have agent history you no longer need?'
        Write-ScreenLine 'Space toggles eligible items in a project. Enter reviews your selection.'
        Write-ScreenLine 'Projects use recorded working directories; shared storage is listed separately.' DarkGray
        Write-SelectionSummary $Session.Items $Session.Selected
        Write-ScreenLine ''
        $breakdown = @()
        if ($groups.Count) {
            $focus = $groups[$index]
            $breakdown = @((Format-SizeDistribution $focus.Items Provider)) + @((Format-SizeDistribution $focus.Items Category))
        }
        $limit = Get-PageSize (15 + $breakdown.Count)
        $start = [math]::Max(0, $index - $limit + 1)
        for ($i = $start; $i -lt [math]::Min($groups.Count, $start + $limit); $i++) {
            $group = $groups[$i]
            $cursor = if ($i -eq $index) { '>' } else { ' ' }
            $color = if ($i -eq $index) { 'White' } else { 'Gray' }
            $prefix = '{0} {1} {2,9} | ' -f $cursor, (Get-SelectionMark $group.Items $Session.Selected), (Format-Bytes $group.Summary.Bytes)
            $label = Format-ProjectLabel $group.Label ((Get-TerminalSize).Width - $prefix.Length - 1)
            Write-ScreenLine ($prefix + $label) $color
        }
        if (-not $groups.Count) { Write-ScreenLine 'No matching agent storage found.' }
        else {
            Write-ScreenLine ('Project/group {0}/{1} | [x] selected  [~] partly selected  [-] inspect only' -f ($index + 1), $groups.Count) DarkGray
            Write-ScreenLine ('Focused: ' + (Format-ProjectLabel $focus.Label ((Get-TerminalSize).Width - 10))) Cyan
            Write-ScreenLine ('{0} items | {1} eligible for cleanup' -f $focus.Summary.Count, (Format-Bytes $focus.Summary.EligibleBytes))
            Write-ScreenLine ('Your selection here: {0} of {1} eligible items' -f (Get-InventorySummary $focus.Items $Session.Selected).SelectedCount, $focus.Summary.EligibleCount)
            foreach ($line in $breakdown) { Write-ScreenLine ('  ' + $line) }
        }
        Write-ScreenLine $notice Yellow
        Write-ScreenLine 'Up/Down move | Space toggle | A select/clear all | I inspect'
        Write-ScreenLine 'Enter review cleanup | B/Backspace back | Esc/Ctrl+C twice quit'
        $notice = ''
        $key = Read-MenuKey
        switch ($key) {
            'Escape' { return 'Exit' }
            { $_ -in @('B', 'Backspace') } { return 'Back' }
            'UpArrow' { if ($groups.Count) { $index = ($index + $groups.Count - 1) % $groups.Count } }
            'DownArrow' { if ($groups.Count) { $index = ($index + 1) % $groups.Count } }
            'Spacebar' {
                if ($groups.Count) {
                    Switch-ItemSelection $groups[$index].Items $Session.Selected
                    if (-not $groups[$index].Summary.EligibleCount) { $notice = 'This group is inspection only. Press I to see why.' }
                }
            }
            'A' { Switch-ItemSelection $Session.Items $Session.Selected }
            { $_ -in @('I', 'RightArrow') } {
                if ($groups.Count -and (Invoke-InventoryUI $Session $groups[$index].Key) -eq 'Exit') { return 'Exit' }
            }
            { $_ -in @('Enter', 'D') } {
                if (@(Get-SelectedItems $Session.Items $Session.Selected).Count) { Invoke-SelectionCleanup $Session }
                else { $notice = 'Nothing selected. Use Space on a project, or A to select all eligible items.' }
            }
        }
    }
}

function Invoke-InventoryUI($Session, [string]$GroupKey = '') {
    $state = [pscustomobject]@{ Level = 0; Provider = ''; Category = ''; Index = 0; DetailKey = '' }
    $selected = $Session.Selected
    $notice = ''
    while ($true) {
        $Items = $Session.Items
        if ($GroupKey) {
            $group = Get-ProjectGroups $Session.Items | Where-Object Key -eq $GroupKey | Select-Object -First 1
            $Items = if ($group) { @($group.Items) } else { @() }
        }
        $rows = @(Get-ViewRows $Items $state)
        if ($state.Index -ge $rows.Count) { $state.Index = [math]::Max(0, $rows.Count - 1) }
        Clear-Host
        Write-ScreenLine ('AGENT PURGE / INSPECT / {0} / {1}' -f $state.Provider, $state.Category) Cyan
        $question = switch ($state.Level) {
            0 { 'Which provider uses this storage? Enter opens its categories.' }
            1 { 'What takes up space? Enter opens sessions, logs, caches, or protected items.' }
            2 { 'Which items do you want to remove? Space toggles; Enter shows exact details.' }
            3 { 'Review this item and its eligibility before selecting it.' }
        }
        Write-ScreenLine $question
        Write-SelectionSummary $Session.Items $selected
        Write-ScreenLine 'Space toggles eligible items in the focused row. [-] items remain protected.' DarkGray
        $focusedItems = @()
        if ($state.Level -eq 3) {
            $item = $Items | Where-Object { $_.Key -eq $state.DetailKey } | Select-Object -First 1
            if ($item) {
                $focusedItems = @($item)
                foreach ($field in @('Provider', 'Project', 'Category', 'Date', 'Title', 'TitleSource', 'Path', 'Resume', 'Reason')) {
                    if ($item.$field) { Write-Host ("{0}: {1}" -f $field, $item.$field) }
                }
                Write-Host ('Size: {0}{1}' -f (Format-Bytes $item.Bytes), $(if ($item.Incomplete) { ' (incomplete)' } else { '' }))
                Write-Host ('Selection: {0} | Eligible: {1}' -f (Get-SelectionMark @($item) $selected), $item.Eligible)
            } else { Write-ScreenLine 'This item is no longer in the inventory. Use B to go back.' }
        } elseif (-not $rows.Count) { Write-Host 'No items.' }
        else {
            $limit = Get-PageSize 10
            $start = [math]::Max(0, $state.Index - $limit + 1)
            for ($i = $start; $i -lt [math]::Min($rows.Count, $start + $limit); $i++) {
                $mark = if ($i -eq $state.Index) { '>' } else { ' ' }
                if ($state.Level -eq 2) {
                    $item = $rows[$i]
                    $rowItems = @($item)
                    $label = if ($item.Title) { $item.Title } else { Split-Path -Leaf $item.Path }
                } else {
                    $rowItems = if ($state.Level -eq 0) { @($Items | Where-Object Provider -eq $rows[$i]) } else { @($Items | Where-Object { $_.Provider -eq $state.Provider -and $_.Category -eq $rows[$i] }) }
                    $label = [string]$rows[$i]
                }
                if ($i -eq $state.Index) { $focusedItems = $rowItems }
                $summary = Get-InventorySummary $rowItems
                $partial = if ($summary.Incomplete) { ' (incomplete)' } else { '' }
                Write-ScreenLine ('{0} {1} {2,9} | {3}{4}' -f $mark, (Get-SelectionMark $rowItems $selected), (Format-Bytes $summary.Bytes), $label, $partial)
            }
            Write-ScreenLine ('Row {0}/{1} | Focused: {2} items, {3} eligible' -f ($state.Index + 1), $rows.Count, $focusedItems.Count, (Format-Bytes (Get-InventorySummary $focusedItems).EligibleBytes)) DarkGray
        }
        Write-ScreenLine $notice Yellow
        Write-ScreenLine 'Up/Down move | Enter open | Space toggle | A select/clear this view'
        Write-ScreenLine 'D review cleanup | C copy resume | B/Backspace back | Esc/Ctrl+C twice quit'
        $notice = ''
        $key = Read-MenuKey
        if ($key -eq 'Escape') { return 'Exit' }
        if ($key -in @('B', 'Backspace') -and $state.Level -eq 0) { return 'Back' }
        if ($key -eq 'D') { Invoke-SelectionCleanup $Session; continue }
        if ($key -eq 'Spacebar') { Switch-ItemSelection $focusedItems $selected; continue }
        if ($key -eq 'A') {
            $viewItems = switch ($state.Level) {
                0 { $Items }
                1 { $Items | Where-Object Provider -eq $state.Provider }
                2 { $rows }
                3 { $focusedItems }
            }
            Switch-ItemSelection $viewItems $selected; continue
        }
        if ($key -eq 'C' -and $state.Level -eq 3 -and $focusedItems.Count -and $focusedItems[0].Resume) {
            try { Set-Clipboard -Value $focusedItems[0].Resume -ErrorAction Stop; $notice = 'Resume command copied.' } catch { $notice = 'Clipboard unavailable; use the resume command shown above.' }
            continue
        }
        $state = Update-NavState $state $key $rows
    }
}

function Install-AgentPurge {
    param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\agent-purge'),
        [ValidateSet('User', 'Process')][string]$PathScope = 'User',
        [string]$SourceFile = $script:AgentPurgeScript)
    $root = Get-FullPath $InstallRoot
    $scriptFile = Join-Path $root 'agent-purge.ps1'
    $launcher = Join-Path $root 'agent-purge.cmd'
    $marker = Join-Path $root 'install.json'
    if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $marker)) { throw "Install directory already exists without an agent-purge marker: $root" }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    if ((Get-FullPath $SourceFile) -ne $scriptFile) { Copy-Item -LiteralPath $SourceFile -Destination $scriptFile -Force }
    $body = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0agent-purge.ps1`" %*`r`n"
    [IO.File]::WriteAllText($launcher, $body, [Text.Encoding]::ASCII)
    $record = [ordered]@{ name = 'agent-purge'; scriptHash = (Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash; launcherHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash }
    [IO.File]::WriteAllText($marker, ($record | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
    $pathValue = [Environment]::GetEnvironmentVariable('Path', $PathScope)
    $segments = @($pathValue -split ';' | Where-Object { $_ })
    if (-not @($segments | Where-Object { $_.TrimEnd('\') -eq $root }).Count) {
        [Environment]::SetEnvironmentVariable('Path', (($segments + $root) -join ';'), $PathScope)
    }
    Write-Host "Installed at $root"
    if ($PathScope -eq 'User') { Write-Host 'Open a new terminal to use agent-purge.' }
}

function Update-AgentPurge {
    param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\agent-purge'),
        [ValidateSet('User', 'Process')][string]$PathScope = 'User',
        [switch]$Prompt)
    $root = Get-FullPath $InstallRoot
    $scriptFile = Join-Path $root 'agent-purge.ps1'
    $download = Join-Path $env:TEMP ('agent-purge-update-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $marker = Join-Path $root 'install.json'
        $launcher = Join-Path $root 'agent-purge.cmd'
        $record = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($record.name -ne 'agent-purge' -or -not $record.scriptHash -or -not $record.launcherHash) { throw 'Invalid installation marker' }
        foreach ($pair in @(@($scriptFile, $record.scriptHash), @($launcher, $record.launcherHash))) {
            if (-not (Test-Path -LiteralPath $pair[0]) -or (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne $pair[1]) {
                throw 'Installed files have changed'
            }
        }
        Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/Etriii/agent-purge/main/agent-purge.ps1' -OutFile $download -TimeoutSec 5 -ErrorAction Stop | Out-Null
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -eq $record.scriptHash) {
            if (-not $Prompt) { Write-Host 'Agent Purge is up to date.' }
            return $false
        }
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($download, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw 'Downloaded update has invalid PowerShell syntax' }
        if ($Prompt) {
            Write-Host 'The published Agent Purge script on GitHub main differs from this installation.'
            Write-Host 'U install published version | S skip and continue'
            while ($true) {
                $choice = Read-MenuKey
                if ($choice -in @('S', 'Escape')) { return $false }
                if ($choice -eq 'U') { break }
            }
        }
        Install-AgentPurge -InstallRoot $root -PathScope $PathScope -SourceFile $download | Out-Null
        Write-Host 'Update installed. Start agent-purge again to use the new version.'
        return $true
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}

function Invoke-StartupUpdateCheck {
    param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\agent-purge'),
        [ValidateSet('User', 'Process')][string]$PathScope = 'User')
    $scriptFile = Join-Path (Get-FullPath $InstallRoot) 'agent-purge.ps1'
    if (-not (Test-InteractiveTerminal) -or (Get-FullPath $script:AgentPurgeScript) -ne $scriptFile) { return $false }
    try { return Update-AgentPurge -InstallRoot $InstallRoot -PathScope $PathScope -Prompt }
    catch {
        Write-Host ('Update check failed: {0}. Continuing with the installed version.' -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Uninstall-AgentPurge {
    param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\agent-purge'),
        [ValidateSet('User', 'Process')][string]$PathScope = 'User')
    $root = Get-FullPath $InstallRoot
    $scriptFile = Join-Path $root 'agent-purge.ps1'
    $launcher = Join-Path $root 'agent-purge.cmd'
    $marker = Join-Path $root 'install.json'
    if (-not (Test-Path -LiteralPath $marker)) { throw "No agent-purge installation marker at $root" }
    $record = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($record.name -ne 'agent-purge') { throw 'Installation marker is invalid' }
    foreach ($pair in @(@($scriptFile, $record.scriptHash), @($launcher, $record.launcherHash))) {
        if ((Test-Path -LiteralPath $pair[0]) -and (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne $pair[1]) { throw "Installed file was modified; leaving installation intact: $($pair[0])" }
    }
    foreach ($file in @($scriptFile, $launcher, $marker)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
    if (-not (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $root }
    $pathValue = [Environment]::GetEnvironmentVariable('Path', $PathScope)
    $segments = @($pathValue -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $root })
    [Environment]::SetEnvironmentVariable('Path', ($segments -join ';'), $PathScope)
    Write-Host "Uninstalled from $root"
}

function Show-AgentPurgeHelp {
    @'
Agent Purge: inspect and selectively clean local Codex and Claude storage.

Usage:
  agent-purge                       Check for updates, then open the guided menu
  agent-purge clean                 Choose projects with Space, then Enter to review
  agent-purge clean --all           Preselect all eligible storage; review before deletion
  agent-purge clean --all --advanced
                                    Also select verified old runtimes and caches
  agent-purge clean --project <path> Choose session history for a folder and descendants
  agent-purge scan --global         Inspect global provider storage
  agent-purge scan --global --advanced
                                    Also allow verified old runtimes and caches
  agent-purge scan --project <path> Inspect sessions in a project and descendants
  agent-purge restore <run-id> <hash>
                                    Restore files saved in an Agent Purge undo run
  agent-purge install               Install a user-local launcher and PATH entry
  agent-purge update                Install the latest published main script
  agent-purge uninstall             Remove installed files and that PATH entry
  agent-purge --help                Show this help

Project picker: Up/Down move, Space toggle, A select/clear all, Enter review,
I inspect. Inspector: Enter open, D review, C copy resume from details.
B/Backspace goes back; Esc or Ctrl+C twice quits. [x] selected, [~] partial, [-] inspect only.
Undo folder keeps files for run-based restore; Recycle Bin needs manual restore.
At file cleanup: U undo folder, R Recycle Bin, P permanent, C skip, B back.
Codex sessions use separate permanent deletion and cannot be restored by this command.
Cleanup letters and confirmation phrases are case sensitive.
Sizes show inventoried agent storage by project/provider/category, not source folders.
Clean --all never removes protected items and still requires typed confirmation.
Redirected scan and clean commands only print inventory; they never remove data.
Installed interactive launches offer an update from GitHub main when available.
Update refreshes the installed copy; to update a source checkout, pull main.
'@ | Write-Output
}

function Show-StartMenu {
    $labels = @('Choose projects to clean (recommended)', 'Inspect all agent storage', 'Clean all eligible storage', 'Choose one project folder', 'Exit')
    $descriptions = @(
        'See project sizes, toggle projects with Space, then review cleanup with Enter.',
        'Browse providers and categories to understand storage and protected items.',
        'Preselect eligible sessions and logs. You can deselect before confirming cleanup.',
        'Limit session history to a project folder and its descendants.',
        'Close Agent Purge without making further changes.'
    )
    $index = 0
    while ($true) {
        Clear-Host
        Write-ScreenLine 'AGENT PURGE' Cyan
        Write-ScreenLine 'What would you like to clean or inspect?'
        Write-ScreenLine 'Find local Codex and Claude storage by project, provider, and category.'
        Write-ScreenLine 'Source-project folders are never cleanup targets. Every deletion needs review.' DarkGray
        Write-ScreenLine ''
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $mark = if ($i -eq $index) { '>' } else { ' ' }
            Write-ScreenLine ('{0} {1}' -f $mark, $labels[$i])
        }
        Write-ScreenLine ''
        Write-ScreenLine $descriptions[$index] Cyan
        Write-ScreenLine 'Up/Down move | Enter choose | Esc/Ctrl+C twice quit'
        $key = Read-MenuKey
        if ($key -eq 'Escape') { return }
        if ($key -eq 'UpArrow') { $index = ($index + $labels.Count - 1) % $labels.Count; continue }
        if ($key -eq 'DownArrow') { $index = ($index + 1) % $labels.Count; continue }
        if ($key -eq 'G') { $index = 1; $key = 'Enter' }
        if ($key -eq 'P') { $index = 3; $key = 'Enter' }
        if ($key -eq 'C') { $index = 0; $key = 'Enter' }
        if ($key -eq 'A') { $index = 2; $key = 'Enter' }
        if ($key -ne 'Enter') { continue }
        switch ($index) {
            0 { return @('clean') }
            1 { return @('scan', '--global') }
            2 { return @('clean', '--all') }
            3 {
                Write-Host 'Enter a source-project folder to find its recorded agent history. Leave blank to go back.'
                $path = (Read-Host 'Project folder').Trim().Trim('"')
                if (-not $path) { continue }
                if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                    Write-Host "Folder not found: $path. Press any key to return."
                    [void](Read-MenuKey); continue
                }
                return @('clean', '--project', $path)
            }
            4 { return }
        }
    }
}

function Invoke-AgentPurge([string[]]$Arguments) {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core' -and $env:OS -ne 'Windows_NT') { throw 'Agent Purge requires Windows.' }
    $fromMenu = -not $Arguments.Count
    if ($fromMenu -and -not (Test-InteractiveTerminal)) { Show-AgentPurgeHelp; return }
    if ($fromMenu -and (Invoke-StartupUpdateCheck)) { return }
    do {
        if ($fromMenu) { $Arguments = @(Show-StartMenu); if (-not $Arguments.Count) { return } }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--help') { Show-AgentPurgeHelp; return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'install') { Install-AgentPurge; return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'update') { [void](Update-AgentPurge); return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'uninstall') { Uninstall-AgentPurge; return }
        if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'restore') {
            Invoke-UndoRestore (New-AgentPurgeContext) $Arguments[1] $Arguments[2]
            return
        }
        if ($Arguments[0] -notin @('scan', 'clean')) { throw 'Unknown command. Use --help.' }
        $clean = $Arguments[0] -eq 'clean'
        $advanced = $false; $selectAll = $false; $project = ''
        if ($Arguments.Count -eq 1 -and $clean) { }
        elseif ($Arguments.Count -in @(2, 3) -and (($clean -and $Arguments[1] -eq '--all') -or (-not $clean -and $Arguments[1] -eq '--global')) -and ($Arguments.Count -eq 2 -or $Arguments[2] -eq '--advanced')) {
            $selectAll = $clean
            $advanced = $Arguments.Count -eq 3
        } elseif ($Arguments.Count -eq 3 -and $Arguments[1] -eq '--project') {
            if (-not (Test-Path -LiteralPath $Arguments[2] -PathType Container)) { throw "Project directory not found: $($Arguments[2])" }
            $project = (Get-Item -LiteralPath $Arguments[2]).FullName
        } else { throw 'Invalid arguments. Use --help.' }
        if (-not $fromMenu -and (Invoke-StartupUpdateCheck)) { return }
        $context = New-AgentPurgeContext
        $items = @(Get-ScanInventory $context $advanced $project)
        if (-not (Test-InteractiveTerminal)) {
            Write-Output 'Read-only inventory: interactive selection and confirmation are required for cleanup.'
            Write-InventoryText $items
            return
        }
        $session = [pscustomobject]@{ Items = $items; Selected = @{}; Context = $context; Advanced = $advanced; ProjectPath = $project }
        if ($selectAll) { Switch-ItemSelection $items $session.Selected }
        $result = if ($clean) { Invoke-ProjectPicker $session } else { Invoke-InventoryUI $session }
        if ($result -eq 'Exit') { return }
        if ($result -eq 'Back') { $fromMenu = $true }
    } while ($fromMenu)
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-AgentPurge $args } catch { Write-Error $_.Exception.Message; exit 1 }
}
