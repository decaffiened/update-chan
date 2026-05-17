# =========================================================
# update-chan.ps1 - Ventoy ISO Manager v9.0 ~(^w^)~
# =========================================================

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Host "`n [ERR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host " Line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkRed
    if ($_.ScriptStackTrace) {
        Write-Host " Stack: $($_.ScriptStackTrace.Split("`n")[0])" -ForegroundColor DarkRed
    }
    Read-Host "`n press Enter to exit"
    exit 1
}

# ====================== TLS SETUP ======================
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Warning "Could not set TLS version — HTTPS downloads may fail." }
}

# ====================== GLOBALS ======================
$Global:MenuMemory  = @{}
$Global:DownloadQueue = [System.Collections.Generic.List[pscustomobject]]::new()
$Global:Version     = "9.0"
$Global:AppTitle    = "Ventoy ISO Manager v$Global:Version"
$Global:PageSize    = 14
$Global:UIWidth     = 84

# ====================== UI HELPERS ======================
function Get-Border {
    param([int]$W = $Global:UIWidth)
    return "+" + ("-" * ($W - 2)) + "+"
}

function Write-Box {
    param([string[]]$Lines, [string]$Color = "Magenta", [int]$Width = $Global:UIWidth)
    $border = Get-Border $Width
    Write-Host $border -ForegroundColor $Color
    foreach ($line in $Lines) {
        $text = if ($line.Length -gt ($Width - 4)) { $line.Substring(0, $Width - 7) + "..." } else { $line }
        Write-Host ("| " + $text.PadRight($Width - 4) + " |") -ForegroundColor $Color
    }
    Write-Host $border -ForegroundColor $Color
}

function Write-Row {
    param([string]$Text = "", [string]$Color = "White", [int]$Width = $Global:UIWidth)
    $text = if ($Text.Length -gt ($Width - 4)) { $Text.Substring(0, $Width - 7) + "..." } else { $Text }
    Write-Host ("| " + $text.PadRight($Width - 4) + " |") -ForegroundColor $Color
}

function Write-Divider {
    param([string]$Color = "DarkGray", [int]$Width = $Global:UIWidth)
    Write-Host ("+" + ("-" * ($Width - 2)) + "+") -ForegroundColor $Color
}

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Box @(" update-chan.ps1 ~(^w^)~  ISO Manager v$Global:Version") -Color Magenta
    Write-Host ""
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -lt 0)         { return "unknown" }
    if ($Bytes -ge 1GB)       { return "{0:F2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB)       { return "{0:F1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB)       { return "{0:F0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Speed {
    param([double]$BytesPerSec)
    if ($BytesPerSec -le 0)   { return "---" }
    if ($BytesPerSec -ge 1MB) { return "{0:F1} MB/s" -f ($BytesPerSec / 1MB) }
    if ($BytesPerSec -ge 1KB) { return "{0:F0} KB/s" -f ($BytesPerSec / 1KB) }
    return "$([int]$BytesPerSec) B/s"
}

function Normalize-Text {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '')
}

# ====================== DRIVE HELPERS ======================
function Get-VentoyDrives {
    <#
    .SYNOPSIS
    Returns a list of drives that look like Ventoy drives (have a ventoy\ folder).
    #>
    $candidates = @()
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                  Where-Object { $_.Root -match '^[A-Z]:\\$' }
        foreach ($d in $drives) {
            $ventoyDir = Join-Path $d.Root "ventoy"
            if (Test-Path $ventoyDir -PathType Container) {
                $free = try { (Get-PSDrive $d.Name).Free } catch { -1 }
                $candidates += [pscustomobject]@{
                    Letter = $d.Name
                    Root   = $d.Root
                    Free   = $free
                    Label  = try { (Get-Volume -DriveLetter $d.Name -ErrorAction Stop).FileSystemLabel } catch { "" }
                }
            }
        }
    } catch { }
    return $candidates
}

