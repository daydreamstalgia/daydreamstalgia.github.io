<#
Builds the JP DM-03 (Master of Destruction) set pack from card data + card art
scraped from the Duel Masters Wiki, as a hand-authored test of the "dynamic
sets" import feature (not extracted from the app's bundled data like the
other packs - see scripts/extract-legacy-sets.ps1).
#>

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$kbWork = "D:\Projects\DuelMastersInventoryWs\kb\.work"
$dataJson = Join-Path $kbWork "jp-dm03-data.json"
$imagesJson = Join-Path $kbWork "jp-dm03-images.json"

$setsOutDir = Join-Path $repoRoot "static\dmi_sets"
$catalogPath = Join-Path $repoRoot "static\duelmastersinventory\sets.json"
$stagingRoot = Join-Path $env:TEMP "dmi-jp-dm03-staging"

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

$data = Get-Content $dataJson -Raw | ConvertFrom-Json
$images = Get-Content $imagesJson -Raw | ConvertFrom-Json

$packDir = Join-Path $stagingRoot "JP_DM-03"
$assetsDir = Join-Path $packDir "assets"
if (Test-Path $stagingRoot) { Remove-Item -Recurse -Force $stagingRoot }
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

Write-Host "Downloading and converting $($data.cards.Count) card images..."
$client = New-Object System.Net.WebClient
$client.Headers.Add("User-Agent", "Mozilla/5.0 (DuelMastersInventory set-pack builder)")

foreach ($card in $data.cards) {
    $url = $images.($card.set_number)
    if (-not $url) {
        Write-Warning "No image URL for set_number=$($card.set_number), skipping art"
        continue
    }
    $tmpJpg = Join-Path $stagingRoot "dl_$($card.set_number).jpg"
    # Wikia's CDN serves WebP by default regardless of the .jpg URL extension
    # (content negotiation via Fastly); ?format=original forces the real JPEG,
    # which System.Drawing (no WebP codec) can actually decode.
    $client.DownloadFile("$url`?format=original", $tmpJpg)

    $dstPng = Join-Path $assetsDir "JP_DM-03_$($card.set_number)_$($card.set_count).png"
    $bmp = [System.Drawing.Bitmap]::FromFile($tmpJpg)
    try {
        $bmp.Save($dstPng, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp.Dispose()
    }
    Remove-Item $tmpJpg
}
$client.Dispose()

Copy-Item $dataJson (Join-Path $packDir "data.json")

$zipName = "JP_DM-03.zip"
$zipPath = Join-Path $setsOutDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath }
New-ZipWithForwardSlashes -SourceDir $packDir -ZipPath $zipPath

Write-Host "Pack written to $zipPath"

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
Write-Host "Catalog updated: $catalogPath"
