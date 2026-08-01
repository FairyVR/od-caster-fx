<#
.SYNOPSIS
    Downloads Orion Drift Competitive team logos into the fairy.casterfx package.

.DESCRIPTION
    The spectator Luau API has no HTTP client and LuauFile is sandboxed to the package
    folder, so the camera script cannot fetch anything itself. This script is the bridge:
    it queries https://oriondriftcompetitive.com/api/v1/teams, downloads the matching
    crests, re-encodes them to square PNGs and writes them to <package>\logos\<STEM>.png.

    STEM is the team name sanitized the same way util.luau's Util.sanitizeTeamName does:
    uppercased, then every UTF-8 byte that is not A-Z or 0-9 becomes an underscore. Both
    sides must agree or the camera will not find the file.

.PARAMETER Team
    One or more team names to fetch. Matching is exact first, then sanitized, then
    substring. Omit when using -Watch.

.PARAMETER Watch
    Poll the package's wanted.json (written by the camera script with the team names it
    detected in the live match) and fetch whatever appears there. Leave this running
    during a broadcast and logos arrive without you typing anything.

.PARAMETER FromSchedule
    List the scheduled ODC matches and fetch both crests for the one you pick, written as
    HOME.png / AWAY.png. This is the most reliable mode: the in-game teamName is the
    station's lobby name rather than the ODC one, so name matching often cannot work at all.

.PARAMETER Week
    Restrict -FromSchedule to one week number.

.PARAMETER AllLeagues
    Include leagues that are not in_progress in the -FromSchedule list.

.PARAMETER Refresh
    Re-download the team index instead of using the local cache.

.EXAMPLE
    .\get-logos.ps1 "SHOT" "TP!"

.EXAMPLE
    .\get-logos.ps1 -Watch

.EXAMPLE
    .\get-logos.ps1 -FromSchedule
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Team,

    [switch] $Watch,
    [switch] $Refresh,
    [switch] $ListMatches,
    [switch] $FromBridge,
    [switch] $FromSchedule,
    [switch] $AllLeagues,
    [int]    $Week = 0,

    [string] $PackagePath = (Join-Path $PSScriptRoot 'fairy.casterfx'),
    [int]    $Size = 512,
    [int]    $PollSeconds = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ApiRoot = 'https://oriondriftcompetitive.com/api/v1'
$ApiBase = "$ApiRoot/teams"
$UserAgent = 'fairy.casterfx-logo-fetch/1.0'
$CachePath = Join-Path $PSScriptRoot '.odc-teams-cache.json'
$LogoDir = Join-Path $PackagePath 'logos'

# Mirror of Util.sanitizeTeamName in util.luau. Walks UTF-8 bytes because the Luau side
# does its gsub over bytes, so multi-byte characters must collapse to one underscore each.
function Get-Stem {
    param([string] $Name)
    if ([string]::IsNullOrEmpty($Name)) { return 'TEAM' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Name.ToUpperInvariant())
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        $c = [char] $b
        if (($c -ge 'A' -and $c -le 'Z') -or ($c -ge '0' -and $c -le '9')) {
            [void] $sb.Append($c)
        } else {
            [void] $sb.Append('_')
        }
    }
    $out = $sb.ToString()
    if ($out.Length -eq 0) { return 'TEAM' }
    return $out
}

# GET /teams supports a server-side `search` (case-insensitive substring), so a single named
# lookup does not need the whole 777-team index. Falls back to the cached index when search
# returns nothing, since search only matches the ODC name and callers may pass a stem.
function Find-TeamRemote {
    param([string] $Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $null }
    try {
        $url = "$ApiBase`?search=$([uri]::EscapeDataString($Query))&limit=25"
        $resp = Invoke-RestMethod -Uri $url -UserAgent $UserAgent -TimeoutSec 30
    } catch {
        return $null
    }
    if (-not $resp.data -or $resp.data.Count -eq 0) { return $null }

    $exact = $resp.data | Where-Object { $_.name -and $_.name.ToUpperInvariant() -eq $Query.ToUpperInvariant() }
    if ($exact) { return @($exact)[0] }
    $wantStem = Get-Stem $Query
    $byStem = $resp.data | Where-Object { $_.name -and (Get-Stem $_.name) -eq $wantStem }
    if ($byStem) { return @($byStem)[0] }
    if ($resp.data.Count -eq 1) { return $resp.data[0] }
    Write-Warning ("'{0}' is ambiguous on the server. Candidates: {1}" -f $Query,
        (($resp.data | Select-Object -First 8 | ForEach-Object { $_.name }) -join ', '))
    return $null
}

