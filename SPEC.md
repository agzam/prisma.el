# El Prisma - Specification

## Vision

A format conversion system for Emacs that creates mirror buffers for editing
content in a preferred format, with lossless round-trip conversion back to the
source. The user's edits must never be lost.

## Core Principles

1. Never lose user edits. If back-conversion would drop data, warn before commit.
2. Untouched regions remain byte-identical in the source after commit.
3. Format-specific constructs with no target equivalent pass through as literal text.
4. Explicit commit/cancel - no live sync.
5. Parsers are pluggable. Tree-sitter where grammars are strong, custom PEG where they aren't.

## Supported Conversion Pairs

| Source   | Target | Direction     | Fidelity                        |
|----------|--------|---------------|---------------------------------|
| Markdown | Org    | Bidirectional | Common subset + passthrough     |
| JSON     | EDN    | Bidirectional | Full (string keys, no keywords) |

Future candidates: YAML, TOML, HTML - not in scope for v1.

---

## Design Decisions

### Why not Pandoc

Pandoc's org<->gfm conversion is lossy and opinionated. It normalizes formatting,
drops metadata, and uses an intermediate AST that doesn't preserve source
positions. Round-tripping through Pandoc produces visibly different output even
when no edits were made. El Prisma exists because Pandoc can't solve the
lossless round-trip problem.

### Why PEG for Org inline (not tree-sitter)

The `emiasims/tree-sitter-org` grammar was evaluated experimentally. Block-level
structure (headings, lists, code blocks, paragraphs) parses adequately. However,
all inline content is flattened to whitespace-split `expr` nodes. Example:

    Input:  "Some *bold* and /italic/ text."
    Parsed: (paragraph (expr "Some") (expr "*bold*") (expr "and")
                       (expr "/italic/") (expr "text."))

The parser cannot distinguish bold (`*bold*`) from plain text, and even splits
Org links (`[[url][text]]`) across multiple `expr` nodes at spaces. This makes
it impossible to build a structural inline AST from tree-sitter-org alone.

By contrast, tree-sitter-markdown-inline correctly identifies `strong_emphasis`,
`emphasis`, `inline_link`, `code_span` etc. as structured nodes with sub-components.

Decision: use tree-sitter for Markdown (both block and inline) and for JSON.
Use a custom PEG parser for Org inline content. Org block structure can use
either tree-sitter-org or PEG - to be decided during implementation based on
whether tree-sitter-org's block parsing is reliable enough.

### Markdown requires two tree-sitter parsers

The `tree-sitter-markdown` grammar is split into two separate parsers:
- `markdown` (block structure): headings, paragraphs, lists, code fences, tables
- `markdown-inline` (inline content): emphasis, links, code spans, images

The block parser produces `(inline)` nodes for paragraph text content but does
not parse emphasis, links, etc. Both parsers must be active in the same buffer
for full structural parsing. The inline parser's nodes overlap with (are children
of) the block parser's `inline` nodes, correlated by byte positions.

### Passthrough eliminates restricted modes

Initially we considered restricting the mirror buffer to prevent users from
entering format-specific constructs (e.g. Org TODO keywords in a
Markdown-originated buffer). The realization: these constructs are just text in
the target format. An Org `SCHEDULED: <2026-05-10 Sat>` line is meaningless to
a Markdown renderer but perfectly valid to include. On conversion back, our
parser recognizes the pattern and reconstructs it.

This means we never need to prevent or warn about any input. Every edit is valid
because unrecognized structural elements become passthrough nodes that round-trip
verbatim by definition. This dramatically simplifies the system.

### EDN parser: custom reader, not PEG

EDN's syntax is regular enough (s-expression based with a few special forms)
that a straightforward recursive descent reader is simpler and clearer than
defining a PEG grammar. The reader only needs to handle the JSON-compatible
subset in v1 (maps, vectors, strings, numbers, booleans, nil - all with string
keys).

### Prerequisites: tree-sitter grammars

Required grammar sources and compilation:

Markdown (block): `https://github.com/tree-sitter-grammars/tree-sitter-markdown`
(NOTE: the old `tree-sitter/tree-sitter-markdown` URL no longer exists)

```sh
# Block grammar
cc -shared -fPIC -O2 \
  -I tree-sitter-markdown/src \
  tree-sitter-markdown/src/parser.c \
  tree-sitter-markdown/src/scanner.c \
  -o libtree-sitter-markdown.dylib

# Inline grammar (same repo, different subdirectory)
cc -shared -fPIC -O2 \
  -I tree-sitter-markdown-inline/src \
  tree-sitter-markdown-inline/src/parser.c \
  tree-sitter-markdown-inline/src/scanner.c \
  -o libtree-sitter-markdown-inline.dylib
```

