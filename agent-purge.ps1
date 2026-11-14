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