function Select-VentoyDrive {
    $detected = Get-VentoyDrives

    Show-Header
    Write-Divider -Color Cyan
    Write-Row " Drive Selection" -Color Cyan
    Write-Divider -Color Cyan

    if ($detected.Count -gt 0) {
        Write-Row " Detected Ventoy drives:" -Color Green
        foreach ($d in $detected) {
            $freeStr = if ($d.Free -ge 0) { Format-Bytes $d.Free + " free" } else { "?" }
            $label   = if ($d.Label) { " [$($d.Label)]" } else { "" }
            Write-Row "   $($d.Letter):\ $label  -  $freeStr" -Color Yellow
        }
        Write-Divider -Color DarkGray
    }

    Write-Row " Enter drive letter (e.g. E) or press Enter to use first detected drive:" -Color White
    Write-Divider -Color DarkGray
    Write-Host "  > " -NoNewline -ForegroundColor Cyan
    $input = (Read-Host).Trim().ToUpper()

    if ([string]::IsNullOrWhiteSpace($input)) {
        if ($detected.Count -gt 0) {
            return $detected[0].Root
        }
        Write-Row " No drive specified and none detected." -Color Red
        Read-Host " press Enter to exit"
        exit 1
    }

    if ($input -match '^[A-Z]$') { return "$input`:\" }

    # allow "E:" or "E:\" too
    if ($input -match '^([A-Z]):?\\?$') { return "$($Matches[1])`:\" }

    Write-Row " Invalid drive letter: $input" -Color Red
    Read-Host " press Enter"
    exit 1
}

function Test-DriveWritable {
    param([string]$Drive)
    $probe = Join-Path $Drive (".wtest_" + [Guid]::NewGuid().ToString("N").Substring(0,8))
    try {
        [IO.File]::WriteAllText($probe, "test")
        Remove-Item $probe -Force
        return $true
    } catch {
        return $false
    }
}

function Get-DriveFreeSpace {
    param([string]$Drive)
    try {
        $letter = $Drive.TrimEnd('\').TrimEnd(':')
        return (Get-PSDrive $letter -ErrorAction Stop).Free
    } catch {
        return -1
    }
}

# ====================== RESOLVER ======================
function Compare-VersionString {
    <# Natural-sort helper: "22.04.1" > "20.04" > "9.3" #>
    param([string]$A, [string]$B)
    $pa = $A -split '[.\-_]'
    $pb = $B -split '[.\-_]'
    $len = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $sa = if ($i -lt $pa.Count) { $pa[$i] } else { "0" }
        $sb = if ($i -lt $pb.Count) { $pb[$i] } else { "0" }
        $ia = 0; $ib = 0
        $numA = [int]::TryParse($sa, [ref]$ia)
        $numB = [int]::TryParse($sb, [ref]$ib)
        if ($numA -and $numB) {
            if ($ia -ne $ib) { return ($ia - $ib) }
        } else {
            $c = [string]::Compare($sa, $sb, $true)
            if ($c -ne 0) { return $c }
        }
    }
    return 0
}

function Get-RemoteFileSize {
    param([string]$Url)
    try {
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Method = "HEAD"
        $req.Timeout = 8000
        $req.UserAgent = "Mozilla/5.0"
        $resp = $req.GetResponse()
        $len = $resp.ContentLength
        $resp.Close()
        return $len
    } catch {
        return -1
    }
}

function Resolve-Entry {
    param($Entry, [switch]$ShowProgress)

    if (-not $Entry) { return $null }

    # Helper: safe property read under StrictMode (missing prop = $null, not an error)
    function EP([object]$O, [string]$P) {
        $prop = $O.PSObject.Properties[$P]
        if ($null -eq $prop) { return $null }
        return $prop.Value
    }

    $eUrl      = EP $Entry 'url'
    $eFile     = EP $Entry 'file'
    $eResolver = EP $Entry 'resolver'
    $ePageUrl  = EP $Entry 'page_url'
    $eRegex    = EP $Entry 'regex'

    # Already fully resolved (has both url and file)
    if ($eUrl -and $eFile) {
        return [pscustomobject]@{ url = $eUrl; file = $eFile; size = -1 }
    }

    # Has URL but no file - try to derive filename from URL
    if ($eUrl) {
        $derivedFile = Split-Path $eUrl -Leaf
        # If URL ends with / or has no filename, or is a page not a file
        if (-not $derivedFile -or $derivedFile -eq "" -or $derivedFile -notmatch '\.(iso|img|ova|zip)$') {
            $derivedFile = "downloaded.iso"
        }
        return [pscustomobject]@{ url = $eUrl; file = $derivedFile; size = -1 }
    }

    # Direct URL with explicit resolver
    if ($eResolver -eq "direct" -and $eUrl) {
        $file = Split-Path $eUrl -Leaf
        if (-not $file -or $file -like "*latest*" -or $file -notlike "*.iso") {
            $file = "downloaded.iso"
        }
        return [pscustomobject]@{ url = $eUrl; file = $file; size = -1 }
    }

    # Page scrape with regex
    if ($ePageUrl -and $eRegex) {
        try {
            if ($ShowProgress) { Write-Row " Fetching directory listing..." -Color DarkGray }
            $wr = Invoke-WebRequest -Uri $ePageUrl -UseBasicParsing -TimeoutSec 25 -UserAgent "Mozilla/5.0"
            $hits = [regex]::Matches($wr.Content, $eRegex, 'IgnoreCase')

            if ($hits.Count -gt 0) {
                # Version-sort descending, pick latest
                $sorted = $hits |
                    Select-Object -ExpandProperty Value |
                    Sort-Object { $_ } -Descending
                $isoName = $sorted[0]
                $base    = $ePageUrl.TrimEnd('/')
                $fullUrl = "$base/$isoName"
                return [pscustomobject]@{ url = $fullUrl; file = $isoName; size = -1 }
            }
            if ($ShowProgress) { Write-Row " Regex matched nothing on page." -Color DarkYellow }
        } catch {
            if ($ShowProgress) { Write-Row " Fetch failed: $($_.Exception.Message)" -Color Red }
        }
    }
    return $null
}

# ====================== ISO MANAGEMENT ======================
function Find-ExistingISO {
    param([string]$Drive, [string]$FileName)
    if (-not $FileName) { return $null }
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName).ToLowerInvariant()
    return Get-ChildItem -Path $Drive -Filter "*.iso" -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.BaseName.ToLowerInvariant() -eq $base } |
           Select-Object -First 1
}

