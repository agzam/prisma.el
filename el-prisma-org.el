;;; el-prisma-org.el --- Org parser and renderer -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Org format parser and renderer for the intermediary model.
;; Block structure parsed with regex; inline content parsed with PEG.
;;
;;; Code:

(require 'cl-lib)
(require 'el-prisma-model)
(require 'el-prisma-peg)

;;;; Inline PEG grammar

(defvar el-prisma-org--inline-grammar
  (el-prisma-peg-compile
   '((inline    (+ (/ bold italic verbatim code strike link text-char)))
     (bold      (seq "*" (+ (seq (! "*") any)) "*"))
     (italic    (seq "/" (+ (seq (! "/") any)) "/"))
     (code      (seq "~" (+ (seq (! "~") any)) "~"))
     (verbatim  (seq "=" (+ (seq (! "=") any)) "="))
     (strike    (seq "+" (+ (seq (! "+") any)) "+"))
     (link      (/ bracket-link-desc bracket-link-plain))
     (bracket-link-desc  (seq "[[" link-target "][" link-desc "]]"))
     (bracket-link-plain (seq "[[" link-target "]]"))
     (link-target (+ (seq (! "]") any)))
     (link-desc  (+ (seq (! "]") any)))
     (text-char  any)))
  "Compiled PEG grammar for Org inline content.")

;;;; Inline parser

(defun el-prisma-org--parse-inlines (text start)
  "Parse inline Org content from TEXT starting at byte offset START.
Returns list of model nodes."
  (let ((pos 0)
        (len (length text))
        (nodes nil))
    (while (< pos len)
      (let ((ch (aref text pos)))
        (cond
         ;; Bold: *...*
         ((and (= ch ?*)
               (el-prisma-org--delimited-span text pos ?* len))
          (let* ((span (el-prisma-org--delimited-span text pos ?* len))
                 (inner (substring text (1+ pos) (1- (cdr span))))
                 (children (el-prisma-org--parse-inlines
                            inner (+ start pos 1))))
            (push (el-prisma-model-strong
                   :children children
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Italic: /.../
         ((and (= ch ?/)
               (el-prisma-org--delimited-span text pos ?/ len))
          (let* ((span (el-prisma-org--delimited-span text pos ?/ len))
                 (inner (substring text (1+ pos) (1- (cdr span))))
                 (children (el-prisma-org--parse-inlines
                            inner (+ start pos 1))))
            (push (el-prisma-model-emphasis
                   :children children
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Code: ~...~
         ((and (= ch ?~)
               (el-prisma-org--delimited-span text pos ?~ len))
          (let* ((span (el-prisma-org--delimited-span text pos ?~ len))
                 (value (substring text (1+ pos) (1- (cdr span)))))
            (push (el-prisma-model-code
                   :value value
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Verbatim: =...=
         ((and (= ch ?=)
               (el-prisma-org--delimited-span text pos ?= len))
          (let* ((span (el-prisma-org--delimited-span text pos ?= len))
                 (value (substring text (1+ pos) (1- (cdr span)))))
            (push (el-prisma-model-verbatim
                   :value value
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Strikethrough: +...+
         ((and (= ch ?+)
               (el-prisma-org--delimited-span text pos ?+ len))
          (let* ((span (el-prisma-org--delimited-span text pos ?+ len))
                 (inner (substring text (1+ pos) (1- (cdr span))))
                 (children (el-prisma-org--parse-inlines
                            inner (+ start pos 1))))
            (push (el-prisma-model-strike
                   :children children
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Link: [[target][desc]] or [[target]]
         ((and (= ch ?\[)
               (< (1+ pos) len)
               (= (aref text (1+ pos)) ?\[))
          (if-let* ((link (el-prisma-org--parse-bracket-link
                           text pos len start)))
              (progn
                (push (car link) nodes)
                (setq pos (cdr link)))
            ;; Not a valid link, treat as text
            (push (el-prisma-model-text
                   :value (char-to-string ch)
                   :start (+ start pos)
                   :end (+ start pos 1)
                   :source-format 'org)
                  nodes)
            (setq pos (1+ pos))))
         ;; Plain text character (or unmatched markup char)
         (t
          (let ((text-start pos))
            ;; Always consume at least one char (prevents infinite loop
            ;; when a markup char like / doesn't form a valid span)
            (setq pos (1+ pos))
            ;; Then accumulate consecutive non-markup chars
            (while (and (< pos len)
                        (not (memq (aref text pos)
                                   '(?* ?/ ?~ ?= ?+ ?\[))))
              (setq pos (1+ pos)))
            (push (el-prisma-model-text
                   :value (substring text text-start pos)
                   :start (+ start text-start)
                   :end (+ start pos)
                   :source-format 'org)
                  nodes))))))
    ;; Merge adjacent text nodes
    (el-prisma-org--merge-text-nodes (nreverse nodes))))

(defun el-prisma-org--delimited-span (text pos delimiter len)
  "Find span delimited by DELIMITER char starting at POS in TEXT.
Returns (POS . END) where END is one past closing delimiter, or nil.
Follows Org emphasis rules: opening delimiter must be preceded by
whitespace/BOL/punctuation, closing delimiter must be followed by
whitespace/EOL/punctuation. Content must not start or end with space."
  (when (and (< (1+ pos) len)
             (= (aref text pos) delimiter)
             ;; Pre-condition: BOL or preceded by whitespace/punctuation
             (or (= pos 0)
                 (let ((prev (aref text (1- pos))))
                   (or (memq prev '(?\s ?\t ?\n))
                       (memq prev '(?\( ?\[ ?\{ ?\" ?' ?- ?.)))))
             ;; Content must not start with space
             (not (= (aref text (1+ pos)) ?\s)))
    (let ((i (1+ pos))
          (found nil))
      (while (and (< i len) (not found))
        (when (and (= (aref text i) delimiter)
                   ;; Content must not end with space
                   (not (= (aref text (1- i)) ?\s))
                   ;; Post-condition: EOL or followed by whitespace/punctuation
                   (or (= (1+ i) len)
                       (let ((next (aref text (1+ i))))
                         (or (memq next '(?\s ?\t ?\n))
                             (memq next '(?\) ?\] ?\} ?\" ?' ?- ?. ?, ?\; ?:))))))
          (setq found (1+ i)))
        (setq i (1+ i)))
      (when found
        (cons pos found)))))

(defun el-prisma-org--parse-bracket-link (text pos len start)
  "Parse Org bracket link at POS in TEXT.
Returns (node . end-pos) or nil."
  ;; Expect [[ at pos
  (when (and (< (+ pos 3) len)
             (= (aref text pos) ?\[)
             (= (aref text (1+ pos)) ?\[))
    (let* ((target-start (+ pos 2))
           (rest (substring text target-start))
           ;; Find ][  or ]]
           (desc-sep (string-match "\\]\\[" rest))
           (close (string-match "\\]\\]" rest)))
      (cond
       ;; [[target][desc]]
       ((and desc-sep close (< desc-sep close))
        (let* ((target (substring rest 0 desc-sep))
               (desc-start (+ desc-sep 2))
               (desc (substring rest desc-start close))
               (end-pos (+ target-start close 2))
               (children (list (el-prisma-model-text
                                :value desc
                                :start (+ start target-start desc-start)
                                :end (+ start target-start close)
                                :source-format 'org))))
          (cons (el-prisma-model-link
                 :url target
                 :children children
                 :start (+ start pos)
                 :end (+ start end-pos)
                 :source-format 'org)
                end-pos)))
       ;; [[target]]
       (close
        (let* ((target (substring rest 0 close))
               (end-pos (+ target-start close 2)))
          (cons (el-prisma-model-link
                 :url target
                 :children nil
                 :start (+ start pos)
                 :end (+ start end-pos)
                 :source-format 'org)
                end-pos)))))))

(defun el-prisma-org--merge-text-nodes (nodes)
  "Merge consecutive text nodes in NODES."
  (let (result)
    (dolist (node nodes)
      (if (and result
               (eq (el-prisma-model-type (car result)) 'text)
               (eq (el-prisma-model-type node) 'text))
          (let* ((prev (pop result))
                 (merged (el-prisma-model-text
                          :value (concat (el-prisma-model-prop prev :value)
                                         (el-prisma-model-prop node :value))
                          :start (el-prisma-model-start prev)
                          :end (el-prisma-model-end node)
                          :source-format (el-prisma-model-source-format prev))))
            (push merged result))
        (push node result)))
    (nreverse result)))

;;;; Block-level parser

(defun el-prisma-org-parse (text)
  "Parse Org TEXT and return an intermediary model AST."
  (let* ((lines (split-string text "\n"))
         (blocks (el-prisma-org--parse-blocks lines 0))
         (len (length text)))
    (el-prisma-model-document
     :start 0 :end len
     :source-format 'org
     :children blocks)))

(defun el-prisma-org--parse-blocks (lines pos)
  "Parse LINES into block-level model nodes. POS is byte offset."
  (let ((result nil)
        (i 0)
        (nlines (length lines))
        (cur-pos pos))
    (while (< i nlines)
      (let ((line (nth i lines)))
        (cond
         ;; Blank line - skip
         ((string-empty-p (string-trim line))
          (setq cur-pos (+ cur-pos (length line) 1))
          (setq i (1+ i)))

         ;; Heading: * text
         ((string-match "^\\(\\*+\\) \\(.*\\)$" line)
          (let* ((stars (match-string 1 line))
                 (level (length stars))
                 (heading-text (match-string 2 line))
                 (line-end (+ cur-pos (length line)))
                 (content-start (+ cur-pos level 1))
                 (children (el-prisma-org--parse-inlines
                            heading-text content-start)))
            (push (el-prisma-model-heading
                   :level level
                   :children children
                   :start cur-pos :end line-end
                   :source-format 'org)
                  result))
          (setq cur-pos (+ cur-pos (length line) 1))
          (setq i (1+ i)))

         ;; Code block: #+begin_src ... #+end_src
         ((string-match "^#\\+begin_src\\(?: \\(.*\\)\\)?$"
                        (downcase line))
          (let* ((lang (match-string 1 (downcase line)))
                 (block-start cur-pos)
                 (body-lines nil)
                 (found-end nil))
            ;; Advance past the begin line
            (setq cur-pos (+ cur-pos (length line) 1))
            (setq i (1+ i))
            ;; Collect body lines until #+end_src
            (while (and (< i nlines) (not found-end))
              (let ((bline (nth i lines)))
                (if (string-match "^#\\+end_src" (downcase bline))
                    (progn
                      (setq found-end t)
                      (setq cur-pos (+ cur-pos (length bline) 1))
                      (setq i (1+ i)))
                  (push bline body-lines)
                  (setq cur-pos (+ cur-pos (length bline) 1))
                  (setq i (1+ i)))))
            (let ((body (if body-lines
                            (concat (mapconcat #'identity
                                               (nreverse body-lines) "\n")
                                    "\n")
                          "")))
              (push (el-prisma-model-code-block
                     :language (when (and lang (not (string-empty-p lang)))
                                 lang)
                     :body body
                     :start block-start :end cur-pos
                     :source-format 'org)
                    result))))

         ;; Blockquote: #+begin_quote ... #+end_quote
         ((string-match "^#\\+begin_quote" (downcase line))
          (let* ((block-start cur-pos)
                 (inner-lines nil)
                 (found-end nil))
            (setq cur-pos (+ cur-pos (length line) 1))
            (setq i (1+ i))
            (while (and (< i nlines) (not found-end))
              (let ((bline (nth i lines)))
                (if (string-match "^#\\+end_quote" (downcase bline))
                    (progn
                      (setq found-end t)
                      (setq cur-pos (+ cur-pos (length bline) 1))
                      (setq i (1+ i)))
                  (push bline inner-lines)
                  (setq cur-pos (+ cur-pos (length bline) 1))
                  (setq i (1+ i)))))
            (let* ((inner-text (mapconcat #'identity
                                          (nreverse inner-lines) "\n"))
                   (inner-blocks (el-prisma-org--parse-blocks
                                  (nreverse inner-lines)
                                  (+ block-start (length line) 1))))
              (push (el-prisma-model-blockquote
                     :children inner-blocks
                     :start block-start :end cur-pos
                     :source-format 'org)
                    result))))

         ;; Table: | ... | lines (passthrough)
         ((string-match "^|" line)
          (let* ((table-start cur-pos)
                 (table-lines nil))
            (while (and (< i nlines)
                        (string-match "^|" (nth i lines)))
              (push (nth i lines) table-lines)
              (setq cur-pos (+ cur-pos (length (nth i lines)) 1))
              (setq i (1+ i)))
            (let ((text (mapconcat #'identity
                                   (nreverse table-lines) "\n")))
              (push (el-prisma-model-passthrough
                     :text text
                     :start table-start
                     :end (1- cur-pos)
                     :source-format 'org)
                    result))))

         ;; Horizontal rule: -----
         ((string-match "^-\\{5,\\}$" line)
          (push (el-prisma-model-horiz-rule
                 :start cur-pos
                 :end (+ cur-pos (length line))
                 :source-format 'org)
                result)
          (setq cur-pos (+ cur-pos (length line) 1))
          (setq i (1+ i)))

         ;; List: - item or N. item
         ((string-match "^\\(?:- \\|[0-9]+\\. \\)" line)
          (let* ((list-result (el-prisma-org--parse-list lines i cur-pos)))
            (push (car list-result) result)
            (setq i (cadr list-result))
            (setq cur-pos (caddr list-result))))

         ;; Paragraph: anything else
         (t
          (let* ((para-result (el-prisma-org--parse-paragraph
                               lines i cur-pos)))
            (push (car para-result) result)
            (setq i (cadr para-result))
            (setq cur-pos (caddr para-result)))))))
    (nreverse result)))

(defun el-prisma-org--parse-list (lines start-i pos)
  "Parse a list starting at START-I in LINES at byte POS.
Returns (list-node next-i next-pos)."
  (let ((items nil)
        (i start-i)
        (nlines (length lines))
        (cur-pos pos)
        (list-start pos)
        (ordered nil))
    ;; Detect ordered vs unordered from first line
    (when (string-match "^[0-9]+\\. " (nth i lines))
      (setq ordered t))
    (while (and (< i nlines)
                (let ((line (nth i lines)))
                  (string-match "^\\(?:- \\|[0-9]+\\. \\)" line)))
      (let* ((line (nth i lines))
             (item-start cur-pos)
             ;; Parse checkbox
             (has-checked (string-match
                           "^\\(?:- \\|[0-9]+\\. \\)\\[X\\] " line))
             (has-unchecked (string-match
                             "^\\(?:- \\|[0-9]+\\. \\)\\[ \\] " line))
             (checkbox (cond (has-checked 'checked)
                             (has-unchecked 'unchecked)))
             ;; Extract content after marker (and optional checkbox)
             (content (cond
                       (has-checked
                        (replace-regexp-in-string
                         "^\\(?:- \\|[0-9]+\\. \\)\\[X\\] " "" line))
                       (has-unchecked
                        (replace-regexp-in-string
                         "^\\(?:- \\|[0-9]+\\. \\)\\[ \\] " "" line))
                       (t (replace-regexp-in-string
                           "^\\(?:- \\|[0-9]+\\. \\)" "" line))))
             (content-offset (- (length line) (length content)))
             (children (el-prisma-org--parse-inlines
                        content (+ cur-pos content-offset))))
        (push (el-prisma-model-list-item
               :checkbox checkbox
               :children children
               :start item-start
               :end (+ cur-pos (length line))
               :source-format 'org)
              items)
        (setq cur-pos (+ cur-pos (length line) 1))
        (setq i (1+ i))))
    (list (el-prisma-model-list
           :ordered ordered
           :children (nreverse items)
           :start list-start :end (1- cur-pos)
           :source-format 'org)
          i cur-pos)))

(defun el-prisma-org--parse-paragraph (lines start-i pos)
  "Parse a paragraph starting at START-I in LINES at byte POS.
Collects consecutive non-blank, non-structural lines.
Returns (paragraph-node next-i next-pos)."
  (let ((para-lines nil)
        (i start-i)
        (nlines (length lines))
        (cur-pos pos)
        (para-start pos))
    (while (and (< i nlines)
                (let ((line (nth i lines)))
                  (and (not (string-empty-p (string-trim line)))
                       (not (string-match "^\\*+ " line))
                       (not (string-match "^#\\+begin_" (downcase line)))
                       (not (string-match "^#\\+end_" (downcase line)))
                       (not (string-match "^-\\{5,\\}$" line))
                       (not (string-match "^|" line))
                       (not (string-match "^\\(?:- \\|[0-9]+\\. \\)" line)))))
      (push (nth i lines) para-lines)
      (setq cur-pos (+ cur-pos (length (nth i lines)) 1))
      (setq i (1+ i)))
    (let* ((para-text (mapconcat #'identity (nreverse para-lines) "\n"))
           (children (el-prisma-org--parse-inlines para-text para-start)))
      (list (el-prisma-model-paragraph
             :children children
             :start para-start :end (1- cur-pos)
             :source-format 'org)
            i cur-pos))))

;;;; Renderer - public API

(defun el-prisma-org-render (ast)
  "Render model AST to Org format string."
  (el-prisma-org--render-node ast))

(defun el-prisma-org--render-node (node)
  "Render a single model NODE to Org syntax."
  (pcase (el-prisma-model-type node)
    ('document
     (el-prisma-org--render-blocks (el-prisma-model-children node)))
    ('heading
     (let ((level (or (el-prisma-model-prop node :level) 1)))
       (concat (make-string level ?*) " "
               (el-prisma-org--render-children node))))
    ('paragraph (el-prisma-org--render-children node))
    ('text (el-prisma-model-prop node :value))
    ('strong (concat "*" (el-prisma-org--render-children node) "*"))
    ('emphasis (concat "/" (el-prisma-org--render-children node) "/"))
    ('code (concat "~" (el-prisma-model-prop node :value) "~"))
    ('verbatim (concat "=" (el-prisma-model-prop node :value) "="))
    ('strike (concat "+" (el-prisma-org--render-children node) "+"))
    ('link
     (let ((url (or (el-prisma-model-prop node :url) ""))
           (desc (el-prisma-org--render-children node)))
       (if (and desc (not (string-empty-p desc)))
           (format "[[%s][%s]]" url desc)
         (format "[[%s]]" url))))
    ('image
     (let ((url (or (el-prisma-model-prop node :url) ""))
           (alt (or (el-prisma-model-prop node :alt) "")))
       ;; Render as MD syntax passthrough since Org has no
       ;; distinct image-with-alt syntax
       (format "![%s](%s)" alt url)))
    ('linebreak "\\\\\n")
    ('code-block
     (let ((lang (or (el-prisma-model-prop node :language) ""))
           (body (or (el-prisma-model-prop node :body) "")))
       (concat "#+begin_src " lang "\n" body
               (if (string-suffix-p "\n" body) "" "\n")
               "#+end_src")))
    ('list (el-prisma-org--render-list node))
    ('list-item (el-prisma-org--render-list-item node nil))
    ('blockquote
     (let ((content (mapconcat #'el-prisma-org--render-node
                               (el-prisma-model-children node) "\n")))
       (concat "#+begin_quote\n" content "\n#+end_quote")))
    ('horiz-rule "-----")
    ('passthrough
     (string-trim-right (or (el-prisma-model-prop node :text) "") "\n"))
    (_ (or (el-prisma-model-prop node :text)
           (el-prisma-org--render-children node)))))

(defun el-prisma-org--render-blocks (nodes)
  "Render block-level NODES with proper inter-block spacing."
  (let (parts)
    (dolist (node nodes)
      (let ((rendered (el-prisma-org--render-node node)))
        (when (and parts (not (string-empty-p rendered)))
          (let ((prev (car parts)))
            ;; Don't double up newlines
            (unless (string-suffix-p "\n\n" prev)
              (push "\n\n" parts))))
        (push rendered parts)))
    (apply #'concat (nreverse parts))))

(defun el-prisma-org--render-children (node)
  "Render children of NODE concatenated."
  (mapconcat #'el-prisma-org--render-node
             (el-prisma-model-children node) ""))

(defun el-prisma-org--render-list (node)
  "Render a list NODE to Org."
  (let ((ordered (el-prisma-model-prop node :ordered))
        (items (el-prisma-model-children node))
        (idx 0))
    (mapconcat (lambda (item)
                 (setq idx (1+ idx))
                 (el-prisma-org--render-list-item item ordered idx))
               items "\n")))

(defun el-prisma-org--render-list-item (node ordered &optional idx)
  "Render a list-item NODE to Org."
  (let ((marker (if ordered (format "%d. " (or idx 1)) "- "))
        (checkbox (el-prisma-model-prop node :checkbox))
        (content (el-prisma-org--render-children node)))
    (concat marker
            (pcase checkbox
              ('checked "[X] ")
              ('unchecked "[ ] ")
              (_ ""))
            content)))

(provide 'el-prisma-org)
;;; el-prisma-org.el ends here
