# Test strategy

## Core invariant

A single edit to the mirror buffer must produce exactly one change in the source buffer. All other bytes must remain identical. This is the non-negotiable property that every test must verify.

## Test layers

### Layer 1: Line-level isolation (most important)

For any edit, count lines that differ between source and result. For N edits, exactly N lines (or the lines within N blocks) should differ. Line count must be preserved for in-place edits.

Helper: `el-prisma-iso--count-line-diffs` counts lines that differ, including length mismatch.

### Layer 2: Byte-level isolation

For unchanged regions, verify byte-identical content:
- Everything before the changed node's range: identical
- Everything after the changed node's range: identical

### Layer 3: Block-level isolation

Split source and result by `\n\n`, compare block-by-block. For N edits, exactly N blocks should differ.

Helper: `el-prisma-iso--count-block-changes`, `el-prisma-iso--changed-block-indices`.

### Layer 4: Whitespace preservation

Test with sources that have non-standard inter-block whitespace (triple newlines, quadruple newlines). Verify that ALL original whitespace patterns are preserved after commit.

Test fixture: `el-prisma-iso--md-varied-ws` has 2, 3, and 4 newlines between blocks.

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

## Real-file test

Must test with actual markdown files (not just synthetic fixtures). The file `~/GitHub/agzam/Redesigning remoto.el lookup architectur.md` (36KB) is a known regression case. A single word edit should produce exactly 1 line diff.
