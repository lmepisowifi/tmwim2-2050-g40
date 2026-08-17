#!/bin/sh
# ---------------------------------------------------------------------------
# lmepisowifi — https://github.com/lmepisowifi/tmwim2-2050-g40
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The lmepisowifi Project — see AUTHORS
#
# Licensed under the GNU AGPLv3 (see LICENSE). Modifying or rewriting this
# file — including by running it through an LLM — does not remove these
# obligations: keep this notice, mark your changes, and offer Corresponding
# Source to network users (AGPLv3 §5, §13). See PROVENANCE.md before
# presenting this as your own original work.
# ---------------------------------------------------------------------------

# ============================================================
# notify.sh — send a hotspot event message to Telegram or Discord
#
#   notify.sh "message text"                 send if alerts are enabled
#   notify.sh "message text" force           send even if disabled (test)
#   notify.sh "message text" "" event_key    send only if that event is
#                                            not individually muted
#   notify.sh "msg" "" event_key dedup_key   as above, but also suppress
#                                            rapid repeats of the SAME
#                                            event+dedup_key (anti-spam)
#   notify.sh --drain                        flush queued messages
#
# event_key (optional 3rd arg) lets the admin silence one event type
# without disabling everything. Each event maps to a NOTIFY_EVT_<KEY>
# flag in notify.env; when that flag is explicitly "0" the message is
# dropped. Unset/empty flags default to enabled, so older configs keep
# every event firing. "force" (test button) bypasses this check.
#
# Config is read from /lmepisowifi/hotspot_data/notify.env
# Queue dir:  /lmepisowifi/hotspot_data/queued_messages/
#
# When internet is unreachable, messages are queued and retried
# automatically when the watchdog calls --drain (every 60s).
# ============================================================

BB="busybox"
bb() { if [ -n "$BB" ]; then "$BB" "$@"; else "$@"; fi; }

# GNU wget (TLS-capable). Do NOT fall back to busybox wget.
WGET="/bin/wget"

NOTIFY_ENV="/lmepisowifi/hotspot_data/notify.env"
QUEUE_DIR="/lmepisowifi/hotspot_data/queued_messages"
TIMEOUT=8
MSG="$1"
FORCE="$2"
EVENT="$3"   # optional event key (e.g. session_paused) for per-event muting
DEDUP="$4"   # optional dedup key (e.g. the device MAC) for anti-spam cooldown

[ -n "$MSG" ] || exit 0
[ -f "$NOTIFY_ENV" ] || exit 0

# ── URL-encode for Telegram ───────────────────────────────────────────────────
urlenc() {
    bb awk -v m="$1" 'BEGIN{
        for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i
        out = ""; n = length(m)
        for (i = 1; i <= n; i++) {
            c = substr(m, i, 1)
            if (c ~ /[A-Za-z0-9._~-]/) out = out c
            else out = out sprintf("%%%02X", ord[c])
        }
        printf "%s", out
    }'
}

# ── JSON-escape for Discord ───────────────────────────────────────────────────
jsonenc() {
    bb awk -v m="$1" 'BEGIN{
        out = ""; n = length(m)
        for (i = 1; i <= n; i++) {
            c = substr(m, i, 1)
            if (c == "\\")      out = out "\\\\"
            else if (c == "\"") out = out "\\\""
            else if (c == "\n") out = out "\\n"
            else if (c == "\r") out = out "\\r"
            else if (c == "\t") out = out "\\t"
            else                out = out c
        }
        printf "%s", out
    }'
}

# ── Send functions ────────────────────────────────────────────────────────────
send_telegram() {
    [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || return 1
    URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    ENC=$(urlenc "$MSG")
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --post-data="chat_id=${TG_CHAT_ID}&text=${ENC}" \
        "$URL" 2>/dev/null
}

send_discord() {
    [ -n "$DISCORD_WEBHOOK" ] || return 1
    # Prepend a separator line — when the same bot sends back-to-back messages
    # Discord groups them visually into one block, making them look merged.
    # A top divider makes each message clearly distinct even when grouped.
    local DSCMSG
    DSCMSG=$(printf '%s' "$MSG")
    ESC=$(jsonenc "$DSCMSG")
    PAYLOAD="{\"content\":\"${ESC}\"}"
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --header="Content-Type: application/json" \
        --post-data="$PAYLOAD" \
        "$DISCORD_WEBHOOK" 2>/dev/null
}

# ── Connectivity check (fast ping — avoids full TLS handshake overhead) ───────
_internet_up() {
    bb ping -c 1 -W 4 8.8.8.8 >/dev/null 2>&1 || \
    bb ping -c 1 -W 4 1.1.1.1 >/dev/null 2>&1
}

# ── Queue a message for later delivery ───────────────────────────────────────
_enqueue() {
    mkdir -p "$QUEUE_DIR" 2>/dev/null
    local ts
    ts=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null || bb date +%s)
    printf '%s' "$MSG" > "${QUEUE_DIR}/${ts}_$$"
}

