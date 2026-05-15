# Test strategy

## Fixture

A complex GFM document (~80 lines) with every element type: headings (h1/h2/h3), paragraphs with inline formatting, code blocks (multiple), ordered and unordered lists, links, tables, blockquotes, horizontal rules. Defined as `el-prisma-e2e--complex-fixture` in `test/el-prisma-e2e-tests.el`.

## Invariant checker

`el-prisma-e2e--check-invariants` runs after every commit in structural tests. Checks:
1. Blank lines before every `##`/`###` heading
2. Code fence count preserved
3. Line count within tolerance

## Test matrix

### Group A: In-place edits (no structural change)

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| A1 | Edit paragraph word | 1 line differs | covered (older tests) |
| A2 | Edit heading | 1 line differs | covered (older tests) |
| A3 | Edit code block body | 1 line differs | covered (older tests) |
| A4 | Edit code block lang | 1 line differs | covered (older tests) |
| A5 | Edit list item | content preserved | covered (older tests) |
| A6 | Edit link URL | 1 line differs | covered (older tests) |
| A7 | Edit link text | 1 line differs | covered (older tests) |
| A8 | Edit bold text | 1 line differs | covered (older tests) |
| A9 | Edit inline code | 1 line differs | covered (older tests) |
| A10 | Edit blockquote | 1 line differs | covered (older tests) |

### Group B: Structural changes (rearrangement)

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| B1 | org-metaup on *** Step 2 | Step 2 before Step 1, all content, blank lines | DONE |
| B2 | org-metaup on *** Step 3 | Step 3 before Step 2, all content | DONE |
| B3 | org-metadown on *** Step 1 | Step 1 after Step 2, all content | DONE |
| B4 | org-metaup on ** Usage | Usage before Configuration, sub-sections intact | DONE |
| B5 | org-metaup on ** Troubleshooting | Troubleshooting before Architecture | DONE |
| B6 | org-metadown on ** Installation | Installation after Configuration | TODO |
| B7 | Insert line in code block | Only that code block changes | DONE |

### Group C: Baselines

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| C1 | Convert + immediate commit | Byte-identical | DONE |
| C2 | Replace with same text + commit | Byte-identical | DONE |

### Group D: Multiple operations

| Test | Operations | Verify | Status |
|------|------------|--------|--------|
| D1 | Edit heading + edit paragraph | Both changes present | DONE |
| D2 | Edit code block + edit list item | Both present, rest intact | TODO |
| D3 | org-metaup Step 2 + edit word | Rearrangement + edit applied | DONE |
| D4 | Edit word + org-metaup different section | Both applied | TODO |
| D5 | org-metaup + org-metaup (two rearrangements) | Both moves applied | TODO |

### Group E: Pre-existing changes

| Test | Setup | Verify | Status |
|------|-------|--------|--------|
| E1 | Modify source after convert | Concurrent modification detected | DONE |
| E2 | Modify source, confirm commit | Both changes applied | TODO |

### Group F: Cursor position

| Test | Source position | Expected mirror position | Status |
|------|----------------|--------------------------|--------|
| F1 | On `## Configuration` | On `** Configuration` line | DONE |
| F2 | On `### Step 2` | On `*** Step 2` line | TODO |
| F3 | On `## Usage` (after code blocks) | On `** Usage` line | DONE |
| F4 | On last line `MIT` | Near end of mirror | TODO |

## Known cosmetic issue

Rearrangement adds ~6 extra blank lines due to `\n\n` separator joining in `build-reorder-ops`. Content is correct; spacing is slightly off. Not a correctness issue.
