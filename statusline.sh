#!/bin/bash
# Disable globbing — defensive measure for handling arbitrary paths/JSON
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "◈ Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
reset='\033[0m'

c_model='\033[38;2;190;180;255m'           # model — soft lavender
c_dir='\033[38;2;220;190;150m'             # warm sand
c_ctx_empty='\033[38;2;55;55;65m'          # context ⛶ empty — dark
c_branch='\033[38;2;80;160;255m'           # cool blue
c_dirty='\033[1;38;2;255;50;50m'           # neon red
c_wt='\033[1;38;2;255;180;0m'              # amber
c_gray='\033[38;2;140;140;140m'            # labels / separators
c_magenta='\033[38;2;190;90;160m'          # effort — medium pink-purple (low-freq)
c_magenta_bright='\033[1;38;2;255;50;180m' # effort max — vivid magenta + bold
c_teal='\033[38;2;0;200;180m'              # agent name
c_coral='\033[38;2;230;175;130m'           # output style — warm peach (low-freq)
c_rate_5h='\033[38;2;255;140;50m'          # 5H icon — neon orange
c_rate_7d='\033[38;2;80;160;255m'          # 7D icon — cool blue
c_cost_low='\033[38;2;0;230;180m'          # cost < $0.50 — green
c_cost_mid='\033[38;2;255;210;0m'          # cost $0.50-$2 — yellow
c_cost_high='\033[1;38;2;255;80;50m'       # cost > $2 — red-orange
c_cost_weekly='\033[38;2;230;200;90m'      # weekly total — clean gold
c_session='\033[38;2;150;200;255m'         # session elapsed — soft sky blue
c_ctx_1m='\033[1;38;2;100;220;255m'        # 1M context badge — bright cyan
c_cache_good='\033[38;2;100;220;130m'      # cache hit ≥90% — soft green
c_cache_mid='\033[38;2;255;210;0m'         # cache hit 60-89% — yellow
c_cache_low='\033[38;2;255;120;120m'       # cache hit <60% — soft red

c_vim_n='\033[1;38;2;0;0;0;48;2;180;130;255m'  # vim normal — black on purple
c_vim_i='\033[1;38;2;0;0;0;48;2;0;230;200m'    # vim insert — black on cyan
c_vim_v='\033[1;38;2;0;0;0;48;2;255;200;80m'  # vim visual (char-wise) — black on gold
c_vim_vl='\033[1;38;2;0;0;0;48;2;255;140;0m'  # vim visual line — black on orange
c_thinking='\033[38;2;200;160;255m'            # thinking — soft lavender (low-freq)

sep=" ${c_gray}│${reset} "

# ── Helpers ─────────────────────────────────────────────
# Portable file mtime in epoch seconds: GNU stat, then BSD/macOS stat, then 0.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then   printf '\033[1;38;2;255;40;40m'
    elif [ "$pct" -ge 70 ]; then printf '\033[1;38;2;255;150;0m'
    elif [ "$pct" -ge 45 ]; then printf '\033[1;38;2;230;230;0m'
    else                         printf '\033[38;2;0;210;100m'
    fi
}

# Traffic Light gradient bar (green → yellow → orange → red)
build_gradient_bar() {
    local pct=$1 width=${2:-30}
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local denom=$(( width > 1 ? width - 1 : 1 ))

    local bar=""
    for ((i=0; i<filled; i++)); do
        local p=$(( i * 100 / denom ))
        local r g b
        if [ "$p" -le 45 ]; then
            local t=$(( p * 100 / 45 ))
            r=$(( 200 * t / 100 ))
            g=$(( 210 + 35 * t / 100 ))
            b=$(( 100 - 100 * t / 100 ))
        elif [ "$p" -le 70 ]; then
            local t=$(( (p - 45) * 100 / 25 ))
            r=$(( 200 + 55 * t / 100 ))
            g=$(( 245 - 95 * t / 100 ))
            b=0
        else
            local t=$(( (p - 70) * 100 / 30 ))
            r=255
            g=$(( 150 - 110 * t / 100 ))
            b=$(( 40 * t / 100 ))
        fi
        bar+="\033[38;2;${r};${g};${b}m━"
    done

    if [ "$empty" -gt 0 ]; then
        bar+="\033[38;2;50;50;60m"
        for ((i=0; i<empty; i++)); do bar+="─"; done
    fi

    printf "%b${reset}" "$bar"
}

