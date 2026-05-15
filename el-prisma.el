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
;; Convert buffer content between formats (Markdown<->Org) while
;; preserving lossless round-trips.  Creates mirror buffers for
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
(declare-function el-prisma-diff-ast "el-prisma-diff")
(declare-function el-prisma-model-children "el-prisma-model")
(declare-function el-prisma-model-start "el-prisma-model")
(declare-function el-prisma-model-end "el-prisma-model")
(declare-function el-prisma-md--render-node "el-prisma-md")
(declare-function el-prisma-org--render-node "el-prisma-org")

;;;; Customization

(defcustom el-prisma-default-targets
  '((markdown-mode . org)
    (gfm-mode . org))
  "Alist mapping source major mode to default target format symbol."
  :type '(alist :key-type symbol :value-type symbol)
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

(defvar-local el-prisma--source-texts nil
  "Vector of original source text per top-level node.
Indexed by render-map node index.")

(defvar-local el-prisma--mirror-texts nil
  "Vector of original mirror text per top-level node.
Indexed by render-map node index.")

;;;; Format detection

(defun el-prisma--detect-source-format (&optional buffer)
  "Detect the source format of BUFFER (or current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((derived-mode-p 'gfm-mode 'markdown-mode) 'markdown)
     ((derived-mode-p 'org-mode) 'org)
     (t nil))))

(defun el-prisma--target-for-source (source-format)
  "Return default target format for SOURCE-FORMAT."
  (pcase source-format
    ('markdown 'org)
    ('org 'markdown)
    (_ nil)))

(defun el-prisma--major-mode-for-format (format)
  "Return the major mode function for FORMAT."
  (pcase format
    ('org 'org-mode)
    ('markdown 'markdown-mode)
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

;;;; Unified commit: re-parse + property-matching

(defun el-prisma--scan-property-intervals ()
  "Scan current buffer for `el-prisma-node-idx' property intervals.
Returns list of (BUF-START BUF-END NODE-IDX-OR-NIL)."
  (let ((segments nil)
        (pos (point-min)))
    (while (< pos (point-max))
      (let ((cur (get-text-property pos 'el-prisma-node-idx))
            (next (or (next-single-property-change
                       pos 'el-prisma-node-idx)
                      (point-max))))
        (push (list pos next cur) segments)
        (setq pos next)))
    (nreverse segments)))

(defun el-prisma--match-nodes (new-children _mirror-text segments
                                             &optional num-old-nodes)
  "Match NEW-CHILDREN to original nodes via text-property hints.
NEW-CHILDREN: AST nodes from re-parsing the edited mirror.
_MIRROR-TEXT: unused, kept for API symmetry with build-unified-replacement.
SEGMENTS: property intervals from `el-prisma--scan-property-intervals'.
NUM-OLD-NODES: when non-nil, total count of original nodes.
  Used for positional gap-fill when properties were wiped by edits.
Returns a vector parallel to NEW-CHILDREN where each element is
the old node-idx (integer) if matched, or nil."
  (let* ((n (length new-children))
         (matches (make-vector n nil))
         (claim-map (make-hash-table :test 'eql)))
    ;; Phase 1: find candidate match for each new node
    (cl-loop
     for node in new-children
     for i from 0
     do (when-let* ((ns (el-prisma-model-start node))
                    (ne (el-prisma-model-end node))
                    ;; String positions -> buffer positions
                    (buf-s (1+ ns))
                    (buf-e (1+ ne)))
          (let (idx-set)
            (dolist (seg segments)
              (let ((ss (nth 0 seg))
                    (se (nth 1 seg))
                    (si (nth 2 seg)))
                (when (and si (< ss buf-e) (> se buf-s))
                  (cl-pushnew si idx-set))))
            ;; Single unique idx -> candidate
            (when (= (length idx-set) 1)
              (aset matches i (car idx-set))))))
    ;; Phase 2: resolve conflicts (multiple new nodes claiming same old)
    (cl-loop
     for i from 0 below n
     for idx = (aref matches i)
     when idx
     do (pcase (gethash idx claim-map :unclaimed)
          (:unclaimed (puthash idx i claim-map))
          ((pred integerp)
           (aset matches (gethash idx claim-map) nil)
           (aset matches i nil)
           (puthash idx :conflict claim-map))
          (:conflict
           (aset matches i nil))))
    ;; Phase 3: positional gap-fill.  When num-old-nodes is known and
    ;; equals n, fill unmatched slots with unclaimed old indices.
    ;; This handles the common case where replace-match wiped text
    ;; properties on the edited node(s).
    (when (and num-old-nodes (= n num-old-nodes))
      (let ((claimed (make-hash-table :test 'eql)))
        (cl-loop for i from 0 below n
                 for idx = (aref matches i)
                 when idx do (puthash idx t claimed))
        (let ((unclaimed
               (cl-loop for idx from 0 below num-old-nodes
                        unless (gethash idx claimed)
                        collect idx))
              (gaps (cl-loop for i from 0 below n
                             unless (aref matches i) collect i)))
          (when (and gaps unclaimed (= (length gaps) (length unclaimed)))
            (let ((candidate (copy-sequence matches)))
              (cl-loop for g in gaps
                       for u in unclaimed
                       do (aset candidate g u))
              ;; Accept only if result is monotonically increasing
              (let ((mono t) (prev -1))
                (cl-loop for i from 0 below n
                         for v = (aref candidate i)
                         while mono
                         do (if (and v (> v prev))
                                (setq prev v)
                              (when (and v (<= v prev))
                                (setq mono nil))))
                (when mono
                  (setq matches candidate))))))))
    matches))

(defun el-prisma--same-structure-p (matches num-old-nodes)
  "Return t when MATCHES is an identity mapping of length NUM-OLD-NODES.
Same node count, same order, every new node maps to its corresponding
original - the edit preserved document structure."
  (and (= (length matches) num-old-nodes)
       (cl-loop for i from 0 below num-old-nodes
                always (eql (aref matches i) i))))

(defun el-prisma--patchable-p (matches num-old-nodes
                                       new-children new-mirror mirror-texts)
  "Return t when MATCHES allows safe in-place patching.
For near-same-structure cases (parser round-trip node-count drift):
monotonic non-nil entries, no deletions, high coverage, and unmatched
new children are parser artifacts (not user-added content).
NEW-CHILDREN, NEW-MIRROR, and MIRROR-TEXTS are needed to inspect
unmatched nodes."
  (let ((n (length matches))
        (prev -1) (matched 0) (ok t))
    (cl-loop for i from 0 below n
             for v = (aref matches i)
             while ok
             when v do (if (> v prev)
                           (progn (setq prev v) (cl-incf matched))
                         (setq ok nil)))
    (and ok
         (> matched 0)
         ;; No deletions: at least as many new children as old nodes
         (>= n num-old-nodes)
         ;; High coverage: nearly all old nodes matched
         (>= matched (- num-old-nodes 3))
         ;; Unmatched new children are parser artifacts, not user content.
         ;; Accept if: each unmatched node's text is found in a matched
         ;; node, OR total unmatched chars < 2% of document size.
         (let ((doc-len (length new-mirror))
               (unmatched-chars 0)
               (all-found t))
           (cl-loop
            for i from 0 below n
            for v = (aref matches i)
            unless v do
            (let* ((node (nth i new-children))
                   (txt (string-trim
                         (substring new-mirror
                                    (el-prisma-model-start node)
                                    (el-prisma-model-end node)))))
              (cl-incf unmatched-chars (length txt))
              (unless (or (string-empty-p txt)
                          (cl-loop
                           for j from 0 below n
                           for vj = (aref matches j)
                           thereis
                           (and vj
                                (< vj (length mirror-texts))
                                (string-search txt
                                               (aref mirror-texts vj)))))
                (setq all-found nil))))
           (or all-found
               (< unmatched-chars (/ doc-len 50)))))))

(defun el-prisma--patch-in-place
    (source-text render-map matches new-children new-mirror
     mirror-texts source-fmt target-fmt)
  "Patch SOURCE-TEXT in place, replacing only changed byte ranges.
For patchable edits (monotonic matches) each matched new node maps
to an original.  Only nodes whose mirror text changed get re-rendered
and spliced into SOURCE-TEXT at the original byte range.  Unmatched
new-children (nil in MATCHES) are skipped - they have no source byte
range.  Everything else stays byte-identical."
  (let ((ops nil))
    (cl-loop
     for node in new-children
     for i from 0
     do (when-let* ((old-idx (aref matches i))
                    (ns (el-prisma-model-start node))
                    (ne (el-prisma-model-end node))
                    (cur-text (substring new-mirror ns ne)))
          (unless (string= cur-text (aref mirror-texts old-idx))
            (let* ((entry (nth old-idx render-map))
                   (src-node (nth 1 entry))
                   (src-start (el-prisma-model-start src-node))
                   (src-end (el-prisma-model-end src-node))
                   (orig-slice (substring source-text src-start src-end))
                   (rendered (el-prisma-render
                              source-fmt
                              (el-prisma-parse target-fmt cur-text)))
                   ;; Preserve trailing-newline pattern from original
                   (orig-trail (if (string-match "\n+\\'" orig-slice)
                                   (match-string 0 orig-slice)
                                 ""))
                   (new-trail (if (string-match "\n+\\'" rendered)
                                  (match-string 0 rendered)
                                ""))
                   (adjusted
                    (if (string= orig-trail new-trail)
                        rendered
                      (concat (replace-regexp-in-string "\n+\\'" "" rendered)
                              orig-trail))))
              (push (list src-start src-end adjusted) ops)))))
    ;; Apply in reverse position order so earlier offsets stay valid
    (setq ops (sort ops (lambda (a b) (> (car a) (car b)))))
    (let ((result source-text))
      (dolist (op ops)
        (let ((s (nth 0 op))
              (e (nth 1 op))
              (text (nth 2 op)))
          (setq result (concat (substring result 0 s)
                               text
                               (substring result e)))))
      result)))

(defun el-prisma--build-unified-replacement
    (new-children mirror-text matches
     source-texts mirror-texts source-fmt target-fmt
     &optional source-text render-map)
  "Build complete replacement source text via the unified algorithm.
For each node in NEW-CHILDREN: if it matches an old node and its
mirror text is unchanged, emit the original source bytes (perfect
fidelity).  Otherwise re-parse the mirror text and render to source
format.
When SOURCE-TEXT and RENDER-MAP are provided, inter-block whitespace
from the original source is preserved between consecutive matched
unchanged nodes.
Returns the assembled source string."
  (let (parts)
    (cl-loop
     for node in new-children
     for i from 0
     do (let* ((ns (el-prisma-model-start node))
               (ne (el-prisma-model-end node))
               (cur-text (substring mirror-text ns ne))
               (old-idx (aref matches i))
               (part
                (if (and old-idx
                         (< old-idx (length mirror-texts))
                         (string= cur-text (aref mirror-texts old-idx)))
                    ;; Unchanged node: use original source bytes
                    (aref source-texts old-idx)
                  ;; Changed or new: round-trip through AST
                  (let* ((parsed (el-prisma-parse target-fmt cur-text))
                         (rendered (el-prisma-render source-fmt parsed)))
                    rendered))))
          (push part parts)))
    (setq parts (nreverse parts))
    ;; Build source-node lookup for inter-block whitespace
    (let ((src-nodes (when render-map
                       (let ((v (make-vector (length render-map) nil)))
                         (dolist (entry render-map)
                           (aset v (nth 0 entry) (nth 1 entry)))
                         v))))
      (let ((trimmed (mapcar (lambda (p)
                               (replace-regexp-in-string "\n+\\'" "" p))
                             parts))
            result-parts)
        (cl-loop
         for i from 0 below (length trimmed)
         do (push (nth i trimmed) result-parts)
         ;; Determine inter-block separator
         when (< i (1- (length trimmed)))
         do (let* ((cur-idx (aref matches i))
                   (next-idx (when (< (1+ i) (length matches))
                               (aref matches (1+ i))))
                   (sep
                    (if (and source-text src-nodes
                             cur-idx next-idx
                             (< cur-idx (length src-nodes))
                             (< next-idx (length src-nodes))
                             ;; Consecutive in original order only
                             (= next-idx (1+ cur-idx))
                             (aref src-nodes cur-idx)
                             (aref src-nodes next-idx))
                        (let* ((end-cur (el-prisma-model-end
                                         (aref src-nodes cur-idx)))
                               (start-next (el-prisma-model-start
                                            (aref src-nodes next-idx)))
                               ;; Account for trailing newlines stripped
                               ;; from the current part.  The source node
                               ;; text includes them, but we trimmed
                               ;; parts above, so the separator must
                               ;; carry them.
                               (src-cur-text
                                (substring source-text
                                           (el-prisma-model-start
                                            (aref src-nodes cur-idx))
                                           end-cur))
                               (content-end
                                (if (string-match "\n+\\'" src-cur-text)
                                    (+ (el-prisma-model-start
                                        (aref src-nodes cur-idx))
                                       (match-beginning 0))
                                  end-cur)))
                          (if (< content-end start-next)
                              (substring source-text content-end start-next)
                            "\n\n"))
                      "\n\n")))
              (push sep result-parts)))
        (apply #'concat (nreverse result-parts))))))

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
              (when region-active (cons region-beg region-end))
              el-prisma--source-texts
              (vconcat
               (mapcar (lambda (entry)
                         (let ((sn (nth 1 entry)))
                           (substring source-text
                                      (el-prisma-model-start sn)
                                      (el-prisma-model-end sn))))
                       render-map))
              el-prisma--mirror-texts
              (vconcat
               (mapcar (lambda (entry)
                         (substring rendered (nth 2 entry) (nth 3 entry)))
                       render-map)))
        (el-prisma-mirror-mode 1)
        (set-buffer-modified-p nil))
      (switch-to-buffer mirror-buf)
      (goto-char (min (1+ target-pos) (point-max)))
      (when win-offset (recenter win-offset)))
    mirror-buf))

(defvar el-prisma-mirror-mode)            ; defined by define-minor-mode below

(defvar el-prisma--skip-kill-confirm nil
  "When non-nil, skip kill-buffer confirmation in mirror mode.")

(defun el-prisma-commit ()
  "Commit mirror edits back to source via unified re-parse + property-match.
Re-parses the entire mirror, matches new AST nodes to originals via
text properties, emits original source bytes for unchanged nodes."
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
         (source-texts el-prisma--source-texts)
         (mirror-texts el-prisma--mirror-texts)
         (region-bounds el-prisma--region-bounds)
         (mirror-pos (1- (point)))
         (win-offset (when (eq (window-buffer) (current-buffer))
                       (count-lines (window-start) (point))))
         (new-mirror (buffer-substring-no-properties
                      (point-min) (point-max)))
         (target-pos (el-prisma--map-position
                      mirror-pos
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
        ;; No changes: return to source
        (progn
          (let ((el-prisma--skip-kill-confirm t))
            (kill-buffer (current-buffer)))
          (switch-to-buffer source-buf)
          (goto-char (min (1+ target-pos) (point-max)))
          (when win-offset (recenter win-offset))
          (message "el-prisma: no changes to commit"))
      ;; Unified commit: re-parse mirror, match nodes, build replacement
      (let* ((segments (el-prisma--scan-property-intervals))
             (new-ast (el-prisma-parse target-fmt new-mirror))
             (new-children (el-prisma-model-children new-ast))
             (matches (el-prisma--match-nodes
                       new-children new-mirror segments
                       (length mirror-texts)))
             (same-structure (or (el-prisma--same-structure-p
                                  matches (length mirror-texts))
                                 (el-prisma--patchable-p
                                  matches (length mirror-texts)
                                  new-children new-mirror mirror-texts)))
             (patched (if same-structure
                          (el-prisma--patch-in-place
                           source-text render-map matches
                           new-children new-mirror
                           mirror-texts source-fmt target-fmt)
                        (el-prisma--build-unified-replacement
                         new-children new-mirror matches
                         source-texts mirror-texts
                         source-fmt target-fmt
                         source-text render-map)))
             (nchanged
              (cl-loop
               for i from 0 below (length new-children)
               for node in new-children
               for old-idx = (aref matches i)
               count (or (null old-idx)
                         (>= old-idx (length mirror-texts))
                         (not (string= (substring new-mirror
                                                  (el-prisma-model-start node)
                                                  (el-prisma-model-end node))
                                       (aref mirror-texts old-idx)))))))
        ;; Data loss safeguard (reassembly path only; patch-in-place
        ;; legitimately returns source-text unchanged when only inter-
        ;; block mirror whitespace was edited)
        (when (and (not same-structure)
                   (string= patched source-text))
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
