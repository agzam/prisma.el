# Testing and architecture strategy

## Architecture (current state)

The commit pipeline uses a HYBRID approach:

### For in-place edits (no reorder):
Line-based diff detects changed nodes. When line count is the same,
per-node line extraction works. When line count differs (insertion/
deletion), uses adjusted byte coordinates with delta compensation,
then filters out nodes whose extracted text matches their original.

### For rearrangements (node order changed):
Text properties (`el-prisma-node-idx`) are set during convert and
travel with text through kill/yank and org-metaup/down. On commit,
the property order is compared to original. If different,
`build-reorder-ops` reconstructs source using original source bytes
in the new order.

### Why hybrid (not pure property-based):
Emacs `insert` does NOT inherit custom text properties (only
`insert-and-inherit` does). User typing creates nil-property gaps.
Properties are reliable for BLOCK MOVEMENT (text moves intact) but
not for detecting within-node edits.

### Key constraints discovered:
- Line-based extraction breaks when line count changes (positions shift)
- Text properties don't survive `insert`/`replace-match` (nil gaps)
- Text properties DO survive `org-metaup`/`kill-yank` (block moves)
- Tree-sitter source positions are byte offsets; Emacs uses char offsets
  (only matters for multi-byte source; mirror is target-format text)

## E2E testing plan

### Test fixture

A complex GFM document (~80-100 lines) containing every element type
we support. Written to a temp file before each test so
`diff-buffer-with-file` works. Structure:

```markdown
# Project Name

Short intro paragraph with **bold**, *italic*, `inline code`, and ~~strike~~.

## Installation

Install via [npm](https://npmjs.com/package/foo):

` ``bash
npm install foo
` ``

Or build from source:

` ``bash
git clone https://github.com/example/foo
cd foo && make install
` ``

## Configuration

### Step 1: Create credentials

1. Go to https://example.com/console
2. Click "New App"
3. Choose "OAuth"
4. Fill in details

### Step 2: Add permissions

Required scopes:
- `read:data` - Read access
- `write:data` - Write access

### Step 3: Set environment

` ``bash
export APP_ID="your-id"
export APP_SECRET="your-secret"
` ``

Or use a `.env` file:

` ``bash
APP_ID=your-id
APP_SECRET=your-secret
` ``

## Usage

### Basic usage

Run the tool:

` ``bash
foo run
` ``

### Advanced usage

Pass a config file:

` ``bash
foo run --config path/to/config.yaml
` ``

## Architecture

| Component | Purpose | Status |
|-----------|---------|--------|
| Parser | Parse input | Stable |
| Renderer | Generate output | Beta |
| Differ | Compute changes | Alpha |

> Note: The differ component is experimental. Use with caution.

---

## Troubleshooting

### "Missing credentials"
Set APP_ID and APP_SECRET environment variables.

### "Connection failed"
- Check network connectivity
- Verify API endpoint URL
- Try increasing timeout

### "Parse error"
Ensure input is valid JSON. Use `foo validate` to check.

## Resources

- [Documentation](https://docs.example.com)
- [API Reference](https://api.example.com)
- [Issue Tracker](https://github.com/example/foo/issues)

## License

MIT
```

### Test protocol

Every test follows this exact sequence:

1. Write fixture to a temp file
2. Open the file in a markdown-mode buffer
3. `el-prisma-convert` to Org mirror
4. Perform the operation in the mirror
5. `el-prisma-commit`
6. `diff-buffer-with-file` on the source buffer
7. Assert: only the expected lines differ
8. Run structural invariant checks (see below)
9. Revert the source buffer for next test

### Structural invariants

A helper function `el-prisma-e2e--check-invariants` runs after every
commit. It takes the original text, the result text, and a list of
expected-change descriptors. It checks:

1. No content loss: every line from original present in result,
   except lines listed as intentionally changed
