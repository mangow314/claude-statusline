#!/usr/bin/env bash
# install.sh — copy the statusline (and the optional progress hook) into ~/.claude/.
#
# This script copies files only. It NEVER edits your settings.json — merging JSON
# safely from a shell script is error-prone, so the snippets you need to merge are
# printed at the end for you to paste in by hand.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

mkdir -p "$CLAUDE_DIR" "$CLAUDE_DIR/hooks"

install -m 0755 "$SRC_DIR/statusline.sh"      "$CLAUDE_DIR/statusline.sh"
echo "installed: $CLAUDE_DIR/statusline.sh"

install -m 0755 "$SRC_DIR/inject-progress.sh" "$CLAUDE_DIR/hooks/inject-progress.sh"
echo "installed: $CLAUDE_DIR/hooks/inject-progress.sh (optional — only used if you wire up the hook below)"

cat <<'EOF'

------------------------------------------------------------------------
Next step: merge the following into ~/.claude/settings.json

  Statusline (required):

    "statusLine": {
      "type": "command",
      "command": "bash \"$HOME/.claude/statusline.sh\""
    }

  Progress task bar (optional — lights up the leading task row):

    "hooks": {
      "SessionStart": [
        { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/inject-progress.sh" } ] }
      ]
    }

Requirements: bash >= 5.0, jq, a Nerd Font, and a truecolor terminal.
macOS ships bash 3.2 — run `brew install bash` and make sure it is first on PATH.
------------------------------------------------------------------------
EOF