JSON: typically already available via `treesit-install-language-grammar`.

Compiled libraries go in the tree-sitter load path
(e.g. `~/.emacs.d/.local/cache/tree-sitter/` for Doom,
`~/.emacs.d/tree-sitter/` for vanilla Emacs).

---

## Architecture Overview

```
Source Buffer          Mirror Buffer
(Markdown)              (Org)
    |                     |
    v                     v
 [Parser]             [Parser]
    |                     |
    v                     v
 AST_1 ---- diff ---- AST_2
 (stored)              (on commit)
    |                     |
    |    [Patch Engine]   |
    |         |           |
    v         v           v
 Patched Source Buffer
```

### Components

1. Parser Layer - extracts positioned AST from source text
2. Intermediary Model - unified node types shared across formats
3. Renderer Layer - emits target format text from the model
4. Diff Engine - structural comparison of two ASTs
5. Patch Engine - applies diffs back to source using byte ranges
6. Buffer Manager - mirror buffer lifecycle, commit/cancel

---

## Intermediary Model

Every node carries source position metadata:

```elisp
(:type <symbol>
 :start <integer>     ; byte position in source buffer
 :end <integer>       ; byte position in source buffer
 :source-format <symbol> ; 'markdown, 'org, 'json, 'edn
 :children <list>     ; child nodes
 :props <plist>)      ; node-specific properties
```

### Document nodes (Markdown <-> Org)

| Node Type    | Props                          | Markdown             | Org                        |
|--------------|--------------------------------|----------------------|----------------------------|
| document     |                                | root                 | root                       |
| heading      | :level, :children (inlines)    | `# text`             | `* text`                   |
| paragraph    | :children (inlines)            | text block           | text block                 |
| list         | :ordered                       | `- item` / `1. item` | `- item` / `1. item`       |
| list-item    | :checkbox, :children           | `- [ ] text`         | `- [ ] text`               |
| code-block   | :language, :body               | ````lang ... ````    | `#+begin_src lang ... end` |
| blockquote   | :children                      | `> text`             | (passthrough or #+begin_quote) |
| table        | :rows                          | GFM table            | Org table                  |
| horiz-rule   |                                | `---`                | `-----`                    |
| passthrough  | :text                          | verbatim text        | verbatim text              |

### Inline nodes (Markdown <-> Org)

| Node Type  | Props                   | Markdown         | Org              |
|------------|-------------------------|------------------|------------------|
| text       | :value                  | plain text       | plain text       |
| strong     | :children               | `**text**`       | `*text*`         |
| emphasis   | :children               | `*text*`         | `/text/`         |
| code       | :value                  | `` `text` ``     | `~text~`         |
| verbatim   | :value                  | `` `text` ``     | `=text=`         |
| link       | :url, :children (desc)  | `[text](url)`    | `[[url][text]]`  |
| image      | :url, :alt              | `![alt](url)`    | `[[url]]`        |
| linebreak  |                         | `\` or 2 spaces  | `\\`             |
| strike     | :children               | `~~text~~`       | `+text+`         |
| passthrough| :text                   | verbatim         | verbatim         |

### Data nodes (JSON <-> EDN)

| Node Type | Props             | JSON             | EDN           |
|-----------|-------------------|------------------|---------------|
| map       | :entries          | `{"k": v}`       | `{"k" v}`     |
| array     | :elements         | `[1, 2]`         | `[1 2]`       |
| string    | :value            | `"text"`         | `"text"`      |
| number    | :value            | `42`, `3.14`     | `42`, `3.14`  |
| boolean   | :value            | `true`/`false`   | `true`/`false`|
| null      |                   | `null`           | `nil`         |
| map-entry | :key, :value      | `"k": v`         | `"k" v`       |

---

## Parser Layer

### Tree-sitter parsers

Used for formats with mature grammars:
- Markdown blocks: `tree-sitter-markdown` (block structure)
- Markdown inline: `tree-sitter-markdown-inline` (emphasis, links, code spans)
- JSON: `tree-sitter-json`

Tree-sitter provides byte-accurate source positions on every node.

Required grammars (compiled .dylib/.so):
- `libtree-sitter-markdown`
- `libtree-sitter-markdown-inline`
- `libtree-sitter-json`

### PEG parser engine

For formats where tree-sitter grammars are insufficient (Org inline content)
or unavailable (EDN).

#### Grammar definition format

Grammars defined as s-expressions:

```elisp
'((inline    (+ (/ bold italic code link strike text)))
  (bold      (seq "*" (+ (/ (! "*") inline-char)) "*"))
  (italic    (seq "/" (+ (/ (! "/") inline-char)) "/"))
  (code      (seq "~" (+ (! "~") any) "~"))
  (link      (/ bracket-link plain-link))
  (bracket-link (seq "[[" target "][" description "]]"))
  (target    (+ (! "]]" "[")))
  (description (+ (! "]]")))
  (strike    (seq "+" (+ (/ (! "+") inline-char)) "+"))
  (text      (+ (! markup-start) any)))
