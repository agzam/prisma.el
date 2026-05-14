;;; el-prisma-patch-tests.el --- Patch engine tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for the patch engine.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma-model)
(require 'el-prisma-patch)

(defun el-prisma-patch-test--text-render (node)
  "Render NODE by returning its :value prop (for testing)."
  (or (el-prisma-model-prop node :value)
      (el-prisma-model-prop node :text)
      ""))

(describe "el-prisma-patch"

  (describe "no changes"
    (it "returns source unchanged for empty diff"
      (let ((diff (list :unchanged nil :modified nil
                        :inserted nil :deleted nil)))
        (expect (el-prisma-patch "hello world" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "hello world"))))

  (describe "modifications"
    (it "replaces a single region"
      (let* ((old-node (el-prisma-model-text :value "old" :start 0 :end 3))
             (new-node (el-prisma-model-text :value "new"))
             (diff (list :unchanged nil
                         :modified (list (cons old-node new-node))
                         :inserted nil :deleted nil)))
        (expect (el-prisma-patch "old world" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "new world")))

    (it "replaces in the middle of text"
      (let* ((old-node (el-prisma-model-text :value "brave" :start 6 :end 11))
             (new-node (el-prisma-model-text :value "cruel"))
             (diff (list :unchanged nil
                         :modified (list (cons old-node new-node))
                         :inserted nil :deleted nil)))
        (expect (el-prisma-patch "hello brave world" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "hello cruel world")))

    (it "handles multiple non-overlapping modifications"
      (let* ((n1-old (el-prisma-model-text :value "aa" :start 0 :end 2))
             (n1-new (el-prisma-model-text :value "XX"))
             (n2-old (el-prisma-model-text :value "bb" :start 3 :end 5))
             (n2-new (el-prisma-model-text :value "YY"))
             (diff (list :unchanged nil
                         :modified (list (cons n1-old n1-new)
                                         (cons n2-old n2-new))
                         :inserted nil :deleted nil)))
        (expect (el-prisma-patch "aa-bb-cc" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "XX-YY-cc")))

    (it "handles replacement with different length"
      (let* ((old-node (el-prisma-model-text :value "hi" :start 0 :end 2))
             (new-node (el-prisma-model-text :value "goodbye"))
             (diff (list :unchanged nil
                         :modified (list (cons old-node new-node))
                         :inserted nil :deleted nil)))
        (expect (el-prisma-patch "hi there" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "goodbye there"))))

  (describe "deletions"
    (it "removes a region"
      (let* ((node (el-prisma-model-text :value "brave " :start 6 :end 12))
             (diff (list :unchanged nil :modified nil
                         :inserted nil
                         :deleted (list node))))
        (expect (el-prisma-patch "hello brave world" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "hello world")))

    (it "removes at start"
      (let* ((node (el-prisma-model-text :value "hello " :start 0 :end 6))
             (diff (list :unchanged nil :modified nil
                         :inserted nil :deleted (list node))))
        (expect (el-prisma-patch "hello world" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "world")))

    (it "removes at end"
      (let* ((node (el-prisma-model-text :value " world" :start 5 :end 11))
             (diff (list :unchanged nil :modified nil
                         :inserted nil :deleted (list node))))
        (expect (el-prisma-patch "hello world" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "hello"))))

  (describe "insertions"
    (it "inserts at document start when no anchors"
      (let* ((node (el-prisma-model-text :value "NEW " :start 0))
             (diff (list :unchanged nil :modified nil
                         :inserted (list node) :deleted nil)))
        (expect (el-prisma-patch "hello" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "NEW hello")))

    (it "inserts after an anchored node"
      (let* ((src-keep (el-prisma-model-text
                        :value "aaa" :start 0 :end 3))
             (mir-keep (el-prisma-model-text
                        :value "aaa" :start 0 :end 3))
             (new-node (el-prisma-model-text
                        :value "BBB" :start 3))
             (diff (list :unchanged (list (cons src-keep mir-keep))
                         :modified nil
                         :inserted (list new-node)
                         :deleted nil)))
        (expect (el-prisma-patch "aaaccc" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "aaaBBBccc"))))

  (describe "mixed operations"
    (it "handles modify + delete together"
      (let* ((n1-old (el-prisma-model-text :value "aa" :start 0 :end 2))
             (n1-new (el-prisma-model-text :value "XX"))
             (n2 (el-prisma-model-text :value "bb" :start 3 :end 5))
             (diff (list :unchanged nil
                         :modified (list (cons n1-old n1-new))
                         :inserted nil
                         :deleted (list n2))))
        (expect (el-prisma-patch "aa-bb-cc" diff
                                 #'el-prisma-patch-test--text-render)
                :to-equal "XX--cc")))))

(provide 'el-prisma-patch-tests)
;;; el-prisma-patch-tests.el ends here
