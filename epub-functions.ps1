# Shared EPUB readers. XML is data: never resolve external entities or DTDs.
function Read-EpubXml {
    param([IO.Compression.ZipArchive]$Archive, [string]$EntryPath)
    $entry = $Archive.GetEntry($EntryPath)
    if (-not $entry) { throw "Missing EPUB entry: $EntryPath" }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $stream = $entry.Open()
    $reader = [Xml.XmlReader]::Create($stream, $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Resolve-EpubEntry {
    param([string]$BasePath, [string]$Reference)
    if ($Reference -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $Reference.StartsWith('//')) {
        throw "External reference is not a local EPUB entry: $Reference"
    }
    $baseUri = [Uri]::new('https://epub.invalid/' + $BasePath)
    $resolved = [Uri]::new($baseUri, $Reference)
    if ($resolved.Host -ne 'epub.invalid') { throw "Invalid EPUB reference: $Reference" }
    return [Uri]::UnescapeDataString($resolved.AbsolutePath.TrimStart('/'))
}

function Get-EpubPackage {
    param([IO.Compression.ZipArchive]$Archive)
    $container = Read-EpubXml $Archive 'META-INF/container.xml'
    $rootfile = $container.SelectSingleNode('//*[local-name()="rootfile"]')
    if (-not $rootfile) { throw 'EPUB container has no rootfile.' }
    $packagePath = $rootfile.GetAttribute('full-path')
    if (-not $packagePath) { throw 'EPUB rootfile has no path.' }
    $package = Read-EpubXml $Archive $packagePath
    return @{ Path = $packagePath; Document = $package }
}

function Test-EpubPackage {
    param([string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $mimeEntry = $archive.GetEntry('mimetype')
        if (-not $mimeEntry) { throw 'EPUB has no mimetype entry.' }
        $reader = [IO.StreamReader]::new($mimeEntry.Open())
        try { $mime = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($mime -cne 'application/epub+zip') { throw 'Invalid EPUB mimetype.' }
        $package = Get-EpubPackage $archive
        $items = @{}
        $navItems = @()
        foreach ($item in $package.Document.SelectNodes('//*[local-name()="manifest"]/*[local-name()="item"]')) {
            $id = $item.GetAttribute('id')
            if (-not $id -or $items.ContainsKey($id)) { throw "Missing or duplicate manifest ID: $id" }
            $href = $item.GetAttribute('href')
            if (-not $href) { throw "Manifest item has no href: $id" }
            $entryPath = Resolve-EpubEntry $package.Path $href
            if (-not $archive.GetEntry($entryPath)) { throw "Missing manifest resource: $entryPath" }
            $items[$id] = $entryPath
            if (($item.GetAttribute('properties') -split '\s+') -contains 'nav') { $navItems += $entryPath }
        }
        $spine = @($package.Document.SelectNodes('//*[local-name()="spine"]/*[local-name()="itemref"]'))
        if ($spine.Count -eq 0) { throw 'EPUB has no reading-order entries.' }
        foreach ($itemref in $spine) {
            $idref = $itemref.GetAttribute('idref')
            if (-not $items.ContainsKey($idref)) { throw "Reading order points to unknown item: $idref" }
            $null = Read-EpubXml $archive $items[$idref]
        }
        $root = $package.Document.DocumentElement
        if ($root.GetAttribute('version') -like '3*') {
            if ($navItems.Count -ne 1) { throw 'EPUB 3 must have exactly one navigation document.' }
            $nav = Read-EpubXml $archive $navItems[0]
            $toc = $nav.SelectSingleNode('//*[local-name()="nav" and contains(concat(" ", @*[local-name()="type"], " "), " toc ")]')
            if (-not $toc) { throw 'Navigation document has no table of contents.' }
            $links = @($toc.SelectNodes('.//*[local-name()="a" and @href]'))
            if ($links.Count -eq 0) { throw 'Table of contents has no links.' }
            foreach ($link in $links) {
                $href = $link.GetAttribute('href')
                $targetPath = Resolve-EpubEntry $navItems[0] $href
                $target = Read-EpubXml $archive $targetPath
                if ($href.Contains('#')) {
                    $fragment = [Uri]::UnescapeDataString(($href -split '#', 2)[1])
                    if ($fragment -and -not @($target.SelectNodes('//*[@id]') | Where-Object { $_.GetAttribute('id') -ceq $fragment }).Count) {
                        throw "Broken navigation anchor: $href"
                    }
                }
            }
        } else {
            $spineNode = $package.Document.SelectSingleNode('//*[local-name()="spine"]')
            $tocId = $spineNode.GetAttribute('toc')
            if (-not $items.ContainsKey($tocId)) { throw 'EPUB 2 has no valid NCX reference.' }
            $null = Read-EpubXml $archive $items[$tocId]
        }
    } finally { $archive.Dispose() }
}
