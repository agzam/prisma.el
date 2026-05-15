# Testing and architecture strategy

## The problem

The current commit pipeline uses line-based extraction: it compares
old and new mirror text line-by-line, finds which lines changed, maps
those line numbers to render map entries, then extracts new content
using OLD mirror line numbers from the NEW mirror.

This works for in-place edits (changing a word within a paragraph)
because line numbers stay stable. It fails catastrophically for
rearrangements (org-metaup/down, cut/paste of blocks) because the
old line numbers point at completely different content in the new mirror.

Result: garbled output, lost content, destroyed code blocks.

## Root cause

`el-prisma--find-changed-nodes` is the broken function. It does:

1. Text-diff old vs new mirror -> changed line indices
2. Convert line indices to byte range
3. For each render map entry overlapping that range, extract text
   from NEW mirror using OLD mirror line numbers

Step 3 is the flaw. When blocks move, old line N contains section A
but new line N contains section B. Wrong content gets assigned to
wrong source nodes.

## The fix: text-property-based node tracking

Tag each mirror region with an `el-prisma-node-idx` text property
during `el-prisma-convert`. Emacs text properties travel with the
text through:
- Kill/yank (cut/paste)
- org-metaup/org-metadown (proven via test)
- In-place edits (editing within a propertied region preserves it)
- org-promote/demote

On commit, scan the mirror buffer for property-tagged regions,
compare each region's current text against its original rendered text.
No line numbers involved. The mapping is always correct regardless of
how the text was rearranged.

### Implementation

Two changes to `el-prisma.el`:

1. In `el-prisma-convert`, after inserting rendered text and BEFORE
   activating the target major mode, apply `el-prisma-node-idx`
   properties from the render map.

2. New function `el-prisma--find-changed-nodes-by-props` replaces
   `el-prisma--find-changed-nodes` in the commit path. It:
   - Builds a hash of idx -> original-text from old-mirror + render-map
   - Scans mirror buffer for each idx's current text
   - Returns (SOURCE-NODE CURRENT-TEXT) for nodes where text changed

The old line-based function stays for potential non-interactive use
but is no longer called from commit.

### Edge cases for property-based approach

- User adds text between nodes: inherits adjacent node's property.
  Detected as change to that node. Re-parsed with the extra content.
  Acceptable - the node's region expanded.

- User deletes entire node: property disappears with the text.
  The idx is absent from the scan. Must detect missing indices and
  treat as deletion. Not currently needed (org-metaup doesn't delete
  nodes) but should be handled for robustness.

- org-mode fontification: does NOT strip custom properties. Confirmed
  by test. Only adds face/fontification properties.

- org-metaup/down swaps separator blank lines: the blank lines between
  nodes may not carry properties (they're in the gap between render map
  entries). After the swap, the separator text changes. This is fine
  because we only track node content, not separators. The
  `merge-adjacent-nodes` and `apply-patch-ops` handle inter-node
  spacing from the source side.

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

| Test | Operation | Verify |
|------|-----------|--------|
| B1 | org-metaup on *** Step 2 | Step 2 before Step 1, all content present, blank lines preserved |
| B2 | org-metaup on *** Step 3 | Step 3 before Step 2, all content present |
| B3 | org-metadown on *** Step 1 | Step 1 after Step 2, all content present |
| B4 | org-metaup on ** Usage | Usage before Configuration, all sub-sections intact, code blocks intact |
| B5 | org-metaup on ** Troubleshooting | Troubleshooting before Architecture, table + blockquote + hr intact |
| B6 | org-metadown on ** Installation | Installation after Configuration |

#### Group C: No-change baseline

| Test | Operation | Verify |
|------|-----------|--------|
| C1 | Convert + immediate commit | Source is byte-identical to file |
| C2 | Convert + type + undo + commit | Source is byte-identical (undo restores original) |

#### Group D: Multiple operations in one commit

| Test | Operations | Verify |
|------|------------|--------|
| D1 | Edit heading + edit paragraph | Exactly 2 lines differ |
| D2 | Edit code block + edit list item | Both changes present, everything else intact |
| D3 | org-metaup Step 2 + edit word in Step 3 | Rearrangement correct AND word changed |
| D4 | Edit word + org-metaup on different section | Both changes applied correctly |
| D5 | org-metaup + org-metaup (two rearrangements) | Both moves applied |

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

## Execution order

1. Write the strategy (this document) - DONE
2. Implement text-property tagging + new find-changed-nodes-by-props
3. Verify properties survive org-metaup in the real commit flow
4. Build the invariant checker helper
5. Write Group C tests first (baseline - no changes)
6. Write Group A tests (in-place edits)
7. Write Group B tests (rearrangements) - these will fail until fix lands
8. Write Group D tests (multiple operations)
9. Write Group E tests (pre-existing changes)
10. Write Group F tests (cursor position)
11. Run against real zoom README manually
12. Ship only when all tests pass
