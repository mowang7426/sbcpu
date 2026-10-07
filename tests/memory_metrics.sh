#!/bin/sh
set -eu
CC=${CC:-clang}
OUT="${TMPDIR:-/tmp}/sbcpu-memory-metrics.$$"
trap 'rm -f "$OUT"' EXIT
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic -I"$(dirname "$0")/.." \
  "$(dirname "$0")/memory_metrics.c" -o "$OUT"
"$OUT"
