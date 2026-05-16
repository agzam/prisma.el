;;; prisma-org.el --- Org parser and renderer -*- lexical-binding: t; package-lint-main-file: "prisma.el"; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Org format parser and renderer for the intermediary model.
;; Block structure parsed with regex; inline content parsed with
;; hand-written recursive descent respecting Org emphasis rules.
;;
;;; Code:

(require 'cl-lib)
(require 'prisma-model)

;;;; Inline parser

(defun prisma-org--parse-inlines (text start)
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
               (prisma-org--delimited-span text pos ?* len))
          (let* ((span (prisma-org--delimited-span text pos ?* len))
                 (inner (substring text (1+ pos) (1- (cdr span))))
                 (children (prisma-org--parse-inlines
                            inner (+ start pos 1))))
            (push (prisma-model-strong
                   :children children
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Italic: /.../
         ((and (= ch ?/)
               (prisma-org--delimited-span text pos ?/ len))
          (let* ((span (prisma-org--delimited-span text pos ?/ len))
                 (inner (substring text (1+ pos) (1- (cdr span))))
                 (children (prisma-org--parse-inlines
                            inner (+ start pos 1))))
            (push (prisma-model-emphasis
                   :children children
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Code: ~...~
         ((and (= ch ?~)
               (prisma-org--delimited-span text pos ?~ len))
          (let* ((span (prisma-org--delimited-span text pos ?~ len))
                 (value (substring text (1+ pos) (1- (cdr span)))))
            (push (prisma-model-code
                   :value value
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Verbatim: =...=
         ((and (= ch ?=)
               (prisma-org--delimited-span text pos ?= len))
          (let* ((span (prisma-org--delimited-span text pos ?= len))
                 (value (substring text (1+ pos) (1- (cdr span)))))
            (push (prisma-model-verbatim
                   :value value
                   :start (+ start pos)
                   :end (+ start (cdr span))
                   :source-format 'org)
                  nodes)
            (setq pos (cdr span))))
         ;; Strikethrough: +...+
         ((and (= ch ?+)
               (prisma-org--delimited-span text pos ?+ len))
          (let* ((span (prisma-org--delimited-span text pos ?+ len))
                 (inner (substring text (1+ pos) (1- (cdr span))))
                 (children (prisma-org--parse-inlines
                            inner (+ start pos 1))))
            (push (prisma-model-strike
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
          (if-let* ((link (prisma-org--parse-bracket-link
                           text pos len start)))
              (progn
                (push (car link) nodes)
                (setq pos (cdr link)))
            ;; Not a valid link, treat as text
            (push (prisma-model-text
                   :value (char-to-string ch)
                   :start (+ start pos)
                   :end (+ start pos 1)
                   :source-format 'org)
                  nodes)
            (setq pos (1+ pos))))
         ;; Plain text character (or unmatched markup char).
         ;; Always consume at least one char (prevents infinite loop
         ;; when a markup char like / doesn't form a valid span),
         ;; then scan to the next markup char or end.
         (t
          (let* ((text-start pos)
                 (next-pos (or (string-match "[][*/~=+]" text (1+ pos))
                               len)))
            (push (prisma-model-text
                   :value (substring text text-start next-pos)
                   :start (+ start text-start)
                   :end (+ start next-pos)
                   :source-format 'org)
                  nodes)
            (setq pos next-pos))))))
    ;; Merge adjacent text nodes
    (prisma-org--merge-text-nodes (nreverse nodes))))

(defun prisma-org--delimited-span (text pos delimiter len)
  "Find span delimited by DELIMITER char starting at POS in TEXT.
Returns (POS . END) where END is one past closing delimiter, or nil.
Follows Org emphasis rules: opening delimiter must be preceded by
whitespace/BOL/punctuation, closing delimiter must be followed by
whitespace/EOL/punctuation.  Content must not start or end with space."
  (when (and (< (1+ pos) len)
             (= (aref text pos) delimiter)
             ;; Pre-condition: BOL or preceded by whitespace/punctuation
             (or (= pos 0)
                 (let ((prev (aref text (1- pos))))
                   (or (memq prev '(?\s ?\t ?\n))
                       (memq prev '(?\( ?\[ ?\{ ?\" ?' ?- ?.)))))
             ;; Content must not start with space
             (not (= (aref text (1+ pos)) ?\s)))
    (cl-loop for i from (1+ pos) below len
             when (= (aref text i) delimiter)
             return (when (and ;; Content must not end with space
                           (/= (aref text (1- i)) ?\s)
                           ;; Post-condition: EOL or followed by
                           ;; whitespace/punctuation
                           (or (= (1+ i) len)
                               (memq (aref text (1+ i))
                                     '(?\s ?\t ?\n
                                       ?\) ?\] ?\} ?\" ?' ?- ?.
                                       ?, ?\; ?:))))
                      (cons pos (1+ i))))))

(defun prisma-org--parse-bracket-link (text pos len start)
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
               (children (list (prisma-model-text
                                :value desc
                                :start (+ start target-start desc-start)
                                :end (+ start target-start close)
                                :source-format 'org))))
          (cons (prisma-model-link
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
          (cons (prisma-model-link
                 :url target
                 :children nil
                 :start (+ start pos)
                 :end (+ start end-pos)
                 :source-format 'org)
                end-pos)))))))

(defun prisma-org--merge-text-nodes (nodes)
  "Merge consecutive text nodes in NODES."
  (let (result)
    (dolist (node nodes)
      (if (and result
               (eq (prisma-model-type (car result)) 'text)
               (eq (prisma-model-type node) 'text))
          (let* ((prev (pop result))
                 (merged (prisma-model-text
                          :value (concat (prisma-model-prop prev :value)
                                         (prisma-model-prop node :value))
                          :start (prisma-model-start prev)
                          :end (prisma-model-end node)
                          :source-format (prisma-model-source-format prev))))
            (push merged result))
        (push node result)))
    (nreverse result)))

;;;; Block-level parser

(defun prisma-org-parse (text)
  "Parse Org TEXT and return an intermediary model AST."
  (let* ((lines (split-string text "\n"))
         (blocks (prisma-org--parse-blocks lines 0))
         (len (length text)))
    ;; Clamp children end positions - the line-based parser may
    ;; overshoot by 1 on the last block (counting a \n that isn't there)
    (dolist (block blocks)
      (when (and (prisma-model-end block)
                 (< len (prisma-model-end block)))
        (plist-put block :end len)))
    (prisma-model-document
     :start 0 :end len
     :source-format 'org
     :children blocks)))

(defun prisma-org--collect-block-body (lines start-i cur-pos end-regex)
  "Collect body lines from LINES at START-I (byte CUR-POS) until END-REGEX matches.
The matching line (compared against its downcase) is consumed but not
included in the body.  Returns plist (:body BODY-LINES :end-i I :end-pos POS).
If END-REGEX never matches, BODY-LINES is everything to end of LINES."
  (cl-loop with pos = cur-pos
           with body = nil
           for i from start-i below (length lines)
           for bline = (nth i lines)
           if (string-match end-regex (downcase bline))
             return (list :body (nreverse body)
                          :end-i (1+ i)
                          :end-pos (+ pos (length bline) 1))
           else do (push bline body)
                   (setq pos (+ pos (length bline) 1))
           finally return (list :body (nreverse body)
                                :end-i i
                                :end-pos pos)))

(defun prisma-org--parse-blocks (lines pos)
  "Parse LINES into block-level model nodes.  POS is byte offset."
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
                 (children (prisma-org--parse-inlines
                            heading-text content-start)))
            (push (prisma-model-heading
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
                 (after-begin-pos (+ cur-pos (length line) 1))
                 (collected (prisma-org--collect-block-body
                             lines (1+ i) after-begin-pos
                             "^#\\+end_src"))
                 (body-lines (plist-get collected :body))
                 (body (if body-lines
                           (concat (mapconcat #'identity body-lines "\n")
                                   "\n")
                         "")))
            (setq i (plist-get collected :end-i))
            (setq cur-pos (plist-get collected :end-pos))
            (push (prisma-model-code-block
                   :language (when (and lang (not (string-empty-p lang)))
                               lang)
                   :body body
                   :start block-start :end cur-pos
                   :source-format 'org)
                  result)))

         ;; Blockquote: #+begin_quote ... #+end_quote
         ((string-match "^#\\+begin_quote" (downcase line))
          (let* ((block-start cur-pos)
                 (after-begin-pos (+ cur-pos (length line) 1))
                 (collected (prisma-org--collect-block-body
                             lines (1+ i) after-begin-pos
                             "^#\\+end_quote"))
                 (inner-blocks (prisma-org--parse-blocks
                                (plist-get collected :body)
                                after-begin-pos)))
            (setq i (plist-get collected :end-i))
            (setq cur-pos (plist-get collected :end-pos))
            (push (prisma-model-blockquote
                   :children inner-blocks
                   :start block-start :end cur-pos
                   :source-format 'org)
                  result)))

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
              (push (prisma-model-passthrough
                     :text text
                     :start table-start
                     :end (1- cur-pos)
                     :source-format 'org)
                    result))))

         ;; Horizontal rule: -----
         ((string-match "^-\\{5,\\}$" line)
          (push (prisma-model-horiz-rule
                 :start cur-pos
                 :end (+ cur-pos (length line))
                 :source-format 'org)
                result)
          (setq cur-pos (+ cur-pos (length line) 1))
          (setq i (1+ i)))

         ;; List: - item or N. item
         ((string-match "^\\(?:- \\|[0-9]+\\. \\)" line)
          (pcase-let ((`(,node ,next-i ,next-pos)
                       (prisma-org--parse-list lines i cur-pos)))
            (push node result)
            (setq i next-i)
            (setq cur-pos next-pos)))

         ;; Paragraph: anything else
         (t
          (pcase-let ((`(,node ,next-i ,next-pos)
                       (prisma-org--parse-paragraph lines i cur-pos)))
            (push node result)
            (setq i next-i)
            (setq cur-pos next-pos))))))
    (nreverse result)))

(defun prisma-org--parse-list (lines start-i pos)
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
             (children (prisma-org--parse-inlines
                        content (+ cur-pos content-offset))))
        (push (prisma-model-list-item
               :checkbox checkbox
               :children children
               :start item-start
               :end (+ cur-pos (length line))
               :source-format 'org)
              items)
        (setq cur-pos (+ cur-pos (length line) 1))
        (setq i (1+ i))))
    (list (prisma-model-list
           :ordered ordered
           :children (nreverse items)
           :start list-start :end (1- cur-pos)
           :source-format 'org)
          i cur-pos)))

(defun prisma-org--parse-paragraph (lines start-i pos)
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
           (children (prisma-org--parse-inlines para-text para-start)))
      (list (prisma-model-paragraph
             :children children
             :start para-start :end (1- cur-pos)
             :source-format 'org)
            i cur-pos))))

;;;; Renderer - public API

(defun prisma-org-render (ast)
  "Render model AST to Org format string."
  (prisma-org--render-node ast))

(defun prisma-org--render-node (node)
  "Render a single model NODE to Org syntax."
  (pcase (prisma-model-type node)
    ('document
     (prisma-org--render-blocks (prisma-model-children node)))
    ('heading
     (let ((level (or (prisma-model-prop node :level) 1)))
       (concat (make-string level ?*) " "
               (prisma-org--render-children node))))
    ('paragraph (prisma-org--render-children node))
    ('text (prisma-model-prop node :value))
    ('strong (concat "*" (prisma-org--render-children node) "*"))
    ('emphasis (concat "/" (prisma-org--render-children node) "/"))
    ('code (concat "~" (prisma-model-prop node :value) "~"))
    ('verbatim (concat "=" (prisma-model-prop node :value) "="))
    ('strike (concat "+" (prisma-org--render-children node) "+"))
    ('link
     (let ((url (or (prisma-model-prop node :url) ""))
           (desc (prisma-org--render-children node)))
       (if (and desc (not (string-empty-p desc)))
           (format "[[%s][%s]]" url desc)
         (format "[[%s]]" url))))
    ('image
     (let ((url (or (prisma-model-prop node :url) ""))
           (alt (or (prisma-model-prop node :alt) "")))
       ;; Render as MD syntax passthrough since Org has no
       ;; distinct image-with-alt syntax
       (format "![%s](%s)" alt url)))
    ('linebreak "\\\\\n")
    ('code-block
     (let ((lang (or (prisma-model-prop node :language) ""))
           (body (or (prisma-model-prop node :body) "")))
       (concat "#+begin_src " lang "\n" body
               (if (string-suffix-p "\n" body) "" "\n")
               "#+end_src")))
    ('list (prisma-org--render-list node))
    ('list-item (prisma-org--render-list-item node nil))
    ('blockquote
     (let ((content (mapconcat #'prisma-org--render-node
                               (prisma-model-children node) "\n")))
       (concat "#+begin_quote\n" content "\n#+end_quote")))
    ('horiz-rule "-----")
    ('passthrough
     (string-trim-right (or (prisma-model-prop node :text) "") "\n"))
    (_ (or (prisma-model-prop node :text)
           (prisma-org--render-children node)))))

(defun prisma-org--render-blocks (nodes)
  "Render block-level NODES with proper inter-block spacing."
  (prisma-model-render-blocks nodes #'prisma-org--render-node))

(defun prisma-org--render-children (node)
  "Render children of NODE concatenated."
  (mapconcat #'prisma-org--render-node
             (prisma-model-children node) ""))

(defun prisma-org--render-list (node)
  "Render a list NODE to Org."
  (let ((ordered (prisma-model-prop node :ordered))
        (items (prisma-model-children node))
        (idx 0))
    (mapconcat (lambda (item)
                 (setq idx (1+ idx))
                 (prisma-org--render-list-item item ordered idx))
               items "\n")))

(defun prisma-org--render-list-item (node ordered &optional idx)
  "Render a list-item NODE to Org.
ORDERED non-nil emits an ordered marker using IDX (defaulting to 1);
otherwise emits an unordered \"- \" marker."
  (let ((marker (if ordered (format "%d. " (or idx 1)) "- "))
        (checkbox (prisma-model-prop node :checkbox))
        (content (prisma-org--render-children node)))
    (concat marker
            (pcase checkbox
              ('checked "[X] ")
              ('unchecked "[ ] ")
              (_ ""))
            content)))

(provide 'prisma-org)
;;; prisma-org.el ends here
