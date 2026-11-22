#!/usr/bin/env bash
# Build Logic Groove MCP from this checkout and register it with the Claude desktop app
# (and Claude Code, if installed). No sudo: the binary goes to ~/.local/bin.
#
# Usage (from anywhere):
#   bash ~/Work/logic-groove-mcp/Scripts/install-local.sh [--restart-claude]
# Or double-click Install.command in the project folder (builds, installs, restarts Claude).
#   --restart-claude  quit and reopen the Claude desktop app at the end so it starts the new server
set -euo pipefail

RESTART_CLAUDE=0
for arg in ${1+"$@"}; do
    if [[ "$arg" == "--restart-claude" ]]; then RESTART_CLAUDE=1; fi
done
SIGNED=0

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

# macOS ties the Accessibility permission to the code signature. An ad-hoc signed binary
# gets a new identity on every build, so the permission is lost after each update.
# Signing with a real certificate (e.g. "Apple Development" from Xcode) keeps it.
IDENTITY="${LOGIC_GROOVE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1 || true)
fi
if [[ -z "$IDENTITY" ]]; then
    # A local self-signed certificate is listed without -v (it is not marked valid).
    IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Logic Groove Signing\)".*/\1/p' | head -1 || true)
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --identifier ro.goldenlobster.logic-groove-mcp \
        "$INSTALL_DIR/$BINARY_NAME" && SIGNED=1 \
        && echo "Signed with: $IDENTITY (Accessibility permission survives updates)"
else
    echo "NOTE: no code-signing certificate found; after each update re-add $BINARY_NAME in"
    echo "      System Settings > Privacy & Security > Accessibility (remove it, then add it again)."
    echo "      To stop that: Keychain Access > Certificate Assistant > Create a Certificate..., Name"
    echo "      \"Logic Groove Signing\", Identity Type \"Self-Signed Root\", Certificate Type \"Code Signing\";"
    echo "      then run this installer again and re-add the binary under Accessibility one last time."
fi

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
if [[ "$RESTART_CLAUDE" == "1" ]]; then
    if [[ "$SIGNED" != "1" ]]; then
        # Unsigned build: the Accessibility entry has to be re-added by hand before the restart.
        echo "ACTION NEEDED: in the Accessibility list that opens now, remove $BINARY_NAME, then add"
        echo "  $INSTALL_DIR/$BINARY_NAME  (press Cmd+Shift+G in the file dialog and paste that path)."
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
        read -r -p "Press Return here when that is done... " _ || true
    fi
    echo "Restarting the Claude app..."
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -x Claude >/dev/null 2>&1 || break
        sleep 0.5
    done
    open -a Claude 2>/dev/null || echo "Could not reopen Claude automatically; open it yourself."
    echo "Done."
else
    echo "Done. Quit and reopen the Claude app so it starts the server."
    echo "If Accessibility/Automation show as missing: System Settings > Privacy & Security >"
    echo "Accessibility and Automation, enable Claude (and $BINARY_NAME if listed)."
fi
