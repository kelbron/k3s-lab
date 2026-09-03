# Isolated targets specifically for unit testing production macros
TARGET_PATH ?= *.yaml

.PHONY: test-safe-envsubst-single-file test-safe-envsubst-multiple-files

test-safe-envsubst-single-file:
	@echo 'domain: $${DOMAIN}' | $(call safe_envsubst,$(lastword $(MAKEFILE_LIST)))

test-safe-envsubst-with-target:
	@echo 'stream_domain: $${DOMAIN}' | $(call safe_envsubst,$(TARGET_PATH))

