#!/usr/bin/env bash
# Wrapper that runs the Python test (more robust than the bash version).
exec python3 "$(dirname "$0")/test.py" "$@"