2. Blank lines: every `##` and `###` heading preceded by blank line
3. Code fences: count of ``` in original equals count in result
   (unless a code block was intentionally edited)
4. Link preservation: all `[text](url)` patterns from original
   present in result (unless intentionally changed)
5. Table preservation: all `|` rows from original present in result
6. Line count: result line count equals original line count
   (for rearrangements, same count; for edits, same count)
7. No data loss: if mirror was modified but source unchanged, error

### Single-operation tests

Each test does ONE operation, commits, diffs, checks invariants.

#### Group A: In-place edits (no structural change)

| Test | Operation | Search | Replace | Verify |
|------|-----------|--------|---------|--------|
| A1 | Edit paragraph word | "intro paragraph" | "intro section" | 1 line differs |
| A2 | Edit heading | "## Configuration" | "## Config" | 1 line differs |
| A3 | Edit code block body | "npm install foo" | "npm install bar" | 1 line differs |
| A4 | Edit code block lang | first ```bash | ```sh | 1 line differs |
| A5 | Edit list item | "`read:data`" | "`read:all`" | 1 line differs |
| A6 | Edit link URL | "https://npmjs.com/package/foo" | "https://example.com" | 1 line differs |
| A7 | Edit link text | "[npm]" | "[the registry]" | 1 line differs |
| A8 | Edit bold text | "**bold**" | "**strong**" | 1 line differs |
| A9 | Edit inline code | "`inline code`" | "`example`" | 1 line differs |
| A10 | Edit blockquote | "experimental" | "unstable" | 1 line differs |

#### Group B: Structural changes (rearrangement)

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| B1 | org-metaup on *** Step 2 | Step 2 before Step 1, all content present, blank lines preserved | DONE |
| B2 | org-metaup on *** Step 3 | Step 3 before Step 2, all content present | TODO |
| B3 | org-metadown on *** Step 1 | Step 1 after Step 2, all content present | TODO |
| B4 | org-metaup on ** Usage | Usage before Configuration, all sub-sections intact, code blocks intact | DONE |
| B5 | org-metaup on ** Troubleshooting | Troubleshooting before Architecture, table + blockquote + hr intact | DONE |
| B6 | org-metadown on ** Installation | Installation after Configuration | TODO |
| B7 | Insert line in code block | Only that code block changes, rest untouched | TODO |

#### Group C: No-change baseline

| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| C1 | Convert + immediate commit | Source is byte-identical to file | DONE |
| C2 | Convert + type + undo + commit | Source is byte-identical (undo restores original) | TODO |

#### Group D: Multiple operations in one commit

| Test | Operations | Verify | Status |
|------|------------|--------|--------|
| D1 | Edit heading + edit paragraph | Exactly 2 lines differ | TODO |
| D2 | Edit code block + edit list item | Both changes present, everything else intact | TODO |
| D3 | org-metaup Step 2 + edit word in Step 3 | Rearrangement correct AND word changed | DONE |
| D4 | Edit word + org-metaup on different section | Both changes applied correctly | TODO |
| D5 | org-metaup + org-metaup (two rearrangements) | Both moves applied | TODO |

#### Group E: Pre-existing unsaved changes

These test that in-memory changes to the source buffer before
conversion are preserved - unless overwritten by mirror edits.

| Test | Setup | Operation | Verify |
|------|-------|-----------|--------|
| E1 | Add "MARKER" at end of source, don't save | Edit a paragraph in mirror, commit | "MARKER" still at end of result (conversion used text at conversion time, but commit should warn about concurrent modification) |
| E2 | Modify a heading in source, don't save | Edit a different paragraph in mirror, commit | Both changes present (source heading change + mirror paragraph change) |

Note: E-group tests verify the concurrent modification detection.
The current implementation stores `source-tick` at conversion time
and warns if source was modified. For E1/E2 the user confirms the
commit; the expectation is that mirror changes override the
corresponding source regions while non-overlapping source changes
are preserved via the `source-text` snapshot mechanism.

### Cursor position tests

| Test | Source position | Expected mirror position |
|------|----------------|--------------------------|
| F1 | On `## Configuration` | On `** Configuration` line |
| F2 | On `### Step 2` | On `*** Step 2` line |
| F3 | On `## Usage` (after code blocks) | On `** Usage` line (not displaced by code block size change) |
| F4 | On last line `MIT` | Near end of mirror |

### Test file location

`test/el-prisma-e2e-tests.el` - extend the existing file.
The fixture string is defined once as a `defconst` at the top of the
test section. Each test uses the same fixture.

## Execution status

1. Write the strategy (this document) - DONE
2. Implement text-property tagging + property-based reorder detection - DONE
3. Verify properties survive org-metaup - DONE (proven)
4. Build the invariant checker helper - DONE
5. Implement hybrid commit (line-based edits + property reorder) - DONE
6. Fix line-count-changing edits (insertion/deletion) - DONE
7. Write Group C tests (baseline) - DONE (C1)
8. Write Group B tests (rearrangements) - PARTIAL (B1, B4, B5)
9. Write Group D tests (multi-op) - PARTIAL (D3)
10. Write Group F tests (cursor) - PARTIAL (F1, F3)
11. Write remaining tests (A, B2/B3/B6/B7, C2, D1/D2/D4/D5, E1/E2) - TODO
12. Run against real zoom README manually - DONE (verified)
13. Ship only when all tests pass - ONGOING
