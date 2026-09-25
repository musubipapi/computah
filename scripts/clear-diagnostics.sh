#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
# Only the app's documented default diagnostic storage. Custom reports are user-managed.
for folder in runs inputs; do
  target="$project_dir/outputs/computah/$folder"
  if [[ -d "$target" ]]; then rm -rf -- "$target"; fi
done
print 'Cleared default saved run and input diagnostics. Custom reports and research archives were retained.'
