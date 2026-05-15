;;; el-prisma-tests.el --- Tests for el-prisma -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Unit tests for El Prisma core and intermediary model.
;;
;;; Code:

(require 'buttercup)
(require 'el-prisma)
(require 'el-prisma-model)

(describe "El Prisma"
  (it "loads successfully"
    (expect (featurep 'el-prisma) :to-be-truthy)))

(describe "el-prisma-model"

  (describe "node constructor"
    (it "creates a node with all fields"
      (let ((n (el-prisma-model-node 'heading
                 :start 0 :end 10
                 :source-format 'markdown
                 :children '(a b)
                 :props '(:level 2))))
        (expect (el-prisma-model-type n) :to-equal 'heading)
        (expect (el-prisma-model-start n) :to-equal 0)
        (expect (el-prisma-model-end n) :to-equal 10)
        (expect (el-prisma-model-source-format n) :to-equal 'markdown)
        (expect (el-prisma-model-children n) :to-equal '(a b))
        (expect (el-prisma-model-props n) :to-equal '(:level 2))))

    (it "defaults missing fields to nil"
      (let ((n (el-prisma-model-node 'paragraph)))
        (expect (el-prisma-model-type n) :to-equal 'paragraph)
        (expect (el-prisma-model-start n) :to-be nil)
        (expect (el-prisma-model-children n) :to-be nil)
        (expect (el-prisma-model-props n) :to-be nil))))

  (describe "node-p predicate"
    (it "returns t for valid nodes"
      (expect (el-prisma-model-node-p
               (el-prisma-model-node 'text :props '(:value "hi")))
              :to-be-truthy))

    (it "returns nil for non-nodes"
      (expect (el-prisma-model-node-p nil) :to-be nil)
      (expect (el-prisma-model-node-p "string") :to-be nil)
      (expect (el-prisma-model-node-p 42) :to-be nil)
      (expect (el-prisma-model-node-p '(1 2 3)) :to-be nil)))

  (describe "prop accessor"
    (it "retrieves specific prop values"
      (let ((n (el-prisma-model-heading :level 3)))
        (expect (el-prisma-model-prop n :level) :to-equal 3)))

    (it "returns nil for missing props"
      (let ((n (el-prisma-model-paragraph)))
        (expect (el-prisma-model-prop n :level) :to-be nil))))

  (describe "convenience constructors"

    (describe "document nodes"
      (it "creates heading with :level"
        (let ((h (el-prisma-model-heading :level 2 :start 0 :end 10)))
          (expect (el-prisma-model-type h) :to-equal 'heading)
          (expect (el-prisma-model-prop h :level) :to-equal 2)
          (expect (el-prisma-model-start h) :to-equal 0)))

      (it "creates code-block with :language and :body"
        (let ((cb (el-prisma-model-code-block
                   :language "elisp" :body "(+ 1 2)")))
          (expect (el-prisma-model-type cb) :to-equal 'code-block)
          (expect (el-prisma-model-prop cb :language) :to-equal "elisp")
          (expect (el-prisma-model-prop cb :body) :to-equal "(+ 1 2)")))

      (it "creates list with :ordered"
        (let ((l (el-prisma-model-list :ordered t)))
          (expect (el-prisma-model-prop l :ordered) :to-equal t)))

      (it "creates passthrough with :text"
        (let ((p (el-prisma-model-passthrough :text "SCHEDULED: <2026-05-10>")))
          (expect (el-prisma-model-prop p :text)
                  :to-equal "SCHEDULED: <2026-05-10>")))

      (it "creates horiz-rule with no props"
        (let ((hr (el-prisma-model-horiz-rule)))
          (expect (el-prisma-model-type hr) :to-equal 'horiz-rule)
          (expect (el-prisma-model-props hr) :to-be nil))))

    (describe "inline nodes"
      (it "creates text with :value"
        (let ((t1 (el-prisma-model-text :value "hello")))
          (expect (el-prisma-model-prop t1 :value) :to-equal "hello")))

      (it "creates link with :url and children"
        (let ((l (el-prisma-model-link
                  :url "http://example.com"
                  :children (list (el-prisma-model-text :value "click")))))
          (expect (el-prisma-model-prop l :url) :to-equal "http://example.com")
          (expect (el-prisma-model-type (car (el-prisma-model-children l)))
                  :to-equal 'text)))

      (it "creates image with :url and :alt"
        (let ((img (el-prisma-model-image :url "pic.png" :alt "A picture")))
          (expect (el-prisma-model-prop img :url) :to-equal "pic.png")
          (expect (el-prisma-model-prop img :alt) :to-equal "A picture")))

      (it "creates strong with children"
        (let ((s (el-prisma-model-strong
                  :children (list (el-prisma-model-text :value "bold")))))
          (expect (el-prisma-model-type s) :to-equal 'strong)
          (expect (el-prisma-model-prop
                   (car (el-prisma-model-children s)) :value)
                  :to-equal "bold")))))

  (describe "content hashing"
    (it "returns a string"
      (let ((h (el-prisma-model-content-hash
                (el-prisma-model-text :value "hello"))))
        (expect h :to-match "^[0-9a-f]\\{40\\}$")))

    (it "produces same hash for identical content"
      (let ((n1 (el-prisma-model-text :value "hello" :start 0 :end 5))
            (n2 (el-prisma-model-text :value "hello" :start 100 :end 105)))
        (expect (el-prisma-model-content-hash n1)
                :to-equal (el-prisma-model-content-hash n2))))

    (it "produces different hash for different content"
      (let ((n1 (el-prisma-model-text :value "hello"))
            (n2 (el-prisma-model-text :value "world")))
        (expect (el-prisma-model-content-hash n1)
                :not :to-equal (el-prisma-model-content-hash n2))))

    (it "produces different hash for different types"
      (let ((n1 (el-prisma-model-text :value "hello"))
            (n2 (el-prisma-model-code :value "hello")))
        (expect (el-prisma-model-content-hash n1)
                :not :to-equal (el-prisma-model-content-hash n2))))

    (it "hashes children recursively"
      (let ((p1 (el-prisma-model-paragraph
                 :children (list (el-prisma-model-text :value "a"))))
            (p2 (el-prisma-model-paragraph
                 :children (list (el-prisma-model-text :value "b")))))
        (expect (el-prisma-model-content-hash p1)
                :not :to-equal (el-prisma-model-content-hash p2))))

    (it "hashes node-valued props recursively"
      (let ((l1 (el-prisma-model-link
                 :url "http://example.com"
                 :children (list (el-prisma-model-text :value "a"))))
            (l2 (el-prisma-model-link
                 :url "http://example.com"
                 :children (list (el-prisma-model-text :value "b")))))
        (expect (el-prisma-model-content-hash l1)
                :not :to-equal (el-prisma-model-content-hash l2))))))

;;; el-prisma-tests.el ends here
