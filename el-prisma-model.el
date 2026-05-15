;;; el-prisma-model.el --- Intermediary AST model -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Unified AST node types shared across all parsers, renderers,
;; and the diff/patch engines. Every node is a plist with :type,
;; :start, :end, :source-format, :children, and :props.
;;
;;; Code:

(require 'cl-lib)

;;;; Core constructor

(defun el-prisma-model-node (type &rest args)
  "Create an AST node of TYPE.
ARGS accepts :start, :end, :source-format, :children, :props."
  (list :type type
        :start (plist-get args :start)
        :end (plist-get args :end)
        :source-format (plist-get args :source-format)
        :children (plist-get args :children)
        :props (plist-get args :props)))

;;;; Predicate

(defun el-prisma-model-node-p (node)
  "Return non-nil if NODE is a valid AST node."
  (and (listp node)
       (plist-get node :type)
       t))

;;;; Accessors

(defun el-prisma-model-type (node)
  "Return the type symbol of NODE."
  (plist-get node :type))

(defun el-prisma-model-start (node)
  "Return start byte position of NODE."
  (plist-get node :start))

(defun el-prisma-model-end (node)
  "Return end byte position of NODE."
  (plist-get node :end))

(defun el-prisma-model-source-format (node)
  "Return source format symbol of NODE."
  (plist-get node :source-format))

(defun el-prisma-model-children (node)
  "Return children list of NODE."
  (plist-get node :children))

(defun el-prisma-model-props (node)
  "Return props plist of NODE."
  (plist-get node :props))

(defun el-prisma-model-prop (node key)
  "Return value of KEY from NODE's props."
  (plist-get (el-prisma-model-props node) key))

;;;; Content hashing

(defun el-prisma-model-content-hash (node)
  "Compute SHA-1 hash of NODE for fast equality checks.
Hashes type, props, and children. Excludes positions and source-format
so identical content at different locations produces the same hash."
  (secure-hash 'sha1 (el-prisma-model--hash-string node)))

(defun el-prisma-model--hash-string (node)
  "Build canonical string representation of NODE for hashing."
  (if (not (el-prisma-model-node-p node))
      (format "%S" node)
    (format "(%s %s %s)"
            (el-prisma-model-type node)
            (el-prisma-model--hash-props (el-prisma-model-props node))
            (mapconcat #'el-prisma-model--hash-string
                       (el-prisma-model-children node) " "))))

(defun el-prisma-model--hash-props (props)
  "Build canonical string for PROPS plist.
Recursively hashes node-valued properties."
  (if (null props)
      ""
    (let (parts)
      (cl-loop for (k v) on props by #'cddr
               do (push (format "%s=%s" k
                                (if (el-prisma-model-node-p v)
                                    (el-prisma-model--hash-string v)
                                  (format "%S" v)))
                        parts))
      (mapconcat #'identity (nreverse parts) ","))))

;;;; Convenience constructor helpers

(defun el-prisma-model--extract-props (args keys)
  "Extract KEYS from plist ARGS, return a new plist with matching entries."
  (let (result)
    (dolist (key keys)
      (when (plist-member args key)
        (push (plist-get args key) result)
        (push key result)))
    result))

(defmacro el-prisma-model--define-node (name prop-keys)
  "Define constructor el-prisma-model-NAME for node type NAME.
PROP-KEYS lists keyword args that go into :props.
Standard keys :start :end :source-format :children are handled automatically."
  (let ((fn-name (intern (format "el-prisma-model-%s" name))))
    `(defun ,fn-name (&rest args)
       ,(format "Create a `%s' node.\nAccepts :start :end :source-format :children%s."
                name
                (if prop-keys
                    (format " and %s" prop-keys)
                  ""))
       (el-prisma-model-node ',name
         :start (plist-get args :start)
         :end (plist-get args :end)
         :source-format (plist-get args :source-format)
         :children (plist-get args :children)
         :props ,(if prop-keys
                     `(el-prisma-model--extract-props args ',prop-keys)
                   nil)))))

;;;; Document node constructors

(el-prisma-model--define-node document nil)
(el-prisma-model--define-node heading (:level))
(el-prisma-model--define-node paragraph nil)
(el-prisma-model--define-node list (:ordered))
(el-prisma-model--define-node list-item (:checkbox))
(el-prisma-model--define-node code-block (:language :body))
(el-prisma-model--define-node blockquote nil)
(el-prisma-model--define-node table (:rows))
(el-prisma-model--define-node horiz-rule nil)
(el-prisma-model--define-node passthrough (:text))

;;;; Inline node constructors

(el-prisma-model--define-node text (:value))
(el-prisma-model--define-node strong nil)
(el-prisma-model--define-node emphasis nil)
(el-prisma-model--define-node code (:value))
(el-prisma-model--define-node verbatim (:value))
(el-prisma-model--define-node link (:url))
(el-prisma-model--define-node image (:url :alt))
(el-prisma-model--define-node linebreak nil)
(el-prisma-model--define-node strike nil)

(provide 'el-prisma-model)
;;; el-prisma-model.el ends here
