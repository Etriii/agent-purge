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

function Format-Bytes([long]$Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    foreach ($unit in @('KB', 'MB', 'GB', 'TB')) {
        $Bytes = [math]::Round($Bytes / 1024, 1)
        if ($Bytes -lt 1024 -or $unit -eq 'TB') { return "$Bytes $unit" }
    }
}

function Write-InventoryText($Items) {
    if (-not @($Items).Count) { Write-Output 'No matching items.'; return }
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
    $count = @($Rows).Count
    switch ($Key) {
        'UpArrow' { if ($count) { $State.Index = ($State.Index + $count - 1) % $count } }
        'DownArrow' { if ($count) { $State.Index = ($State.Index + 1) % $count } }
        'Enter' {
            if ($count -and $State.Level -lt 3) {
                if ($State.Level -eq 0) { $State.Provider = [string]$Rows[$State.Index] }
                if ($State.Level -eq 1) { $State.Category = [string]$Rows[$State.Index] }
                $State.Level++; $State.Index = 0
            }
        }
        'Backspace' { if ($State.Level -gt 0) { $State.Level--; $State.Index = 0 } }
    }
    return $State
}

function Get-SelectedItems($Items, $Selected) {
    return @($Items | Where-Object { $Selected.ContainsKey($_.Key) })
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

function Invoke-CodexDeletion([string]$Id) {
    $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'codex CLI unavailable' }
    & $command.Source delete --force $Id
    if ($LASTEXITCODE -ne 0) { throw "codex delete exited $LASTEXITCODE" }
}

function Invoke-Cleanup($Items, $Context, [bool]$Advanced = $false) {
    $selected = @($Items)
    if (-not $selected.Count) { Write-Host 'Nothing selected.'; return }
    $files = @($selected | Where-Object Kind -ne 'CodexSession')
    $codex = @($selected | Where-Object Kind -eq 'CodexSession')
    $before = Get-FreeSpace $selected
    if ($files.Count) {
        Write-Host "`nFile cleanup: $($files.Count) items"
        $choice = (Read-Host 'Method: R = Recycle Bin, P = permanent, C = cancel').Trim().ToUpperInvariant()
        if ($choice -in @('R', 'P')) {
            $method = if ($choice -eq 'R') { 'Recycle Bin' } else { 'Permanent' }
            [long]$bytes = 0
            $preview = @{}
            foreach ($item in $files) {
                $bytes += $item.Bytes
                $preview[$item.Key] = @(Get-ItemPaths $item)
                foreach ($path in $preview[$item.Key]) { Write-Host ("  {0} | {1}" -f $method, $path) }
            }
            Write-Host ("{0} items, {1} estimated logical size." -f $files.Count, (Format-Bytes $bytes))
            if ((Read-Host 'Type DELETE FILES to confirm') -ceq 'DELETE FILES') {
                foreach ($item in $files) {
                    if (-not (Test-AppClosed $item.Provider)) { Write-Host "SKIP $($item.Path): close $($item.Provider) first"; continue }
                    $reason = Test-SafeItem $item $Context $Advanced
                    if ($reason) { Write-Host "SKIP $($item.Path): $reason"; continue }
                    $now = @(Get-ItemPaths $item)
                    $was = @($preview[$item.Key])
                    if (($now -join [char]0) -cne ($was -join [char]0)) { Write-Host "SKIP $($item.Path): paths changed after preview"; continue }
                    foreach ($path in $was) {
                        try {
                            if (-not (Test-NoReparse $path $true)) { throw 'Reparse point or unreadable path' }
                            Invoke-FileRemoval $path $method
                            Write-Host "OK $method $path"
                        } catch { Write-Host "FAIL $path`: $($_.Exception.Message)" }
                    }
                }
            } else { Write-Host 'File cleanup cancelled.' }
        } else { Write-Host 'File cleanup cancelled.' }
    }
    if ($codex.Count) {
        Write-Host "`nCodex sessions: $($codex.Count) permanent deletions via codex delete"
        [long]$bytes = 0
        foreach ($item in $codex) { $bytes += $item.Bytes; Write-Host ("  codex delete {0} | {1}" -f $item.Id, $item.Path) }
        Write-Host ("{0} items, {1} estimated logical size." -f $codex.Count, (Format-Bytes $bytes))
        if ((Read-Host 'Type DELETE CODEX to confirm') -ceq 'DELETE CODEX') {
            foreach ($item in $codex) {
                if (-not (Test-AppClosed 'Codex')) { Write-Host "SKIP $($item.Id): close Codex first"; continue }
                $reason = Test-SafeItem $item $Context $Advanced
                if ($reason) { Write-Host "SKIP $($item.Id): $reason"; continue }
                try {
                    Invoke-CodexDeletion $item.Id
                    Write-Host "OK codex delete $($item.Id)"
                } catch { Write-Host "FAIL codex delete $($item.Id): $($_.Exception.Message)" }
            }
        } else { Write-Host 'Codex cleanup cancelled.' }
    }
    $after = Get-FreeSpace $selected
    foreach ($root in $before.Keys) {
        if ($after.ContainsKey($root)) { Write-Host ("Free space {0}: {1} -> {2}" -f $root, (Format-Bytes $before[$root]), (Format-Bytes $after[$root])) }
    }
}