function Get-TeamIndex {
    param([switch] $Force)

    if (-not $Force -and (Test-Path $CachePath)) {
        $age = (Get-Date) - (Get-Item $CachePath).LastWriteTime
        if ($age.TotalHours -lt 12) {
            return (Get-Content $CachePath -Raw | ConvertFrom-Json)
        }
    }

    Write-Host 'Fetching team index from oriondriftcompetitive.com...' -ForegroundColor Cyan
    $all = New-Object System.Collections.ArrayList
    $page = 1
    do {
        # limit is capped at 50 server-side ("Too big: expected number to be <=50").
        $url = "$ApiBase`?page=$page&limit=50"
        $resp = Invoke-RestMethod -Uri $url -UserAgent $UserAgent -TimeoutSec 30
        foreach ($t in $resp.data) { [void] $all.Add($t) }
        Write-Host ("  page {0}/{1} ({2} teams)" -f $page, $resp.totalPages, $all.Count)
        $page++
    } while ($resp.hasNextPage -and $page -le 100)

    $payload = $all.ToArray()
    $payload | ConvertTo-Json -Depth 6 | Out-File $CachePath -Encoding utf8
    Write-Host ("Cached {0} teams." -f $payload.Count) -ForegroundColor Green
    return $payload
}

function Find-Team {
    param($Index, [string] $Query)

    # Server-side search first: it is one request instead of paging 777 teams, and it stays
    # correct when a team is created after the local cache was written.
    $remote = Find-TeamRemote -Query $Query
    if ($remote) { return $remote }

    $exact = $Index | Where-Object { $_.name -and $_.name.ToUpperInvariant() -eq $Query.ToUpperInvariant() }
    if ($exact) { return @($exact)[0] }

    $wantStem = Get-Stem $Query
    $byStem = $Index | Where-Object { $_.name -and (Get-Stem $_.name) -eq $wantStem }
    if ($byStem) { return @($byStem)[0] }

    $partial = @($Index | Where-Object { $_.name -and $_.name.ToUpperInvariant().Contains($Query.ToUpperInvariant()) })
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) {
        Write-Warning ("'{0}' is ambiguous. Candidates: {1}" -f $Query, (($partial | Select-Object -First 8 | ForEach-Object { $_.name }) -join ', '))
        return $null
    }
    Write-Warning ("No ODC team matches '{0}'." -f $Query)
    return $null
}

# Re-encode to a square PNG so the Luau side only ever loads <STEM>.png, whatever the
# source format was (the CDN serves a mix of PNG and JPEG). Alpha is preserved; note the
# game uses cutout alpha, so semi-transparent edges will harden rather than blend.
function Save-SquarePng {
    param([byte[]] $Bytes, [string] $Path, [int] $Edge)

    $ms = New-Object System.IO.MemoryStream(, $Bytes)
    try {
        $src = [System.Drawing.Image]::FromStream($ms)
    } catch {
        throw "downloaded data is not a readable image: $($_.Exception.Message)"
    }
    try {
        $canvas = New-Object System.Drawing.Bitmap($Edge, $Edge, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $scale = [Math]::Min($Edge / $src.Width, $Edge / $src.Height)
            $w = [int] [Math]::Round($src.Width * $scale)
            $h = [int] [Math]::Round($src.Height * $scale)
            $g.DrawImage($src, [int](($Edge - $w) / 2), [int](($Edge - $h) / 2), $w, $h)
        } finally {
            $g.Dispose()
        }
        $canvas.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $canvas.Dispose()
    } finally {
        $src.Dispose()
        $ms.Dispose()
    }
}

