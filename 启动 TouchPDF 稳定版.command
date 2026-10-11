#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_app="$task_root/dist/TouchPDF.app"
if [[ ! -x "$task_app/Contents/MacOS/TouchPDF" ]]; then
  print -u2 "找不到稳定版应用：$task_app"
  exit 1
fi
# A fresh process is intentional: open -a may reuse an old, still-running binary.
# The app resolves other instances with ordinary quit requests and save dialogs.
exec /usr/bin/open -n "$task_app"
