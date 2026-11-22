#!/bin/bash
# Double-click in Finder: builds and installs Logic Groove MCP from this folder,
# then restarts the Claude desktop app so it starts the new server.
cd "$(dirname "$0")" || exit 1
bash Scripts/install-local.sh --restart-claude
status=$?
echo ""
if [[ $status -ne 0 ]]; then
    echo "The install FAILED (exit code $status). Scroll up for the error."
fi
read -r -n 1 -s -p "Press any key to close this window."
echo ""