# ── Source notify config ──────────────────────────────────────────────────────
NOTIFY_ENABLED=0
NOTIFY_PROVIDER="telegram"
TG_BOT_TOKEN=""; TG_CHAT_ID=""; DISCORD_WEBHOOK=""
. "$NOTIFY_ENV" 2>/dev/null

# ── DRAIN MODE — flush queued messages when internet is back ──────────────────
if [ "$MSG" = "--drain" ]; then
    [ "${NOTIFY_ENABLED:-0}" = "1" ] || exit 0
    [ -d "$QUEUE_DIR" ] || exit 0
    _internet_up || exit 0
    for qf in "${QUEUE_DIR}"/*; do
        [ -f "$qf" ] || continue
        MSG=$(cat "$qf" 2>/dev/null)
        [ -n "$MSG" ] || { rm -f "$qf"; continue; }
        case "${NOTIFY_PROVIDER:-telegram}" in
            discord) send_discord && rm -f "$qf" ;;
            *)       send_telegram && rm -f "$qf" ;;
        esac
    done
    exit 0
fi

# ── REGULAR SEND ──────────────────────────────────────────────────────────────
if [ "$FORCE" != "force" ]; then
    [ "${NOTIFY_ENABLED:-0}" = "1" ] || exit 0

    # Per-event mute: if an event key was supplied and its NOTIFY_EVT_<KEY>
    # flag is explicitly "0", stay silent. Unset/empty defaults to enabled.
    # The key is sanitized to [A-Z_] so the eval below can never expand to
    # anything other than a NOTIFY_EVT_* variable name.
    if [ -n "$EVENT" ]; then
        _EVT_KEY=$(printf '%s' "$EVENT" | bb tr 'a-z' 'A-Z' | bb tr -cd 'A-Z0-9_')
        if [ -n "$_EVT_KEY" ]; then
            eval "_EVT_FLAG=\"\${NOTIFY_EVT_${_EVT_KEY}:-1}\""
            [ "$_EVT_FLAG" = "0" ] && exit 0
        fi
    fi
fi

# ── Rapid-repeat suppression (anti-spam) ─────────────────────────────
# When a dedup key is supplied (e.g. the device MAC), collapse bursts of
# the SAME event+key inside a short cooldown window. This kills the flood
# from a client hammering the Pause/Resume buttons: the first pause and
# first resume still notify, but repeats within the window are dropped.
# Window is NOTIFY_DEDUP_WINDOW seconds (default 30); set it to 0 to
# disable. Uses /proc/uptime (monotonic) so a clock jump can't wedge it.
if [ "$FORCE" != "force" ] && [ -n "$DEDUP" ]; then
    _WIN="${NOTIFY_DEDUP_WINDOW:-30}"
    case "$_WIN" in ''|*[!0-9]*) _WIN=30 ;; esac
    if [ "$_WIN" -gt 0 ]; then
        # Map anything outside [A-Za-z0-9_] to _ so the key is a safe
        # filename (colons in the MAC included) — no path traversal.
        _DKEY=$(printf '%s' "${EVENT}_${DEDUP}" | bb tr -c 'A-Za-z0-9_' '_')
        _DDIR="/tmp/notify_dedup"; mkdir -p "$_DDIR" 2>/dev/null
        _DFILE="${_DDIR}/${_DKEY}"
        _NOWU=$(bb awk '{print int($1)}' /proc/uptime 2>/dev/null || bb date +%s)
        if [ -f "$_DFILE" ]; then
            _LAST=$(cat "$_DFILE" 2>/dev/null)
            case "$_LAST" in ''|*[!0-9]*) _LAST=0 ;; esac
            [ $(( _NOWU - _LAST )) -lt "$_WIN" ] && exit 0
        fi
        printf '%s' "$_NOWU" > "$_DFILE"
    fi
fi

# Skip connectivity check for forced sends (test button — always try)
if [ "$FORCE" != "force" ] && ! _internet_up; then
    _enqueue
    exit 0
fi

# Try to send; queue on failure (transient or auth error)
case "${NOTIFY_PROVIDER:-telegram}" in
    discord) send_discord || { [ "$FORCE" != "force" ] && _enqueue; } ;;
    *)       send_telegram || { [ "$FORCE" != "force" ] && _enqueue; } ;;
esac

exit 0