```

#### PEG operators

| Operator   | Meaning                    |
|------------|----------------------------|
| `(seq ...)` | Sequence - match all in order |
| `(/ ...)`   | Ordered choice             |
| `(+ e)`     | One or more                |
| `(* e)`     | Zero or more               |
| `(? e)`     | Optional                   |
| `(! e)`     | Negative lookahead         |
| `(& e)`     | Positive lookahead         |
| `any`       | Any single character       |
| `"literal"` | Literal string match       |
| `[a-z]`     | Character class            |

#### Output

PEG parser produces the same intermediary model nodes as tree-sitter parsers,
with :start and :end positions. The parser layer presents a uniform interface
regardless of which engine parsed the text.

#### Performance

Packrat memoization (hash-table of (rule, position) -> result) gives O(n) time.
For typical buffer sizes (< 10k lines), pure Elisp performance is acceptable.
Parser is only invoked twice per session: once on convert, once on commit.

### EDN parser

Custom reader in Elisp (EDN is simple enough to not need PEG):
- Maps: `{...}`
- Vectors: `[...]`
- Strings: `"..."`
- Numbers: integer and float
- Booleans: `true`, `false`
- Nil: `nil`
- No keywords, symbols, sets, or tagged literals in v1 (string keys only)

---

## Renderer Layer

One renderer per target format. Each renderer walks the intermediary AST and
emits text.

### Rendering rules

- Convertible nodes: render in target format syntax
- Passthrough nodes: emit :text verbatim, no transformation
- Unknown node types: treat as passthrough (safety net)

### Indentation and whitespace

Renderers emit canonical formatting for new/modified nodes:
- Headings: one blank line before (except at document start)
- Paragraphs: one blank line between
- List items: consistent indentation
- Code blocks: no trailing whitespace in body

For unchanged nodes (on commit path), original bytes are used instead
of renderer output - so formatting preferences are preserved.

---

## Diff Engine

Structural diff on the intermediary model. Compares AST_1 (from initial parse)
with AST_2 (from parsing the edited mirror buffer).

### Algorithm

Document trees are shallow (typically 3-5 levels), so a simple recursive
approach suffices:

1. Align top-level blocks by (type, position-hint, content-hash)
2. For matched blocks: recursively diff children
3. Detect: unchanged, modified, inserted, deleted nodes

### Node matching strategy

Nodes are matched by a composite key:
- Same type + same content hash -> unchanged (no diffing of children needed)
- Same type + similar position -> potentially modified (diff children)
- No match -> inserted or deleted

Content hash: SHA-1 of the rendered text of the node in the target format.
Fast equality check before expensive structural comparison.

### Diff result

```elisp
(:unchanged <list of (ast1-node . ast2-node) pairs>
 :modified  <list of (ast1-node . ast2-node) pairs>  ; same node, different content
 :inserted  <list of ast2-nodes>                      ; new in mirror
 :deleted   <list of ast1-nodes>)                     ; removed from mirror
