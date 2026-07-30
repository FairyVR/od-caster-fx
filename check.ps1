<#
.SYNOPSIS
    Type-checks and lints the fairy.casterfx Luau against the game's own type definitions.

.DESCRIPTION
    Uses luau-lsp (the analyzer the game's shipped .vscode/settings.json is configured for)
    with the install's types/v2/*.d.lua loaded as globals. Downloads the tool into tools\
    on first run.

    Two flags matter and are not obvious:

      --no-flags-enabled   luau-lsp turns on every Luau FFlag by default, which enables the
                           new type solver. The new solver rejects the `declare class ... end`
                           syntax the shipped definition files use, so without this every
                           engine global comes back "Unknown global".

      --base-luaurc        the shipped Behaviors\.luaurc disables the FunctionUnused lint,
                           which otherwise fires on main/tick/onGui -- functions the engine
                           calls and nothing in the file does.

.PARAMETER GamePath
    Orion Drift install root. Auto-detected across the usual Oculus/Steam locations.
#>
[CmdletBinding()]
param(
    [string] $PackagePath = (Join-Path $PSScriptRoot 'fairy.casterfx'),
    [string] $GamePath,
    [string] $LuauLspVersion = '1.69.0'
)

$ErrorActionPreference = 'Stop'

$candidates = @(
    'C:\Users\tibba\Documents\ocyulus apps\Software\another-axiom-a2-cqxlff',
    'C:\Program Files\Oculus\Software\Software\another-axiom-a2-cqxlff',
    "${env:ProgramFiles(x86)}\Steam\steamapps\common\Orion Drift"
)
if ($GamePath) { $candidates = @($GamePath) + $candidates }

$behaviors = $null
foreach ($c in $candidates) {
    $p = Join-Path $c 'A2\Content\Scripts\Cameras\Behaviors'
    if (Test-Path $p) { $behaviors = $p; break }
}
if (-not $behaviors) {
    throw "Could not find the game's Behaviors folder. Pass -GamePath <install root>."
}

$types = Join-Path $behaviors 'types\v2'
$luaurc = Join-Path $behaviors '.luaurc'

$toolDir = Join-Path $PSScriptRoot 'tools\luau'
$lsp = Join-Path $toolDir 'luau-lsp.exe'
if (-not (Test-Path $lsp)) {
    Write-Host "luau-lsp not found, downloading $LuauLspVersion..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
    $zip = Join-Path $env:TEMP 'luau-lsp-win64.zip'
    $url = "https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LuauLspVersion/luau-lsp-win64.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    Expand-Archive $zip -DestinationPath $toolDir -Force
    Remove-Item $zip
}

# Order matters only for readability; luau-lsp merges all definitions into the global scope.
$defs = @()
foreach ($f in @('base.d.lua', 'gui.d.lua', 'keys.d.lua', 'special.d.lua')) {
    $path = Join-Path $types $f
    if (Test-Path $path) { $defs += "--definitions=$path" }
}

Push-Location $PackagePath
try {
    $files = Get-ChildItem -Filter *.luau | ForEach-Object { $_.Name }
    Write-Host ("Analyzing {0} file(s) against {1}" -f $files.Count, $types) -ForegroundColor Cyan

    $args = @('analyze', '--no-flags-enabled', "--base-luaurc=$luaurc") + $defs
    $args += '--formatter=plain'
    $args += $files

    # luau-lsp writes [INFO] chatter to stderr. In PS 5.1 a native exe's stderr becomes
    # ErrorRecords whenever anything up the chain is redirecting, and Stop would make those
    # fatal -- so relax the preference across the call rather than trying to redirect.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & $lsp @args | Out-String
    $toolExit = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference

    # 0 = clean, 1 = diagnostics reported. Anything else (bad flag, missing file) means the
    # analysis never ran, and must not be mistaken for a pass.
    if ($toolExit -ne 0 -and $toolExit -ne 1) {
        Write-Host $raw
        throw "luau-lsp failed with exit code $toolExit -- the code was NOT checked."
    }
    # Diagnostics look like "file.luau:12:15-30: (W0) TypeError: ...". Everything else is
    # progress chatter from the definition loader.
    $diags = $raw -split "`r?`n" | Where-Object { $_ -match '\.luau:\d+:' }
} finally {
    Pop-Location
}

# Writing alwaysTick is how a script asks to keep ticking while another camera is active.
# It is exactly what the shipped anotheraxiom.analysis camera does. Allowlisted narrowly by
# global name so any OTHER builtin-global write still fails the check.
$expected = "BuiltinGlobalWrite: Built-in global 'alwaysTick'"
$real = @($diags | Where-Object { $_ -notmatch [regex]::Escape($expected) })
$waived = $diags.Count - $real.Count

if ($real.Count -eq 0) {
    Write-Host ("Clean -- no type errors or lint warnings ({0} expected alwaysTick write(s) waived)." -f $waived) -ForegroundColor Green
    exit 0
}

Write-Host ("{0} diagnostic(s):" -f $real.Count) -ForegroundColor Yellow
$real | ForEach-Object { Write-Host "  $_" }
exit 1