function Invoke-InventoryUI($Items, $Context, [bool]$Advanced = $false) {
    if ([Console]::IsInputRedirected) { Write-InventoryText $Items; return }
    $state = [pscustomobject]@{ Level = 0; Provider = ''; Category = ''; Index = 0; DetailKey = '' }
    $selected = @{}
    while ($true) {
        $rows = @(Get-ViewRows $Items $state)
        if ($state.Index -ge $rows.Count) { $state.Index = [math]::Max(0, $rows.Count - 1) }
        Clear-Host
        Write-Host ('Agent Purge | {0} selected | Esc quit | D cleanup' -f $selected.Count)
        Write-Host 'Arrows navigate | Enter open | Space select | Backspace back | C copy resume'
        Write-Host ("{0} {1}" -f $state.Provider, $state.Category)
        if ($state.Level -eq 3) {
            $item = $Items | Where-Object { $_.Key -eq $state.DetailKey } | Select-Object -First 1
            if ($item) {
                foreach ($field in @('Provider', 'Project', 'Category', 'Date', 'Title', 'TitleSource', 'Path', 'Resume', 'Reason')) {
                    if ($item.$field) { Write-Host ("{0}: {1}" -f $field, $item.$field) }
                }
                Write-Host ('Size: {0}{1}' -f (Format-Bytes $item.Bytes), $(if ($item.Incomplete) { ' (incomplete)' } else { '' }))
                Write-Host ('Selectable: ' + $item.Eligible)
            }
        } elseif (-not $rows.Count) { Write-Host 'No items.' }
        else {
            $limit = [math]::Min($rows.Count, [math]::Max(8, [Console]::WindowHeight - 7))
            $start = [math]::Max(0, $state.Index - $limit + 1)
            for ($i = $start; $i -lt [math]::Min($rows.Count, $start + $limit); $i++) {
                $mark = if ($i -eq $state.Index) { '>' } else { ' ' }
                if ($state.Level -eq 2) {
                    $item = $rows[$i]
                    $check = if ($selected.ContainsKey($item.Key)) { '[x]' } elseif ($item.Eligible) { '[ ]' } else { '[-]' }
                    Write-Host ("{0} {1} {2} {3} {4}" -f $mark, $check, (Format-Bytes $item.Bytes), (Split-Path -Leaf $item.Path), $item.Title)
                } else { Write-Host ("{0} {1}" -f $mark, $rows[$i]) }
            }
        }
        $key = [Console]::ReadKey($true).Key.ToString()
        if ($key -eq 'Escape') { return }
        if ($key -eq 'D') { Invoke-Cleanup (Get-SelectedItems $Items $selected) $Context $Advanced; [void][Console]::ReadKey($true); continue }
        if ($key -eq 'Spacebar' -and $state.Level -ge 2) {
            $item = if ($state.Level -eq 3) { $Items | Where-Object Key -eq $state.DetailKey | Select-Object -First 1 } elseif ($rows.Count) { $rows[$state.Index] }
            if ($item -and $item.Eligible) { if ($selected.ContainsKey($item.Key)) { $selected.Remove($item.Key) } else { $selected[$item.Key] = $true } }
            continue
        }
        if ($key -eq 'C' -and $state.Level -eq 3 -and $item.Resume) {
            try { Set-Clipboard -Value $item.Resume -ErrorAction Stop } catch { Write-Host "Clipboard unavailable: $($item.Resume)"; [void][Console]::ReadKey($true) }
            continue
        }
        if ($key -eq 'Enter' -and $state.Level -eq 2 -and $rows.Count) { $state.DetailKey = $rows[$state.Index].Key; $state.Level = 3; continue }
        $state = Update-NavState $state $key $rows
    }
}

