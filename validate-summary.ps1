<#
.SYNOPSIS
Checks Markdown structure and coverage records. Does not certify factual accuracy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$CoveragePath,
    [string[]]$RequiredHeadings = @('About This Summary', 'One-Page Condensed Summary', 'Chapter-by-Chapter Summary', 'Key Takeaways', 'Coverage And Reliability Audit')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($variableName in @('InputPath', 'CoveragePath')) {
    $value = Get-Variable -Name $variableName -ValueOnly
    if (-not [IO.Path]::IsPathRooted($value)) { Set-Variable -Name $variableName -Value (Join-Path $PSScriptRoot $value) }
}
$issues = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$markdown = Get-Content -LiteralPath $InputPath -Raw -Encoding utf8
$coverage = Get-Content -LiteralPath $CoveragePath -Raw -Encoding utf8 | ConvertFrom-Json
$pandocCommand = Get-Command pandoc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$pandoc = if ($pandocCommand) { $pandocCommand.Source } else { $null }
if (-not $pandoc) {
    foreach ($candidate in @('%LOCALAPPDATA%\Pandoc\pandoc.exe', '%PROGRAMFILES%\Pandoc\pandoc.exe')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) { $pandoc = $expanded; break }
    }
}
if (-not $pandoc) { throw 'Pandoc is required to parse Markdown and YAML metadata.' }
$temporaryJson = [IO.Path]::GetTempFileName()
try {
    & $pandoc $InputPath --from markdown-smart --to json --output $temporaryJson
    if ($LASTEXITCODE -ne 0) { throw 'Pandoc could not parse the Markdown/YAML.' }
    $ast = Get-Content -LiteralPath $temporaryJson -Raw -Encoding utf8 | ConvertFrom-Json
} finally { [IO.File]::Delete($temporaryJson) }
function Get-AstNodes {
    param($Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    if ($Value -is [array]) { foreach ($child in $Value) { Get-AstNodes $child }; return }
    if ($Value.PSObject.Properties['t']) { Write-Output $Value }
    foreach ($property in $Value.PSObject.Properties) { Get-AstNodes $property.Value }
}
function Get-InlineText {
    param($Inlines)
    $parts = foreach ($inline in $Inlines) {
        switch ($inline.t) {
            'Str' { $inline.c }
            'Space' { ' ' }
            'SoftBreak' { ' ' }
            'LineBreak' { ' ' }
            'Code' { $inline.c[1] }
            'Math' { $inline.c[1] }
            'Cite' { Get-InlineText $inline.c[1] }
            'Note' { '' }
            'Link' { Get-InlineText $inline.c[1] }
            'Image' { Get-InlineText $inline.c[1] }
            'Quoted' { Get-InlineText $inline.c[1] }
            'Span' { Get-InlineText $inline.c[1] }
            default { if ($inline.PSObject.Properties['c']) { Get-InlineText $inline.c } }
        }
    }
    return ($parts -join '')
}
if ($markdown -notmatch '\A(?:\uFEFF)?---\r?\n') { $issues.Add('Document must begin with YAML front matter.') }
foreach ($key in @('title', 'lang')) {
    if (-not $ast.meta.PSObject.Properties[$key]) { $issues.Add("Missing YAML metadata: $key") }
    elseif (-not $ast.meta.$key.c -or -not (Get-InlineText $ast.meta.$key.c).Trim()) { $issues.Add("Empty YAML metadata: $key") }
}
if ($ast.meta.PSObject.Properties['lang']) {
    $language = Get-InlineText $ast.meta.lang.c
    if ($language -notmatch '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$') { $issues.Add('lang must contain a language tag such as en-US or pt-BR.') }
}
$nodes = @(Get-AstNodes $ast.blocks)
$headers = @($nodes | Where-Object t -eq 'Header')
$headings = @($headers | ForEach-Object { Get-InlineText $_.c[2] })
$ids = @($headers | ForEach-Object { $_.c[1][0] })
if (@($headers | Where-Object { $_.c[0] -eq 1 }).Count -ne 1) { $issues.Add('Expected exactly one level-one book title.') }
foreach ($required in $RequiredHeadings) {
    if ($headings -cnotcontains $required) { $issues.Add("Missing required heading: $required") }
}
foreach ($group in @($headings | Group-Object -CaseSensitive | Where-Object Count -gt 1)) { $warnings.Add("Repeated heading: $($group.Name)") }
$previousLevel = 0
foreach ($header in $headers) {
    $level = [int]$header.c[0]
    if ($level -gt 4) { $issues.Add('Heading levels deeper than four are not supported by the project style.') }
    if ($level -gt $previousLevel + 1) { $issues.Add("Skipped heading level near: $(Get-InlineText $header.c[2])") }
    $previousLevel = $level
}
foreach ($link in @($nodes | Where-Object t -eq 'Link')) {
    $target = $link.c[2][0]
    if ($target.StartsWith('#') -and $ids -cnotcontains [Uri]::UnescapeDataString($target.Substring(1))) { $issues.Add("Broken heading link: $target") }
}
if (@($nodes | Where-Object { $_.t -eq 'Image' }).Count) { $issues.Add('Summary must be self-contained prose; replace image dependencies with descriptions.') }
if (@($nodes | Where-Object { $_.t -in @('RawBlock', 'RawInline', 'Table') }).Count) { $issues.Add('Remove raw HTML or tables; use prose or simple lists.') }
if ($markdown -match '(?im)\[(Book Title|TODO|TBD|INSERT[^\]]*)\]|\bTODO\b|\bTBD\b') { $issues.Add('Unresolved placeholder found.') }
if ($markdown -match '(?im)\b(partial draft|incomplete draft)\b') { $issues.Add('A partial draft cannot be published as complete.') }
if (-not $coverage.PSObject.Properties['schemaVersion'] -or $coverage.schemaVersion -ne 1) { $issues.Add('Unsupported or missing coverage schemaVersion.') }
if (-not $coverage.PSObject.Properties['inventoryReviewed'] -or $coverage.inventoryReviewed -isnot [bool] -or -not $coverage.inventoryReviewed) { $issues.Add('Coverage inventory must be reconciled and inventoryReviewed=true.') }
if (-not $coverage.PSObject.Properties['sourceSha256'] -or $coverage.sourceSha256 -notmatch '^[a-fA-F0-9]{64}$') { $issues.Add('Coverage requires the source SHA-256 hash.') }
$sections = if ($coverage.PSObject.Properties['sections']) { @($coverage.sections) } else { @() }
if ($sections.Count -eq 0) { $issues.Add('Coverage inventory has no sections.') }
$sectionIds = @{}
foreach ($section in $sections) {
    $missing = @('id', 'title', 'sourceLocation', 'kind', 'substantive', 'readStatus', 'summaryHeading', 'notes') | Where-Object { -not $section.PSObject.Properties[$_] }
    if ($missing) { $issues.Add("Coverage entry missing fields: $($missing -join ', ')"); continue }
    if (-not $section.id -or $sectionIds.ContainsKey($section.id)) { $issues.Add("Missing or duplicate coverage ID: $($section.id)") }
    else { $sectionIds[$section.id] = $true }
    if (-not $section.title -or -not $section.sourceLocation) { $issues.Add("Missing title or source location: $($section.id)") }
    if ($section.substantive -isnot [bool]) { $issues.Add("substantive must be boolean: $($section.id)") }
    if ($section.kind -eq 'unclassified') { $issues.Add("Unclassified file placeholder: $($section.id)") }
    if ($section.readStatus -notin @('unread', 'read', 'partial', 'unavailable')) { $issues.Add("Invalid reading status: $($section.id)") }
    if ($section.substantive) {
        if ($section.readStatus -ne 'read') { $issues.Add("Substantive section is not fully read: $($section.title)") }
        if (-not $section.summaryHeading -or $headings -cnotcontains $section.summaryHeading) { $issues.Add("Coverage heading does not exist: $($section.title) -> $($section.summaryHeading)") }
    } elseif (-not $section.notes) { $issues.Add("Explain non-substantive exclusion: $($section.id)") }
}
$manifestPath = Join-Path (Split-Path -Parent $CoveragePath) 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($coverage.sourceSha256 -cne $manifest.sourceSha256) { $issues.Add('Coverage source hash differs from the extraction manifest.') }
    $resourcePaths = @($manifest.resources | ForEach-Object { $_.path })
    $representedPaths = @()
    foreach ($section in $sections) {
        if (-not $section.PSObject.Properties['sourceLocation']) { continue }
        # Optional paragraph ranges use "path :: paragraphs 1-3"; anchors use "path#id".
        $location = [string]$section.sourceLocation
        $path = ($location -split ' :: ', 2)[0]
        $anchor = $null
        if ($path.Contains('#')) { $path, $anchor = $path -split '#', 2 }
        $representedPaths += $path
        if ($resourcePaths -cnotcontains $path) { $issues.Add("Coverage location is not an EPUB manifest resource: $location"); continue }
        if ($anchor) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $rawRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) 'raw')) + [IO.Path]::DirectorySeparatorChar
            $rawPath = [IO.Path]::GetFullPath((Join-Path $rawRoot $path))
            if (-not $rawPath.StartsWith($rawRoot, [StringComparison]::OrdinalIgnoreCase)) { $issues.Add("Coverage path escapes extraction folder: $location"); continue }
            if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
                # Parse the preserved XHTML with external entity resolution disabled.
                $xmlSettings = [Xml.XmlReaderSettings]::new()
                $xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Ignore
                $xmlSettings.XmlResolver = $null
                $reader = [Xml.XmlReader]::Create($rawPath, $xmlSettings)
                try {
                    $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader)
                    if (-not @($xml.SelectNodes('//*[@id]') | Where-Object { $_.GetAttribute('id') -ceq [Uri]::UnescapeDataString($anchor) }).Count) { $issues.Add("Coverage source anchor does not exist: $location") }
                } finally { $reader.Dispose() }
            } else { $warnings.Add("Preserved XHTML unavailable for anchor checking: $path") }
        }
    }
    foreach ($entry in $manifest.readingOrder) {
        if ($representedPaths -cnotcontains $entry.sourcePath) { $issues.Add("Reading-order file has no coverage entry or explained exclusion: $($entry.sourcePath)") }
    }
    if (Test-Path -LiteralPath $manifest.sourcePath -PathType Leaf) {
        $currentHash = (Get-FileHash -LiteralPath $manifest.sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -cne $manifest.sourceSha256) { $issues.Add('Source book changed since extraction; reconcile the inventory against the new edition.') }
    } else { $warnings.Add('Original source is unavailable for a current hash check.') }
} else { $warnings.Add('No adjacent extraction manifest; source identity could not be cross-checked.') }
$words = [regex]::Matches($markdown, '\S+').Count
foreach ($warning in $warnings) { Write-Warning $warning }
if ($issues.Count) {
    foreach ($issue in $issues) { Write-Host "ERROR: $issue" }
    throw "Summary validation failed with $($issues.Count) issue(s)."
}
Write-Host "Structural checks passed: approximately $words words, $($sections.Count) coverage entries."
Write-Host 'Still required: manual review of source fidelity, quotations, actual coverage, language, and repetition.'
