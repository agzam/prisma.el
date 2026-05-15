# Prisma - Specification

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
when no edits were made. Prisma exists because Pandoc can't solve the
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
    v                     |
 [Parser]                 |
    |                     |
    v                     v
 AST_1 --- [Renderer] --> mirror text (stored)
 (stored)                 |
                     user edits
                          |
                          v
              text diff (stored mirror vs edited)
                          |
                          v
              changed regions mapped to AST_1 nodes
                          |
                          v
              re-parse changed regions in target format
                          |
                          v
              render changed nodes to source format
                          |
                          v
              patch source at original byte ranges
```

The key insight: we never parse the entire mirror buffer with a different
parser. We compare the mirror against itself (before vs after editing) to
find what changed, then map those changes back to source AST nodes.

### Components

1. Parser Layer - extracts positioned AST from source text
2. Intermediary Model - unified node types shared across formats
3. Renderer Layer - emits target format text with a render map (source node -> mirror byte range)
4. Text Diff - compares original mirror text vs edited mirror text
5. Patch Engine - applies changes back to source using byte ranges from render map
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

### Data nodes (JSON <-> EDN) - Phase 2, not yet implemented

Reserved for future JSON/EDN conversion support.

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

## Change Detection

Instead of parsing the mirror buffer with a second parser and diffing two
ASTs (which fails because different parsers produce structurally different
ASTs), we compare the mirror text against itself.

### Render map

During the initial render (source AST -> mirror text), the renderer records
a render map: a list of `(source-node-index mirror-start mirror-end)` entries.
This maps each top-level source AST node to its byte range in the rendered
mirror text. Stored as buffer-local in the mirror buffer.

### Finding changes

On commit:
1. Text-diff the stored original mirror text against the current mirror content
2. Each changed byte range in the mirror maps (via render map) to one or more
   source AST nodes
3. For each affected source node: extract the corresponding region from the
   edited mirror text, parse it in the target format, render to source format

This approach:
- Never compares two different parsers' outputs
- Only parses changed regions, not the entire mirror
- Is O(changed-regions) not O(document-size)
- Handles any document regardless of parser disagreements

### Result

A list of patch operations: `(source-start source-end replacement-text)`.
Unchanged source nodes produce no operations.

---

## Patch Engine

Takes a list of patch operations and applies them to the source buffer.

Patches applied in reverse source-position order (bottom of buffer first)
so earlier byte ranges remain valid. Each operation replaces
bytes [start, end) with new text. Trailing newlines from the original
region are preserved if the replacement doesn't include one.

---

## Buffer Manager

### Convert flow

1. User invokes `prisma-convert` in source buffer
2. Detect source format (from major mode or explicit argument)
3. Look up target format from conversion map
4. Parse source -> AST
5. Render AST -> target format text + render map (node-index -> mirror byte range)
6. Create mirror buffer named `*prisma:<source-name>:<target-format>*`
7. Insert rendered text, set appropriate major mode
8. Store as buffer-local in mirror:
   - `prisma--source-buffer`: reference to source buffer
   - `prisma--source-ast`: AST
   - `prisma--source-format`: source format symbol
   - `prisma--target-format`: target format symbol
   - `prisma--mirror-text`: original rendered mirror text (for diffing on commit)
   - `prisma--render-map`: list of (node-index mirror-start mirror-end)
9. Enable `prisma-mirror-mode` (minor mode with commit/cancel bindings)
10. Switch to mirror buffer in same window, preserve scroll position

### Commit flow

1. User invokes `prisma-commit` in mirror buffer
2. Text-diff stored original mirror text vs current mirror content
3. If no changes: message "No changes", done
4. Map changed mirror regions to source AST nodes via render map
5. For each affected node: extract edited mirror text, parse in target
   format, render to source format
6. Apply patches to source buffer via Patch Engine
7. Kill mirror buffer, switch to source in same window

### Cancel flow

1. User invokes `prisma-cancel` in mirror buffer
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

Removed. The text-diff approach (comparing mirror against itself) eliminates
the class of problems that validation was designed to catch. Since we never
re-parse the entire mirror with a different parser, there are no structural
disagreements to validate against.

---

## Interactive Commands

| Command              | Context       | Description                            |
|----------------------|---------------|----------------------------------------|
| `prisma-convert`  | source buffer | Open mirror buffer in target format    |
| `prisma-commit`   | mirror buffer | Convert back and patch source          |
| `prisma-cancel`   | mirror buffer | Discard mirror, no changes to source   |
| `prisma-diff`     | mirror buffer | Preview what would change in source    |

## Public API

```elisp
;; Parse text in a given format, return intermediary AST
(prisma-parse FORMAT TEXT &optional START)

;; Render AST to target format, return string
(prisma-render FORMAT AST)

;; Diff two ASTs, return diff structure
(prisma-diff-ast AST-1 AST-2)

;; Apply a diff to source text, return patched string
(prisma-patch SOURCE-TEXT DIFF RENDER-FN)
```

## Customization

```elisp
;; Alist of (source-format . default-target-format)
(defcustom prisma-default-targets
  '((markdown-mode . org)
    (gfm-mode . org))
  ...)
```

---

## Mirror Mode

`prisma-mirror-mode` is a minor mode activated in mirror buffers.

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

Markdown and Org have different emphasis boundary rules. Prisma's hand-written
Org inline parser follows Org emphasis rules (pre/post-conditions on delimiters).
Some edge cases at emphasis boundaries may not round-trip perfectly - this is
acceptable as the common cases work correctly.

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
  prisma.el           ; main entry point, buffer manager, commands
  prisma-model.el     ; intermediary AST types and constructors
  prisma-peg.el       ; PEG parser engine
  prisma-ts.el        ; tree-sitter parser integration
  prisma-diff.el      ; AST diff algorithm
  prisma-patch.el     ; patch engine
  prisma-md.el        ; Markdown parser + renderer
  prisma-org.el       ; Org parser + renderer
  prisma-json.el      ; JSON parser + renderer
  prisma-edn.el       ; EDN parser + renderer
  test/
    prisma-tests.el         ; unit tests
    prisma-peg-tests.el     ; PEG engine tests
    prisma-md-tests.el      ; Markdown round-trip tests
    prisma-org-tests.el     ; Org round-trip tests
    prisma-json-tests.el    ; JSON/EDN round-trip tests
    prisma-diff-tests.el    ; diff algorithm tests
    prisma-patch-tests.el   ; patch engine tests
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
- [x] prisma-mirror-mode
- [x] Commit flow with patch engine
- [x] Cancel flow
- [x] Region conversion support

### Phase 5: Polish
- [x] Concurrent modification detection
- [x] Diff preview command
- [x] Customization options
- [x] Header-line with keybinding hints
- [x] AST-based cursor position mapping
- [x] Vertical scroll position preservation
- [ ] Documentation
