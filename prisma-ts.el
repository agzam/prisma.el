;;; prisma-ts.el --- Tree-sitter parser integration -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Tree-sitter utilities shared across format-specific parsers.
;; Provides node traversal and range-based filtering for
;; dual-parser coordination (e.g. markdown block + inline).
;;
;;; Code:

(require 'treesit)
(require 'cl-lib)

(defun prisma-ts-nodes-in-range (root start end)
  "Find named children of ROOT within byte range [START, END)."
  (let (result)
    (dolist (child (treesit-node-children root t))
      (when (and (>= (treesit-node-start child) start)
                 (<= (treesit-node-end child) end))
        (push child result)))
    (nreverse result)))

(defun prisma-ts-child-by-type (node type)
  "Find first named child of NODE with TYPE string."
  (cl-loop for child in (treesit-node-children node t)
           when (string= (treesit-node-type child) type)
           return child))

(defun prisma-ts-children-by-type (node type)
  "Find all children of NODE with TYPE string (named and anonymous)."
  (cl-loop for child in (treesit-node-children node)
           when (string= (treesit-node-type child) type)
           collect child))

(defun prisma-ts-content-range (node delimiter-type)
  "Return (CONTENT-START . CONTENT-END) for NODE.
Finds delimiter children of DELIMITER-TYPE and returns the range
between the opening and closing delimiter groups."
  (let* ((delims (prisma-ts-children-by-type node delimiter-type))
         (count (length delims))
         (mid (/ count 2)))
    (when (>= count 2)
      (cons (treesit-node-end (nth (1- mid) delims))
            (treesit-node-start (nth mid delims))))))

(provide 'prisma-ts)
;;; prisma-ts.el ends here