function Remove-ISOFromDrive {
    param([string]$Drive)
    Show-Header
    Write-Divider -Color Red
    Write-Row " Delete ISO from Drive" -Color Red
    Write-Divider -Color Red

    $isos = @(Get-ChildItem -Path $Drive -Filter "*.iso" -Recurse -ErrorAction SilentlyContinue)
    if ($isos.Count -eq 0) {
        Write-Row " No ISOs found on drive." -Color Yellow
        Read-Host " press Enter"
        return
    }

    $choice = Show-Selector `
        -MenuId "delete_iso" `
        -Title "[ SELECT ISO TO DELETE ]" `
        -Items $isos `
        -GetLabel { param($f) "$($f.Name)  ($(Format-Bytes $f.Length))" } `
        -AllowBack

    if ($null -eq $choice) { return }

    Show-Header
    Write-Divider -Color Red
    Write-Row " WARNING: This will permanently delete:" -Color Red
    Write-Row "   $($choice.FullName)" -Color Yellow
    Write-Row "   Size: $(Format-Bytes $choice.Length)" -Color White
    Write-Divider -Color DarkGray
    Write-Host " Type 'yes' to confirm: " -NoNewline -ForegroundColor Red
    $confirm = (Read-Host).Trim().ToLower()
    if ($confirm -eq "yes") {
        try {
            Remove-Item $choice.FullName -Force
            Write-Row " Deleted successfully." -Color Green
        } catch {
            Write-Row " Delete failed: $($_.Exception.Message)" -Color Red
        }
    } else {
        Write-Row " Cancelled." -Color DarkGray
    }
    Read-Host " press Enter"
}

function Show-DriveContents {
    param([string]$Drive)
    Show-Header
    Write-Divider -Color Cyan
    Write-Row " ISOs on drive: $Drive" -Color Cyan
    Write-Divider -Color Cyan

    $isos = @(Get-ChildItem -Path $Drive -Filter "*.iso" -Recurse -ErrorAction SilentlyContinue |
              Sort-Object Name)

    if ($isos.Count -eq 0) {
        Write-Row " No ISOs found." -Color DarkGray
    } else {
        $total = ($isos | Measure-Object -Property Length -Sum).Sum
        foreach ($f in $isos) {
            $rel = $f.FullName.Substring($Drive.Length)
            Write-Row ("  " + $rel.PadRight(55) + (Format-Bytes $f.Length).PadLeft(12)) -Color White
        }
        Write-Divider -Color DarkGray
        Write-Row ("  Total: $($isos.Count) ISO(s)   $(Format-Bytes $total)") -Color Yellow
    }

    $free = Get-DriveFreeSpace $Drive
    if ($free -ge 0) {
        Write-Row ("  Free space on drive: $(Format-Bytes $free)") -Color DarkCyan
    }
    Write-Divider -Color DarkGray
    Read-Host " press Enter"
}

# ====================== DOWNLOAD ENGINE ======================
function Invoke-DownloadWithProgress {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$DisplayName,
        [long]$KnownSize = -1
    )

    $tmpFile = $OutFile + ".part"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $client  = $null

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $req.Timeout   = [System.Threading.Timeout]::Infinite
        $req.ReadWriteTimeout = [System.Threading.Timeout]::Infinite

        # Resume support
        $resumeOffset = 0L
        if (Test-Path $tmpFile) {
            $resumeOffset = (Get-Item $tmpFile).Length
            if ($resumeOffset -gt 0) {
                $req.AddRange($resumeOffset)
                Write-Row " Resuming from $(Format-Bytes $resumeOffset)..." -Color DarkYellow
            }
        }

        $resp       = $req.GetResponse()
        $totalBytes = if ($KnownSize -gt 0) { $KnownSize }
                      elseif ($resp.ContentLength -gt 0) { $resp.ContentLength + $resumeOffset }
                      else { -1L }

        $stream  = $resp.GetResponseStream()
        $fs      = [System.IO.FileStream]::new($tmpFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 65536)
        $buf     = New-Object byte[] 65536
        $written = $resumeOffset
        $lastReport = [System.Diagnostics.Stopwatch]::StartNew()
        $speedBytes  = 0L
        $speedWindow = [System.Diagnostics.Stopwatch]::StartNew()

        Write-Row " Downloading: $DisplayName" -Color Cyan
        Write-Divider -Color DarkGray

        try {
            while ($true) {
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -le 0) { break }
                $fs.Write($buf, 0, $read)
                $written   += $read
                $speedBytes += $read

                if ($lastReport.ElapsedMilliseconds -ge 250) {
                    $elapsed = $sw.Elapsed.TotalSeconds
                    $speed   = if ($speedWindow.Elapsed.TotalSeconds -gt 0) {
                                   $speedBytes / $speedWindow.Elapsed.TotalSeconds
                               } else { 0 }

                    if ($speedWindow.ElapsedMilliseconds -ge 1000) {
                        $speedBytes = 0
                        $speedWindow.Restart()
                    }

                    $pct = if ($totalBytes -gt 0) {
                        [Math]::Min(100, [int](($written / $totalBytes) * 100))
                    } else { -1 }

                    $eta = if ($totalBytes -gt 0 -and $speed -gt 0) {
                        $remaining = $totalBytes - $written
                        $secs = [int]($remaining / $speed)
                        "{0:D2}:{1:D2}" -f ([int]($secs / 60)), ($secs % 60)
                    } else { "--:--" }

                    $bar = ""
                    if ($pct -ge 0) {
                        $filled = [int]($pct / 5)
                        $bar = "[" + ("=" * $filled) + ("." * (20 - $filled)) + "] $pct%"
                    }

                    $status = " $(Format-Bytes $written)"
                    if ($totalBytes -gt 0) { $status += " / $(Format-Bytes $totalBytes)" }
                    $status += "  $(Format-Speed $speed)  ETA $eta"
                    if ($bar) { $status = " $bar $status" }

                    Write-Host ("`r" + $status.PadRight($Global:UIWidth - 2)) -NoNewline -ForegroundColor DarkCyan
                    $lastReport.Restart()
                }
            }
        } finally {
            $fs.Flush()
            $fs.Dispose()
            $stream.Dispose()
            $resp.Dispose()
        }

        Write-Host ""  # newline after progress

        # Atomic rename
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        Move-Item $tmpFile $OutFile -Force
        return $true

    } catch [System.Threading.ThreadAbortException] {
        Write-Host ""
        Write-Row " Download interrupted." -Color DarkYellow
        return $false
    } catch {
        Write-Host ""
        Write-Row " Download error: $($_.Exception.Message)" -Color Red
        return $false
    } finally {
        $sw.Stop()
        if ($client) { try { $client.Dispose() } catch {} }
    }
}

