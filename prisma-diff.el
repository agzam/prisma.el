;;; prisma-diff.el --- AST diff algorithm -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Structural diff on the intermediary AST model. Compares two ASTs
;; and classifies children as unchanged, modified, inserted, or deleted.
;; Uses content hashing for fast equality and order-preserving greedy
;; matching.
;;
;;; Code:

(require 'cl-lib)
(require 'prisma-model)

;;;; Public API

(defun prisma-diff-ast (ast1 ast2)
  "Structural diff between AST1 and AST2.
Compares child node lists and classifies each as unchanged, modified,
inserted, or deleted. Returns a plist:
  :unchanged - list of (ast1-node . ast2-node) pairs
  :modified  - list of (ast1-node . ast2-node) pairs
  :inserted  - list of ast2-nodes
  :deleted   - list of ast1-nodes"
  (prisma-diff--children
   (prisma-model-children ast1)
   (prisma-model-children ast2)))

;;;; Internal matching

(defun prisma-diff--children (nodes1 nodes2)
  "Match and classify two lists of sibling nodes."
  (let* ((vec1 (vconcat nodes1))
         (vec2 (vconcat nodes2))
         (len1 (length vec1))
         (len2 (length vec2))
         (hashes1 (prisma-diff--hash-vec vec1))
         (hashes2 (prisma-diff--hash-vec vec2))
         (used1 (make-vector len1 nil))
         (used2 (make-vector len2 nil))
         (matches nil))
    ;; Pass 1: exact matches by type + content-hash, order-preserving
    (let ((min-j 0))
      (dotimes (i len1)
        (let ((type1 (prisma-model-type (aref vec1 i)))
              (hash1 (aref hashes1 i)))
          (cl-loop for j from min-j below len2
                   when (and (not (aref used2 j))
                             (eq type1 (prisma-model-type (aref vec2 j)))
                             (string= hash1 (aref hashes2 j)))
                   do (aset used1 i t)
                      (aset used2 j t)
                      (push (list i j :unchanged) matches)
                      (setq min-j (1+ j))
                      (cl-return)))))
    ;; Pass 2: type-only matches for remaining nodes (modified)
    (let ((min-j 0))
      (dotimes (i len1)
        (unless (aref used1 i)
          (let ((type1 (prisma-model-type (aref vec1 i))))
            (cl-loop for j from min-j below len2
                     when (and (not (aref used2 j))
                               (eq type1 (prisma-model-type (aref vec2 j))))
                     do (aset used1 i t)
                        (aset used2 j t)
                        (push (list i j :modified) matches)
                        (setq min-j (1+ j))
                        (cl-return))))))
    ;; Build result
    (prisma-diff--build-result vec1 vec2 used1 used2 (nreverse matches))))

(defun prisma-diff--hash-vec (vec)
  "Compute content hashes for all nodes in VEC.  Returns a hash vector."
  (let ((hashes (make-vector (length vec) nil)))
    (dotimes (i (length vec))
      (aset hashes i (prisma-model-content-hash (aref vec i))))
    hashes))

(defun prisma-diff--build-result (vec1 vec2 used1 used2 matches)
  "Build diff result plist from matching data."
  (let (unchanged modified deleted inserted)
    (dolist (m matches)
      (let ((node1 (aref vec1 (nth 0 m)))
            (node2 (aref vec2 (nth 1 m))))
        (pcase (nth 2 m)
          (:unchanged (push (cons node1 node2) unchanged))
          (:modified  (push (cons node1 node2) modified)))))
    (dotimes (i (length vec1))
      (unless (aref used1 i)
        (push (aref vec1 i) deleted)))
    (dotimes (j (length vec2))
      (unless (aref used2 j)
        (push (aref vec2 j) inserted)))
    (list :unchanged (nreverse unchanged)
          :modified (nreverse modified)
          :inserted (nreverse inserted)
          :deleted (nreverse deleted))))

(provide 'prisma-diff)
;;; prisma-diff.el ends here
