;;; el-prisma.el --- Format conversion with lossless round-trips -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: May 09, 2026
;; Version: 0.1.0
;; Keywords: tools convenience
;; Homepage: https://github.com/agzam/prisma.el
;; Package-Requires: ((emacs "29.1"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; El Prisma - same content, different spectrum.
;;
;; Convert buffer content between formats (Markdown<->Org, JSON<->EDN)
;; while preserving lossless round-trips.  Creates mirror buffers for
;; editing in a preferred format with explicit commit/cancel workflow.
;;
;;; Code:

(defgroup el-prisma nil
  "Format conversion with lossless round-trips."
  :group 'tools
  :prefix "el-prisma-")

(provide 'el-prisma)
;;; el-prisma.el ends here
