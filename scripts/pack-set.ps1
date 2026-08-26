<#
Builds a set pack zip from a hand-authored data.json (SetPackData shape) +
an images.json (set_number -> wiki image URL) and registers/updates it in
the Discover catalog. Generalized from pack-jp-dm03.ps1 so each new
wiki-sourced set doesn't need its own copy of this logic.

Usage:
    powershell -File scripts/pack-set.ps1 -DataJson <path> -ImagesJson <path>
#>
param(
    [Parameter(Mandatory = $true)][string]$DataJson,
    [Parameter(Mandatory = $true)][string]$ImagesJson
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$setsOutDir = Join-Path $repoRoot "static\dmi_sets"
$catalogPath = Join-Path $repoRoot "static\duelmastersinventory\sets.json"

function New-ZipWithForwardSlashes {
    param([string]$SourceDir, [string]$ZipPath)
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = Get-ChildItem -Path $SourceDir -Recurse -File
        foreach ($f in $files) {
            $relative = $f.FullName.Substring($SourceDir.Length + 1) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-JsonNoBom {
    param([string]$Path, [string]$Json)
    [System.IO.File]::WriteAllText($Path, $Json, $Utf8NoBom)
}

$data = Get-Content $DataJson -Raw | ConvertFrom-Json
$images = Get-Content $ImagesJson -Raw | ConvertFrom-Json

$packName = "$($data.set_language)_$($data.set_code)"
$stagingRoot = Join-Path $env:TEMP "dmi-pack-staging-$packName"
$packDir = Join-Path $stagingRoot $packName
$assetsDir = Join-Path $packDir "assets"
if (Test-Path $stagingRoot) { Remove-Item -Recurse -Force $stagingRoot }
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

Write-Host "[$packName] Downloading and converting $($data.cards.Count) card images..."
$client = New-Object System.Net.WebClient
$client.Headers.Add("User-Agent", "Mozilla/5.0 (DuelMastersInventory set-pack builder)")

$missing = 0
foreach ($card in $data.cards) {
    $url = $images.($card.set_number)
    if (-not $url) {
        Write-Warning "  No image URL for set_number=$($card.set_number), skipping art"
        $missing++
        continue
    }
    $tmpJpg = Join-Path $stagingRoot "dl_$($card.set_number).jpg"
    # Wikia's CDN serves WebP by default regardless of the .jpg URL extension
    # (content negotiation via Fastly); ?format=original forces the real JPEG,
    # which System.Drawing (no WebP codec) can actually decode. Strip any
    # existing query string first (the allimages API's "url" field already
    # carries a ?cb=... cache-buster) so this doesn't produce an invalid
    # double "?" that makes the CDN choke.
    $baseUrl = $url -replace '\?.*$', ''
    $client.DownloadFile("$baseUrl`?format=original", $tmpJpg)

    $dstPng = Join-Path $assetsDir "$($packName)_$($card.set_number)_$($card.set_count).png"
    $bmp = [System.Drawing.Bitmap]::FromFile($tmpJpg)
    try {
        $bmp.Save($dstPng, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp.Dispose()
    }
    Remove-Item $tmpJpg
}
$client.Dispose()

Copy-Item $DataJson (Join-Path $packDir "data.json")

$zipName = "$packName.zip"
$zipPath = Join-Path $setsOutDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath }
New-ZipWithForwardSlashes -SourceDir $packDir -ZipPath $zipPath

Write-Host "[$packName] Pack written to $zipPath ($($data.cards.Count) cards, $missing missing images)"

# Append/update this set's entry in the Discover catalog
$catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
$entry = [ordered]@{
    set_language = $data.set_language
    set_code     = $data.set_code
    set_name     = $data.set_name
    url          = "https://daydreamstalgia.github.io/static/dmi_sets/$zipName"
}
$existing = $catalog.content | Where-Object { $_.set_language -eq $data.set_language -and $_.set_code -eq $data.set_code }
if ($existing) {
    $existing.set_name = $entry.set_name
    $existing.url = $entry.url
} else {
    $catalog.content = @($catalog.content) + [PSCustomObject]$entry
}
Write-JsonNoBom -Path $catalogPath -Json ($catalog | ConvertTo-Json -Depth 6)

Remove-Item -Recurse -Force $stagingRoot
Write-Host "[$packName] Catalog updated: $catalogPath"
