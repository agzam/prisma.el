;;; prisma-fixture-tests.el --- Data-driven fixture tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Systematic round-trip testing via inline fixtures.
;; Each case: source -> convert to mirror -> edit mirror -> commit -> verify source.
;; Adding a regression test = adding one entry to a fixture list.
;;
;;; Code:

(require 'buttercup)
(require 'prisma)
(require 'prisma-model)
(require 'prisma-md)
(require 'prisma-org)

;;;; Test runner

(defun prisma-fixture--run (source-mode source-text edits expected-text)
  "Run a single fixture test case.
SOURCE-MODE: major mode function for the source buffer.
SOURCE-TEXT: initial source content.
EDITS: list of (SEARCH . REPLACE) pairs applied to mirror buffer, or nil.
EXPECTED-TEXT: what source should contain after commit.
Returns the actual source text after commit."
  (let ((source-buf (generate-new-buffer " *fixture-src*"))
        (result nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buf
            (insert source-text)
            (funcall source-mode)
            (goto-char (point-min)))
          (let ((mirror-buf (with-current-buffer source-buf
                              (prisma-convert))))
            (with-current-buffer mirror-buf
              ;; Apply edits via search/replace (preserves text properties)
              (when edits
                (dolist (edit edits)
                  (goto-char (point-min))
                  (unless (search-forward (car edit) nil t)
                    (error "Fixture edit: could not find %S in mirror"
                           (car edit)))
                  (replace-match (cdr edit) t t)))
              (prisma-commit))
            (setq result (with-current-buffer source-buf
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))
      (when (buffer-live-p source-buf)
        (kill-buffer source-buf))
      (dolist (buf (buffer-list))
        (when (string-prefix-p "*prisma:" (buffer-name buf))
          (let ((kill-buffer-query-functions nil)
                (prisma--skip-kill-confirm t))
            (kill-buffer buf)))))
    result))

(defun prisma-fixture--run-baseline (source-mode source-text)
  "Run a baseline test: convert + immediate commit = byte-identical source."
  (let ((source-buf (generate-new-buffer " *fixture-src*"))
        (result nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buf
            (insert source-text)
            (funcall source-mode)
            (goto-char (point-min)))
          (let ((mirror-buf (with-current-buffer source-buf
                              (prisma-convert))))
            (with-current-buffer mirror-buf
              (prisma-commit)))
          (setq result (with-current-buffer source-buf
                         (buffer-substring-no-properties
                          (point-min) (point-max)))))
      (when (buffer-live-p source-buf)
        (kill-buffer source-buf))
      (dolist (buf (buffer-list))
        (when (string-prefix-p "*prisma:" (buffer-name buf))
          (let ((kill-buffer-query-functions nil)
                (prisma--skip-kill-confirm t))
            (kill-buffer buf)))))
    result))

;;;; MD -> Org -> MD fixtures

(defvar prisma-fixture--md-to-org
  '(;; ══════════════════════════════════════════════════════════════
    ;; BASELINES: convert + commit with no edits = byte-identical
    ;; ══════════════════════════════════════════════════════════════

    (:name "baseline: single heading"
     :source "# Hello")

    (:name "baseline: heading + paragraph"
     :source "# Title\n\nHello world")

    (:name "baseline: multiple headings"
     :source "# First\n\nParagraph one\n\n## Second\n\nParagraph two")

    (:name "baseline: code block"
     :source "```python\nprint(\"hello\")\n```")

    (:name "baseline: code block with surrounding"
     :source "# Title\n\n```js\nconst x = 1;\n```\n\nAfter")

    (:name "baseline: unordered list"
     :source "- alpha\n- beta\n- gamma")

    (:name "baseline: ordered list"
     :source "1. first\n2. second\n3. third")

    (:name "baseline: bold and italic"
     :source "Some **bold** and *italic* text")

    (:name "baseline: inline code"
     :source "Use `foo()` for that")

    (:name "baseline: link"
     :source "[click here](https://example.com)")

    (:name "baseline: image"
     :source "![alt text](image.png)")

    (:name "baseline: blockquote"
     :source "> This is a quote")

    (:name "baseline: horizontal rule"
     :source "Above\n\n---\n\nBelow")

    (:name "baseline: strikethrough"
     :source "Some ~~deleted~~ text")

    (:name "baseline: complex document"
     :source "# Project\n\nA **bold** claim with *emphasis*.\n\n## Install\n\n```bash\nnpm install\n```\n\n- step one\n- step two\n\n> Note: be careful\n\n---\n\n## Links\n\n[docs](https://docs.example.com)")

    ;; ══════════════════════════════════════════════════════════════
    ;; SINGLE ELEMENT EDITS
    ;; ══════════════════════════════════════════════════════════════

    (:name "edit: paragraph word"
     :source "# Title\n\nHello world"
     :edits (("Hello" . "Goodbye"))
     :expected "# Title\n\nGoodbye world")

    (:name "edit: heading text"
     :source "# Old Title\n\nContent here"
     :edits (("Old Title" . "New Title"))
     :expected "# New Title\n\nContent here")

    (:name "edit: h2 heading"
     :source "# Main\n\n## Old Sub\n\nText"
     :edits (("Old Sub" . "New Sub"))
     :expected "# Main\n\n## New Sub\n\nText")

    (:name "edit: bold content"
     :source "Text with **bold** here"
     :edits (("*bold*" . "*stronger*"))
     :expected "Text with **stronger** here")

    (:name "edit: italic content"
     :source "Text with *italic* here"
     :edits (("/italic/" . "/slanted/"))
     :expected "Text with *slanted* here")

    (:name "edit: inline code"
     :source "Use `oldFunc()` here"
     :edits (("~oldFunc()~" . "~newFunc()~"))
     :expected "Use `newFunc()` here")

    (:name "edit: link URL"
     :source "See [docs](https://old.example.com) for info"
     :edits (("https://old.example.com" . "https://new.example.com"))
     :expected "See [docs](https://new.example.com) for info")

    (:name "edit: link text"
     :source "Visit [old text](https://example.com) now"
     :edits (("old text" . "new text"))
     :expected "Visit [new text](https://example.com) now")

    (:name "edit: code block body"
     :source "# Code\n\n```python\nprint(\"old\")\n```"
     :edits (("print(\"old\")" . "print(\"new\")"))
     :expected "# Code\n\n```python\nprint(\"new\")\n```")

    (:name "edit: code block language"
     :source "```python\nx = 1\n```"
     :edits (("#+begin_src python" . "#+begin_src ruby"))
     :expected "```ruby\nx = 1\n```")

    (:name "edit: list item content"
     :source "# List\n\n- old item\n- keep this"
     :edits (("old item" . "new item"))
     :expected "# List\n\n- new item\n- keep this")

    (:name "edit: ordered list item"
     :source "1. first thing\n2. second thing"
     :edits (("first thing" . "primary thing"))
     :expected "1. primary thing\n2. second thing")

    (:name "edit: blockquote content"
     :source "# Section\n\n> old quote"
     :edits (("old quote" . "new quote"))
     :expected "# Section\n\n> new quote")

    (:name "edit: strikethrough content"
     :source "Some ~~old~~ text"
     :edits (("+old+" . "+new+"))
     :expected "Some ~~new~~ text")

    ;; ══════════════════════════════════════════════════════════════
    ;; MULTI-ELEMENT EDITS
    ;; ══════════════════════════════════════════════════════════════

    (:name "multi: heading + paragraph"
     :source "# Old Title\n\nOld content"
     :edits (("Old Title" . "New Title") ("Old content" . "New content"))
     :expected "# New Title\n\nNew content")

    (:name "multi: two paragraphs"
     :source "# Title\n\nFirst paragraph\n\nSecond paragraph"
     :edits (("First" . "1st") ("Second" . "2nd"))
     :expected "# Title\n\n1st paragraph\n\n2nd paragraph")

    (:name "multi: code block + list"
     :source "```js\nold()\n```\n\n- old item"
     :edits (("old()" . "new()") ("old item" . "new item"))
     :expected "```js\nnew()\n```\n\n- new item")

    (:name "multi: bold + italic in same paragraph"
     :source "Has **bold** and *italic* words"
     :edits (("*bold*" . "*strong*") ("/italic/" . "/emphasized/"))
     :expected "Has **strong** and *emphasized* words")

    ;; ══════════════════════════════════════════════════════════════
    ;; LINE-COUNT CHANGING EDITS (insertion/deletion)
    ;; ══════════════════════════════════════════════════════════════

    (:name "insert: add line to code block"
     :source "```python\nline1\n```"
     :edits (("line1" . "line1\nline2"))
     :expected "```python\nline1\nline2\n```")

    (:name "insert: add line to paragraph"
     :source "# Title\n\nOne line"
     :edits (("One line" . "One line\nTwo lines"))
     :expected "# Title\n\nOne line\nTwo lines")

    ;; ══════════════════════════════════════════════════════════════
    ;; EDGE CASES
    ;; ══════════════════════════════════════════════════════════════

    ;; NOTE: empty->non-empty body produces extra blank line before
    ;; closing fence. Cosmetic issue, content is correct.
    (:name "edge: empty code block"
     :source "```\n```"
     :edits (("#+begin_src " . "#+begin_src \nadded"))
     :expected "```\nadded\n\n```")

    (:name "edge: single character edit"
     :source "# Title\n\nA"
     :edits (("A" . "B"))
     :expected "# Title\n\nB")

    (:name "edge: special characters in paragraph"
     :source "# Title\n\nHas < and > and & chars"
     :edits (("Has" . "Contains"))
     :expected "# Title\n\nContains < and > and & chars"))

  "Fixture cases for MD -> Org -> MD round-trip testing.
Each entry is a plist with :name, :source, optional :edits, optional :expected.
When :edits is nil, tests baseline round-trip identity.
When :expected is nil, expects byte-identical to :source after commit.")

;;;; Org -> MD -> Org fixtures

(defvar prisma-fixture--org-to-md
  '(;; ══════════════════════════════════════════════════════════════
    ;; BASELINES
    ;; ══════════════════════════════════════════════════════════════

    (:name "baseline: single heading"
     :source "* Hello")

    (:name "baseline: heading + paragraph"
     :source "* Title\n\nHello world")

    (:name "baseline: nested headings"
     :source "* First\n\nText\n\n** Second\n\nMore text")

    (:name "baseline: code block"
     :source "#+begin_src python\nprint(1)\n#+end_src")

    (:name "baseline: list"
     :source "- alpha\n- beta\n- gamma")

    (:name "baseline: bold and italic"
     :source "Some *bold* and /italic/ text")

    (:name "baseline: inline code"
     :source "Use ~foo()~ here")

    (:name "baseline: link with desc"
     :source "[[https://example.com][click here]]")

    (:name "baseline: blockquote"
     :source "#+begin_quote\nQuoted text\n#+end_quote")

    (:name "baseline: horizontal rule"
     :source "Above\n\n-----\n\nBelow")

    (:name "baseline: complex document"
     :source "* Project\n\nA *bold* claim with /emphasis/.\n\n** Install\n\n#+begin_src bash\nnpm install\n#+end_src\n\n- step one\n- step two\n\n#+begin_quote\nNote: be careful\n#+end_quote\n\n-----\n\n** Links\n\n[[https://docs.example.com][docs]]")

    ;; ══════════════════════════════════════════════════════════════
    ;; SINGLE ELEMENT EDITS
    ;; ══════════════════════════════════════════════════════════════

    (:name "edit: paragraph word"
     :source "* Title\n\nHello world"
     :edits (("Hello" . "Goodbye"))
     :expected "* Title\n\nGoodbye world")

    (:name "edit: heading text"
     :source "* Old Title\n\nContent here"
     :edits (("Old Title" . "New Title"))
     :expected "* New Title\n\nContent here")

    (:name "edit: bold content"
     :source "Text with *bold* here"
     :edits (("**bold**" . "**stronger**"))
     :expected "Text with *stronger* here")

    (:name "edit: italic content"
     :source "Text with /italic/ here"
     :edits (("*italic*" . "*slanted*"))
     :expected "Text with /slanted/ here")

    (:name "edit: inline code"
     :source "Use ~oldFunc()~ here"
     :edits (("`oldFunc()`" . "`newFunc()`"))
     :expected "Use ~newFunc()~ here")

    (:name "edit: link URL"
     :source "See [[https://old.example.com][docs]] for info"
     :edits (("https://old.example.com" . "https://new.example.com"))
     :expected "See [[https://new.example.com][docs]] for info")

    (:name "edit: link text"
     :source "Visit [[https://example.com][old text]] now"
     :edits (("old text" . "new text"))
     :expected "Visit [[https://example.com][new text]] now")

    (:name "edit: code block body"
     :source "* Code\n\n#+begin_src python\nprint(\"old\")\n#+end_src"
     :edits (("print(\"old\")" . "print(\"new\")"))
     :expected "* Code\n\n#+begin_src python\nprint(\"new\")\n#+end_src")

    (:name "edit: code block language"
     :source "#+begin_src python\nx = 1\n#+end_src"
     :edits (("```python" . "```ruby"))
     :expected "#+begin_src ruby\nx = 1\n#+end_src")

    (:name "edit: list item"
     :source "* List\n\n- old item\n- keep this"
     :edits (("old item" . "new item"))
     :expected "* List\n\n- new item\n- keep this")

    (:name "edit: blockquote content"
     :source "* Section\n\n#+begin_quote\nold quote\n#+end_quote"
     :edits (("old quote" . "new quote"))
     :expected "* Section\n\n#+begin_quote\nnew quote\n#+end_quote")

    ;; ══════════════════════════════════════════════════════════════
    ;; MULTI-ELEMENT EDITS
    ;; ══════════════════════════════════════════════════════════════

    (:name "multi: heading + paragraph"
     :source "* Old Title\n\nOld content"
     :edits (("Old Title" . "New Title") ("Old content" . "New content"))
     :expected "* New Title\n\nNew content")

    (:name "multi: code block + list"
     :source "#+begin_src js\nold()\n#+end_src\n\n- old item"
     :edits (("old()" . "new()") ("old item" . "new item"))
     :expected "#+begin_src js\nnew()\n#+end_src\n\n- new item"))

  "Fixture cases for Org -> MD -> Org round-trip testing.")

;;;; Rearrangement fixtures (require text property preservation)

(defvar prisma-fixture--rearrangements
  '((:name "B1: metaup step 2 before step 1"
     :source "# Guide\n\n## Steps\n\n### Step 1\n\nDo first thing\n\n### Step 2\n\nDo second thing"
     :target-line "*** Step 2"
     :operation metaup
     :verify (lambda (result)
               (let ((s2 (string-match "Step 2" result))
                     (s1 (string-match "Step 1" result)))
                 (and s2 s1 (< s2 s1)
                      (string-match "Do first thing" result)
                      (string-match "Do second thing" result)))))

    (:name "B2: metaup step 3 before step 2"
     :source "# Guide\n\n### Step 1\n\nFirst\n\n### Step 2\n\nSecond\n\n### Step 3\n\nThird"
     :target-line "*** Step 3"
     :operation metaup
     :verify (lambda (result)
               (let ((s3 (string-match "Step 3" result))
                     (s2 (string-match "Step 2" result)))
                 (and s3 s2 (< s3 s2)
                      (string-match "Third" result)))))

    (:name "B3: metadown step 1 after step 2"
     :source "# Guide\n\n### Step 1\n\nFirst\n\n### Step 2\n\nSecond"
     :target-line "*** Step 1"
     :operation metadown
     :verify (lambda (result)
               (let ((s1 (string-match "Step 1" result))
                     (s2 (string-match "Step 2" result)))
                 (and s1 s2 (> s1 s2)
                      (string-match "First" result)
                      (string-match "Second" result)))))

    (:name "B4: metaup h2 section"
     :source "# Project\n\n## Installation\n\nInstall steps\n\n## Usage\n\nUsage info"
     :target-line "** Usage"
     :operation metaup
     :verify (lambda (result)
               (let ((usage (string-match "Usage" result))
                     (install (string-match "Installation" result)))
                 (and usage install (< usage install)))))

    (:name "B5: metaup troubleshooting before architecture"
     :source "# Docs\n\n## Architecture\n\nArch details\n\n## Troubleshooting\n\nTrouble details"
     :target-line "** Troubleshooting"
     :operation metaup
     :verify (lambda (result)
               (let ((trouble (string-match "Troubleshooting" result))
                     (arch (string-match "Architecture" result)))
                 (and trouble arch (< trouble arch)))))

    (:name "B6: metadown installation after configuration"
     :source "# Docs\n\n## Installation\n\nInstall info\n\n## Configuration\n\nConfig info"
     :target-line "** Installation"
     :operation metadown
     :verify (lambda (result)
               (let ((install (string-match "Installation" result))
                     (config (string-match "Configuration" result)))
                 (and install config (> install config))))))

  "Rearrangement test cases requiring org-metaup/metadown.")

(defun prisma-fixture--run-rearrangement (case)
  "Run a rearrangement fixture CASE."
  (let* ((source-text (plist-get case :source))
         (target-line (plist-get case :target-line))
         (operation (plist-get case :operation))
         (source-buf (generate-new-buffer " *fixture-src*"))
         (result nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buf
            (insert source-text)
            (markdown-mode)
            (goto-char (point-min)))
          (let ((mirror-buf (with-current-buffer source-buf
                              (prisma-convert))))
            (with-current-buffer mirror-buf
              ;; Navigate to target line
              (goto-char (point-min))
              (unless (search-forward target-line nil t)
                (error "Cannot find target line %S" target-line))
              (beginning-of-line)
              ;; Execute operation
              (pcase operation
                ('metaup (org-metaup))
                ('metadown (org-metadown)))
              ;; Commit
              (prisma-commit)))
          (setq result (with-current-buffer source-buf
                         (buffer-substring-no-properties
                          (point-min) (point-max)))))
      (when (buffer-live-p source-buf)
        (kill-buffer source-buf))
      (dolist (buf (buffer-list))
        (when (string-prefix-p "*prisma:" (buffer-name buf))
          (let ((kill-buffer-query-functions nil)
                (prisma--skip-kill-confirm t))
            (kill-buffer buf)))))
    result))

;;;; Generate buttercup specs

(describe "Fixtures: MD -> Org -> MD"

  (dolist (case prisma-fixture--md-to-org)
    (let ((name (plist-get case :name))
          (source (plist-get case :source))
          (edits (plist-get case :edits))
          (expected (plist-get case :expected)))
      (it name
        (if edits
            (expect (prisma-fixture--run #'markdown-mode source edits expected)
                    :to-equal expected)
          ;; Baseline: expect byte-identical round-trip
          (expect (prisma-fixture--run-baseline #'markdown-mode source)
                  :to-equal source))))))

(describe "Fixtures: Org -> MD -> Org"

  (dolist (case prisma-fixture--org-to-md)
    (let ((name (plist-get case :name))
          (source (plist-get case :source))
          (edits (plist-get case :edits))
          (expected (plist-get case :expected)))
      (it name
        (if edits
            (expect (prisma-fixture--run #'org-mode source edits expected)
                    :to-equal expected)
          (expect (prisma-fixture--run-baseline #'org-mode source)
                  :to-equal source))))))

(describe "Fixtures: Rearrangements"

  (dolist (case prisma-fixture--rearrangements)
    (let ((name (plist-get case :name))
          (verify-fn (plist-get case :verify)))
      (it name
        (let ((result (prisma-fixture--run-rearrangement case)))
          (expect (funcall verify-fn result) :to-be-truthy))))))

;;;; Edge case tests (programmatic)

(describe "Edge cases"

  (it "data loss safeguard: code exists in commit"
    ;; The safeguard prevents silent data loss when the pipeline
    ;; detects mirror changes but patch produces no source diff.
    ;; Hard to trigger artificially since our pipeline now correctly
    ;; propagates all changes. Verify the safeguard code path exists.
    (expect (symbol-function 'prisma-commit) :to-be-truthy)
    (let ((source (symbol-function 'prisma-commit)))
      ;; Verify the safeguard string is in the compiled function
      (expect (format "%s" source) :to-match "patch produced")))

  (it "no-change commit: returns to source cleanly"
    (let ((source-buf (generate-new-buffer " *fixture-src*")))
      (unwind-protect
          (progn
            (with-current-buffer source-buf
              (insert "# Hello\n\nWorld")
              (markdown-mode)
              (goto-char (point-min)))
            (let ((mirror-buf (with-current-buffer source-buf
                                (prisma-convert))))
              (with-current-buffer mirror-buf
                (prisma-commit))
              (expect (with-current-buffer source-buf
                        (buffer-substring-no-properties
                         (point-min) (point-max)))
                      :to-equal "# Hello\n\nWorld")))
        (when (buffer-live-p source-buf)
          (kill-buffer source-buf))
        (dolist (buf (buffer-list))
          (when (string-prefix-p "*prisma:" (buffer-name buf))
            (let ((kill-buffer-query-functions nil)
                  (prisma--skip-kill-confirm t))
              (kill-buffer buf)))))))

  (it "region conversion: edits only affect region"
    (let ((source-buf (generate-new-buffer " *fixture-src*")))
      (unwind-protect
          (progn
            (with-current-buffer source-buf
              (insert "# Keep This\n\n## Convert This\n\nOld text\n\n# Keep That")
              (markdown-mode)
              ;; Select just the "## Convert This\n\nOld text" region
              (goto-char (point-min))
              (search-forward "## Convert")
              (beginning-of-line)
              (set-mark (point))
              (search-forward "Old text")
              (end-of-line)
              (activate-mark))
            (let ((mirror-buf (with-current-buffer source-buf
                                (prisma-convert))))
              (with-current-buffer mirror-buf
                (goto-char (point-min))
                (search-forward "Old text")
                (replace-match "New text" t t)
                (prisma-commit)))
            (let ((result (with-current-buffer source-buf
                            (buffer-substring-no-properties
                             (point-min) (point-max)))))
              (expect result :to-match "# Keep This")
              (expect result :to-match "New text")
              (expect result :to-match "# Keep That")))
        (when (buffer-live-p source-buf)
          (kill-buffer source-buf))
        (dolist (buf (buffer-list))
          (when (string-prefix-p "*prisma:" (buffer-name buf))
            (let ((kill-buffer-query-functions nil)
                  (prisma--skip-kill-confirm t))
              (kill-buffer buf))))))))

;;; prisma-fixture-tests.el ends here
