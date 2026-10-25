<#
.SYNOPSIS
Prepares a separate, resumable working folder from an EPUB without marking it read.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$BookId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'epub-functions.ps1')
if (-not [IO.Path]::IsPathRooted($InputPath)) { $InputPath = Join-Path $PSScriptRoot $InputPath }
$source = Get-Item -LiteralPath $InputPath
if ($source.PSIsContainer -or $source.Extension -ine '.epub') { throw 'Input must be an EPUB file.' }
$sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $BookId) {
    $slug = [regex]::Replace($source.BaseName, '[^\p{L}\p{N}]+', '-').Trim('-').ToLowerInvariant()
    if (-not $slug) { $slug = 'book' }
    if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50).TrimEnd('-') }
    $BookId = $slug + '-' + $sourceHash.Substring(0, 8)
}
if ($BookId -notmatch '^[\p{L}\p{N}][\p{L}\p{N}_-]{0,79}$' -or $BookId -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') {
    throw 'BookId must be a safe folder name of 1-80 letters, numbers, hyphens, or underscores.'
}
$destination = Join-Path (Join-Path $PSScriptRoot 'Working') $BookId
if (Test-Path -LiteralPath $destination) { throw "Working folder already exists; resume it or choose another BookId: $destination" }
$pandocCommand = Get-Command pandoc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$pandoc = if ($pandocCommand) { $pandocCommand.Source } else { $null }
if (-not $pandoc) {
    foreach ($candidate in @('%LOCALAPPDATA%\Pandoc\pandoc.exe', '%PROGRAMFILES%\Pandoc\pandoc.exe')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) { $pandoc = $expanded; break }
    }
}
if (-not $pandoc) { throw 'Pandoc is required for text extraction.' }
$archive = [IO.Compression.ZipFile]::OpenRead($source.FullName)
try {
    $package = Get-EpubPackage $archive
    $rawDirectory = Join-Path $destination 'raw'
    $textDirectory = Join-Path $destination 'text'
    $rawRoot = [IO.Path]::GetFullPath($rawDirectory) + [IO.Path]::DirectorySeparatorChar
    # Validate every destination before writing any archive entries (including on Windows).
    $targets = @{}
    $expandedSize = [long]0
    foreach ($entry in $archive.Entries) {
        $expandedSize += $entry.Length
        if ($expandedSize -gt 1GB) { throw 'EPUB exceeds the 1 GiB extraction limit.' }
        if ($entry.FullName -match '(^[/\\]|^[A-Za-z]:|:)' -or $entry.FullName.Contains('\')) { throw "Unsafe archive path: $($entry.FullName)" }
        $target = [IO.Path]::GetFullPath((Join-Path $rawDirectory $entry.FullName))
        if (-not $target.StartsWith($rawRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Archive path escapes working folder: $($entry.FullName)" }
        if ($targets.ContainsKey($target)) { throw "Duplicate archive destination: $($entry.FullName)" }
        $targets[$target] = $true
    }
    [IO.Directory]::CreateDirectory($textDirectory) | Out-Null
    foreach ($entry in $archive.Entries) {
        $target = [IO.Path]::GetFullPath((Join-Path $rawDirectory $entry.FullName))
        if ($entry.FullName.EndsWith('/')) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
    }
    $metadata = @()
    foreach ($node in $package.Document.SelectNodes('//*[local-name()="metadata"]/*')) {
        $metadata += [ordered]@{ name = $node.LocalName; value = $node.InnerText; attributes = @($node.Attributes | ForEach-Object { $_.Name + '=' + $_.Value }) }
    }
    $items = @{}
    $resources = @()
    foreach ($item in $package.Document.SelectNodes('//*[local-name()="manifest"]/*[local-name()="item"]')) {
        $path = Resolve-EpubEntry $package.Path $item.GetAttribute('href')
        $items[$item.GetAttribute('id')] = $path
        $resources += [ordered]@{ path = $path; mediaType = $item.GetAttribute('media-type'); properties = $item.GetAttribute('properties') }
    }
    $readingOrder = @()
    $coverage = @()
    $index = 0
    foreach ($itemref in $package.Document.SelectNodes('//*[local-name()="spine"]/*[local-name()="itemref"]')) {
        $index++
        $idref = $itemref.GetAttribute('idref')
        if (-not $items.ContainsKey($idref)) { throw "Unknown reading-order item: $idref" }
        $path = $items[$idref]
        $xml = Read-EpubXml $archive $path
        $textFile = 'text/{0:D4}.txt' -f $index
        $inputFile = Join-Path $rawDirectory $path
        & $pandoc $inputFile --from html --to plain --wrap none --output (Join-Path $destination $textFile)
        if ($LASTEXITCODE -ne 0) { throw "Pandoc could not extract $path" }
        $headings = @($xml.SelectNodes('//*[local-name()="h1" or local-name()="h2" or local-name()="h3" or local-name()="h4" or local-name()="h5" or local-name()="h6"]') | ForEach-Object {
            [ordered]@{ title = $_.InnerText.Trim(); anchor = $_.GetAttribute('id') }
        })
        $readingOrder += [ordered]@{ order = $index; sourcePath = $path; textPath = $textFile; linear = $itemref.GetAttribute('linear'); headings = $headings }
        $coverage += [ordered]@{ id = ('file-{0:D4}' -f $index); title = $path; sourceLocation = $path; kind = 'unclassified'; substantive = $true; readStatus = 'unread'; summaryHeading = ''; notes = 'File-level placeholder. Inspect internal articles, notes, and headings; split or reclassify before marking inventory reviewed.' }
    }
    $navigation = @()
    foreach ($resource in $resources) {
        if (($resource.properties -split '\s+') -contains 'nav' -or $resource.mediaType -eq 'application/x-dtbncx+xml') {
            $xml = Read-EpubXml $archive $resource.path
            foreach ($link in $xml.SelectNodes('//*[local-name()="a" and @href] | //*[local-name()="navPoint"]')) {
                if ($link.LocalName -eq 'a') { $title = $link.InnerText; $href = $link.GetAttribute('href') }
                else {
                    $label = $link.SelectSingleNode('./*[local-name()="navLabel"]/*[local-name()="text"]')
                    $content = $link.SelectSingleNode('./*[local-name()="content"]')
                    if (-not $label -or -not $content) { continue }
                    $title = $label.InnerText; $href = $content.GetAttribute('src')
                }
                $navigation += [ordered]@{ title = $title.Trim(); href = $href; navigationFile = $resource.path }
            }
        }
    }
    $manifest = [ordered]@{ schemaVersion = 1; sourcePath = $source.FullName; sourceSha256 = $sourceHash; extractedAt = [DateTime]::UtcNow.ToString('o'); packagePath = $package.Path; metadata = $metadata; readingOrder = $readingOrder; navigation = $navigation; resources = $resources; warnings = @('Metadata is unverified. Reconcile with title/copyright pages.', 'Plain text loses typography. Inspect raw XHTML, notes, images, and internal article headings.', 'Extraction and navigation inventories do not prove complete coverage or reading.') }
    $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding utf8
    [ordered]@{ schemaVersion = 1; sourceSha256 = $sourceHash; inventoryReviewed = $false; sections = $coverage } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $destination 'coverage.json') -Encoding utf8
    "# Evidence ledger`n`nFor each consequential claim or quote: statement, classification, source path and anchor/paragraph range, verification status, and external source/access date if checked." | Set-Content -LiteralPath (Join-Path $destination 'evidence.md') -Encoding utf8
    "# Progress`n`nStatus: extracted, not read.`nEffective settings: record defaults and user overrides before reading.`nNext: reconcile metadata and article-level inventory; begin reading in manifest order.`nSource SHA-256: $sourceHash`n`nOriginal XHTML, images, and notes are preserved under raw/. Do not execute embedded content." | Set-Content -LiteralPath (Join-Path $destination 'progress.md') -Encoding utf8
    Write-Host "Prepared $($readingOrder.Count) reading-order files: $destination"
    Write-Host 'Coverage starts unread and inventoryReviewed=false. Reconcile internal sections before drafting.'
} catch {
    if (Test-Path -LiteralPath $destination) { Write-Warning "Incomplete extraction preserved at $destination. Inspect it; rerun using a new BookId." }
    throw
} finally { $archive.Dispose() }