function Get-Logo {
    param($Index, [string] $Query)

    $team = Find-Team -Index $Index -Query $Query
    if (-not $team) { return $false }
    if (-not $team.profilePicture) {
        Write-Warning ("'{0}' has no logo uploaded on ODC." -f $team.name)
        return $false
    }

    $stem = Get-Stem $team.name
    $dest = Join-Path $LogoDir "$stem.png"
    try {
        # -UseBasicParsing: without it PS 5.1 boots the IE parser, which dies outside an
        # interactive session, and .Content would be a string instead of bytes.
        $resp = Invoke-WebRequest -Uri $team.profilePicture -UserAgent $UserAgent -TimeoutSec 30 -UseBasicParsing
        Save-SquarePng -Bytes $resp.Content -Path $dest -Edge $Size
    } catch {
        Write-Warning ("Failed to fetch logo for '{0}': {1}" -f $team.name, $_.Exception.Message)
        return $false
    }
    Write-Host ("  {0}  ->  logos\{1}.png" -f $team.name, $stem) -ForegroundColor Green
    return $true
}

# OD Caster Bridge (github.com/dennssen/OD_Caster_Bridge) already solves the hard half of this:
# the caster uploads each team's crest through its UI, and it stores them BY SIDE at
#   %APPDATA%\ODCasterBridge\logos\{home,away}\{side}_{unixtime}.{ext}
# with the team names in data.json. Importing from there beats matching on teamName, because
# an ordinary lobby reports the same teamName for both sides -- the Bridge knows which is which
# because a human told it. Written out as HOME.png / AWAY.png, which the camera prefers.
function Import-FromBridge {
    $bridge = Join-Path $env:APPDATA 'ODCasterBridge'
    if (-not (Test-Path $bridge)) {
        Write-Warning "OD Caster Bridge data not found at $bridge -- is it installed and has it saved logos?"
        return 0
    }

    $names = @{}
    $dataPath = Join-Path $bridge 'data.json'
    if (Test-Path $dataPath) {
        try {
            $data = Get-Content $dataPath -Raw | ConvertFrom-Json
            foreach ($side in @('home', 'away')) {
                if ($data.teams -and $data.teams.$side -and $data.teams.$side.name) {
                    $names[$side] = $data.teams.$side.name
                }
            }
        } catch {
            Write-Warning "Could not parse $dataPath : $($_.Exception.Message)"
        }
    }

    $imported = 0
    foreach ($side in @('home', 'away')) {
        $dir = Join-Path $bridge "logos\$side"
        if (-not (Test-Path $dir)) { continue }
        # The Bridge empties the folder on each upload, so there is normally exactly one file;
        # take the newest regardless.
        $file = Get-ChildItem $dir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $file) { continue }

        $dest = Join-Path $LogoDir ("{0}.png" -f $side.ToUpperInvariant())
        try {
            Save-SquarePng -Bytes ([System.IO.File]::ReadAllBytes($file.FullName)) -Path $dest -Edge $Size
        } catch {
            Write-Warning ("Could not convert {0}: {1}" -f $file.Name, $_.Exception.Message)
            continue
        }
        $label = if ($names[$side]) { $names[$side] } else { '(name not set in Bridge)' }
        Write-Host ("  {0,-5} {1}  ->  logos\{2}.png" -f $side, $label, $side.ToUpperInvariant()) -ForegroundColor Green
        $imported++

        # Also write it under the team name, so a name-keyed lookup works too.
        if ($names[$side]) {
            $stem = Get-Stem $names[$side]
            Copy-Item $dest (Join-Path $LogoDir "$stem.png") -Force
        }
    }
    return $imported
}

# The reliable path. GET /leagues and GET /leagues/{id}/matches are both public, and a match
# arrives with team1Id/team2Id already populated (name + profilePicture). That sidesteps the
# whole problem that made name matching unreliable: the in-game teamName is the station's
# lobby name, not the ODC one -- "predators", "Kaiju!" and "samurais" from real captures all
# return zero hits against /teams. Picking the scheduled match is unambiguous by construction,
# and it knows which side is which, so it can write HOME.png / AWAY.png directly.
function Get-Leagues {
    $resp = Invoke-RestMethod -Uri "$ApiRoot/leagues?limit=25" -UserAgent $UserAgent -TimeoutSec 30
    return @($resp.data)
}

