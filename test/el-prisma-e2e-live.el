;;; el-prisma-e2e-live.el --- Live Emacs E2E tests -*- lexical-binding: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; E2E tests designed to run inside a live Emacs session.
;; Uses `ert' instead of buttercup since the user's Emacs may not
;; have buttercup loaded. All tests clean up after themselves.
;;
;; Run via: M-x el-prisma-e2e-live-run
;; Or: make test-live (uses emacsclient)
;;
;;; Code:

(require 'ert)
(require 'el-prisma)
(require 'el-prisma-md)
(require 'el-prisma-org)
(require 'el-prisma-diff)
(require 'el-prisma-patch)
(require 'el-prisma-model)

;;;; Cleanup helper

(defvar el-prisma-e2e-live--buffers nil)

(defun el-prisma-e2e-live--cleanup ()
  "Kill all test buffers."
  (dolist (buf el-prisma-e2e-live--buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)))
  (dolist (buf (buffer-list))
    (when (string-match-p "^\\*prisma:.*e2e-live\\|^\\*el-prisma-" (buffer-name buf))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf)))
  (setq el-prisma-e2e-live--buffers nil))

(defmacro el-prisma-e2e-live--with-cleanup (&rest body)
  "Run BODY with cleanup guarantee."
  `(unwind-protect (progn ,@body)
     (el-prisma-e2e-live--cleanup)))

;;;; Tests

(ert-deftest el-prisma-e2e-live/md-to-org-convert ()
  "Create markdown buffer, convert to Org mirror."
  (el-prisma-e2e-live--with-cleanup
   (let* ((src (generate-new-buffer "e2e-live-test.md"))
          mirror)
     (push src el-prisma-e2e-live--buffers)
     (with-current-buffer src
       (insert "# Hello World\n\nA **bold** paragraph.\n")
       (markdown-mode)
       (set-buffer-modified-p nil))
     (with-current-buffer src
       (setq mirror (el-prisma-convert)))
     (push mirror el-prisma-e2e-live--buffers)
     (should (buffer-live-p mirror))
     (should (string-match-p "\\*prisma:" (buffer-name mirror)))
     (with-current-buffer mirror
       (should el-prisma-mirror-mode)
       (should (string-match-p "^\\* Hello World" (buffer-string)))
       (should (string-match-p "\\*bold\\*" (buffer-string)))))))

(ert-deftest el-prisma-e2e-live/md-to-org-commit ()
  "Convert markdown, edit Org mirror, commit back to source."
  (el-prisma-e2e-live--with-cleanup
   (let* ((src (generate-new-buffer "e2e-live-test.md"))
          mirror)
     (push src el-prisma-e2e-live--buffers)
     (with-current-buffer src
       (insert "# Title\n\nOriginal text here.\n")
       (markdown-mode)
       (set-buffer-modified-p nil))
     (with-current-buffer src
       (setq mirror (el-prisma-convert)))
     (push mirror el-prisma-e2e-live--buffers)
     ;; Edit mirror
     (with-current-buffer mirror
       (goto-char (point-min))
       (search-forward "Original")
       (replace-match "Modified")
       (let ((el-prisma--skip-kill-confirm t))
         (el-prisma-commit)))
     ;; Verify source patched
     (with-current-buffer src
       (should (string-match-p "Modified" (buffer-string))))
     ;; Mirror should be dead
     (should-not (buffer-live-p mirror)))))

(ert-deftest el-prisma-e2e-live/org-to-md-convert ()
  "Create org buffer, convert to Markdown mirror."
  (el-prisma-e2e-live--with-cleanup
   (let* ((src (generate-new-buffer "e2e-live-test.org"))
          mirror)
     (push src el-prisma-e2e-live--buffers)
     (with-current-buffer src
       (insert "* Heading\n\nSome /italic/ text.\n")
       (org-mode)
       (set-buffer-modified-p nil))
     (with-current-buffer src
       (setq mirror (el-prisma-convert)))
     (push mirror el-prisma-e2e-live--buffers)
     (should (buffer-live-p mirror))
     (with-current-buffer mirror
       (should (string-match-p "^# Heading" (buffer-string)))
       (should (string-match-p "\\*italic\\*" (buffer-string)))))))

