;;; prisma-md.el --- Markdown parser and renderer -*- lexical-binding: t; package-lint-main-file: "prisma.el"; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Markdown parser using dual tree-sitter grammars (block + inline)
;; and renderer that emits Markdown from the intermediary model.
;;
;;; Code:

(require 'cl-lib)
(require 'prisma-model)
(require 'prisma-ts)

;;;; Parser - public API

(defun prisma-md-parse (text)
  "Parse Markdown TEXT and return an intermediary model AST.
Returns AST with 0-based string positions (matching TEXT indices)."
  (with-temp-buffer
    (insert text)
    (let* ((block-parser (treesit-parser-create 'markdown))
           (inline-parser (treesit-parser-create 'markdown-inline))
           (block-root (treesit-parser-root-node block-parser))
           (inline-root (treesit-parser-root-node inline-parser))
           (buf-text (buffer-string)))
      ;; Prepend a NUL so (substring text buf-pos) works directly with
      ;; tree-sitter's 1-based buffer positions during parsing.
      ;; The final AST positions are shifted to 0-based via
      ;; prisma-md--shift-positions before returning.
      (let* ((nul-text (concat "\0" buf-text))
             (ast (prisma-model-document
                   :start 1 :end (1+ (length buf-text))
                   :source-format 'markdown
                   :children (prisma-md--process-block-children
                              block-root inline-root
                              nul-text))))
        (prisma-md--shift-positions ast -1)))))

;;;; Position normalization

(defun prisma-md--shift-positions (node offset)
  "Shift all :start/:end positions in NODE tree by OFFSET."
  (let ((start (prisma-model-start node))
        (end (prisma-model-end node))
        (children (prisma-model-children node))
        (props (prisma-model-props node)))
    (list :type (prisma-model-type node)
          :start (when start (+ start offset))
          :end (when end (+ end offset))
          :source-format (prisma-model-source-format node)
          :children (mapcar (lambda (c)
                              (prisma-md--shift-positions c offset))
                            children)
          :props (prisma-md--shift-props props offset))))

(defun prisma-md--shift-props (props offset)
  "Shift any node-valued entries in PROPS by OFFSET."
  (when props
    (let (result)
      (cl-loop for (k v) on props by #'cddr
               do (push k result)
                  (push (if (prisma-model-node-p v)
                            (prisma-md--shift-positions v offset)
                          v)
                        result))
      (nreverse result))))

;;;; Block-level processing

(defun prisma-md--content-node-p (type)
  "Return non-nil if TYPE is a content block node type."
  (member type '("section" "atx_heading" "paragraph" "list" "list_item"
                 "fenced_code_block" "block_quote" "thematic_break"
                 "pipe_table")))

(defun prisma-md--process-block-children (parent inline-root text)
  "Process named children of PARENT, unwrapping sections transparently.
INLINE-ROOT is the inline tree-sitter root.  TEXT is the buffer text
\(NUL-prefixed so positions are 1-based)."
  (let (result)
    (dolist (child (treesit-node-children parent t))
      (let ((type (treesit-node-type child)))
        (when (prisma-md--content-node-p type)
          (if (string= type "section")
              (dolist (sub (prisma-md--process-block-children
                           child inline-root text))
                (push sub result))
            (when-let* ((node (prisma-md--process-block
                               child inline-root text)))
              (push node result))))))
    (nreverse result)))

(defun prisma-md--process-block (node inline-root text)
  "Convert a block-level treesit NODE to a model node.
INLINE-ROOT is the inline tree-sitter root; TEXT is the source string."
  (let ((type (treesit-node-type node))
        (start (treesit-node-start node))
        (end (treesit-node-end node)))
    (pcase type
      ("atx_heading"
       (prisma-md--process-heading node inline-root text))
      ("paragraph"
       (prisma-md--process-paragraph node inline-root text))
      ("list"
       (prisma-md--process-list node inline-root text))
      ("fenced_code_block"
       (prisma-md--process-code-block node text))
      ("block_quote"
       (prisma-md--process-blockquote node inline-root text))
      ("thematic_break"
       (prisma-model-horiz-rule
        :start start :end end :source-format 'markdown))
      (_
       (prisma-model-passthrough
        :text (string-trim-right (substring text start end) "\n")
        :start start :end end :source-format 'markdown)))))

(defun prisma-md--inline-children (node inline-root text)
  "Return inline children list parsed from NODE's \"inline\" child, or nil.
INLINE-ROOT is the inline tree-sitter root; TEXT is the source string."
  (when-let* ((inline-node (prisma-ts-child-by-type node "inline")))
    (prisma-md--process-inlines inline-node inline-root text)))

(defun prisma-md--heading-level (node)
  "Return heading level (1-6) for an atx_heading NODE."
  (if-let* ((marker (treesit-node-child node 0))
            (mtype (treesit-node-type marker))
            (_ (string-match "atx_h\\([1-6]\\)_marker" mtype)))
      (string-to-number (match-string 1 mtype))
    1))

(defun prisma-md--process-heading (node inline-root text)
  "Process an atx_heading NODE.
INLINE-ROOT and TEXT are forwarded to inline parsing."
  (prisma-model-heading
   :level (prisma-md--heading-level node)
   :children (prisma-md--inline-children node inline-root text)
   :start (treesit-node-start node)
   :end (treesit-node-end node)
   :source-format 'markdown))

(defun prisma-md--process-paragraph (node inline-root text)
  "Process a paragraph NODE.
INLINE-ROOT and TEXT are forwarded to inline parsing."
  (prisma-model-paragraph
   :children (prisma-md--inline-children node inline-root text)
   :start (treesit-node-start node)
   :end (treesit-node-end node)
   :source-format 'markdown))

(defun prisma-md--process-list (node inline-root text)
  "Process a list NODE.
INLINE-ROOT and TEXT are forwarded to inline parsing."
  (let* ((start (treesit-node-start node))
         (end (treesit-node-end node))
         (items (prisma-ts-children-by-type node "list_item"))
         (ordered (when (car items)
                    (not (null (prisma-ts-child-by-type
                                (car items) "list_marker_dot")))))
         (children (mapcar (lambda (item)
                             (prisma-md--process-list-item
                              item inline-root text))
                           items)))
    (prisma-model-list
     :ordered ordered :children children
     :start start :end end :source-format 'markdown)))

(defun prisma-md--list-item-checkbox (node)
  "Return checkbox state for NODE: `checked', `unchecked', or nil."
  (cond ((prisma-ts-child-by-type node "task_list_marker_checked")
         'checked)
        ((prisma-ts-child-by-type node "task_list_marker_unchecked")
         'unchecked)))

(defun prisma-md--process-list-item (node inline-root text)
  "Process a list_item NODE.
INLINE-ROOT and TEXT are forwarded to inline parsing."
  (prisma-model-list-item
   :checkbox (prisma-md--list-item-checkbox node)
   :children (when-let* ((para (prisma-ts-child-by-type node "paragraph")))
               (prisma-md--inline-children para inline-root text))
   :start (treesit-node-start node)
   :end (treesit-node-end node)
   :source-format 'markdown))

(defun prisma-md--process-code-block (node _text)
  "Process a fenced_code_block NODE."
  (let* ((start (treesit-node-start node))
         (end (treesit-node-end node))
         (info (prisma-ts-child-by-type node "info_string"))
         (lang-node (when info
                      (prisma-ts-child-by-type info "language")))
         (language (when lang-node (treesit-node-text lang-node t)))
         (content-node (prisma-ts-child-by-type
                        node "code_fence_content"))
         (raw-body (if content-node
                       (treesit-node-text content-node t)
                     ""))
         ;; Some tree-sitter-markdown versions include the closing
         ;; fence in the content node. Strip it if present.
         (body (let ((stripped (replace-regexp-in-string
                                "\n?[`~]\\{3,\\}\\s-*\\'" "" raw-body)))
                 ;; Ensure body ends with \n if non-empty
                 (if (and (not (string-empty-p stripped))
                          (not (string-suffix-p "\n" stripped)))
                     (concat stripped "\n")
                   stripped))))
    (prisma-model-code-block
     :language language :body body
     :start start :end end :source-format 'markdown)))

(defun prisma-md--process-blockquote (node inline-root text)
  "Process a block_quote NODE.
INLINE-ROOT and TEXT are forwarded to inline parsing."
  (let* ((start (treesit-node-start node))
         (end (treesit-node-end node))
         (content-children
          (seq-filter
           (lambda (c)
             (prisma-md--content-node-p (treesit-node-type c)))
           (treesit-node-children node t)))
         (children
          (seq-remove
           #'null
           (mapcar (lambda (c)
                     (prisma-md--process-block c inline-root text))
                   content-children))))
    (prisma-model-blockquote
     :children children
     :start start :end end :source-format 'markdown)))

;;;; Inline processing

(defun prisma-md--process-inlines (inline-node inline-root text)
  "Build inline model nodes from INLINE-NODE's byte range.
Uses INLINE-ROOT to find structural inline elements, filling gaps with
text nodes drawn from TEXT."
  (let* ((start (treesit-node-start inline-node))
         (end (treesit-node-end inline-node))
         (nodes (prisma-ts-nodes-in-range inline-root start end)))
    (prisma-md--fill-text-gaps nodes start end text)))

(defun prisma-md--fill-text-gaps (nodes start end text)
  "Build inline children list, creating text nodes for gaps between NODES.
START and END bound the source byte range to fill; TEXT supplies bytes."
  (let ((result nil)
        (pos start)
        (sorted (sort (copy-sequence nodes)
                      (lambda (a b)
                        (< (treesit-node-start a)
                           (treesit-node-start b))))))
    (dolist (node sorted)
      (let ((ns (treesit-node-start node))
            (ne (treesit-node-end node)))
        (when (< pos ns)
          (push (prisma-model-text
                 :value (substring text pos ns)
                 :start pos :end ns :source-format 'markdown)
                result))
        (push (prisma-md--process-inline-node node text) result)
        (setq pos ne)))
    (when (< pos end)
      (push (prisma-model-text
             :value (substring text pos end)
             :start pos :end end :source-format 'markdown)
            result))
    (nreverse result)))

(defun prisma-md--process-inline-node (node text)
  "Convert an inline treesit NODE to a model node.
TEXT supplies bytes for nodes that extract value from their byte range."
  (let ((type (treesit-node-type node))
        (start (treesit-node-start node))
        (end (treesit-node-end node)))
    (pcase type
      ("strong_emphasis"
       (prisma-md--process-emphasis node text 'strong))
      ("emphasis"
       (prisma-md--process-emphasis node text 'emphasis))
      ("code_span"
       (let* ((range (prisma-ts-content-range node "code_span_delimiter"))
              (value (if range
                        (substring text (car range) (cdr range))
                      "")))
         (prisma-model-code
          :value value :start start :end end :source-format 'markdown)))
      ("inline_link"
       (let* ((lt (prisma-ts-child-by-type node "link_text"))
              (ld (prisma-ts-child-by-type node "link_destination"))
              (desc (when lt (treesit-node-text lt t)))
              (url (when ld (treesit-node-text ld t)))
              (children (when desc
                          (list (prisma-model-text
                                 :value desc
                                 :start (treesit-node-start lt)
                                 :end (treesit-node-end lt)
                                 :source-format 'markdown)))))
         (prisma-model-link
          :url url :children children
          :start start :end end :source-format 'markdown)))
      ("image"
       (let* ((desc (prisma-ts-child-by-type node "image_description"))
              (dest (prisma-ts-child-by-type node "link_destination"))
              (alt (when desc (treesit-node-text desc t)))
              (url (when dest (treesit-node-text dest t))))
         (prisma-model-image
          :url url :alt alt
          :start start :end end :source-format 'markdown)))
      ("strikethrough"
       (let* ((cs (+ start 2))
              (ce (- end 2))
              (inner-text (substring text cs ce))
              (children (list (prisma-model-text
                               :value inner-text
                               :start cs :end ce
                               :source-format 'markdown))))
         (prisma-model-strike
          :children children
          :start start :end end :source-format 'markdown)))
      (_
       (prisma-model-passthrough
        :text (substring text start end)
        :start start :end end :source-format 'markdown)))))

(defun prisma-md--process-emphasis (node text kind)
  "Process strong_emphasis or emphasis NODE into KIND model node.
KIND is `strong' or `emphasis'.  TEXT supplies inline source bytes."
  (let* ((start (treesit-node-start node))
         (end (treesit-node-end node))
         (range (prisma-ts-content-range node "emphasis_delimiter"))
         (cs (if range (car range) start))
         (ce (if range (cdr range) end))
         (nested (seq-remove
                  (lambda (c)
                    (string= (treesit-node-type c) "emphasis_delimiter"))
                  (treesit-node-children node)))
         (children (prisma-md--fill-text-gaps nested cs ce text)))
    (prisma-model-node kind
                       :children children
                       :start start :end end
                       :source-format 'markdown)))

;;;; Renderer - public API

(defun prisma-md-render (ast)
  "Render model AST to Markdown format string."
  (prisma-md--render-node ast))

(defun prisma-md--render-node (node)
  "Render a single model NODE to Markdown."
  (pcase (prisma-model-type node)
    ('document
     (prisma-md--render-blocks (prisma-model-children node)))
    ('heading
     (let ((level (or (prisma-model-prop node :level) 1)))
       (concat (make-string level ?#) " "
               (prisma-md--render-children node))))
    ('paragraph (prisma-md--render-children node))
    ('text (prisma-model-prop node :value))
    ('strong (concat "**" (prisma-md--render-children node) "**"))
    ('emphasis (concat "*" (prisma-md--render-children node) "*"))
    ('code (concat "`" (prisma-model-prop node :value) "`"))
    ('verbatim (concat "`" (prisma-model-prop node :value) "`"))
    ('strike (concat "~~" (prisma-md--render-children node) "~~"))
    ('link
     (let ((url (or (prisma-model-prop node :url) ""))
           (desc (prisma-md--render-children node)))
       (format "[%s](%s)" desc url)))
    ('image
     (let ((url (or (prisma-model-prop node :url) ""))
           (alt (or (prisma-model-prop node :alt) "")))
       (format "![%s](%s)" alt url)))
    ('linebreak "  \n")
    ('code-block
     (let ((lang (or (prisma-model-prop node :language) ""))
           (body (or (prisma-model-prop node :body) "")))
       (concat "```" lang "\n" body
               (if (string-suffix-p "\n" body) "" "\n")
               "```")))
    ('list (prisma-md--render-list node))
    ('list-item (prisma-md--render-list-item node))
    ('blockquote
     (let ((inner (mapconcat #'prisma-md--render-node
                             (prisma-model-children node) "\n")))
       (mapconcat (lambda (line) (concat "> " line))
                  (split-string inner "\n") "\n")))
    ('horiz-rule "---")
    ('passthrough
     (string-trim-right (or (prisma-model-prop node :text) "") "\n"))
    (_ (or (prisma-model-prop node :text)
           (prisma-md--render-children node)))))

(defun prisma-md--render-blocks (nodes)
  "Render block-level NODES with proper inter-block spacing."
  (prisma-model-render-blocks nodes #'prisma-md--render-node))

(defun prisma-md--render-children (node)
  "Render children of NODE concatenated."
  (mapconcat #'prisma-md--render-node
             (prisma-model-children node) ""))

(defun prisma-md--render-list (node)
  "Render a list NODE."
  (let ((ordered (prisma-model-prop node :ordered))
        (items (prisma-model-children node))
        (idx 0))
    (mapconcat (lambda (item)
                 (setq idx (1+ idx))
                 (let ((marker (if ordered (format "%d. " idx) "- "))
                       (checkbox (prisma-model-prop item :checkbox))
                       (content (prisma-md--render-children item)))
                   (concat marker
                           (pcase checkbox
                             ('checked "[x] ")
                             ('unchecked "[ ] ")
                             (_ ""))
                           content)))
               items "\n")))

(defun prisma-md--render-list-item (node)
  "Render a standalone list-item NODE (fallback)."
  (concat "- " (prisma-md--render-children node)))

(provide 'prisma-md)
;;; prisma-md.el ends here

