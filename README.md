# Book Summarizer

Create source-grounded Markdown study guides and optional EPUB editions. Agents start with `AGENTS.md`, follow `prompt.md`, and read defaults from `summary-settings.json`. Explicit user requests override defaults.

## Defaults

- Standard depth: approximately 15-25% of substantive source words, usually 4,000-10,000 words including study aids. Brief and comprehensive modes are available.
- Preserve the source language. Set `language` to a specific tag, such as `pt-BR` or `en-US`, to request another language.
- Textual critical analysis: assess what the book supports internally. Externally verified analysis requires authoritative sources and dated references.
- Markdown output with useful study aids. Add `epub` to `formats` or request EPUB explicitly to also convert it.

All depth levels require reading and accounting for the full accessible source. Length budgets are flexible; they do not justify skipping chapters or articles.

## Workflow

1. Put books in `Sources/`.
2. Prepare an EPUB with PowerShell and Pandoc:

   ```powershell
   .\extract-epub.ps1 -InputPath 'Sources\Book.epub'
   ```

   The utility prints a new `Working/<book-id>/` folder. It never overwrites an existing folder; resume that folder or supply a distinct `-BookId`. Relative paths resolve from the script's folder. Other book formats require a separate extraction method.

3. Ask the agent to follow `prompt.md`, read the book, and draft the summary. Example: "Summarize this book in Portuguese at comprehensive depth and create an EPUB."
4. Review the final draft and validate its structure and coverage records:

   ```powershell
   .\validate-summary.ps1 -InputPath 'Working\<book-id>\draft.md' -CoveragePath 'Working\<book-id>\coverage.json'
   ```

5. After automated checks and manual editorial review, publish the finished Markdown in `Summaries/` as `[Book Title] - Complete Summary.md`.
6. Convert the exact finished summary if EPUB is wanted:

   ```powershell
   .\convert-to-epub.ps1 -InputPath 'Summaries\Book Title - Complete Summary.md'
   ```

## Working records and coverage

Each new book gets its own working directory containing:

- `raw/`: original EPUB files, including XHTML, notes, and images. These are source material; do not execute embedded content.
- `text/`: plain-text files in EPUB spine order. Typography may be lost; consult the original XHTML for quotations, footnotes, and speaker distinctions.
- `manifest.json`: source SHA-256, unverified metadata, reading order, headings, navigation, and resource inventory.
- `coverage.json`: an initially unread file inventory that must be reconciled into meaningful chapters/articles before use.
- `evidence.md`: claim/quotation references and verification status.
- `progress.md` and drafts: effective settings, completed work, unresolved issues, and next reading location.

One EPUB file can contain many essays, and navigation can omit material. Inspect internal structure and add a coverage entry for each substantive article or chapter, plus substantive notes and appendices. Record original publication dates and contributors when available. Set `inventoryReviewed` to true only after reconciling the inventory against the full book.

Coverage schema version 1 uses `sourceSha256`, `inventoryReviewed`, and `sections`. Each section requires `id`, `title`, `sourceLocation`, `kind`, `substantive`, `readStatus`, `summaryHeading`, and `notes`. Optional fields include `originalDate`, `publication`, and `contributor`. `readStatus` is `unread`, `read`, `partial`, or `unavailable`; `summaryHeading` must exactly match a draft heading without its Markdown hashes. Give non-substantive exclusions a reason in `notes`. Replace the extractor's `unclassified` placeholders with actual section kinds.

The validator checks metadata parsing, required headings, heading hierarchy, internal heading links, placeholders, image/HTML/table dependencies, and reconciled coverage records. Where an adjacent manifest exists, it also compares source hashes, checks source paths and preserved XHTML anchors, and requires every reading-order file to have coverage or an explained exclusion. Source locations use `path/to/chapter.xhtml#anchor` or `path/to/chapter.xhtml :: paragraphs 1-3`; paragraph ranges require manual checking. It cannot prove that reading occurred, the inventory is exhaustive, or claims are correct. The evidence ledger and source fidelity still require manual review.

For translated headings, pass all five exact required headings in the output language, for example:

```powershell
.\validate-summary.ps1 -InputPath 'Working\<book-id>\draft.md' -CoveragePath 'Working\<book-id>\coverage.json' -RequiredHeadings @('Sobre este resumo', 'Resumo condensado', 'Resumo por capítulo', 'Principais conclusões', 'Auditoria de cobertura e confiabilidade')
```

Existing loose files in `Working/` belong to the earlier Naval summary. They remain unchanged and are not automatically certified or migrated by the new checks.

## EPUB conversion

Pandoc is required by all three utilities. PATH and common Windows installation locations are checked. PowerShell 7 is recommended.

Run `convert-to-epub.ps1` without arguments to convert all `.md` files directly inside `Summaries/`. Outputs go into `EPUB/` using the exact Markdown base filename. `-OutputPath` specifies a directory, not a filename. Relative paths resolve from the script's folder; absolute paths also work. Legacy EPUB names are not automatically renamed or removed.

Existing outputs are skipped. Add `-Overwrite` only for an intentional replacement. Conversion happens in a unique staging directory, and an existing output is replaced only after conversion and package/navigation checks succeed. A batch continues after individual failures and reports an error at the end. Major level-two sections are split into separate EPUB content files; navigation includes level-three chapter headings.

Use `-UseCalibre` to process Pandoc's EPUB with Calibre's `ebook-convert`. Calibre may change metadata and format details; in an earlier sample it normalized `pt-BR` to `pt`. Prefer default Pandoc conversion when retaining language regions or EPUB 3 matters.

Use `-ValidateWithEpubCheck` to require an `epubcheck` command on PATH and run it before publishing each EPUB. Built-in checks cover required entries, package XML, manifest resources, reading order, and EPUB 3 table-of-contents targets and anchors. EPUB 2 checks verify its NCX reference and XML. These are not full standards validation or visual reading-app checks. Missing EPUBCheck is an error only when that option is requested.

## Verification

Run `./tests/workflow.tests.ps1` in PowerShell to exercise extraction, coverage validation, navigation checks, conversion splitting, and overwrite protection using temporary fixtures. Existing source books and summaries are not changed.

Add `-IncludeProjectBooks` to also extract every source EPUB and convert existing summaries inside a temporary copy of the tooling. Temporary fixtures are removed after the run.
