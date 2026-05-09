;;; el-prisma-tests.el --- Tests for el-prisma -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for El Prisma - format conversion with lossless round-trips.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma)

(describe "El Prisma"
  (it "loads successfully"
    (expect (featurep 'el-prisma) :to-be-truthy)))

;;; el-prisma-tests.el ends here
