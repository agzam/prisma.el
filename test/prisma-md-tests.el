;;; prisma-md-tests.el --- Markdown conversion tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Integration tests for Markdown <-> Org conversion.
;;  Requires tree-sitter markdown grammars.
;;
;;; Code:

(require 'buttercup)
(require 'prisma)
(require 'prisma-md)
(require 'prisma-org)

(defun prisma-test-md->org (md)
  "Parse MD, render to Org, return string."
  (prisma-render 'org (prisma-parse 'markdown md)))

(describe "Markdown -> Org conversion"

  (describe "headings"
    (it "converts h1"
      (expect (prisma-test-md->org "# Hello\n")
              :to-equal "* Hello"))
    (it "converts h2"
      (expect (prisma-test-md->org "## Sub\n")
              :to-equal "** Sub"))
    (it "converts h3"
      (expect (prisma-test-md->org "### Deep\n")
              :to-equal "*** Deep")))

  (describe "inline emphasis"
    (it "converts bold"
      (expect (prisma-test-md->org "**bold**\n")
              :to-equal "*bold*"))
    (it "converts italic"
      (expect (prisma-test-md->org "*italic*\n")
              :to-equal "/italic/"))
    (it "converts inline code"
      (expect (prisma-test-md->org "`code`\n")
              :to-equal "~code~"))
    (it "converts mixed inline"
      (expect (prisma-test-md->org "Some **bold** and *italic* text.\n")
              :to-equal "Some *bold* and /italic/ text.")))

  (describe "links"
    (it "converts inline links"
      (expect (prisma-test-md->org "[text](http://example.com)\n")
              :to-equal "[[http://example.com][text]]")))

  (describe "code blocks"
    (it "converts fenced code blocks"
      (let ((result (prisma-test-md->org "```elisp\n(+ 1 2)\n```\n")))
        (expect result :to-match "^#\\+begin_src elisp")
        (expect result :to-match "(\\+ 1 2)")
        (expect result :to-match "#\\+end_src$"))))

  (describe "lists"
    (it "converts unordered lists"
      (let ((result (prisma-test-md->org "- one\n- two\n")))
        (expect result :to-match "^- one")
        (expect result :to-match "- two")))
    (it "converts ordered lists"
      (let ((result (prisma-test-md->org "1. first\n2. second\n")))
        (expect result :to-match "^1\\. first")
        (expect result :to-match "2\\. second"))))

  (describe "block elements"
    (it "converts blockquotes"
      (let ((result (prisma-test-md->org "> quoted text\n")))
        (expect result :to-match "#\\+begin_quote")
        (expect result :to-match "quoted text")
        (expect result :to-match "#\\+end_quote")))
    (it "converts horizontal rules"
      (expect (prisma-test-md->org "---\n") :to-equal "-----")))

  (describe "full document"
    (it "converts a complete document"
      (let* ((md "# Title\n\nA paragraph with **bold** and *italic*.\n\n- item 1\n- item 2\n\n```python\nprint('hello')\n```\n\n[link](http://example.com)\n")
             (org (prisma-test-md->org md)))
        (expect org :to-match "^\\* Title")
        (expect org :to-match "\\*bold\\*")
        (expect org :to-match "/italic/")
        (expect org :to-match "- item 1")
        (expect org :to-match "#\\+begin_src python")
        (expect org :to-match "\\[\\[http://example.com\\]\\[link\\]\\]")))))

(describe "MD->Org round-trip stability per element type"
  (dolist (pair '(("heading" "## Title\n")
                  ("paragraph" "A paragraph.\n")
                  ("bold" "**bold**\n")
                  ("italic" "*italic*\n")
                  ("code-span" "`code`\n")
                  ("strikethrough" "~~struck~~\n")
                  ("link" "[text](http://url)\n")
                  ("image" "![alt](http://img.png)\n")
                  ("code-block" "```py\nx=1\n```\n")
                  ("blockquote" "> quote\n")
                  ("horiz-rule" "---\n")
                  ("unordered-list" "- a\n- b\n")
                  ("ordered-list" "1. a\n2. b\n")
                  ("table" "| A | B |\n|---|---|\n| 1 | 2 |\n")))
    (let ((name (car pair))
          (md (cadr pair)))
      (it (format "%s round-trips through Org" name)
        (let* ((ast (prisma-parse 'markdown md))
               (org (prisma-render 'org ast))
               (org-ast (prisma-parse 'org org))
               (re-org (prisma-render 'org org-ast)))
          (expect org :to-equal re-org))))))

(describe "MD->Org multi-element document round-trip"
  (it "preserves all element types in a combined document"
    (let* ((md (concat "# Heading\n\n"
                       "Paragraph with **bold** and *italic* and `code`.\n\n"
                       "[link](http://example.com)\n\n"
                       "![alt](http://img.png)\n\n"
                       "| A | B |\n|---|---|\n| 1 | 2 |\n\n"
                       "> blockquote\n\n"
                       "---\n\n"
                       "- item\n\n"
                       "1. ordered\n\n"
                       "```py\ncode()\n```\n\n"
                       "Final.\n"))
           (ast (prisma-parse 'markdown md))
           (org (prisma-render 'org ast))
           (org-ast (prisma-parse 'org org))
           (re-org (prisma-render 'org org-ast)))
      (expect org :to-equal re-org))))

;;;; Group G - Tables

(describe "Tables: MD parser"

  (it "parses pipe_table into structured nodes"
    (let* ((md "| A | B |\n|---|---|\n| 1 | 2 |\n")
           (ast (prisma-parse 'markdown md))
           (tbl (car (prisma-model-children ast))))
      (expect (prisma-model-type tbl) :to-equal 'table)
      (expect (mapcar #'prisma-model-type
                      (prisma-model-children tbl))
              :to-equal '(table-row table-separator table-row))))

  (it "extracts alignment markers"
    (let* ((md "| L | C | R | D |\n|:---|:---:|---:|---|\n| 1 | 2 | 3 | 4 |\n")
           (ast (prisma-parse 'markdown md))
           (tbl (car (prisma-model-children ast))))
      (expect (prisma-model-prop tbl :alignments)
              :to-equal '(:left :center :right :default))))

  (it "parses inline markup inside cells"
    (let* ((md "| A **bold** | B *italic* | `code` |\n|---|---|---|\n")
           (ast (prisma-parse 'markdown md))
           (header (car (prisma-model-children
                         (car (prisma-model-children ast)))))
           (cells (prisma-model-children header))
           (cell-child-types
            (mapcar (lambda (cell)
                      (mapcar #'prisma-model-type
                              (prisma-model-children cell)))
                    cells)))
      ;; First cell: text "A " + strong
      (expect (cadar cell-child-types) :to-equal 'strong)
      ;; Second cell: text "B " + emphasis
      (expect (cadr (cadr cell-child-types)) :to-equal 'emphasis)
      ;; Third cell: code
      (expect (caddr cell-child-types) :to-equal '(code))))

  (it "parses links inside cells"
    (let* ((md "| Link |\n|---|\n| [click](http://x) |\n")
           (ast (prisma-parse 'markdown md))
           (data-row (nth 2 (prisma-model-children
                             (car (prisma-model-children ast)))))
           (cell (car (prisma-model-children data-row)))
           (link (car (prisma-model-children cell))))
      (expect (prisma-model-type link) :to-equal 'link)
      (expect (prisma-model-prop link :url) :to-equal "http://x"))))

(describe "Tables: MD->Org conversion"

  (it "converts pipe separator to + separator with column alignment"
    (let* ((md "| Test | Operation | Status |
|------|-----------|--------|
| A1 | Edit word | DONE |
| A2 | Edit longer text | DONE |
")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-equal "| Test | Operation        | Status |
|------+------------------+--------|
| A1   | Edit word        | DONE   |
| A2   | Edit longer text | DONE   |")))

  (it "reproduces the user's known example"
    (let* ((md "| Test | Operation | Verify | Status |
|------|-----------|--------|--------|
| A1 | Edit paragraph word | 1 block differs | DONE |
| A2 | Edit heading text | 1 block differs | DONE |
| A11 | Single char change in large doc | 1 block differs | DONE |
")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-equal "| Test | Operation                       | Verify          | Status |
|------+---------------------------------+-----------------+--------|
| A1   | Edit paragraph word             | 1 block differs | DONE   |
| A2   | Edit heading text               | 1 block differs | DONE   |
| A11  | Single char change in large doc | 1 block differs | DONE   |")))

  (it "converts inline markup inside cells"
    (let* ((md "| A **bold** | B *italic* |\n|---|---|\n| 1 | 2 |\n")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-match "A \\*bold\\*")
      (expect org :to-match "B /italic/")))

  (it "converts links inside cells"
    (let* ((md "| Link |\n|---|\n| [click](http://x) |\n")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-match "\\[\\[http://x\\]\\[click\\]\\]")))

  (it "handles CJK widths via string-width"
    (let* ((md "| 私 | World |\n|---|---|\n| あ | hello |\n")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      ;; Each CJK char is width 2, so column 1 is width 2.
      (expect org :to-match "| 私 |"))))

(describe "Tables: round-trip MD->Org->MD"

  (it "produces valid GFM (single separator) from multi-hline Org"
    (let* ((org "| A | B |\n|---+---|\n| 1 | 2 |\n|---+---|\n| 3 | 4 |\n")
           (md (prisma-render 'markdown (prisma-parse 'org org))))
      ;; Exactly one separator row in the output
      (expect (length
               (cl-remove-if-not
                (lambda (line) (string-match-p "^|---" line))
                (split-string md "\n")))
              :to-equal 1)))

  (it "renders MD back from Org converted from MD"
    (let* ((md "| A | B |\n|---|---|\n| 1 | 2 |\n")
           (org (prisma-render 'org (prisma-parse 'markdown md)))
           (back (prisma-render 'markdown (prisma-parse 'org org))))
      (expect back :to-equal "| A | B |
|---|---|
| 1 | 2 |"))))

(describe "Tables: edge cases"

  (it "single column table renders correctly"
    (let* ((md "| Only |\n|---|\n| 1 |\n")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-match "^| Only |")
      (expect org :to-match "|------|")))

  (it "header-only table renders without body"
    (let* ((md "| A | B |\n|---|---|\n")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-equal "| A | B |\n|---+---|")))

  (it "empty cell renders as space-padded"
    (let* ((md "| A |  | C |\n|---|---|---|\n")
           (org (prisma-render 'org (prisma-parse 'markdown md))))
      (expect org :to-match "| A |   | C |")))

  (it "escaped pipe in cell preserved on MD output"
    (let* ((md "| A \\| B | C |\n|---|---|\n| 1 \\| 2 | 3 |\n")
           (back (prisma-render 'markdown
                                (prisma-parse 'org
                                              (prisma-render 'org
                                                             (prisma-parse 'markdown md))))))
      ;; Round-trip preserves the escape
      (expect back :to-match "A \\\\| B")
      (expect back :to-match "1 \\\\| 2"))))

(describe "Tables: Org->MD conversion"

  (it "+ separator becomes | separator"
    (let* ((org "| A | B |\n|---+---|\n| 1 | 2 |\n")
           (md (prisma-render 'markdown (prisma-parse 'org org))))
      (expect md :to-equal "| A | B |\n|---|---|\n| 1 | 2 |")))

  (it "Org table without separator gets one injected in MD"
    (let* ((org "| A | B |\n| 1 | 2 |\n")
           (md (prisma-render 'markdown (prisma-parse 'org org))))
      ;; Must contain a separator row for valid GFM
      (expect md :to-match "^|---")))

  (it "converts inline markup back"
    (let* ((org "| *bold* | /italic/ |\n|---+---|\n")
           (md (prisma-render 'markdown (prisma-parse 'org org))))
      (expect md :to-match "\\*\\*bold\\*\\*")
      (expect md :to-match "\\*italic\\*"))))

(provide 'prisma-md-tests)
;;; prisma-md-tests.el ends here
