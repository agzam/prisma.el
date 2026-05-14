;;; el-prisma-text-diff-tests.el --- Tests for text-diff commit pipeline -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Unit tests for the text-diff primitives: render-with-map,
;; text-diff-changed-lines, lines-to-byte-range, find-changed-nodes,
;; merge-adjacent-nodes, and build-patch-ops.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma)
(require 'el-prisma-model)

;;;; render-with-map

(describe "el-prisma-render-with-map"

  (it "returns rendered text and map as cons"
    (let* ((ast (el-prisma-model-node
                 'document
                 :children (list (el-prisma-model-paragraph
                                  :children (list (el-prisma-model-text :value "Hello."))
                                  :start 0 :end 6))))
           (result (el-prisma-render-with-map 'org ast)))
      (expect (consp result) :to-be-truthy)
      (expect (stringp (car result)) :to-be-truthy)
      (expect (listp (cdr result)) :to-be-truthy)))

  (it "map entries match rendered text boundaries"
    (let* ((ast (el-prisma-model-node
                 'document
                 :children (list
                            (el-prisma-model-heading
                             :level 1
                             :children (list (el-prisma-model-text :value "Title"))
                             :start 0 :end 8)
                            (el-prisma-model-paragraph
                             :children (list (el-prisma-model-text :value "Body text."))
                             :start 10 :end 20))))
           (result (el-prisma-render-with-map 'org ast))
           (text (car result))
           (rmap (cdr result)))
      ;; Each map entry's [start, end) should extract that node's rendered text
      (dolist (entry rmap)
        (let ((mstart (nth 2 entry))
              (mend (nth 3 entry)))
          (expect (<= mstart mend) :to-be-truthy)
          (expect (<= mend (length text)) :to-be-truthy)
          ;; Extracted substring should be non-empty
          (expect (length (substring text mstart mend)) :to-be-greater-than 0)))))

  (it "map covers heading, paragraph, code block"
    (let* ((ast (el-prisma-model-node
                 'document
                 :children (list
                            (el-prisma-model-heading
                             :level 2
                             :children (list (el-prisma-model-text :value "Section"))
                             :start 0 :end 12)
                            (el-prisma-model-paragraph
                             :children (list (el-prisma-model-text :value "Some text."))
                             :start 14 :end 24)
                            (el-prisma-model-code-block
                             :language "python" :body "pass"
                             :start 26 :end 46))))
           (result (el-prisma-render-with-map 'org ast))
           (text (car result))
           (rmap (cdr result)))
      (expect (length rmap) :to-equal 3)
      ;; Index order
      (expect (nth 0 (nth 0 rmap)) :to-equal 0)
      (expect (nth 0 (nth 1 rmap)) :to-equal 1)
      (expect (nth 0 (nth 2 rmap)) :to-equal 2)
      ;; Heading rendered as Org
      (expect (substring text
                         (nth 2 (nth 0 rmap))
                         (nth 3 (nth 0 rmap)))
              :to-match "^\\*\\* Section")
      ;; Paragraph text
      (expect (substring text
                         (nth 2 (nth 1 rmap))
                         (nth 3 (nth 1 rmap)))
              :to-match "Some text")
      ;; Code block
      (expect (substring text
                         (nth 2 (nth 2 rmap))
                         (nth 3 (nth 2 rmap)))
              :to-match "begin_src")))

  (it "map entries are contiguous (no gaps or overlaps)"
    (let* ((ast (el-prisma-model-node
                 'document
                 :children (list
                            (el-prisma-model-heading
                             :level 1
                             :children (list (el-prisma-model-text :value "A"))
                             :start 0 :end 4)
                            (el-prisma-model-paragraph
                             :children (list (el-prisma-model-text :value "B"))
                             :start 6 :end 8)
                            (el-prisma-model-paragraph
                             :children (list (el-prisma-model-text :value "C"))
                             :start 10 :end 12))))
           (result (el-prisma-render-with-map 'org ast))
           (text (car result))
           (rmap (cdr result)))
      ;; First entry starts at 0
      (expect (nth 2 (nth 0 rmap)) :to-equal 0)
      ;; Last entry ends at text length
      (expect (nth 3 (car (last rmap))) :to-equal (length text))
      ;; Each entry starts where the previous ended (plus separator)
      (cl-loop for i from 1 below (length rmap)
               for prev = (nth (1- i) rmap)
               for curr = (nth i rmap)
               ;; Current start >= previous end (separator may be between)
               do (expect (>= (nth 2 curr) (nth 3 prev)) :to-be-truthy))))

  (it "handles single-node document"
    (let* ((ast (el-prisma-model-node
                 'document
                 :children (list
                            (el-prisma-model-paragraph
                             :children (list (el-prisma-model-text :value "Only."))
                             :start 0 :end 5))))
           (result (el-prisma-render-with-map 'org ast))
           (text (car result))
           (rmap (cdr result)))
      (expect (length rmap) :to-equal 1)
      (expect (nth 2 (car rmap)) :to-equal 0)
      (expect (nth 3 (car rmap)) :to-equal (length text))))

  (it "handles table node"
    (let* ((ast (el-prisma-model-node
                 'document
                 :children (list
                            (el-prisma-model-node
                             'table
                             :start 0 :end 30
                             :props '(:header ("A" "B")
                                      :rows (("1" "2")))))))
           (result (el-prisma-render-with-map 'org ast))
           (rmap (cdr result)))
      ;; Table node produces a render map entry regardless of rendered content
      (expect (length rmap) :to-equal 1)
      (expect (nth 0 (car rmap)) :to-equal 0))))

;;;; text-diff-changed-lines

(describe "el-prisma--text-diff-changed-lines"

  (it "detects no changes for identical text"
    (let ((text "line one\nline two\nline three"))
      (expect (el-prisma--text-diff-changed-lines text text) :to-equal nil)))

  (it "detects single changed line"
    (expect (el-prisma--text-diff-changed-lines
             "aaa\nbbb\nccc"
             "aaa\nBBB\nccc")
            :to-equal '(1)))

  (it "detects multiple changed lines"
    (expect (el-prisma--text-diff-changed-lines
             "aaa\nbbb\nccc\nddd"
             "AAA\nbbb\nCCC\nddd")
            :to-equal '(0 2)))

  (it "detects added lines at end"
    (expect (el-prisma--text-diff-changed-lines
             "aaa\nbbb"
             "aaa\nbbb\nccc")
            :to-equal '(2)))

  (it "detects removed lines at end"
    (expect (el-prisma--text-diff-changed-lines
             "aaa\nbbb\nccc"
             "aaa\nbbb")
            :to-equal '(2)))

  (it "detects both changed and added lines"
    (expect (el-prisma--text-diff-changed-lines
             "aaa\nbbb"
             "AAA\nbbb\nccc\nddd")
            :to-equal '(0 2 3)))

  (it "handles empty strings"
    (expect (el-prisma--text-diff-changed-lines "" "") :to-equal nil))

  (it "handles entirely different text"
    (expect (el-prisma--text-diff-changed-lines
             "aaa\nbbb" "xxx\nyyy")
            :to-equal '(0 1))))

;;;; lines-to-byte-range

(describe "el-prisma--lines-to-byte-range"

  (it "returns nil for empty indices"
    (expect (el-prisma--lines-to-byte-range "aaa\nbbb" nil) :to-be nil))

  (it "returns byte range for single line"
    ;; "aaa\nbbb\nccc" -> line 1 = "bbb" at bytes 4..7 (plus newline = 8)
    (let ((range (el-prisma--lines-to-byte-range "aaa\nbbb\nccc" '(1))))
      (expect (car range) :to-equal 4)
      (expect (cdr range) :to-equal 8)))

  (it "returns byte range for first line"
    (let ((range (el-prisma--lines-to-byte-range "aaa\nbbb\nccc" '(0))))
      (expect (car range) :to-equal 0)
      (expect (cdr range) :to-equal 4)))

  (it "returns byte range spanning multiple lines"
    ;; lines 0 and 2 -> should cover from start of line 0 to end of line 2
    (let ((range (el-prisma--lines-to-byte-range "aaa\nbbb\nccc" '(0 2))))
      (expect (car range) :to-equal 0)
      ;; End of line 2: "ccc" is 3 chars at offset 8, so 8+3+1=12, but
      ;; clamped to text length 11
      (expect (cdr range) :to-equal 11)))

  (it "returns range for last line"
    ;; "aaa\nbbb" = 7 chars, line 1 starts at 4
    (let ((range (el-prisma--lines-to-byte-range "aaa\nbbb" '(1))))
      (expect (car range) :to-equal 4)
      ;; 4 + 3 + 1 = 8, clamped to 7
      (expect (cdr range) :to-equal 7)))

  (it "handles single-line text"
    (let ((range (el-prisma--lines-to-byte-range "hello" '(0))))
      (expect (car range) :to-equal 0)
      (expect (cdr range) :to-equal 5))))

;;;; byte-pos-to-line

(describe "el-prisma--byte-pos-to-line"

  (it "returns 0 for position in first line"
    (expect (el-prisma--byte-pos-to-line "aaa\nbbb\nccc" 2) :to-equal 0))

  (it "returns 1 for position in second line"
    (expect (el-prisma--byte-pos-to-line "aaa\nbbb\nccc" 5) :to-equal 1))

  (it "returns 2 for position in third line"
    (expect (el-prisma--byte-pos-to-line "aaa\nbbb\nccc" 9) :to-equal 2))

  (it "returns 0 for position 0"
    (expect (el-prisma--byte-pos-to-line "aaa\nbbb" 0) :to-equal 0))

  (it "counts newline at exact newline position"
    ;; Position 3 is the newline itself in "aaa\nbbb"
    (expect (el-prisma--byte-pos-to-line "aaa\nbbb" 3) :to-equal 0)))

;;;; extract-lines

(describe "el-prisma--extract-lines"

  (it "extracts single line"
    (expect (el-prisma--extract-lines "aaa\nbbb\nccc" 1 1)
            :to-equal "bbb"))

  (it "extracts range of lines"
    (expect (el-prisma--extract-lines "aaa\nbbb\nccc\nddd" 1 2)
            :to-equal "bbb\nccc"))

  (it "extracts first line"
    (expect (el-prisma--extract-lines "aaa\nbbb" 0 0)
            :to-equal "aaa"))

  (it "extracts all lines"
    (expect (el-prisma--extract-lines "aaa\nbbb\nccc" 0 2)
            :to-equal "aaa\nbbb\nccc"))

  (it "clamps to available lines"
    (expect (el-prisma--extract-lines "aaa\nbbb" 0 5)
            :to-equal "aaa\nbbb")))

;;;; find-changed-nodes

(describe "el-prisma--find-changed-nodes"

  (it "returns nil for identical text"
    (let* ((render-map '((0 (:type heading :start 0 :end 8) 0 8)
                         (1 (:type paragraph :start 10 :end 20) 10 22)))
           (mirror "* Title\n\nBody text."))
      (expect (el-prisma--find-changed-nodes mirror mirror render-map)
              :to-be nil)))

  (it "identifies single changed node"
    (let* ((h-node (el-prisma-model-heading
                    :level 1
                    :children (list (el-prisma-model-text :value "Title"))
                    :start 0 :end 8))
           (p-node (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "Old text."))
                    :start 10 :end 20))
           (render-map (list (list 0 h-node 0 8)
                             (list 1 p-node 10 22)))
           (old-mirror "* Title\n\nOld text.")
           (new-mirror "* Title\n\nNew text."))
      (let ((result (el-prisma--find-changed-nodes
                     old-mirror new-mirror render-map)))
        (expect (length result) :to-equal 1)
        ;; Changed node is the paragraph
        (expect (el-prisma-model-type (caar result)) :to-equal 'paragraph))))

  (it "identifies multiple changed nodes"
    (let* ((h-node (el-prisma-model-heading
                    :level 1
                    :children (list (el-prisma-model-text :value "Old"))
                    :start 0 :end 6))
           (p-node (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "Old body."))
                    :start 8 :end 17))
           (render-map (list (list 0 h-node 0 6)
                             (list 1 p-node 8 17)))
           (old-mirror "* Old\n\nOld body.")
           (new-mirror "* New\n\nNew body."))
      (let ((result (el-prisma--find-changed-nodes
                     old-mirror new-mirror render-map)))
        (expect (length result) :to-equal 2))))

  (it "extracts correct edited text for changed node"
    (let* ((h-node (el-prisma-model-heading
                    :level 1
                    :children (list (el-prisma-model-text :value "Title"))
                    :start 0 :end 8))
           (p-node (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "Old word."))
                    :start 10 :end 20))
           (render-map (list (list 0 h-node 0 8)
                             (list 1 p-node 10 22)))
           (old-mirror "* Title\n\nOld word.")
           (new-mirror "* Title\n\nNew word."))
      (let ((result (el-prisma--find-changed-nodes
                     old-mirror new-mirror render-map)))
        ;; Extracted text should be from the new mirror
        (expect (cadr (car result)) :to-match "New word"))))

  (it "handles edit in first node"
    (let* ((h-node (el-prisma-model-heading
                    :level 1
                    :children (list (el-prisma-model-text :value "Old"))
                    :start 0 :end 6))
           (p-node (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "Keep."))
                    :start 8 :end 13))
           (render-map (list (list 0 h-node 0 6)
                             (list 1 p-node 8 13)))
           (old-mirror "* Old\n\nKeep.")
           (new-mirror "* New\n\nKeep."))
      (let ((result (el-prisma--find-changed-nodes
                     old-mirror new-mirror render-map)))
        (expect (length result) :to-equal 1)
        (expect (el-prisma-model-type (caar result)) :to-equal 'heading)))))

;;;; merge-adjacent-nodes

(describe "el-prisma--merge-adjacent-nodes"

  (it "returns nil for nil input"
    (expect (el-prisma--merge-adjacent-nodes nil) :to-be nil))

  (it "returns single group for single node"
    (let* ((node (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "X"))
                  :start 10 :end 20))
           (result (el-prisma--merge-adjacent-nodes
                    (list (list node "New text")))))
      (expect (length result) :to-equal 1)
      (expect (nth 0 (car result)) :to-equal 10)
      (expect (nth 1 (car result)) :to-equal 20)
      (expect (nth 2 (car result)) :to-equal "New text")))

  (it "merges adjacent nodes (gap < 4)"
    (let* ((n1 (el-prisma-model-paragraph :start 0 :end 10))
           (n2 (el-prisma-model-paragraph :start 12 :end 20))
           (result (el-prisma--merge-adjacent-nodes
                    (list (list n1 "Text A") (list n2 "Text B")))))
      (expect (length result) :to-equal 1)
      (expect (nth 0 (car result)) :to-equal 0)
      (expect (nth 1 (car result)) :to-equal 20)
      (expect (nth 2 (car result)) :to-match "Text A\n\nText B")))

  (it "keeps separate groups for distant nodes"
    (let* ((n1 (el-prisma-model-paragraph :start 0 :end 10))
           (n2 (el-prisma-model-paragraph :start 50 :end 60))
           (result (el-prisma--merge-adjacent-nodes
                    (list (list n1 "A") (list n2 "B")))))
      (expect (length result) :to-equal 2)
      (expect (nth 0 (car result)) :to-equal 0)
      (expect (nth 0 (cadr result)) :to-equal 50))))

;;;; build-patch-ops integration

(describe "el-prisma--build-patch-ops"

  (it "produces ops from changed nodes"
    (let* ((node (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "Old."))
                  :start 10 :end 14))
           (changed (list (list node "New paragraph.")))
           (ops (el-prisma--build-patch-ops changed 'markdown 'org)))
      (expect (length ops) :to-equal 1)
      (let ((op (car ops)))
        (expect (nth 0 op) :to-equal 10)
        (expect (nth 1 op) :to-equal 14)
        ;; Replacement should be the MD rendering of parsed Org
        (expect (stringp (nth 2 op)) :to-be-truthy)))))

;;;; apply-patch-ops

(describe "el-prisma--apply-patch-ops"

  (it "applies single replacement"
    (let ((result (el-prisma--apply-patch-ops
                   "aaaBBBccc"
                   '((3 6 "XXX")))))
      (expect result :to-equal "aaaXXXccc")))

  (it "applies multiple non-overlapping replacements"
    (let ((result (el-prisma--apply-patch-ops
                   "aaaBBBcccDDD"
                   '((3 6 "XX") (9 12 "YY")))))
      (expect result :to-equal "aaaXXcccYY")))

  (it "preserves trailing newline from original"
    (let ((result (el-prisma--apply-patch-ops
                   "old\n"
                   '((0 3 "new")))))
      (expect result :to-equal "new\n")))

  (it "preserves trailing newline count from original range"
    ;; Range [0,5) = "aaa\n\n" has two trailing newlines
    (let ((result (el-prisma--apply-patch-ops
                   "aaa\n\nbbb"
                   '((0 5 "XXX")))))
      (expect result :to-equal "XXX\n\nbbb")))

  (it "preserves trailing blank line at end of range"
    (let ((result (el-prisma--apply-patch-ops
                   "old content\n\nnext section"
                   '((0 13 "new content")))))
      ;; Original "old content\n\n" has \n\n, must preserve it
      (expect result :to-equal "new content\n\nnext section")))

  (it "returns text unchanged for empty ops"
    (expect (el-prisma--apply-patch-ops "hello" nil) :to-equal "hello")))

(provide 'el-prisma-text-diff-tests)
;;; el-prisma-text-diff-tests.el ends here
