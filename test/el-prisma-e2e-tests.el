;;; el-prisma-e2e-tests.el --- End-to-end buffer lifecycle tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Full convert/edit/commit/cancel cycle tests.
;; Exercises the buffer manager with real markdown<->org conversion.
;; Safe for live Emacs: cleans up all temp buffers.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma)
(require 'el-prisma-model)

;;;; Test helpers

(defvar el-prisma-e2e--buffers nil
  "Buffers created during tests, cleaned up after each.")

(defun el-prisma-e2e--make-md-buffer (name content)
  "Create a markdown buffer NAME with CONTENT for testing."
  (let ((buf (generate-new-buffer name)))
    (push buf el-prisma-e2e--buffers)
    (with-current-buffer buf
      (insert content)
      (markdown-mode)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    buf))

(defun el-prisma-e2e--make-org-buffer (name content)
  "Create an org buffer NAME with CONTENT for testing."
  (let ((buf (generate-new-buffer name)))
    (push buf el-prisma-e2e--buffers)
    (with-current-buffer buf
      (insert content)
      (org-mode)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    buf))

(defun el-prisma-e2e--cleanup ()
  "Kill all test buffers."
  (dolist (buf el-prisma-e2e--buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (kill-buffer buf)))
  ;; Also kill any stray prisma mirror buffers
  (dolist (buf (buffer-list))
    (when (string-match-p "^\\*prisma:" (buffer-name buf))
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (kill-buffer buf)))
  (setq el-prisma-e2e--buffers nil))

;;;; Tests

(describe "E2E: buffer lifecycle"
  (after-each (el-prisma-e2e--cleanup))

  (describe "cursor position"
    (it "convert places cursor near corresponding mirror position"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nLine two.\n\nLine four.\n"))
             mirror)
        (with-current-buffer src
          (goto-char (point-min))
          (forward-line 3)
          (setq mirror (el-prisma-convert)))
        (push mirror el-prisma-e2e--buffers)
        ;; Should be near line 3-5, not at top or bottom
        (with-current-buffer mirror
          (expect (line-number-at-pos) :to-be-greater-than 1)
          (expect (line-number-at-pos) :to-be-less-than 6))))

    (it "commit restores mirror line in source"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nKeep.\n\nOld text.\n\nAfter.\n"))
             (mirror (with-current-buffer src (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          ;; Go to line 5, edit there
          (goto-char (point-min))
          (forward-line 3)
          (when (search-forward "Old" nil t)
            (replace-match "New"))
          (let ((el-prisma--skip-kill-confirm t)
                (el-prisma-validate-on-commit nil))
            (el-prisma-commit)))
        (with-current-buffer src
          ;; Should be on or near line 4 where we were editing
          (expect (line-number-at-pos) :to-be-greater-than 2))))

    (it "cancel restores mirror line in source"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nLine two.\n\nLine four.\n\nLine six.\n"))
             (mirror (with-current-buffer src (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (forward-line 4)
          (let ((el-prisma--skip-kill-confirm t))
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (el-prisma-cancel))))
        (with-current-buffer src
          (expect (line-number-at-pos) :to-equal 5)))))

  (describe "surgical precision"
    ;; The critical test: a single edit must produce exactly one
    ;; line difference in the source. No collateral damage.
    (it "single paragraph edit changes only that paragraph"
      (let* ((md (concat "# Title\n\n"
                         "First paragraph.\n\n"
                         "Second paragraph with old word.\n\n"
                         "Third paragraph.\n"))
             (src (el-prisma-e2e--make-md-buffer "test.md" md))
             (mirror (with-current-buffer src (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (search-forward "old")
          (replace-match "new")
          (let ((el-prisma--skip-kill-confirm t)
                (el-prisma-validate-on-commit nil))
            (el-prisma-commit)))
        (let* ((result (with-current-buffer src (buffer-string)))
               (orig-lines (split-string md "\n"))
               (result-lines (split-string result "\n"))
               (diff-count 0))
          (cl-loop for a in orig-lines
                   for b in result-lines
                   unless (string= a b) do (cl-incf diff-count))
          ;; Exactly one line should differ
          (expect diff-count :to-equal 1)
          ;; And it should contain our edit
          (expect result :to-match "new word")
          ;; And the other lines should be intact
          (expect result :to-match "# Title")
          (expect result :to-match "First paragraph")
          (expect result :to-match "Third paragraph"))))

    (it "single edit in complex document - no collateral damage"
      (let* ((md (concat "# Heading\n\n"
                         "Paragraph with **bold** and *italic*.\n\n"
                         "| A | B |\n|---|---|\n| 1 | 2 |\n\n"
                         "> blockquote\n\n"
                         "---\n\n"
                         "- list item\n\n"
                         "```python\ncode()\n```\n\n"
                         "Edit old word here.\n\n"
                         "[link](http://example.com)\n"))
             (src (el-prisma-e2e--make-md-buffer "test.md" md))
             (mirror (with-current-buffer src (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (search-forward "old word")
          (replace-match "new word")
          (let ((el-prisma--skip-kill-confirm t)
                (el-prisma-validate-on-commit nil))
            (el-prisma-commit)))
        (let* ((result (with-current-buffer src (buffer-string)))
               (orig-lines (split-string md "\n"))
               (result-lines (split-string result "\n"))
               (diff-count 0)
               (diff-lines nil))
          (cl-loop for a in orig-lines
                   for b in result-lines
                   for i from 1
                   unless (string= a b)
                   do (cl-incf diff-count)
                      (push i diff-lines))
          ;; At most 1 line should differ
          (expect diff-count :to-be-less-than 2)
          ;; Same line count
          (expect (length result-lines) :to-equal (length orig-lines))
          ;; All elements preserved
          (expect result :to-match "# Heading")
          (expect result :to-match "\\*\\*bold\\*\\*")
          (expect result :to-match "| A | B |")
          (expect result :to-match "> blockquote")
          (expect result :to-match "---")
          (expect result :to-match "- list item")
          (expect result :to-match "code()")
          (expect result :to-match "\\[link\\]")
          (expect result :to-match "new word")))))

  (describe "el-prisma-convert"
    (it "creates a mirror buffer from markdown source"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Hello\n\nWorld.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (expect (buffer-live-p mirror) :to-be-truthy)
        (expect (buffer-name mirror) :to-match "\\*prisma:.*:org\\*")))

    (it "mirror buffer contains converted Org content"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nSome **bold** text.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (let ((content (buffer-string)))
            (expect content :to-match "^\\* Title")
            (expect content :to-match "\\*bold\\*")))))

    (it "mirror buffer has mirror-mode enabled"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Hello\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (expect el-prisma-mirror-mode :to-be-truthy))))

    (it "stores source buffer linkage"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Hello\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (expect el-prisma--source-buffer :to-equal src)
          (expect el-prisma--source-format :to-equal 'markdown)
          (expect el-prisma--target-format :to-equal 'org)
          (expect el-prisma--source-ast :not :to-be nil)))))

  (describe "el-prisma-commit"
    (it "patches source after editing mirror"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nOriginal paragraph.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          ;; Edit: change "Original" to "Modified"
          (goto-char (point-min))
          (when (search-forward "Original" nil t)
            (replace-match "Modified"))
          (let ((el-prisma--skip-kill-confirm t))
            (el-prisma-commit)))
        (with-current-buffer src
          (expect (buffer-string) :to-match "Modified"))))

    (it "reports no changes when mirror is unmodified"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (el-prisma-commit))
        ;; Mirror should be killed
        (expect (buffer-live-p mirror) :not :to-be-truthy)))

    (it "kills mirror buffer after commit"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nText.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (when (search-forward "Text" nil t)
            (replace-match "Changed"))
          (let ((el-prisma--skip-kill-confirm t))
            (el-prisma-commit)))
        (expect (buffer-live-p mirror) :not :to-be-truthy))))

  (describe "el-prisma-cancel"
    (it "kills mirror without changing source"
      (let* ((original-text "# Title\n\nDon't change me.\n")
             (src (el-prisma-e2e--make-md-buffer "test.md" original-text))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          ;; Make an edit
          (goto-char (point-max))
          (insert "\nExtra stuff\n")
          ;; Cancel
          (let ((el-prisma--skip-kill-confirm t))
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (el-prisma-cancel))))
        (expect (buffer-live-p mirror) :not :to-be-truthy)
        (with-current-buffer src
          (expect (buffer-string) :to-equal original-text)))))

  (describe "el-prisma-diff"
    (it "shows diff preview without modifying source"
      (let* ((original-text "# Title\n\nParagraph.\n")
             (src (el-prisma-e2e--make-md-buffer "test.md" original-text))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (when (search-forward "Paragraph" nil t)
            (replace-match "Changed"))
          (el-prisma-diff))
        ;; Source unchanged
        (with-current-buffer src
          (expect (buffer-string) :to-equal original-text))
        ;; Diff buffer exists
        (expect (get-buffer "*el-prisma-diff*") :to-be-truthy)
        (when-let* ((diff-buf (get-buffer "*el-prisma-diff*")))
          (push diff-buf el-prisma-e2e--buffers)))))

  (describe "concurrent modification detection"
    (it "detects source buffer changes"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nOriginal.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        ;; Modify source behind mirror's back
        (with-current-buffer src
          (goto-char (point-max))
          (insert "sneaky change\n"))
        ;; Commit should detect this
        (with-current-buffer mirror
          ;; Stub yes-or-no-p to say no
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
            (expect (el-prisma-commit) :to-throw 'user-error))))))

  (describe "round-trip validation"
    (it "validation passes for clean round-trip"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nSimple paragraph.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (when (search-forward "Simple" nil t)
            (replace-match "Changed"))
          ;; Should commit without validation failure
          (let ((el-prisma-validate-on-commit t)
                (el-prisma--skip-kill-confirm t))
            (el-prisma-commit)))
        (with-current-buffer src
          (expect (buffer-string) :to-match "Changed"))))

    (it "can disable validation"
      (let* ((src (el-prisma-e2e--make-md-buffer
                   "test.md" "# Title\n\nText.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (with-current-buffer mirror
          (goto-char (point-min))
          (when (search-forward "Text" nil t)
            (replace-match "New"))
          (let ((el-prisma-validate-on-commit nil)
                (el-prisma--skip-kill-confirm t))
            (el-prisma-commit)))
        (with-current-buffer src
          (expect (buffer-string) :to-match "New")))))

  (describe "Org->Markdown direction"
    (it "converts org buffer to markdown mirror"
      (let* ((src (el-prisma-e2e--make-org-buffer
                   "test.org" "* Title\n\nSome /italic/ text.\n"))
             (mirror (with-current-buffer src
                       (el-prisma-convert))))
        (push mirror el-prisma-e2e--buffers)
        (expect (buffer-name mirror) :to-match "\\*prisma:.*:markdown\\*")
        (with-current-buffer mirror
          (let ((content (buffer-string)))
            (expect content :to-match "^# Title")
            (expect content :to-match "\\*italic\\*")))))))

;;;; Per-element-type edit+commit tests

(defun el-prisma-e2e--md-edit-commit (md-source search replace)
  "Convert MD-SOURCE to Org mirror, replace SEARCH with REPLACE, commit.
Returns the patched source string."
  (let (src mirror)
    (setq src (el-prisma-e2e--make-md-buffer "elem-test.md" md-source))
    (setq mirror (with-current-buffer src (el-prisma-convert)))
    (push mirror el-prisma-e2e--buffers)
    (with-current-buffer mirror
      (goto-char (point-min))
      (when (search-forward search nil t)
        (replace-match replace))
      (let ((el-prisma--skip-kill-confirm t)
            (el-prisma-validate-on-commit nil))
        (el-prisma-commit)))
    (with-current-buffer src (buffer-string))))

(defun el-prisma-e2e--org-edit-commit (org-source search replace)
  "Convert ORG-SOURCE to Markdown mirror, replace SEARCH with REPLACE, commit.
Returns the patched source string."
  (let (src mirror)
    (setq src (el-prisma-e2e--make-org-buffer "elem-test.org" org-source))
    (setq mirror (with-current-buffer src (el-prisma-convert)))
    (push mirror el-prisma-e2e--buffers)
    (with-current-buffer mirror
      (goto-char (point-min))
      (when (search-forward search nil t)
        (replace-match replace))
      (let ((el-prisma--skip-kill-confirm t)
            (el-prisma-validate-on-commit nil))
        (el-prisma-commit)))
    (with-current-buffer src (buffer-string))))

(describe "E2E: per-element edit+commit (MD->Org->MD)"
  (after-each (el-prisma-e2e--cleanup))

  (it "heading text"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "# Old Title\n\nBody.\n"
                   "Old Title" "New Title")))
      (expect result :to-match "# New Title")
      (expect result :to-match "Body")))

  (it "heading level preserved"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "## Sub Heading\n\nBody.\n"
                   "Sub Heading" "Changed")))
      (expect result :to-match "## Changed")))

  (it "paragraph text"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "# Title\n\nOld paragraph here.\n"
                   "Old paragraph" "New paragraph")))
      (expect result :to-match "New paragraph")))

  (it "bold text"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "Some **old** text.\n"
                   "*old*" "*new*")))
      (expect result :to-match "\\*\\*new\\*\\*")))

  (it "italic text"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "Some *old* text.\n"
                   "/old/" "/new/")))
      (expect result :to-match "\\*new\\*")))

  (it "inline code"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "Use `old-fn` here.\n"
                   "~old-fn~" "~new-fn~")))
      (expect result :to-match "`new-fn`")))

  (it "link URL"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "[click](http://old.com)\n"
                   "http://old.com" "http://new.com")))
      (expect result :to-match "http://new.com")))

  (it "link description"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "[old text](http://example.com)\n"
                   "old text" "new text")))
      (expect result :to-match "\\[new text\\]")))

  (it "code block body"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "```elisp\n(old-fn)\n```\n"
                   "(old-fn)" "(new-fn)")))
      (expect result :to-match "(new-fn)")
      (expect result :to-match "```elisp")))

  (it "code block language"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "```python\npass\n```\n"
                   "python" "ruby")))
      (expect result :to-match "```ruby")))

  (it "list item text"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "- old item\n- keep\n"
                   "old item" "new item")))
      (expect result :to-match "new item")
      (expect result :to-match "keep")))

  (it "ordered list item"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "1. old first\n2. second\n"
                   "old first" "new first")))
      (expect result :to-match "new first")
      (expect result :to-match "second")))

  (it "blockquote content"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "> old quote\n"
                   "old quote" "new quote")))
      (expect result :to-match "new quote")))

  (it "strikethrough"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "Some ~~old~~ text.\n"
                   "+old+" "+new+")))
      (expect result :to-match "~~new~~")))

  (it "table preserved when editing around it"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "# Title\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nOld text.\n"
                   "Old text" "New text")))
      (expect result :to-match "| A | B |")
      (expect result :to-match "| 1 | 2 |")
      (expect result :to-match "New text")))

  (it "image preserved when editing around it"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "![alt](http://img.png)\n\nOld text.\n"
                   "Old text" "New text")))
      (expect result :to-match "!\\[alt\\]")
      (expect result :to-match "New text")))

  (it "horizontal rule unchanged when editing around it"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "# Title\n\n---\n\nOld text.\n"
                   "Old text" "New text")))
      (expect result :to-match "---")
      (expect result :to-match "New text")))

  (it "multiple elements - edit one, others unchanged"
    (let ((result (el-prisma-e2e--md-edit-commit
                   "# Title\n\nKeep this.\n\n- keep item\n\n```js\nkeepCode()\n```\n\nChange **this** word.\n"
                   "*this*" "*THAT*")))
      (expect result :to-match "# Title")
      (expect result :to-match "Keep this")
      (expect result :to-match "keep item")
      (expect result :to-match "keepCode()")
      (expect result :to-match "\\*\\*THAT\\*\\*")))

  (it "all element types in one document"
    (let ((result (el-prisma-e2e--md-edit-commit
                   (concat "# Heading\n\n"
                           "Paragraph with **bold** and *italic* and `code` and ~~strike~~.\n\n"
                           "[link](http://example.com)\n\n"
                           "![alt](http://img.png)\n\n"
                           "| A | B |\n|---|---|\n| 1 | 2 |\n\n"
                           "> blockquote\n\n"
                           "---\n\n"
                           "- unordered\n\n"
                           "1. ordered\n\n"
                           "```python\ncode_body()\n```\n\n"
                           "Old final.\n")
                   "Old final" "New final")))
      ;; Everything preserved
      (expect result :to-match "# Heading")
      (expect result :to-match "\\*\\*bold\\*\\*")
      (expect result :to-match "\\*italic\\*")
      (expect result :to-match "`code`")
      (expect result :to-match "~~strike~~")
      (expect result :to-match "\\[link\\]")
      (expect result :to-match "!\\[alt\\]")
      (expect result :to-match "| A | B |")
      (expect result :to-match "> blockquote")
      (expect result :to-match "---")
      (expect result :to-match "- unordered")
      (expect result :to-match "1\\. ordered")
      (expect result :to-match "code_body()")
      (expect result :to-match "New final"))))