format_epoch() {
    local epoch=$1 fmt=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] && return
    local ts
    LC_ALL=C printf -v ts "%(${fmt})T" "$epoch"
    ts="${ts,,}"                       # lowercase
    ts="${ts#"${ts%%[! ]*}"}"          # trim leading spaces
    ts="${ts//  / }"                   # collapse double spaces
    printf '%s' "$ts"
}

abbrev_style() {
    case "$1" in
        Explanatory) printf "Exp" ;;
        Concise)     printf "Con" ;;
        Verbose)     printf "Vrb" ;;
        Formal)      printf "Fml" ;;
        *)           printf "%.3s" "$1" ;;
    esac
}

format_session_duration() {
    local ms=$1
    [ -z "$ms" ] || [ "$ms" = "null" ] && return
    # Guard: pure-integer check (avoid arithmetic errors on malformed input)
    [[ "$ms" =~ ^[0-9]+$ ]] || return
    local total_sec=$((ms / 1000))
    local hours=$((total_sec / 3600))
    local mins=$(( (total_sec % 3600) / 60 ))
    if [ "$hours" -gt 0 ]; then
        printf '%dh %dm' "$hours" "$mins"
    else
        printf '%dm' "$mins"
    fi
}

render_rate_bar() {
    local label=$1 pct=$2 reset_epoch=$3 c_label=$4 icon=$5 epoch_fmt=$6
    [ -z "$pct" ] || [ "$pct" = "null" ] && return
    local reset_time color bar
    reset_time=$(format_epoch "$reset_epoch" "$epoch_fmt")
    color=$(color_for_pct "$pct")
    bar=$(build_gradient_bar "$pct" "$bar_width")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${c_label}${icon} ${label}${reset} ${bar} ${color}$(printf '%3d' "$pct")%${reset}"
    [ -n "$reset_time" ] && rate_lines+=" ${c_gray}↻ ${reset_time}${reset}"
}

# ── Extract JSON (single jq call, merged with settings) ─
settings_file="$HOME/.claude/settings.json"
[ -f "$settings_file" ] || settings_file="/dev/null"

