#!/bin/sh
# /data/local-ai/asgard/rust-test.sh MODEL - kept for the docs; the E2E runner is now e2e-test.sh MODEL TASK
# (rust|go|c|asm) and e2e-all.sh MODEL runs all four.
exec "$(dirname "$(realpath "$0")")/e2e-test.sh" "${1:-north}" rust
