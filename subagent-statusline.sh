#!/bin/bash
# subagentStatusLine renderer.
# stdin: { columns, tasks: [{ id, name, type, status, description, label, startTime, model, contextWindowSize, tokenCount, tokenSamples, cwd }, ...] }
#   model = resolved model ID (v2.1.205+; omitted until the task's model is resolved)
# stdout: one JSON line per row to override: {"id": "<id>", "content": "<rendered body>"}
set -f

input=$(cat)
[ -z "$input" ] && exit 0

# ── Colors (real ESC bytes via $'\e[...]' so output needs no %b interpretation) ─
reset=$'\e[0m'
c_running=$'\e[1;38;2;100;220;130m'    # bright green — actively running
c_pending=$'\e[38;2;230;200;90m'       # gold — pending/queued
c_completed=$'\e[38;2;130;130;130m'    # gray — done
c_failed=$'\e[1;38;2;255;80;80m'       # red — failed
c_idle=$'\e[38;2;180;130;255m'         # purple — idle/waiting
c_label=$'\e[38;2;200;160;100m'        # warm — label/type tag
c_name=$'\e[38;2;220;220;240m'         # near-white — task name
c_token=$'\e[38;2;100;220;255m'        # cyan — token count
c_dim=$'\e[38;2;120;120;130m'          # dim — description
c_dur=$'\e[38;2;150;200;255m'          # soft sky — duration
# model family colors — one glance tells the tier
c_m_haiku=$'\e[38;2;140;220;120m'      # green — cheap tier
c_m_sonnet=$'\e[38;2;120;180;255m'     # blue — mid tier
c_m_opus=$'\e[38;2;255;170;90m'        # orange — high tier
c_m_fable=$'\e[38;2;220;140;255m'      # magenta — mythos tier

# ── Helpers ─────────────────────────────────────────────
fmt_tokens() {
    local n=${1:-0}
    [[ "$n" =~ ^[0-9]+$ ]] || { printf '0'; return; }
    if [ "$n" -ge 1000000 ]; then
        printf '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
    elif [ "$n" -ge 1000 ]; then
        printf '%d.%dk' $((n/1000)) $(((n%1000)/100))
    else
        printf '%d' "$n"
    fi
}

# Computes elapsed wall-clock duration from start_ms (subagent task startTime).
# NOW_SEC is hoisted once per script run before the render loop.
fmt_duration() {
    local start_ms=${1:-0}
    [[ "$start_ms" =~ ^[0-9]+$ ]] || return
    [ "$start_ms" -le 0 ] && return
    local elapsed=$(( NOW_SEC - start_ms / 1000 ))
    [ "$elapsed" -lt 0 ] && return
    if [ "$elapsed" -ge 3600 ]; then
        printf '%dh%dm' $((elapsed/3600)) $(((elapsed%3600)/60))
    elif [ "$elapsed" -ge 60 ]; then
        printf '%dm%ds' $((elapsed/60)) $((elapsed%60))
    else
        printf '%ds' "$elapsed"
    fi
}

NOW_SEC=$EPOCHSECONDS

# ── Render pipeline ─────────────────────────────────────
# 1. jq extracts each task, US-separated (\x1f) so empty fields don't collapse
#    like they would with tab (bash IFS-whitespace coalesces runs of \t).
# 2. bash loop builds id\tcontent\n with raw ESC color bytes (tab is fine here
#    because the trailing jq splits on tab and id/content never contain literal tabs).
# 3. trailing jq -Rcn slurps the lines and emits one JSON object per row.
# Total: 2 forks per refresh tick regardless of N tasks.
{
    echo "$input" | jq -r '
        .tasks // [] | .[] |
        [
            .id // "",
            .name // "",
            .type // "",
            .status // "",
            (.description // "" | gsub("[\u001f\\n]"; " ")),
            .label // "",
            .model // "",
            (.startTime // 0 | tostring),
            (.tokenCount // 0 | tostring)
        ] | join("\u001f")
    ' 2>/dev/null | while IFS=$'\x1f' read -r id name type status description label model start_time token_count; do
        [ -z "$id" ] && continue

        case "$status" in
            running|in_progress|active|executing) icon='●'; c_status="$c_running" ;;
            pending|queued|waiting)               icon='○'; c_status="$c_pending" ;;
            idle)                                 icon='◐'; c_status="$c_idle" ;;
            completed|done|success|finished)      icon='✓'; c_status="$c_completed" ;;
            failed|error|cancelled|stopped)       icon='✗'; c_status="$c_failed" ;;
            *)                                    icon='·'; c_status="$c_dim" ;;
        esac

        content="${c_status}${icon}${reset}"
        # model first (after the status icon) so a long task name can't push it
        # off the truncated line — one glance still audits each subagent's tier.
        if [ -n "$model" ]; then
            # claude-haiku-4-5-20251001 → haiku-4-5
            model_short=${model#claude-}
            model_short=${model_short%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}
            case "$model" in
                *haiku*)          c_model="$c_m_haiku" ;;
                *sonnet*)         c_model="$c_m_sonnet" ;;
                *opus*)           c_model="$c_m_opus" ;;
                *fable*|*mythos*) c_model="$c_m_fable" ;;
                *)                c_model="$c_dim" ;;
            esac
            content+=" ${c_model}${model_short}${reset}"
        fi
        content+=" ${c_name}${name}${reset}"
        if [ -n "$label" ] && [ "$label" != "$name" ]; then
            content+=" ${c_label}[${label}]${reset}"
        elif [ -n "$type" ]; then
            content+=" ${c_label}[${type}]${reset}"
        fi
        if [[ "$token_count" =~ ^[0-9]+$ ]] && [ "$token_count" -gt 0 ]; then
            content+=" ${c_token}$(fmt_tokens "$token_count")t${reset}"
        fi
        dur_fmt=$(fmt_duration "$start_time")
        if [ -n "$dur_fmt" ]; then
            content+=" ${c_dur}${dur_fmt}${reset}"
        fi
        if [ -n "$description" ]; then
            content+=" ${c_dim}· ${description}${reset}"
        fi

        printf '%s\t%s\n' "$id" "$content"
    done
} | jq -Rcn 'inputs | split("\t") | {id: .[0], content: .[1]}'

exit 0
