;;; prisma-isolation-tests.el --- Edit isolation & structural change tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Tests verifying that edits to specific nodes produce changes ONLY to those
;; nodes in the source buffer. Non-edited nodes must remain byte-identical.
;;
;; Categories:
;;  1. Single-edit isolation (1 edit = 1 changed block)
;;  2. Multi-edit isolation (N edits = N changed blocks)
;;  3. Structural: reordering
;;  4. Structural: insertion / deletion
;;  5. Boundary-crossing and edge cases
;;
;;; Code:

(require 'buttercup)
(require 'prisma)
(require 'prisma-md)
(require 'prisma-org)

;;;; ----------------------------------------------------------------
;;;; Helpers
;;;; ----------------------------------------------------------------

(defun prisma-iso--run (source-mode source-text edit-fn)
  "Create source in SOURCE-MODE, convert, apply EDIT-FN in mirror, commit.
EDIT-FN is called with no args in the mirror buffer (nil = no edits).
Returns the source buffer text after commit."
  (let ((source-buf (generate-new-buffer " *iso-src*"))
        result)
    (unwind-protect
        (progn
          (with-current-buffer source-buf
            (insert source-text)
            (funcall source-mode)
            (goto-char (point-min)))
          (let ((mirror-buf (with-current-buffer source-buf
                              (prisma-convert))))
            (with-current-buffer mirror-buf
              (when edit-fn (funcall edit-fn))
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

(defun prisma-iso--replace (&rest pairs)
  "Return an edit function that applies search-replace PAIRS in the mirror.
Each element is (SEARCH . REPLACEMENT)."
  (lambda ()
    (let ((case-fold-search nil))
      (dolist (pair pairs)
        (goto-char (point-min))
        (unless (search-forward (car pair) nil t)
          (error "Edit: cannot find %S in mirror buffer" (car pair)))
        (replace-match (cdr pair) t t)))))

(defun prisma-iso--split-blocks (text)
  "Split TEXT into top-level blocks at blank-line boundaries."
  (split-string text "\n\n"))

(defun prisma-iso--count-line-diffs (a b)
  "Count lines that differ between A and B, including length mismatch."
  (let ((al (split-string a "\n"))
        (bl (split-string b "\n"))
        (n 0))
    (cl-mapc (lambda (x y) (unless (string= x y) (cl-incf n))) al bl)
    (+ n (abs (- (length al) (length bl))))))

(defun prisma-iso--count-block-changes (source result)
  "Count blocks that differ between SOURCE and RESULT.
Both must have the same block count (non-structural edits)."
  (let ((sb (prisma-iso--split-blocks source))
        (rb (prisma-iso--split-blocks result))
        (n 0))
    (unless (= (length sb) (length rb))
      (error "Block count changed: %d -> %d" (length sb) (length rb)))
    (cl-mapc (lambda (s r) (unless (string= s r) (cl-incf n))) sb rb)
    n))

(defun prisma-iso--changed-block-indices (source result)
  "Return 0-based indices of blocks that differ between SOURCE and RESULT."
  (let ((sb (prisma-iso--split-blocks source))
        (rb (prisma-iso--split-blocks result))
        indices)
    (cl-loop for i from 0
             for s in sb
             for r in rb
             unless (string= s r)
             do (push i indices))
    (nreverse indices)))

(defun prisma-iso--blocks-at (text indices)
  "Extract blocks at 0-based INDICES from TEXT."
  (let ((blocks (prisma-iso--split-blocks text)))
    (mapcar (lambda (i) (nth i blocks)) indices)))

;;;; ----------------------------------------------------------------
;;;; Test documents
;;;; ----------------------------------------------------------------

;; 5-block Markdown document. Each block has a unique keyword.
(defvar prisma-iso--md5
  "# Heading Alpha\n\nParagraph bravo content\n\n## Heading Charlie\n\nParagraph delta content\n\nParagraph echo content")

;; 7-block Markdown document covering heading, paragraph, code, list,
;; sub-heading, paragraph, blockquote.
(defvar prisma-iso--md7
  "# Main Title\n\nFirst paragraph here\n\n```python\nx = 42\n```\n\n- item one\n- item two\n\n## Section Two\n\nSecond paragraph here\n\n> A notable quote")

;; 5-block Org document.
(defvar prisma-iso--org5
  "* Heading Foxtrot\n\nParagraph golf content\n\n** Heading Hotel\n\nParagraph india content\n\nParagraph juliet content")

;; 7-block Org document.
(defvar prisma-iso--org7
  "* Top Heading\n\nOpening paragraph text\n\n#+begin_src python\ny = 99\n#+end_src\n\n- lima item\n- mike item\n\n** Lower Section\n\nClosing paragraph text\n\n#+begin_quote\nA memorable remark\n#+end_quote")

;;;; ================================================================
;;;; 1. SINGLE-EDIT ISOLATION
;;;; ================================================================

(describe "Edit isolation: single edit on MD source"

  (it "editing first heading changes only block 0"
    (let* ((src prisma-iso--md5)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("Heading Alpha" . "Heading Modified")))))
      (expect res :to-equal
              "# Heading Modified\n\nParagraph bravo content\n\n## Heading Charlie\n\nParagraph delta content\n\nParagraph echo content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0))))

  (it "editing middle paragraph changes only block 1"
    (let* ((src prisma-iso--md5)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("bravo content" . "bravo modified")))))
      (expect res :to-equal
              "# Heading Alpha\n\nParagraph bravo modified\n\n## Heading Charlie\n\nParagraph delta content\n\nParagraph echo content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(1))))

  (it "editing last paragraph changes only block 4"
    (let* ((src prisma-iso--md5)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("echo content" . "echo modified")))))
      (expect res :to-equal
              "# Heading Alpha\n\nParagraph bravo content\n\n## Heading Charlie\n\nParagraph delta content\n\nParagraph echo modified")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(4))))

  (it "editing code block body changes only block 2"
    (let* ((src prisma-iso--md7)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("x = 42" . "x = 99")))))
      (expect res :to-equal
              "# Main Title\n\nFirst paragraph here\n\n```python\nx = 99\n```\n\n- item one\n- item two\n\n## Section Two\n\nSecond paragraph here\n\n> A notable quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(2))))

  (it "editing list item changes only block 3"
    (let* ((src prisma-iso--md7)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("item one" . "item modified")))))
      (expect res :to-equal
              "# Main Title\n\nFirst paragraph here\n\n```python\nx = 42\n```\n\n- item modified\n- item two\n\n## Section Two\n\nSecond paragraph here\n\n> A notable quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(3))))

  (it "editing blockquote changes only block 6"
    (let* ((src prisma-iso--md7)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("A notable quote" . "A different quote")))))
      (expect res :to-equal
              "# Main Title\n\nFirst paragraph here\n\n```python\nx = 42\n```\n\n- item one\n- item two\n\n## Section Two\n\nSecond paragraph here\n\n> A different quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(6))))

  (it "editing h2 heading changes only block 4"
    (let* ((src prisma-iso--md7)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("Section Two" . "Section Modified")))))
      (expect res :to-equal
              "# Main Title\n\nFirst paragraph here\n\n```python\nx = 42\n```\n\n- item one\n- item two\n\n## Section Modified\n\nSecond paragraph here\n\n> A notable quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(4))))

  (it "editing bold inside paragraph changes only that paragraph"
    (let* ((src "# Title\n\nText with **bold** and *italic* and `code` here\n\nAnother paragraph")
           (res (prisma-iso--run
                 #'markdown-mode src
                 ;; In Org mirror bold is *bold*
                 (prisma-iso--replace '("*bold*" . "*stronger*")))))
      (expect res :to-equal
              "# Title\n\nText with **stronger** and *italic* and `code` here\n\nAnother paragraph")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(1)))))

(describe "Edit isolation: single edit on Org source"

  (it "editing heading changes only block 0"
    (let* ((src prisma-iso--org5)
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace '("Heading Foxtrot" . "Heading Modified")))))
      (expect res :to-equal
              "* Heading Modified\n\nParagraph golf content\n\n** Heading Hotel\n\nParagraph india content\n\nParagraph juliet content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0))))

  (it "editing middle paragraph changes only block 1"
    (let* ((src prisma-iso--org5)
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace '("golf content" . "golf modified")))))
      (expect res :to-equal
              "* Heading Foxtrot\n\nParagraph golf modified\n\n** Heading Hotel\n\nParagraph india content\n\nParagraph juliet content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(1))))

  (it "editing code block body changes only block 2"
    (let* ((src prisma-iso--org7)
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace '("y = 99" . "y = 100")))))
      (expect res :to-equal
              "* Top Heading\n\nOpening paragraph text\n\n#+begin_src python\ny = 100\n#+end_src\n\n- lima item\n- mike item\n\n** Lower Section\n\nClosing paragraph text\n\n#+begin_quote\nA memorable remark\n#+end_quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(2))))

  (it "editing blockquote changes only block 6"
    (let* ((src prisma-iso--org7)
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace '("A memorable remark" . "A changed remark")))))
      (expect res :to-equal
              "* Top Heading\n\nOpening paragraph text\n\n#+begin_src python\ny = 99\n#+end_src\n\n- lima item\n- mike item\n\n** Lower Section\n\nClosing paragraph text\n\n#+begin_quote\nA changed remark\n#+end_quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(6)))))

;;;; ================================================================
;;;; 2. MULTI-EDIT ISOLATION
;;;; ================================================================

(describe "Edit isolation: multiple edits on MD source"

  (it "two edits produce exactly 2 changed blocks"
    (let* ((src prisma-iso--md5)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace
                  '("Heading Alpha" . "Heading Modified")
                  '("delta content" . "delta modified")))))
      (expect res :to-equal
              "# Heading Modified\n\nParagraph bravo content\n\n## Heading Charlie\n\nParagraph delta modified\n\nParagraph echo content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 2)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0 3))))

  (it "editing first and last blocks leaves middle 3 intact"
    (let* ((src prisma-iso--md5)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace
                  '("Heading Alpha" . "Heading Modified")
                  '("echo content" . "echo modified")))))
      (expect res :to-equal
              "# Heading Modified\n\nParagraph bravo content\n\n## Heading Charlie\n\nParagraph delta content\n\nParagraph echo modified")
      (expect (prisma-iso--count-block-changes src res) :to-equal 2)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0 4))))

  (it "three edits in 7-block doc produce exactly 3 changed blocks"
    (let* ((src prisma-iso--md7)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace
                  '("Main Title" . "New Title")
                  '("x = 42" . "x = 99")
                  '("A notable quote" . "A modified quote")))))
      (expect res :to-equal
              "# New Title\n\nFirst paragraph here\n\n```python\nx = 99\n```\n\n- item one\n- item two\n\n## Section Two\n\nSecond paragraph here\n\n> A modified quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 3)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0 2 6)))))

(describe "Edit isolation: multiple edits on Org source"

  (it "two edits produce exactly 2 changed blocks"
    (let* ((src prisma-iso--org5)
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace
                  '("Heading Foxtrot" . "Heading Modified")
                  '("india content" . "india modified")))))
      (expect res :to-equal
              "* Heading Modified\n\nParagraph golf content\n\n** Heading Hotel\n\nParagraph india modified\n\nParagraph juliet content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 2)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0 3))))

  (it "three edits in 7-block doc produce exactly 3 changed blocks"
    (let* ((src prisma-iso--org7)
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace
                  '("Top Heading" . "New Heading")
                  '("lima item" . "lima changed")
                  '("A memorable remark" . "A changed remark")))))
      (expect res :to-equal
              "* New Heading\n\nOpening paragraph text\n\n#+begin_src python\ny = 99\n#+end_src\n\n- lima changed\n- mike item\n\n** Lower Section\n\nClosing paragraph text\n\n#+begin_quote\nA changed remark\n#+end_quote")
      (expect (prisma-iso--count-block-changes src res) :to-equal 3)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0 3 6)))))

;;;; ================================================================
;;;; 3. STRUCTURAL CHANGES: REORDERING
;;;; ================================================================

(describe "Structural: reordering"

  (it "swapping two adjacent sections preserves uninvolved blocks"
    (let* ((src "# Guide\n\n## Step One\n\nDo the first\n\n## Step Two\n\nDo the second\n\n## Step Three\n\nDo the third")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "** Step Two")
                   (beginning-of-line)
                   (org-metaup)))))
      ;; Step Two now before Step One
      (expect (string-match-p "Step Two" res) :to-be-truthy)
      (expect (string-match-p "Step One" res) :to-be-truthy)
      (expect (< (string-match "Step Two" res)
                 (string-match "Step One" res))
              :to-be-truthy)
      ;; Uninvolved blocks preserved at same positions
      (expect (prisma-iso--blocks-at res '(0))
              :to-equal (prisma-iso--blocks-at src '(0)))
      (expect (prisma-iso--blocks-at res '(5 6))
              :to-equal (prisma-iso--blocks-at src '(5 6)))
      ;; All original content present
      (expect (string-match-p "Do the first" res) :to-be-truthy)
      (expect (string-match-p "Do the second" res) :to-be-truthy)
      (expect (string-match-p "Do the third" res) :to-be-truthy)))

  (it "reordering preserves content of moved sections byte-identically"
    (let* ((src "# Guide\n\n## Step One\n\nDo the first\n\n## Step Two\n\nDo the second\n\n## Step Three\n\nDo the third")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "** Step Two")
                   (beginning-of-line)
                   (org-metaup))))
           (src-blocks (prisma-iso--split-blocks src))
           (res-blocks (prisma-iso--split-blocks res)))
      ;; Source blocks 1,2 (Step One + body) appear in result at 3,4
      (expect (nth 3 res-blocks) :to-equal (nth 1 src-blocks))
      (expect (nth 4 res-blocks) :to-equal (nth 2 src-blocks))
      ;; Source blocks 3,4 (Step Two + body) appear in result at 1,2
      (expect (nth 1 res-blocks) :to-equal (nth 3 src-blocks))
      (expect (nth 2 res-blocks) :to-equal (nth 4 src-blocks))))

  (it "reorder + edit: swap two nodes AND edit a third"
    (let* ((src "# Guide\n\n## Step One\n\nDo the first\n\n## Step Two\n\nDo the second\n\n## Step Three\n\nDo the third")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   ;; Reorder: move Step Two before Step One
                   (goto-char (point-min))
                   (search-forward "** Step Two")
                   (beginning-of-line)
                   (org-metaup)
                   ;; Edit: change Step Three content
                   (goto-char (point-min))
                   (search-forward "Do the third")
                   (replace-match "Do the third modified" t t)))))
      ;; Step Two before Step One
      (expect (< (string-match "Step Two" res)
                 (string-match "Step One" res))
              :to-be-truthy)
      ;; Edit applied
      (expect (string-match-p "Do the third modified" res) :to-be-truthy)
      ;; Guide heading preserved
      (expect (prisma-iso--blocks-at res '(0))
              :to-equal (list "# Guide"))))

  (it "Org source: swapping sections preserves uninvolved blocks"
    (let* ((src "* Guide\n\n** Step One\n\nDo the first\n\n** Step Two\n\nDo the second\n\n** Step Three\n\nDo the third")
           (res (prisma-iso--run
                 #'org-mode src
                 (lambda ()
                   ;; Mirror is MD. Reorder via cut/paste.
                   (let* ((s2-start (progn (goto-char (point-min))
                                           (search-forward "## Step Two")
                                           (beginning-of-line) (point)))
                          (s2-end (progn (search-forward "Do the second")
                                        (end-of-line) (point)))
                          (s2-text (buffer-substring s2-start s2-end)))
                     ;; Delete Step Two section (include preceding blank line)
                     (delete-region (- s2-start 2) s2-end)
                     ;; Insert before Step One
                     (goto-char (point-min))
                     (search-forward "## Step One")
                     (beginning-of-line)
                     (insert s2-text "\n\n"))))))
      ;; Step Two before Step One
      (expect (< (string-match "Step Two" res)
                 (string-match "Step One" res))
              :to-be-truthy)
      ;; Uninvolved blocks preserved
      (expect (prisma-iso--blocks-at res '(0))
              :to-equal (list "* Guide"))
      (expect (string-match-p "Do the third" res) :to-be-truthy))))

;;;; ================================================================
;;;; 4. STRUCTURAL CHANGES: INSERTION & DELETION
;;;; ================================================================

(describe "Structural: node insertion"

  (it "inserting new paragraph between existing ones preserves all originals"
    (let* ((src "# Heading\n\nParagraph one\n\nParagraph two\n\nParagraph three")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "Paragraph one")
                   (end-of-line)
                   (insert "\n\nInserted paragraph")))))
      (expect res :to-equal
              "# Heading\n\nParagraph one\n\nInserted paragraph\n\nParagraph two\n\nParagraph three")
      ;; Original content preserved
      (expect (string-match-p "# Heading" res) :to-be-truthy)
      (expect (string-match-p "Paragraph one" res) :to-be-truthy)
      (expect (string-match-p "Paragraph two" res) :to-be-truthy)
      (expect (string-match-p "Paragraph three" res) :to-be-truthy)))

  (it "inserting new heading creates correct MD syntax"
    (let* ((src "# Main\n\nSome content\n\nMore content")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "Some content")
                   (end-of-line)
                   (insert "\n\n** New Section")))))
      (expect res :to-equal
              "# Main\n\nSome content\n\n## New Section\n\nMore content")
      ;; Original blocks preserved
      (expect (string-match-p "# Main" res) :to-be-truthy)
      (expect (string-match-p "Some content" res) :to-be-truthy)
      (expect (string-match-p "More content" res) :to-be-truthy)))

  (it "inserting in Org source doc preserves all originals"
    (let* ((src "* Heading\n\nParagraph one\n\nParagraph two")
           (res (prisma-iso--run
                 #'org-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "Paragraph one")
                   (end-of-line)
                   (insert "\n\nInserted paragraph")))))
      (expect res :to-equal
              "* Heading\n\nParagraph one\n\nInserted paragraph\n\nParagraph two")
      (expect (string-match-p "\\* Heading" res) :to-be-truthy)
      (expect (string-match-p "Paragraph one" res) :to-be-truthy)
      (expect (string-match-p "Paragraph two" res) :to-be-truthy))))

(describe "Structural: node deletion"

  (it "deleting a middle paragraph preserves surrounding blocks"
    (let* ((src "# Heading\n\nParagraph one\n\nParagraph two\n\nParagraph three")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "\n\nParagraph two")
                   (replace-match "" t t)))))
      (expect res :to-equal
              "# Heading\n\nParagraph one\n\nParagraph three")
      (let ((blocks (prisma-iso--split-blocks res)))
        (expect (nth 0 blocks) :to-equal "# Heading")
        (expect (nth 1 blocks) :to-equal "Paragraph one")
        (expect (nth 2 blocks) :to-equal "Paragraph three"))))

  (it "deleting a heading+body preserves surrounding blocks"
    (let* ((src "# Main\n\n## Section One\n\nContent one\n\n## Section Two\n\nContent two")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "\n\n** Section One\n\nContent one")
                   (replace-match "" t t)))))
      (expect res :to-equal
              "# Main\n\n## Section Two\n\nContent two")
      (let ((blocks (prisma-iso--split-blocks res)))
        (expect (nth 0 blocks) :to-equal "# Main")
        (expect (nth 1 blocks) :to-equal "## Section Two")
        (expect (nth 2 blocks) :to-equal "Content two"))))

  (it "deleting in Org source doc preserves surrounding blocks"
    (let* ((src "* Heading\n\nParagraph one\n\nParagraph two\n\nParagraph three")
           (res (prisma-iso--run
                 #'org-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "\n\nParagraph two")
                   (replace-match "" t t)))))
      (expect res :to-equal
              "* Heading\n\nParagraph one\n\nParagraph three"))))

;;;; ================================================================
;;;; 5. BOUNDARY-CROSSING AND EDGE CASES
;;;; ================================================================

(describe "Boundary: editing at buffer extremes"

  (it "inserting text at the very beginning of the buffer"
    (let* ((src "# Heading\n\nContent here")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (insert "Prepended text\n\n")))))
      (expect res :to-equal
              "Prepended text\n\n# Heading\n\nContent here")
      ;; Original blocks preserved
      (expect (string-match-p "# Heading" res) :to-be-truthy)
      (expect (string-match-p "Content here" res) :to-be-truthy)))

  (it "appending text at the very end of the buffer"
    (let* ((src "# Heading\n\nContent here")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-max))
                   (insert "\n\nAppended text")))))
      (expect res :to-equal
              "# Heading\n\nContent here\n\nAppended text")
      ;; Original blocks preserved
      (expect (string-match-p "# Heading" res) :to-be-truthy)
      (expect (string-match-p "Content here" res) :to-be-truthy))))

(describe "Boundary: merging and splitting nodes"

  (it "merging two paragraphs by deleting blank line"
    (let* ((src "# Heading\n\nParagraph one\n\nParagraph two\n\nParagraph three")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "Paragraph one\n\nParagraph two")
                   (replace-match "Paragraph one\nParagraph two" t t)))))
      (expect res :to-equal
              "# Heading\n\nParagraph one\nParagraph two\n\nParagraph three")
      ;; Heading and third paragraph preserved
      (expect (nth 0 (prisma-iso--split-blocks res))
              :to-equal "# Heading")
      (expect (nth 2 (prisma-iso--split-blocks res))
              :to-equal "Paragraph three")))

  (it "splitting a paragraph by inserting a heading"
    (let* ((src "# Main\n\nFirst part. Second part.\n\nFinal paragraph")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (lambda ()
                   (goto-char (point-min))
                   (search-forward "First part. Second part.")
                   (replace-match "First part.\n\n** New Section\n\nSecond part." t t)))))
      (expect res :to-equal
              "# Main\n\nFirst part.\n\n## New Section\n\nSecond part.\n\nFinal paragraph")
      ;; Surrounding blocks preserved
      (expect (nth 0 (prisma-iso--split-blocks res))
              :to-equal "# Main")
      (expect (car (last (prisma-iso--split-blocks res)))
              :to-equal "Final paragraph"))))

(describe "Boundary: line-count changes within a node"

  (it "adding lines to a paragraph preserves other blocks"
    (let* ((src "# Heading\n\nShort line\n\nAnother paragraph")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace
                  '("Short line" . "First line\nSecond line\nThird line")))))
      (expect res :to-equal
              "# Heading\n\nFirst line\nSecond line\nThird line\n\nAnother paragraph")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(1))))

  (it "adding lines to code block body preserves other blocks"
    (let* ((src "# Title\n\n```python\nline1\n```\n\nAfter code")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("line1" . "line1\nline2\nline3")))))
      (expect res :to-equal
              "# Title\n\n```python\nline1\nline2\nline3\n```\n\nAfter code")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(1)))))