```

---

## Patch Engine

Takes a diff result and applies it to the source buffer.

### For unchanged nodes

No action. Original source bytes remain untouched.

### For modified nodes

1. Look up ast1-node's :start and :end in source buffer
2. Render ast2-node to source format
3. Replace bytes [start, end) with rendered text

### For inserted nodes

1. Determine insertion point from surrounding unchanged/modified nodes
2. Render the new node to source format
3. Insert at the computed position

### For deleted nodes

1. Look up the node's :start and :end in source buffer
2. Delete bytes [start, end)

### Offset management

Patches applied in reverse source-position order (bottom of buffer first)
so earlier byte ranges remain valid. Alternatively, maintain a cumulative
offset accumulator.

---

## Buffer Manager

### Convert flow

1. User invokes `el-prisma-convert` in source buffer
2. Detect source format (from major mode or explicit argument)
3. Look up target format from conversion map
4. Parse source -> AST_1
5. Render AST_1 -> target format text
6. Create mirror buffer named `*prisma:<source-name>:<target-format>*`
7. Insert rendered text, set appropriate major mode
8. Store as buffer-local in mirror:
   - `el-prisma--source-buffer`: reference to source buffer
   - `el-prisma--source-ast`: AST_1
   - `el-prisma--source-format`: source format symbol
   - `el-prisma--target-format`: target format symbol
9. Enable `el-prisma-mirror-mode` (minor mode with commit/cancel bindings)
10. Display mirror buffer (same window or split, configurable)

### Commit flow

1. User invokes `el-prisma-commit` in mirror buffer
2. Parse mirror content -> AST_2
3. Diff AST_1 vs AST_2
4. If only unchanged nodes: message "No changes", done
5. Optional round-trip validation:
   a. Render AST_2 -> source format -> re-parse -> AST_3
   b. Diff AST_2 vs AST_3
   c. If differences: warn user with details, ask to proceed or abort
6. Apply patches to source buffer via Patch Engine
7. Kill mirror buffer

### Cancel flow

1. User invokes `el-prisma-cancel` in mirror buffer
2. If mirror buffer is modified, ask for confirmation
3. Kill mirror buffer, no changes to source

### Region conversion

When invoked with an active region:
- Parse only the selected region
- Mirror buffer contains only that region's content
- On commit, patch only that region in source buffer
- Byte offsets are relative to region start

---

## Round-trip Validation

An optional safety check on commit. Verifies that the back-converted content
can be re-converted to the mirror format without loss.

```
Mirror (Org) -> parse -> AST_2 -> render to MD -> parse -> AST_3 -> render to Org
Compare: mirror text vs re-rendered Org text
```

If they differ, the user sees a diff showing what would change. They can:
- Commit anyway (accept the difference)
- Return to mirror buffer and adjust
- Cancel entirely

This is a safety net. With the passthrough mechanism, it should rarely trigger.

Controlled by: `el-prisma-validate-on-commit` (default: t)

---

## Interactive Commands

| Command              | Context       | Description                            |
|----------------------|---------------|----------------------------------------|
| `el-prisma-convert`  | source buffer | Open mirror buffer in target format    |
| `el-prisma-commit`   | mirror buffer | Convert back and patch source          |
| `el-prisma-cancel`   | mirror buffer | Discard mirror, no changes to source   |
| `el-prisma-diff`     | mirror buffer | Preview what would change in source    |

## Public API

```elisp
;; Parse text in a given format, return intermediary AST
(el-prisma-parse FORMAT TEXT &optional START)

;; Render AST to target format, return string
(el-prisma-render FORMAT AST)

;; Diff two ASTs, return diff structure
(el-prisma-diff-ast AST-1 AST-2)

;; Apply a diff to source text, return patched string
(el-prisma-patch SOURCE-TEXT DIFF SOURCE-FORMAT)

;; Register a new conversion pair
(el-prisma-register-pair SOURCE-FORMAT TARGET-FORMAT &key parser renderer)
```

## Customization

```elisp
;; Alist of (source-format . default-target-format)
(defcustom el-prisma-default-targets
  '((markdown-mode . org)
    (gfm-mode . org)
    (json-mode . edn)
    (json-ts-mode . edn)
    (js-json-mode . edn))
  ...)

;; Whether to run round-trip validation on commit
(defcustom el-prisma-validate-on-commit t ...)

