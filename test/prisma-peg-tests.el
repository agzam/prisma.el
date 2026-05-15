;;; prisma-peg-tests.el --- PEG engine tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for the PEG parser engine.
;;
;;; Code:

(require 'buttercup)
(require 'prisma-peg)

(describe "prisma-peg"

  (describe "grammar compilation"
    (it "compiles alist to hash-table"
      (let ((g (prisma-peg-compile '((a "x") (b "y")))))
        (expect (hash-table-p g) :to-be-truthy)
        (expect (gethash 'a g) :to-equal "x")
        (expect (gethash 'b g) :to-equal "y"))))

  (describe "literal matching"
    (it "matches exact string"
      (let ((r (prisma-peg-parse '((s "hello")) 's "hello")))
        (expect r :not :to-be nil)
        (expect (prisma-peg-result-value r) :to-equal "hello")
        (expect (prisma-peg-result-start r) :to-equal 0)
        (expect (prisma-peg-result-end r) :to-equal 5)))

    (it "matches at offset"
      (let ((r (prisma-peg-parse '((s "world")) 's "hello world" 6)))
        (expect r :not :to-be nil)
        (expect (prisma-peg-result-value r) :to-equal "world")))

    (it "fails on mismatch"
      (expect (prisma-peg-parse '((s "hello")) 's "world")
              :to-be nil))

    (it "fails when text is too short"
      (expect (prisma-peg-parse '((s "hello")) 's "hel")
              :to-be nil)))

  (describe "any"
    (it "matches any single character"
      (let ((r (prisma-peg-parse '((s any)) 's "x")))
        (expect (prisma-peg-result-value r) :to-equal "x")
        (expect (prisma-peg-result-end r) :to-equal 1)))

    (it "fails at end of input"
      (expect (prisma-peg-parse '((s any)) 's "") :to-be nil)))

  (describe "seq"
    (it "matches all expressions in order"
      (let ((r (prisma-peg-parse '((s (seq "a" "b" "c"))) 's "abc")))
        (expect (prisma-peg-result-value r) :to-equal '("a" "b" "c"))
        (expect (prisma-peg-result-end r) :to-equal 3)))

    (it "fails if any part fails"
      (expect (prisma-peg-parse '((s (seq "a" "b" "c"))) 's "abx")
              :to-be nil))

    (it "does not consume on partial failure"
      ;; The parse result is nil, position stays at start
      (expect (prisma-peg-parse '((s (seq "a" "x"))) 's "ab")
              :to-be nil)))

  (describe "ordered choice (/)"
    (it "returns first matching alternative"
      (let ((r (prisma-peg-parse '((s (/ "a" "b"))) 's "a")))
        (expect (prisma-peg-result-value r) :to-equal "a")))

    (it "tries next alternative on failure"
      (let ((r (prisma-peg-parse '((s (/ "a" "b"))) 's "b")))
        (expect (prisma-peg-result-value r) :to-equal "b")))

    (it "fails if no alternative matches"
      (expect (prisma-peg-parse '((s (/ "a" "b"))) 's "c")
              :to-be nil)))

  (describe "one-or-more (+)"
    (it "matches one occurrence"
      (let ((r (prisma-peg-parse '((s (+ "a"))) 's "a")))
        (expect (prisma-peg-result-value r) :to-equal '("a"))))

    (it "matches multiple occurrences"
      (let ((r (prisma-peg-parse '((s (+ "a"))) 's "aaab")))
        (expect (prisma-peg-result-value r) :to-equal '("a" "a" "a"))
        (expect (prisma-peg-result-end r) :to-equal 3)))

    (it "fails on zero occurrences"
      (expect (prisma-peg-parse '((s (+ "a"))) 's "b") :to-be nil)))

  (describe "zero-or-more (*)"
    (it "matches zero occurrences"
      (let ((r (prisma-peg-parse '((s (* "a"))) 's "b")))
        (expect (prisma-peg-result-value r) :to-equal nil)
        (expect (prisma-peg-result-end r) :to-equal 0)))

    (it "matches multiple occurrences"
      (let ((r (prisma-peg-parse '((s (* "a"))) 's "aaa")))
        (expect (prisma-peg-result-value r) :to-equal '("a" "a" "a")))))

  (describe "optional (?)"
    (it "matches when present"
      (let ((r (prisma-peg-parse '((s (seq (? "a") "b"))) 's "ab")))
        (expect (prisma-peg-result-value r) :to-equal '("a" "b"))))

    (it "succeeds when absent"
      (let ((r (prisma-peg-parse '((s (seq (? "a") "b"))) 's "b")))
        (expect (prisma-peg-result-value r) :to-equal '(nil "b")))))

  (describe "negative lookahead (!)"
    (it "succeeds when expression fails"
      (let ((r (prisma-peg-parse '((s (seq (! "x") "a"))) 's "a")))
        (expect r :not :to-be nil)
        (expect (prisma-peg-result-end r) :to-equal 1)))

    (it "fails when expression succeeds"
      (expect (prisma-peg-parse '((s (seq (! "a") any))) 's "a")
              :to-be nil))

    (it "does not consume input"
      (let ((r (prisma-peg-parse '((s (seq (! "x") any))) 's "ab")))
        ;; ! doesn't consume, then any consumes 1
        (expect (prisma-peg-result-end r) :to-equal 1))))

  (describe "positive lookahead (&)"
    (it "succeeds without consuming"
      (let ((r (prisma-peg-parse '((s (seq (& "a") any))) 's "a")))
        (expect r :not :to-be nil)
        (expect (prisma-peg-result-end r) :to-equal 1)))

    (it "fails when expression doesn't match"
      (expect (prisma-peg-parse '((s (seq (& "a") any))) 's "b")
              :to-be nil)))

  (describe "character class"
    (it "matches single character in range"
      (let ((r (prisma-peg-parse '((s (class "a-z"))) 's "m")))
        (expect (prisma-peg-result-value r) :to-equal "m")))

    (it "fails on character outside range"
      (expect (prisma-peg-parse '((s (class "a-z"))) 's "M")
              :to-be nil))

    (it "handles multiple ranges"
      (let ((r (prisma-peg-parse '((s (class "a-zA-Z"))) 's "Z")))
        (expect (prisma-peg-result-value r) :to-equal "Z")))

    (it "handles individual characters in class"
      (let ((r (prisma-peg-parse '((s (class "_"))) 's "_")))
        (expect (prisma-peg-result-value r) :to-equal "_")))

    (it "handles mixed ranges and characters"
      (let ((r (prisma-peg-parse '((s (+ (class "a-z_")))) 's "hello_world")))
        (expect (prisma-peg-result-end r) :to-equal 11))))

  (describe "rule references"
    (it "follows named rules"
      (let ((r (prisma-peg-parse
                '((start word)
                  (word (+ (class "a-z"))))
                'start "hello")))
        (expect (prisma-peg-result-value r) :to-equal '("h" "e" "l" "l" "o"))))

    (it "handles nested rule references"
      (let ((r (prisma-peg-parse
                '((pair (seq key "=" val))
                  (key (+ (class "a-z")))
                  (val (+ (class "0-9"))))
                'pair "age=42")))
        (expect (prisma-peg-result-value r)
                :to-equal '(("a" "g" "e") "=" ("4" "2"))))))

  (describe "position tracking"
    (it "tracks start and end positions"
      (let ((r (prisma-peg-parse '((s "abc")) 's "xxxabc" 3)))
        (expect (prisma-peg-result-start r) :to-equal 3)
        (expect (prisma-peg-result-end r) :to-equal 6))))

  (describe "packrat memoization"
    (it "produces consistent results for same input"
      (let* ((grammar (prisma-peg-compile
                       '((s (/ (seq a "x") a))
                         (a "a"))))
             (r1 (prisma-peg-parse grammar 's "ax"))
             (r2 (prisma-peg-parse grammar 's "ax")))
        (expect (prisma-peg-result-value r1)
                :to-equal (prisma-peg-result-value r2)))))

  (describe "complex grammars"
    (it "parses simple arithmetic"
      ;; number ('+' number)*
      (let ((r (prisma-peg-parse
                '((expr (seq num (* (seq "+" num))))
                  (num (+ (class "0-9"))))
                'expr "1+23+456")))
        (expect r :not :to-be nil)
        (expect (prisma-peg-result-end r) :to-equal 8)))

    (it "parses with negative lookahead for boundaries"
      ;; word = (!(space) any)+
      (let ((r (prisma-peg-parse
                '((word (+ (seq (! " ") any))))
                'word "hello world")))
        (expect (prisma-peg-result-end r) :to-equal 5)))))

;;; prisma-peg-tests.el ends here
