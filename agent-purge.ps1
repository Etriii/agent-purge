# Windows PowerShell 5.1 compatible. Dot-source this file to exercise its functions with fixtures.
$script:AgentPurgeScript = $PSCommandPath
$script:AgentPurgeVersion = '1.0.2'

function Get-AgentPurgeScriptVersion([string]$Path, [bool]$AllowLegacy = $false) {
    $source = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $matches = [regex]::Matches($source, '(?m)^\$script:AgentPurgeVersion = ''([0-9]+\.[0-9]+\.[0-9]+)''\s*$')
    if ($matches.Count -eq 1) { return [version]$matches[0].Groups[1].Value }
    if ($matches.Count -eq 0 -and $AllowLegacy) { return [version]'0.0.0' }
    throw "Missing or invalid Agent Purge version in $Path"
}

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

function Get-CurrentProjectPath {
    try {
        $cursor = Get-FullPath (Get-Location).ProviderPath
        while ($true) {
            if (Test-Path -LiteralPath (Join-Path $cursor '.git')) { return $cursor }
            $parent = Split-Path -Parent $cursor
            if (-not $parent -or $parent -eq $cursor) { break }
            $cursor = $parent
        }
    } catch { }
    return ''
}

function New-AgentPurgeContext {
    param(
        [string]$CodexRoot = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
        [string]$ClaudeRoot = (Join-Path $env:USERPROFILE '.claude'),
        [string]$CodexPackages = '',
        [string]$ClaudeVersions = (Join-Path $env:USERPROFILE '.local\share\claude\versions'),
        [string]$ClaudeBinary = (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        [string]$CodexBinary = (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'),
        [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'agent-purge\config.json')
    )
    if (-not $CodexPackages) { $CodexPackages = Join-Path $CodexRoot 'packages' }
    return [pscustomobject]@{
        CodexRoot = Get-FullPath $CodexRoot
        ClaudeRoot = Get-FullPath $ClaudeRoot
        CodexPackages = Get-FullPath $CodexPackages
        ClaudeVersions = Get-FullPath $ClaudeVersions
        ClaudeBinary = Get-FullPath $ClaudeBinary
        CodexBinary = Get-FullPath $CodexBinary
        ConfigPath = Get-FullPath $ConfigPath
    }
}

function Get-AgentPurgeConfig($Context, [int]$RetentionOverride = 0) {
    $previous = $Context.ConfigPath + '.previous'
    if (-not (Test-Path -LiteralPath $Context.ConfigPath) -and (Test-Path -LiteralPath $previous)) {
        if (-not (Test-NoReparse $previous)) { throw 'Unsafe previous Agent Purge config' }
        [IO.File]::Move($previous, $Context.ConfigPath)
    }
    if (-not (Test-Path -LiteralPath $Context.ConfigPath)) {
        return [pscustomobject]@{ RetentionDays = $(if ($RetentionOverride) { $RetentionOverride } else { 30 }); UndoDirectory = ''; UndoHistory = @(); ProjectScopes = @{}; Source = 'default' }
    }
    if (-not (Test-NoReparse $Context.ConfigPath)) { throw 'Unsafe Agent Purge config path' }
    $saved = Get-Content -LiteralPath $Context.ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $RetentionOverride -and ($null -eq $saved.retentionDays -or $saved.retentionDays -isnot [int] -or $saved.retentionDays -lt 1 -or $saved.retentionDays -gt 365)) {
        throw 'Invalid retentionDays in Agent Purge config; expected an integer from 1 to 365'
    }
    $undoDirectory = ''
    if ($saved.PSObject.Properties['undoDirectory']) {
        if ($saved.undoDirectory -isnot [string] -or -not [IO.Path]::IsPathRooted($saved.undoDirectory) -or
            (Get-FullPath $saved.undoDirectory) -cne $saved.undoDirectory) { throw 'Invalid undoDirectory in Agent Purge config' }
        $undoDirectory = $saved.undoDirectory
    }
    $history = @()
    if ($saved.PSObject.Properties['undoHistory']) {
        if ($saved.undoHistory -isnot [array]) { throw 'Invalid undoHistory in Agent Purge config' }
        foreach ($path in $saved.undoHistory) {
            if ($path -isnot [string] -or -not [IO.Path]::IsPathRooted($path) -or (Get-FullPath $path) -cne $path) { throw 'Invalid undoHistory path in Agent Purge config' }
            $history += $path
        }
    }
    $projectScopes = @{}
    if ($saved.PSObject.Properties['projectScopes']) {
        if ($saved.projectScopes -isnot [pscustomobject]) { throw 'Invalid projectScopes in Agent Purge config' }
        foreach ($entry in $saved.projectScopes.PSObject.Properties) {
            if (-not [IO.Path]::IsPathRooted($entry.Name) -or (Get-FullPath $entry.Name) -cne $entry.Name -or
                $entry.Value -cnotin @('project', 'global')) { throw 'Invalid project scope preference in Agent Purge config' }
            $projectScopes[$entry.Name] = [string]$entry.Value
        }
    }
    return [pscustomobject]@{ RetentionDays = $(if ($RetentionOverride) { $RetentionOverride } else { [int]$saved.retentionDays }); UndoDirectory = $undoDirectory; UndoHistory = $history; ProjectScopes = $projectScopes; Source = $Context.ConfigPath }
}

function Save-AgentPurgeConfig($Context, $Config) {
    $path = $Context.ConfigPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) {
        if (-not (Test-NoReparse (Split-Path -Parent $parent))) { throw 'Unsafe Agent Purge config parent' }
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    if (-not (Test-NoReparse $parent) -or ((Test-Path -LiteralPath $path) -and -not (Test-NoReparse $path))) { throw 'Unsafe Agent Purge config path' }
    $body = [ordered]@{ retentionDays = [int]$Config.RetentionDays }
    if ($Config.UndoDirectory) { $body['undoDirectory'] = [string]$Config.UndoDirectory }
    if (@($Config.UndoHistory).Count) { $body['undoHistory'] = @($Config.UndoHistory) }
    if ($Config.ProjectScopes.Count) { $body['projectScopes'] = $Config.ProjectScopes }
    $temporary = Join-Path $parent ('.agent-purge-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $path + '.previous'
    try {
        [IO.File]::WriteAllText($temporary, ($body | ConvertTo-Json -Compress -Depth 4), [Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $backup) {
            if (-not (Test-Path -LiteralPath $path) -or -not (Test-NoReparse $backup)) { throw 'Unresolved Agent Purge config backup' }
            Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $path) { [IO.File]::Move($path, $backup) }
        try { [IO.File]::Move($temporary, $path) }
        catch {
            if (Test-Path -LiteralPath $backup) { [IO.File]::Move($backup, $path) }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
}

function Set-ProjectScopePreference($Context, [string]$ProjectPath, [string]$Choice) {
    if ($Choice -cnotin @('project', 'global', 'ask')) { throw 'Scope must be project, global, or ask' }
    $project = Get-FullPath $ProjectPath
    if (-not (Test-Path -LiteralPath $project -PathType Container)) { throw 'Project folder not found' }
    $config = Get-AgentPurgeConfig $Context
    if ($Choice -eq 'ask') { [void]$config.ProjectScopes.Remove($project) }
    else { $config.ProjectScopes[$project] = $Choice }
    Save-AgentPurgeConfig $Context $config
}

function Set-AgentPurgeRetention($Context, [int]$Days) {
    if ($Days -lt 1 -or $Days -gt 365) { throw 'Retention days must be from 1 to 365' }
    $config = Get-AgentPurgeConfig $Context $Days
    $config.RetentionDays = $Days
    Save-AgentPurgeConfig $Context $config
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
        'PageUp' { if ($count) { $State.Index = [math]::Max(0, $State.Index - (Get-PageSize 11)) } }
        'PageDown' { if ($count) { $State.Index = [math]::Min($count - 1, $State.Index + (Get-PageSize 11)) } }
        'Home' { if ($count) { $State.Index = 0 } }
        'End' { if ($count) { $State.Index = $count - 1 } }
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

function Get-LegacyUndoRootForPath([string]$Path, $Context, [string]$Provider) {
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

function Get-UndoRootKey([string]$LegacyRoot) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((Get-FullPath $LegacyRoot).ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
}

function Get-UndoManifestRoot($Context, $Config = $null) {
    if ($null -eq $Config) { $Config = Get-AgentPurgeConfig $Context }
    if ($Config.UndoDirectory) { return $Config.UndoDirectory }
    return (Join-Path (Split-Path -Parent $Context.CodexRoot) '.agent-purge-undo')
}

function Get-UndoRootForPath([string]$Path, $Context, [string]$Provider, $Config = $null) {
    $legacyRoot = Get-LegacyUndoRootForPath $Path $Context $Provider
    if ($null -eq $Config) { $Config = Get-AgentPurgeConfig $Context }
    if (-not $Config.UndoDirectory) { return $legacyRoot }
    return (Join-Path (Join-Path $Config.UndoDirectory 'locations') (Get-UndoRootKey $legacyRoot))
}

function Resolve-UndoEntryPath($Entry, [string]$RunId, $Context, $Config = $null) {
    if ($null -eq $Config) { $Config = Get-AgentPurgeConfig $Context }
    $legacyRoot = Get-LegacyUndoRootForPath $Entry.Original $Context $Entry.Provider
    $key = Get-UndoRootKey $legacyRoot
    $currentRoot = Get-UndoRootForPath $Entry.Original $Context $Entry.Provider $Config
    $current = Join-Path (Join-Path (Join-Path $currentRoot 'payload') $RunId) ([string]$Entry.Index)
    $allowed = @($current, (Join-Path (Join-Path (Join-Path $legacyRoot 'payload') $RunId) ([string]$Entry.Index)))
    foreach ($prior in @($Config.UndoHistory)) {
        $allowed += Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $prior 'locations') $key) 'payload') $RunId) ([string]$Entry.Index)
    }
    if ($Entry.Archived -cnotin $allowed) { throw 'Undo manifest path mismatch' }
    return $current
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
    if ($Run.PSObject.Properties['CreatedAtUtc'] -and $Run.PSObject.Properties['ExpiresAtUtc']) {
        $plan['CreatedAtUtc'] = [string]$Run.CreatedAtUtc
        $plan['ExpiresAtUtc'] = [string]$Run.ExpiresAtUtc
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($plan | ConvertTo-Json -Compress -Depth 5))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function New-UndoRun($Items, $Context) {
    $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $config = Get-AgentPurgeConfig $Context
    foreach ($item in $Items) {
        foreach ($path in (Get-ItemPaths $item)) {
            $root = Get-UndoRootForPath $path $Context $item.Provider $config
            $entries.Add([pscustomobject]@{
                Index = $entries.Count; Original = (Get-FullPath $path)
                Archived = (Join-Path (Join-Path (Join-Path $root 'payload') $runId) ([string]$entries.Count))
                Provider = $item.Provider
            })
        }
    }
    $created = [DateTime]::UtcNow
    $retention = $config.RetentionDays
    $run = [pscustomobject]@{
        RunId = $runId; Entries = $entries.ToArray(); Hash = ''
        CreatedAtUtc = $created.ToString('o'); ExpiresAtUtc = $created.AddDays($retention).ToString('o')
    }
    $run.Hash = Get-UndoHash $run
    $manifestRoot = Get-UndoManifestRoot $Context $config
    foreach ($root in @($manifestRoot) + @($run.Entries | ForEach-Object { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $_.Archived)) } | Select-Object -Unique)) {
        $parent = Split-Path -Parent $root
        if (-not (Test-Path -LiteralPath $parent)) {
            if (-not (Test-NoReparse (Split-Path -Parent $parent))) { throw 'Unsafe undo location parent' }
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        Initialize-UndoRoot $root
    }
    $runs = Join-Path $manifestRoot 'runs'
    New-Item -ItemType Directory -Path $runs -Force -ErrorAction Stop | Out-Null
    $manifest = Join-Path $runs ($runId + '.json')
    [IO.File]::WriteAllText($manifest, ($run | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
    return $run
}

function Get-PathFingerprint([string]$Path) {
    if (-not (Test-NoReparse $Path $true)) { throw "Unsafe or unreadable path: $Path" }
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $records = New-Object 'System.Collections.Generic.List[string]'
    $entries = @($root)
    if ($root.PSIsContainer) { $entries += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Sort-Object FullName) }
    foreach ($entry in $entries) {
        $relative = $entry.FullName.Substring($root.FullName.Length).TrimStart([char]'\', [char]'/')
        if ($entry.PSIsContainer) { $records.Add("D|$relative") }
        else { $records.Add("F|$relative|$($entry.Length)|$((Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash)") }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($records -join "`n"))))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-LegacyUndoRoots($Context) {
    return @(@($Context.CodexRoot, $Context.ClaudeRoot, $Context.CodexPackages, $Context.ClaudeVersions) |
        ForEach-Object { Join-Path (Split-Path -Parent $_) '.agent-purge-undo' } | Sort-Object -Unique)
}

function Copy-VerifiedPath([string]$Source, [string]$Destination) {
    if (-not (Test-NoReparse $Source $true) -or -not (Test-NoReparse (Split-Path -Parent $Destination)) -or (Test-Path -LiteralPath $Destination)) {
        throw 'Unsafe, missing, or occupied copy path'
    }
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $sourceHash = Get-PathFingerprint $Source
    $staging = $Destination + '.copy-' + [guid]::NewGuid().ToString('N')
    try {
        if ($item.PSIsContainer) { Copy-Item -LiteralPath $Source -Destination $staging -Recurse -Force -ErrorAction Stop }
        else { [IO.File]::Copy($Source, $staging) }
        if ((Get-PathFingerprint $staging) -cne $sourceHash -or (Get-PathFingerprint $Source) -cne $sourceHash) {
            throw 'Copied data differs from the source; original kept'
        }
        if ($item.PSIsContainer) { [IO.Directory]::Move($staging, $Destination) }
        else { [IO.File]::Move($staging, $Destination) }
    } finally {
        if (Test-Path -LiteralPath $staging) {
            if (-not (Test-Within $staging (Split-Path -Parent $Destination))) { throw 'Unsafe copy staging path' }
            Remove-Item -LiteralPath $staging -Force -Recurse -ErrorAction Stop
        }
    }
}

function Copy-VerifiedUndoContents([string]$SourceRoot, [string]$TargetRoot) {
    Initialize-UndoRoot $SourceRoot
    Initialize-UndoRoot $TargetRoot
    if (-not (Test-NoReparse $SourceRoot $true)) { throw "Unsafe undo source: $SourceRoot" }
    $before = Get-PathFingerprint $SourceRoot
    foreach ($child in (Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction Stop)) {
        if ($child.Name -eq 'agent-purge-undo-v1.marker') { continue }
        $destination = Join-Path $TargetRoot $child.Name
        if (-not (Test-Path -LiteralPath $destination)) { Copy-VerifiedPath $child.FullName $destination }
        if ((Get-PathFingerprint $child.FullName) -cne (Get-PathFingerprint $destination)) {
            throw "Undo copy differs from source: $($child.FullName)"
        }
    }
    if ((Get-PathFingerprint $SourceRoot) -cne $before) { throw "Undo source changed during copy: $SourceRoot" }
    return $before
}

function Set-AgentPurgeUndoDirectory($Context, [string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Undo directory must be an absolute path' }
    $target = Get-FullPath $Path
    if ($target -eq [IO.Path]::GetPathRoot($target)) { throw 'Choose a folder, not a drive root' }
    $config = Get-AgentPurgeConfig $Context
    if ($config.UndoDirectory -and $target -ieq $config.UndoDirectory) { Write-Host "Undo folder already set to $target"; return }
    $sources = if ($config.UndoDirectory) { @($config.UndoDirectory) } else { @(Get-LegacyUndoRoots $Context | Where-Object { Test-Path -LiteralPath $_ }) }
    foreach ($unsafe in @($Context.CodexRoot, $Context.ClaudeRoot, $Context.CodexPackages, $Context.ClaudeVersions, $Context.ConfigPath) + @(Get-LegacyUndoRoots $Context) + $sources) {
        if ((Test-Within $target $unsafe) -or (Test-Within $unsafe $target)) { throw "Undo directory overlaps protected or existing storage: $unsafe" }
    }
    $ancestor = $target
    while (-not (Test-Path -LiteralPath $ancestor)) { $ancestor = Split-Path -Parent $ancestor }
    if (-not (Test-NoReparse $ancestor)) { throw 'Unsafe undo directory parent' }
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null }
    if (-not (Test-NoReparse $target)) { throw 'Unsafe undo directory' }
    $marker = Join-Path $target 'agent-purge-undo-v1.marker'
    if (-not (Test-Path -LiteralPath $marker) -and -not @(Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop).Count) {
        [IO.File]::WriteAllText($marker, 'agent-purge-undo-v1', [Text.Encoding]::ASCII)
    }
    Initialize-UndoRoot $target
    $migrationMarker = Join-Path $target '.agent-purge-migration-source'
    $sourceIdentity = (@($sources | Sort-Object) -join "`n")
    if (Test-Path -LiteralPath $migrationMarker) {
        if (-not (Test-NoReparse $migrationMarker) -or (Get-Content -LiteralPath $migrationMarker -Raw -ErrorAction Stop) -cne $sourceIdentity) {
            throw 'Undo destination belongs to another migration'
        }
    } else {
        if (@(Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop | Where-Object Name -ne 'agent-purge-undo-v1.marker').Count) {
            throw 'Undo destination already contains data; choose an empty folder'
        }
        [IO.File]::WriteAllText($migrationMarker, $sourceIdentity, [Text.Encoding]::UTF8)
    }
    $snapshots = @{}
    if ($config.UndoDirectory) {
        $snapshots[$config.UndoDirectory] = Copy-VerifiedUndoContents $config.UndoDirectory $target
    } else {
        foreach ($source in $sources) {
            $location = Join-Path (Join-Path $target 'locations') (Get-UndoRootKey $source)
            New-Item -ItemType Directory -Path (Split-Path -Parent $location) -Force -ErrorAction Stop | Out-Null
            if (-not (Test-Path -LiteralPath $location)) { New-Item -ItemType Directory -Path $location -ErrorAction Stop | Out-Null }
            if (-not (Test-NoReparse $location)) { throw 'Unsafe undo destination location' }
            $locationMarker = Join-Path $location 'agent-purge-undo-v1.marker'
            if (-not (Test-Path -LiteralPath $locationMarker) -and -not @(Get-ChildItem -LiteralPath $location -Force -ErrorAction Stop).Count) {
                [IO.File]::WriteAllText($locationMarker, 'agent-purge-undo-v1', [Text.Encoding]::ASCII)
            }
            $snapshots[$source] = Copy-VerifiedUndoContents $source $location
        }
        $manifestSource = Join-Path (Split-Path -Parent $Context.CodexRoot) '.agent-purge-undo'
        $oldRuns = Join-Path $manifestSource 'runs'
        if (Test-Path -LiteralPath $oldRuns) {
            $newRuns = Join-Path $target 'runs'
            if (-not (Test-Path -LiteralPath $newRuns)) { Copy-VerifiedPath $oldRuns $newRuns }
            if ((Get-PathFingerprint $oldRuns) -cne (Get-PathFingerprint $newRuns)) { throw 'Undo manifest copy differs from source' }
        }
    }
    if ($config.UndoDirectory) { $config.UndoHistory = @($config.UndoHistory) + @($config.UndoDirectory) }
    $config.UndoDirectory = $target
    Save-AgentPurgeConfig $Context $config
    foreach ($source in $sources) {
        if ((Test-Path -LiteralPath $source) -and (Get-PathFingerprint $source) -ceq $snapshots[$source]) {
            if (-not (Test-NoReparse $source $true)) { throw "Unsafe old undo folder: $source" }
            Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $source) {
            Write-Host "Old undo folder changed during migration; inspect and remove it manually: $source" -ForegroundColor Yellow
        }
    }
    if (Test-Path -LiteralPath $migrationMarker) { Remove-Item -LiteralPath $migrationMarker -Force -ErrorAction Stop }
    Write-Host "Undo folder set to $target. Existing undo data was verified at the new location."
}

function Get-UndoRunInventory($Context) {
    $root = Get-UndoManifestRoot $Context
    $result = [pscustomobject]@{ Runs = @(); Warnings = @() }
    if (-not (Test-Path -LiteralPath $root)) { return $result }
    Initialize-UndoRoot $root
    $runsPath = Join-Path $root 'runs'
    if (-not (Test-Path -LiteralPath $runsPath)) { return $result }
    if (-not (Test-NoReparse $runsPath)) { throw 'Unsafe undo manifest directory' }
    $runs = New-Object 'System.Collections.Generic.List[object]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in (Get-ChildItem -LiteralPath $runsPath -File -Filter '*.json' -ErrorAction Stop)) {
        try {
            if ($file.BaseName -cnotmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$' -or -not (Test-NoReparse $file.FullName)) { throw 'Invalid or unsafe manifest path' }
            $run = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($run.RunId -cne $file.BaseName -or $run.Hash -cne (Get-UndoHash $run) -or -not @($run.Entries).Count) { throw 'Invalid undo manifest' }
            $expires = Get-UndoExpiry $run
            $expired = $null -ne $expires -and $expires -le [datetimeoffset]::UtcNow
            $stored = New-Object 'System.Collections.Generic.List[object]'
            $payloadDirs = @{}
            [long]$bytes = $file.Length
            $incomplete = $false
            $occupied = 0
            $indices = @{}
            foreach ($entry in $run.Entries) {
                if ($entry.Index -isnot [int] -or $entry.Index -lt 0 -or $indices.ContainsKey($entry.Index)) { throw 'Invalid undo entry index' }
                $indices[$entry.Index] = $true
                $path = Resolve-UndoEntryPath $entry $run.RunId $Context
                $directory = Split-Path -Parent $path
                if (Test-Path -LiteralPath $directory -PathType Container) { $payloadDirs[$directory] = $true }
                if (Test-Path -LiteralPath $path) {
                    if (-not (Test-NoReparse $path $true)) { throw 'Unsafe saved undo entry' }
                    $size = Get-PathSize $path
                    $bytes += $size.Bytes
                    $incomplete = $incomplete -or $size.Incomplete
                    $stored.Add([pscustomobject]@{ Original = $entry.Original; Archived = $path; Bytes = $size.Bytes })
                    if (Test-Path -LiteralPath $entry.Original) { $occupied++ }
                }
            }
            $runs.Add([pscustomobject]@{
                Key = $run.RunId; Path = $file.FullName; Kind = 'UndoRun'; Eligible = -not $incomplete
                Bytes = $bytes; Incomplete = $incomplete; Run = $run; Stored = $stored.ToArray()
                PayloadDirs = @($payloadDirs.Keys | Sort-Object); OccupiedCount = $occupied; Expired = $expired
            })
            if ($incomplete) { $warnings.Add("$($file.Name): saved size is incomplete; this run cannot be cleaned automatically") }
        } catch { $warnings.Add("$($file.Name): $($_.Exception.Message)") }
    }
    $result.Runs = @($runs.ToArray() | Sort-Object { $_.Run.RunId } -Descending)
    $result.Warnings = $warnings.ToArray()
    return $result
}

function Show-UndoRunDetails($Item) {
    $page = 0
    $entries = @($Item.Run.Entries)
    while ($true) {
        $pageSize = Get-PageSize 10
        $pages = [math]::Max(1, [int][math]::Ceiling($entries.Count / $pageSize))
        $start = $page * $pageSize
        $end = [math]::Min($entries.Count, $start + $pageSize)
        Clear-Host
        Write-ScreenLine 'AGENT PURGE / SAVED UNDO RUN' Cyan
        Write-ScreenLine ("Run: $($Item.Run.RunId)") Cyan
        Write-ScreenLine ("Stored: $($Item.Stored.Count)/$($entries.Count) paths | $(Format-Bytes $Item.Bytes) logical | $($Item.OccupiedCount) occupied originals")
        if ($Item.Expired) { Write-ScreenLine 'Expired: automatic restore is unavailable; inspect saved files or Recycle Bin.' Yellow }
        else { Write-Host ("Restore: agent-purge restore {0} {1}" -f $Item.Run.RunId, $Item.Run.Hash) }
        Write-ScreenLine ('Original paths {0}-{1}/{2}' -f ($start + 1), $end, $entries.Count) DarkGray
        for ($i = $start; $i -lt $end; $i++) {
            $entry = $entries[$i]
            $stored = @($Item.Stored | Where-Object Original -eq $entry.Original).Count -gt 0
            Write-ScreenLine ('  {0} {1}' -f $(if ($stored) { 'saved' } else { 'missing/restored' }), $entry.Original)
        }
        Write-ScreenLine 'PgUp/PgDn browse | I show full original and saved paths'
        Write-ScreenLine 'Enter/B back | Esc quit'
        $key = Read-MenuKey
        if ($key -eq 'Escape') { return 'Exit' }
        if ($key -in @('Enter', 'B', 'Backspace')) { return 'Back' }
        if ($key -eq 'PageUp') { $page = [math]::Max(0, $page - 1) }
        if ($key -eq 'PageDown') { $page = [math]::Min($pages - 1, $page + 1) }
        if ($key -eq 'I') {
            Clear-Host
            for ($i = $start; $i -lt $end; $i++) {
                $entry = $entries[$i]
                $saved = @($Item.Stored | Where-Object Original -eq $entry.Original | Select-Object -First 1)
                Write-Host ("Original: $($entry.Original)")
                Write-Host ("Saved: $(if ($saved.Count) { $saved[0].Archived } else { 'not in undo folder' })")
            }
            Write-Host 'Press any key to return to run details.'
            if ((Read-MenuKey) -eq 'Escape') { return 'Exit' }
        }
    }
}

function Test-UndoRunPayload($Item, $Context, [string]$Directory) {
    Initialize-UndoRoot (Split-Path -Parent (Split-Path -Parent $Directory))
    if (-not (Test-NoReparse $Directory $true)) { throw 'Unsafe undo payload directory' }
    $expected = @($Item.Run.Entries | Where-Object { (Split-Path -Parent (Resolve-UndoEntryPath $_ $Item.Run.RunId $Context)) -eq $Directory } | ForEach-Object { [string]$_.Index })
    foreach ($child in (Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
        if ($child.Name -notin $expected -and $child.Name -ne 'agent-purge-manifest.json') { throw "Unexpected undo payload entry: $($child.Name)" }
    }
}

function Invoke-SelectedUndoCleanup($Context, $Items, [string]$Method) {
    $current = Get-UndoRunInventory $Context
    foreach ($item in $Items) {
        try {
            $now = @($current.Runs | Where-Object Key -eq $item.Key | Select-Object -First 1)
            if (-not $now.Count -or $now[0].Run.Hash -cne $item.Run.Hash -or
                (@($now[0].PayloadDirs) -join [char]0) -cne (@($item.PayloadDirs) -join [char]0)) { throw 'Undo run changed since review' }
            $run = $now[0]
            if ((Get-PathFingerprint $run.Path) -cne $item.ManifestFingerprint) { throw 'Undo manifest changed after confirmation' }
            foreach ($directory in $item.PayloadDirs) {
                if (-not (Test-Path -LiteralPath $directory)) { throw 'Undo payload changed after confirmation' }
                Test-UndoRunPayload $run $Context $directory
                if ((Get-PathFingerprint $directory) -cne $item.PayloadFingerprints[$directory]) { throw 'Undo payload changed after confirmation' }
            }
            foreach ($directory in $item.PayloadDirs) {
                if ($Method -eq 'Recycle Bin') {
                    $copy = Join-Path $directory 'agent-purge-manifest.json'
                    if (-not (Test-Path -LiteralPath $copy)) { [IO.File]::Copy($run.Path, $copy) }
                    elseif ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $run.Path -Algorithm SHA256).Hash) { throw 'Saved manifest copy differs' }
                }
                Invoke-FileRemoval $directory $Method
            }
            Invoke-FileRemoval $run.Path $Method
            Write-Host "OK $Method undo run $($run.Run.RunId)"
        } catch { Write-Host "FAIL undo run $($item.Key): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Invoke-UndoRunReview($Context, $Items) {
    $choice = Read-CleanupChoice 'REVIEW SAVED RUNS' $Items @('Choose cleanup method', 'Back to run list') 0 'Inspect individual runs with Enter in the list. Selected manifests and saved payloads will be removed together.'
    if ($choice -eq 'Exit') { return 'Exit' }
    if ($choice -ne 'Choose cleanup method') { return }
    $choice = Read-CleanupChoice 'CHOOSE UNDO CLEANUP METHOD' $Items @('Move selected runs to Recycle Bin (recommended)', 'Delete selected runs permanently', 'Back to run list') 0 'Recycle Bin retains manual recovery until emptied; permanent deletion cannot be reversed.'
    if ($choice -eq 'Exit') { return 'Exit' }
    if ($choice -in @('Back', 'Back to run list')) { return }
    $method = if ($choice -eq 'Delete selected runs permanently') { 'Permanent' } else { 'Recycle Bin' }
    if ($method -eq 'Permanent') {
        $warning = Read-CleanupChoice 'PERMANENT UNDO WARNING' $Items @('I understand selected runs cannot be restored', 'Back / keep undo runs') 1 'Permanent removal deletes the selected saved files and their restore manifests.'
        if ($warning -eq 'Exit') { return 'Exit' }
        if ($warning -ne 'I understand selected runs cannot be restored') { return }
    }
    Write-Host 'Verifying selected undo runs before final confirmation...'
    try {
        foreach ($item in $Items) {
            $item | Add-Member -NotePropertyName ManifestFingerprint -NotePropertyValue (Get-PathFingerprint $item.Path) -Force
            $fingerprints = @{}
            foreach ($directory in $item.PayloadDirs) {
                Test-UndoRunPayload $item $Context $directory
                $fingerprints[$directory] = Get-PathFingerprint $directory
            }
            $item | Add-Member -NotePropertyName PayloadFingerprints -NotePropertyValue $fingerprints -Force
        }
    } catch {
        Write-Host "Undo cleanup stopped before confirmation: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Press any key to return to saved runs.'
        if ((Read-MenuKey) -eq 'Escape') { return 'Exit' }
        return
    }
    $action = if ($method -eq 'Permanent') { 'Delete selected runs permanently' } else { 'Move selected runs to Recycle Bin' }
    $confirm = Read-CleanupChoice 'CONFIRM UNDO CLEANUP' $Items @($action, 'Back / keep undo runs') 1 'Only the selected runs will be removed. Other runs and undo folder markers stay in place.'
    if ($confirm -eq 'Exit') { return 'Exit' }
    if ($confirm -ne $action) { return }
    $spaceItems = @($Items | ForEach-Object {
        [pscustomobject]@{ Path = $_.Path }
        foreach ($directory in $_.PayloadDirs) { [pscustomobject]@{ Path = $directory } }
    })
    $before = Get-FreeSpace $spaceItems
    Invoke-SelectedUndoCleanup $Context $Items $method
    $after = Get-FreeSpace $spaceItems
    foreach ($root in $before.Keys) {
        if ($after.ContainsKey($root)) {
            $delta = [long]($after[$root] - $before[$root])
            Write-Host ("Free space {0}: {1} ({2})" -f $root, (Format-Bytes $after[$root]), $(if ($delta -ge 0) { '+' + (Format-Bytes $delta) } else { Format-Bytes $delta }))
        }
    }
    if ($method -eq 'Recycle Bin') { Write-Host 'Recycle Bin still uses disk space until emptied.' }
    Write-Host 'Press any key to return to saved runs.'
    if ((Read-MenuKey) -eq 'Escape') { return 'Exit' }
}

function Invoke-UndoFolderCleanup($Context) {
    if (-not (Test-InteractiveTerminal)) { throw 'Undo cleanup requires an interactive terminal' }
    $inventory = Get-UndoRunInventory $Context
    $items = @($inventory.Runs)
    if (-not $items.Count) {
        Write-Host 'No saved undo runs found. Other or invalid undo data was not changed.'
        foreach ($warning in $inventory.Warnings) { Write-Host $warning -ForegroundColor Yellow }
        Write-Host 'Press any key to return to settings.'
        if ((Read-MenuKey) -eq 'Escape') { return 'Exit' }
        return
    }
    $selected = @{}
    $index = 0
    $notice = ''
    while ($true) {
        $index = [math]::Min($index, $items.Count + 2)
        $summary = Get-InventorySummary $items $selected
        $limit = Get-PageSize 13
        $focusedRun = $index - 1
        $start = [math]::Max(0, $focusedRun - $limit + 1)
        Clear-Host
        Write-ScreenLine 'AGENT PURGE / CLEAN SAVED UNDO RUNS' Cyan
        Write-ScreenLine ('Selected: {0}/{1} eligible runs | {2} logical' -f $summary.SelectedCount, $summary.EligibleCount, (Format-Bytes $summary.SelectedBytes)) Cyan
        Write-ScreenLine 'Each run contains saved files and a restore manifest. Deleting it ends automatic restore.' Yellow
        if ($inventory.Warnings.Count) { Write-ScreenLine ("$($inventory.Warnings.Count) run(s) need manual review and were left untouched.") Yellow }
        Write-ScreenLine ''
        Write-ScreenLine ('{0} {1} Select all runs' -f $(if ($index -eq 0) { '>' } else { ' ' }), (Get-SelectionMark $items $selected)) $(if ($index -eq 0) { 'White' } else { 'Gray' })
        for ($i = $start; $i -lt [math]::Min($items.Count, $start + $limit); $i++) {
            $item = $items[$i]
            $shortId = $item.Run.RunId.Substring(0, 16) + '-' + $item.Run.RunId.Substring(17, 8)
            Write-ScreenLine ('{0} {1} {2,9} | {3} | {4}/{5} saved{6}' -f $(if ($index -eq $i + 1) { '>' } else { ' ' }), (Get-SelectionMark @($item) $selected), (Format-Bytes $item.Bytes), $shortId, $item.Stored.Count, @($item.Run.Entries).Count, $(if ($item.Expired) { ' (expired)' } else { '' })) $(if ($index -eq $i + 1) { 'White' } else { 'Gray' })
        }
        Write-ScreenLine ('{0} Review selected runs' -f $(if ($index -eq $items.Count + 1) { '>' } else { ' ' })) $(if ($index -eq $items.Count + 1) { 'White' } else { 'Gray' })
        Write-ScreenLine ('{0} Back / keep undo data' -f $(if ($index -eq $items.Count + 2) { '>' } else { ' ' })) $(if ($index -eq $items.Count + 2) { 'White' } else { 'Gray' })
        Write-ScreenLine $notice Yellow
        Write-ScreenLine 'Up/Down move | Space toggle | A select/clear all | Enter inspect/review'
        Write-ScreenLine 'D review | I inspect | PgUp/PgDn jump | B back | Esc quit'
        $notice = ''
        $key = Read-MenuKey
        if ($key -eq 'Escape') { return 'Exit' }
        if ($key -in @('B', 'Backspace')) { return }
        if ($key -eq 'UpArrow') { $index = ($index + $items.Count + 2) % ($items.Count + 3); continue }
        if ($key -eq 'DownArrow') { $index = ($index + 1) % ($items.Count + 3); continue }
        if ($key -eq 'Home') { $index = 0; continue }
        if ($key -eq 'End') { $index = $items.Count + 2; continue }
        if ($key -eq 'PageUp') { $index = [math]::Max(0, $index - $limit); continue }
        if ($key -eq 'PageDown') { $index = [math]::Min($items.Count + 2, $index + $limit); continue }
        if ($key -eq 'A' -or ($key -eq 'Spacebar' -and $index -eq 0)) { Switch-ItemSelection $items $selected; continue }
        if ($key -eq 'Spacebar' -and $index -ge 1 -and $index -le $items.Count) { Switch-ItemSelection @($items[$index - 1]) $selected; continue }
        if ($key -eq 'I' -or ($key -eq 'Enter' -and $index -ge 1 -and $index -le $items.Count)) {
            if ($index -ge 1 -and $index -le $items.Count -and (Show-UndoRunDetails $items[$index - 1]) -eq 'Exit') { return 'Exit' }
            continue
        }
        if ($key -eq 'Enter' -and $index -eq $items.Count + 2) { return }
        if ($key -eq 'D' -or ($key -eq 'Enter' -and ($index -eq 0 -or $index -eq $items.Count + 1))) {
            if ($index -eq 0 -and $key -eq 'Enter' -and $summary.SelectedCount -lt $summary.EligibleCount) { Switch-ItemSelection $items $selected }
            $chosen = @(Get-SelectedItems $items $selected)
            if (-not $chosen.Count) { $notice = 'Nothing selected. Use Space on a run or the select-all row.'; continue }
            if ((Invoke-UndoRunReview $Context $chosen) -eq 'Exit') { return 'Exit' }
            $inventory = Get-UndoRunInventory $Context
            $items = @($inventory.Runs)
            $valid = @{}
            foreach ($item in $items) { $valid[$item.Key] = $true }
            foreach ($key in @($selected.Keys)) { if (-not $valid.ContainsKey($key)) { $selected.Remove($key) } }
            if (-not $items.Count) { Write-Host 'No selectable saved runs remain. Invalid data, if any, was left untouched. Press any key to return to settings.'; [void](Read-MenuKey); return }
        }
    }
}

function Move-VerifiedPath([string]$Source, [string]$Destination) {
    if (-not (Test-NoReparse $Source $true) -or -not (Test-NoReparse (Split-Path -Parent $Destination)) -or (Test-Path -LiteralPath $Destination)) {
        throw 'Unsafe, missing, or occupied move path'
    }
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ([IO.Path]::GetPathRoot($Source) -eq [IO.Path]::GetPathRoot($Destination)) {
        if ($item.PSIsContainer) { [IO.Directory]::Move($Source, $Destination) }
        else { [IO.File]::Move($Source, $Destination) }
        return
    }
    Copy-VerifiedPath $Source $Destination
    Remove-Item -LiteralPath $Source -Force -Recurse -ErrorAction Stop
}

function Invoke-UndoMove([string]$Original, [string]$Archived) {
    $parent = Split-Path -Parent $Archived
    $payload = Split-Path -Parent $parent
    $root = Split-Path -Parent $payload
    if (-not (Test-NoReparse $root) -or ((Test-Path -LiteralPath $payload) -and -not (Test-NoReparse $payload)) -or
        ((Test-Path -LiteralPath $parent) -and -not (Test-NoReparse $parent))) { throw 'Unsafe undo destination' }
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    if (-not (Test-NoReparse $parent) -or (Test-Path -LiteralPath $Archived)) { throw 'Unsafe or occupied undo destination' }
    Move-VerifiedPath $Original $Archived
}

function Invoke-UndoCompress([string]$Archived) {
    $volume = [IO.Path]::GetPathRoot($Archived)
    if (([IO.DriveInfo]::new($volume)).DriveFormat -ne 'NTFS' -or -not (Get-Command compact.exe -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-NoReparse $Archived $true)) { throw 'Unsafe archived path before compression' }
    if (Test-Path -LiteralPath $Archived -PathType Container) {
        & compact.exe /C /Q /A ('/S:' + $Archived) *> $null
    } else {
        & compact.exe /C /Q /A $Archived *> $null
    }
    return $LASTEXITCODE -eq 0
}

function Get-UndoExpiry($Run) {
    if (-not $Run.PSObject.Properties['ExpiresAtUtc']) { return $null }
    [datetimeoffset]$expires = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Run.ExpiresAtUtc, [ref]$expires)) { throw 'Invalid undo run deadline' }
    return $expires
}

function Invoke-ExpiredUndoRun($Context, $Run, [string]$ManifestPath, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $expires = Get-UndoExpiry $Run
    if ($null -eq $expires -or $expires -gt $Now) { return [pscustomobject]@{ Moved = 0; Skipped = 0 } }
    $moved = 0; $skipped = 0
    $name = 'agent-purge-' + $Run.RunId + '-' + $Run.Hash.Substring(0, 12)
    $roots = @{}
    $config = Get-AgentPurgeConfig $Context
    foreach ($entry in $Run.Entries) {
        $root = Get-UndoRootForPath $entry.Original $Context $entry.Provider $config
        [void](Resolve-UndoEntryPath $entry $Run.RunId $Context $config)
        $roots[$root] = $true
    }
    $byVolume = @{}
    foreach ($root in $roots.Keys) {
        $volume = [IO.Path]::GetPathRoot($root)
        if (-not $byVolume.ContainsKey($volume)) { $byVolume[$volume] = New-Object 'System.Collections.Generic.List[string]' }
        $byVolume[$volume].Add($root)
    }
    foreach ($volume in $byVolume.Keys) {
        $volumeRoots = @($byVolume[$volume] | Sort-Object)
        $anchor = $volumeRoots[0]
        $bundle = Join-Path (Join-Path $anchor 'expired') $name
        try {
            if (-not (Test-Path -LiteralPath $anchor)) { throw 'Undo location is missing' }
            Initialize-UndoRoot $anchor
            $hasPayload = Test-Path -LiteralPath $bundle -PathType Container
            foreach ($root in $volumeRoots) {
                $source = Join-Path (Join-Path $root 'payload') $Run.RunId
                $oldNamed = Join-Path (Join-Path $root 'payload') $name
                if ((Test-Path -LiteralPath $oldNamed -PathType Container) -or
                    ((Test-Path -LiteralPath $source -PathType Container) -and @(Get-ChildItem -LiteralPath $source -Force -ErrorAction Stop).Count)) { $hasPayload = $true }
            }
            if (-not $hasPayload) { continue }
            $expired = Split-Path -Parent $bundle
            if ((Test-Path -LiteralPath $expired) -and -not (Test-NoReparse $expired)) { throw 'Unsafe expired-run folder' }
            if ((Test-Path -LiteralPath $bundle) -and -not (Test-NoReparse $bundle)) { throw 'Unsafe expired-run bundle' }
            New-Item -ItemType Directory -Path $bundle -Force -ErrorAction Stop | Out-Null
            if (-not (Test-NoReparse $bundle)) { throw 'Unsafe expired-run bundle' }
            $copy = Join-Path $bundle 'agent-purge-manifest.json'
            if (Test-Path -LiteralPath $copy) {
                if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash) { throw 'Expired-run manifest differs from the run manifest' }
            } else { [IO.File]::Copy($ManifestPath, $copy) }
            for ($i = 0; $i -lt $volumeRoots.Count; $i++) {
                $root = $volumeRoots[$i]
                if (-not (Test-Path -LiteralPath $root)) { throw "Undo location is missing: $root" }
                Initialize-UndoRoot $root
                $source = Join-Path (Join-Path $root 'payload') $Run.RunId
                $oldNamed = Join-Path (Join-Path $root 'payload') $name
                $part = Join-Path $bundle ("part-$i")
                $sourceExists = Test-Path -LiteralPath $source -PathType Container
                $oldExists = Test-Path -LiteralPath $oldNamed -PathType Container
                if (([int]$sourceExists + [int]$oldExists + [int](Test-Path -LiteralPath $part -PathType Container)) -gt 1) { throw "Conflicting undo folders at $root" }
                if (Test-Path -LiteralPath $part -PathType Container) { continue }
                $from = if ($oldExists) { $oldNamed } else { $source }
                if (-not (Test-Path -LiteralPath $from -PathType Container)) { continue }
                if (-not (Test-NoReparse $from $true)) { throw "Unsafe undo folder contents at $root" }
                $children = @(Get-ChildItem -LiteralPath $from -Force -ErrorAction Stop)
                if (-not $children.Count) { continue }
                $expectedNames = @($Run.Entries | Where-Object { (Split-Path -Parent (Resolve-UndoEntryPath $_ $Run.RunId $Context $config)) -eq $source } | ForEach-Object { [string]$_.Index })
                foreach ($child in $children) {
                    if ($child.Name -notin $expectedNames -and $child.Name -ne 'agent-purge-manifest.json') { throw "Unexpected undo folder entry: $($child.Name)" }
                }
                [IO.Directory]::Move($from, $part)
            }
            $parts = @(Get-ChildItem -LiteralPath $bundle -Directory -Filter 'part-*' -ErrorAction Stop)
            if (-not $parts.Count) { continue }
            $allowed = @('agent-purge-manifest.json') + @(0..($volumeRoots.Count - 1) | ForEach-Object { "part-$_" })
            foreach ($child in (Get-ChildItem -LiteralPath $bundle -Force -ErrorAction Stop)) {
                if ($child.Name -notin $allowed) { throw "Unexpected expired-run bundle entry: $($child.Name)" }
            }
            if (-not (Test-NoReparse $bundle $true)) { throw 'Unsafe expired-run bundle contents' }
            Invoke-FileRemoval $bundle 'Recycle Bin'
            $moved++
            Write-Host "Expired undo run $($Run.RunId): moved $name to the Recycle Bin from $volume."
        } catch { $skipped++; Write-Host "Expiry skipped for $($Run.RunId) on $volume`: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    return [pscustomobject]@{ Moved = $moved; Skipped = $skipped }
}

function Invoke-ExpiredUndoRuns($Context, [datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $moved = 0; $skipped = 0
    $root = Get-UndoManifestRoot $Context
    if (-not (Test-Path -LiteralPath $root)) { return [pscustomobject]@{ Moved = 0; Skipped = 0 } }
    Initialize-UndoRoot $root
    $runs = Join-Path $root 'runs'
    if (-not (Test-Path -LiteralPath $runs)) { return [pscustomobject]@{ Moved = 0; Skipped = 0 } }
    if (-not (Test-NoReparse $runs)) { throw 'Unsafe undo manifest directory' }
    foreach ($file in (Get-ChildItem -LiteralPath $runs -File -Filter '*.json' -ErrorAction Stop)) {
        try {
            if (-not (Test-NoReparse $file.FullName)) { throw 'Unsafe undo manifest' }
            $run = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($run.RunId -cne $file.BaseName -or $run.Hash -cne (Get-UndoHash $run)) { throw 'Undo manifest hash mismatch' }
            $result = Invoke-ExpiredUndoRun $Context $run $file.FullName $Now
            $moved += $result.Moved; $skipped += $result.Skipped
        } catch { $skipped++; Write-Host "Expiry skipped for $($file.Name): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    return [pscustomobject]@{ Moved = $moved; Skipped = $skipped }
}

function Show-ExpiryCheck($Context) {
    try { $result = Invoke-ExpiredUndoRuns $Context }
    catch { Write-Host "Undo expiry check failed: $($_.Exception.Message)" -ForegroundColor Yellow; $result = [pscustomobject]@{ Moved = 0; Skipped = 1 } }
    if ($result.Moved -or $result.Skipped) {
        Write-Host "Undo expiry: $($result.Moved) folder(s) moved to Recycle Bin; $($result.Skipped) skipped."
        Write-Host 'Press any key to continue, or Esc to quit.'
        if ((Read-MenuKey) -eq 'Escape') { return 'Exit' }
    }
    return 'Continue'
}

function Invoke-UndoRestore($Context, [string]$RunId, [string]$Hash) {
    if ($RunId -cnotmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$' -or $Hash -cnotmatch '^[0-9A-F]{64}$') { throw 'Invalid run ID or restore hash format' }
    $config = Get-AgentPurgeConfig $Context
    $root = Get-UndoManifestRoot $Context $config
    if (-not (Test-Path -LiteralPath $root)) { throw 'Undo folder not found' }
    Initialize-UndoRoot $root
    $manifest = Join-Path (Join-Path $root 'runs') ($RunId + '.json')
    if (-not (Test-NoReparse $manifest)) { throw 'Unsafe undo manifest path' }
    $run = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($run.RunId -cne $RunId -or $run.Hash -cne $Hash -or (Get-UndoHash $run) -cne $Hash) { throw 'Restore hash does not match this undo run' }
    $expires = Get-UndoExpiry $run
    if ($null -ne $expires -and $expires -le [datetimeoffset]::UtcNow) {
        [void](Invoke-ExpiredUndoRun $Context $run $manifest)
        throw 'This undo run has expired. Check its named folder in the undo location or Windows Recycle Bin for manual recovery.'
    }
    $restored = 0; $skipped = 0
    foreach ($entry in $run.Entries) {
        try {
            $archiveRoot = Get-UndoRootForPath $entry.Original $Context $entry.Provider $config
            $archivedPath = Resolve-UndoEntryPath $entry $RunId $Context $config
            Initialize-UndoRoot $archiveRoot
            if (-not (Test-Path -LiteralPath $archivedPath)) { $skipped++; Write-Host "SKIP not archived: $($entry.Original)"; continue }
            if (Test-Path -LiteralPath $entry.Original) { throw 'Original path already exists; no overwrite' }
            if (-not (Test-AppClosed $entry.Provider)) { throw "Close $($entry.Provider) before restore" }
            if (-not (Test-NoReparse $archivedPath $true) -or -not (Test-NoReparse (Split-Path -Parent $entry.Original))) { throw 'Reparse point, missing parent, or unreadable path' }
            Move-VerifiedPath $archivedPath $entry.Original
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

function Read-CleanupChoice([string]$Heading, $Items, [string[]]$Options, [int]$DefaultIndex = 0, [string]$Description = '', [string[]]$UndoRoots = @()) {
    $paths = @($Items | ForEach-Object {
        if ($_.Kind -eq 'CodexSession') { 'codex delete {0} | {1}' -f $_.Id, $_.Path }
        else { Get-ItemPaths $_ }
    })
    $summary = Get-InventorySummary $Items
    $index = $DefaultIndex; $page = 0
    while ($true) {
        $pageSize = Get-PageSize (9 + $Options.Count + $UndoRoots.Count)
        $pages = [math]::Max(1, [int][math]::Ceiling($paths.Count / $pageSize))
        $page = [math]::Min($page, $pages - 1)
        $start = $page * $pageSize
        $end = [math]::Min($paths.Count, $start + $pageSize)
        Clear-Host
        Write-ScreenLine ('AGENT PURGE / ' + $Heading) Cyan
        $itemLabel = if ($summary.Count -eq 1) { 'item' } else { 'items' }
        Write-ScreenLine ('Selected: {0} {1} | {2} estimated logical size' -f $summary.Count, $itemLabel, (Format-Bytes $summary.Bytes)) Cyan
        if ($Description) { Write-ScreenLine $Description Yellow }
        foreach ($root in $UndoRoots) { Write-ScreenLine ("Undo folder: $root") Cyan }
        Write-ScreenLine ('Exact paths {0}-{1}/{2} | PgUp/PgDn browse | I show full paths' -f ($start + [int]($paths.Count -gt 0)), $end, $paths.Count) DarkGray
        for ($i = $start; $i -lt $end; $i++) { Write-ScreenLine ('  ' + $paths[$i]) }
        Write-ScreenLine ''
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-ScreenLine ('{0} {1}' -f $(if ($i -eq $index) { '>' } else { ' ' }), $Options[$i]) $(if ($i -eq $index) { 'White' } else { 'Gray' })
        }
        Write-ScreenLine 'Up/Down choose | Enter/Space select | B back | Esc/Ctrl+C twice quit'
        $key = Read-MenuKey
        switch ($key) {
            'Escape' { return 'Exit' }
            { $_ -in @('B', 'Backspace') } { return 'Back' }
            'UpArrow' { $index = ($index + $Options.Count - 1) % $Options.Count }
            'DownArrow' { $index = ($index + 1) % $Options.Count }
            'PageUp' { $page = [math]::Max(0, $page - 1) }
            'PageDown' { $page = [math]::Min($pages - 1, $page + 1) }
            'I' {
                Clear-Host
                Write-Host ("Exact selected paths $($start + 1)-$end/$($paths.Count):")
                for ($i = $start; $i -lt $end; $i++) { Write-Host $paths[$i] }
                Write-Host 'Press any key to return to choices.'
                if ((Read-MenuKey) -eq 'Escape') { return 'Exit' }
            }
            { $_ -in @('Enter', 'Spacebar') } { return $Options[$index] }
        }
    }
}

function Invoke-Cleanup($Items, $Context, [bool]$Advanced = $false) {
    $selected = @($Items | Where-Object Eligible)
    if (-not $selected.Count) { Write-Host 'Nothing selected.'; return }
    $files = @($selected | Where-Object Kind -ne 'CodexSession')
    $codex = @($selected | Where-Object Kind -eq 'CodexSession')
    $review = Read-CleanupChoice 'REVIEW SELECTION' $selected @('Continue to cleanup methods', 'Back to selection') 0 'Review every exact path before choosing a method. No files have moved.'
    if ($review -eq 'Exit') { return 'Exit' }
    if ($review -ne 'Continue to cleanup methods') { return }
    $confirmFiles = $false; $confirmCodex = $false
    $preview = @{}
    $before = Get-FreeSpace $selected
    if ($files.Count) {
        while ($true) {
            $choice = Read-CleanupChoice 'CHOOSE FILE METHOD' $files @('Compressed undo folder (recommended)', 'Recycle Bin', 'Permanent', 'Keep files (skip this batch)', 'Back to selection') 0 'This method applies only to files, not Codex sessions. Undo uses NTFS compression when available.'
            if ($choice -eq 'Exit') { return 'Exit' }
            if ($choice -in @('Back', 'Back to selection')) { return }
            if ($choice -eq 'Keep files (skip this batch)') { break }
            $method = if ($choice -eq 'Compressed undo folder (recommended)') { 'Undo folder' } else { $choice }
            foreach ($item in $files) {
                $preview[$item.Key] = @(Get-ItemPaths $item)
            }
            if ($method -eq 'Permanent') {
                $ack = Read-CleanupChoice 'PERMANENT FILE WARNING' $files @('I understand these files cannot be restored', 'Change file method', 'Keep files (cancel this batch)') 2 'Permanent removal has no restore command or Recycle Bin recovery.'
                if ($ack -eq 'Exit') { return 'Exit' }
                if ($ack -eq 'Back') { return }
                if ($ack -eq 'Change file method') { continue }
                if ($ack -ne 'I understand these files cannot be restored') { break }
            }
            $action = if ($method -eq 'Undo folder') { 'Move to compressed undo folder' } elseif ($method -eq 'Recycle Bin') { 'Move to Recycle Bin' } else { 'Delete files permanently' }
            $undoRoots = if ($method -eq 'Undo folder') { @( $files | ForEach-Object { Get-UndoRootForPath $_.Path $Context $_.Provider } | Sort-Object -Unique ) } else { @() }
            $answer = Read-CleanupChoice 'CONFIRM FILE CLEANUP' $files @($action, 'Change file method', 'Keep files (cancel this batch)') 2 ("Choose $action or keep these files. Codex is separate.") $undoRoots
            if ($answer -eq 'Exit') { return 'Exit' }
            if ($answer -eq 'Back') { return }
            if ($answer -eq 'Change file method') { continue }
            $confirmFiles = $answer -eq $action
            break
        }
    }
    if ($codex.Count) {
        $ack = Read-CleanupChoice 'PERMANENT CODEX WARNING' $codex @('I understand Codex sessions cannot be restored', 'Cancel Codex batch') 1 'Codex sessions were not moved to undo. Delete changes provider records and cannot be restored here.'
        if ($ack -eq 'Exit') { return 'Exit' }
        if ($ack -eq 'Back') { return }
        if ($ack -eq 'I understand Codex sessions cannot be restored') {
            $answer = Read-CleanupChoice 'CONFIRM CODEX DELETION' $codex @('Delete Codex sessions permanently', 'Cancel Codex batch') 1 'Cancel is the default. Only the focused permanent action authorizes Codex deletion.'
            if ($answer -eq 'Exit') { return 'Exit' }
            if ($answer -eq 'Back') { return }
            $confirmCodex = $answer -eq 'Delete Codex sessions permanently'
        }
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
                    if ($undoRun) {
                        $archived = $undoPaths[(Get-FullPath $path)]
                        Invoke-UndoMove $path $archived
                        try {
                            if (-not (Invoke-UndoCompress $archived)) { Write-Host "NOTE Undo copy remains uncompressed: $archived" }
                        } catch { Write-Host "NOTE Compression unavailable for $archived`: $($_.Exception.Message)" }
                    }
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
        foreach ($root in @($undoRun.Entries | ForEach-Object { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $_.Archived)) } | Sort-Object -Unique)) {
            Write-Host "Undo folder: $root"
            Write-Host ("This run's stored files: {0}" -f (Join-Path (Join-Path $root 'payload') $undoRun.RunId))
        }
        Write-Host ("Undo manifest: {0}" -f (Join-Path (Join-Path (Get-UndoManifestRoot $Context) 'runs') ($undoRun.RunId + '.json')))
        Write-Host 'Undo files still use disk space. Inventory shows logical size, which does not shrink with NTFS compression; check free-space change or Size on disk for savings. Codex deletions are not part of this restore.'
    }
    $after = Get-FreeSpace $selected
    foreach ($root in $before.Keys) {
        if ($after.ContainsKey($root)) {
            $delta = [long]($after[$root] - $before[$root])
            $change = if ($delta -ge 0) { '+' + (Format-Bytes $delta) } else { Format-Bytes $delta }
            Write-Host ("Free space {0}: {1} -> {2} ({3})" -f $root, (Format-Bytes $before[$root]), (Format-Bytes $after[$root]), $change)
        }
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
    if ($null -ne $script:MenuFrame) {
        $script:MenuFrame.Add([pscustomobject]@{ Text = $clean; Color = $Color })
        return
    }
    Write-Host $clean -ForegroundColor $Color
}

function Show-MenuFrame {
    $frame = $script:MenuFrame
    $script:MenuFrame = $null
    $size = Get-TerminalSize
    $repaint = $false
    try {
        $repaint = -not [Console]::IsOutputRedirected -and $Host.Name -eq 'ConsoleHost' -and
            [Console]::BufferWidth -ge $size.Width -and [Console]::WindowHeight -ge $frame.Count
    } catch { }
    if (-not $repaint) {
        Clear-Host
        foreach ($line in $frame) { Write-Host $line.Text -ForegroundColor $line.Color }
        $script:PreviousMenuFrame = $null
        return
    }
    try {
        if ($null -eq $script:PreviousMenuFrame -or $script:PreviousMenuWidth -ne $size.Width) {
            [Console]::Clear()
            $script:PreviousMenuFrame = @()
        }
        $oldCount = @($script:PreviousMenuFrame).Count
        for ($i = 0; $i -lt [math]::Max($frame.Count, $oldCount); $i++) {
            $line = if ($i -lt $frame.Count) { $frame[$i] } else { [pscustomobject]@{ Text = ''; Color = [ConsoleColor]::Gray } }
            if ($i -lt $oldCount -and $line.Text -ceq $script:PreviousMenuFrame[$i].Text -and $line.Color -eq $script:PreviousMenuFrame[$i].Color) { continue }
            [Console]::SetCursorPosition(0, $i)
            [Console]::ForegroundColor = $line.Color
            [Console]::Write($line.Text.PadRight($size.Width - 1))
        }
        [Console]::ResetColor()
        [Console]::SetCursorPosition(0, [math]::Min($frame.Count, $size.Height - 1))
        $script:PreviousMenuFrame = @($frame.ToArray())
        $script:PreviousMenuWidth = $size.Width
    } catch {
        [Console]::ResetColor()
        $script:PreviousMenuFrame = $null
        Clear-Host
        foreach ($line in $frame) { Write-Host $line.Text -ForegroundColor $line.Color }
    }
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
    if ($attempted -is [string] -and $attempted -ceq 'Exit') { return 'Exit' }
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
    $groups = @(Get-ProjectGroups $Session.Items)
    $breakdowns = @{}
    foreach ($group in $groups) { $breakdowns[$group.Key] = @((Format-SizeDistribution $group.Items Provider)) + @((Format-SizeDistribution $group.Items Category)) }
    $script:PreviousMenuFrame = $null
    while ($true) {
        $index = [math]::Min($index, [math]::Max(-1, $groups.Count - 1))
        $script:MenuFrame = New-Object 'System.Collections.Generic.List[object]'
        $mode = if ($Session.Advanced) { ' / ADVANCED' } else { '' }
        Write-ScreenLine ('AGENT PURGE / CHOOSE PROJECTS TO CLEAN' + $mode) Cyan
        Write-ScreenLine 'Which projects have agent history you no longer need?'
        Write-ScreenLine 'Space toggles eligible items in a project. Enter reviews your selection.'
        Write-ScreenLine 'Projects use recorded working directories; shared storage is listed separately.' DarkGray
        Write-SelectionSummary $Session.Items $Session.Selected
        Write-ScreenLine ''
        $allMark = Get-SelectionMark $Session.Items $Session.Selected
        Write-ScreenLine ('{0} {1} Select all eligible items' -f $(if ($index -eq -1) { '>' } else { ' ' }), $allMark) $(if ($index -eq -1) { 'White' } else { 'Gray' })
        $breakdown = @()
        if ($groups.Count -and $index -ge 0) {
            $focus = $groups[$index]
            $breakdown = $breakdowns[$focus.Key]
        }
        $limit = Get-PageSize (17 + $breakdown.Count)
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
        elseif ($index -eq -1) { Write-ScreenLine 'Space selects/clears all eligible items. Enter reviews the selection.' Cyan }
        else {
            Write-ScreenLine ('Project/group {0}/{1} | [x] selected  [~] partly selected  [-] inspect only' -f ($index + 1), $groups.Count) DarkGray
            Write-ScreenLine ('Focused: ' + (Format-ProjectLabel $focus.Label ((Get-TerminalSize).Width - 10))) Cyan
            Write-ScreenLine ('{0} items | {1} eligible for cleanup' -f $focus.Summary.Count, (Format-Bytes $focus.Summary.EligibleBytes))
            Write-ScreenLine ('Your selection here: {0} of {1} eligible items' -f (Get-InventorySummary $focus.Items $Session.Selected).SelectedCount, $focus.Summary.EligibleCount)
            foreach ($line in $breakdown) { Write-ScreenLine ('  ' + $line) }
        }
        Write-ScreenLine $notice Yellow
        Write-ScreenLine 'Up/Down move | PgUp/PgDn jump | Home/End ends | Space toggle'
        Write-ScreenLine 'F find project | A select/clear all | I inspect'
        Write-ScreenLine 'Enter review cleanup | B/Backspace back | Esc/Ctrl+C twice quit'
        Show-MenuFrame
        $notice = ''
        $key = Read-MenuKey
        switch ($key) {
            'Escape' { $script:PreviousMenuFrame = $null; return 'Exit' }
            { $_ -in @('B', 'Backspace') } { $script:PreviousMenuFrame = $null; return 'Back' }
            'UpArrow' { if ($groups.Count) { $index = if ($index -eq -1) { $groups.Count - 1 } else { $index - 1 } } }
            'DownArrow' { if ($groups.Count) { $index = if ($index -eq $groups.Count - 1) { -1 } else { $index + 1 } } }
            'PageUp' { $index = [math]::Max(-1, $index - (Get-PageSize (17 + $breakdown.Count))) }
            'PageDown' { $index = [math]::Min([math]::Max(-1, $groups.Count - 1), $index + (Get-PageSize (17 + $breakdown.Count))) }
            'Home' { $index = -1 }
            'End' { $index = [math]::Max(0, $groups.Count - 1) }
            'F' {
                $query = (Read-Host 'Find project name or path').Trim()
                $script:PreviousMenuFrame = $null
                if ($query) {
                    $match = @($groups | Where-Object { $_.Label.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1)
                    if ($match.Count) { $index = [array]::IndexOf($groups, $match[0]) }
                    else { $notice = 'No project matches that search.' }
                }
            }
            'Spacebar' {
                if ($index -eq -1) { Switch-ItemSelection $Session.Items $Session.Selected }
                elseif ($groups.Count) {
                    Switch-ItemSelection $groups[$index].Items $Session.Selected
                    if (-not $groups[$index].Summary.EligibleCount) { $notice = 'This group is inspection only. Press I to see why.' }
                }
            }
            'A' { Switch-ItemSelection $Session.Items $Session.Selected }
            { $_ -in @('I', 'RightArrow') } {
                if ($index -ge 0 -and $groups.Count -and (Invoke-InventoryUI $Session $groups[$index].Key) -eq 'Exit') { return 'Exit' }
                $script:PreviousMenuFrame = $null
            }
            { $_ -in @('Enter', 'D') } {
                if ($key -eq 'Enter' -and $index -eq -1) {
                    $summary = Get-InventorySummary $Session.Items $Session.Selected
                    if ($summary.SelectedCount -lt $summary.EligibleCount) { Switch-ItemSelection $Session.Items $Session.Selected }
                }
                if (@(Get-SelectedItems $Session.Items $Session.Selected).Count) {
                    if ((Invoke-SelectionCleanup $Session) -eq 'Exit') { return 'Exit' }
                    $groups = @(Get-ProjectGroups $Session.Items)
                    $breakdowns = @{}
                    foreach ($group in $groups) { $breakdowns[$group.Key] = @((Format-SizeDistribution $group.Items Provider)) + @((Format-SizeDistribution $group.Items Category)) }
                    $script:PreviousMenuFrame = $null
                }
                else { $notice = 'Nothing selected. Use Space on a project, or A to select all eligible items.' }
            }
        }
    }
}

function Invoke-InventoryUI($Session, [string]$GroupKey = '') {
    $state = [pscustomobject]@{ Level = 0; Provider = ''; Category = ''; Index = 0; DetailKey = '' }
    $selected = $Session.Selected
    $selectAllFocused = $false
    $notice = ''
    while ($true) {
        $Items = $Session.Items
        if ($GroupKey) {
            $group = Get-ProjectGroups $Session.Items | Where-Object Key -eq $GroupKey | Select-Object -First 1
            $Items = if ($group) { @($group.Items) } else { @() }
        }
        $rows = @(Get-ViewRows $Items $state)
        $viewItems = switch ($state.Level) {
            0 { $Items }
            1 { $Items | Where-Object Provider -eq $state.Provider }
            2 { $rows }
            3 { $Items | Where-Object Key -eq $state.DetailKey }
        }
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
        if ($state.Level -lt 3) {
            $allMark = Get-SelectionMark $viewItems $selected
            Write-ScreenLine ('{0} {1} Select all eligible items in this view' -f $(if ($selectAllFocused) { '>' } else { ' ' }), $allMark) $(if ($selectAllFocused) { 'White' } else { 'Gray' })
        }
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
            $limit = Get-PageSize 12
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
        Write-ScreenLine ('Up/Down move | PgUp/PgDn jump | Home/End ends | Enter ' + $(if ($selectAllFocused) { 'review' } else { 'open' }))
        Write-ScreenLine 'Space toggle | A select/clear this view'
        Write-ScreenLine 'D review cleanup | C copy resume | B/Backspace back | Esc/Ctrl+C twice quit'
        $notice = ''
        $key = Read-MenuKey
        if ($key -eq 'Escape') { return 'Exit' }
        if ($key -in @('B', 'Backspace') -and $state.Level -eq 0) { return 'Back' }
        if ($key -eq 'D') { if ((Invoke-SelectionCleanup $Session) -eq 'Exit') { return 'Exit' }; continue }
        if ($key -eq 'A') { Switch-ItemSelection $viewItems $selected; continue }
        if ($key -eq 'Enter' -and $selectAllFocused) {
            $summary = Get-InventorySummary $viewItems $selected
            if (-not $summary.EligibleCount) { $notice = 'Nothing eligible in this view.'; continue }
            if ($summary.SelectedCount -lt $summary.EligibleCount) { Switch-ItemSelection $viewItems $selected }
            if ((Invoke-SelectionCleanup $Session) -eq 'Exit') { return 'Exit' }
            continue
        }
        if ($key -eq 'Spacebar') {
            Switch-ItemSelection $(if ($selectAllFocused) { $viewItems } else { $focusedItems }) $selected
            continue
        }
        if ($state.Level -lt 3) {
            if ($key -eq 'Home') { $selectAllFocused = $true; continue }
            if ($selectAllFocused) {
                if ($key -in @('DownArrow', 'PageDown', 'End')) { $selectAllFocused = $false; $state.Index = if ($key -eq 'End') { [math]::Max(0, $rows.Count - 1) } else { 0 } }
                elseif ($key -eq 'UpArrow') { $selectAllFocused = $false; $state.Index = [math]::Max(0, $rows.Count - 1) }
                elseif ($key -notin @('B', 'Backspace', 'LeftArrow')) { continue }
                else { $selectAllFocused = $false }
                if ($key -notin @('B', 'Backspace', 'LeftArrow')) { continue }
            } elseif ($key -eq 'UpArrow' -and $state.Index -eq 0) { $selectAllFocused = $true; continue }
            elseif ($key -eq 'PageUp' -and $state.Index -eq 0) { $selectAllFocused = $true; continue }
        }
        if ($key -eq 'C' -and $state.Level -eq 3 -and $focusedItems.Count -and $focusedItems[0].Resume) {
            try { Set-Clipboard -Value $focusedItems[0].Resume -ErrorAction Stop; $notice = 'Resume command copied.' } catch { $notice = 'Clipboard unavailable; use the resume command shown above.' }
            continue
        }
        $state = Update-NavState $state $key $rows
        if ($key -eq 'Enter') { $selectAllFocused = $false }
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
    $version = Get-AgentPurgeScriptVersion $SourceFile
    if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $marker)) { throw "Install directory already exists without an agent-purge marker: $root" }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    if ((Get-FullPath $SourceFile) -ne $scriptFile) { Copy-Item -LiteralPath $SourceFile -Destination $scriptFile -Force }
    $body = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0agent-purge.ps1`" %*`r`n"
    [IO.File]::WriteAllText($launcher, $body, [Text.Encoding]::ASCII)
    $record = [ordered]@{ name = 'agent-purge'; version = $version.ToString(); scriptHash = (Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash; launcherHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash }
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
        [ValidateSet('User', 'Process')][string]$PathScope = 'User')
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
        $installedVersion = Get-AgentPurgeScriptVersion $scriptFile $true
        if ($record.PSObject.Properties['version'] -and $record.version -ne $installedVersion.ToString()) { throw 'Installed version differs from its marker' }
        Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/Etriii/agent-purge/main/agent-purge.ps1' -OutFile $download -TimeoutSec 5 -ErrorAction Stop | Out-Null
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -eq $record.scriptHash) {
            Write-Host 'Agent Purge is up to date.'
            return $false
        }
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($download, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw 'Downloaded update has invalid PowerShell syntax' }
        $availableVersion = Get-AgentPurgeScriptVersion $download $true
        if ($availableVersion -le $installedVersion) {
            Write-Host "Published version $availableVersion is not newer than installed version $installedVersion. Installed files were kept."
            return $false
        }
        Install-AgentPurge -InstallRoot $root -PathScope $PathScope -SourceFile $download | Out-Null
        Write-Host "Agent Purge $availableVersion installed. Start agent-purge again to use it."
        return $true
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
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
    Write-Output "Agent Purge $script:AgentPurgeVersion"
    @'
Agent Purge: inspect and selectively clean local Codex and Claude storage.

Usage:
  agent-purge                       Choose current project or global scope, then open the menu
  agent-purge scan                  Inspect the chosen scope
  agent-purge clean                 Choose sessions in the chosen scope, then review
  agent-purge clean --all           Preselect eligible items in the chosen scope; review
  agent-purge clean --all --advanced
                                    In global scope, also select old runtimes and caches
  agent-purge clean --project <path> Choose session history for a folder and descendants
  agent-purge scan --global         Inspect global provider storage
  agent-purge scan --global --advanced
                                    Also allow verified old runtimes and caches
  agent-purge scan --project <path> Inspect sessions in a project and descendants
  agent-purge scope show            Show this Git project's saved scope choice
  agent-purge scope project         Remember project scope for this Git project
  agent-purge scope global          Remember global scope for this Git project
  agent-purge scope ask             Ask again on the next interactive run
  agent-purge scope reset           Alias for scope ask
  agent-purge restore <run-id> <hash>
                                    Restore files saved in an Agent Purge undo run
  agent-purge settings              View or change retention with keyboard controls
  agent-purge settings show         Print the current retention setting
  agent-purge settings set retention-days <1-365>
                                    Set retention for future undo runs
  agent-purge settings set undo-dir <absolute-path>
                                    Move existing undo data and store new runs there
  agent-purge undo clean            Inspect and clean selected saved undo runs
  agent-purge install               Install a user-local launcher and PATH entry
  agent-purge update                Install a newer version from published main
  agent-purge --version             Show the installed script version
  agent-purge uninstall             Remove installed files and that PATH entry
  agent-purge --help                Show this help

Inside a Git project, Current project is recommended. Space in the scope
prompt remembers the selected choice for that project. Explicit scan --global
and scan/clean --project paths override it. Outside a Git project, scope is global.
Project scope filters scans and cleanup to recorded sessions in that project;
settings, restore, and undo-folder cleanup remain global operations.

Project picker: Up/Down move, PgUp/PgDn jump, Home/End ends, F find,
Space toggle, A select/clear all, Enter review, I inspect.
Inspector: Enter open, D review, C copy resume from details.
B/Backspace goes back; Esc or Ctrl+C twice quits. [x] selected, [~] partial, [-] inspect only.
Undo folder uses NTFS compression when available and prints its location.
Small or already compressed files may save little space. Recycle Bin needs manual restore.
Expired runs move to a named Recycle Bin folder on the next interactive launch.
At file cleanup: Up/Down choose; Enter/Space select. PgUp/PgDn browse paths; I shows full paths.
Codex sessions use separate permanent deletion and cannot be restored by this command.
Permanent deletion requires an acknowledgement and a final confirmation; Cancel is the default.
Sizes show inventoried agent storage by project/provider/category, not source folders.
Clean --all never removes protected items and still requires an explicit keyboard confirmation.
Redirected scan and clean commands only print inventory; they never remove data.
Interactive launches stay local; use agent-purge update to check GitHub main.
 Update keeps the installed copy when published main is older or has the same version.
 To update a source checkout, pull main.
'@ | Write-Output
}

function Show-SettingsMenu($Context) {
    $saved = Get-AgentPurgeConfig $Context
    $days = $saved.RetentionDays
    $index = 0
    $labels = @('Undo retention', 'Move undo folder', 'Clean undo folder', 'Back to main menu')
    while ($true) {
        Clear-Host
        Write-ScreenLine 'AGENT PURGE / SETTINGS' Cyan
        Write-ScreenLine 'Choose a setting with Up/Down, then press Enter.'
        Write-ScreenLine ''
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $label = $labels[$i]
            if ($i -eq 0) { $label += ('   {0} days{1}' -f $days, $(if ($days -ne $saved.RetentionDays) { ' (unsaved)' } else { '' })) }
            Write-ScreenLine ('{0} {1}' -f $(if ($i -eq $index) { '>' } else { ' ' }), $label) $(if ($i -eq $index) { 'White' } else { 'Gray' })
        }
        Write-ScreenLine ''
        Write-ScreenLine ('Saved retention: {0} days ({1})' -f $saved.RetentionDays, $(if ($saved.Source -eq 'default') { 'default' } else { 'saved' })) DarkGray
        Write-ScreenLine ('Undo location: ' + $(if ($saved.UndoDirectory) { $saved.UndoDirectory } else { Get-UndoManifestRoot $Context $saved })) Cyan
        $description = switch ($index) {
            0 { 'Adjust days with Left/Right (1), PgUp/PgDn (10), or Home (30); Enter saves.' }
            1 { 'Enter opens a path prompt. Existing undo runs move to the new folder.' }
            2 { 'Enter lists saved undo runs for inspection and selective cleanup.' }
            3 { 'Enter returns to the main menu without saving an edited retention value.' }
        }
        Write-ScreenLine $description Yellow
        Write-ScreenLine 'Retention changes apply only to new undo runs.' DarkGray
        Write-ScreenLine 'Up/Down move | Enter/Space choose | B/Backspace back'
        Write-ScreenLine 'Esc/Ctrl+C twice quit'
        $key = Read-MenuKey
        if ($key -eq 'Escape') { return 'Exit' }
        if ($key -in @('B', 'Backspace')) { return 'Back' }
        if ($key -eq 'UpArrow') { $index = ($index + $labels.Count - 1) % $labels.Count; continue }
        if ($key -eq 'DownArrow') { $index = ($index + 1) % $labels.Count; continue }
        if ($index -eq 0) {
            switch ($key) {
                'RightArrow' { $days = [math]::Min(365, $days + 1); continue }
                'LeftArrow' { $days = [math]::Max(1, $days - 1); continue }
                'PageUp' { $days = [math]::Min(365, $days + 10); continue }
                'PageDown' { $days = [math]::Max(1, $days - 10); continue }
                'Home' { $days = 30; continue }
            }
        }
        if ($key -eq 'U') { $index = 1 }
        elseif ($key -eq 'C') { $index = 2 }
        elseif ($key -notin @('Enter', 'Spacebar')) { continue }
        switch ($index) {
            0 {
                Set-AgentPurgeRetention $Context $days
                Write-Host "Retention saved: $days days for new undo runs."
                return 'Back'
            }
            1 {
                $path = (Read-Host 'New undo folder (absolute path; blank cancels)').Trim().Trim('"')
                if ($path) {
                    try { Set-AgentPurgeUndoDirectory $Context $path; $saved = Get-AgentPurgeConfig $Context }
                    catch { Write-Host "Undo location unchanged: $($_.Exception.Message)" -ForegroundColor Yellow }
                    Write-Host 'Press any key to return to settings.'
                    [void](Read-MenuKey)
                }
            }
            2 {
                if ((Invoke-UndoFolderCleanup $Context) -eq 'Exit') { return 'Exit' }
            }
            3 { return 'Back' }
        }
    }
}

function Show-ProjectScopePrompt($Context, [string]$ProjectPath) {
    $index = 0
    $remember = $false
    while ($true) {
        Clear-Host
        Write-ScreenLine 'AGENT PURGE / CHOOSE SCOPE' Cyan
        Write-ScreenLine 'Where should Agent Purge look for agent history?'
        Write-ScreenLine ('Project: ' + (Format-ProjectLabel $ProjectPath ((Get-TerminalSize).Width - 10))) Cyan
        Write-ScreenLine ('{0} Current project (recommended)' -f $(if ($index -eq 0) { '>' } else { ' ' }))
        Write-ScreenLine ('{0} Global agent storage' -f $(if ($index -eq 1) { '>' } else { ' ' }))
        Write-ScreenLine ('{0} Do not ask again for this project' -f $(if ($remember) { '[x]' } else { '[ ]' }))
        Write-ScreenLine 'Up/Down choose | Space toggle memory | Enter continue | Esc quit'
        $key = Read-MenuKey
        switch ($key) {
            'Escape' { return 'Exit' }
            'UpArrow' { $index = ($index + 1) % 2 }
            'DownArrow' { $index = ($index + 1) % 2 }
            'Spacebar' { $remember = -not $remember }
            'Enter' {
                $choice = if ($index -eq 0) { 'project' } else { 'global' }
                if ($remember) { Set-ProjectScopePreference $Context $ProjectPath $choice }
                return $choice
            }
        }
    }
}

function Resolve-ProjectScope($Context, [string]$ProjectPath) {
    if (-not $ProjectPath) { return 'global' }
    $config = Get-AgentPurgeConfig $Context
    if ($config.ProjectScopes.ContainsKey($ProjectPath)) { return $config.ProjectScopes[$ProjectPath] }
    if (-not (Test-InteractiveTerminal)) { return 'project' }
    return Show-ProjectScopePrompt $Context $ProjectPath
}

function Show-StartMenu([string]$Scope = 'global', [string]$ProjectPath = '') {
    if ($Scope -eq 'project') {
        $labels = @('Clean current project (recommended)', 'Inspect current project', 'Clean all eligible current-project sessions', 'Switch to global scope', 'Settings', 'Exit')
        $descriptions = @(
            'Review agent sessions recorded in this project and its descendants.',
            "Browse this project's Codex and Claude sessions.",
            'Preselect eligible sessions from this project; review before cleanup.',
            'Use all known agent storage for this run.',
            'Set undo retention and storage location, or clean saved undo data.',
            'Close Agent Purge without making further changes.'
        )
    } else {
        $labels = @('Choose projects to clean (recommended)', 'Inspect all agent storage', 'Clean all eligible storage', $(if ($ProjectPath) { 'Switch to current project' } else { 'Choose one project folder' }), 'Settings', 'Exit')
        $descriptions = @(
            'See project sizes, toggle projects with Space, then review cleanup with Enter.',
            'Browse providers and categories to understand storage and protected items.',
            'Preselect eligible sessions and logs. You can deselect before confirming cleanup.',
            $(if ($ProjectPath) { 'Use only sessions recorded in the current project.' } else { 'Limit session history to a project folder and its descendants.' }),
            'Set undo retention and storage location, or clean saved undo data.',
            'Close Agent Purge without making further changes.'
        )
    }
    $index = 0
    while ($true) {
        Clear-Host
        Write-ScreenLine ("AGENT PURGE $script:AgentPurgeVersion") Cyan
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
            1 { if ($Scope -eq 'project') { return @('scan') }; return @('scan', '--global') }
            2 { return @('clean', '--all') }
            3 {
                if ($ProjectPath) {
                    if ($Scope -eq 'project') { return @('__scope', 'global') }
                    return @('__scope', 'project')
                }
                Write-Host 'Enter a source-project folder to find its recorded agent history. Leave blank to go back.'
                $path = (Read-Host 'Project folder').Trim().Trim('"')
                if (-not $path) { continue }
                if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                    Write-Host "Folder not found: $path. Press any key to return."
                    [void](Read-MenuKey); continue
                }
                return @('clean', '--project', $path)
            }
            4 { return @('settings') }
            5 { return }
        }
    }
}

function Invoke-AgentPurge([string[]]$Arguments) {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core' -and $env:OS -ne 'Windows_NT') { throw 'Agent Purge requires Windows.' }
    $fromMenu = -not $Arguments.Count
    $expiryChecked = $false
    $detectedProject = Get-CurrentProjectPath
    $scope = ''
    $scopeChosen = $false
    if ($fromMenu -and -not (Test-InteractiveTerminal)) { Show-AgentPurgeHelp; return }
    do {
        if ($fromMenu) {
            if (-not $scopeChosen) {
                $scope = Resolve-ProjectScope (New-AgentPurgeContext) $detectedProject
                if ($scope -eq 'Exit') { return }
                $scopeChosen = $true
            }
            if (-not $expiryChecked -and $scope -eq 'global') {
                if ((Show-ExpiryCheck (New-AgentPurgeContext)) -eq 'Exit') { return }
                $expiryChecked = $true
            }
            $Arguments = @(Show-StartMenu $scope $detectedProject)
            if (-not $Arguments.Count) { return }
            if ($Arguments[0] -eq '__scope') { $scope = $Arguments[1]; continue }
        }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--help') { Show-AgentPurgeHelp; return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--version') { Write-Output "Agent Purge $script:AgentPurgeVersion"; return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'install') { Install-AgentPurge; return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'update') { [void](Update-AgentPurge); return }
        if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'uninstall') { Uninstall-AgentPurge; return }
        if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'undo' -and $Arguments[1] -eq 'clean') {
            Invoke-UndoFolderCleanup (New-AgentPurgeContext)
            return
        }
        if ($Arguments[0] -eq 'scope') {
            if (-not $detectedProject) { throw 'Run scope commands inside a Git project' }
            $context = New-AgentPurgeContext
            if ($Arguments.Count -eq 1 -or ($Arguments.Count -eq 2 -and $Arguments[1] -eq 'show')) {
                $saved = Get-AgentPurgeConfig $context
                $preference = if ($saved.ProjectScopes.ContainsKey($detectedProject)) { $saved.ProjectScopes[$detectedProject] } else { 'ask' }
                Write-Output "Project: $detectedProject"
                Write-Output "Scope preference: $preference"
                return
            }
            if ($Arguments.Count -eq 2 -and $Arguments[1] -in @('project', 'global', 'ask', 'reset')) {
                $choice = if ($Arguments[1] -eq 'reset') { 'ask' } else { $Arguments[1] }
                Set-ProjectScopePreference $context $detectedProject $choice
                Write-Output "Scope preference for $detectedProject`: $choice"
                return
            }
            throw 'Invalid scope command. Use scope show, project, global, ask, or reset.'
        }
        if ($Arguments[0] -eq 'settings') {
            $settingsContext = New-AgentPurgeContext
            if ($Arguments.Count -eq 2 -and $Arguments[1] -eq 'show') {
                $saved = Get-AgentPurgeConfig $settingsContext
                Write-Output ("Undo retention: $($saved.RetentionDays) days ($($saved.Source)); future runs only.")
                Write-Output ("Undo location: $(Get-UndoManifestRoot $settingsContext $saved)")
                return
            }
            if ($Arguments.Count -eq 4 -and $Arguments[1] -eq 'set' -and $Arguments[2] -eq 'undo-dir') {
                Set-AgentPurgeUndoDirectory $settingsContext $Arguments[3]
                return
            }
            if ($Arguments.Count -eq 4 -and $Arguments[1] -eq 'set' -and $Arguments[2] -eq 'retention-days') {
                [int]$days = 0
                if (-not [int]::TryParse($Arguments[3], [ref]$days)) { throw 'Retention days must be an integer from 1 to 365' }
                Set-AgentPurgeRetention $settingsContext $days
                Write-Output "Undo retention saved: $days days for future runs."
                return
            }
            if ($Arguments.Count -eq 1) {
                if (-not (Test-InteractiveTerminal)) { throw 'Interactive settings require a terminal; use settings show or settings set.' }
                if (-not $expiryChecked) {
                    if ((Show-ExpiryCheck $settingsContext) -eq 'Exit') { return }
                    $expiryChecked = $true
                }
                if ((Show-SettingsMenu $settingsContext) -eq 'Exit') { return }
                $fromMenu = $true
                continue
            }
            throw 'Invalid settings command. Use --help.'
        }
        if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'restore') {
            Invoke-UndoRestore (New-AgentPurgeContext) $Arguments[1] $Arguments[2]
            return
        }
        if ($Arguments[0] -notin @('scan', 'clean')) { throw 'Unknown command. Use --help.' }
        $clean = $Arguments[0] -eq 'clean'
        $advanced = $false; $selectAll = $false; $project = ''
        if ($Arguments.Count -eq 1) { }
        elseif ($Arguments.Count -in @(2, 3) -and (($clean -and $Arguments[1] -eq '--all') -or (-not $clean -and $Arguments[1] -eq '--global')) -and ($Arguments.Count -eq 2 -or $Arguments[2] -eq '--advanced')) {
            $selectAll = $clean
            $advanced = $Arguments.Count -eq 3
        } elseif ($Arguments.Count -eq 3 -and $Arguments[1] -eq '--project') {
            if (-not (Test-Path -LiteralPath $Arguments[2] -PathType Container)) { throw "Project directory not found: $($Arguments[2])" }
            $project = (Get-Item -LiteralPath $Arguments[2]).FullName
        } else { throw 'Invalid arguments. Use --help.' }
        $context = New-AgentPurgeContext
        $explicitScope = ($Arguments.Count -eq 3 -and $Arguments[1] -eq '--project') -or ($Arguments.Count -ge 2 -and $Arguments[1] -eq '--global')
        if (-not $explicitScope) {
            if (-not $scopeChosen) {
                $scope = Resolve-ProjectScope $context $detectedProject
                if ($scope -eq 'Exit') { return }
                $scopeChosen = $true
            }
            if ($scope -eq 'project') { $project = $detectedProject }
        }
        $items = @(Get-ScanInventory $context $advanced $project)
        if (-not (Test-InteractiveTerminal)) {
            Write-Output 'Read-only inventory: interactive selection and confirmation are required for cleanup.'
            Write-InventoryText $items
            return
        }
        if (-not $expiryChecked -and -not $project) {
            if ((Show-ExpiryCheck $context) -eq 'Exit') { return }
            $expiryChecked = $true
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
