;;; prisma-yank-tests.el --- Cross-format kill and yank tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for `prisma-yank-mode'.  Conversion itself is stubbed: these
;;  specs are about which text gets converted, and about the kill-ring
;;  wiring that decides it.  No tree-sitter grammar needed.
;;
;;; Code:

(require 'buttercup)
(require 'prisma)
(require 'prisma-yank)

(defmacro prisma-yank-test-with-buffer (format &rest body)
  "Run BODY in a temp buffer posing as a FORMAT buffer.
FORMAT is `org', `markdown' or nil for a buffer of neither format."
  (declare (indent 1))
  `(with-temp-buffer
     (pcase ,format
       ('org (setq major-mode 'org-mode))
       ('markdown (setq major-mode 'markdown-mode)))
     ,@body))

(defun prisma-yank-test-stub-conversion ()
  "Stand in for the parser and renderer: render tags the text."
  (spy-on 'prisma-parse :and-call-fake (lambda (_format text) (list :ast text)))
  (spy-on 'prisma-render
          :and-call-fake (lambda (format ast)
                           (format "%s:%s" format (cadr ast)))))

(describe "prisma-yank--tag-kill"
  (it "records the format of the buffer the kill came from"
    (prisma-yank-test-with-buffer 'org
      (let ((kill-ring (list (copy-sequence "* heading"))))
        (prisma-yank--tag-kill)
        (expect (get-text-property 0 'prisma-format (car kill-ring))
                :to-be 'org))))

  (it "leaves kills from other buffers alone"
    (prisma-yank-test-with-buffer nil
      (let ((kill-ring (list (copy-sequence "plain"))))
        (prisma-yank--tag-kill)
        (expect (get-text-property 0 'prisma-format (car kill-ring))
                :to-be nil))))

  (it "leaves text read from another program alone"
    (prisma-yank-test-with-buffer 'org
      (let ((kill-ring (list (copy-sequence "* heading")))
            (prisma-yank--reading-kill t))
        (prisma-yank--tag-kill)
        (expect (get-text-property 0 'prisma-format (car kill-ring))
                :to-be nil)))))

(describe "prisma-yank--format-of"
  (it "reads the property off the text"
    (expect (prisma-yank--format-of
             (propertize "# hi" 'prisma-format 'markdown))
            :to-be 'markdown))

  (it "recovers the format from the kill ring when the property is gone"
    (let ((kill-ring (list (propertize "# hi" 'prisma-format 'markdown))))
      (expect (prisma-yank--format-of "# hi") :to-be 'markdown)))

  (it "skips an untagged duplicate to reach the tagged kill"
    ;; the clipboard round-trip pushes an untagged copy in front
    (let ((kill-ring (list "# hi"
                           (propertize "# hi" 'prisma-format 'markdown))))
      (expect (prisma-yank--format-of "# hi") :to-be 'markdown)))

  (it "returns nil for text of unknown origin"
    (let ((kill-ring (list "something else")))
      (expect (prisma-yank--format-of "# hi") :to-be nil))))

(describe "prisma-yank--transform"
  (before-each (prisma-yank-test-stub-conversion))

  (it "converts a Markdown kill pasted into Org"
    (prisma-yank-test-with-buffer 'org
      (expect (prisma-yank--transform
               (propertize "# hi" 'prisma-format 'markdown))
              :to-equal "org:# hi")))

  (it "leaves the kill alone when both ends share a format"
    (prisma-yank-test-with-buffer 'markdown
      (expect (prisma-yank--transform
               (propertize "# hi" 'prisma-format 'markdown))
              :to-equal "# hi")))

  (it "leaves the kill alone in a buffer of neither format"
    (prisma-yank-test-with-buffer nil
      (expect (prisma-yank--transform
               (propertize "# hi" 'prisma-format 'markdown))
              :to-equal "# hi")))

  (it "leaves the kill alone on a bare C-u"
    (prisma-yank-test-with-buffer 'org
      (let ((current-prefix-arg '(4)))
        (expect (prisma-yank--transform
                 (propertize "# hi" 'prisma-format 'markdown))
                :to-equal "# hi"))))

  (it "leaves the kill alone while inhibited"
    (prisma-yank-test-with-buffer 'org
      (let ((prisma-yank-inhibit t))
        (expect (prisma-yank--transform
                 (propertize "# hi" 'prisma-format 'markdown))
                :to-equal "# hi"))))

  (it "leaves a rectangle kill alone: its lines travel in the handler"
    (prisma-yank-test-with-buffer 'org
      (let ((text (propertize "# hi"
                              'prisma-format 'markdown
                              'yank-handler '(evil-yank-block-handler ("# hi")))))
        (expect (prisma-yank--transform text) :to-equal "# hi"))))

  (it "keeps a line-wise kill line-wise: trailing newline and handler"
    ;; renderers trim the trailing newline a line-wise kill needs
    (spy-on 'prisma-render
            :and-call-fake (lambda (format ast)
                             (format "%s:%s" format (string-trim (cadr ast)))))
    (prisma-yank-test-with-buffer 'org
      (let* ((handler '(evil-yank-line-handler nil t))
             (text (propertize "# hi\n"
                               'prisma-format 'markdown
                               'yank-handler handler))
             (converted (prisma-yank--transform text)))
        (expect converted :to-equal "org:# hi\n")
        (expect (get-text-property 0 'yank-handler converted)
                :to-equal handler))))

  (it "pastes as-is when the conversion fails"
    (spy-on 'prisma-parse :and-call-fake (lambda (&rest _) (error "Boom")))
    (spy-on 'message)
    (prisma-yank-test-with-buffer 'org
      (expect (prisma-yank--transform
               (propertize "# hi" 'prisma-format 'markdown))
              :to-equal "# hi"))))

(describe "prisma-yank--evil-paste-a"
  (it "pastes once and unconverted on a bare C-u"
    (let (seen)
      (prisma-yank--evil-paste-a
       (lambda (count &optional _register _handler)
         (setq seen (list count prisma-yank-inhibit)))
       '(4) nil nil)
      (expect seen :to-equal '(nil t))))

  (it "passes any other count through"
    (let (seen)
      (prisma-yank--evil-paste-a
       (lambda (count &optional register _handler)
         (setq seen (list count register prisma-yank-inhibit)))
       3 ?a nil)
      (expect seen :to-equal '(3 ?a nil)))))

(describe "prisma-yank-mode"
  (after-each (prisma-yank-mode -1))

  (it "hooks the kill ring on, and off again"
    (prisma-yank-mode 1)
    (expect (memq #'prisma-yank--transform yank-transform-functions)
            :to-be-truthy)
    (expect (advice-member-p #'prisma-yank--tag-kill 'kill-new)
            :to-be-truthy)
    (expect (advice-member-p #'prisma-yank--reading-kill-a 'current-kill)
            :to-be-truthy)
    (prisma-yank-mode -1)
    (expect (memq #'prisma-yank--transform yank-transform-functions)
            :to-be nil)
    (expect (advice-member-p #'prisma-yank--tag-kill 'kill-new)
            :to-be nil)
    (expect (advice-member-p #'prisma-yank--reading-kill-a 'current-kill)
            :to-be nil))

  (it "converts a real kill on a real yank"
    (prisma-yank-test-stub-conversion)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil)
          (interprogram-paste-function nil))
      (prisma-yank-mode 1)
      (prisma-yank-test-with-buffer 'org (kill-new (copy-sequence "* heading")))
      (prisma-yank-test-with-buffer 'markdown
        (insert-for-yank (current-kill 0))
        (expect (buffer-string) :to-equal "markdown:* heading"))))

  (it "keeps text from another program out of the conversion"
    (prisma-yank-test-stub-conversion)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil)
          (interprogram-paste-function (lambda () "* not really org")))
      (prisma-yank-mode 1)
      ;; reading the clipboard in an Org buffer must not brand it Org
      (prisma-yank-test-with-buffer 'org (current-kill 0))
      (prisma-yank-test-with-buffer 'markdown
        (setq interprogram-paste-function nil)
        (insert-for-yank (current-kill 0))
        (expect (buffer-string) :to-equal "* not really org")))))

(provide 'prisma-yank-tests)
;;; prisma-yank-tests.el ends here
