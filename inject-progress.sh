#!/usr/bin/env bash
# inject-progress.sh — per-session progress injection (hook: SessionStart, runs every time)
#
# Each session gets its own namespace: <cwd>/.progress/<session_id>/INDEX.md
#   - compact : re-inject the INDEX content into context (so you re-read your own work
#               state right after a compaction)
#   - resume  : INDEX exists -> re-inject content; missing -> emit the path hint
#   - startup : emit the path hint (new session, INDEX does not exist yet)
#   - clear   : path hint only, do NOT re-inject the old INDEX (clear usually means "start over")
#
# Subagents (input.agent_type non-empty) are skipped: SessionStart also fires inside
# subagents, and not filtering would spawn junk directories and pollute context.
#
# Output stays small (<2KB) so it fits inside the SessionStart injection window.
# The path is handed to the model fully resolved — copy it verbatim, never reconstruct
# the session_id yourself.

set -uo pipefail

INPUT=$(cat 2>/dev/null || echo '{}')

# --- subagent filter (highest priority) ---
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
[ -n "$AGENT_TYPE" ] && exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
[ -z "$CWD" ] && CWD="$PWD"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
SOURCE=$(echo "$INPUT" | jq -r '.source // ""' 2>/dev/null || echo "")

# Without a session_id we cannot isolate the namespace; exit quietly.
{ [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; } && exit 0

PROGRESS_DIR="$CWD/.progress/$SESSION_ID"
INDEX="$PROGRESS_DIR/INDEX.md"

emit_index() {
  echo "---"
  echo "## Re-read after compaction: $INDEX (your work state for THIS session — treat it as the source of truth)"
  head -c 4096 "$INDEX"
  echo ""
  # On the compact branch, restate the "keep maintaining it" instruction. The opening
  # "please maintain this" line is often dropped during compaction, after which the model
  # treats the re-injected content as a read-only snapshot and stops updating INDEX
  # (= the root cause of progress going stale after a compaction).
  echo "(You maintain this file: after a compaction, KEEP updating it — on every finished phase / major decision / blocker, rewrite the current-state, next-step and blocker lines; keep it under 2KB; do not treat it as a read-only snapshot.)"
}

emit_path_hint() {
  echo "---"
  echo "## Progress file for this session"
  echo "Path (copy it verbatim, do not reconstruct the session_id): $INDEX"
  echo "If this is a medium-or-larger task that will cross a compaction, maintain this file: first line \`# <one-line task>\`, second line \`phase: <N or short label>\`, followed by current-state / next-step / fatal-blocker+error / key metrics / hard constraints, kept under 2KB. After a compaction this file is auto re-injected — it is your cross-compaction memory anchor. Put longer detail in decisions.md / phase-N.md / blockers.md and point to them from INDEX."
}

case "$SOURCE" in
  compact)
    [ -f "$INDEX" ] && emit_index
    ;;
  resume)
    if [ -f "$INDEX" ]; then emit_index; else emit_path_hint; fi
    ;;
  clear)
    emit_path_hint
    # /clear is the preferred exit path (checkpoint→/clear→reload), but a stale INDEX may
    # live under a different session_id dir (session_id can change after /clear), so scan
    # every session dir for the freshest one (within 6h). Hint the path only — never
    # re-inject content (/clear usually means "start over").
    # Use find's %T@ directly rather than a second stat: this avoids a TOCTOU where the
    # file vanishes between find and stat and an arithmetic error breaks this hook's
    # "always exit 0" contract; a future mtime (clock skew) is clamped to 0.
    FRESH_LINE=$(find "$CWD/.progress" -mindepth 2 -maxdepth 2 -name 'INDEX.md' -mmin -360 \
                   -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n 1)
    if [ -n "$FRESH_LINE" ]; then
      FRESH_TS=${FRESH_LINE%%$'\t'*}; FRESH_TS=${FRESH_TS%%.*}
      FRESH=${FRESH_LINE#*$'\t'}
      AGE_MIN=$(( ( $(date +%s) - FRESH_TS ) / 60 ))
      [ "$AGE_MIN" -lt 0 ] && AGE_MIN=0
      echo "(Recent INDEX detected: $FRESH, updated ~${AGE_MIN} min ago — may belong to a previous or parallel session. If this /clear is a checkpoint→/clear→reload flow, Read that file to resume; if you meant to start over, ignore it.)"
    fi
    ;;
  startup|*)
    emit_path_hint
    ;;
esac

exit 0