function Get-Matches {
    param([string] $LeagueId, [int] $Week, [int] $Limit = 50)
    $url = "$ApiRoot/leagues/$LeagueId/matches?limit=$Limit"
    if ($Week -gt 0) { $url += "&weekNumber=$Week" }
    $resp = Invoke-RestMethod -Uri $url -UserAgent $UserAgent -TimeoutSec 30
    return @($resp.data)
}

function Save-TeamLogo {
    param($TeamObj, [string] $Side)
    if (-not $TeamObj) { return $false }
    if (-not $TeamObj.profilePicture) {
        Write-Warning ("'{0}' has no logo uploaded on ODC." -f $TeamObj.name)
        return $false
    }
    try {
        $resp = Invoke-WebRequest -Uri $TeamObj.profilePicture -UserAgent $UserAgent -TimeoutSec 30 -UseBasicParsing
    } catch {
        Write-Warning ("Failed to fetch logo for '{0}': {1}" -f $TeamObj.name, $_.Exception.Message)
        return $false
    }
    $stem = Get-Stem $TeamObj.name
    Save-SquarePng -Bytes $resp.Content -Path (Join-Path $LogoDir "$stem.png") -Edge $Size
    if ($Side) {
        # HOME.png / AWAY.png is what the camera prefers, because it is unambiguous even when
        # both sides report the same in-game team name.
        Save-SquarePng -Bytes $resp.Content -Path (Join-Path $LogoDir "$Side.png") -Edge $Size
        Write-Host ("  {0,-4} {1}  ->  logos\{2}.png + {3}.png" -f $Side, $TeamObj.name, $Side, $stem) -ForegroundColor Green
    } else {
        Write-Host ("  {0}  ->  logos\{1}.png" -f $TeamObj.name, $stem) -ForegroundColor Green
    }
    return $true
}

function Show-MatchPicker {
    param([int] $Week)

    $leagues = Get-Leagues
    if ($leagues.Count -eq 0) { Write-Warning 'No leagues returned.'; return }

    $rows = New-Object System.Collections.ArrayList
    foreach ($lg in $leagues) {
        if ($lg.status -ne 'in_progress' -and -not $AllLeagues) { continue }
        foreach ($m in (Get-Matches -LeagueId $lg._id -Week $Week)) {
            if (-not $m.team1Id -or -not $m.team2Id) { continue }
            [void] $rows.Add([pscustomobject]@{
                League = $lg.name
                Week   = $m.weekNumber
                State  = $m.state
                Home   = $m.team1Id
                Away   = $m.team2Id
            })
        }
    }
    if ($rows.Count -eq 0) {
        Write-Warning 'No matches found. Try -Week <n>, or -AllLeagues for finished seasons.'
        return
    }

    $sorted = $rows | Sort-Object Week, League
    Write-Host ''
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $r = $sorted[$i]
        Write-Host ("  [{0,3}] wk{1,-3} {2,-14} {3}  vs  {4}   ({5})" -f `
            ($i + 1), $r.Week, $r.League, $r.Home.name, $r.Away.name, $r.State)
    }
    Write-Host ''
    $pick = Read-Host 'Match number to fetch (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($pick)) { return }
    $n = 0
    if (-not [int]::TryParse($pick, [ref] $n) -or $n -lt 1 -or $n -gt $sorted.Count) {
        Write-Warning 'Not a listed number.'
        return
    }
    $r = $sorted[$n - 1]
    Write-Host ("Fetching {0} vs {1}..." -f $r.Home.name, $r.Away.name) -ForegroundColor Cyan
    [void] (Save-TeamLogo -TeamObj $r.Home -Side 'HOME')
    [void] (Save-TeamLogo -TeamObj $r.Away -Side 'AWAY')
    Write-Host '  done -- press "Rescan logos/ folder" in the camera GUI.' -ForegroundColor Green
}

function Read-Wanted {
    $path = Join-Path $PackagePath 'wanted.json'
    if (-not (Test-Path $path)) { return @() }
    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        return @()
    }
    if (-not $data.teams) { return @() }
    return @($data.teams | Where-Object { $_ -and $_ -ne '' })
}

# --- main -------------------------------------------------------------------

if (-not (Test-Path $PackagePath)) {
    throw "Package folder not found: $PackagePath (pass -PackagePath)"
}
if (-not (Test-Path $LogoDir)) {
    New-Item -ItemType Directory -Path $LogoDir | Out-Null
    Write-Host "Created $LogoDir"
}

if ($FromSchedule) {
    Show-MatchPicker -Week $Week
    if (-not $Watch) { return }
}

if ($FromBridge) {
    Write-Host "Importing logos from OD Caster Bridge..." -ForegroundColor Cyan
    $n = Import-FromBridge
    Write-Host ("{0} logo(s) imported." -f $n) -ForegroundColor Green
    Write-Host '  Press "Rescan logos/ folder" in the camera GUI.'
    if (-not $Watch) { return }
}

# The ODC index is only needed for name-based fetching, so don't pay for it in -FromBridge runs.
$index = @()
if (-not $FromBridge -and -not $FromSchedule) { $index = Get-TeamIndex -Force:$Refresh }

if ($ListMatches) {
    foreach ($q in $Team) {
        Write-Host "`n'$q' matches:" -ForegroundColor Cyan
        $index | Where-Object { $_.name -and $_.name.ToUpperInvariant().Contains($q.ToUpperInvariant()) } |
            Select-Object -First 20 | ForEach-Object {
                Write-Host ("  {0}   (stem {1})" -f $_.name, (Get-Stem $_.name))
            }
    }
    return
}

