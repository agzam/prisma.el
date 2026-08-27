ELPA_DIR = $(CURDIR)/.elpa

EMACS_BATCH = emacs -Q --batch \
	--eval "(setq load-prefer-newer t)" \
	--eval "(setq package-user-dir \"$(ELPA_DIR)\")" \
	--eval "(require 'package)" \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	--eval "(package-initialize)"

.PHONY: help test test-e2e deps check-autoloads check-compile compile clean

help:
	@echo "Available commands:"
	@echo "  make deps              Install dependencies"
	@echo "  make test              Run unit tests"
	@echo "  make test-e2e          Run end-to-end tests"
	@echo "  make compile           Byte-compile the package"
	@echo "  make check-autoloads   Generate and load autoloads"
	@echo "  make check-compile     Check for clean byte-compilation"
	@echo "  make clean             Remove compiled files"

$(ELPA_DIR):
	@echo "Installing dependencies..."
	$(EMACS_BATCH) \
	--eval "(package-refresh-contents)" \
	--eval "(package-install 'buttercup)" \
	--eval "(package-install 'markdown-mode)"

deps: $(ELPA_DIR)

test: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/prisma-tests.el \
	-l test/prisma-diff-tests.el \
	-l test/prisma-org-tests.el \
	-l test/prisma-text-diff-tests.el \
	-l test/prisma-yank-tests.el \
	--funcall buttercup-run

test-e2e: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(dolist (d '(\"$(HOME)/.emacs.d/.local/cache/tree-sitter\" \"$(HOME)/.emacs.d/tree-sitter\")) (when (file-directory-p d) (push d treesit-extra-load-path)))" \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/prisma-tests.el \
	-l test/prisma-diff-tests.el \
	-l test/prisma-org-tests.el \
	-l test/prisma-md-tests.el \
	-l test/prisma-text-diff-tests.el \
	-l test/prisma-fixture-tests.el \
	-l test/prisma-isolation-tests.el \
	-l test/prisma-yank-tests.el \
	--funcall buttercup-run

test-live:
	@echo "Live tests removed. Use 'make test-e2e' for fixture tests."

check-autoloads:
	@echo "Generating and loading autoloads..."
	rm -f prisma-autoloads.el
	emacs -Q --batch \
	--eval "(setq generated-autoload-file (expand-file-name \"prisma-autoloads.el\" \"$(CURDIR)\"))" \
	--eval "(update-directory-autoloads \"$(CURDIR)\")" \
	--eval "(load generated-autoload-file nil 'nomessage)"

SRCS = prisma.el prisma-model.el prisma-diff.el prisma-ts.el prisma-md.el prisma-org.el prisma-yank.el

check-compile: $(ELPA_DIR) check-autoloads
	@echo "Checking byte-compilation..."
	$(EMACS_BATCH) \
	--eval "(setq byte-compile-error-on-warn t)" \
	--eval "(add-to-list 'load-path \".\")" \
	$(foreach f,$(SRCS),--eval "(byte-compile-file \"$(f)\")")

compile: $(ELPA_DIR)
	@echo "Byte-compiling package files..."
	$(EMACS_BATCH) \
	--eval "(add-to-list 'load-path \".\")" \
	$(foreach f,$(SRCS),--eval "(byte-compile-file \"$(f)\")")

clean:
	@echo "Cleaning compiled files..."
	rm -f *.elc test/*.elc
	rm -rf $(ELPA_DIR)
