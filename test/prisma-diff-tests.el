;;; prisma-diff-tests.el --- Diff algorithm tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for the AST structural diff algorithm.
;;
;;; Code:

(require 'buttercup)
(require 'prisma-model)
(require 'prisma-diff)

(describe "prisma-diff"

  (describe "empty inputs"
    (it "returns empty diff for two empty documents"
      (let* ((a (prisma-model-document))
             (b (prisma-model-document))
             (d (prisma-diff-ast a b)))
        (expect (plist-get d :unchanged) :to-equal nil)
        (expect (plist-get d :modified) :to-equal nil)
        (expect (plist-get d :inserted) :to-equal nil)
        (expect (plist-get d :deleted) :to-equal nil))))

  (describe "unchanged detection"
    (it "detects identical single children as unchanged"
      (let* ((p (prisma-model-paragraph
                 :children (list (prisma-model-text :value "hello"))))
             (a (prisma-model-document :children (list p)))
             (b (prisma-model-document :children (list p)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (plist-get d :modified) :to-equal nil)
        (expect (plist-get d :inserted) :to-equal nil)
        (expect (plist-get d :deleted) :to-equal nil)))

    (it "detects multiple identical children"
      (let* ((p1 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "a"))))
             (p2 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "b"))))
             (a (prisma-model-document :children (list p1 p2)))
             (b (prisma-model-document :children (list p1 p2)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 2)))

    (it "matches by content regardless of position"
      (let* ((n1 (prisma-model-text :value "same" :start 0 :end 4))
             (n2 (prisma-model-text :value "same" :start 50 :end 54))
             (a (prisma-model-document :children (list n1)))
             (b (prisma-model-document :children (list n2)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1))))

  (describe "modification detection"
    (it "detects same-type different-content as modified"
      (let* ((p1 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "old"))))
             (p2 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "new"))))
             (a (prisma-model-document :children (list p1)))
             (b (prisma-model-document :children (list p2)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :modified)) :to-equal 1)
        (expect (plist-get d :unchanged) :to-equal nil)))

    (it "provides both old and new nodes in modified pairs"
      (let* ((old-p (prisma-model-paragraph
                     :children (list (prisma-model-text :value "old"))))
             (new-p (prisma-model-paragraph
                     :children (list (prisma-model-text :value "new"))))
             (a (prisma-model-document :children (list old-p)))
             (b (prisma-model-document :children (list new-p)))
             (d (prisma-diff-ast a b))
             (pair (car (plist-get d :modified))))
        (expect (prisma-model-prop
                 (car (prisma-model-children (car pair))) :value)
                :to-equal "old")
        (expect (prisma-model-prop
                 (car (prisma-model-children (cdr pair))) :value)
                :to-equal "new"))))

  (describe "insertion detection"
    (it "detects new nodes as inserted"
      (let* ((p1 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "existing"))))
             (p2 (prisma-model-heading
                  :level 1
                  :children (list (prisma-model-text :value "new heading"))))
             (a (prisma-model-document :children (list p1)))
             (b (prisma-model-document :children (list p1 p2)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :inserted)) :to-equal 1)
        (expect (prisma-model-type (car (plist-get d :inserted)))
                :to-equal 'heading))))

  (describe "deletion detection"
    (it "detects removed nodes as deleted"
      (let* ((p1 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "keep"))))
             (p2 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "remove"))))
             (a (prisma-model-document :children (list p1 p2)))
             (b (prisma-model-document :children (list p1)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :deleted)) :to-equal 1))))

  (describe "mixed changes"
    (it "handles unchanged + modified + inserted + deleted"
      (let* ((keep (prisma-model-paragraph
                    :children (list (prisma-model-text :value "keep"))))
             (mod-old (prisma-model-paragraph
                       :children (list (prisma-model-text :value "old"))))
             (mod-new (prisma-model-paragraph
                       :children (list (prisma-model-text :value "new"))))
             (gone (prisma-model-heading
                    :level 1
                    :children (list (prisma-model-text :value "bye"))))
             (added (prisma-model-code-block
                     :language "elisp" :body "(hi)"))
             (a (prisma-model-document :children (list keep mod-old gone)))
             (b (prisma-model-document :children (list keep mod-new added)))
             (d (prisma-diff-ast a b)))
        (expect (length (plist-get d :unchanged)) :to-equal 1)
        (expect (length (plist-get d :modified)) :to-equal 1)
        (expect (length (plist-get d :inserted)) :to-equal 1)
        (expect (length (plist-get d :deleted)) :to-equal 1)))

    (it "handles complete replacement"
      (let* ((old1 (prisma-model-paragraph
                    :children (list (prisma-model-text :value "a"))))
             (old2 (prisma-model-paragraph
                    :children (list (prisma-model-text :value "b"))))
             (new1 (prisma-model-heading
                    :level 1
                    :children (list (prisma-model-text :value "x"))))
             (new2 (prisma-model-heading
                    :level 2
                    :children (list (prisma-model-text :value "y"))))
             (a (prisma-model-document :children (list old1 old2)))
             (b (prisma-model-document :children (list new1 new2)))
             (d (prisma-diff-ast a b)))
        ;; Different types, so no modified matches
        (expect (plist-get d :unchanged) :to-equal nil)
        (expect (plist-get d :modified) :to-equal nil)
        (expect (length (plist-get d :deleted)) :to-equal 2)
        (expect (length (plist-get d :inserted)) :to-equal 2))))

  (describe "order preservation"
    (it "preserves match order"
      (let* ((p1 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "first"))))
             (p2 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "second"))))
             (p3 (prisma-model-paragraph
                  :children (list (prisma-model-text :value "third"))))
             (a (prisma-model-document :children (list p1 p2 p3)))
             (b (prisma-model-document :children (list p1 p2 p3)))
             (d (prisma-diff-ast a b))
             (pairs (plist-get d :unchanged)))
        ;; All three unchanged, in order
        (expect (length pairs) :to-equal 3)
        (expect (prisma-model-prop
                 (car (prisma-model-children (car (nth 0 pairs)))) :value)
                :to-equal "first")
        (expect (prisma-model-prop
                 (car (prisma-model-children (car (nth 1 pairs)))) :value)
                :to-equal "second"))))

)

;;; prisma-diff-tests.el ends here
