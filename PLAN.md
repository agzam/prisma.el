# v1.1 Plan: Text-diff commit architecture

## Problem

The current commit flow parses the entire mirror buffer with a second parser
(e.g., Org parser for an Org mirror), then AST-diffs the result against the
source AST (from the MD parser). This fails because different parsers produce
structurally different ASTs - different node counts, different boundaries,
different handling of whitespace and tables. A single-character edit can cause
cascading mismatches across the entire document.

## Solution

Compare the mirror text against itself (before vs after editing). Map changed
regions back to source AST nodes via a render map built during initial conversion.

## Tasks

### 1. Render map

Modify renderers (`el-prisma-org--render-node`, `el-prisma-md--render-node`)
to produce a render map alongside the rendered text. The render map is a list:

```elisp
((0 source-node-0 0 125)      ; node-index, source-node, mirror-start, mirror-end
 (1 source-node-1 127 340)
 ...)
```

Each entry records which source AST node produced which byte range in the
mirror text. The separator text between blocks (`\n\n`) belongs to the
preceding entry's range.

Implementation: a new function `el-prisma-render-with-map` that wraps the
existing renderer, tracking positions as it concatenates output. The existing
`el-prisma-render` remains unchanged for backward compatibility.

Store the render map as `el-prisma--render-map` buffer-local in the mirror.
Store the original mirror text as `el-prisma--mirror-text`.

### 2. Text diff

A function `el-prisma--text-diff-regions` that takes two strings (original
and edited mirror text) and returns a list of changed byte ranges:

```elisp
((start1 . end1) (start2 . end2) ...)
```

Implementation options (in order of preference):
- Use Emacs's built-in `compare-buffer-substrings` on temp buffers
- Line-by-line comparison with `split-string`, accumulate changed line ranges
- Call out to `diff` command and parse output

Line-by-line is simplest and sufficient. Changed lines map to byte ranges
via cumulative line lengths.

### 3. Region-to-node mapping

A function `el-prisma--changed-nodes` that takes changed mirror byte ranges
and the render map, returns the list of affected source AST nodes (with their
source byte ranges and the corresponding edited mirror text).

For each changed byte range, find all render map entries that overlap with it.
Those are the affected source nodes. Extract the corresponding region from
the edited mirror text for each.

### 4. Per-node re-parse and render

For each affected source node:
1. Extract the edited mirror text for that node's region
2. Parse it in the target format (e.g., parse the Org snippet)
3. Render the result to the source format (e.g., render to Markdown)
4. This is the replacement text for the source byte range

This only parses small regions, not the full document.

### 5. Rewrite commit flow

Replace the current `el-prisma-commit`:

```
Current:  parse entire mirror -> AST diff -> patch
New:      text diff mirror -> find changed nodes -> per-node re-parse -> patch
```

The patch engine's `el-prisma-patch--apply-ops` remains the same.

### 6. Remove dead code

- Remove `el-prisma-diff-ast` from the commit path (keep for potential future use)
- Remove `el-prisma--validate-round-trip` (no longer needed)
- Remove `el-prisma-validate-on-commit` defcustom

### 7. Update tests

- Add render map tests: verify map positions match actual rendered text
- Add text diff tests: verify changed regions detected correctly
- Add region-to-node mapping tests
- Update all E2E tests to use the new commit flow
- Add E2E test with the real problematic file (paths with `/`, tables, etc.)
- Keep existing parser/renderer unit tests unchanged

### 8. Edge cases to handle

- User adds new content between existing blocks: the added region falls
  between two render map entries. Treat as an insertion after the preceding
  source node.
- User deletes an entire block: the render map entry's region is now empty
  in the edited text. Treat as deletion of that source node.
- User edits across block boundaries (merges two paragraphs, splits one):
  multiple render map entries affected. Re-parse the combined region as
  a single chunk and produce replacement for all affected source byte ranges.
- Empty edits (no changes): short-circuit, no patching.

## Execution order

1 -> 2 -> 3 -> 4 -> 5 -> 7 -> 6

Build the new pipeline first (1-5), verify with tests (7), then clean up (6).
Each step is independently testable.

## Known issue: blank lines lost during block rearrangement

When using org-move-subtree-up/down to rearrange blocks in the mirror,
the commit loses blank lines between blocks. Root cause:
`el-prisma--merge-adjacent-nodes` joins the mirror text of adjacent
changed nodes with `\n\n`, but the MD renderer's output for the merged
block may not produce the same inter-block spacing as the original source.

The fix needs to happen in how merged ops handle the source byte range.
Currently the merged group covers `[first-node-start, last-node-end)` but
the inter-node gaps (blank lines in source) between those nodes are included
in that range. The replacement text must also include those gaps.

Reproduction: open a markdown file with `### Step 1` / `### Step 2` sections,
convert to Org, `org-move-subtree-up` on Step 2, commit. The blank line before
Step 1 (now second) is missing.

## Not in scope

- JSON/EDN conversion (phase 2, unchanged)
- Region conversion (deferred)
- Org parser improvements beyond what's needed for per-node re-parse