(describe "Boundary: single character and minimal edits"

  (it "single character change in large doc affects only one block"
    (let* ((src prisma-iso--md7)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("First paragraph here" . "First paragraph hare")))))
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(1))))

  (it "appending one character to heading affects only that block"
    (let* ((src prisma-iso--md5)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("Heading Alpha" . "Heading Alpha!")))))
      (expect res :to-equal
              "# Heading Alpha!\n\nParagraph bravo content\n\n## Heading Charlie\n\nParagraph delta content\n\nParagraph echo content")
      (expect (prisma-iso--count-block-changes src res) :to-equal 1)
      (expect (prisma-iso--changed-block-indices src res) :to-equal '(0)))))

;;;; ================================================================
;;;; 6. WHITESPACE PRESERVATION (inter-block spacing)
;;;; ================================================================

;; Source with non-standard whitespace: triple and quadruple newlines
(defvar prisma-iso--md-varied-ws
  "# Title\n\nSome intro text.\n\n\n## Section One\n\nContent of section one.\n\n\n\n## Section Two\n\nContent of section two."
  "MD source with varied inter-block whitespace (2, 3, and 4 newlines).")

(describe "Whitespace preservation: single edit must not alter inter-block spacing"

  (it "single edit in doc with triple-newline gap: exactly 1 line differs"
    (let* ((src prisma-iso--md-varied-ws)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("section one" . "section modified")))))
      (expect (length (split-string res "\n"))
              :to-equal (length (split-string src "\n")))
      (expect (prisma-iso--count-line-diffs src res) :to-equal 1)))

  (it "single edit preserves exact byte content outside the changed node"
    (let* ((src prisma-iso--md-varied-ws)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("section one" . "section modified")))))
      ;; Everything before "Content of section" must be byte-identical
      (let ((prefix-end (string-match "Content of section" src)))
        (expect (substring res 0 prefix-end)
                :to-equal (substring src 0 prefix-end)))
      ;; Everything after the changed line must be byte-identical
      (let* ((case-fold-search nil)
             (suffix-start-src (+ (string-match "section one" src) (length "section one")))
             (suffix-start-res (+ (string-match "section modified" res) (length "section modified"))))
        (expect (substring res suffix-start-res)
                :to-equal (substring src suffix-start-src)))))

  (it "editing last block preserves all preceding whitespace"
    (let* ((src "# Heading\n\n\nMiddle paragraph\n\n\n\nLast paragraph")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("Last paragraph" . "Last CHANGED")))))
      (expect (prisma-iso--count-line-diffs src res) :to-equal 1)
      ;; Everything before "Last" must match
      (let ((pre (string-match "Last" src)))
        (expect (substring res 0 pre) :to-equal (substring src 0 pre)))))

  (it "editing first block preserves all following whitespace"
    (let* ((src "# Original Heading\n\n\nMiddle paragraph\n\n\n\nLast paragraph")
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace '("Original Heading" . "Changed Heading")))))
      ;; Only the heading line should differ
      (expect (prisma-iso--count-line-diffs src res) :to-equal 1)
      ;; Everything after the heading line must match
      (let ((suffix-src (string-match "\n" src))
            (suffix-res (string-match "\n" res)))
        (expect (substring res suffix-res) :to-equal (substring src suffix-src)))))

  (it "two edits in doc with varied whitespace: exactly 2 lines differ"
    (let* ((src prisma-iso--md-varied-ws)
           (res (prisma-iso--run
                 #'markdown-mode src
                 (prisma-iso--replace
                  '("intro text" . "intro CHANGED")
                  '("section two" . "section CHANGED")))))
      (expect (length (split-string res "\n"))
              :to-equal (length (split-string src "\n")))
      (expect (prisma-iso--count-line-diffs src res) :to-equal 2)))

  (it "Org source with varied whitespace: single edit preserves spacing"
    (let* ((src "* Title\n\nSome intro text.\n\n\n** Section One\n\nContent of section one.\n\n\n\n** Section Two\n\nContent of section two.")
           (res (prisma-iso--run
                 #'org-mode src
                 (prisma-iso--replace '("section one" . "section modified")))))
      (expect (length (split-string res "\n"))
              :to-equal (length (split-string src "\n")))
      (expect (prisma-iso--count-line-diffs src res) :to-equal 1))))

;;; prisma-isolation-tests.el ends here