read_json=$(echo "$input" | jq -r --slurpfile settings "$settings_file" '[
    .model.display_name // "Claude",
    (.context_window.used_percentage // 0 | round | tostring),
    .vim.mode // "",
    (if .worktree then "yes" else "" end),
    (.workspace.current_dir // .cwd // ""),
    .output_style.name // "",
    .agent.name // "",
    .session_id // "",
    (.cost.total_cost_usd // null | if . then tostring else "" end),
    (.rate_limits.five_hour.used_percentage // null | if . then round | tostring else "" end),
    (.rate_limits.seven_day.used_percentage // null | if . then round | tostring else "" end),
    (.rate_limits.five_hour.resets_at // null | if . then tostring else "" end),
    (.rate_limits.seven_day.resets_at // null | if . then tostring else "" end),
    (.cost.total_duration_ms // 0 | tostring),
    (.effort.level // $settings[0].effortLevel // "default"),
    (.context_window.context_window_size // 200000 | tostring),
    (.workspace.git_worktree // ""),
    (.thinking.enabled | if . == null then "" else tostring end),
    (.context_window.current_usage.input_tokens // 0 | tostring),
    (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
    (.context_window.current_usage.cache_read_input_tokens // 0 | tostring)
] | join("\u001f")' 2>/dev/null)

IFS=$'\x1f' read -r model_name ctx_pct vim_mode has_worktree cwd \
    output_style agent_name session_id cost_usd five_pct seven_pct \
    five_reset_epoch seven_reset_epoch session_ms effort \
    ctx_size ws_git_worktree thinking_on \
    cache_input cache_creation cache_read \
    <<< "$read_json"

model_name="${model_name%% (*}"

# Env var override pins the displayed effort regardless of stdin/settings.
# Kept for users who want a fixed badge independent of runtime state.
[ -n "$CLAUDE_CODE_EFFORT_LEVEL" ] && effort="$CLAUDE_CODE_EFFORT_LEVEL"

# ── Nerd Font Icons ─────────────────────────────────────
cost_icon=$'\uf06d'       #  fire (burn rate)
folder_icon=$'\uf07b'     #  folder
effort_icon=$'\uf013'  #  single cog (FA4) — tier via color + label
style_icon=$'\uf040'      #  pencil
agent_icon=$'\uf544'      #  robot
rate_5h_icon=$'\uf017'    #  clock
rate_7d_icon=$'\uf133'    #  calendar-alt
session_icon=$'\uf2f2'    #  stopwatch
model_icon=$'\uf2db'      #  microchip

# ── LINE 1 ──────────────────────────────────────────────
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""

git_cache_file=""
if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
    # Prefer XDG_RUNTIME_DIR (tmpfs, per-user, usually writable) over /tmp.
    # If neither is writable the cache silently disables itself below.
    cache_dir="${XDG_RUNTIME_DIR:-/tmp}"
    [ -w "$cache_dir" ] && git_cache_file="${cache_dir}/statusline-git-${session_id}"
fi

cache_valid=false
if [ -n "$git_cache_file" ] && [ -s "$git_cache_file" ]; then
    cache_age=$(( EPOCHSECONDS - $(file_mtime "$git_cache_file") ))
    # TTL=10 (not 5) so alternating refreshInterval=5 ticks hit the cache
    if [ "$cache_age" -lt 10 ]; then
        IFS=$'\x1f' read -r cached_cwd git_branch git_dirty < "$git_cache_file"
        if [ "$cached_cwd" = "$cwd" ]; then
            cache_valid=true
        else
            git_branch=""
            git_dirty=""
        fi
    fi
fi

if [ "$cache_valid" = false ]; then
    if git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null); then
        if [ -n "$(git -C "$cwd" status --porcelain --no-optional-locks 2>/dev/null)" ]; then
            git_dirty="*"
        fi
    fi
    if [ -n "$git_cache_file" ]; then
        # Atomic write: tmp + rename. Best-effort: silence write failures
        # so a transient/read-only FS never leaks shell errors into the UI.
        { printf '%s\x1f%s\x1f%s' "$cwd" "$git_branch" "$git_dirty" > "${git_cache_file}.$$" \
            && mv "${git_cache_file}.$$" "$git_cache_file"; } 2>/dev/null
    fi
fi

# Probabilistic stale-cache cleanup (~1% of invocations)
if [ -n "$git_cache_file" ] && [ "$((EPOCHSECONDS % 100))" -eq 0 ]; then
    find "$(dirname "$git_cache_file")" -maxdepth 1 -name 'statusline-git-*' -mtime +1 -delete 2>/dev/null
fi

ctx_color=$(color_for_pct "$ctx_pct")

# Context meter (5 icons, each = 20%; filled icons get trailing space for readability)
ctx_meter=""
ctx_filled=$(( (ctx_pct + 19) / 20 ))
[ "$ctx_filled" -gt 5 ] && ctx_filled=5
for ((i=0; i<ctx_filled; i++)); do
    ctx_meter+="${ctx_color}⛁ "
done
for ((i=ctx_filled; i<5; i++)); do
    ctx_meter+="${c_ctx_empty}⛶"
done
ctx_meter+="${reset}"

line1="${c_model}${model_icon} ${model_name}${reset}"
if [[ "$ctx_size" =~ ^[0-9]+$ ]] && [ "$ctx_size" -gt 200000 ]; then
    line1+=" ${c_ctx_1m}[1M]${reset}"
fi
line1+="${sep}${ctx_meter} ${ctx_color}${ctx_pct}%${reset}"
line1+="${sep}${c_dir}${folder_icon} ${dirname}${reset}"

if [ -n "$git_branch" ]; then
    line1+=" ${c_branch}(${git_branch}${c_dirty}${git_dirty}${c_branch})${reset}"
fi

if [ -n "$has_worktree" ]; then
    line1+=" ${c_wt}[WT]${reset}"
elif [ -n "$ws_git_worktree" ]; then
    line1+=" ${c_wt}[WT:${ws_git_worktree}]${reset}"
fi

if [ -n "$vim_mode" ] && [ "$vim_mode" != "null" ]; then
    vim_icon=$'\ue62b'
    case "$vim_mode" in
        NORMAL)        line1+="${sep}${c_vim_n} ${vim_icon} Normal ${reset}" ;;
        INSERT)        line1+="${sep}${c_vim_i} ${vim_icon} Insert ${reset}" ;;
        VISUAL)        line1+="${sep}${c_vim_v} ${vim_icon} Visual ${reset}" ;;
        "VISUAL LINE") line1+="${sep}${c_vim_vl} ${vim_icon} V-Line ${reset}" ;;
        *)             line1+="${sep}${c_gray}${vim_icon} ${vim_mode}${reset}" ;;
    esac
fi

if [ -n "$output_style" ] && [ "$output_style" != "null" ]; then
    style_abbr=$(abbrev_style "$output_style")
    line1+="${sep}${c_coral}${style_icon} ${style_abbr}${reset}"
fi

if [ -n "$agent_name" ] && [ "$agent_name" != "null" ]; then
    line1+="${sep}${c_teal}${agent_icon} ${agent_name}${reset}"
fi

if [ -n "$effort" ]; then
    case "$effort" in
        max)         line1+="${sep}${c_magenta_bright}${effort_icon} ${effort}${reset}" ;;
        xhigh|high)  line1+="${sep}${c_magenta}${effort_icon} ${effort}${reset}" ;;
        *)           line1+="${sep}${c_gray}${effort_icon} ${effort}${reset}" ;;
    esac
fi

# Thinking indicator — low-frequency badge tacked onto effort segment.
# Only surfaces when thinking is actively on, so it doubles as a silent-toggle safety net.
if [ "$thinking_on" = "true" ]; then
    line1+=" ${c_thinking}· thinking${reset}"
elif [ "$thinking_on" = "false" ]; then
    line1+=" ${c_wt} off${reset}"
fi

# ── Session cost + weekly ledger ────────────────────────
cost_line=""
if [ -n "$cost_usd" ] && [ "$cost_usd" != "null" ]; then
    # Pure bash float → centesimal integer (no awk fork)
    cost_int="${cost_usd%%.*}"
    cost_frac="${cost_usd#*.}"
    cost_frac="${cost_frac}00"
    cost_frac="${cost_frac:0:2}"
    cost_cents=$(( 10#${cost_int:-0} * 100 + 10#${cost_frac} ))

    if [ "$cost_cents" -ge 200 ]; then
        c_cost="$c_cost_high"
    elif [ "$cost_cents" -ge 50 ]; then
        c_cost="$c_cost_mid"
    else
        c_cost="$c_cost_low"
    fi
    printf -v cost_fmt '$%.2f' "$cost_usd"

    # Weekly cost ledger — single awk pass for prune + upsert + aggregate
    ledger="$HOME/.claude/cost-ledger"
    now=$EPOCHSECONDS
    if [ -n "$seven_reset_epoch" ] && [ "$seven_reset_epoch" != "null" ] && [ "$seven_reset_epoch" -gt 0 ] 2>/dev/null; then
        week_start=$(( seven_reset_epoch - 604800 ))
    else
        week_start=$(( now - 604800 ))
    fi
    weekly_total="$cost_usd"

    if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
        touch "$ledger"
        # Single awk pass: prune old entries, upsert session, aggregate total
        # Output "SAME:total" if cost unchanged, otherwise just "total"
        result=$(awk -F'\t' -v OFS='\t' \
            -v sid="$session_id" -v cost="$cost_usd" -v ts="$now" -v ws="$week_start" '
        BEGIN { found = 0; total = 0; same = 0 }
        {
            if ($3+0 < ws+0) next
            if ($1 == sid) {
                if ($2 == cost) same = 1
                found = 1
                print sid, cost, ts > "/dev/fd/3"
                total += cost
            } else {
                print > "/dev/fd/3"
                total += $2
            }
        }
        END {
            if (!found) { print sid, cost, ts > "/dev/fd/3"; total += cost }
            if (same) printf "SAME:"
            printf "%.2f", total
        }' "$ledger" 3>"${ledger}.tmp" 2>/dev/null)

        if [[ "$result" == SAME:* ]]; then
            weekly_total="${result#SAME:}"
            rm -f "${ledger}.tmp"
        else
            weekly_total="$result"
            mv "${ledger}.tmp" "$ledger"
        fi
    fi

    printf -v weekly_fmt '$%.2f' "$weekly_total"
    cost_line="${c_cost}${cost_icon} ${cost_fmt}${reset}"
    if [ "$weekly_fmt" != "$cost_fmt" ]; then
        cost_line+=" ${c_cost_weekly}/ ${weekly_fmt}${reset}"
    fi

    # Session elapsed time (wall-clock since this conversation started)
    session_dur=$(format_session_duration "$session_ms")
    if [ -n "$session_dur" ]; then
        cost_line+="${sep}${c_session}${session_icon} ${session_dur}${reset}"
    fi

    # Cache hit ratio from the most recent API call. Skipped before the first API
    # response (all three counters are 0) to avoid misleading "0%" early in the session.
    # Ratio = cache_read / (input + cache_creation + cache_read).
    [[ "$cache_input"    =~ ^[0-9]+$ ]] || cache_input=0
    [[ "$cache_creation" =~ ^[0-9]+$ ]] || cache_creation=0
    [[ "$cache_read"     =~ ^[0-9]+$ ]] || cache_read=0
    cache_total=$(( cache_input + cache_creation + cache_read ))
    if [ "$cache_total" -gt 0 ]; then
        cache_pct=$(( cache_read * 100 / cache_total ))
        if   [ "$cache_pct" -ge 90 ]; then c_cache="$c_cache_good"
        elif [ "$cache_pct" -ge 60 ]; then c_cache="$c_cache_mid"
        else                               c_cache="$c_cache_low"
        fi
        cost_line+="${sep}${c_cache}󰓅 ${cache_pct}%${reset}"
    fi
fi

# ── LINE 2+: Cost + Rate Limits ─────────────────────────
rate_lines=""
bar_width=30

rate_lines+="${cost_line}"
render_rate_bar "5H" "$five_pct"  "$five_reset_epoch"  "$c_rate_5h" "$rate_5h_icon" "%-l:%M%P"
render_rate_bar "7D" "$seven_pct" "$seven_reset_epoch" "$c_rate_7d" "$rate_7d_icon" "%b %-d %-l:%M%P"

# ── Output ──────────────────────────────────────────────
# Current task + phase (reads <cwd>/.progress/<session_id>/INDEX.md; hidden entirely when absent)
task_line=""
if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
    index_file="${cwd}/.progress/${session_id}/INDEX.md"
    if [ -f "$index_file" ]; then
        IFS= read -r task_first < "$index_file"
        task_name="${task_first#\#}"; task_name="${task_name#\#}"; task_name="${task_name# }"
        task_phase=$(grep -m1 -iE '^phase:' "$index_file" 2>/dev/null)
        task_phase="${task_phase#*:}"; task_phase="${task_phase# }"
        if [ -n "$task_name" ]; then
            task_line="${c_teal}📋 ${task_name}${reset}"
            [ -n "$task_phase" ] && task_line+="${sep}${c_gray}phase ${task_phase}${reset}"
        fi
    fi
fi

[ -n "$task_line" ] && printf "%b\n" "$task_line"
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n%b" "$rate_lines"

exit 0