function Invoke-ISODownload {
    param([string]$Name, $Entry, [string]$Drive)

    if (-not $Entry -or -not $Entry.url) {
        Write-Row " No download URL available." -Color Red
        Read-Host " press Enter"
        return
    }

    $existing = Find-ExistingISO $Drive $Entry.file
    if ($existing) {
        Show-Header
        Write-Divider -Color Yellow
        Write-Row " ISO already exists on drive:" -Color Yellow
        Write-Row "   $($existing.FullName)" -Color White
        Write-Row "   Size: $(Format-Bytes $existing.Length)" -Color DarkGray
        Write-Divider -Color DarkGray
        Write-Row " [R] Re-download    [Esc] Cancel" -Color DarkCyan
        $k = [Console]::ReadKey($true)
        if ($k.Key -ne "R") { return }
        Remove-Item $existing.FullName -Force
    }

    $outPath = Join-Path $Drive $Entry.file
    New-Item (Split-Path $outPath -Parent) -ItemType Directory -Force | Out-Null

    # Check free space
    $freeSpace = Get-DriveFreeSpace $Drive
    $remoteSize = Get-RemoteFileSize $Entry.url

    Show-Header
    Write-Divider -Color Cyan
    Write-Row " Download: $Name" -Color Cyan
    Write-Divider -Color Cyan
    Write-Row " URL:    $($Entry.url)" -Color DarkGray
    Write-Row " Target: $outPath" -Color White
    if ($remoteSize -gt 0) { Write-Row " Size:   $(Format-Bytes $remoteSize)" -Color DarkCyan }
    if ($freeSpace -ge 0)  { Write-Row " Free:   $(Format-Bytes $freeSpace)"  -Color DarkCyan }

    if ($remoteSize -gt 0 -and $freeSpace -ge 0 -and $remoteSize -gt $freeSpace) {
        Write-Divider -Color Red
        Write-Row " WARNING: Not enough free space! $(Format-Bytes ($remoteSize - $freeSpace)) short." -Color Red
        Write-Divider -Color Red
        Read-Host " press Enter"
        return
    }

    Write-Divider -Color DarkGray

    $ok = Invoke-DownloadWithProgress -Url $Entry.url -OutFile $outPath -DisplayName $Name -KnownSize $remoteSize

    Write-Divider -Color DarkGray
    if ($ok) {
        Write-Row " Download complete! ~(^w^)~" -Color Green
        $size = if (Test-Path $outPath) { Format-Bytes (Get-Item $outPath).Length } else { "?" }
        Write-Row " Saved: $outPath  ($size)" -Color DarkGreen
    } else {
        Write-Row " Download did not complete. Partial file kept as .part" -Color DarkYellow
    }
    Write-Divider -Color DarkGray
    Read-Host " press Enter"
}

