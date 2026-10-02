#!/bin/sh
# One command per exit path of examples/keys.exs.
#
#   scripts/restore_matrix.sh quit
#   scripts/restore_matrix.sh interrupt
#   scripts/restore_matrix.sh crash
#
# Each command runs `mix run examples/keys.exs` on a PTY, sends one key
# (q, Ctrl+C, or !), and checks restore. The crash path must print
# "boom from view/1" after the restore sequence, then the shell must print
# TERRA_SHELL_OK.
#
# Real emulator results are a separate run. See docs/RESTORE.md.

set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/restore_matrix.py "$@"