function Install-AgentPurge {
    param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\agent-purge'),
        [ValidateSet('User', 'Process')][string]$PathScope = 'User')
    $root = Get-FullPath $InstallRoot
    $scriptFile = Join-Path $root 'agent-purge.ps1'
    $launcher = Join-Path $root 'agent-purge.cmd'
    $marker = Join-Path $root 'install.json'
    if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $marker)) { throw "Install directory already exists without an agent-purge marker: $root" }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    if ((Get-FullPath $script:AgentPurgeScript) -ne $scriptFile) { Copy-Item -LiteralPath $script:AgentPurgeScript -Destination $scriptFile -Force }
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
  agent-purge                       Interactive global/project scope picker
  agent-purge scan --global         Inspect global provider storage
  agent-purge scan --global --advanced
                                    Also allow verified old runtimes and caches
  agent-purge scan --project <path> Inspect sessions in a project and descendants
  agent-purge install               Install a user-local launcher and PATH entry
  agent-purge uninstall             Remove installed files and that PATH entry
  agent-purge --help                Show this help

Keys: Up/Down navigate, Enter open, Space select, Backspace back, C copy resume
command from detail, D review cleanup, Esc quit. Protected items show [-].
Redirected scans print an inventory and cannot remove anything.
To update: pull the latest main branch in your Git checkout and run install again.
'@ | Write-Output
}

function Invoke-AgentPurge([string[]]$Arguments) {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core' -and $env:OS -ne 'Windows_NT') { throw 'Agent Purge requires Windows.' }
    if (-not $Arguments.Count) {
        if ([Console]::IsInputRedirected) { Show-AgentPurgeHelp; return }
        Write-Host 'Agent Purge: G global scan, P project scan, Esc quit'
        $key = [Console]::ReadKey($true).Key.ToString()
        if ($key -eq 'Escape') { return }
        if ($key -eq 'G') { $Arguments = @('scan', '--global') }
        elseif ($key -eq 'P') { $Arguments = @('scan', '--project', (Read-Host 'Project path')) }
        else { return }
    }
    if ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--help') { Show-AgentPurgeHelp; return }
    if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'install') { Install-AgentPurge; return }
    if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'uninstall') { Uninstall-AgentPurge; return }
    if ($Arguments[0] -ne 'scan') { throw 'Unknown command. Use --help.' }
    $context = New-AgentPurgeContext
    if ($Arguments.Count -eq 2 -and $Arguments[1] -eq '--global') {
        Invoke-InventoryUI (Get-GlobalInventory $context $false) $context $false
        return
    }
    if ($Arguments.Count -eq 3 -and $Arguments[1] -eq '--global' -and $Arguments[2] -eq '--advanced') {
        Invoke-InventoryUI (Get-GlobalInventory $context $true) $context $true
        return
    }
    if ($Arguments.Count -eq 3 -and $Arguments[1] -eq '--project') {
        if (-not (Test-Path -LiteralPath $Arguments[2] -PathType Container)) { throw "Project directory not found: $($Arguments[2])" }
        $project = (Get-Item -LiteralPath $Arguments[2]).FullName
        Invoke-InventoryUI (Get-SessionInventory $context $project) $context $false
        return
    }
    throw 'Invalid arguments. Use --help.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-AgentPurge $args } catch { Write-Error $_.Exception.Message; exit 1 }
}