# ====================== QUEUE SYSTEM ======================
function Add-ToQueue {
    param([string]$Name, $Entry)
    $exists = $Global:DownloadQueue | Where-Object { $_.Entry.url -eq $Entry.url }
    if ($exists) {
        Write-Row " Already in queue: $Name" -Color DarkYellow
    } else {
        $Global:DownloadQueue.Add([pscustomobject]@{ Name = $Name; Entry = $Entry })
        Write-Row " Added to queue: $Name" -Color Green
    }
    Start-Sleep -Milliseconds 600
}

function Show-DownloadQueue {
    param([string]$Drive)
    while ($true) {
        Show-Header
        Write-Divider -Color Cyan
        Write-Row " Download Queue  ($($Global:DownloadQueue.Count) items)" -Color Cyan
        Write-Divider -Color Cyan

        if ($Global:DownloadQueue.Count -eq 0) {
            Write-Row " Queue is empty." -Color DarkGray
            Write-Divider -Color DarkGray
            Read-Host " press Enter"
            return
        }

        $i = 0
        foreach ($item in $Global:DownloadQueue) {
            $i++
            Write-Row "  $i. $($item.Name)" -Color White
            Write-Row "     $($item.Entry.url)" -Color DarkGray
        }

        Write-Divider -Color DarkGray
        Write-Row " [D] Download All   [C] Clear Queue   [Esc] Back" -Color DarkCyan
        Write-Divider -Color DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "D" {
                foreach ($item in $Global:DownloadQueue) {
                    Invoke-ISODownload -Name $item.Name -Entry $item.Entry -Drive $Drive
                }
                $Global:DownloadQueue.Clear()
                return
            }
            "C" {
                $Global:DownloadQueue.Clear()
                Write-Row " Queue cleared." -Color DarkGray
                Start-Sleep -Milliseconds 500
                return
            }
            "Escape" { return }
        }
    }
}

