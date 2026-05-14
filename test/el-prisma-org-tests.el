;;; el-prisma-org-tests.el --- Org parser and conversion tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for Org parser and Org<->Markdown round-trips.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma)
(require 'el-prisma-model)
(require 'el-prisma-org)

(defun el-prisma-test-org-parse-type (text)
  "Parse Org TEXT, return types of top-level children."
  (let ((ast (el-prisma-parse 'org text)))
    (mapcar #'el-prisma-model-type (el-prisma-model-children ast))))

(defun el-prisma-test-org->md (org)
  "Parse ORG text, render to Markdown."
  (el-prisma-render 'markdown (el-prisma-parse 'org org)))

(defun el-prisma-test-org-roundtrip (org)
  "Parse ORG, render back to Org."
  (el-prisma-render 'org (el-prisma-parse 'org org)))

(describe "Org parser"

  (describe "headings"
    (it "parses level 1"
      (let* ((ast (el-prisma-parse 'org "* Hello\n"))
             (h (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type h) :to-equal 'heading)
        (expect (el-prisma-model-prop h :level) :to-equal 1)
        (expect (el-prisma-model-prop
                 (car (el-prisma-model-children h)) :value)
                :to-equal "Hello")))
    (it "parses level 3"
      (let* ((ast (el-prisma-parse 'org "*** Deep\n"))
             (h (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-prop h :level) :to-equal 3)))
    (it "parses heading with inline markup"
      (let* ((ast (el-prisma-parse 'org "* A *bold* heading\n"))
             (h (car (el-prisma-model-children ast)))
             (children (el-prisma-model-children h)))
        (expect (length children) :to-be-greater-than 1)
        (expect (cl-some (lambda (c) (eq (el-prisma-model-type c) 'strong))
                         children)
                :to-be-truthy))))

  (describe "paragraphs"
    (it "parses plain text as paragraph"
      (let* ((ast (el-prisma-parse 'org "Just some text.\n"))
             (p (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type p) :to-equal 'paragraph)))
    (it "parses inline emphasis in paragraphs"
      (let* ((ast (el-prisma-parse 'org "Some *bold* and /italic/ text.\n"))
             (p (car (el-prisma-model-children ast)))
             (children (el-prisma-model-children p))
             (types (mapcar #'el-prisma-model-type children)))
        (expect (member 'strong types) :to-be-truthy)
        (expect (member 'emphasis types) :to-be-truthy))))

  (describe "inline elements"
    (it "parses bold"
      (let* ((ast (el-prisma-parse 'org "*bold*\n"))
             (p (car (el-prisma-model-children ast)))
             (bold (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type bold) :to-equal 'strong)))
    (it "parses italic"
      (let* ((ast (el-prisma-parse 'org "/italic/\n"))
             (p (car (el-prisma-model-children ast)))
             (em (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type em) :to-equal 'emphasis)))
    (it "parses inline code"
      (let* ((ast (el-prisma-parse 'org "~code~\n"))
             (p (car (el-prisma-model-children ast)))
             (c (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type c) :to-equal 'code)
        (expect (el-prisma-model-prop c :value) :to-equal "code")))
    (it "parses verbatim"
      (let* ((ast (el-prisma-parse 'org "=verb=\n"))
             (p (car (el-prisma-model-children ast)))
             (v (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type v) :to-equal 'verbatim)
        (expect (el-prisma-model-prop v :value) :to-equal "verb")))
    (it "parses strikethrough"
      (let* ((ast (el-prisma-parse 'org "+struck+\n"))
             (p (car (el-prisma-model-children ast)))
             (s (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type s) :to-equal 'strike)))
    (it "parses bracket link with description"
      (let* ((ast (el-prisma-parse 'org "[[http://ex.com][click]]\n"))
             (p (car (el-prisma-model-children ast)))
             (link (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type link) :to-equal 'link)
        (expect (el-prisma-model-prop link :url) :to-equal "http://ex.com")
        (expect (el-prisma-model-prop
                 (car (el-prisma-model-children link)) :value)
                :to-equal "click")))
    (it "does not hang on URLs with slashes"
      (let* ((ast (el-prisma-parse 'org "Visit http://example.com/foo/bar now.\n"))
             (p (car (el-prisma-model-children ast)))
             (types (mapcar #'el-prisma-model-type
                            (el-prisma-model-children p))))
        ;; Should parse without hanging; slashes in URL are not italic
        (expect (member 'text types) :to-be-truthy)
        (expect (member 'emphasis types) :not :to-be-truthy)))
    (it "does not hang on unmatched markup chars"
      (let* ((ast (el-prisma-parse 'org "a/b and c*d end.\n"))
             (p (car (el-prisma-model-children ast))))
        ;; Should parse without hanging
        (expect (el-prisma-model-type p) :to-equal 'paragraph)))
    (it "parses bracket link without description"
      (let* ((ast (el-prisma-parse 'org "[[http://ex.com]]\n"))
             (p (car (el-prisma-model-children ast)))
             (link (car (el-prisma-model-children p))))
        (expect (el-prisma-model-type link) :to-equal 'link)
        (expect (el-prisma-model-prop link :url) :to-equal "http://ex.com")
        (expect (el-prisma-model-children link) :to-equal nil))))

  (describe "code blocks"
    (it "parses src blocks"
      (let* ((text "#+begin_src elisp\n(+ 1 2)\n#+end_src\n")
             (ast (el-prisma-parse 'org text))
             (cb (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type cb) :to-equal 'code-block)
        (expect (el-prisma-model-prop cb :language) :to-equal "elisp")
        (expect (el-prisma-model-prop cb :body) :to-match "(\\+ 1 2)")))
    (it "parses src block without language"
      (let* ((text "#+begin_src\nsome code\n#+end_src\n")
             (ast (el-prisma-parse 'org text))
             (cb (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type cb) :to-equal 'code-block)
        (expect (el-prisma-model-prop cb :language) :to-be nil))))

  (describe "lists"
    (it "parses unordered list"
      (let* ((ast (el-prisma-parse 'org "- one\n- two\n"))
             (lst (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type lst) :to-equal 'list)
        (expect (el-prisma-model-prop lst :ordered) :to-be nil)
        (expect (length (el-prisma-model-children lst)) :to-equal 2)))
    (it "parses ordered list"
      (let* ((ast (el-prisma-parse 'org "1. first\n2. second\n"))
             (lst (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type lst) :to-equal 'list)
        (expect (el-prisma-model-prop lst :ordered) :to-be-truthy)))
    (it "parses checkbox items"
      (let* ((ast (el-prisma-parse 'org "- [X] done\n- [ ] todo\n"))
             (lst (car (el-prisma-model-children ast)))
             (items (el-prisma-model-children lst)))
        (expect (el-prisma-model-prop (car items) :checkbox)
                :to-equal 'checked)
        (expect (el-prisma-model-prop (cadr items) :checkbox)
                :to-equal 'unchecked))))

  (describe "block elements"
    (it "parses blockquotes"
      (let* ((text "#+begin_quote\nquoted text\n#+end_quote\n")
             (ast (el-prisma-parse 'org text))
             (bq (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type bq) :to-equal 'blockquote)))
    (it "parses horizontal rules"
      (let* ((ast (el-prisma-parse 'org "-----\n"))
             (hr (car (el-prisma-model-children ast))))
        (expect (el-prisma-model-type hr) :to-equal 'horiz-rule)))
    (it "identifies block types correctly"
      (expect (el-prisma-test-org-parse-type
               "* Heading\n\nParagraph.\n\n-----\n")
              :to-equal '(heading paragraph horiz-rule))))

  (describe "multi-block document"
    (it "parses a complete document"
      (let* ((text (concat "* Title\n\n"
                           "A paragraph with *bold* and /italic/.\n\n"
                           "- item 1\n- item 2\n\n"
                           "#+begin_src python\nprint('hello')\n#+end_src\n\n"
                           "[[http://example.com][link]]\n"))
             (ast (el-prisma-parse 'org text))
             (types (mapcar #'el-prisma-model-type
                            (el-prisma-model-children ast))))
        (expect (member 'heading types) :to-be-truthy)
        (expect (member 'paragraph types) :to-be-truthy)
        (expect (member 'list types) :to-be-truthy)
        (expect (member 'code-block types) :to-be-truthy)))))

(describe "Org -> Markdown conversion"
  (it "converts headings"
    (expect (el-prisma-test-org->md "* Title\n")
            :to-equal "# Title"))
  (it "converts bold"
    (expect (el-prisma-test-org->md "*bold*\n")
            :to-equal "**bold**"))
  (it "converts italic"
    (expect (el-prisma-test-org->md "/italic/\n")
            :to-equal "*italic*"))
  (it "converts inline code"
    (expect (el-prisma-test-org->md "~code~\n")
            :to-equal "`code`"))
  (it "converts links"
    (expect (el-prisma-test-org->md "[[http://ex.com][click]]\n")
            :to-equal "[click](http://ex.com)"))
  (it "converts code blocks"
    (let ((result (el-prisma-test-org->md
                   "#+begin_src elisp\n(+ 1 2)\n#+end_src\n")))
      (expect result :to-match "^```elisp")
      (expect result :to-match "(\\+ 1 2)")
      (expect result :to-match "```$")))
  (it "converts lists"
    (let ((result (el-prisma-test-org->md "- one\n- two\n")))
      (expect result :to-match "^- one")
      (expect result :to-match "- two")))
  (it "converts horizontal rule"
    (expect (el-prisma-test-org->md "-----\n") :to-equal "---")))

(describe "Org round-trip"
  (it "round-trips headings"
    (expect (el-prisma-test-org-roundtrip "* Hello\n")
            :to-equal "* Hello"))
  (it "round-trips bold"
    (expect (el-prisma-test-org-roundtrip "*bold*\n")
            :to-equal "*bold*"))
  (it "round-trips inline code"
    (expect (el-prisma-test-org-roundtrip "~code~\n")
            :to-equal "~code~"))
  (it "round-trips links"
    (expect (el-prisma-test-org-roundtrip "[[http://ex.com][click]]\n")
            :to-equal "[[http://ex.com][click]]"))
  (it "round-trips horizontal rule"
    (expect (el-prisma-test-org-roundtrip "-----\n")
            :to-equal "-----")))

(describe "Org parser - tables"
  (it "parses pipe tables as passthrough"
    (let* ((ast (el-prisma-parse 'org "| A | B |\n|---|---|\n| 1 | 2 |\n"))
           (pt (car (el-prisma-model-children ast))))
      (expect (el-prisma-model-type pt) :to-equal 'passthrough)
      (expect (el-prisma-model-prop pt :text) :to-match "| A | B |")))

  (it "table followed by paragraph keeps both"
    (let* ((ast (el-prisma-parse 'org "| A |\n|---|\n| 1 |\n\nAfter.\n"))
           (types (mapcar #'el-prisma-model-type
                          (el-prisma-model-children ast))))
      (expect types :to-equal '(passthrough paragraph)))))



(provide 'el-prisma-org-tests)
;;; el-prisma-org-tests.el ends here
