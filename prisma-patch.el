;;; prisma-patch.el --- Patch engine -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Applies a structural diff back to source text. Handles modified,
;; inserted, and deleted nodes while leaving unchanged regions intact.
;;
;;; Code:

(require 'cl-lib)
(require 'prisma-model)

;;;; Public API

(defun prisma-patch (source-text diff render-fn)
  "Apply DIFF to SOURCE-TEXT, return patched string.
RENDER-FN takes a model node and returns its source-format string.
DIFF is a plist from `prisma-diff-ast'."
  (let ((ops (prisma-patch--collect-ops diff render-fn source-text)))
    (prisma-patch--apply-ops source-text ops)))

;;;; Operation collection

(defun prisma-patch--collect-ops (diff render-fn source-text)
  "Build list of patch operations from DIFF.
Each op is (:action TYPE :start POS :end END :text REPLACEMENT)."
  (let ((ops nil)
        (unchanged (plist-get diff :unchanged))
        (modified (plist-get diff :modified))
        (inserted (plist-get diff :inserted))
        (deleted (plist-get diff :deleted)))
    ;; Modified: replace source range with re-rendered content
    (dolist (pair modified)
      (let* ((src-node (car pair))
             (mir-node (cdr pair))
             (start (prisma-model-start src-node))
             (end (prisma-model-end src-node))
             (text (funcall render-fn mir-node)))
        (when (and start end)
          (push (list :action 'replace :start start :end end :text text)
                ops))))
    ;; Deleted: remove source range
    (dolist (node deleted)
      (let ((start (prisma-model-start node))
            (end (prisma-model-end node)))
        (when (and start end)
          (push (list :action 'delete :start start :end end) ops))))
    ;; Inserted: find insertion point from mirror ordering
    (when inserted
      (let ((anchor-map (prisma-patch--build-anchor-map
                         unchanged modified)))
        (dolist (node inserted)
          (let* ((mir-pos (or (prisma-model-start node) 0))
                 (insert-at (prisma-patch--find-insert-point
                             mir-pos anchor-map
                             (length source-text)))
                 (text (funcall render-fn node)))
            (push (list :action 'insert :start insert-at :text text)
                  ops)))))
    ops))

(defun prisma-patch--build-anchor-map (unchanged modified)
  "Build a sorted alist of (mirror-end . source-end) from matched pairs.
Used to determine insertion points for new nodes."
  (let (anchors)
    (dolist (pair unchanged)
      (let ((src (car pair))
            (mir (cdr pair)))
        (when (and (prisma-model-end mir)
                   (prisma-model-end src))
          (push (cons (prisma-model-end mir)
                      (prisma-model-end src))
                anchors))))
    (dolist (pair modified)
      (let ((src (car pair))
            (mir (cdr pair)))
        (when (and (prisma-model-end mir)
                   (prisma-model-end src))
          (push (cons (prisma-model-end mir)
                      (prisma-model-end src))
                anchors))))
    (sort anchors (lambda (a b) (< (car a) (car b))))))

(defun prisma-patch--find-insert-point (mirror-pos anchor-map source-len)
  "Find source position for inserting a node at MIRROR-POS.
Uses ANCHOR-MAP to map mirror positions to source positions."
  (let ((best-src 0))
    (dolist (anchor anchor-map)
      (when (<= (car anchor) mirror-pos)
        (setq best-src (cdr anchor))))
    (min best-src source-len)))

;;;; Operation application

(defun prisma-patch--apply-ops (text ops)
  "Apply OPS to TEXT in reverse position order."
  (let ((sorted (sort (copy-sequence ops)
                      (lambda (a b)
                        (> (plist-get a :start)
                           (plist-get b :start))))))
    (dolist (op sorted)
      (let ((action (plist-get op :action))
            (start (plist-get op :start))
            (end (plist-get op :end))
            (replacement (plist-get op :text)))
        (setq text
              (pcase action
                ('replace
                 (let* ((original (substring text start end))
                        ;; Preserve trailing newline if original had one
                        (fixed (if (and (string-suffix-p "\n" original)
                                        (not (string-suffix-p "\n" replacement)))
                                   (concat replacement "\n")
                                 replacement)))
                   (concat (substring text 0 start)
                           fixed
                           (substring text end))))
                ('delete
                 (concat (substring text 0 start)
                         (substring text end)))
                ('insert
                 (concat (substring text 0 start)
                         replacement
                         (substring text start)))))))
    text))

(provide 'prisma-patch)
;;; prisma-patch.el ends here