# ====================== SELECTOR ======================
function Show-Selector {
    param(
        [string]$MenuId,
        [string]$Title,
        [array]$Items,
        [scriptblock]$GetLabel,
        [scriptblock]$GetMeta = { "" },
        [switch]$AllowBack
    )

    if (-not $Items -or $Items.Count -eq 0) {
        Show-Header
        Write-Row " No items available." -Color DarkGray
        Read-Host " press Enter"
        return $null
    }

    if (-not $Global:MenuMemory.ContainsKey($MenuId)) {
        $Global:MenuMemory[$MenuId] = @{ Selected = 0; Offset = 0; Search = "" }
    }

    $state    = $Global:MenuMemory[$MenuId]
    $search   = $state.Search
    $selected = $state.Selected
    $offset   = $state.Offset
    $pageSize = $Global:PageSize

    while ($true) {
        $filtered = @($Items | Where-Object {
            [string]::IsNullOrWhiteSpace($search) -or
            (Normalize-Text (& $GetLabel $_)).Contains((Normalize-Text $search))
        })

        if ($selected -ge $filtered.Count) { $selected = [Math]::Max(0, $filtered.Count - 1) }
        if ($selected -lt $offset)         { $offset = $selected }
        if ($selected -ge $offset + $pageSize) { $offset = $selected - $pageSize + 1 }

        Show-Header
        Write-Divider -Color Cyan
        Write-Row $Title -Color Cyan
        if ($Global:DownloadQueue.Count -gt 0) {
            Write-Row "  Queue: $($Global:DownloadQueue.Count) item(s) pending" -Color DarkYellow
        }
        Write-Divider -Color Cyan
        $searchDisplay = if ($search) { $search } else { "(type to filter)" }
        Write-Row ("  Search: " + $searchDisplay) -Color Yellow
        Write-Row "  Up/Down = Navigate   Enter = Select   Q = Queue   Esc = Back" -Color DarkGray
        Write-Divider -Color DarkGray

        if ($filtered.Count -eq 0) {
            Write-Row "  No items match '$search'" -Color DarkGray
        } else {
            $end = [Math]::Min($filtered.Count - 1, $offset + $pageSize - 1)
            for ($i = $offset; $i -le $end; $i++) {
                $item   = $filtered[$i]
                $label  = & $GetLabel $item
                $meta   = & $GetMeta $item
                $isSelected = ($i -eq $selected)
                $prefix = if ($isSelected) { " >> " } else { "    " }
                $color  = if ($isSelected) { "Yellow" } else { "White" }
                $metaColor = if ($isSelected) { "DarkYellow" } else { "DarkGray" }
                $line   = $prefix + $label
                if ($meta) { $line += "  $meta" }
                Write-Row $line -Color $color
            }
            if ($filtered.Count -gt $pageSize) {
                Write-Divider -Color DarkGray
                Write-Row ("  Page: " + [int]([Math]::Floor($offset / $pageSize) + 1) + "/" + [int]([Math]::Ceiling($filtered.Count / $pageSize)) + "  ($($filtered.Count) items)") -Color DarkGray
            }
        }
        Write-Divider -Color DarkGray

        $Global:MenuMemory[$MenuId] = @{ Selected = $selected; Offset = $offset; Search = $search }

        $key = [Console]::ReadKey($true)
        $keyName = $key.Key.ToString()   # consistent string for switch

        switch ($keyName) {
            "UpArrow"   { if ($selected -gt 0) { $selected-- } }
            "DownArrow" { if ($selected -lt ($filtered.Count - 1)) { $selected++ } }
            "PageUp"    { $selected = [Math]::Max(0, $selected - $pageSize) }
            "PageDown"  { $selected = [Math]::Min([Math]::Max(0, $filtered.Count - 1), $selected + $pageSize) }
            "Home"      { $selected = 0 }
            "End"       { $selected = [Math]::Max(0, $filtered.Count - 1) }
            "Enter"     {
                if ($filtered.Count -gt 0) {
                    return $filtered[$selected]
                }
            }
            "Q"         {
                # Q with no search text = queue shortcut; otherwise treat as search char
                if ([string]::IsNullOrEmpty($search) -and $filtered.Count -gt 0) {
                    return [pscustomobject]@{ __queue = $true; __item = $filtered[$selected] }
                } else {
                    $search += $key.KeyChar
                    $selected = 0; $offset = 0
                }
            }
            "Escape"    {
                if ($search.Length -gt 0) { $search = ""; $selected = 0; $offset = 0 }
                elseif ($AllowBack) { return $null }
            }
            "Backspace" {
                if ($search.Length -gt 0) { $search = $search.Substring(0, $search.Length - 1) }
                elseif ($AllowBack) { return $null }
            }
            default {
                $ch = $key.KeyChar
                if ($ch -and -not [char]::IsControl($ch)) {
                    $search += $ch
                    $selected = 0
                    $offset = 0
                }
            }
        }
    }
}

