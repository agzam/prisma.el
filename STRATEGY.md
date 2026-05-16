# Test strategy

## Core invariant

A single edit to the mirror buffer must produce exactly one change in the source buffer. All other bytes must remain identical. This is the non-negotiable property that every test must verify.

## Test layers

### Layer 1: Line-level isolation (most important)

For any edit, count lines that differ between source and result. For N edits, exactly N lines (or the lines within N blocks) should differ. Line count must be preserved for in-place edits.

Helper: `prisma-iso--count-line-diffs` counts lines that differ, including length mismatch.

### Layer 2: Byte-level isolation

For unchanged regions, verify byte-identical content:
- Everything before the changed node's range: identical
- Everything after the changed node's range: identical

### Layer 3: Block-level isolation

Split source and result by `\n\n`, compare block-by-block. For N edits, exactly N blocks should differ.

Helper: `prisma-iso--count-block-changes`, `prisma-iso--changed-block-indices`.

### Layer 4: Whitespace preservation

Test with sources that have non-standard inter-block whitespace (triple newlines, quadruple newlines). Verify that ALL original whitespace patterns are preserved after commit.

Test fixture: `prisma-iso--md-varied-ws` has 2, 3, and 4 newlines between blocks.

## Test matrix

### Group A: In-place edits (single edit, same structure)

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| A1 | Edit paragraph word | 1 block differs | DONE |
| A2 | Edit heading text | 1 block differs | DONE |
| A3 | Edit code block body | 1 block differs | DONE |
| A4 | Edit code block lang | 1 block differs | DONE (fixture) |
| A5 | Edit list item | 1 block differs | DONE |
| A6 | Edit link URL | 1 block differs | DONE (fixture) |
| A7 | Edit link text | 1 block differs | DONE (fixture) |
| A8 | Edit bold inside paragraph | 1 block differs | DONE |
| A9 | Edit blockquote content | 1 block differs | DONE |
| A10 | Edit h2 heading | 1 block differs | DONE |
| A11 | Single char change in large doc | 1 block differs | DONE |

### Group A-WS: Whitespace preservation (CRITICAL)

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| WS1 | Edit in doc with triple-newline gap | 1 line differs, line count preserved | DONE |
| WS2 | Edit preserves exact bytes outside changed node | prefix + suffix identical | DONE |
| WS3 | Edit last block, preserve preceding whitespace | all preceding bytes identical | DONE |
| WS4 | Edit first block, preserve following whitespace | all following bytes identical | DONE |
| WS5 | Two edits in varied-ws doc | 2 lines differ, line count preserved | DONE |
| WS6 | Org source with varied whitespace | 1 line differs | DONE |

### Group B: Structural changes (rearrangement)

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| B1 | org-metaup Step 2 | Step 2 before Step 1, uninvolved blocks preserved | DONE |
| B2 | Reorder preserves moved content byte-identically | swapped blocks identical | DONE |
| B3 | Reorder + edit third section | swap applied + edit applied + guide preserved | DONE |
| B4 | Org source: swap sections | uninvolved blocks preserved | DONE |

### Group C: Baselines

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| C1 | Convert + immediate commit (MD) | Byte-identical | DONE |
| C2 | Convert + immediate commit (Org) | Byte-identical | DONE |

### Group D: Multiple edits

| Test | Operations | Verify | Status |
|------|------------|--------|--------|
| D1 | Two edits in 5-block doc | exactly 2 blocks differ | DONE |
| D2 | Edit first + last blocks | middle 3 intact | DONE |
| D3 | Three edits in 7-block doc | exactly 3 blocks differ | DONE |

### Group E: Node insertion/deletion

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| E1 | Insert paragraph between existing | all originals preserved | DONE |
| E2 | Insert new heading | correct syntax, originals preserved | DONE |
| E3 | Delete middle paragraph | surrounding blocks preserved | DONE |
| E4 | Delete heading + body | surrounding blocks preserved | DONE |

### Group F: Boundary cases

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| F1 | Insert at buffer start | original content preserved | DONE |
| F2 | Append at buffer end | original content preserved | DONE |
| F3 | Merge paragraphs (delete blank line) | heading + third paragraph preserved | DONE |
| F4 | Split paragraph (insert heading) | surrounding blocks preserved | DONE |
| F5 | Add lines to paragraph | 1 block differs | DONE |
| F6 | Add lines to code block | 1 block differs | DONE |

### Group G: Tables

Tables are structured nodes in the intermediary model (`table`, `table-row`, `table-separator`, `table-cell`). Conversion is asymmetric by design: MD renders in loose form (one-space cell padding, separator dashes match header cell widths) so committed output matches hand-written MD shape; Org renders column-aligned (cells padded to max column `string-width`, `+` joiner) so the mirror buffer is comfortable to edit. Round-trips with no edits are byte-identical via the source-bytes path; edited tables re-render in the target format's preferred shape.

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| G1 | MD->Org basic conversion | + separator, columns padded by `string-width` | DONE |
| G2 | Org->MD basic conversion | `|` separator, loose (1-space) padding | DONE |
| G3 | MD->Org->MD round-trip (no edits) | Byte-identical via source bytes | DONE |
| G4 | Org->MD->Org round-trip (no edits) | Byte-identical via source bytes | DONE |
| G5 | Edit cell in MD source via Org mirror | 1 block differs (the table) | DONE |
| G6 | Edit cell in Org source via MD mirror | 1 block differs | DONE |
| G7 | Inline bold/italic/code in cells | Markup converts in both directions | DONE |
| G8 | Link inside cell | Link syntax converts | DONE |
| G9 | MD alignment markers (:---, :---:, ---:) | Parsed; emitted on MD output; absent on Org | DONE |
| G10 | Empty cell | Renders as space-padded | DONE |
| G11 | Single-column table | Renders correctly | DONE |
| G12 | Wide chars (CJK) in cells | `string-width` based padding | DONE |
| G13 | Header-only table (no body rows) | Renders correctly | DONE |
| G14 | Org table without separator -> MD | Separator injected after first row | DONE |
| G15 | Multiple hlines in Org -> MD | Collapsed to single header separator | DONE |
| G16 | Long content overflows column | Column expands on re-render | DONE |
| G17 | Escaped pipe in cell (`\|`) | Round-trips through both formats | DONE |
| G18 | Table after a paragraph (preceded by `Before`) | Both blocks preserved | DONE |
| G19 | Table before a paragraph | Both blocks preserved | DONE |
| G20 | Header cell edit | 1 block differs | DONE |

## Real-file test

Must test with actual markdown files (not just synthetic fixtures). The file `~/GitHub/agzam/Redesigning remoto.el lookup architectur.md` (36KB) is a known regression case. A single word edit should produce exactly 1 line diff.
