;;; prisma-model.el --- Intermediary AST model -*- lexical-binding: t; package-lint-main-file: "prisma.el"; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Unified AST node types shared across all parsers, renderers,
;; and the diff/patch engines.  Every node is a plist with :type,
;; :start, :end, :source-format, :children, and :props.
;;
;;; Code:

(require 'cl-lib)

;;;; Core constructor

(defun prisma-model-node (type &rest args)
  "Create an AST node of TYPE.
ARGS accepts :start, :end, :source-format, :children, :props."
  (list :type type
        :start (plist-get args :start)
        :end (plist-get args :end)
        :source-format (plist-get args :source-format)
        :children (plist-get args :children)
        :props (plist-get args :props)))

;;;; Predicate

(defun prisma-model-node-p (node)
  "Return non-nil if NODE is a valid AST node."
  (and (listp node)
       (plist-get node :type)
       t))

;;;; Accessors

(defun prisma-model-type (node)
  "Return the type symbol of NODE."
  (plist-get node :type))

(defun prisma-model-start (node)
  "Return start byte position of NODE."
  (plist-get node :start))

(defun prisma-model-end (node)
  "Return end byte position of NODE."
  (plist-get node :end))

(defun prisma-model-source-format (node)
  "Return source format symbol of NODE."
  (plist-get node :source-format))

(defun prisma-model-children (node)
  "Return children list of NODE."
  (plist-get node :children))

(defun prisma-model-props (node)
  "Return props plist of NODE."
  (plist-get node :props))

(defun prisma-model-prop (node key)
  "Return value of KEY from NODE's props."
  (plist-get (prisma-model-props node) key))

;;;; Content hashing

(defun prisma-model-content-hash (node)
  "Compute SHA-1 hash of NODE for fast equality check.
Hashes type, props, and children.  Excludes positions and source-format
so identical content at different locations produces the same hash."
  (secure-hash 'sha1 (prisma-model--hash-string node)))

(defun prisma-model--hash-string (node)
  "Build canonical string representation of NODE for hashing."
  (if (not (prisma-model-node-p node))
      (format "%S" node)
    (format "(%s %s %s)"
            (prisma-model-type node)
            (prisma-model--hash-props (prisma-model-props node))
            (mapconcat #'prisma-model--hash-string
                       (prisma-model-children node) " "))))

(defun prisma-model--hash-props (props)
  "Build canonical string for PROPS plist.
Recursively hashes node-valued properties."
  (if (null props)
      ""
    (let (parts)
      (cl-loop for (k v) on props by #'cddr
               do (push (format "%s=%s" k
                                (if (prisma-model-node-p v)
                                    (prisma-model--hash-string v)
                                  (format "%S" v)))
                        parts))
      (mapconcat #'identity (nreverse parts) ","))))

;;;; Rendering helpers

(defun prisma-model-render-blocks (nodes render-fn)
  "Render block-level NODES to a single string via RENDER-FN.
RENDER-FN is a function taking one node and returning its rendered
string.  Consecutive non-empty parts are separated by \"\\n\\n\",
unless the previous part already ends with two newlines."
  (let (parts)
    (dolist (node nodes)
      (let ((rendered (funcall render-fn node)))
        (when (and parts
                   (not (string-empty-p rendered))
                   (not (string-suffix-p "\n\n" (car parts))))
          (push "\n\n" parts))
        (push rendered parts)))
    (apply #'concat (nreverse parts))))

(defun prisma-model-table-column-widths (table render-cell-fn)
  "Return a list of column display widths for TABLE.
TABLE is a `table' node.  RENDER-CELL-FN renders the children of one
`table-cell' to a string (without surrounding padding).
Widths use `string-width' so multibyte characters count correctly.
Skips `table-separator' children and pads ragged rows with width 0.
A column has minimum width 1 so an empty cell still renders visibly."
  (let* ((rows (cl-remove-if-not
                (lambda (c) (eq (prisma-model-type c) 'table-row))
                (prisma-model-children table)))
         (ncols (apply #'max 0 (mapcar (lambda (r)
                                         (length (prisma-model-children r)))
                                       rows))))
    (cl-loop for col from 0 below ncols
             collect
             (apply #'max 1
                    (mapcar
                     (lambda (row)
                       (let ((cell (nth col (prisma-model-children row))))
                         (if cell
                             (string-width
                              (funcall render-cell-fn cell))
                           0)))
                     rows)))))

;;;; Convenience constructor helpers

(defun prisma-model--extract-props (args keys)
  "Extract KEYS from plist ARGS, return a new plist with matching entries."
  (let (result)
    (dolist (key keys)
      (when (plist-member args key)
        (push (plist-get args key) result)
        (push key result)))
    result))

(defmacro prisma-model--define-node (name prop-keys)
  "Define constructor prisma-model-NAME for node type NAME.
PROP-KEYS lists keyword args that go into :props.
Standard keys :start :end :source-format :children are handled automatically."
  (let ((fn-name (intern (format "prisma-model-%s" name))))
    `(defun ,fn-name (&rest args)
       ,(format "Create a `%s' node.\nAccepts :start :end :source-format :children%s."
                name
                (if prop-keys
                    (format " and %s" prop-keys)
                  ""))
       (prisma-model-node ',name
         :start (plist-get args :start)
         :end (plist-get args :end)
         :source-format (plist-get args :source-format)
         :children (plist-get args :children)
         :props ,(if prop-keys
                     `(prisma-model--extract-props args ',prop-keys)
                   nil)))))

;;;; Document node constructors

(prisma-model--define-node document nil)
(prisma-model--define-node heading (:level))
(prisma-model--define-node paragraph nil)
(prisma-model--define-node list (:ordered))
(prisma-model--define-node list-item (:checkbox))
(prisma-model--define-node code-block (:language :body))
(prisma-model--define-node blockquote nil)
(prisma-model--define-node table (:alignments))
(prisma-model--define-node table-row nil)
(prisma-model--define-node table-separator nil)
(prisma-model--define-node table-cell nil)
(prisma-model--define-node horiz-rule nil)
(prisma-model--define-node passthrough (:text))

;;;; Inline node constructors

(prisma-model--define-node text (:value))
(prisma-model--define-node strong nil)
(prisma-model--define-node emphasis nil)
(prisma-model--define-node code (:value))
(prisma-model--define-node verbatim (:value))
(prisma-model--define-node link (:url))
(prisma-model--define-node image (:url :alt))
(prisma-model--define-node linebreak nil)
(prisma-model--define-node strike nil)

(provide 'prisma-model)
;;; prisma-model.el ends here

