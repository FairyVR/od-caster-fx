<#
.SYNOPSIS
    Generates the particle sprite PNGs for fairy.casterfx.

.DESCRIPTION
    The game renders texture alpha as CUTOUT: a pixel is fully opaque or fully gone,
    there is no blending. So these sprites are crisp geometric shapes with hard edges
    rather than the soft radial gradients a normal particle system would use -- a
    gradient would just get sliced at the alpha threshold and look like a disc.

    Shapes are drawn white. A textured mesh ignores mesh.color, so anything that needs
    to be a team colour is untextured geometry on the Luau side instead.

    Re-run any time; it overwrites. Output: <package>\sprites\{flare,star,spark}.png
#>
[CmdletBinding()]
param(
    [string] $PackagePath = (Join-Path $PSScriptRoot 'fairy.casterfx'),
    [int]    $Size = 256
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PackagePath 'sprites'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

function New-Canvas {
    param([int] $Edge)
    $bmp = New-Object System.Drawing.Bitmap($Edge, $Edge, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    # Antialiasing is deliberately OFF: cutout alpha hardens partial pixels anyway, and
    # AA edges turn into ragged fringes rather than smooth ones.
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    return @{ Bitmap = $bmp; Graphics = $g }
}

function Save-Canvas {
    param($Canvas, [string] $Name)
    $Canvas.Graphics.Dispose()
    $path = Join-Path $outDir "$Name.png"
    $Canvas.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $Canvas.Bitmap.Dispose()
    Write-Host "  sprites\$Name.png" -ForegroundColor Green
}

# Star polygon: alternating outer/inner radius points.
function Get-StarPoints {
    param([int] $Points, [double] $Cx, [double] $Cy, [double] $Outer, [double] $Inner, [double] $Rotation = -90)
    $pts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Points * 2; $i++) {
        $r = if ($i % 2 -eq 0) { $Outer } else { $Inner }
        $a = ($Rotation + $i * (180.0 / $Points)) * [Math]::PI / 180.0
        [void] $pts.Add((New-Object System.Drawing.PointF(
            [float]($Cx + $r * [Math]::Cos($a)), [float]($Cy + $r * [Math]::Sin($a)))))
    }
    return $pts.ToArray()
}

$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$half = $Size / 2.0

Write-Host "Generating sprites into $outDir" -ForegroundColor Cyan

# flare: 4-point spike with a solid core -- the workhorse "bright bit" of an explosion.
$c = New-Canvas -Edge $Size
$c.Graphics.FillPolygon($white, (Get-StarPoints -Points 4 -Cx $half -Cy $half -Outer ($half * 0.98) -Inner ($half * 0.13)))
$c.Graphics.FillEllipse($white, [float]($half - $half * 0.26), [float]($half - $half * 0.26), [float]($half * 0.52), [float]($half * 0.52))
Save-Canvas -Canvas $c -Name 'flare'

# star: 6-point, chunkier, reads at larger sizes.
$c = New-Canvas -Edge $Size
$c.Graphics.FillPolygon($white, (Get-StarPoints -Points 6 -Cx $half -Cy $half -Outer ($half * 0.96) -Inner ($half * 0.40)))
Save-Canvas -Canvas $c -Name 'star'

# spark: a tapered vertical sliver plus a dot, for fast small hits.
$c = New-Canvas -Edge $Size
$sliver = @(
    (New-Object System.Drawing.PointF([float]$half, [float]($half * 0.04))),
    (New-Object System.Drawing.PointF([float]($half * 1.16), [float]$half)),
    (New-Object System.Drawing.PointF([float]$half, [float]($Size - $half * 0.04))),
    (New-Object System.Drawing.PointF([float]($half * 0.84), [float]$half))
)
$c.Graphics.FillPolygon($white, $sliver)
$c.Graphics.FillEllipse($white, [float]($half - $half * 0.15), [float]($half - $half * 0.15), [float]($half * 0.30), [float]($half * 0.30))
Save-Canvas -Canvas $c -Name 'spark'

$white.Dispose()
Write-Host 'Done.' -ForegroundColor Green