;; How to display the mirror buffer
(defcustom el-prisma-display-action
  '(display-buffer-pop-up-window) ...)
```

---

## Mirror Mode

`el-prisma-mirror-mode` is a minor mode activated in mirror buffers.

Provides:
- Keymap with commit/cancel/diff bindings
- Mode-line indicator showing source buffer name and format
- Buffer-local variables linking back to source
- Kill-buffer hook that warns about uncommitted changes

Default keymap (prefix `C-c C-p`):
- `C-c C-p C-c` or `C-c C-c`: commit
- `C-c C-p C-k` or `C-c C-k`: cancel
- `C-c C-p C-d`: diff preview

The mirror buffer's major mode matches the target format (org-mode, clojure-mode,
etc.) so the user gets full editing support - fontification, indentation,
structural navigation.

---

## Edge Cases and Guarantees

### Passthrough handling

Any text in the mirror buffer that doesn't parse as a recognized structural
element is treated as passthrough. This includes:
- Org planning lines (SCHEDULED, DEADLINE) in a Markdown-originated buffer
- TODO keywords and tags on headings
- Property drawers
- Arbitrary text the user types that isn't markup

Passthrough text round-trips verbatim by definition.

### Emphasis ambiguity

Markdown and Org have different emphasis boundary rules. El Prisma's PEG grammar
for Org inline content uses Markdown-compatible rules when the source was
Markdown. This means some valid Org emphasis patterns won't be recognized if
they wouldn't work in Markdown - this is intentional and prevents ambiguous
round-trips.

### Links

| Direction  | From                        | To                         |
|------------|-----------------------------|----------------------------|
| MD -> Org  | `[text](url)`               | `[[url][text]]`            |
| MD -> Org  | `[text](url "title")`       | `[[url][text]]` (title passthrough) |
| Org -> MD  | `[[url][text]]`             | `[text](url)`              |
| MD -> Org  | `![alt](url)`               | `[[url]]` + passthrough alt|
| either     | Autolinks, reference links  | Passthrough                |

Reference-style links (`[text][ref]` ... `[ref]: url`) are kept as passthrough
because they have document-level semantics (the reference definition may be
elsewhere in the file).

### Code blocks

Fenced code blocks (Markdown) <-> src blocks (Org) convert structurally.
The body content is never modified - only the delimiters change.

Indented code blocks (Markdown) are passthrough (ambiguous semantics).

### Tables

GFM tables <-> Org tables convert structurally. Alignment indicators
(`:---`, `:---:`, `---:`) map to Org column groups where possible,
otherwise passthrough.

### JSON <-> EDN specifics

- All JSON types have direct EDN equivalents
- EDN string keys (not keywords) for maps - lossless round-trip
- JSON number precision is preserved (no float <-> int coercion)
- JSON escape sequences are normalized on parse and re-emitted correctly
- Trailing commas in JSON: tolerated on parse, not emitted on render
- EDN commas are optional whitespace: tolerated on parse
- Pretty-printing: the mirror buffer (EDN) is formatted for readability;
  on commit, the source (JSON) preserves its original formatting for
  unchanged entries

### Empty edits

If the user opens a mirror buffer and commits without changes, the source
buffer is not touched. The diff will show all nodes as unchanged.

### Concurrent modification

If the source buffer is modified while a mirror buffer is open, commit will
warn that the source has changed since conversion. The user can:
- Cancel and re-convert (picking up source changes)
- Force commit (overwrites source changes in affected regions)

Detected via source buffer's `buffer-modified-tick` stored at convert time.

---

## File Organization

```
prisma.el/
  el-prisma.el           ; main entry point, buffer manager, commands
  el-prisma-model.el     ; intermediary AST types and constructors
  el-prisma-peg.el       ; PEG parser engine
  el-prisma-ts.el        ; tree-sitter parser integration
  el-prisma-diff.el      ; AST diff algorithm
  el-prisma-patch.el     ; patch engine
  el-prisma-md.el        ; Markdown parser + renderer
  el-prisma-org.el       ; Org parser + renderer
  el-prisma-json.el      ; JSON parser + renderer
  el-prisma-edn.el       ; EDN parser + renderer
  test/
    el-prisma-tests.el         ; unit tests
    el-prisma-peg-tests.el     ; PEG engine tests
    el-prisma-md-tests.el      ; Markdown round-trip tests
    el-prisma-org-tests.el     ; Org round-trip tests
    el-prisma-json-tests.el    ; JSON/EDN round-trip tests
    el-prisma-diff-tests.el    ; diff algorithm tests
    el-prisma-patch-tests.el   ; patch engine tests
```

---

## Implementation Order

### Phase 1: Foundation
- [x] Intermediary model types and constructors
- [x] PEG parser engine with position tracking
- [x] AST diff algorithm

### Phase 2: JSON <-> EDN
- [ ] JSON parser (tree-sitter)
- [ ] EDN parser (custom reader)
- [ ] JSON renderer
- [ ] EDN renderer
- [ ] Round-trip tests

### Phase 3: Markdown <-> Org
- [x] Markdown parser (tree-sitter block + inline)
- [x] Org inline parser (hand-written with emphasis boundary rules)
- [x] Org block parser (regex-based)
- [x] Markdown renderer
- [x] Org renderer
- [x] Round-trip tests with passthrough verification

### Phase 4: Buffer Management
- [x] Mirror buffer creation and lifecycle
- [x] el-prisma-mirror-mode
- [x] Commit flow with patch engine
- [x] Cancel flow
- [x] Round-trip validation (optional, off by default)
- [ ] Region conversion support

### Phase 5: Polish
- [x] Concurrent modification detection
- [x] Diff preview command
- [x] Customization options
- [x] Header-line with keybinding hints
- [x] AST-based cursor position mapping
- [x] Vertical scroll position preservation
- [ ] Documentation
