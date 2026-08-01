<#
.SYNOPSIS
    Copies fairy.casterfx into the Orion Drift Behaviors folder.

.DESCRIPTION
    Scripts hot-reload on save, but only in the game's own Behaviors folder -- so develop
    here and sync there. With -Watch it re-syncs on every change, which combined with
    hot-reload means saving a file in this repo updates the running camera.

    Logos are copied INTO the game folder but never back, and never deleted there: the
    -Watch loop is one-way on purpose so a stray edit in the game folder can't overwrite
    the repo. wanted.json is left alone in both directions -- the camera writes it in the
    game folder and get-logos.ps1 reads it there.

.PARAMETER Watch
    Re-sync whenever a file changes. Ctrl+C to stop.
#>
[CmdletBinding()]
param(
    [string] $PackagePath = (Join-Path $PSScriptRoot 'fairy.casterfx'),
    [string] $BehaviorsPath,
    [switch] $Watch,
    [int]    $PollSeconds = 2
)

$ErrorActionPreference = 'Stop'

# Documents is often OneDrive-redirected, so check both.
if (-not $BehaviorsPath) {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\Another-Axiom\A2\Cameras\Behaviors'),
        (Join-Path $env:USERPROFILE 'Documents\Another-Axiom\A2\Cameras\Behaviors')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $BehaviorsPath = $c; break }
    }
}
if (-not $BehaviorsPath -or -not (Test-Path $BehaviorsPath)) {
    throw "Could not find the A2 Cameras\Behaviors folder. Pass -BehaviorsPath."
}

$name = Split-Path $PackagePath -Leaf
$dest = Join-Path $BehaviorsPath $name

# Whitelist, not blacklist. Other tooling drops junk into working directories (this repo
# has collected empty files named "0", "900" and "0.999"), and an earlier version of this
# script cheerfully replicated all of it into the game folder.
$allowedExtensions = @('.luau', '.json', '.png', '.jpg', '.jpeg', '.glb', '.gltf', '.bin')

function Sync-Once {
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
    $copied = 0
    foreach ($src in Get-ChildItem $PackagePath -Recurse -File) {
        $rel = $src.FullName.Substring($PackagePath.Length + 1)
        # Written by the camera in the game folder; syncing over them would clobber live data.
        if ($rel -eq 'wanted.json' -or $rel -eq 'diagnostics.json' -or $rel -eq 'gamedata-log.json') { continue }
        if ($allowedExtensions -notcontains $src.Extension.ToLowerInvariant()) { continue }
        if ($rel -split '[\\/]' | Where-Object { $_.StartsWith('.') }) { continue }
        $target = Join-Path $dest $rel
        $targetDir = Split-Path $target -Parent
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        $needs = $true
        if (Test-Path $target) {
            $t = Get-Item $target
            # Length plus mtime is enough here and avoids hashing PNGs every poll.
            $needs = ($t.Length -ne $src.Length) -or ($t.LastWriteTimeUtc -lt $src.LastWriteTimeUtc)
        }
        if ($needs) {
            Copy-Item $src.FullName $target -Force
            $copied++
            if ($Watch) { Write-Host ("  {0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $rel) -ForegroundColor Green }
        }
    }
    return $copied
}

# A .luau in the destination that no longer exists here is a renamed module. Leaving it
# behind is how you end up with two versions of a module in one package.
function Get-StaleModules {
    if (-not (Test-Path $dest)) { return @() }
    $stale = @()
    foreach ($f in Get-ChildItem $dest -Filter *.luau -File) {
        if (-not (Test-Path (Join-Path $PackagePath $f.Name))) { $stale += $f }
    }
    return $stale
}

$n = Sync-Once
Write-Host ("Synced {0} file(s) -> {1}" -f $n, $dest) -ForegroundColor Cyan

$stale = Get-StaleModules
foreach ($f in $stale) {
    Remove-Item $f.FullName -Force
    Write-Host ("Removed stale module: {0}" -f $f.Name) -ForegroundColor Yellow
}

if (-not $Watch) { return }

Write-Host "Watching for changes -- Ctrl+C to stop." -ForegroundColor Cyan
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    [void] (Sync-Once)
}
