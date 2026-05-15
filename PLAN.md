# El Prisma - Architecture and Status

## Current architecture (v1.1)

### Commit pipeline

The commit flow has three paths based on what changed in the mirror:

1. No change: `string=` old vs new mirror -> short-circuit, kill mirror
2. In-place edit (same line count): line-based diff -> per-node extraction -> re-parse/re-render -> patch
3. In-place edit (different line count): line-based diff -> adjusted byte extraction (accounting for length delta) -> filter unchanged nodes -> re-parse/re-render -> patch
4. Rearrangement (node order changed): property-based order detection -> reconstruct source from original node bytes in new order -> patch

### Key components

- `el-prisma-render-with-map`: renders AST to target format, produces render map (node-idx -> mirror byte range)
- `el-prisma-node-idx` text property: tagged on mirror regions during convert, travels with text through org-metaup/down
- `el-prisma--mirror-node-order`: reads property order from mirror buffer
- `el-prisma--find-changed-nodes`: line-based detection for edits (handles both same and different line counts)
- `el-prisma--build-reorder-ops`: reconstructs source in new node order using original source bytes
- `el-prisma--apply-patch-ops`: applies ops with trailing whitespace preservation
- Data loss safeguard: refuses to kill mirror if patch produces unchanged source

### How edits work

1. Text-diff old vs new mirror -> changed line indices
2. Convert to byte range (clamped to available lines)
3. Find overlapping render map entries
4. For same line count: extract per-node using line numbers
5. For different line count: extract using adjusted byte positions, filter nodes whose text didn't actually change
6. Merge adjacent changed nodes, re-parse combined mirror text, render to source format
7. Apply patch ops to source text

### How rearrangement works

1. Read `el-prisma-node-idx` property order from mirror buffer
2. Compare against original order (skipping zero-length nodes)
3. If different: for each node in new order, take its original source bytes
4. Join with `\n\n`, create single replacement op covering full range
5. Apply with trailing whitespace preservation

### Cursor position mapping

Uses render map to build synthetic nodes with mirror byte positions. `el-prisma--map-position` finds containing node by index, computes proportional offset within the node.

## What's done

- [x] Render map (task 1)
- [x] Text diff (task 2)
- [x] Region-to-node mapping (task 3)
- [x] Per-node re-parse (task 4)
- [x] Rewritten commit flow (task 5)
- [x] Dead code removal (task 6)
- [x] Unit tests for text-diff primitives
- [x] E2E tests: in-place edits, rearrangements, baselines, cursor
- [x] Cursor position fix (synthetic mirror-position nodes)
- [x] Blank-line preservation (trailing whitespace pattern)
- [x] Data loss safeguard
- [x] Text-property node tracking for rearrangement
- [x] Line-count-changing edit fix (insertion/deletion)
- [x] Comprehensive test matrix (STRATEGY.md groups B, C, D, F)

## Remaining work

- [ ] Complete test matrix from STRATEGY.md (groups A, B2/B3/B6, C2, D1/D2/D4/D5, E1/E2, F2/F4)
- [ ] Add insertion/deletion E2E test (emoji in code block scenario)
- [ ] Rearrangement cosmetic: ~6 extra blank lines from `\n\n` joining (functional, not correctness issue)
- [ ] JSON/EDN conversion (phase 2)

## Not in scope

- JSON/EDN conversion (phase 2)
- Org parser improvements beyond what's needed for per-node re-parse
