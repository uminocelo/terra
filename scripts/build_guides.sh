#!/usr/bin/env bash
#
# Build the Terra guides into a static site with Manto.
#
# Manto is a separate Elixir/Phoenix project, so this script runs its
# `manto.build` mix task from Manto's own checkout while keeping the content
# (`guides/`) and the output (`dist/`) in this repository. Point it at a
# different Manto clone with MANTO_DIR, or change the destination with
# OUTPUT_DIR:
#
#   ./scripts/build_guides.sh
#   MANTO_DIR=~/code/manto OUTPUT_DIR=/tmp/terra-docs ./scripts/build_guides.sh
#   TERRA_THEME=default ./scripts/build_guides.sh
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terra_dir="$(cd "${script_dir}/.." && pwd)"

manto_dir="${MANTO_DIR:-$(cd "${terra_dir}/.." && pwd)/manto}"
output_dir="${OUTPUT_DIR:-${terra_dir}/dist}"

if [ ! -f "${manto_dir}/mix.exs" ]; then
  echo "Manto not found at ${manto_dir}." >&2
  echo "Clone https://github.com/uminocelo/manto next to this repo, or set MANTO_DIR." >&2
  exit 1
fi

export TERRA_DIR="${terra_dir}"
export TERRA_OUTPUT="${output_dir}"
if [ -n "${TERRA_THEME:-}" ]; then
  export TERRA_THEME
fi

cd "${manto_dir}"
mix deps.get
mix run "${terra_dir}/scripts/manto_build.exs"

echo "Guides built into ${output_dir}"