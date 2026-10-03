#!/bin/bash
# Dev-only: sync this repo into the live shell plugin dir and rescan.
#
# Why a copy and not a symlink: the shell's file watcher does not reliably
# fire through symlinked plugin dirs, and rescanPlugins skips reloading
# unchanged entry URLs — edits silently never land. A real directory copy
# plus rescan is the supported path (same layout `omarchy plugin add`
# produces). If the bar still shows stale content after this, run
# `omarchy restart shell` (clears all in-memory component caches).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/folken.opencode-status"

mkdir -p "$DEST"
cp -r "$REPO_DIR/manifest.json" "$REPO_DIR/Widget.qml" "$REPO_DIR/README.md" \
  "$REPO_DIR/LICENSE" "$REPO_DIR/install.sh" "$REPO_DIR/bin" \
  "$REPO_DIR/opencode-plugin" "$DEST/"
echo "synced: $REPO_DIR -> $DEST"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins
  echo "rescanned."
  echo "NOTE: rescan skips reloading unchanged entry URLs and the file watcher"
  echo "is unreliable - if the bar does not reflect the change, run:"
  echo "  omarchy restart shell"
else
  echo "note: omarchy-shell not found; rescan manually."
fi
