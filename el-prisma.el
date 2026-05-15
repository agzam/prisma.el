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

(defvar-local el-prisma--mirror-text nil
  "Original rendered mirror text, for diffing on commit.")

(defvar-local el-prisma--render-map nil
  "List of (NODE-INDEX SOURCE-NODE MIRROR-START MIRROR-END).
Maps each source AST node to its byte range in the rendered mirror text.")

(defvar-local el-prisma--region-bounds nil
  "When non-nil, (START . END) buffer positions of the converted region.
Nil means the entire buffer was converted.")

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

;;;; Render with map

(defun el-prisma-render-with-map (format ast)
  "Render AST to FORMAT, return (RENDERED-TEXT . RENDER-MAP).
RENDER-MAP is a list of (INDEX SOURCE-NODE MIRROR-START MIRROR-END)."
  (let ((children (el-prisma-model-children ast))
        (pos 0)
        (parts nil)
        (render-map nil)
        (idx 0))
    (dolist (node children)
      (when (and parts (not (string-empty-p (car parts))))
        ;; Add block separator if previous part doesn't already end with \n\n
        (unless (string-suffix-p "\n\n" (car parts))
          (push "\n\n" parts)
          (setq pos (+ pos 2))))
      (let* ((rendered (el-prisma-render-node format node))
             (len (length rendered))
             (start pos)
             (end (+ pos len)))
        (push (list idx node start end) render-map)
        (push rendered parts)
        (setq pos end)
        (cl-incf idx)))
    (cons (apply #'concat (nreverse parts))
          (nreverse render-map))))

(defun el-prisma-render-node (format node)
  "Render a single NODE to FORMAT string."
  (pcase format
    ('org
     (require 'el-prisma-org)
     (el-prisma-org--render-node node))
    ('markdown
     (require 'el-prisma-md)
     (el-prisma-md--render-node node))
    (_ (error "el-prisma: unsupported render format: %s" format))))

;;;; Text diff (mirror before vs after)

(defun el-prisma--text-diff-changed-lines (old-text new-text)
  "Compare OLD-TEXT and NEW-TEXT line by line.
Returns list of 0-based line indices that differ."
  (let ((old-lines (split-string old-text "\n"))
        (new-lines (split-string new-text "\n"))
        (changed nil))
    (cl-loop for i from 0
             for ol in old-lines
             for nl in new-lines
             unless (string= ol nl)
             do (push i changed))
    ;; Handle length differences
    (let ((old-len (length old-lines))
          (new-len (length new-lines)))
      (when (/= old-len new-len)
        (cl-loop for i from (min old-len new-len)
                 below (max old-len new-len)
                 do (push i changed))))
    (nreverse changed)))

(defun el-prisma--lines-to-byte-range (text line-indices)
  "Convert LINE-INDICES (0-based) to a (START . END) byte range in TEXT.
Returns the minimal byte range covering all listed lines."
  (when line-indices
    (let ((lines (split-string text "\n"))
          (min-line (apply #'min line-indices))
          (max-line (apply #'max line-indices))
          (pos 0)
          (start nil)
          (end nil))
      (cl-loop for i from 0
               for line in lines
               do (when (= i min-line) (setq start pos))
                  (setq pos (+ pos (length line) 1))
                  (when (= i max-line) (setq end pos)))
      (when (and start end)
        (cons start (min end (length text)))))))

;;;; Property-based changed node detection

(defun el-prisma--find-changed-nodes-by-props (mirror-buf old-mirror render-map)
  "Find changed nodes by reading `el-prisma-node-idx' text properties.
Properties are set during convert and travel with text through
kill/yank and org-metaup/down. Compares each tagged region's current
text against original text from OLD-MIRROR. Returns list of
\(SOURCE-NODE CURRENT-MIRROR-TEXT) for nodes whose text changed."
  (let ((idx-to-node (make-hash-table :test 'eql))
        (idx-to-orig (make-hash-table :test 'eql))
        (result nil))
    (dolist (entry render-map)
      (let ((idx (nth 0 entry))
            (src-node (nth 1 entry))
            (mstart (nth 2 entry))
            (mend (nth 3 entry)))
        (puthash idx src-node idx-to-node)
        (puthash idx (substring old-mirror mstart mend) idx-to-orig)))
    (with-current-buffer mirror-buf
      (let ((pos (point-min))
            (seen (make-hash-table :test 'eql)))
        (while (< pos (point-max))
          (let ((idx (get-text-property pos 'el-prisma-node-idx))
                (next (or (next-single-property-change
                           pos 'el-prisma-node-idx)
                          (point-max))))
            (when (and idx (not (gethash idx seen)))
              (puthash idx t seen)
              (let ((text (el-prisma--collect-prop-text
                           mirror-buf idx))
                    (orig (gethash idx idx-to-orig))
                    (src-node (gethash idx idx-to-node)))
                (when (and orig src-node
                           (not (string= text orig)))
                  (push (list src-node text) result))))
            (setq pos next)))))
    (nreverse result)))

(defun el-prisma--collect-prop-text (buffer idx)
  "Collect text in BUFFER for node IDX, including internal gaps.
When editing inserts text at a propertied boundary, the new text
may lack the property (nil gap). We include nil-propertied segments
that are sandwiched between two segments of the same IDX."
  (with-current-buffer buffer
    (let ((segments nil)
          (pos (point-min)))
      ;; Collect all (START END PROP-IDX) segments
      (while (< pos (point-max))
        (let ((cur (get-text-property pos 'el-prisma-node-idx))
              (next (or (next-single-property-change
                         pos 'el-prisma-node-idx)
                        (point-max))))
          (push (list pos next cur) segments)
          (setq pos next)))
      (setq segments (nreverse segments))
      ;; Collect text: include segments matching idx, and nil segments
      ;; that are between two segments of the same idx
      (let ((parts nil)
            (len (length segments)))
        (cl-loop for i from 0 below len
                 for seg = (nth i segments)
                 for seg-idx = (nth 2 seg)
                 do (cond
                     ((eql seg-idx idx)
                      (push (buffer-substring-no-properties
                             (nth 0 seg) (nth 1 seg))
                            parts))
                     ;; Nil gap: include only if sandwiched between two
                     ;; segments of the SAME idx (edit inserted text)
                     ((and (null seg-idx)
                           (> i 0)
                           (< i (1- len))
                           (eql idx (nth 2 (nth (1- i) segments)))
                           (eql idx (nth 2 (nth (1+ i) segments))))
                      (push (buffer-substring-no-properties
                             (nth 0 seg) (nth 1 seg))
                            parts))))
        (apply #'concat (nreverse parts))))))

(defun el-prisma--mirror-node-order (mirror-buf)
  "Return the order of `el-prisma-node-idx' values in MIRROR-BUF.
Returns a deduplicated list of indices in the order they appear."
  (with-current-buffer mirror-buf
    (let ((order nil)
          (pos (point-min)))
      (while (< pos (point-max))
        (let ((idx (get-text-property pos 'el-prisma-node-idx))
              (next (or (next-single-property-change
                         pos 'el-prisma-node-idx)
                        (point-max))))
          (when (and idx (not (memql idx order)))
            (push idx order))
          (setq pos next)))
      (nreverse order))))

(defun el-prisma--build-reorder-ops (node-order render-map source-text
                                     mirror-buf source-fmt target-fmt)
  "Build patch ops for reordered nodes.
NODE-ORDER is the current mirror order of node indices.
For each node, uses original source text (preserving formatting)
unless the mirror text changed, in which case re-parses.
Returns list of (START END REPLACEMENT)."
  (let* ((idx-to-entry (make-hash-table :test 'eql))
         (idx-to-orig-mirror (make-hash-table :test 'eql))
         (all-starts nil)
         (all-ends nil)
         (parts nil))
    ;; Build lookups
    (dolist (entry render-map)
      (let ((idx (nth 0 entry))
            (src-node (nth 1 entry))
            (mstart (nth 2 entry))
            (mend (nth 3 entry)))
        (puthash idx (list src-node mstart mend) idx-to-entry)
        (puthash idx (substring (with-current-buffer mirror-buf
                                  el-prisma--mirror-text)
                                mstart mend)
                 idx-to-orig-mirror)))
    ;; Build replacement parts in mirror order
    (dolist (idx node-order)
      (when-let* ((info (gethash idx idx-to-entry)))
        (let* ((src-node (nth 0 info))
               (s (el-prisma-model-start src-node))
               (e (el-prisma-model-end src-node))
               (cur-text (el-prisma--collect-prop-text mirror-buf idx))
               (orig-mirror (gethash idx idx-to-orig-mirror)))
          (push s all-starts)
          (push e all-ends)
          (if (string= cur-text orig-mirror)
              ;; Unchanged: use original source bytes (perfect fidelity)
              (push (substring source-text s e) parts)
            ;; Changed: re-parse and re-render
            (let* ((parsed (el-prisma-parse target-fmt cur-text))
                   (rendered (el-prisma-render source-fmt parsed)))
              (push rendered parts))))))
    (when parts
      (let* ((src-start (apply #'min all-starts))
             (src-end (apply #'max all-ends))
             ;; Strip trailing newlines from each part before joining,
             ;; since source text segments already include trailing \n
             (trimmed (mapcar (lambda (p)
                                (replace-regexp-in-string "\n+\\'" "" p))
                              (nreverse parts)))
             (replacement (mapconcat #'identity trimmed "\n\n")))
        (list (list src-start src-end replacement))))))

;;;; Changed node detection

(defun el-prisma--byte-pos-to-line (text pos)
  "Return the 0-based line number at byte POS in TEXT."
  (let ((line 0))
    (cl-loop for i from 0 below (min pos (length text))
             when (= (aref text i) ?\n) do (cl-incf line))
    line))

(defun el-prisma--extract-lines (text start-line end-line)
  "Extract lines START-LINE to END-LINE (inclusive, 0-based) from TEXT."
  (let ((lines (split-string text "\n")))
    (mapconcat #'identity
               (cl-subseq lines start-line
                           (min (1+ end-line) (length lines)))
               "\n")))

(defun el-prisma--find-changed-nodes (old-mirror new-mirror render-map)
  "Find source nodes affected by changes between OLD-MIRROR and NEW-MIRROR.
Uses RENDER-MAP to correlate mirror byte ranges to source nodes.
Returns list of (SOURCE-NODE EDITED-MIRROR-TEXT) for affected nodes.
Extracts text from NEW-MIRROR using line ranges (stable across edits)."
  (let* ((changed-lines (el-prisma--text-diff-changed-lines
                         old-mirror new-mirror))
         (changed-range (el-prisma--lines-to-byte-range
                         old-mirror changed-lines)))
    (when changed-range
      (let ((cstart (car changed-range))
            (cend (cdr changed-range))
            (result nil))
        (dolist (entry render-map)
          (let ((mstart (nth 2 entry))
                (mend (nth 3 entry))
                (src-node (nth 1 entry)))
            (when (and (< mstart cend) (> mend cstart))
              ;; Map byte range to line range (stable across edits)
              (let* ((start-line (el-prisma--byte-pos-to-line
                                  old-mirror mstart))
                     (end-line (el-prisma--byte-pos-to-line
                                old-mirror (1- mend)))
                     (extracted (el-prisma--extract-lines
                                 new-mirror start-line end-line)))
                (push (list src-node extracted) result)))))
        (nreverse result)))))

(defun el-prisma--merge-adjacent-nodes (changed-nodes)
  "Merge adjacent CHANGED-NODES into combined operations.
Adjacent means their source byte ranges are contiguous (allowing
for inter-block whitespace). Returns list of (SOURCE-START SOURCE-END
COMBINED-MIRROR-TEXT)."
  (when changed-nodes
    (let ((sorted (sort (copy-sequence changed-nodes)
                        (lambda (a b)
                          (< (el-prisma-model-start (car a))
                             (el-prisma-model-start (car b))))))
          (groups nil)
          (cur-start nil)
          (cur-end nil)
          (cur-texts nil))
      (dolist (entry sorted)
        (let* ((src-node (car entry))
               (mirror-text (cadr entry))
               (s (el-prisma-model-start src-node))
               (e (el-prisma-model-end src-node)))
          (if (and cur-end
                   ;; Adjacent if gap is small (whitespace between blocks)
                   (< (- s cur-end) 4))
              ;; Extend current group
              (progn
                (setq cur-end e)
                (push mirror-text cur-texts))
            ;; Start new group
            (when cur-start
              (push (list cur-start cur-end
                          (mapconcat #'identity (nreverse cur-texts) "\n\n"))
                    groups))
            (setq cur-start s
                  cur-end e
                  cur-texts (list mirror-text)))))
      (when cur-start
        (push (list cur-start cur-end
                    (mapconcat #'identity (nreverse cur-texts) "\n\n"))
              groups))
      (nreverse groups))))

(defun el-prisma--build-patch-ops (changed-nodes source-fmt target-fmt)
  "Build patch operations from CHANGED-NODES.
Merges adjacent changed nodes into single operations to preserve
inter-block spacing. Returns list of (SOURCE-START SOURCE-END REPLACEMENT)."
  (let ((merged (el-prisma--merge-adjacent-nodes changed-nodes))
        ops)
    (dolist (group merged)
      (let* ((src-start (nth 0 group))
             (src-end (nth 1 group))
             (mirror-text (nth 2 group))
             (parsed (el-prisma-parse target-fmt mirror-text))
             (rendered (el-prisma-render source-fmt parsed)))
        (push (list src-start src-end rendered) ops)))
    (nreverse ops)))

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
  "Convert current buffer (or region) to TARGET-FORMAT in a mirror buffer.
When a region is active, converts only the selected region."
  (interactive)
  (let* ((source-buf (current-buffer))
         (source-fmt (or (el-prisma--detect-source-format)
                         (error "el-prisma: cannot detect source format")))
         (target-fmt (or target-format
                         (el-prisma--target-for-source source-fmt)
                         (error "el-prisma: no target for %s" source-fmt)))
         (region-active (use-region-p))
         (region-beg (when region-active (region-beginning)))
         (region-end (when region-active (region-end)))
         (source-text (if region-active
                          (buffer-substring-no-properties region-beg region-end)
                        (buffer-substring-no-properties (point-min) (point-max))))
         (source-ast (el-prisma-parse source-fmt source-text))
         (mirror-name (format "*prisma:%s:%s*"
                              (buffer-name source-buf) target-fmt))
         (mirror-buf (get-buffer-create mirror-name))
         (source-tick (buffer-modified-tick source-buf)))
    (let* ((source-pos (1- (point)))
           (win-offset (when (eq (window-buffer) (current-buffer))
                         (count-lines (window-start) (point))))
           (render-result (el-prisma-render-with-map target-fmt source-ast))
           (rendered (car render-result))
           (render-map (cdr render-result))
           (target-pos (el-prisma--map-position
                        source-pos
                        (el-prisma-model-children source-ast)
                        ;; Synthetic nodes with mirror byte positions
                        (mapcar (lambda (entry)
                                  (list :type 'mirror-pos
                                        :start (nth 2 entry)
                                        :end (nth 3 entry)))
                                render-map))))
      (with-current-buffer mirror-buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert rendered)
          ;; Tag each region with source node index. Properties travel
          ;; with text through kill/yank and org-metaup/down, so commit
          ;; can always map mirror regions back to source nodes.
          (dolist (entry render-map)
            (let ((idx (nth 0 entry))
                  (mstart (nth 2 entry))
                  (mend (nth 3 entry)))
              (when (< mstart mend)
                (put-text-property (1+ mstart) (1+ mend)
                                   'el-prisma-node-idx idx)))))
        (funcall (el-prisma--major-mode-for-format target-fmt))
        (setq el-prisma--source-buffer source-buf
              el-prisma--source-ast source-ast
              el-prisma--source-format source-fmt
              el-prisma--target-format target-fmt
              el-prisma--source-tick source-tick
              el-prisma--source-text source-text
              el-prisma--mirror-text rendered
              el-prisma--render-map render-map
              el-prisma--region-bounds
              (when region-active (cons region-beg region-end)))
        (el-prisma-mirror-mode 1)
        (set-buffer-modified-p nil))
      (switch-to-buffer mirror-buf)
      (goto-char (min (1+ target-pos) (point-max)))
      (when win-offset (recenter win-offset)))
    mirror-buf))

(defun el-prisma--apply-patch-ops (source-text ops)
  "Apply patch OPS to SOURCE-TEXT in reverse position order.
Each op is (START END REPLACEMENT). Preserves trailing whitespace
pattern from the original source range."
  (let ((sorted (sort (copy-sequence ops)
                      (lambda (a b) (> (car a) (car b))))))
    (dolist (op sorted)
      (let* ((start (nth 0 op))
             (end (nth 1 op))
             (replacement (nth 2 op))
             (original (substring source-text start end))
             ;; Preserve the original's trailing newline pattern
             (orig-trail (if (string-match "\n+\\'" original)
                             (match-string 0 original) ""))
             (repl-trimmed (replace-regexp-in-string "\n+\\'" "" replacement))
             (fixed (concat repl-trimmed orig-trail)))
        (setq source-text
              (concat (substring source-text 0 start)
                      fixed
                      (substring source-text end)))))
    source-text))

(defun el-prisma-commit ()
  "Text-diff mirror, map changes to source nodes, patch source."
  (interactive)
  (unless el-prisma-mirror-mode
    (error "el-prisma: not in a mirror buffer"))
  (let* ((source-buf el-prisma--source-buffer)
         (source-ast el-prisma--source-ast)
         (source-fmt el-prisma--source-format)
         (target-fmt el-prisma--target-format)
         (source-text el-prisma--source-text)
         (source-tick el-prisma--source-tick)
         (old-mirror el-prisma--mirror-text)
         (render-map el-prisma--render-map)
         (region-bounds el-prisma--region-bounds)
         (mirror-pos (1- (point)))
         (win-offset (when (eq (window-buffer) (current-buffer))
                       (count-lines (window-start) (point))))
         (new-mirror (buffer-substring-no-properties
                      (point-min) (point-max)))
         (target-pos (el-prisma--map-position
                      mirror-pos
                      ;; Synthetic nodes with mirror byte positions
                      (mapcar (lambda (entry)
                                (list :type 'mirror-pos
                                      :start (nth 2 entry)
                                      :end (nth 3 entry)))
                              render-map)
                      (el-prisma-model-children source-ast))))
    (unless (buffer-live-p source-buf)
      (error "el-prisma: source buffer no longer exists"))
    (when (and source-tick
               (/= source-tick (buffer-modified-tick source-buf)))
      (unless (yes-or-no-p
               "Source buffer was modified since conversion. Commit anyway? ")
        (user-error "Commit cancelled")))
    (if (string= old-mirror new-mirror)
        (progn
          (let ((el-prisma--skip-kill-confirm t))
            (kill-buffer (current-buffer)))
          (switch-to-buffer source-buf)
          (goto-char (min (1+ target-pos) (point-max)))
          (when win-offset (recenter win-offset))
          (message "el-prisma: no changes to commit"))
      (let* ((mirror-order (el-prisma--mirror-node-order
                            (current-buffer)))
             ;; Only compare nodes with non-zero renders
             (orig-order (mapcar #'car
                                 (cl-remove-if
                                  (lambda (e) (= (nth 2 e) (nth 3 e)))
                                  render-map)))
             (reordered (not (equal mirror-order orig-order)))
             ;; Hybrid: line-based for edits, property-based for reorder
             (changed (unless reordered
                        (el-prisma--find-changed-nodes
                         old-mirror new-mirror render-map)))
             (ops (cond
                   (reordered
                    (el-prisma--build-reorder-ops
                     mirror-order render-map source-text
                     (current-buffer) source-fmt target-fmt))
                   (changed
                    (el-prisma--build-patch-ops
                     changed source-fmt target-fmt))))
             (patched (if ops
                         (el-prisma--apply-patch-ops source-text ops)
                       source-text))
             (nchanged (+ (length changed)
                          (if reordered 1 0))))
        ;; DATA LOSS SAFEGUARD: mirror was modified (we passed the
        ;; string= check above) but patch produced no source change.
        ;; This means the pipeline failed to propagate edits. NEVER
        ;; silently kill the mirror - the user's work would be lost.
        (when (string= patched source-text)
          (error "el-prisma: edits detected in mirror but patch produced \
no source changes. Mirror preserved - your edits are safe. \
Please report this as a bug"))
        (with-current-buffer source-buf
          (let ((inhibit-read-only t))
            (if region-bounds
                (progn
                  (delete-region (car region-bounds) (cdr region-bounds))
                  (goto-char (car region-bounds))
                  (insert patched))
              (erase-buffer)
              (insert patched))))
        (let ((el-prisma--skip-kill-confirm t))
          (kill-buffer (current-buffer)))
        (switch-to-buffer source-buf)
        (let ((dest (+ (1+ target-pos)
                       (if region-bounds (car region-bounds) 0))))
          (goto-char (min dest (point-max))))
        (when win-offset (recenter win-offset))
        (message "el-prisma: committed %d change(s)" nchanged)))))

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
         (when el-prisma--region-bounds
           (propertize " [region] " 'face '(:inherit warning)))
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