(describe "E2E: per-element edit+commit (Org->MD->Org)"
  (after-each (el-prisma-e2e--cleanup))

  (it "heading text"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "* Old Title\n\nBody.\n"
                   "Old Title" "New Title")))
      (expect result :to-match "\\* New Title")))

  (it "bold text"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "Some *old* text.\n"
                   "**old**" "**new**")))
      (expect result :to-match "\\*new\\*")))

  (it "italic text"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "Some /old/ text.\n"
                   "*old*" "*new*")))
      (expect result :to-match "/new/")))

  (it "inline code"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "Use ~old-fn~ here.\n"
                   "`old-fn`" "`new-fn`")))
      (expect result :to-match "~new-fn~")))

  (it "link description"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "[[http://example.com][old text]]\n"
                   "old text" "new text")))
      (expect result :to-match "new text")))

  (it "code block body"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "#+begin_src elisp\n(old-fn)\n#+end_src\n"
                   "(old-fn)" "(new-fn)")))
      (expect result :to-match "(new-fn)")))

  (it "list item text"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "- old item\n- keep\n"
                   "old item" "new item")))
      (expect result :to-match "new item")
      (expect result :to-match "keep")))

  (it "multiple elements - edit one, others unchanged"
    (let ((result (el-prisma-e2e--org-edit-commit
                   "* Title\n\nKeep this.\n\n- keep item\n\n#+begin_src js\nkeepCode()\n#+end_src\n\nChange *this* word.\n"
                   "**this**" "**THAT**")))
      (expect result :to-match "\\* Title")
      (expect result :to-match "Keep this")
      (expect result :to-match "keep item")
      (expect result :to-match "keepCode()")
      (expect result :to-match "\\*THAT\\*"))))

(provide 'el-prisma-e2e-tests)
;;; el-prisma-e2e-tests.el ends here
