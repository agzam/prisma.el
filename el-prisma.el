;;; el-prisma.el --- Format conversion with lossless round-trips -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: May 09, 2026
;; Version: 0.1.0
;; Keywords: tools convenience
;; Homepage: https://github.com/agzam/prisma.el
;; Package-Requires: ((emacs "29.1"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; El Prisma - same content, different spectrum.
;;
;; Convert buffer content between formats (Markdown<->Org, JSON<->EDN)
;; while preserving lossless round-trips.  Creates mirror buffers for
;; editing in a preferred format with explicit commit/cancel workflow.
;;
;;; Code:

(defgroup el-prisma nil
  "Format conversion with lossless round-trips."
  :group 'tools
  :prefix "el-prisma-")

(declare-function el-prisma-md-parse "el-prisma-md")
(declare-function el-prisma-md-render "el-prisma-md")
(declare-function el-prisma-org-parse "el-prisma-org")
(declare-function el-prisma-org-render "el-prisma-org")
(declare-function el-prisma-patch "el-prisma-patch")
(declare-function el-prisma-diff-ast "el-prisma-diff")

;;;; Customization

(defcustom el-prisma-default-targets
  '((markdown-mode . org)
    (gfm-mode . org)
    (json-mode . edn)
    (json-ts-mode . edn)
    (js-json-mode . edn))
  "Alist mapping source major mode to default target format symbol."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'el-prisma)

(defcustom el-prisma-validate-on-commit nil
  "When non-nil, run round-trip validation before committing.
Disabled by default because the diff+patch architecture already
preserves unchanged regions byte-for-byte, making whole-document
validation redundant. Minor normalization differences (whitespace,
blank lines) will always exist and produce false positives."
  :type 'boolean
  :group 'el-prisma)

(defcustom el-prisma-display-action
  '(display-buffer-same-window)
  "Display action for showing the mirror buffer."
  :type 'sexp
  :group 'el-prisma)

;;;; Internal variables

(defvar-local el-prisma--source-buffer nil
  "Reference to the source buffer in a mirror buffer.")

(defvar-local el-prisma--source-ast nil
  "AST from the initial parse of the source buffer.")

(defvar-local el-prisma--source-format nil
  "Format symbol of the source buffer (e.g. `markdown').")

(defvar-local el-prisma--target-format nil
  "Format symbol of the mirror buffer (e.g. `org').")

(defvar-local el-prisma--source-tick nil
  "Source buffer `buffer-modified-tick' at conversion time.")

(defvar-local el-prisma--source-text nil
  "Original source text at conversion time.")

;;;; Format detection

(defun el-prisma--detect-source-format (&optional buffer)
  "Detect the source format of BUFFER (or current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((derived-mode-p 'gfm-mode 'markdown-mode) 'markdown)
     ((derived-mode-p 'org-mode) 'org)
     ((derived-mode-p 'json-mode 'json-ts-mode 'js-json-mode) 'json)
     (t nil))))

(defun el-prisma--target-for-source (source-format)
  "Return default target format for SOURCE-FORMAT."
  (pcase source-format
    ('markdown 'org)
    ('org 'markdown)
    ('json 'edn)
    ('edn 'json)
    (_ nil)))

(defun el-prisma--major-mode-for-format (format)
  "Return the major mode function for FORMAT."
  (pcase format
    ('org 'org-mode)
    ('markdown 'markdown-mode)
    ('json 'json-mode)
    ('edn 'clojure-mode)
    (_ 'fundamental-mode)))

;;;; Public API

(defun el-prisma-parse (format text &optional _start)
  "Parse TEXT in FORMAT, return intermediary model AST.
FORMAT is a symbol: `markdown', `org'."
  (pcase format
    ('markdown
     (require 'el-prisma-md)
     (el-prisma-md-parse text))
    ('org
     (require 'el-prisma-org)
     (el-prisma-org-parse text))
    (_ (error "el-prisma: unsupported parse format: %s" format))))

(defun el-prisma-render (format ast)
  "Render AST to FORMAT, return string.
FORMAT is a symbol: `org', `markdown'."
  (pcase format
    ('org
     (require 'el-prisma-org)
     (el-prisma-org-render ast))
    ('markdown
     (require 'el-prisma-md)
     (el-prisma-md-render ast))
    (_ (error "el-prisma: unsupported render format: %s" format))))

;;;; Cursor position mapping

(defun el-prisma--find-node-at-pos (pos children)
  "Find the top-level node in CHILDREN whose range contains POS.
Returns (INDEX . NODE) or nil."
  (cl-loop for node in children
           for i from 0
           when (and (el-prisma-model-start node)
                     (el-prisma-model-end node)
                     (<= (el-prisma-model-start node) pos)
                     (< pos (el-prisma-model-end node)))
           return (cons i node)))

(defun el-prisma--map-position (pos source-children target-children)
  "Map cursor POS from source coordinate space to target.
Finds which node in SOURCE-CHILDREN contains POS, looks up the
corresponding node in TARGET-CHILDREN by index, and computes
a proportional offset within that node."
  (if-let* ((match (el-prisma--find-node-at-pos pos source-children))
            (idx (car match))
            (src-node (cdr match))
            (tgt-node (nth idx target-children))
            (src-start (el-prisma-model-start src-node))
            (src-end (el-prisma-model-end src-node))
            (src-span (max 1 (- src-end src-start)))
            (tgt-start (el-prisma-model-start tgt-node))
            (tgt-end (el-prisma-model-end tgt-node))
            (tgt-span (- tgt-end tgt-start))
            (ratio (/ (float (- pos src-start)) src-span)))
      (+ tgt-start (round (* ratio tgt-span)))
    ;; Fallback: proportional position in whole document
    (if (and source-children target-children)
        (let* ((src-last (car (last source-children)))
               (tgt-last (car (last target-children)))
               (src-total (or (el-prisma-model-end src-last) 1))
               (tgt-total (or (el-prisma-model-end tgt-last) 1)))
          (min tgt-total
               (round (* (/ (float pos) (max 1 src-total)) tgt-total))))
      (min pos 1))))

;;;; Interactive commands

;;;###autoload
(defun el-prisma-convert (&optional target-format)
  "Convert current buffer to TARGET-FORMAT in a mirror buffer.
When called interactively, detects source format and uses the default target."
  (interactive)
  (let* ((source-buf (current-buffer))
         (source-fmt (or (el-prisma--detect-source-format)
                         (error "el-prisma: cannot detect source format")))
         (target-fmt (or target-format
                         (el-prisma--target-for-source source-fmt)
                         (error "el-prisma: no target for %s" source-fmt)))
         (source-text (buffer-substring-no-properties (point-min) (point-max)))
         (source-ast (el-prisma-parse source-fmt source-text))
         (rendered (el-prisma-render target-fmt source-ast))
         (mirror-name (format "*prisma:%s:%s*"
                              (buffer-name source-buf) target-fmt))
         (mirror-buf (get-buffer-create mirror-name))
         (source-tick (buffer-modified-tick source-buf)))
    (let* ((source-pos (1- (point)))
           (win-offset (when (eq (window-buffer) (current-buffer))
                         (count-lines (window-start) (point))))
           (mirror-ast (el-prisma-parse target-fmt rendered))
           (target-pos (el-prisma--map-position
                        source-pos
                        (el-prisma-model-children source-ast)
                        (el-prisma-model-children mirror-ast))))
      (with-current-buffer mirror-buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert rendered))
        (funcall (el-prisma--major-mode-for-format target-fmt))
        (setq el-prisma--source-buffer source-buf
              el-prisma--source-ast source-ast
              el-prisma--source-format source-fmt
              el-prisma--target-format target-fmt
              el-prisma--source-tick source-tick
              el-prisma--source-text source-text)
        (el-prisma-mirror-mode 1)
        (set-buffer-modified-p nil))
      (switch-to-buffer mirror-buf)
      (goto-char (min (1+ target-pos) (point-max)))
      (when win-offset (recenter win-offset)))
    mirror-buf))

(defun el-prisma-commit ()
  "Parse mirror buffer, diff against source AST, patch source."
  (interactive)
  (unless el-prisma-mirror-mode
    (error "el-prisma: not in a mirror buffer"))
  (let* ((source-buf el-prisma--source-buffer)
         (source-ast el-prisma--source-ast)
         (source-fmt el-prisma--source-format)
         (target-fmt el-prisma--target-format)
         (source-text el-prisma--source-text)
         (source-tick el-prisma--source-tick)
         (mirror-pos (1- (point)))
         (win-offset (when (eq (window-buffer) (current-buffer))
                       (count-lines (window-start) (point))))
         (mirror-text (buffer-substring-no-properties
                       (point-min) (point-max)))
         (mirror-ast (el-prisma-parse target-fmt mirror-text))
         (target-pos (el-prisma--map-position
                      mirror-pos
                      (el-prisma-model-children mirror-ast)
                      (el-prisma-model-children source-ast))))
    (unless (buffer-live-p source-buf)
      (error "el-prisma: source buffer no longer exists"))
    (when (and source-tick
               (/= source-tick (buffer-modified-tick source-buf)))
      (unless (yes-or-no-p
               "Source buffer was modified since conversion. Commit anyway? ")
        (user-error "Commit cancelled")))
    (require 'el-prisma-diff)
    (let ((diff (el-prisma-diff-ast source-ast mirror-ast)))
      (if (and (null (plist-get diff :modified))
               (null (plist-get diff :inserted))
               (null (plist-get diff :deleted)))
          (progn
            (let ((el-prisma--skip-kill-confirm t))
              (kill-buffer (current-buffer)))
            (switch-to-buffer source-buf)
            (goto-char (min (1+ target-pos) (point-max)))
            (when win-offset (recenter win-offset))
            (message "el-prisma: no changes to commit"))
        (when el-prisma-validate-on-commit
          (el-prisma--validate-round-trip
           mirror-text target-fmt source-fmt))
        (require 'el-prisma-patch)
        (let* ((render-fn (lambda (node)
                            (el-prisma-render source-fmt node)))
               (patched (el-prisma-patch source-text diff render-fn)))
          (with-current-buffer source-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert patched)))
          (let ((el-prisma--skip-kill-confirm t))
            (kill-buffer (current-buffer)))
          (switch-to-buffer source-buf)
          (goto-char (min (1+ target-pos) (point-max)))
          (when win-offset (recenter win-offset))
          (message "el-prisma: committed %d modification(s), %d insertion(s), %d deletion(s)"
                   (length (plist-get diff :modified))
                   (length (plist-get diff :inserted))
                   (length (plist-get diff :deleted))))))))

(defun el-prisma-cancel ()
  "Cancel conversion, kill mirror buffer without changing source."
  (interactive)
  (unless el-prisma-mirror-mode
    (error "el-prisma: not in a mirror buffer"))
  (when (and (buffer-modified-p)
             (not (yes-or-no-p "Mirror buffer has unsaved changes. Cancel anyway? ")))
    (user-error "Cancel aborted"))
  (let* ((source-buf el-prisma--source-buffer)
         (source-ast el-prisma--source-ast)
         (target-fmt el-prisma--target-format)
         (mirror-pos (1- (point)))
         (win-offset (when (eq (window-buffer) (current-buffer))
                       (count-lines (window-start) (point))))
         (mirror-text (buffer-substring-no-properties
                       (point-min) (point-max)))
         (mirror-ast (el-prisma-parse target-fmt mirror-text))
         (target-pos (el-prisma--map-position
                      mirror-pos
                      (el-prisma-model-children mirror-ast)
                      (el-prisma-model-children source-ast)))
         (el-prisma--skip-kill-confirm t))
    (kill-buffer (current-buffer))
    (when (buffer-live-p source-buf)
      (switch-to-buffer source-buf)
      (goto-char (min (1+ target-pos) (point-max)))
      (when win-offset (recenter win-offset)))
    (message "el-prisma: conversion cancelled")))

(defun el-prisma-diff ()
  "Preview what changes would be applied to the source buffer."
  (interactive)
  (unless el-prisma-mirror-mode
    (error "el-prisma: not in a mirror buffer"))
  (let* ((target-fmt el-prisma--target-format)
         (source-ast el-prisma--source-ast)
         (mirror-text (buffer-substring-no-properties
                       (point-min) (point-max)))
         (mirror-ast (el-prisma-parse target-fmt mirror-text))
         (diff (progn
                 (require 'el-prisma-diff)
                 (el-prisma-diff-ast source-ast mirror-ast))))
    (with-output-to-temp-buffer "*el-prisma-diff*"
      (princ (format "Modified: %d node(s)\n" (length (plist-get diff :modified))))
      (princ (format "Inserted: %d node(s)\n" (length (plist-get diff :inserted))))
      (princ (format "Deleted:  %d node(s)\n" (length (plist-get diff :deleted))))
      (princ (format "Unchanged: %d node(s)\n" (length (plist-get diff :unchanged)))))))

;;;; Round-trip validation

(defun el-prisma--normalize-whitespace (text)
  "Collapse runs of blank lines to single blank lines in TEXT."
  (replace-regexp-in-string "\n\\{3,\\}" "\n\n" text))

(defun el-prisma--validate-round-trip (mirror-text target-fmt source-fmt)
  "Validate that MIRROR-TEXT round-trips losslessly.
Converts mirror (TARGET-FMT) -> source (SOURCE-FMT) -> back to TARGET-FMT
and checks for structural differences. Whitespace normalization
(collapsed blank lines) is not flagged. Signals `user-error' if
user declines."
  (condition-case err
      (let* ((mirror-ast (el-prisma-parse target-fmt mirror-text))
             (source-rendered (el-prisma-render source-fmt mirror-ast))
             (re-ast (el-prisma-parse source-fmt source-rendered))
             (re-rendered (el-prisma-render target-fmt re-ast))
             (norm-mirror (el-prisma--normalize-whitespace mirror-text))
             (norm-re (el-prisma--normalize-whitespace re-rendered)))
        (unless (string= norm-mirror norm-re)
          (let ((diff-summary (el-prisma--diff-summary norm-mirror norm-re)))
            (with-output-to-temp-buffer "*el-prisma-validation*"
              (princ "Round-trip validation found structural differences:\n\n")
              (princ diff-summary))
            (unless (yes-or-no-p
                     "Structural differences detected. Commit anyway? ")
              (user-error "Commit cancelled due to validation failure")))))
    (user-error (signal (car err) (cdr err)))
    (error nil)))

(defun el-prisma--diff-summary (text-a text-b)
  "Return a human-readable summary of differences between TEXT-A and TEXT-B."
  (let ((lines-a (split-string text-a "\n"))
        (lines-b (split-string text-b "\n"))
        (diffs nil)
        (ai 0) (bi 0))
    (while (and (< ai (length lines-a)) (< bi (length lines-b))
                (< (length diffs) 8))
      (if (string= (nth ai lines-a) (nth bi lines-b))
          (progn (cl-incf ai) (cl-incf bi))
        (push (format "Line %d changed:\n  before: %s\n  after:  %s"
                      (1+ ai)
                      (truncate-string-to-width (nth ai lines-a) 72)
                      (truncate-string-to-width (nth bi lines-b) 72))
              diffs)
        (cl-incf ai) (cl-incf bi)))
    (when (> (length diffs) 0)
      (setq diffs (nreverse diffs)))
    (if diffs
        (mapconcat #'identity diffs "\n\n")
      (format "Length differs: %d vs %d characters"
              (length text-a) (length text-b)))))

;;;; Mirror minor mode

(defvar el-prisma--skip-kill-confirm nil
  "When non-nil, skip kill-buffer confirmation in mirror mode.")

(defvar el-prisma-mirror-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'el-prisma-commit)
    (define-key map (kbd "C-c C-k") #'el-prisma-cancel)
    (define-key map (kbd "C-c C-p C-c") #'el-prisma-commit)
    (define-key map (kbd "C-c C-p C-k") #'el-prisma-cancel)
    (define-key map (kbd "C-c C-p C-d") #'el-prisma-diff)
    map)
  "Keymap for `el-prisma-mirror-mode'.")

(define-minor-mode el-prisma-mirror-mode
  "Minor mode for El Prisma mirror buffers.
Provides commit/cancel bindings and tracks source buffer linkage."
  :lighter " Prisma"
  :keymap el-prisma-mirror-mode-map
  (if el-prisma-mirror-mode
      (progn
        (add-hook 'kill-buffer-query-functions
                  #'el-prisma--kill-buffer-query nil t)
        (el-prisma--set-header-line))
    (remove-hook 'kill-buffer-query-functions
                 #'el-prisma--kill-buffer-query t)
    (setq header-line-format nil)))

(defun el-prisma--key-for (cmd)
  "Return a human-readable key string for CMD in the mirror mode map."
  (let ((key (where-is-internal cmd el-prisma-mirror-mode-map t)))
    (if key (key-description key) "???")))

(defun el-prisma--set-header-line ()
  "Set `header-line-format' showing source info and keybindings."
  (setq header-line-format
        (list
         (propertize (format " Prisma: %s -> %s "
                             (or el-prisma--source-format "?")
                             (or el-prisma--target-format "?"))
                     'face '(:weight bold :inherit font-lock-function-name-face))
         (when el-prisma--source-buffer
           (propertize (format " [%s] "
                               (buffer-name el-prisma--source-buffer))
                       'face '(:inherit font-lock-string-face)))
         (propertize " │ " 'face 'shadow)
         (propertize (el-prisma--key-for #'el-prisma-commit)
                     'face '(:weight bold :inherit success))
         (propertize " commit " 'face 'shadow)
         (propertize "│ " 'face 'shadow)
         (propertize (el-prisma--key-for #'el-prisma-cancel)
                     'face '(:weight bold :inherit error))
         (propertize " cancel " 'face 'shadow)
         (propertize "│ " 'face 'shadow)
         (propertize (el-prisma--key-for #'el-prisma-diff)
                     'face '(:weight bold :inherit font-lock-constant-face))
         (propertize " diff" 'face 'shadow))))

(defun el-prisma--kill-buffer-query ()
  "Warn before killing a modified mirror buffer."
  (or el-prisma--skip-kill-confirm
      (not (buffer-modified-p))
      (yes-or-no-p "Mirror buffer has uncommitted changes. Kill anyway? ")))

(provide 'el-prisma)
;;; el-prisma.el ends here
