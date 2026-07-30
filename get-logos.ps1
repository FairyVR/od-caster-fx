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

.PARAMETER Refresh
    Re-download the team index instead of using the local cache.

.EXAMPLE
    .\get-logos.ps1 "SHOT" "TP!"

.EXAMPLE
    .\get-logos.ps1 -Watch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Team,

    [switch] $Watch,
    [switch] $Refresh,
    [switch] $ListMatches,

    [string] $PackagePath = (Join-Path $PSScriptRoot 'fairy.casterfx'),
    [int]    $Size = 512,
    [int]    $PollSeconds = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ApiBase = 'https://oriondriftcompetitive.com/api/v1/teams'
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

$index = Get-TeamIndex -Force:$Refresh

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