# ====================== RECURSIVE MENU ======================
function Get-NodeItems {
    param($Node)
    $items = [System.Collections.Generic.List[pscustomobject]]::new()

    # Safe property existence check - required under Set-StrictMode -Version Latest
    # Accessing a missing property on a PSCustomObject throws under StrictMode
    function HasProp([object]$Obj, [string]$Name) {
        return $null -ne $Obj.PSObject.Properties[$Name]
    }

    # Helper to get display label for a property
    function Get-Label($Prop) {
        if ($Prop.Value -is [System.Management.Automation.PSCustomObject] -and $Prop.Value.label) {
            return $Prop.Value.label
        }
        return $Prop.Name
    }

    if (HasProp $Node 'children') {
        foreach ($ch in $Node.children.PSObject.Properties) {
            $items.Add([pscustomobject]@{ Name = (Get-Label $ch); Type = "submenu"; Entry = $ch.Value })
        }
    }

    if (HasProp $Node 'releases') {
        $versions = @($Node.releases.PSObject.Properties | Sort-Object {
            try { [version]($_.Name -replace '[^0-9.]','') } catch { [version]"0.0" }
        } -Descending)

        foreach ($ver in $versions) {
            foreach ($variant in $ver.Value.PSObject.Properties) {
                $resolved = Resolve-Entry $variant.Value
                if ($resolved) {
                    $items.Add([pscustomobject]@{
                        Name  = "$($ver.Name) - $($variant.Name)"
                        Type  = "download"
                        Entry = $resolved
                    })
                }
            }
        }
    }

    if (HasProp $Node 'variants') {
        foreach ($v in $Node.variants.PSObject.Properties) {
            $resolved = Resolve-Entry $v.Value
            if ($resolved) {
                $items.Add([pscustomobject]@{ Name = $v.Name; Type = "download"; Entry = $resolved })
            }
        }
    }

    # Handle 'latest' and 'install' keys that contain direct entries
    $directKeys = @('latest', 'install')
    foreach ($key in $directKeys) {
        if (HasProp $Node $key) {
            $resolved = Resolve-Entry $Node.$key
            if ($resolved) {
                $items.Add([pscustomobject]@{ Name = $key; Type = "download"; Entry = $resolved })
            }
        }
    }

    $skipKeys = @('label','type','children','releases','variants','latest','install')
    foreach ($prop in $Node.PSObject.Properties) {
        if ($prop.Name -in $skipKeys) { continue }
        $val = $prop.Value
        if ($val -is [System.Management.Automation.PSCustomObject]) {
            $resolved = Resolve-Entry $val
            if ($resolved) {
                $items.Add([pscustomobject]@{ Name = (Get-Label $prop); Type = "download"; Entry = $resolved })
            } else {
                # Check if this property has children/releases/variants/latest itself
                if ((HasProp $val 'children') -or (HasProp $val 'releases') -or (HasProp $val 'variants') -or (HasProp $val 'latest') -or (HasProp $val 'install')) {
                    $items.Add([pscustomobject]@{ Name = (Get-Label $prop); Type = "submenu"; Entry = $val })
                }
            }
        }
    }

    return $items.ToArray()
}

function Show-RecursiveMenu {
    param([string]$MenuId, [string]$Title, $Node, [string]$Drive)

    while ($true) {
        $items = @(Get-NodeItems $Node)

        if ($items.Count -eq 0) {
            Show-Header
            Write-Row " This section is empty in sources.json" -Color Yellow
            Read-Host " press Enter"
            return
        }

        $choice = Show-Selector `
            -MenuId    $MenuId `
            -Title     $Title `
            -Items     $items `
            -GetLabel  { param($i) $i.Name } `
            -GetMeta   { param($i) if ($i.Type -eq "submenu") { "[+]" } else { "[ISO]" } } `
            -AllowBack

        if ($null -eq $choice) { return }

        # Queue shortcut
        if ($choice.PSObject.Properties['__queue']) {
            $real = $choice.__item
            if ($real.Type -eq "download") {
                Add-ToQueue -Name $real.Name -Entry $real.Entry
            } else {
                Write-Row " Can only queue downloadable items." -Color DarkYellow
                Start-Sleep -Milliseconds 600
            }
            continue
        }

        if ($choice.Type -eq "submenu") {
            Show-RecursiveMenu `
                -MenuId ($MenuId + "/" + $choice.Name) `
                -Title  "[ $($choice.Name) ]" `
                -Node   $choice.Entry `
                -Drive  $Drive
        } elseif ($choice.Type -eq "download") {
            Show-Header
            Write-Divider -Color Cyan
            Write-Row " $($choice.Name)" -Color Cyan
            Write-Row " $($choice.Entry.url)" -Color DarkGray
            Write-Divider -Color DarkGray
            Write-Row " [D] Download Now   [Q] Add to Queue   [Esc] Cancel" -Color DarkCyan
            Write-Divider -Color DarkGray
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                "D"      { Invoke-ISODownload -Name $choice.Name -Entry $choice.Entry -Drive $Drive }
                "Q"      { Add-ToQueue -Name $choice.Name -Entry $choice.Entry }
                "Escape" { }
            }
        }
    }
}

