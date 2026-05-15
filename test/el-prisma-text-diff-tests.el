;;; el-prisma-text-diff-tests.el --- Tests for commit pipeline primitives -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Unit tests for render-with-map and the unified commit primitives:
;; scan-property-intervals, match-nodes, build-unified-replacement.
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

;;;; scan-property-intervals

(describe "el-prisma--scan-property-intervals"

  (it "returns segments for a propertized buffer"
    (with-temp-buffer
      (insert "AAABBBCCC")
      (put-text-property 1 4 'el-prisma-node-idx 0)
      (put-text-property 4 7 'el-prisma-node-idx 1)
      (put-text-property 7 10 'el-prisma-node-idx 2)
      (let ((segs (el-prisma--scan-property-intervals)))
        (expect (length segs) :to-equal 3)
        ;; Each segment has the correct idx
        (expect (nth 2 (nth 0 segs)) :to-equal 0)
        (expect (nth 2 (nth 1 segs)) :to-equal 1)
        (expect (nth 2 (nth 2 segs)) :to-equal 2))))

  (it "detects nil-property gaps between nodes"
    (with-temp-buffer
      (insert "AAA--BBB")
      (put-text-property 1 4 'el-prisma-node-idx 0)
      ;; positions 4-6 have no property (the "--" gap)
      (put-text-property 6 9 'el-prisma-node-idx 1)
      (let ((segs (el-prisma--scan-property-intervals)))
        (expect (length segs) :to-equal 3)
        (expect (nth 2 (nth 0 segs)) :to-equal 0)
        (expect (nth 2 (nth 1 segs)) :to-be nil)
        (expect (nth 2 (nth 2 segs)) :to-equal 1))))

  (it "handles buffer with no properties"
    (with-temp-buffer
      (insert "plain text")
      (let ((segs (el-prisma--scan-property-intervals)))
        (expect (length segs) :to-equal 1)
        (expect (nth 2 (car segs)) :to-be nil)))))

;;;; match-nodes

(describe "el-prisma--match-nodes"

  (it "matches nodes with single-idx property regions"
    (with-temp-buffer
      (insert "AAABBB")
      (put-text-property 1 4 'el-prisma-node-idx 0)
      (put-text-property 4 7 'el-prisma-node-idx 1)
      (let* ((segs (el-prisma--scan-property-intervals))
             ;; Simulate two AST nodes covering the same ranges (0-based string)
             (children (list (list :type 'paragraph :start 0 :end 3)
                             (list :type 'paragraph :start 3 :end 6)))
             (matches (el-prisma--match-nodes children "AAABBB" segs)))
        (expect (aref matches 0) :to-equal 0)
        (expect (aref matches 1) :to-equal 1))))

  (it "returns nil for nodes in nil-property regions"
    (with-temp-buffer
      (insert "AAANEWNEWBBB")
      (put-text-property 1 4 'el-prisma-node-idx 0)
      ;; 4-10 is new text with no property
      (put-text-property 10 13 'el-prisma-node-idx 1)
      (let* ((segs (el-prisma--scan-property-intervals))
             (children (list (list :type 'paragraph :start 0 :end 3)
                             (list :type 'paragraph :start 3 :end 9)
                             (list :type 'paragraph :start 9 :end 12)))
             (matches (el-prisma--match-nodes children "AAANEWNEWBBB" segs)))
        (expect (aref matches 0) :to-equal 0)
        (expect (aref matches 1) :to-be nil) ; new content
        (expect (aref matches 2) :to-equal 1))))

  (it "resolves conflicts when multiple nodes claim same old-idx"
    (with-temp-buffer
      (insert "AAABBB")
      ;; Both regions have the same node-idx (simulating a split)
      (put-text-property 1 4 'el-prisma-node-idx 0)
      (put-text-property 4 7 'el-prisma-node-idx 0)
      (let* ((segs (el-prisma--scan-property-intervals))
             (children (list (list :type 'paragraph :start 0 :end 3)
                             (list :type 'paragraph :start 3 :end 6)))
             (matches (el-prisma--match-nodes children "AAABBB" segs)))
        ;; Both should be nil (conflict)
        (expect (aref matches 0) :to-be nil)
        (expect (aref matches 1) :to-be nil))))

  (it "handles mixed property regions within a node"
    (with-temp-buffer
      (insert "AAABBB")
      (put-text-property 1 3 'el-prisma-node-idx 0)
      (put-text-property 3 5 'el-prisma-node-idx 1)
      (put-text-property 5 7 'el-prisma-node-idx 2)
      (let* ((segs (el-prisma--scan-property-intervals))
             ;; One node spanning across properties 0 and 1
             (children (list (list :type 'paragraph :start 0 :end 4)
                             (list :type 'paragraph :start 4 :end 6)))
             (matches (el-prisma--match-nodes children "AAABBB" segs)))
        ;; First node has mixed properties -> nil
        (expect (aref matches 0) :to-be nil)
        (expect (aref matches 1) :to-equal 2)))))

;;;; build-unified-replacement

(describe "el-prisma--build-unified-replacement"

  (it "uses original source bytes for unchanged nodes"
    (let* ((children (list (list :type 'heading :start 0 :end 7)
                           (list :type 'paragraph :start 9 :end 19)))
           (mirror-text "* Title\n\nBody text.")
           (matches (vector 0 1))
           ;; Original source/mirror texts for the 2 nodes
           (source-texts (vector "# Title" "Body text."))
           (mirror-texts (vector "* Title" "Body text."))
           (result (el-prisma--build-unified-replacement
                    children mirror-text matches
                    source-texts mirror-texts 'markdown 'org)))
      ;; Both unchanged -> uses original source bytes joined with \n\n
      (expect result :to-equal "# Title\n\nBody text.")))

  (it "re-renders changed nodes while preserving unchanged ones"
    (let* ((children (list (list :type 'heading :start 0 :end 7)
                           (list :type 'paragraph :start 9 :end 19)))
           (mirror-text "* Title\n\nNew text!!")
           (matches (vector 0 1))
           (source-texts (vector "# Title" "Body text."))
           (mirror-texts (vector "* Title" "Body text."))
           (result (el-prisma--build-unified-replacement
                    children mirror-text matches
                    source-texts mirror-texts 'markdown 'org)))
      ;; Heading unchanged (original source), paragraph re-rendered
      (expect result :to-match "^# Title\n\n")
      (expect result :to-match "New text!!")))

  (it "handles unmatched (new) nodes"
    (let* ((children (list (list :type 'heading :start 0 :end 7)
                           (list :type 'paragraph :start 9 :end 22)
                           (list :type 'paragraph :start 24 :end 34)))
           (mirror-text "* Title\n\nNew paragraph\n\nBody text.")
           (matches (vector 0 nil 1))
           (source-texts (vector "# Title" "Body text."))
           (mirror-texts (vector "* Title" "Body text."))
           (result (el-prisma--build-unified-replacement
                    children mirror-text matches
                    source-texts mirror-texts 'markdown 'org)))
      ;; Heading and last paragraph from source, middle is new
      (expect result :to-match "^# Title")
      (expect result :to-match "New paragraph")
      (expect result :to-match "Body text\\.$"))))

;;;; el-prisma--same-structure-p

(describe "el-prisma--same-structure-p"

  (it "returns t for identity mapping [0 1 2] with n=3"
    (expect (el-prisma--same-structure-p (vector 0 1 2) 3)
            :to-be-truthy))

  (it "returns nil when a match is nil"
    (expect (el-prisma--same-structure-p (vector 0 nil 2) 3)
            :not :to-be-truthy))

  (it "returns nil for reordered matches [1 0 2]"
    (expect (el-prisma--same-structure-p (vector 1 0 2) 3)
            :not :to-be-truthy))

  (it "returns nil when length mismatches num-old-nodes"
    (expect (el-prisma--same-structure-p (vector 0 1) 3)
            :not :to-be-truthy)
    (expect (el-prisma--same-structure-p (vector 0 1 2 3) 3)
            :not :to-be-truthy))

  (it "returns t for empty matches with n=0"
    (expect (el-prisma--same-structure-p (vector) 0)
            :to-be-truthy)))

;;;; el-prisma--patch-in-place

(describe "el-prisma--patch-in-place"

  (it "returns source-text unchanged when no node text differs"
    (let* ((src "Hello world.")
           (src-node (list :type 'paragraph :start 0 :end 12))
           (render-map (list (list 0 src-node 0 12)))
           (matches (vector 0))
           (new-child (list :type 'paragraph :start 0 :end 12))
           (mirror "Hello world.")
           (mirror-texts (vector "Hello world.")))
      (expect (el-prisma--patch-in-place
               src render-map matches
               (list new-child) mirror
               mirror-texts 'markdown 'org)
              :to-equal src)))

  (it "patches only the changed node, preserving surrounding bytes"
    ;; Source: two nodes separated by triple newline
    (let* ((src "# First\n\n\nSecond para.")
           (node0 (list :type 'heading :start 0 :end 7))
           (node1 (list :type 'paragraph :start 10 :end 22))
           (render-map (list (list 0 node0 0 9)
                             (list 1 node1 11 23)))
           (matches (vector 0 1))
           ;; Mirror: node0 unchanged, node1 edited
           (mirror "* First\n\nChanged para.")
           (new0 (list :type 'heading :start 0 :end 7))
           (new1 (list :type 'paragraph :start 9 :end 22))
           (mirror-texts (vector "* First" "Second para."))
           (result (el-prisma--patch-in-place
                    src render-map matches
                    (list new0 new1) mirror
                    mirror-texts 'markdown 'org)))
      ;; Prefix up to node1 (including triple newline) preserved
      (expect (substring result 0 10) :to-equal "# First\n\n\n")
      ;; Changed node replaced
      (expect result :to-match "Changed para\\.")
      ;; Overall: only the node1 range changed
      (expect (substring result 0 (length "# First\n\n\n"))
              :to-equal (substring src 0 (length "# First\n\n\n")))))

  (it "preserves varied whitespace in multi-node document"
    ;; Source: "# Title\n\nIntro.\n\n\n## Sec1\n\nBody1.\n\n\n\n## Sec2\n\nBody2."
    ;; Offsets: # Title=0..7, \n\n, Intro.=9..15, \n\n\n,
    ;;          ## Sec1=18..25, \n\n, Body1.=27..33, \n\n\n\n,
    ;;          ## Sec2=37..44, \n\n, Body2.=46..52
    ;; Edit "Body1." -> "CHANGED." in node3
    (let* ((src "# Title\n\nIntro.\n\n\n## Sec1\n\nBody1.\n\n\n\n## Sec2\n\nBody2.")
           (n0 (list :type 'h :start 0 :end 7))
           (n1 (list :type 'p :start 9 :end 15))
           (n2 (list :type 'h :start 18 :end 25))
           (n3 (list :type 'p :start 27 :end 33))
           (n4 (list :type 'h :start 37 :end 44))
           (n5 (list :type 'p :start 46 :end 52))
           (rmap (list (list 0 n0 0 7) (list 1 n1 9 15)
                       (list 2 n2 17 24) (list 3 n3 26 32)
                       (list 4 n4 34 41) (list 5 n5 43 49)))
           (matches (vector 0 1 2 3 4 5))
           ;; Mirror: "* Title\n\nIntro.\n\n** Sec1\n\nCHANGED.\n\n** Sec2\n\nBody2."
           ;; Offsets: * Title=0..7, \n\n, Intro.=9..15, \n\n,
           ;;          ** Sec1=17..24, \n\n, CHANGED.=26..34, \n\n,
           ;;          ** Sec2=36..43, \n\n, Body2.=45..51
           (mirror "* Title\n\nIntro.\n\n** Sec1\n\nCHANGED.\n\n** Sec2\n\nBody2.")
           (m0 (list :type 'h :start 0 :end 7))
           (m1 (list :type 'p :start 9 :end 15))
           (m2 (list :type 'h :start 17 :end 24))
           (m3 (list :type 'p :start 26 :end 34))
           (m4 (list :type 'h :start 36 :end 43))
           (m5 (list :type 'p :start 45 :end 51))
           (mtexts (vector "* Title" "Intro." "** Sec1" "Body1." "** Sec2" "Body2."))
           (result (el-prisma--patch-in-place
                    src rmap matches
                    (list m0 m1 m2 m3 m4 m5) mirror
                    mtexts 'markdown 'org)))
      ;; Same line count (CHANGED. has no newlines, same as Body1.)
      (expect (length (split-string result "\n"))
              :to-equal (length (split-string src "\n")))
      ;; Everything before the changed node byte-identical
      (expect (substring result 0 27) :to-equal (substring src 0 27))
      ;; Everything after the changed node byte-identical
      (let ((suffix-start-src 33)
            (suffix-start-res (+ 27 (length "CHANGED."))))
        (expect (substring result suffix-start-res)
                :to-equal (substring src suffix-start-src)))))

  (it "applies two patches in reverse order without offset corruption"
    (let* ((src "# A\n\n\nB text.\n\n\n\nC text.")
           (n0 (list :type 'h :start 0 :end 3))
           (n1 (list :type 'p :start 6 :end 13))
           (n2 (list :type 'p :start 17 :end 24))
           (rmap (list (list 0 n0 0 3) (list 1 n1 5 14)
                       (list 2 n2 16 25)))
           (matches (vector 0 1 2))
           (mirror "* A\n\nB NEW.\n\nC NEW.")
           (m0 (list :type 'h :start 0 :end 3))
           (m1 (list :type 'p :start 5 :end 11))
           (m2 (list :type 'p :start 13 :end 19))
           (mtexts (vector "* A" "B text." "C text."))
           (result (el-prisma--patch-in-place
                    src rmap matches
                    (list m0 m1 m2) mirror
                    mtexts 'markdown 'org)))
      ;; Prefix preserved
      (expect (substring result 0 6) :to-equal "# A\n\n\n")
      ;; Both nodes replaced
      (expect result :to-match "B NEW\\.")
      (expect result :to-match "C NEW\\.")
      ;; Triple and quadruple newlines preserved between blocks
      (expect result :to-match "\n\n\n[^\n]")
      (expect result :to-match "\n\n\n\n[^\n]"))))

(provide 'el-prisma-text-diff-tests)
;;; el-prisma-text-diff-tests.el ends here
