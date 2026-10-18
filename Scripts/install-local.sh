#!/usr/bin/env bash
# Build Logic Groove MCP from this checkout and register it with the Claude desktop app
# (and Claude Code, if installed). No sudo: the binary goes to ~/.local/bin.
#
# Usage (from anywhere):
#   bash ~/Work/logic-groove-mcp/Scripts/install-local.sh
set -euo pipefail

BINARY_NAME="LogicGrooveMCP"
SERVER_KEY="logic-groove"
INSTALL_DIR="$HOME/.local/bin"
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Logic Groove MCP - local install ==="

if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: Swift not found. Install Xcode or run: xcode-select --install"
    exit 1
fi

echo "Building (release) in $PROJECT_DIR ..."
cd "$PROJECT_DIR"
swift build -c release
BUILT="$PROJECT_DIR/.build/release/$BINARY_NAME"
[[ -f "$BUILT" ]] || { echo "ERROR: build finished but $BUILT is missing"; exit 1; }

mkdir -p "$INSTALL_DIR"
install -m 0755 "$BUILT" "$INSTALL_DIR/$BINARY_NAME"
echo "Installed: $INSTALL_DIR/$BINARY_NAME"

# Register with the Claude desktop app: merge into the existing config, keep a backup.
mkdir -p "$(dirname "$CONFIG")"
[[ -f "$CONFIG" ]] || echo '{}' > "$CONFIG"
cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
/usr/bin/osascript -l JavaScript - "$CONFIG" "$SERVER_KEY" "$INSTALL_DIR/$BINARY_NAME" <<'JXA'
function run(argv) {
  const [path, key, cmd] = argv;
  ObjC.import('Foundation');
  const raw = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js || '{}';
  const cfg = JSON.parse(raw.trim() || '{}');
  cfg.mcpServers = cfg.mcpServers || {};
  cfg.mcpServers[key] = { command: cmd, args: [] };
  $(JSON.stringify(cfg, null, 2)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  return 'Registered "' + key + '" in ' + path;
}
JXA

if command -v claude >/dev/null 2>&1; then
    claude mcp add --scope user "$SERVER_KEY" -- "$INSTALL_DIR/$BINARY_NAME" >/dev/null 2>&1 \
        && echo "Registered with Claude Code." || echo "Claude Code: already registered (skipped)."
fi

echo ""
echo "Permissions check:"
"$INSTALL_DIR/$BINARY_NAME" --check-permissions 2>&1 || true
echo ""
echo "Done. Quit and reopen the Claude app so it starts the server."
echo "If Accessibility/Automation show as missing: System Settings > Privacy & Security >"
echo "Accessibility and Automation, enable Claude (and $BINARY_NAME if listed)."