# ====================== MAIN ======================
Show-Header
$Drive = Select-VentoyDrive

if (-not (Test-Path $Drive)) {
    Write-Row " Drive not found: $Drive" -Color Red
    Read-Host " press Enter"
    exit 1
}

if (-not (Test-DriveWritable $Drive)) {
    Write-Row " Drive is read-only or inaccessible: $Drive" -Color Red
    Read-Host " press Enter"
    exit 1
}

$ConfigFile = Join-Path $Drive "ventoy\tools\sources.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Host "`n sources.json not found at: $ConfigFile" -ForegroundColor Red
    Read-Host " press Enter"
    exit 1
}

$Sources = $null
try {
    $raw = Get-Content $ConfigFile -Raw -Encoding UTF8
    $Sources = $raw | ConvertFrom-Json
} catch {
    Write-Host "`n Failed to parse sources.json: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host " press Enter"
    exit 1
}

# Build main menu from ALL top-level sections in sources.json
$mainItems = [System.Collections.Generic.List[pscustomobject]]::new()

# Add Linux as a single big folder containing all linux.* subsections
if ($Sources.linux -is [System.Management.Automation.PSCustomObject]) {
    $mainItems.Add([pscustomobject]@{ 
        Name  = "Linux"
        Type  = "submenu"
        Entry = $Sources.linux
        Exit  = $false 
    })
}

# Add all other top-level sections (BSD, windows, recovery_tools, privacy_security, etc.)
$skipTopLevel = @('schema_version', 'generated', 'notes', 'linux')
foreach ($prop in $Sources.PSObject.Properties) {
    if ($prop.Name -in $skipTopLevel) { continue }
    if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
        # Use label if available, otherwise capitalize the key name
        $label = if ($prop.Value.label) { $prop.Value.label } else { (Get-Culture).TextInfo.ToTitleCase($prop.Name -replace '_', ' ') }
        $mainItems.Add([pscustomobject]@{ 
            Name  = $label
            Type  = "submenu"
            Entry = $prop.Value
            Exit  = $false 
        })
    }
}

# Add utility options
$mainItems.Add([pscustomobject]@{ Name = "View Drive Contents";  Type = "util"; Exit = $false })
$mainItems.Add([pscustomobject]@{ Name = "Delete ISO from Drive"; Type = "util"; Exit = $false })
$mainItems.Add([pscustomobject]@{ Name = "Download Queue";        Type = "util"; Exit = $false })
$mainItems.Add([pscustomobject]@{ Name = "Exit";                  Type = "exit"; Exit = $true  })

while ($true) {
    $choice = Show-Selector `
        -MenuId   "main" `
        -Title    "[ MAIN MENU ]  Drive: $Drive" `
        -Items    $mainItems.ToArray() `
        -GetLabel { param($i) $i.Name } `
        -GetMeta  { param($i)
            if ($i.Type -eq "exit") { "[x]" }
            elseif ($i.Type -eq "util") { "[*]" }
            else { "[+]" }
        }

    if ($null -eq $choice -or $choice.Exit) {
        Show-Header
        Write-Row " Thank you for using update-chan! v$Global:Version ~(^w^)~" -Color Magenta
        Write-Host ""
        exit 0
    }

    switch ($choice.Type) {
        "submenu" {
            Show-RecursiveMenu `
                -MenuId "main/$($choice.Name)" `
                -Title  "[ $($choice.Name) ]" `
                -Node   $choice.Entry `
                -Drive  $Drive
        }
        "util" {
            switch ($choice.Name) {
                "View Drive Contents"   { Show-DriveContents $Drive }
                "Delete ISO from Drive" { Remove-ISOFromDrive $Drive }
                "Download Queue"        { Show-DownloadQueue $Drive }
            }
        }
    }
}
