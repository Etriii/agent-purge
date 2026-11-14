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
            if (-not $head.Id -or $f.Name -notmatch [regex]::Escape($head.Id) + '\.jsonl$') {
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

