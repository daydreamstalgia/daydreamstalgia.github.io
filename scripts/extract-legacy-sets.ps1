<#
One-time migration: turns the app's bundled populate_db CSVs + card_images
assets into the new dmi_sets zip-pack format (see DuelMastersInventory KB,
"dynamic sets" spec). Run once from this repo root:

    powershell -File scripts/extract-legacy-sets.ps1

Produces:
  static/dmi_sets/<LANG>_<SET>.zip          - one pack per (language, set)
  static/duelmastersinventory/sets.json     - the Discover catalog
#>

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-JsonNoBom {
    param([string]$Path, [string]$Json)
    [System.IO.File]::WriteAllText($Path, $Json, $Utf8NoBom)
}

# Compress-Archive writes backslash path separators into zip entry names on
# Windows, which Java's ZipInputStream treats as a literal filename character
# rather than a directory separator (the ZIP spec mandates '/'). Build the
# archive by hand instead so `assets/...` entries actually nest correctly
# when the app unzips a pack on Android.
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$appAssets = "D:\Projects\DuelMastersInventoryWs\DuelMastersInventory\app\src\main\assets"
$prototypesCsv = Join-Path $appAssets "populate_db\CardPrototype.csv"
$printsCsv = Join-Path $appAssets "populate_db\CardPrint.csv"
$imagesDir = Join-Path $appAssets "card_images"

$setsOutDir = Join-Path $repoRoot "static\dmi_sets"
$catalogDir = Join-Path $repoRoot "static\duelmastersinventory"
$stagingRoot = Join-Path $env:TEMP "dmi-set-pack-staging"

if ((Test-Path $setsOutDir) -and -not (Get-Item $setsOutDir).PSIsContainer) { Remove-Item $setsOutDir }
if ((Test-Path $catalogDir) -and -not (Get-Item $catalogDir).PSIsContainer) { Remove-Item $catalogDir }
New-Item -ItemType Directory -Force -Path $setsOutDir | Out-Null
New-Item -ItemType Directory -Force -Path $catalogDir | Out-Null
if (Test-Path $stagingRoot) { Remove-Item -Recurse -Force $stagingRoot }
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

$SET_NAMES = @{
    "EN|DM-01" = "Base Set"
    "EN|DM-02" = "Evo-Crushinators of Doom"
    "EN|DM-03" = "Rampage of the Super Warriors"
    "EN|DM-04" = "Shadowclash of Blinding Night"
    "EN|DM-05" = "Survivors of the Megapocalypse"
    "EN|DM-06" = "Stomp-A-Trons of Invincible Wrath"
    "EN|DM-07" = "Thundercharge of Ultra Destruction"
    "EN|DM-08" = "Epic Dragons of Hyperchaos"
    "EN|DM-09" = "Fatal Brood of Infinite Ruin"
    "EN|DM-10" = "Shockwaves of the Shattered Rainbow"
    "EN|DM-11" = "Blast-o-Splosion of Gigantic Rage"
    "EN|DM-12" = "Thrash of the Hybrid Megacreatures"
    "EN|CTD"   = "Collector's Tin Deck"
    "EN|Promo" = "Promo"
    "JP|DM-01" = "Basic Set"
}

Write-Host "Reading CSVs..."
$prototypes = Import-Csv $prototypesCsv
$prints = Import-Csv $printsCsv

$prototypeById = @{}
foreach ($p in $prototypes) { $prototypeById[$p.id] = $p }

$groups = $prints | Group-Object language, set

$catalogContent = @()

foreach ($group in $groups) {
    $parts = $group.Name -split ", "
    $language = $parts[0]
    $setCode = $parts[1]
    $key = "$language|$setCode"
    $setName = if ($SET_NAMES.ContainsKey($key)) { $SET_NAMES[$key] } else { $setCode }

    Write-Host "Packing $language $setCode ($($group.Group.Count) cards) - $setName"

    $packDir = Join-Path $stagingRoot "$language`_$setCode"
    $assetsDir = Join-Path $packDir "assets"
    New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

    $cards = @()
    foreach ($print in $group.Group) {
        $proto = $prototypeById[$print.cardPrototypeId]
        if (-not $proto) {
            Write-Warning "  No prototype for cardPrototypeId=$($print.cardPrototypeId), skipping print $($print.id)"
            continue
        }

        $mana = $null
        if ($proto.mana -ne "" -and $proto.mana -ne $null) { $mana = [int]$proto.mana }

        $cards += [ordered]@{
            set_number      = $print.setNumber
            set_count       = $print.setCount
            rarity          = $print.rarity
            name            = $proto.name
            civilization    = $proto.civilization
            races           = $proto.races
            mana            = $mana
            power           = $proto.power
            type            = $proto.type
            text            = $proto.text
            translated_name = if ($print.translatedName) { $print.translatedName } else { $null }
            translated_text = if ($print.translatedText) { $print.translatedText } else { $null }
        }

        $srcImage = Join-Path $imagesDir "$($print.id).jpg"
        $dstImage = Join-Path $assetsDir "$($language)_$($setCode)_$($print.setNumber)_$($print.setCount).png"
        if (Test-Path $srcImage) {
            $bmp = [System.Drawing.Bitmap]::FromFile($srcImage)
            try {
                $bmp.Save($dstImage, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $bmp.Dispose()
            }
        } else {
            Write-Warning "  Missing source image for print id=$($print.id) ($language $setCode $($print.setNumber)/$($print.setCount))"
        }
    }

    $data = [ordered]@{
        set_language = $language
        set_code     = $setCode
        set_name     = $setName
        cards        = $cards
    }
    Write-JsonNoBom -Path (Join-Path $packDir "data.json") -Json ($data | ConvertTo-Json -Depth 6)

    $zipName = "$($language)_$($setCode).zip"
    $zipPath = Join-Path $setsOutDir $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    New-ZipWithForwardSlashes -SourceDir $packDir -ZipPath $zipPath

    $catalogContent += [ordered]@{
        set_language = $language
        set_code     = $setCode
        set_name     = $setName
        url          = "https://daydreamstalgia.github.io/static/dmi_sets/$zipName"
    }
}

$catalog = [ordered]@{
    target  = "DMInventory"
    content = $catalogContent
}
Write-JsonNoBom -Path (Join-Path $catalogDir "sets.json") -Json ($catalog | ConvertTo-Json -Depth 6)

Remove-Item -Recurse -Force $stagingRoot

Write-Host "Done. $($groups.Count) set packs written to $setsOutDir"
Write-Host "Catalog written to $(Join-Path $catalogDir 'sets.json')"
