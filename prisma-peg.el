;;; prisma-peg.el --- PEG parser engine -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;; Generic PEG (Parsing Expression Grammar) engine with packrat
;; memoization for O(n) parsing. Used for Org inline content where
;; tree-sitter grammars are insufficient.
;;
;;; Code:

(require 'cl-lib)

;;;; Grammar compilation

(defun prisma-peg-compile (grammar-alist)
  "Compile GRAMMAR-ALIST into a hash-table for O(1) rule lookup.
Each entry in GRAMMAR-ALIST is (RULE-NAME EXPRESSION)."
  (let ((table (make-hash-table :test 'eq :size (length grammar-alist))))
    (dolist (entry grammar-alist)
      (puthash (car entry) (cadr entry) table))
    table))

;;;; Public API

(defun prisma-peg-parse (grammar start-rule text &optional start-pos)
  "Parse TEXT using GRAMMAR from START-RULE at START-POS.
GRAMMAR is an alist or pre-compiled hash-table.
Returns plist (:start :end :value :rule) on success, nil on failure."
  (let* ((compiled (if (hash-table-p grammar)
                       grammar
                     (prisma-peg-compile grammar)))
         (memo (make-hash-table :test 'equal))
         (pos (or start-pos 0))
         (result (prisma-peg--parse-expr
                  start-rule text pos memo compiled)))
    (when result
      (list :start pos
            :end (car result)
            :value (cdr result)
            :rule start-rule))))

;;;; Result accessors

(defun prisma-peg-result-start (result)
  "Return start position from parse RESULT."
  (plist-get result :start))

(defun prisma-peg-result-end (result)
  "Return end position from parse RESULT."
  (plist-get result :end))

(defun prisma-peg-result-value (result)
  "Return parsed value from RESULT."
  (plist-get result :value))

(defun prisma-peg-result-rule (result)
  "Return the start rule name from RESULT."
  (plist-get result :rule))

;;;; Internal parser
;; Result convention: (NEW-POS . VALUE) on success, nil on failure.

(defun prisma-peg--parse-expr (expr text pos memo grammar)
  "Parse EXPR at POS in TEXT.  Return (NEW-POS . VALUE) or nil.
MEMO is the packrat table, GRAMMAR the compiled rule table."
  (cond
   ((stringp expr)
    (prisma-peg--parse-literal expr text pos))
   ((symbolp expr)
    (if (eq expr 'any)
        (when (< pos (length text))
          (cons (1+ pos) (substring text pos (1+ pos))))
      (prisma-peg--parse-rule expr text pos memo grammar)))
   ((consp expr)
    (pcase (car expr)
      ('seq   (prisma-peg--parse-seq   (cdr expr) text pos memo grammar))
      ('/     (prisma-peg--parse-choice (cdr expr) text pos memo grammar))
      ('+     (prisma-peg--parse-plus  (cadr expr) text pos memo grammar))
      ('*     (prisma-peg--parse-star  (cadr expr) text pos memo grammar))
      ('?     (prisma-peg--parse-opt   (cadr expr) text pos memo grammar))
      ('!     (prisma-peg--parse-not   (cadr expr) text pos memo grammar))
      ('&     (prisma-peg--parse-and   (cadr expr) text pos memo grammar))
      ('class (prisma-peg--parse-class (cadr expr) text pos))))))

(defun prisma-peg--parse-literal (lit text pos)
  "Match literal string LIT at POS in TEXT."
  (let ((end (+ pos (length lit))))
    (when (and (<= end (length text))
               (string= lit (substring text pos end)))
      (cons end lit))))

(defun prisma-peg--parse-rule (rule text pos memo grammar)
  "Parse named RULE at POS with packrat memoization."
  (let* ((memo-key (cons rule pos))
         (cached (gethash memo-key memo 'prisma--miss)))
    (if (not (eq cached 'prisma--miss))
        cached
      ;; Seed nil to prevent left-recursion infinite loops
      (puthash memo-key nil memo)
      (when-let* ((rule-expr (gethash rule grammar)))
        (let ((result (prisma-peg--parse-expr
                       rule-expr text pos memo grammar)))
          (puthash memo-key result memo)
          result)))))

(defun prisma-peg--parse-seq (exprs text pos memo grammar)
  "Parse sequence of EXPRS at POS.  All must match or entire seq fails."
  (let ((values nil)
        (cur-pos pos)
        (failed nil))
    (dolist (expr exprs)
      (unless failed
        (if-let* ((result (prisma-peg--parse-expr
                           expr text cur-pos memo grammar)))
            (progn
              (push (cdr result) values)
              (setq cur-pos (car result)))
          (setq failed t))))
    (unless failed
      (cons cur-pos (nreverse values)))))

(defun prisma-peg--parse-choice (exprs text pos memo grammar)
  "Try each of EXPRS in order, return first success."
  (cl-loop for expr in exprs
           for result = (prisma-peg--parse-expr
                         expr text pos memo grammar)
           when result return result))

(defun prisma-peg--parse-plus (expr text pos memo grammar)
  "Match EXPR one or more times at POS."
  (when-let* ((first (prisma-peg--parse-expr
                      expr text pos memo grammar)))
    (let ((values (list (cdr first)))
          (cur-pos (car first)))
      (cl-loop for result = (prisma-peg--parse-expr
                             expr text cur-pos memo grammar)
               while (and result (> (car result) cur-pos))
               do (push (cdr result) values)
                  (setq cur-pos (car result)))
      (cons cur-pos (nreverse values)))))

(defun prisma-peg--parse-star (expr text pos memo grammar)
  "Match EXPR zero or more times at POS.  Always succeeds."
  (let ((values nil)
        (cur-pos pos))
    (cl-loop for result = (prisma-peg--parse-expr
                           expr text cur-pos memo grammar)
             while (and result (> (car result) cur-pos))
             do (push (cdr result) values)
                (setq cur-pos (car result)))
    (cons cur-pos (nreverse values))))

(defun prisma-peg--parse-opt (expr text pos memo grammar)
  "Match EXPR optionally at POS.  Always succeeds."
  (or (prisma-peg--parse-expr expr text pos memo grammar)
      (cons pos nil)))

(defun prisma-peg--parse-not (expr text pos memo grammar)
  "Negative lookahead: succeed without consuming if EXPR fails at POS."
  (if (prisma-peg--parse-expr expr text pos memo grammar)
      nil
    (cons pos t)))

(defun prisma-peg--parse-and (expr text pos memo grammar)
  "Positive lookahead: succeed without consuming if EXPR matches at POS."
  (when (prisma-peg--parse-expr expr text pos memo grammar)
    (cons pos t)))

(defun prisma-peg--parse-class (class-str text pos)
  "Match one character at POS against character class CLASS-STR.
CLASS-STR uses range notation like \"a-zA-Z0-9\"."
  (when (< pos (length text))
    (let ((ch (aref text pos)))
      (when (prisma-peg--class-match-p ch class-str)
        (cons (1+ pos) (char-to-string ch))))))

(defun prisma-peg--class-match-p (ch class-str)
  "Return non-nil if character CH matches CLASS-STR."
  (let ((i 0)
        (len (length class-str)))
    (catch 'match
      (while (< i len)
        (let ((c (aref class-str i)))
          (if (and (< (+ i 2) len)
                   (= (aref class-str (1+ i)) ?-))
              (let ((end-c (aref class-str (+ i 2))))
                (when (and (<= c ch) (<= ch end-c))
                  (throw 'match t))
                (setq i (+ i 3)))
            (when (= c ch)
              (throw 'match t))
            (setq i (1+ i)))))
      nil)))

(provide 'prisma-peg)
;;; prisma-peg.el ends here
