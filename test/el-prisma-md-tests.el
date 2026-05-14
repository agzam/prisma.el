;;; el-prisma-md-tests.el --- Markdown conversion tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Integration tests for Markdown <-> Org conversion.
;;  Requires tree-sitter markdown grammars.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma)
(require 'el-prisma-md)
(require 'el-prisma-org)

(defun el-prisma-test-md->org (md)
  "Parse MD, render to Org, return string."
  (el-prisma-render 'org (el-prisma-parse 'markdown md)))

(describe "Markdown -> Org conversion"

  (describe "headings"
    (it "converts h1"
      (expect (el-prisma-test-md->org "# Hello\n")
              :to-equal "* Hello"))
    (it "converts h2"
      (expect (el-prisma-test-md->org "## Sub\n")
              :to-equal "** Sub"))
    (it "converts h3"
      (expect (el-prisma-test-md->org "### Deep\n")
              :to-equal "*** Deep")))

  (describe "inline emphasis"
    (it "converts bold"
      (expect (el-prisma-test-md->org "**bold**\n")
              :to-equal "*bold*"))
    (it "converts italic"
      (expect (el-prisma-test-md->org "*italic*\n")
              :to-equal "/italic/"))
    (it "converts inline code"
      (expect (el-prisma-test-md->org "`code`\n")
              :to-equal "~code~"))
    (it "converts mixed inline"
      (expect (el-prisma-test-md->org "Some **bold** and *italic* text.\n")
              :to-equal "Some *bold* and /italic/ text.")))

  (describe "links"
    (it "converts inline links"
      (expect (el-prisma-test-md->org "[text](http://example.com)\n")
              :to-equal "[[http://example.com][text]]")))

  (describe "code blocks"
    (it "converts fenced code blocks"
      (let ((result (el-prisma-test-md->org "```elisp\n(+ 1 2)\n```\n")))
        (expect result :to-match "^#\\+begin_src elisp")
        (expect result :to-match "(\\+ 1 2)")
        (expect result :to-match "#\\+end_src$"))))

  (describe "lists"
    (it "converts unordered lists"
      (let ((result (el-prisma-test-md->org "- one\n- two\n")))
        (expect result :to-match "^- one")
        (expect result :to-match "- two")))
    (it "converts ordered lists"
      (let ((result (el-prisma-test-md->org "1. first\n2. second\n")))
        (expect result :to-match "^1\\. first")
        (expect result :to-match "2\\. second"))))

  (describe "block elements"
    (it "converts blockquotes"
      (let ((result (el-prisma-test-md->org "> quoted text\n")))
        (expect result :to-match "#\\+begin_quote")
        (expect result :to-match "quoted text")
        (expect result :to-match "#\\+end_quote")))
    (it "converts horizontal rules"
      (expect (el-prisma-test-md->org "---\n") :to-equal "-----")))

  (describe "full document"
    (it "converts a complete document"
      (let* ((md "# Title\n\nA paragraph with **bold** and *italic*.\n\n- item 1\n- item 2\n\n```python\nprint('hello')\n```\n\n[link](http://example.com)\n")
             (org (el-prisma-test-md->org md)))
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
        (let* ((ast (el-prisma-parse 'markdown md))
               (org (el-prisma-render 'org ast))
               (org-ast (el-prisma-parse 'org org))
               (re-org (el-prisma-render 'org org-ast)))
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
           (ast (el-prisma-parse 'markdown md))
           (org (el-prisma-render 'org ast))
           (org-ast (el-prisma-parse 'org org))
           (re-org (el-prisma-render 'org org-ast)))
      (expect org :to-equal re-org))))

(provide 'el-prisma-md-tests)
;;; el-prisma-md-tests.el ends here
