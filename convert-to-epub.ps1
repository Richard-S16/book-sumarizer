<#
.SYNOPSIS
Converts Markdown summaries to EPUB with Pandoc, optionally using Calibre.
.DESCRIPTION
Relative paths are resolved from this script's directory. Existing EPUBs are
preserved unless -Overwrite is supplied. Calibre uses Pandoc to read Markdown
and its YAML metadata before converting the intermediate EPUB.
.EXAMPLE
.\convert-to-epub.ps1 -InputPath 'Summaries\My Book Complete Summary.md'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$InputPath = 'Summaries',
    [ValidateNotNullOrEmpty()][string]$OutputPath = 'EPUB',
    [switch]$UseCalibre,
    [switch]$ValidateWithEpubCheck,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'epub-functions.ps1')

function Resolve-Tool {
    param([string]$Name, [string[]]$CandidatePaths)
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($candidate in $CandidatePaths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) { return $expanded }
    }
    return $null
}

function Get-ProjectPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $PSScriptRoot $Path }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-Epub {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Converter did not create an EPUB: $Path"
    }
    Test-EpubPackage $Path
}

$InputPath = Get-ProjectPath $InputPath
$OutputPath = Get-ProjectPath $OutputPath
$inputItem = Get-Item -LiteralPath $InputPath
if ($inputItem.PSIsContainer) {
    $markdownFiles = @(Get-ChildItem -LiteralPath $InputPath -Filter '*.md' -File | Sort-Object Name)
} else {
    if ($inputItem.Extension -ine '.md') { throw 'Input must be a Markdown (.md) file or a directory.' }
    $markdownFiles = @($inputItem)
}
if ($markdownFiles.Count -eq 0) {
    Write-Host "No Markdown files found in '$InputPath'."
    return
}
if ((Test-Path -LiteralPath $OutputPath) -and -not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    throw "Output path must be a directory: $OutputPath"
}
$pending = @($markdownFiles | Where-Object {
    $destination = Join-Path $OutputPath ($_.BaseName + '.epub')
    if ((Test-Path -LiteralPath $destination) -and -not $Overwrite) {
        Write-Host "Skipping existing EPUB: $destination"
        $false
    } else { $true }
})
if ($pending.Count -eq 0) { return }

$pandoc = Resolve-Tool 'pandoc' @(
    '%LOCALAPPDATA%\Pandoc\pandoc.exe',
    '%PROGRAMFILES%\Pandoc\pandoc.exe',
    '%PROGRAMFILES(X86)%\Pandoc\pandoc.exe'
)
if (-not $pandoc) { throw 'Pandoc was not found. Install Pandoc and open a new terminal. Pandoc is required for both conversion modes.' }
$calibre = $null
$epubCheck = $null
if ($ValidateWithEpubCheck) {
    $epubCheckCommand = Get-Command 'epubcheck' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $epubCheckCommand) { throw 'EPUBCheck was requested but epubcheck was not found on PATH.' }
    $epubCheck = $epubCheckCommand.Source
}
if ($UseCalibre) {
    $calibre = Resolve-Tool 'ebook-convert' @(
        '%PROGRAMFILES%\Calibre2\ebook-convert.exe',
        '%PROGRAMFILES(X86)%\Calibre2\ebook-convert.exe'
    )
    if (-not $calibre) { throw "Calibre's ebook-convert was not found. Install Calibre and open a new terminal." }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Directory]::CreateDirectory($OutputPath) | Out-Null
$failures = @()
foreach ($file in $pending) {
    $outputFile = Join-Path $OutputPath ($file.BaseName + '.epub')
    # Stage on the destination volume so a failed conversion cannot replace a good EPUB.
    $staging = Join-Path $OutputPath ('.convert-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        Write-Host "Converting: $($file.Name)"
        $temporaryEpub = Join-Path $staging 'pandoc.epub'
        & $pandoc $file.FullName --from markdown-smart --to epub3 --standalone --toc --toc-depth 3 --split-level 2 --resource-path $file.DirectoryName --output $temporaryEpub
        if ($LASTEXITCODE -ne 0) { throw "Pandoc exited with code $LASTEXITCODE." }
        Assert-Epub $temporaryEpub
        if ($UseCalibre) {
            $calibreEpub = Join-Path $staging 'calibre.epub'
            & $calibre $temporaryEpub $calibreEpub
            if ($LASTEXITCODE -ne 0) { throw "Calibre exited with code $LASTEXITCODE." }
            Assert-Epub $calibreEpub
            $temporaryEpub = $calibreEpub
        }
        if ($ValidateWithEpubCheck) {
            & $epubCheck $temporaryEpub
            if ($LASTEXITCODE -ne 0) { throw "EPUBCheck exited with code $LASTEXITCODE." }
        }
        if (Test-Path -LiteralPath $outputFile) {
            if (-not $Overwrite) { throw 'Destination appeared during conversion; rerun with -Overwrite to replace it.' }
            [IO.File]::Replace($temporaryEpub, $outputFile, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($temporaryEpub, $outputFile)
        }
        Write-Host "Created: $outputFile"
    } catch {
        $failures += $file.Name
        Write-Warning "Failed to convert '$($file.Name)': $($_.Exception.Message)"
    } finally {
        # Only files directly created in this unique staging directory are removed.
        foreach ($temporaryName in @('pandoc.epub', 'calibre.epub')) {
            $temporaryPath = Join-Path $staging $temporaryName
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { [IO.File]::Delete($temporaryPath) }
        }
        [IO.Directory]::Delete($staging)
    }
}
if ($failures.Count -gt 0) {
    throw "Conversion failed for $($failures.Count) file(s): $($failures -join ', ')"
}