if ($Watch) {
    if ($FromBridge) {
        Write-Host "Watching OD Caster Bridge logo folders -- Ctrl+C to stop." -ForegroundColor Cyan
        $lastStamp = ''
        while ($true) {
            $bridge = Join-Path $env:APPDATA 'ODCasterBridge\logos'
            $stamp = ''
            if (Test-Path $bridge) {
                $stamp = (Get-ChildItem $bridge -Recurse -File |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 2 |
                    ForEach-Object { "$($_.Name):$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
            }
            if ($stamp -ne $lastStamp) {
                $lastStamp = $stamp
                Write-Host ("`n[{0}] Bridge logos changed" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
                [void] (Import-FromBridge)
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }

    Write-Host "Watching $PackagePath\wanted.json -- Ctrl+C to stop." -ForegroundColor Cyan
    $seen = ''
    while ($true) {
        $wanted = Read-Wanted
        if ($wanted.Count -gt 0) {
            $key = ($wanted -join '|')
            if ($key -ne $seen) {
                $seen = $key
                Write-Host ("`n[{0}] wanted: {1}" -f (Get-Date -Format 'HH:mm:ss'), $key) -ForegroundColor Cyan
                foreach ($t in $wanted) {
                    $stem = Get-Stem $t
                    if (Test-Path (Join-Path $LogoDir "$stem.png")) {
                        Write-Host ("  {0} already present" -f $t) -ForegroundColor DarkGray
                    } else {
                        [void] (Get-Logo -Index $index -Query $t)
                    }
                }
                Write-Host '  done -- press "Rescan logos/ folder" in the camera GUI.'
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

if (-not $Team -or $Team.Count -eq 0) {
    Write-Host 'Nothing to do. Pass team names, or -Watch. See -? for help.' -ForegroundColor Yellow
    return
}

Write-Host ("Fetching {0} logo(s) into {1}" -f $Team.Count, $LogoDir) -ForegroundColor Cyan
$ok = 0
foreach ($t in $Team) {
    if (Get-Logo -Index $index -Query $t) { $ok++ }
}
Write-Host ("{0}/{1} downloaded." -f $ok, $Team.Count) -ForegroundColor Green
