function g {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "git not found in PATH" -ForegroundColor Red;
        return;
    }

    Add-Type -AssemblyName Microsoft.VisualBasic;

    $selectedIndex = 0;
    $pageSize = 15;
    $defaultMessage = "update";
    $currentPath = (Get-Location).Path;
    $items = @();
    $itemsPath = "";
    $here = $null;
    $pendingSelectName = "";
    $drawnPage = -1;
    $idCache = @{};
    $listingCache = @{};
    $globalName = "";
    $globalEmail = "";
    try { $enc = [System.Text.Encoding]::GetEncoding(936); } catch { $enc = [System.Text.Encoding]::Default; }

    function Get-One([object]$value) {
        if ($null -eq $value) { return ""; }
        return ("$value").Trim();
    }

    $ignorePath = "C:\Users\kasus\Documents\GitHub\g\ignore.json";
    $ignored = @{};

    function Read-Ignored {
        $ignored.Clear();
        if (-not (Test-Path -LiteralPath $ignorePath)) { return; }
        try {
            $data = Get-Content -Raw -LiteralPath $ignorePath -Encoding UTF8 | ConvertFrom-Json;
            foreach ($p in @($data.paths)) {
                $norm = Get-Norm "$p";
                if ($norm) { $ignored[$norm] = $true; }
            }
        } catch {}
    }

    function Save-Ignored {
        $paths = @($ignored.Keys | Sort-Object);
        $json = @{ paths = $paths } | ConvertTo-Json -Compress;
        $utf8 = New-Object System.Text.UTF8Encoding $false;
        [System.IO.File]::WriteAllText($ignorePath, $json, $utf8);
    }

    function Test-Ignored([string]$path) {
        $norm = Get-Norm $path;
        return ($norm -and $ignored.ContainsKey($norm));
    }

    function Get-Norm([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) { return ""; }
        try { return [System.IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant(); } catch { return $path.TrimEnd('\').ToLowerInvariant(); }
    }

    function Get-VisualWidth([string]$text) {
        if ([string]::IsNullOrEmpty($text)) { return 0; }
        return $enc.GetByteCount($text);
    }

    function Get-CharWidth([char]$ch, [int]$pos) {
        if ($ch -eq "`t") {
            return (([Math]::Floor($pos / 8) + 1) * 8) - $pos;
        }
        return Get-VisualWidth ([string]$ch);
    }

    function Get-DisplayWidth([string]$text) {
        $pos = 0;
        if ([string]::IsNullOrEmpty($text)) { return 0; }
        foreach ($ch in $text.ToCharArray()) { $pos += Get-CharWidth $ch $pos; }
        return $pos;
    }

    function Get-NextStop([int]$width) {
        $stop = ([Math]::Floor($width / 8) + 1) * 8;
        if ($stop -le $width) { $stop += 8; }
        return $stop;
    }

    function Pad-To([string]$text, [int]$target) {
        $pos = Get-DisplayWidth $text;
        if ($pos -ge $target) { return $text + " "; }
        return $text + (" " * ($target - $pos));
    }

    function Get-FittedLine([string]$text, [int]$width) {
        if ($width -lt 1) { return ""; }
        $pos = 0;
        $sb = New-Object System.Text.StringBuilder;
        foreach ($ch in $text.ToCharArray()) {
            $cw = Get-CharWidth $ch $pos;
            if (($pos + $cw) -gt $width) { break; }
            [void]$sb.Append($ch);
            $pos += $cw;
        }
        if ($pos -lt $width) { [void]$sb.Append((" " * ($width - $pos))); }
        return $sb.ToString();
    }

    function Get-Rule {
        $unit = Get-VisualWidth "─";
        if ($unit -lt 1) { $unit = 1; }
        $count = [Math]::Max(1, [Math]::Floor($winWidth / $unit));
        return "─" * $count;
    }

    function Write-FittedLine([string]$text, [string]$fg, [string]$bg) {
        $line = Get-FittedLine $text $winWidth;
        if ($bg) {
            Write-Host $line -ForegroundColor $fg -BackgroundColor $bg;
        } else {
            Write-Host $line -ForegroundColor $fg;
        }
    }

    function New-RepoRow([string]$name, [string]$fullName) {
        return [pscustomobject]@{
            Name = $name
            FullName = $fullName
            IsDir = $true
            IsRepo = $true
            Branch = ""
            Upstream = ""
            Ahead = 0
            Behind = 0
            Dirty = 0
            Detached = $false
        };
    }

    function Parse-StatusText([string]$text) {
        $parsed = @{
            Branch = ""
            Upstream = ""
            Ahead = 0
            Behind = 0
            Dirty = 0
            Detached = $false
            Ok = $false
        };
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) });
        if ($lines.Count -eq 0) { return $parsed; }
        $head = $lines[0];
        if ($head -notmatch '^##\s+(.+)$') { return $parsed; }
        $rest = $Matches[1];
        if ($rest -match '^(?<br>.+?)(?:\.\.\.(?<up>\S+))?(?:\s+\[(?<trk>.+)\])?$') {
            $branch = $Matches['br'];
            $upstream = if ($Matches['up']) { $Matches['up'] } else { "" };
            $trk = if ($Matches['trk']) { $Matches['trk'] } else { "" };
            if ($branch -match '^No commits yet on (.+)$') { $branch = $Matches[1]; }
            $parsed.Branch = $branch;
            $parsed.Upstream = $upstream;
            if ($trk -match 'ahead (\d+)') { $parsed.Ahead = [int]$Matches[1]; }
            if ($trk -match 'behind (\d+)') { $parsed.Behind = [int]$Matches[1]; }
        }
        if ($parsed.Branch -eq 'HEAD (no branch)' -or $parsed.Branch -like 'HEAD *') { $parsed.Detached = $true; }
        $parsed.Dirty = @($lines | Select-Object -Skip 1).Count;
        $parsed.Ok = $true;
        return $parsed;
    }

    function Set-RepoFields($row, $parsed) {
        $row.Branch = $parsed.Branch;
        $row.Upstream = $parsed.Upstream;
        $row.Ahead = $parsed.Ahead;
        $row.Behind = $parsed.Behind;
        $row.Dirty = $parsed.Dirty;
        $row.Detached = $parsed.Detached;
    }

    function Resolve-Detached($row) {
        if (-not $row.Detached) { return; }
        $raw = @(& git -C $row.FullName for-each-ref --points-at HEAD refs/heads --format="%(refname:short)|%(upstream:short)" 2>$null);
        $cands = @();
        foreach ($line in $raw) {
            $text = Get-One $line;
            if (-not $text -or $text -notmatch '^([^|]+)\|(.*)$') { continue; }
            $cands += [pscustomobject]@{ Name = $Matches[1]; Up = $Matches[2] };
        }
        if ($cands.Count -eq 0) { return; }
        $pick = $cands | Where-Object { $_.Name -eq 'main' -or $_.Name -eq 'master' } | Select-Object -First 1;
        if (-not $pick -and $cands.Count -eq 1) { $pick = $cands[0]; }
        if (-not $pick) { $pick = $cands | Where-Object { $_.Up } | Select-Object -First 1; }
        if (-not $pick) { $pick = $cands[0]; }
        $row.Branch = $pick.Name;
        $row.Upstream = $pick.Up;
        $row.Ahead = 0;
        $row.Behind = 0;
        if ($pick.Up) {
            $counts = Get-One (& git -C $row.FullName rev-list --left-right --count "$($pick.Up)...HEAD" 2>$null);
            $parts = @($counts -split '\s+' | Where-Object { $_ -match '^\d+$' });
            if ($parts.Count -ge 2) {
                $row.Behind = [int]$parts[0];
                $row.Ahead = [int]$parts[1];
            }
        }
    }

    function Start-GitProbe([string]$path, [string]$kind, [string]$arguments) {
        $p = New-Object System.Diagnostics.Process;
        $p.StartInfo.FileName = "git";
        $p.StartInfo.Arguments = $arguments;
        $p.StartInfo.UseShellExecute = $false;
        $p.StartInfo.RedirectStandardOutput = $true;
        $p.StartInfo.RedirectStandardError = $true;
        $p.StartInfo.CreateNoWindow = $true;
        $p.StartInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false);
        $p.StartInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false);
        [void]$p.Start();
        return [pscustomobject]@{ Proc = $p; Path = $path; Kind = $kind; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() };
    }

    function Read-GitProbe($item) {
        try { [void]$item.Proc.WaitForExit(); } catch {}
        $text = "";
        try { $text = $item.Out.Result; } catch {}
        try { [void]$item.Err.Result; } catch {}
        try { $item.Proc.Dispose(); } catch {}
        return $text;
    }

    function Get-ProbeMap([string[]]$paths) {
        $map = @{};
        $list = @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) });
        if ($list.Count -eq 0) { return $map; }
        $procs = @();
        foreach ($path in $list) {
            $quoted = '"' + ($path -replace '"', '\"') + '"';
            $procs += Start-GitProbe $path "status" "-C $quoted --no-pager status -sb --porcelain=v1";
            $procs += Start-GitProbe $path "config" "-C $quoted config --get-regexp ^user\.(name|email)$";
        }
        $bucket = @{};
        foreach ($item in $procs) {
            $text = Read-GitProbe $item;
            $key = Get-Norm $item.Path;
            if (-not $bucket.ContainsKey($key)) { $bucket[$key] = @{ Status = ""; Config = "" }; }
            if ($item.Kind -eq "status") { $bucket[$key].Status = $text; }
            else { $bucket[$key].Config = $text; }
        }
        foreach ($key in $bucket.Keys) { $map[$key] = $bucket[$key]; }
        return $map;
    }

    function Fill-Repo($row, $probeMap) {
        $key = Get-Norm $row.FullName;
        $probe = if ($probeMap.ContainsKey($key)) { $probeMap[$key] } else { @{ Status = ""; Config = "" } };
        $parsed = Parse-StatusText $probe.Status;
        if ($parsed.Ok) { Set-RepoFields $row $parsed; }
        if ($row.Detached) { Resolve-Detached $row; }
        $name = $globalName;
        $email = $globalEmail;
        foreach ($line in @($probe.Config -split "`r?`n")) {
            $text = Get-One $line;
            if ($text -match '^user\.name\s+(.+)$') { $name = $Matches[1].Trim(); }
            if ($text -match '^user\.email\s+(.+)$') { $email = $Matches[1].Trim(); }
        }
        $row | Add-Member -NotePropertyName UserName -NotePropertyValue $name -Force;
        $row | Add-Member -NotePropertyName UserEmail -NotePropertyValue $email -Force;
        if ($key) { $idCache[$key] = @{ Name = $name; Email = $email }; }
    }

    function Get-Listing([string]$path) {
        $children = @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue);
        $rows = @();
        foreach ($child in $children) {
            $isRepo = $false;
            if ($child.PSIsContainer) {
                $isRepo = Test-Path -LiteralPath (Join-Path $child.FullName '.git');
            }
            $rows += [pscustomobject]@{
                Name = $child.Name
                FullName = $child.FullName
                IsDir = [bool]$child.PSIsContainer
                IsRepo = $isRepo
                Branch = ""
                Upstream = ""
                Ahead = 0
                Behind = 0
                Dirty = 0
                Detached = $false
            };
        }
        $repos = @($rows | Where-Object { $_.IsRepo });
        if ($repos.Count -gt 0) {
            $probeMap = Get-ProbeMap @($repos | ForEach-Object { $_.FullName });
            foreach ($row in $repos) { Fill-Repo $row $probeMap; }
        }
        return @($rows | Sort-Object @{ Expression = { if ($_.IsRepo) { 0 } elseif ($_.IsDir) { 1 } else { 2 } } }, @{ Expression = 'Name' });
    }

    function Get-Here([string]$path) {
        $top = Get-One (& git -C $path rev-parse --show-toplevel 2>$null);
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($top)) { return $null; }
        $row = New-RepoRow (Split-Path -Leaf $top) $top;
        $probeMap = Get-ProbeMap @($top);
        Fill-Repo $row $probeMap;
        return $row;
    }

    function Refresh-Repo([string]$path) {
        $row = New-RepoRow (Split-Path -Leaf $path) $path;
        $probeMap = Get-ProbeMap @($path);
        Fill-Repo $row $probeMap;
        $norm = Get-Norm $path;
        foreach ($entry in $listingCache.Values) {
            foreach ($item in @($entry.Items)) {
                if ($item.IsRepo -and (Get-Norm $item.FullName) -eq $norm) {
                    Set-RepoFields $item $row;
                    $item.Detached = $row.Detached;
                }
            }
            if ($entry.Here -and (Get-Norm $entry.Here.FullName) -eq $norm) {
                Set-RepoFields $entry.Here $row;
                $entry.Here.Detached = $row.Detached;
            }
        }
    }

    function Get-CmdQuote([string]$text) {
        return '"' + ($text -replace '"', '""') + '"';
    }

    function Start-GApp([string]$file, [string]$path) {
        if (-not $file -or -not (Test-Path -LiteralPath $file) -or -not $path) { return $false; }
        $psi = New-Object System.Diagnostics.ProcessStartInfo;
        $psi.FileName = "cmd.exe";
        $psi.Arguments = "/d /s /c call $(Get-CmdQuote $file) $(Get-CmdQuote $path)";
        $psi.UseShellExecute = $false;
        $psi.CreateNoWindow = $true;
        [void][System.Diagnostics.Process]::Start($psi);
        return $true;
    }

    function Find-CodeCmd {
        $cmd = @(Get-Command code.cmd, code -ErrorAction SilentlyContinue) | Select-Object -First 1;
        if ($cmd) { return $cmd.Source; }
        $fallback = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd";
        if (Test-Path -LiteralPath $fallback) { return $fallback; }
        return $null;
    }

    function Find-GitHubCmd {
        $fallback = Join-Path $env:LOCALAPPDATA "GitHubDesktop\bin\github.bat";
        if (Test-Path -LiteralPath $fallback) { return $fallback; }
        $cmd = @(Get-Command github.bat, github -ErrorAction SilentlyContinue) | Select-Object -First 1;
        if ($cmd) { return $cmd.Source; }
        return $null;
    }

    function Get-SelectedItem {
        if ($items.Count -gt 0 -and $selectedIndex -ge 0 -and $selectedIndex -lt $items.Count) {
            return $items[$selectedIndex];
        }
        return $null;
    }

    function Show-OpenFailed([string]$name) {
        Clear-Host;
        Write-Host "  $name was not found." -ForegroundColor Red;
        Wait-AnyKey;
        Clear-Host;
    }

    function Get-Target {
        if ($items.Count -gt 0 -and $selectedIndex -ge 0 -and $selectedIndex -lt $items.Count) {
            $sel = $items[$selectedIndex];
            if ($sel.IsRepo) { return $sel; }
        }
        return $here;
    }

    function Get-Identity([string]$path) {
        $key = if ($path) { Get-Norm $path } else { "" };
        if ($key -and $idCache.ContainsKey($key)) { return $idCache[$key]; }
        $name = $globalName;
        $email = $globalEmail;
        if ($key) {
            $n = Get-One (& git -C $path config --get user.name 2>$null);
            $e = Get-One (& git -C $path config --get user.email 2>$null);
            if ($n) { $name = $n; }
            if ($e) { $email = $e; }
            $idCache[$key] = @{ Name = $name; Email = $email };
            return $idCache[$key];
        }
        return @{ Name = $name; Email = $email };
    }

    function Get-RowText($item) {
        $label = $item.Name;
        if ($item.IsDir -and -not $item.IsRepo) { $label += "\"; }
        $mark = if ($item.IsDir -and (Test-Ignored $item.FullName)) { "* " } else { "  " };
        $line = "  $mark$label";
        if (-not $item.IsRepo -or -not $item.Branch) { return $line; }
        $kept = Test-Ignored $item.FullName;
        $line = Pad-To $line $nameStop;
        $line += $item.Branch;
        $line = Pad-To $line $branchStop;
        $state = if ($kept -or $item.Dirty -eq 0) { "clean" } else { "$($item.Dirty)" };
        $line += $state;
        if (-not $kept) {
            $extra = @();
            if ($item.Ahead -gt 0) { $extra += "+$($item.Ahead)"; }
            if ($item.Behind -gt 0) { $extra += "-$($item.Behind)"; }
            if ($extra.Count -gt 0) {
                $line = Pad-To $line $statusStop;
                $line += ($extra -join "  ");
            }
        }
        return $line;
    }

    function Get-RowColor($item) {
        if ($item.IsDir -and (Test-Ignored $item.FullName)) { return "Green"; }
        if ($item.IsRepo) {
            if (-not $item.Branch) { return "DarkGray"; }
            if ($item.Dirty -gt 0) { return "Yellow"; }
            return "Green";
        }
        if ($item.IsDir) { return "White"; }
        return "DarkGray";
    }

    function Invoke-QuietCommit([string]$path, [string]$message) {
        $add = (& git -C $path add -A 2>&1 | Out-String);
        $addCode = $LASTEXITCODE;
        $commit = "";
        $commitCode = 0;
        if ($addCode -eq 0) {
            $commit = (& git -C $path commit -m $message 2>&1 | Out-String);
            $commitCode = $LASTEXITCODE;
        }
        $benign = $commit -match 'nothing to commit|no changes added to commit';
        return @{ Ok = ($addCode -eq 0 -and ($commitCode -eq 0 -or $benign)); Text = ($add + $commit).Trim() };
    }

    function Read-GLine([string]$prompt, [string]$initial) {
        $text = $initial;
        $cursor = $text.Length;
        $baseTop = [Console]::CursorTop;
        [Console]::CursorVisible = $true;
        while ($true) {
            $width = [Math]::Max(10, [Console]::WindowWidth - 1);
            $combo = $prompt + $text.Substring(0, $cursor);
            while ((Get-VisualWidth $combo) -gt ($width - 1) -and $combo.Length -gt 0) {
                $combo = $combo.Substring(1);
            }
            $room = $width - (Get-VisualWidth $combo);
            $afterShown = "";
            foreach ($ch in $text.Substring($cursor).ToCharArray()) {
                if ((Get-VisualWidth ($afterShown + $ch)) -gt $room) { break; }
                $afterShown += $ch;
            }
            $shown = $combo + $afterShown;
            $pad = [Math]::Max(0, $width - (Get-VisualWidth $shown));
            [Console]::SetCursorPosition(0, [Math]::Min($baseTop, [Math]::Max(0, [Console]::BufferHeight - 1)));
            Write-Host ($shown + (" " * $pad)) -NoNewline;
            $col = [Math]::Min((Get-VisualWidth $combo), $width - 1);
            [Console]::SetCursorPosition($col, [Math]::Min($baseTop, [Math]::Max(0, [Console]::BufferHeight - 1)));
            $key = [Console]::ReadKey($true);
            $isPaste = $key.Key -eq 'V' -and $key.Modifiers.HasFlag([ConsoleModifiers]::Control);
            if ($key.Key -eq 'Enter') { Write-Host ""; [Console]::CursorVisible = $false; return $text; }
            if ($key.Key -eq 'Escape') { Write-Host ""; [Console]::CursorVisible = $false; return $null; }
            if ($key.Key -eq 'Backspace') {
                if ($cursor -gt 0) { $text = $text.Remove($cursor - 1, 1); $cursor--; }
                continue;
            }
            if ($key.Key -eq 'Delete') {
                if ($cursor -lt $text.Length) { $text = $text.Remove($cursor, 1); }
                continue;
            }
            if ($key.Key -eq 'LeftArrow') { if ($cursor -gt 0) { $cursor--; }; continue; }
            if ($key.Key -eq 'RightArrow') { if ($cursor -lt $text.Length) { $cursor++; }; continue; }
            if ($key.Key -eq 'Home') { $cursor = 0; continue; }
            if ($key.Key -eq 'End') { $cursor = $text.Length; continue; }
            if ($isPaste) {
                try {
                    $clip = Get-Clipboard -Raw -ErrorAction Stop;
                    if ($clip) {
                        $clip = ($clip -replace '[\r\n]+', ' ');
                        $text = $text.Insert($cursor, $clip);
                        $cursor += $clip.Length;
                    }
                } catch {}
                continue;
            }
            $ch = $key.KeyChar;
            if ($ch -and -not [char]::IsControl($ch)) {
                $text = $text.Insert($cursor, $ch);
                $cursor++;
            }
        }
    }

    function Read-ActionKey {
        while ([Console]::KeyAvailable) {
            $pending = [Console]::ReadKey($true);
            $nav = $pending.Key -eq 'UpArrow' -or $pending.Key -eq 'DownArrow' -or $pending.KeyChar -eq 'j' -or $pending.KeyChar -eq 'k' -or $pending.KeyChar -eq 'J' -or $pending.KeyChar -eq 'K';
            if (-not $nav) { return $pending; }
        }
        return [Console]::ReadKey($true);
    }

    function Wait-AnyKey {
        Write-Host "";
        Write-Host " Press any key to return" -ForegroundColor DarkGray;
        [Console]::CursorVisible = $false;
        $null = [Console]::ReadKey($true);
    }

    function Show-NeedRepo {
        Clear-Host;
        Write-Host "  Not a git repository." -ForegroundColor Red;
        Wait-AnyKey;
        Clear-Host;
    }

    $globalName = Get-One (& git config --global --get user.name 2>$null);
    $globalEmail = Get-One (& git config --global --get user.email 2>$null);
    if (-not $globalName) { $globalName = Get-One (& git config --get user.name 2>$null); }
    if (-not $globalEmail) { $globalEmail = Get-One (& git config --get user.email 2>$null); }
    Read-Ignored;

    [Console]::CursorVisible = $false;
    Clear-Host;

    try {
        while ($true) {
            $winWidth = 80;
            try {
                $w = [Console]::WindowWidth;
                if ($w -gt 1) { $winWidth = $w - 1; }
            } catch {}

            if ((Get-Norm $itemsPath) -ne (Get-Norm $currentPath)) {
                $cacheKey = Get-Norm $currentPath;
                if ($listingCache.ContainsKey($cacheKey)) {
                    $here = $listingCache[$cacheKey].Here;
                    $items = @($listingCache[$cacheKey].Items);
                } else {
                    Clear-Host;
                    Write-Host "  reading..." -ForegroundColor DarkGray;
                    $here = Get-Here $currentPath;
                    $items = @(Get-Listing $currentPath);
                    $listingCache[$cacheKey] = @{ Here = $here; Items = $items };
                }
                $itemsPath = $currentPath;
                $drawnPage = -1;
                if ($pendingSelectName) {
                    $found = 0;
                    for ($idx = 0; $idx -lt $items.Count; $idx++) {
                        if ($items[$idx].Name -eq $pendingSelectName) { $found = $idx; break; }
                    }
                    $selectedIndex = $found;
                    $pendingSelectName = "";
                } else {
                    $selectedIndex = 0;
                }
                Clear-Host;
            }

            $totalCount = $items.Count;
            if ($totalCount -gt 0) {
                if ($selectedIndex -ge $totalCount) { $selectedIndex = $totalCount - 1; }
                if ($selectedIndex -lt 0) { $selectedIndex = 0; }
            } else {
                $selectedIndex = 0;
            }
            $currentPage = if ($totalCount -gt 0) { [Math]::Floor($selectedIndex / $pageSize) } else { 0 };
            $totalPages = if ($totalCount -gt 0) { [Math]::Ceiling($totalCount / $pageSize) } else { 1 };
            $startIndex = $currentPage * $pageSize;

            $nameMax = 2;
            $branchMax = 0;
            $statusMax = 5;
            foreach ($item in $items) {
                $label = $item.Name;
                if ($item.IsDir -and -not $item.IsRepo) { $label += "\"; }
                $nw = 4 + (Get-VisualWidth $label);
                if ($nw -gt $nameMax) { $nameMax = $nw; }
                if ($item.IsRepo -and $item.Branch) {
                    $bw = Get-VisualWidth $item.Branch;
                    if ($bw -gt $branchMax) { $branchMax = $bw; }
                    $sw = if ($item.Dirty -eq 0) { 5 } else { "$($item.Dirty)".Length };
                    if ($sw -gt $statusMax) { $statusMax = $sw; }
                }
            }
            $nameStop = Get-NextStop $nameMax;
            $branchStop = Get-NextStop ($nameStop + $branchMax);
            $statusStop = Get-NextStop ($branchStop + $statusMax);

            if ($currentPage -ne $drawnPage) {
                Clear-Host;
                $drawnPage = $currentPage;
            }

            $target = Get-Target;
            $id = if ($target) { Get-Identity $target.FullName } else { @{ Name = $globalName; Email = $globalEmail } };
            $idName = if ([string]::IsNullOrWhiteSpace($id.Name)) { "?" } else { $id.Name };
            $idEmail = if ([string]::IsNullOrWhiteSpace($id.Email)) { "no email" } else { $id.Email };
            $idColor = if ([string]::IsNullOrWhiteSpace($id.Name) -or [string]::IsNullOrWhiteSpace($id.Email)) { "Red" } else { "Cyan" };

            $whereText = "  $currentPath";
            $whereColor = "Cyan";
            if ($here) {
                $hereTag = if ($here.Dirty -eq 0 -or (Test-Ignored $here.FullName)) { "clean" } else { "$($here.Dirty)" };
                $hereName = if (Test-Ignored $here.FullName) { "* $($here.Name)" } else { $here.Name };
                $whereText = "  $hereName · $($here.Branch) · $hereTag";
                if (-not (Test-Ignored $here.FullName)) {
                    if ($here.Ahead -gt 0) { $whereText += " +$($here.Ahead)"; }
                    if ($here.Behind -gt 0) { $whereText += " -$($here.Behind)"; }
                }
                $whereColor = if ((Test-Ignored $here.FullName) -or $here.Dirty -eq 0) { "Green" } else { "Yellow" };
            }

            [Console]::SetCursorPosition(0, 0);
            Write-FittedLine "  $idName <$idEmail>" $idColor $null;
            Write-FittedLine $whereText $whereColor $null;
            Write-FittedLine (Get-Rule) "DarkGray" $null;

            if ($totalCount -eq 0) {
                Write-FittedLine "  <Empty>" "DarkGray" $null;
                for ($k = 1; $k -lt $pageSize; $k++) { Write-FittedLine "" "White" $null; }
            } else {
                for ($i = 0; $i -lt $pageSize; $i++) {
                    $actual = $startIndex + $i;
                    if ($actual -lt $totalCount) {
                        $item = $items[$actual];
                        if ($actual -eq $selectedIndex) {
                            Write-FittedLine (Get-RowText $item) "White" "DarkCyan";
                        } else {
                            Write-FittedLine (Get-RowText $item) (Get-RowColor $item) $null;
                        }
                    } else {
                        Write-FittedLine "" "White" $null;
                    }
                }
            }

            Write-FittedLine (Get-Rule) "DarkGray" $null;
            $pageTag = " $($currentPage + 1)/$totalPages";
            Write-FittedLine " $pageTag  [C] Commit  [Shift+C] Edit  [L] Pull  [P] Push  [I] Ignore  [D] Trash  [G] Desktop  [V] Code  [Q] Quit" "Green" $null;

            $key = Read-ActionKey;
            $isUp = $key.Key -eq 'UpArrow' -or $key.KeyChar -eq 'k' -or $key.KeyChar -eq 'K';
            $isDown = $key.Key -eq 'DownArrow' -or $key.KeyChar -eq 'j' -or $key.KeyChar -eq 'J';
            $isLeft = $key.Key -eq 'LeftArrow' -or $key.KeyChar -eq 'h' -or $key.KeyChar -eq 'H';
            $isRight = $key.Key -eq 'RightArrow';

            if ($isUp) {
                if ($totalCount -gt 0) {
                    if ($selectedIndex -eq 0) { $selectedIndex = $totalCount - 1; } else { $selectedIndex--; }
                }
                continue;
            }
            if ($isDown) {
                if ($totalCount -gt 0) {
                    if ($selectedIndex -eq ($totalCount - 1)) { $selectedIndex = 0; } else { $selectedIndex++; }
                }
                continue;
            }
            if ($isLeft -or $key.Key -eq 'Backspace') {
                $parent = $currentPath | Split-Path -Parent;
                if ($parent) {
                    $pendingSelectName = Split-Path -Leaf $currentPath;
                    $currentPath = $parent;
                }
                continue;
            }
            if ($isRight) {
                if ($totalCount -gt 0 -and $items[$selectedIndex].IsDir) {
                    $currentPath = $items[$selectedIndex].FullName;
                }
                continue;
            }
            if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') {
                Set-Location -LiteralPath $currentPath;
                Clear-Host;
                return;
            }
            if ($key.KeyChar -eq ',' -or $key.KeyChar -eq '<') {
                if ($currentPage -gt 0) { $selectedIndex = ($currentPage - 1) * $pageSize; }
                continue;
            }
            if ($key.KeyChar -eq '.' -or $key.KeyChar -eq '>') {
                if ($currentPage -lt ($totalPages - 1)) { $selectedIndex = ($currentPage + 1) * $pageSize; }
                continue;
            }

            $target = Get-Target;
            $selected = Get-SelectedItem;

            if ($key.Key -eq 'G') {
                $openPath = $currentPath;
                if ($selected -and $selected.IsDir) { $openPath = $selected.FullName; }
                elseif ($selected) { $openPath = Split-Path -Parent $selected.FullName; }
                elseif ($target) { $openPath = $target.FullName; }
                if (-not (Start-GApp (Find-GitHubCmd) $openPath)) { Show-OpenFailed "GitHub Desktop"; }
                continue;
            }

            if ($key.Key -eq 'V') {
                $openPath = if ($selected) { $selected.FullName } else { $currentPath };
                if (-not (Start-GApp (Find-CodeCmd) $openPath)) { Show-OpenFailed "VS Code"; }
                continue;
            }

            if ($key.Key -eq 'D') {
                if ($totalCount -gt 0) {
                    $selectedItem = $items[$selectedIndex];
                    $skipConfirm = $key.Modifiers.HasFlag([ConsoleModifiers]::Shift);
                    $shouldDelete = $false;
                    if ($skipConfirm) {
                        $shouldDelete = $true;
                    } else {
                        [Console]::CursorVisible = $true;
                        Write-Host "";
                        $confirm = Read-Host "  Move [$($selectedItem.Name)] to Recycle Bin? (Y/n)";
                        [Console]::CursorVisible = $false;
                        if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm -eq 'y' -or $confirm -eq 'Y') {
                            $shouldDelete = $true;
                        }
                    }
                    if ($shouldDelete) {
                        try {
                            if ($selectedItem.IsDir) {
                                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($selectedItem.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin');
                            } else {
                                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($selectedItem.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin');
                            }
                            $norm = Get-Norm $selectedItem.FullName;
                            $items = @($items | Where-Object { (Get-Norm $_.FullName) -ne $norm });
                            $cacheKey = Get-Norm $currentPath;
                            if ($listingCache.ContainsKey($cacheKey)) { $listingCache[$cacheKey].Items = $items; }
                            if ($listingCache.ContainsKey($norm)) { [void]$listingCache.Remove($norm); }
                            if ($selectedIndex -ge $items.Count) { $selectedIndex = [Math]::Max(0, $items.Count - 1); }
                        } catch {
                            Write-Host "  Delete failed: $_" -ForegroundColor Red;
                            $null = [Console]::ReadKey($true);
                        }
                    }
                    Clear-Host;
                }
                continue;
            }

            if ($key.Key -eq 'I') {
                $markPath = $null;
                if ($selected -and $selected.IsDir) { $markPath = $selected.FullName; }
                elseif ($target) { $markPath = $target.FullName; }
                if ($markPath) {
                    $norm = Get-Norm $markPath;
                    if ($ignored.ContainsKey($norm)) { [void]$ignored.Remove($norm); }
                    else { $ignored[$norm] = $true; }
                    Save-Ignored;
                }
                continue;
            }

            if ($key.Key -eq 'C' -and -not $key.Modifiers.HasFlag([ConsoleModifiers]::Control)) {
                if (-not $target) { Show-NeedRepo; continue; }
                $edit = $key.Modifiers.HasFlag([ConsoleModifiers]::Shift);
                if (-not $edit) {
                    $result = Invoke-QuietCommit $target.FullName $defaultMessage;
                    Refresh-Repo $target.FullName;
                    if (-not $result.Ok) {
                        Clear-Host;
                        Write-Host $result.Text -ForegroundColor Red;
                        Wait-AnyKey;
                        Clear-Host;
                    }
                    continue;
                }
                Clear-Host;
                [Console]::CursorVisible = $true;
                $cid = Get-Identity $target.FullName;
                $cn = if ($cid.Name) { $cid.Name } else { "?" };
                $ce = if ($cid.Email) { $cid.Email } else { "no email" };
                Write-Host "  $cn <$ce>" -ForegroundColor Cyan;
                Write-Host "  $($target.Name) · $($target.Branch)" -ForegroundColor Cyan;
                if ($edit) {
                    Write-Host (Get-Rule) -ForegroundColor DarkGray;
                    Write-Host "  Message is already filled. Enter commits it. Esc cancels." -ForegroundColor DarkGray;
                    Write-Host "";
                    $message = Read-GLine " message: " $defaultMessage;
                    if ($null -eq $message -or [string]::IsNullOrWhiteSpace($message)) {
                        Write-Host "  Cancelled." -ForegroundColor DarkGray;
                        Wait-AnyKey;
                        Clear-Host;
                        continue;
                    }
                }
                Write-Host "";
                & git -C $target.FullName add -A;
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  git add failed." -ForegroundColor Red;
                } else {
                    & git -C $target.FullName commit -m $message;
                }
                Refresh-Repo $target.FullName;
                Wait-AnyKey;
                Clear-Host;
                continue;
            }

            if ($key.Key -eq 'L') {
                if (-not $target) { Show-NeedRepo; continue; }
                Clear-Host;
                [Console]::CursorVisible = $true;
                $lid = Get-Identity $target.FullName;
                $ln = if ($lid.Name) { $lid.Name } else { "?" };
                $le = if ($lid.Email) { $lid.Email } else { "no email" };
                Write-Host "  $ln <$le>" -ForegroundColor Cyan;
                if (-not $target.Branch -or $target.Branch -like 'HEAD *') {
                    Write-Host "  $($target.Name) has no branch to pull." -ForegroundColor Red;
                    Wait-AnyKey;
                    Clear-Host;
                    continue;
                }
                if ($target.Detached) {
                    & git -C $target.FullName switch -- $target.Branch;
                    if ($LASTEXITCODE -ne 0) {
                        Wait-AnyKey;
                        Clear-Host;
                        continue;
                    }
                }
                $remote = "origin";
                $remotes = @(& git -C $target.FullName remote 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ });
                if ($remotes -notcontains 'origin' -and $remotes.Count -gt 0) { $remote = $remotes[0]; }
                if ($target.Upstream) {
                    Write-Host "  $($target.Upstream) -> $($target.Branch)" -ForegroundColor Cyan;
                    Write-Host "";
                    & git -C $target.FullName pull;
                } elseif ($remotes.Count -eq 0) {
                    Write-Host "  No git remote." -ForegroundColor Red;
                } else {
                    Write-Host "  ${remote}/$($target.Branch) -> $($target.Branch)" -ForegroundColor Cyan;
                    Write-Host "";
                    & git -C $target.FullName pull $remote $target.Branch;
                }
                Refresh-Repo $target.FullName;
                Wait-AnyKey;
                Clear-Host;
                continue;
            }

            if ($key.Key -eq 'P') {
                if (-not $target) { Show-NeedRepo; continue; }
                Clear-Host;
                [Console]::CursorVisible = $true;
                $pidId = Get-Identity $target.FullName;
                $pn = if ($pidId.Name) { $pidId.Name } else { "?" };
                $pe = if ($pidId.Email) { $pidId.Email } else { "no email" };
                Write-Host "  $pn <$pe>" -ForegroundColor Cyan;
                if (-not $target.Branch -or $target.Branch -like 'HEAD *') {
                    Write-Host "  $($target.Name) has no branch to push." -ForegroundColor Red;
                    Wait-AnyKey;
                    Clear-Host;
                    continue;
                }
                if ($target.Detached) {
                    & git -C $target.FullName switch -- $target.Branch;
                    if ($LASTEXITCODE -ne 0) {
                        Wait-AnyKey;
                        Clear-Host;
                        continue;
                    }
                }
                $remote = "origin";
                $remotes = @(& git -C $target.FullName remote 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ });
                if ($remotes -notcontains 'origin' -and $remotes.Count -gt 0) { $remote = $remotes[0]; }
                if ($target.Upstream) {
                    Write-Host "  $($target.Branch) -> $($target.Upstream)" -ForegroundColor Cyan;
                    Write-Host "";
                    & git -C $target.FullName push;
                } elseif ($remotes.Count -eq 0) {
                    Write-Host "  No git remote." -ForegroundColor Red;
                } else {
                    Write-Host "  $($target.Branch) -> ${remote}/$($target.Branch)" -ForegroundColor Cyan;
                    Write-Host "";
                    & git -C $target.FullName push -u $remote $target.Branch;
                }
                Refresh-Repo $target.FullName;
                Wait-AnyKey;
                Clear-Host;
                continue;
            }

            if ($key.Key -eq 'Enter') {
                if ($target) {
                    while ($true) {
                        Clear-Host;
                        $eid = Get-Identity $target.FullName;
                        $en = if ($eid.Name) { $eid.Name } else { "?" };
                        $ee = if ($eid.Email) { $eid.Email } else { "no email" };
                        Write-Host "  $en <$ee>" -ForegroundColor Cyan;
                        Write-Host "  $($target.Name)" -ForegroundColor Cyan;
                        Write-Host "";
                        & git -C $target.FullName -c color.ui=always --no-pager status;
                        Write-Host "";
                        Write-Host "  [R] Discard all changes    [any other key] Return" -ForegroundColor DarkGray;
                        [Console]::CursorVisible = $false;
                        $statusKey = [Console]::ReadKey($true);
                        if ($statusKey.Key -ne 'R') { break; }
                        [Console]::CursorVisible = $true;
                        Write-Host "";
                        $answer = Read-Host "  Discard all changes in $($target.Name)? (y/N)";
                        if ($answer -eq 'y' -or $answer -eq 'Y') {
                            Write-Host "";
                            & git -C $target.FullName reset --hard;
                            if ($LASTEXITCODE -eq 0) {
                                & git -C $target.FullName clean -fd;
                            }
                            Refresh-Repo $target.FullName;
                        }
                    }
                    Clear-Host;
                } elseif ($totalCount -gt 0 -and $items[$selectedIndex].IsDir) {
                    $currentPath = $items[$selectedIndex].FullName;
                }
                continue;
            }
        }
    } finally {
        [Console]::CursorVisible = $true;
    }
}
