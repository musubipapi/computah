#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
case "${1:-}" in
  ""|--record-diagnostics) ;;
  *) print -u2 'Usage: zsh scripts/run.sh [--record-diagnostics]'; exit 2 ;;
esac
if pgrep -x Computah >/dev/null; then
  print -u2 'Computah is already running. Quit it before rebuilding/relaunching so startup options take effect.'
  exit 1
fi
zsh "$project_dir/scripts/build.sh"
args=(--root "$project_dir")
if [[ "${1:-}" == --record-diagnostics ]]; then args+=(--record-diagnostics); fi
open "$project_dir/outputs/Computah.app" --args "${args[@]}"
