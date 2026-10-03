#!/bin/bash
# Installs the opencode side of opencode-status: symlinks the event plugin
# into ~/.config/opencode/plugins/ and seeds the state file the widget reads.
# The Omarchy widget itself is installed via `omarchy plugin add <git-url>`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$REPO_DIR/opencode-plugin/opencode-omarchy-status.js"
PLUGIN_DIR="${HOME}/.config/opencode/plugins"
STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
STATE_DIR="$STATE_HOME/omarchy"
STATE_FILE="$STATE_DIR/opencode-status.json"

mkdir -p "$PLUGIN_DIR" "$STATE_DIR"

ln -sfn "$PLUGIN_SRC" "$PLUGIN_DIR/opencode-omarchy-status.js"
echo "linked: $PLUGIN_DIR/opencode-omarchy-status.js -> $PLUGIN_SRC"

if [[ ! -f "$STATE_FILE" ]]; then
  printf '{"version":1,"updatedAt":0,"sessions":[]}' > "$STATE_FILE"
  echo "seeded: $STATE_FILE"
else
  echo "kept:   $STATE_FILE (already exists)"
fi

# Bar placement: ask where the icon should live. Honors BAR_SECTION when set
# (non-interactive installs: BAR_SECTION=center ./install.sh).
SECTION="${BAR_SECTION:-}"
if [[ -z "$SECTION" && -t 0 ]]; then
  read -r -p "Where in the topbar should the opencode icon live? [left/center/right] (default: center): " SECTION || true
fi
SECTION="${SECTION:-center}"
if [[ "$SECTION" != "left" && "$SECTION" != "center" && "$SECTION" != "right" ]]; then
  echo "ignoring invalid section '$SECTION' (want: left, center, or right)"
else
  if command -v omarchy >/dev/null 2>&1; then
    omarchy bar move folken.opencode-status --section "$SECTION" && echo "placed: opencode icon in the $SECTION section"
  else
    echo "skip:   omarchy CLI not found; run this later:"
    echo "  omarchy bar move folken.opencode-status --section $SECTION"
  fi
fi

echo ""
echo "Done. Remaining steps:"
echo "  1. Restart opencode so it loads the plugin (plugins load at startup)."
echo "  2. If the widget isn't enabled yet:"
echo "     omarchy plugin enable folken.opencode-status --section center"
echo "     (on a fresh machine: omarchy plugin add <git-url> --enable, then move it)"
