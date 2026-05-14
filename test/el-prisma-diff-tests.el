;;; el-prisma-diff-tests.el --- Diff algorithm tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for the AST structural diff algorithm.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma-model)
(require 'el-prisma-diff)

(describe "el-prisma-diff"

  (describe "empty inputs"
    (it "returns empty diff for two empty documents"
      (let* ((a (el-prisma-model-document))
             (b (el-prisma-model-document))
             (d (el-prisma-diff-ast a b)))
        (expect (plist-get d :unchanged) :to-equal nil)
        (expect (plist-get d :modified) :to-equal nil)
        (expect (plist-get d :inserted) :to-equal nil)
        (expect (plist-get d :deleted) :to-equal nil))))

  (describe "unchanged detection"
    (it "detects identical single children as unchanged"
      (let* ((p (el-prisma-model-paragraph
                 :children (list (el-prisma-model-text :value "hello"))))
             (a (el-prisma-model-document :children (list p)))
             (b (el-prisma-model-document :children (list p)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (plist-get d :modified) :to-equal nil)
        (expect (plist-get d :inserted) :to-equal nil)
        (expect (plist-get d :deleted) :to-equal nil)))

    (it "detects multiple identical children"
      (let* ((p1 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "a"))))
             (p2 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "b"))))
             (a (el-prisma-model-document :children (list p1 p2)))
             (b (el-prisma-model-document :children (list p1 p2)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 2)))

    (it "matches by content regardless of position"
      (let* ((n1 (el-prisma-model-text :value "same" :start 0 :end 4))
             (n2 (el-prisma-model-text :value "same" :start 50 :end 54))
             (a (el-prisma-model-document :children (list n1)))
             (b (el-prisma-model-document :children (list n2)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1))))

  (describe "modification detection"
    (it "detects same-type different-content as modified"
      (let* ((p1 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "old"))))
             (p2 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "new"))))
             (a (el-prisma-model-document :children (list p1)))
             (b (el-prisma-model-document :children (list p2)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :modified)) :to-equal 1)
        (expect (plist-get d :unchanged) :to-equal nil)))

    (it "provides both old and new nodes in modified pairs"
      (let* ((old-p (el-prisma-model-paragraph
                     :children (list (el-prisma-model-text :value "old"))))
             (new-p (el-prisma-model-paragraph
                     :children (list (el-prisma-model-text :value "new"))))
             (a (el-prisma-model-document :children (list old-p)))
             (b (el-prisma-model-document :children (list new-p)))
             (d (el-prisma-diff-ast a b))
             (pair (car (plist-get d :modified))))
        (expect (el-prisma-model-prop
                 (car (el-prisma-model-children (car pair))) :value)
                :to-equal "old")
        (expect (el-prisma-model-prop
                 (car (el-prisma-model-children (cdr pair))) :value)
                :to-equal "new"))))

  (describe "insertion detection"
    (it "detects new nodes as inserted"
      (let* ((p1 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "existing"))))
             (p2 (el-prisma-model-heading
                  :level 1
                  :children (list (el-prisma-model-text :value "new heading"))))
             (a (el-prisma-model-document :children (list p1)))
             (b (el-prisma-model-document :children (list p1 p2)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :inserted)) :to-equal 1)
        (expect (el-prisma-model-type (car (plist-get d :inserted)))
                :to-equal 'heading))))

  (describe "deletion detection"
    (it "detects removed nodes as deleted"
      (let* ((p1 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "keep"))))
             (p2 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "remove"))))
             (a (el-prisma-model-document :children (list p1 p2)))
             (b (el-prisma-model-document :children (list p1)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :deleted)) :to-equal 1))))

  (describe "mixed changes"
    (it "handles unchanged + modified + inserted + deleted"
      (let* ((keep (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "keep"))))
             (mod-old (el-prisma-model-paragraph
                       :children (list (el-prisma-model-text :value "old"))))
             (mod-new (el-prisma-model-paragraph
                       :children (list (el-prisma-model-text :value "new"))))
             (gone (el-prisma-model-heading
                    :level 1
                    :children (list (el-prisma-model-text :value "bye"))))
             (added (el-prisma-model-code-block
                     :language "elisp" :body "(hi)"))
             (a (el-prisma-model-document :children (list keep mod-old gone)))
             (b (el-prisma-model-document :children (list keep mod-new added)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :modified)) :to-equal 1)
        (expect (length (plist-get d :inserted)) :to-equal 1)
        (expect (length (plist-get d :deleted)) :to-equal 1)))

    (it "handles complete replacement"
      (let* ((old1 (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "a"))))
             (old2 (el-prisma-model-paragraph
                    :children (list (el-prisma-model-text :value "b"))))
             (new1 (el-prisma-model-heading
                    :level 1
                    :children (list (el-prisma-model-text :value "x"))))
             (new2 (el-prisma-model-heading
                    :level 2
                    :children (list (el-prisma-model-text :value "y"))))
             (a (el-prisma-model-document :children (list old1 old2)))
             (b (el-prisma-model-document :children (list new1 new2)))
             (d (el-prisma-diff-ast a b)))
        ;; Different types, so no modified matches
        (expect (plist-get d :unchanged) :to-equal nil)
        (expect (plist-get d :modified) :to-equal nil)
        (expect (length (plist-get d :deleted)) :to-equal 2)
        (expect (length (plist-get d :inserted)) :to-equal 2))))

  (describe "order preservation"
    (it "preserves match order"
      (let* ((p1 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "first"))))
             (p2 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "second"))))
             (p3 (el-prisma-model-paragraph
                  :children (list (el-prisma-model-text :value "third"))))
             (a (el-prisma-model-document :children (list p1 p2 p3)))
             (b (el-prisma-model-document :children (list p1 p2 p3)))
             (d (el-prisma-diff-ast a b))
             (pairs (plist-get d :unchanged)))
        ;; All three unchanged, in order
        (expect (length pairs) :to-equal 3)
        (expect (el-prisma-model-prop
                 (car (el-prisma-model-children (car (nth 0 pairs)))) :value)
                :to-equal "first")
        (expect (el-prisma-model-prop
                 (car (el-prisma-model-children (car (nth 1 pairs)))) :value)
                :to-equal "second"))))

  (describe "data node diffing"
    (it "diffs map children"
      (let* ((e1 (el-prisma-model-map-entry
                  :key (el-prisma-model-string :value "a")
                  :value (el-prisma-model-number :value 1)))
             (e2 (el-prisma-model-map-entry
                  :key (el-prisma-model-string :value "b")
                  :value (el-prisma-model-number :value 2)))
             (e2-mod (el-prisma-model-map-entry
                      :key (el-prisma-model-string :value "b")
                      :value (el-prisma-model-number :value 99)))
             (a (el-prisma-model-map :children (list e1 e2)))
             (b (el-prisma-model-map :children (list e1 e2-mod)))
             (d (el-prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :modified)) :to-equal 1)))))

;;; el-prisma-diff-tests.el ends here
