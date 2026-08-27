;;; prisma-yank.el --- Cross-format kill and yank -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Homepage: https://github.com/agzam/prisma.el
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Kills remember the markup format of the buffer they came from.  When
;; the paste target uses the other format, the text goes through Prisma
;; on the way in: Markdown pasted into Org arrives as Org, Org pasted
;; into Markdown arrives as Markdown.
;;
;; Turn it on with `prisma-yank-mode'.  It hooks the kill ring itself,
;; so it covers `yank', `yank-pop' and Evil's paste commands alike.
;;
;;; Code:

(require 'prisma)

;;;; Internal variables

(defvar prisma-yank-inhibit nil
  "When non-nil, pastes insert the kill unchanged.
Bind it around a paste to opt out of conversion for that paste.")

(defconst prisma-yank--convertible-handlers '(nil evil-yank-line-handler)
  "The `yank-handler' functions conversion is known to survive.
Rectangle handlers carry their lines beside the text, where no
whole-blob conversion can reach them.")

(defvar prisma-yank--reading-kill nil
  "Non-nil while `current-kill' runs.
Text `current-kill' pulls in from another program has no buffer of
origin, so the format of the buffer being pasted into says nothing
about it.")

;;;; Kill side

(defun prisma-yank--tag-kill (&rest _)
  "Record the current buffer's markup format on the freshest kill.
`:after' advice for `kill-new', the funnel every kill passes through."
  (when-let* (((not prisma-yank--reading-kill))
              (format (prisma--detect-source-format))
              (text (car kill-ring)))
    (put-text-property 0 (length text) 'prisma-format format text)))

(defun prisma-yank--reading-kill-a (fn &rest args)
  "Call FN with ARGS over a marked dynamic extent.
`:around' advice for `current-kill', which kills the text it reads
from the system clipboard."
  (let ((prisma-yank--reading-kill t))
    (apply fn args)))

;;;; Paste side

(defun prisma-yank--format-of (text)
  "Return the markup format TEXT was killed from, or nil.
Falls back to the kill ring entry with the same characters, whose
property survives both the clipboard round-trip and Evil, which
strips properties off charwise pastes."
  (or (get-text-property 0 'prisma-format text)
      (seq-some (lambda (kill)
                  (and (equal text kill)
                       (get-text-property 0 'prisma-format kill)))
                kill-ring)))

(defun prisma-yank--convert (text source target)
  "Convert TEXT from SOURCE format to TARGET format.
Restores the line-wise `yank-handler' and the trailing newline the
renderers drop, so a line-wise kill still pastes as whole lines."
  (let ((handler (get-text-property 0 'yank-handler text))
        (converted (prisma-render
                    target
                    (prisma-parse source (substring-no-properties text)))))
    (when handler
      (unless (string-suffix-p "\n" converted)
        (setq converted (concat converted "\n")))
      (put-text-property 0 (length converted) 'yank-handler handler converted))
    converted))

(defun prisma-yank--transform (text)
  "Convert TEXT to the markup format of the buffer receiving it.
Returns TEXT untouched when the formats match, when either end is not
a markup buffer, or when the conversion fails.  Runs from
`yank-transform-functions'."
  (let* ((source (and (stringp text)
                      (not prisma-yank-inhibit)
                      (not (equal current-prefix-arg '(4)))
                      (memq (car-safe (get-text-property 0 'yank-handler text))
                            prisma-yank--convertible-handlers)
                      (prisma-yank--format-of text)))
         (target (and source (prisma--detect-source-format))))
    (if (and target (not (eq source target)))
        (condition-case err
            (prisma-yank--convert text source target)
          (error
           (message "prisma: pasting as-is, conversion failed (%s)"
                    (error-message-string err))
           text))
      text)))

;;;; Evil

(defun prisma-yank--evil-paste-a (fn count &optional register yank-handler)
  "Paste once and unconverted on a bare \\[universal-argument].
Without this, COUNT would carry the prefix into FN and paste four
copies.  REGISTER and YANK-HANDLER pass through untouched.
`:around' advice for `evil-paste-after' and `evil-paste-before'."
  (if (equal count '(4))
      (let ((prisma-yank-inhibit t))
        (funcall fn nil register yank-handler))
    (funcall fn count register yank-handler)))

(defun prisma-yank--install-evil ()
  "Advise Evil's paste commands, once Evil is loaded to be advised."
  (when (featurep 'evil)
    (advice-add 'evil-paste-after :around #'prisma-yank--evil-paste-a)
    (advice-add 'evil-paste-before :around #'prisma-yank--evil-paste-a)))

;;;; Entry point

;;;###autoload
(define-minor-mode prisma-yank-mode
  "Convert kills between Markdown and Org as they are pasted.

A kill remembers the markup format of the buffer it came from.
Pasting it into a buffer of the other format converts it first, so
copying between Markdown and Org needs no thought.  Everything else
pastes as it always did.

A bare \\[universal-argument] before the paste command inserts the
kill unchanged; so does binding `prisma-yank-inhibit' around a paste."
  :global t
  :group 'prisma
  (if prisma-yank-mode
      (progn
        (advice-add 'kill-new :after #'prisma-yank--tag-kill)
        (advice-add 'current-kill :around #'prisma-yank--reading-kill-a)
        (add-hook 'yank-transform-functions #'prisma-yank--transform)
        (prisma-yank--install-evil))
    (advice-remove 'kill-new #'prisma-yank--tag-kill)
    (advice-remove 'current-kill #'prisma-yank--reading-kill-a)
    (remove-hook 'yank-transform-functions #'prisma-yank--transform)
    (advice-remove 'evil-paste-after #'prisma-yank--evil-paste-a)
    (advice-remove 'evil-paste-before #'prisma-yank--evil-paste-a)))

(with-eval-after-load 'evil
  (when prisma-yank-mode
    (prisma-yank--install-evil)))

(provide 'prisma-yank)
;;; prisma-yank.el ends here