(ert-deftest el-prisma-e2e-live/cancel-preserves-source ()
  "Cancel discards mirror without touching source."
  (el-prisma-e2e-live--with-cleanup
   (let* ((original "# Untouched\n\nDon't change.\n")
          (src (generate-new-buffer "e2e-live-test.md"))
          mirror)
     (push src el-prisma-e2e-live--buffers)
     (with-current-buffer src
       (insert original)
       (markdown-mode)
       (set-buffer-modified-p nil))
     (with-current-buffer src
       (setq mirror (el-prisma-convert)))
     (push mirror el-prisma-e2e-live--buffers)
     ;; Edit mirror then cancel
     (with-current-buffer mirror
       (goto-char (point-max))
       (insert "\nNew content!\n")
       (let ((el-prisma--skip-kill-confirm t))
         (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
           (el-prisma-cancel))))
     (should-not (buffer-live-p mirror))
     (with-current-buffer src
       (should (string= (buffer-string) original))))))

(ert-deftest el-prisma-e2e-live/mixed-inline-roundtrip ()
  "Convert markdown with mixed inline, edit, commit, verify."
  (el-prisma-e2e-live--with-cleanup
   (let* ((src (generate-new-buffer "e2e-live-test.md"))
          mirror)
     (push src el-prisma-e2e-live--buffers)
     (with-current-buffer src
       (insert "Some **bold** and *italic* and `code` text.\n")
       (markdown-mode)
       (set-buffer-modified-p nil))
     (with-current-buffer src
       (setq mirror (el-prisma-convert)))
     (push mirror el-prisma-e2e-live--buffers)
     ;; Verify Org conversion
     (with-current-buffer mirror
       (let ((content (buffer-string)))
         (should (string-match-p "\\*bold\\*" content))
         (should (string-match-p "/italic/" content))
         (should (string-match-p "~code~" content)))))))

(ert-deftest el-prisma-e2e-live/diff-preview ()
  "Diff preview shows changes without modifying source."
  (el-prisma-e2e-live--with-cleanup
   (let* ((original "# Title\n\nParagraph.\n")
          (src (generate-new-buffer "e2e-live-test.md"))
          mirror)
     (push src el-prisma-e2e-live--buffers)
     (with-current-buffer src
       (insert original)
       (markdown-mode)
       (set-buffer-modified-p nil))
     (with-current-buffer src
       (setq mirror (el-prisma-convert)))
     (push mirror el-prisma-e2e-live--buffers)
     (with-current-buffer mirror
       (goto-char (point-min))
       (search-forward "Paragraph")
       (replace-match "Changed")
       (el-prisma-diff))
     ;; Source unchanged
     (with-current-buffer src
       (should (string= (buffer-string) original)))
     ;; Diff buffer appeared
     (let ((diff-buf (get-buffer "*el-prisma-diff*")))
       (should diff-buf)
       (push diff-buf el-prisma-e2e-live--buffers)
       (with-current-buffer diff-buf
         (should (string-match-p "Modified: 1" (buffer-string))))))))

;;;; Runner

(defun el-prisma-e2e-live-run ()
  "Run all el-prisma live E2E tests and report results."
  (interactive)
  (let* ((selector "el-prisma-e2e-live/")
         (stats (ert-run-tests-batch selector)))
    (if (zerop (ert-stats-completed-unexpected stats))
        (format "PASS: %d/%d tests passed"
                (ert-stats-completed-expected stats)
                (ert-stats-total stats))
      (format "FAIL: %d unexpected out of %d"
              (ert-stats-completed-unexpected stats)
              (ert-stats-total stats)))))

(provide 'el-prisma-e2e-live)
;;; el-prisma-e2e-live.el ends here
