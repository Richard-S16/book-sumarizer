[CmdletBinding()]
param([switch]$IncludeProjectBooks)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'epub-functions.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testId = 'workflow-test-' + [guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) $testId
$workingDirectory = Join-Path (Join-Path $projectRoot 'Working') $testId
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
$checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
    Write-Host "PASS: $Message"
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Expected, [string]$Message)
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    Assert-True ([bool]($caught -and $caught -like "*$Expected*")) "$Message (expected: $Expected; actual: $caught)"
}
function Write-Zip {
    param([string]$Path, [hashtable]$Entries)
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($key in $Entries.Keys) {
            $entry = $archive.CreateEntry($key)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write($Entries[$key]) } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
}
try {
    $sourcePath = Join-Path $temporaryRoot 'Coleção de artigos.epub'
    $entries = @{
        'mimetype' = 'application/epub+zip'
        'META-INF/container.xml' = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
        'OPS/book.opf' = '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Coleção</dc:title><dc:language>pt-BR</dc:language></metadata><manifest><item id="articles" href="articles.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="image" href="image.svg" media-type="image/svg+xml"/></manifest><spine><itemref idref="articles"/><itemref idref="notes"/></spine></package>'
        'OPS/articles.xhtml' = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Artigos</title></head><body><h1 id="a">Primeiro artigo</h1><p>Um argumento sobre educação.</p><h2 id="b">Segundo artigo</h2><p>Outro argumento, com <a href="notes.xhtml#n">nota</a>.</p><img src="image.svg" alt="Diagrama"/></body></html>'
        'OPS/notes.xhtml' = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Notas</title></head><body><h1 id="n">Notas do editor</h1><p>Contexto editorial.</p></body></html>'
        'OPS/nav.xhtml' = '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Sumário</title></head><body><nav epub:type="toc"><ol><li><a href="articles.xhtml#a">Artigos</a></li><li><a href="notes.xhtml#n">Notas</a></li></ol></nav></body></html>'
        'OPS/image.svg' = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'
    }
    Write-Zip $sourcePath $entries
    Test-EpubPackage $sourcePath
    Assert-True $true 'A complete EPUB 3 package and navigation are accepted'
    & (Join-Path $projectRoot 'extract-epub.ps1') -InputPath $sourcePath -BookId $testId
    $manifest = Get-Content (Join-Path $workingDirectory 'manifest.json') -Raw | ConvertFrom-Json
    $coveragePath = Join-Path $workingDirectory 'coverage.json'
    $coverage = Get-Content $coveragePath -Raw | ConvertFrom-Json
    Assert-True ($manifest.readingOrder.Count -eq 2 -and $manifest.readingOrder[0].sourcePath -eq 'OPS/articles.xhtml') 'Extraction follows spine order'
    Assert-True ($manifest.readingOrder[0].headings.Count -eq 2) 'Internal article headings are inventoried even when navigation omits one'
    Assert-True ((Get-Content (Join-Path $workingDirectory 'text/0001.txt') -Raw) -match 'educação') 'Extracted UTF-8 text retains accents'
    Assert-True (Test-Path (Join-Path $workingDirectory 'raw/OPS/image.svg')) 'Original images are retained'
    Assert-True (-not $coverage.inventoryReviewed -and @($coverage.sections | Where-Object readStatus -ne 'unread').Count -eq 0) 'Extraction never marks coverage reviewed or read'
    Assert-Rejected { & (Join-Path $projectRoot 'extract-epub.ps1') -InputPath $sourcePath -BookId $testId } 'already exists' 'Existing working records are protected'

    $draftPath = Join-Path $temporaryRoot 'Coleção - Complete Summary.md'
    @'
---
title: "Coleção - Complete Summary"
lang: "pt-BR"
---
# Coleção

## About This Summary
An independent study guide.

## One-Page Condensed Summary
A concise orientation.

## Chapter-by-Chapter Summary
### Primeiro artigo
A synthesis. [Second article](#segundo-artigo).

### Segundo artigo
An explanation.

## Key Takeaways
An important lesson.

## Coverage And Reliability Audit
Coverage and limitations explained.
'@ | Set-Content $draftPath -Encoding utf8
    Assert-Rejected { & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath } 'validation failed' 'Unreviewed and unread coverage cannot pass'
    $coverage.inventoryReviewed = $true
    $coverage.sections = @(
        [ordered]@{id='article-1';title='Primeiro artigo';sourceLocation='OPS/articles.xhtml#a';kind='article';substantive=$true;readStatus='read';summaryHeading='Primeiro artigo';notes='Test fixture'},
        [ordered]@{id='article-2';title='Segundo artigo';sourceLocation='OPS/articles.xhtml#b';kind='article';substantive=$true;readStatus='read';summaryHeading='Segundo artigo';notes='Test fixture'},
        [ordered]@{id='notes';title='Notas';sourceLocation='OPS/notes.xhtml#n';kind='editor-notes';substantive=$true;readStatus='read';summaryHeading='Coverage And Reliability Audit';notes='Test fixture'}
    )
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath
    Assert-True $true 'Reconciled article-level coverage and valid Markdown pass'
    $validDraft = Get-Content $draftPath -Raw
    $validDraft.Replace('### Primeiro artigo', "### Author's example") | Set-Content $draftPath -Encoding utf8
    $coverage.sections[0].summaryHeading = "Author's example"
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath
    Assert-True $true 'Literal apostrophes in coverage headings are preserved'
    $coverage.sections[0].summaryHeading = 'Primeiro artigo'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    $validDraft.Replace('#segundo-artigo', '#missing') | Set-Content $draftPath -Encoding utf8
    Assert-Rejected { & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath } 'validation failed' 'Broken internal heading links fail'
    $validDraft | Set-Content $draftPath -Encoding utf8
    $coverage.sections[1].readStatus = 'partial'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    Assert-Rejected { & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath } 'validation failed' 'A partially read article prevents completion'
    $coverage.sections[1].readStatus = 'read'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    $coverage.sections[1].sourceLocation = 'OPS/articles.xhtml#invented'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    Assert-Rejected { & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath } 'validation failed' 'Invented source anchors are rejected'
    $coverage.sections[1].sourceLocation = 'OPS/articles.xhtml#b'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    $savedSections = $coverage.sections
    $coverage.sections = @($coverage.sections | Where-Object { $_.id -ne 'notes' })
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    Assert-Rejected { & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath } 'validation failed' 'Omitting an entire notes file prevents completion'
    $coverage.sections = $savedSections
    $originalHash = $coverage.sourceSha256
    $coverage.sourceSha256 = '0' * 64
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    Assert-Rejected { & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath } 'validation failed' 'Coverage for a different source hash is rejected'
    $coverage.sourceSha256 = $originalHash
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    $translatedDraft = $validDraft.Replace('About This Summary', 'Sobre este resumo').Replace('One-Page Condensed Summary', 'Resumo condensado').Replace('Chapter-by-Chapter Summary', 'Resumo por capítulo').Replace('Key Takeaways', 'Principais conclusões').Replace('Coverage And Reliability Audit', 'Auditoria de cobertura')
    $translatedDraft | Set-Content $draftPath -Encoding utf8
    $coverage.sections[2].summaryHeading = 'Auditoria de cobertura'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    & (Join-Path $projectRoot 'validate-summary.ps1') -InputPath $draftPath -CoveragePath $coveragePath -RequiredHeadings @('Sobre este resumo', 'Resumo condensado', 'Resumo por capítulo', 'Principais conclusões', 'Auditoria de cobertura')
    Assert-True $true 'Translated required headings are supported'
    $coverage.sections[2].summaryHeading = 'Coverage And Reliability Audit'
    $coverage | ConvertTo-Json -Depth 10 | Set-Content $coveragePath -Encoding utf8
    $validDraft | Set-Content $draftPath -Encoding utf8

    $outputDirectory = Join-Path $temporaryRoot 'output'
    & (Join-Path $projectRoot 'convert-to-epub.ps1') -InputPath $draftPath -OutputPath $outputDirectory
    $outputFile = Join-Path $outputDirectory 'Coleção - Complete Summary.epub'
    Assert-True (Test-Path $outputFile) 'Conversion preserves the Markdown base filename'
    Test-EpubPackage $outputFile
    $archive = [IO.Compression.ZipFile]::OpenRead($outputFile)
    try {
        $package = Get-EpubPackage $archive
        $spineCount = $package.Document.SelectNodes('//*[local-name()="spine"]/*[local-name()="itemref"]').Count
        Assert-True ($spineCount -gt 3) 'Major sections are split across EPUB content documents'
        Assert-True ($package.Document.SelectSingleNode('//*[local-name()="language"]').InnerText -eq 'pt-BR') 'EPUB language preserves pt-BR'
    } finally { $archive.Dispose() }
    $before = (Get-FileHash $outputFile).Hash
    & (Join-Path $projectRoot 'convert-to-epub.ps1') -InputPath $draftPath -OutputPath $outputDirectory
    Assert-True ((Get-FileHash $outputFile).Hash -eq $before) 'Existing EPUB is unchanged without Overwrite'
    & (Join-Path $projectRoot 'convert-to-epub.ps1') -InputPath $draftPath -OutputPath $outputDirectory -Overwrite
    Test-EpubPackage $outputFile
    Assert-True $true 'Explicit overwrite produces a validated EPUB'

    $entries['OPS/nav.xhtml'] = $entries['OPS/nav.xhtml'].Replace('articles.xhtml#a', 'articles.xhtml#missing')
    $brokenPath = Join-Path $temporaryRoot 'broken.epub'
    Write-Zip $brokenPath $entries
    Assert-Rejected { Test-EpubPackage $brokenPath } 'Broken navigation anchor' 'Broken EPUB navigation anchors are rejected'
    $entries['OPS/nav.xhtml'] = $entries['OPS/nav.xhtml'].Replace('articles.xhtml#missing', 'articles.xhtml#a')
    $entries['../escaped.txt'] = 'Must never be written'
    $unsafePath = Join-Path $temporaryRoot 'unsafe.epub'
    Write-Zip $unsafePath $entries
    Assert-Rejected { & (Join-Path $projectRoot 'extract-epub.ps1') -InputPath $unsafePath -BookId ($testId + '-bad') } 'escapes working folder' 'Archive traversal is rejected before extraction'
    Assert-True (-not (Test-Path (Join-Path (Join-Path $projectRoot 'Working') ($testId + '-bad')))) 'Rejected archive leaves no working folder'
    if ($IncludeProjectBooks) {
        # Run actual source extraction in a temporary copy of the tooling.
        foreach ($toolName in @('extract-epub.ps1', 'epub-functions.ps1', 'convert-to-epub.ps1')) { Copy-Item -LiteralPath (Join-Path $projectRoot $toolName) -Destination $temporaryRoot }
        $bookIndex = 0
        foreach ($book in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Sources') -Filter '*.epub' -File) {
            $bookIndex++
            $bookHash = (Get-FileHash -LiteralPath $book.FullName).Hash
            & (Join-Path $temporaryRoot 'extract-epub.ps1') -InputPath $book.FullName -BookId "source-$bookIndex"
            $bookManifest = Get-Content (Join-Path $temporaryRoot "Working/source-$bookIndex/manifest.json") -Raw | ConvertFrom-Json
            Assert-True ($bookManifest.readingOrder.Count -gt 0 -and $bookManifest.navigation.Count -gt 0) "Actual book extraction includes reading order and navigation: $($book.Name)"
            Assert-True ((Get-FileHash -LiteralPath $book.FullName).Hash -eq $bookHash) 'Source EPUB remains unchanged'
        }
        $summaryIndex = 0
        foreach ($summary in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Summaries') -Filter '*.md' -File) {
            $summaryIndex++
            $summaryHash = (Get-FileHash -LiteralPath $summary.FullName).Hash
            & (Join-Path $temporaryRoot 'convert-to-epub.ps1') -InputPath $summary.FullName -OutputPath (Join-Path $temporaryRoot "actual-output-$summaryIndex")
            Assert-True ((Get-FileHash -LiteralPath $summary.FullName).Hash -eq $summaryHash) 'Actual summary converts without modifying its Markdown'
        }
    }
    Write-Host "All $checks checks passed."
} finally {
    # Only remove the exact unique fixture paths after checking their resolved parents.
    $expectedTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $expectedWorkingParent = [IO.Path]::GetFullPath((Join-Path $projectRoot 'Working')).TrimEnd('\', '/')
    foreach ($fixture in @($temporaryRoot, $workingDirectory)) {
        $absolute = [IO.Path]::GetFullPath($fixture)
        $parent = [IO.Path]::GetDirectoryName($absolute).TrimEnd('\', '/')
        if ([IO.Path]::GetFileName($absolute) -cne $testId -or ($parent -ine $expectedTempParent -and $parent -ine $expectedWorkingParent)) { throw "Refusing unexpected fixture cleanup path: $absolute" }
        if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    }
}
