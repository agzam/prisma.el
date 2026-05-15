# Prisma - Architecture and Status

## Current architecture (v2.0 - unified commit)

### Commit pipeline

The commit flow uses a single unified path:

1. No change: `string=` old vs new mirror -> short-circuit, kill mirror
2. Re-parse entire edited mirror -> new AST
3. Match new AST nodes to original nodes via `prisma-node-idx` text properties
4. For each new node: if matched + unchanged mirror text -> use original source bytes; else re-render
5. Assemble replacement and write to source

### Key components

- `prisma-render-with-map`: renders AST to target format, produces render map (node-idx -> mirror byte range)
- `prisma-node-idx` text property: tagged on mirror regions during convert, travels with text through kill/yank and org-metaup/down
- `prisma--source-texts` / `prisma--mirror-texts`: per-node original text vectors stored at convert time (the "complement")
- `prisma--scan-property-intervals`: walks mirror buffer collecting property segments
- `prisma--match-nodes`: matches re-parsed AST nodes to originals via property hints, resolves conflicts (split detection)
- `prisma--build-unified-replacement`: assembles result - original bytes for unchanged, re-rendered for changed/new
- Data loss safeguard: refuses to kill mirror if patch produces unchanged source

### FIXED: whitespace normalization

`prisma--build-unified-replacement` used to reassemble the entire document by stripping trailing newlines and joining with `\n\n`, normalizing all inter-block whitespace. Fixed via patch-in-place for same/near-same-structure edits and improved reassembly with original whitespace preservation for the fallback path. Single word edit in 36KB file now produces exactly 1 line diff.

## What's done

- [x] Unified commit pipeline (re-parse + property-match)
- [x] Node insertion/deletion support
- [x] Reorder support (via text property travel)
- [x] Combined reorder + edit
- [x] Boundary-crossing edits (merge/split nodes)
- [x] Data loss safeguard
- [x] Comprehensive isolation tests (41 specs)
- [x] Fixture tests (71 specs)
- [x] Unit tests for commit primitives
- [x] Region conversion support
- [x] Cursor position mapping

## Remaining work

- [x] FIX: patch-in-place for same-structure edits (whitespace normalization bug)
- [x] FIX: buttercup tests - not silently swallowing; `make test` simply didn't load isolation tests. `make test-e2e` runs them and they pass.
- [x] Improve structural-change reassembly to preserve unchanged consecutive runs
- [x] Test with real-world large markdown files (36KB, 1 diff for 1-word edit)
- [ ] Complete test matrix from STRATEGY.md
- [ ] Documentation
