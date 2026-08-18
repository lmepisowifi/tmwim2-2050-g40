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
# notify.sh — send hotspot event messages to Telegram/Discord, AND
#             (in --bot mode) run the interactive Telegram command
#             router bot. Merged into one file so both share the same
#             config, wget transport, and Telegram JSON parsing.
#
#   notify.sh "message text"                 send if alerts are enabled
#   notify.sh "message text" force            send even if disabled (test)
#   notify.sh "message text" "" event_key     send only if that event is
#                                              not individually muted
#   notify.sh "msg" "" event_key dedup_key    as above, but also suppress
#                                              rapid repeats of the SAME
#                                              event+dedup_key (anti-spam)
#   notify.sh --drain                         flush queued messages
#   notify.sh --bot                           run the interactive
#                                              command-router bot
#                                              (foreground, long-running —
#                                              launch it backgrounded/
#                                              supervised, it never returns)
#   notify.sh --bot-autostart                 boot-time launcher: starts
#                                              --bot in the background (and
#                                              writes /tmp/telegram_bot.pid)
#                                              IFF BOT_AUTOSTART="1" in
#                                              telegram_bot.env, i.e. the
#                                              admin panel's bot switch was
#                                              left on. No-op otherwise, or
#                                              if already running. Called
#                                              from a boot marker in
#                                              www2/sh/startup.sh that
#                                              hotspot.cgi adds/removes
#                                              when the switch is toggled.
#
# event_key (optional 3rd arg) lets the admin silence one event type
# without disabling everything. Each event maps to a NOTIFY_EVT_<KEY>
# flag in notify.env; when that flag is explicitly "0" the message is
# dropped. Unset/empty flags default to enabled, so older configs keep
# every event firing. "force" (test button) bypasses this check.
#
# Config is read from /lmepisowifi/hotspot_data/notify.env
# Queue dir:  /lmepisowifi/hotspot_data/queued_messages/
# Bot config: /lmepisowifi/hotspot_data/telegram_bot.env (--bot /
#             --bot-autostart modes only)
#
# When internet is unreachable, messages are queued and retried
# automatically when the watchdog calls --drain (every 60s).
#
# No curl on this device — every Telegram/Discord call in this file goes
# through GNU wget with --no-check-certificate (see $WGET below).
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

# ============================================================
# --- Interactive Telegram router bot (--bot mode) ------------------------
#
# Everything below this point is only used when notify.sh is launched as
# `notify.sh --bot`. It's a long-poll command router (status/reboot/
# hotspotstats/...), formerly a standalone telegram_bot.sh, merged in
# here so it shares this file's $WGET transport and config instead of
# duplicating a second curl-based HTTP layer.
# ============================================================

# ---------------------------------------------------------------
# Minimal generic JSON parser (bot mode only) — no jq required.
#
# Flattens any JSON into "path<TAB>value" lines via a grep -Eo tokenizer
# + recursive-descent walker, then looks values up by path, so it
# doesn't depend on field ordering the way naive anchor-based grep/sed
# would.
#
# Usage:  json_get "$JSON_TEXT" "path/to/value"   (array indices are numeric)
#         e.g. json_get "$UPDATE" "result/0/message/from/id"
# ---------------------------------------------------------------

JNL='
'

_json_tokenize() {
    printf '%s' "$1" | grep -Eo '"([^"\\]|\\.)*"|-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null|\{|\}|\[|\]|:|,'
}

_json_peek() { JTOKEN=${JTOKENS%%"$JNL"*}; }

_json_advance() {
    _json_peek
    case "$JTOKENS" in
        *"$JNL"*) JTOKENS=${JTOKENS#*"$JNL"} ;;
        *) JTOKENS="" ;;
    esac
}

# Strip quotes + unescape a JSON string token; numbers/bool/null pass through as-is.
_json_scalar() {
    case "$1" in
        \"*\")
            s=${1#\"}; s=${s%\"}
            printf '%s' "$s" | sed 's/\\"/"/g; s/\\\\/\\/g; s/\\\//\//g'
            ;;
        *) printf '%s' "$1" ;;
    esac
}

_json_value() {
    local p="$1"
    _json_peek
    case "$JTOKEN" in
        '{') _json_object "$p" ;;
        '[') _json_array "$p" ;;
        *)   _json_advance; printf '%s\t%s\n' "$p" "$(_json_scalar "$JTOKEN")" ;;
    esac
}

_json_object() {
    local p="$1" key
    _json_advance
    _json_peek
    [ "$JTOKEN" = '}' ] && { _json_advance; return; }
    while :; do
        _json_advance
        [ -z "$JTOKEN" ] && break        # truncated/malformed JSON guard
        key=$(_json_scalar "$JTOKEN")
        _json_advance                    # consume ':'
        [ -n "$p" ] && _json_value "$p/$key" || _json_value "$key"
        _json_peek
        case "$JTOKEN" in
            ',') _json_advance ;;
            '}') _json_advance; break ;;
            '')  break ;;
        esac
    done
}

_json_array() {
    local p="$1" idx=0
    _json_advance
    _json_peek
    [ "$JTOKEN" = ']' ] && { _json_advance; return; }
    while :; do
        [ -n "$p" ] && _json_value "$p/$idx" || _json_value "$idx"
        idx=$((idx + 1))
        _json_peek
        case "$JTOKEN" in
            ',') _json_advance ;;
            ']') _json_advance; break ;;
            '')  break ;;
        esac
    done
}

# Flatten JSON text ($1) to "path<TAB>value" lines.
json_flatten() {
    JTOKENS=$(_json_tokenize "$1")
    _json_value ""
}

# Get a single value by path, e.g. json_get "$JSON" "result/0/message/text"
json_get() {
    json_flatten "$1" | while IFS="$BOTTAB" read -r p v; do
        if [ "$p" = "$2" ]; then
            printf '%s' "$v"
            break
        fi
    done
}
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# Command registry — "name|description|handler" one per line.
# To add a command: add a line here and a cmd_<name>() function below.
# To remove one: delete its line (or set CMD_ENABLED_<NAME>="0" in
# telegram_bot.env to disable it without touching code).
#
# NOTE: hotspot.cgi extracts this exact block out of THIS file (by
# sed'ing between the CMD_REGISTRY=" line and the closing ") to build
# the admin UI's command list, so keep this assignment's formatting
# (leading `CMD_REGISTRY="` at column 1, closing `"` alone at EOL) as-is.
# ---------------------------------------------------------------
CMD_REGISTRY="status|Check router uptime|cmd_status
reboot|Reboot the router|cmd_reboot
hotspotstats|View hotspot status, sessions, and income|cmd_hotspot_stats"

esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Is command $1 (bare name, no slash) enabled? Missing/unset flag = enabled,
# so a telegram_bot.env from before this command existed still runs it.
cmd_is_enabled() {
    local key flag
    key=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9_')
    [ -n "$key" ] || return 1
    eval "flag=\"\${CMD_ENABLED_${key}:-1}\""
    [ "$flag" != "0" ]
}

# Build the setMyCommands JSON array, skipping disabled commands.
build_commands_json() {
    local first=1 out="" name desc handler
    while IFS='|' read -r name desc handler; do
        [ -z "$name" ] && continue
        cmd_is_enabled "$name" || continue
        if [ "$first" = "1" ]; then first=0; else out="${out},"; fi
        out="${out}{\"command\":\"$(esc_json "$name")\",\"description\":\"$(esc_json "$desc")\"}"
    done <<EOF
$CMD_REGISTRY
EOF
    printf '[%s]' "$out"
}

# Look up the handler function name for bare command $1, empty if none.
lookup_handler() {
    local target="$1" name desc handler
    while IFS='|' read -r name desc handler; do
        if [ "$name" = "$target" ]; then
            printf '%s' "$handler"
            return
        fi
    done <<EOF
$CMD_REGISTRY
EOF
}

# --- Command handlers -------------------------------------------------
# Each sets $RESPONSE (the reply text) and, optionally, $POST_ACTION
# (an action to run AFTER the reply is sent, e.g. "reboot").

cmd_status() {
    RESPONSE=$(uptime)
}

cmd_reboot() {
    RESPONSE="Rebooting router now..."
    POST_ACTION="reboot"
}

cmd_hotspot_stats() {
    if [ ! -d /lmepisowifi/hotspot ]; then
        RESPONSE="Hotspot module is not installed on this device."
        return
    fi

    local running="Stopped"
    if [ -f /tmp/hotspot_watchdog.pid ]; then
        local pid
        pid=$(cat /tmp/hotspot_watchdog.pid 2>/dev/null)
        kill -0 "$pid" 2>/dev/null && running="Running"
    fi

    local sessions=0
    if [ -f /tmp/active_sessions.txt ]; then
        sessions=$(grep -c '.' /tmp/active_sessions.txt 2>/dev/null)
        [ -n "$sessions" ] || sessions=0
    fi

    local income_json daily monthly yearly total
    income_json=$(/lmepisowifi/hotspot/income.sh get 2>/dev/null)
    [ -n "$income_json" ] || income_json='{"daily":0,"monthly":0,"yearly":0,"total":0,"synced":false}'
    daily=$(json_get "$income_json" "daily");     [ -n "$daily" ]   || daily=0
    monthly=$(json_get "$income_json" "monthly"); [ -n "$monthly" ] || monthly=0
    yearly=$(json_get "$income_json" "yearly");   [ -n "$yearly" ]  || yearly=0
    total=$(json_get "$income_json" "total");     [ -n "$total" ]   || total=0

    RESPONSE="Hotspot: ${running}
Active sessions: ${sessions}

Income
Today: ₱${daily}
Month: ₱${monthly}
Year: ₱${yearly}
All-time: ₱${total}"
}
# ------------------------------------------------------------------------

# wget POST of a JSON body (setMyCommands) — replaces `curl -s -X POST ... -d`.
_bot_post_json() {
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --header="Content-Type: application/json" \
        --post-data="$2" \
        "$1" 2>/dev/null
}

# wget POST of a chat_id/text reply — replaces `curl -s -d ... -d ...`.
_bot_send_reply() {
    local chat_id="$1" text="$2" enc
    enc=$(urlenc "$text")
    "$WGET" -q -T "$TIMEOUT" --no-check-certificate -O /dev/null \
        --post-data="chat_id=${chat_id}&text=${enc}" \
        "$BOT_API_URL/sendMessage" 2>/dev/null
}

run_bot() {
    local BOT_OFFSET=0
    BOTTAB="$(printf '\t')"

    # === Bot configuration ===
    local BOT_ENV="/lmepisowifi/hotspot_data/telegram_bot.env"

    # Seed values only — used to create $BOT_ENV the first time this bot
    # ever runs on a device, and as a last-resort fallback. Once $BOT_ENV
    # exists it is the source of truth; edit that file, not this script.
    # REMEMBER: Revoke and regenerate your token in @BotFather!
    local BOT_TOKEN_SEED="YOUR_BOT_TOKEN_HERE"
    local ALLOWED_USER_IDS="6664530859"

    if [ ! -f "$BOT_ENV" ]; then
        mkdir -p "$(dirname "$BOT_ENV")" 2>/dev/null
        cat > "$BOT_ENV" 2>/dev/null <<EOF
# telegram_bot.env — persisted router-bot config.
# Auto-created on first run. Edit THIS file, not the script — updates to
# notify.sh only replace the code, never this file.
#
# Leave BOT_TOKEN empty to reuse the bot token already configured for
# Telegram alerts in notify.env (one bot for alerts + commands). Set it
# here only if the interactive bot should use a different token.
BOT_TOKEN=""
ALLOWED_USER_IDS="$ALLOWED_USER_IDS"

# Start the router bot automatically on every boot. Kept in sync with the
# bot switch in the admin panel (Hotspot > Income > Telegram Bot Commands)
# -- flipping that switch rewrites this line AND adds/removes a matching
# boot marker in www2/sh/startup.sh, so this file doesn't need hand-
# editing. "1" = launch at boot; "0"/unset = stays off until the admin
# flips the switch again.
BOT_AUTOSTART="0"

# Per-command on/off switches. "0" removes a command from the Telegram
# menu and refuses it if sent anyway. Missing/unset = enabled, so this
# file staying untouched after a new command is added keeps working —
# same convention as NOTIFY_EVT_* in notify.env.
# CMD_ENABLED_STATUS="1"
# CMD_ENABLED_REBOOT="1"
# CMD_ENABLED_HOTSPOTSTATS="1"
EOF
    fi

    local BOT_TOKEN=""
    [ -f "$BOT_ENV" ] && . "$BOT_ENV" 2>/dev/null
    local TOKEN="$BOT_TOKEN_SEED"
    [ -n "$BOT_TOKEN" ] && TOKEN="$BOT_TOKEN"
    [ -n "$ALLOWED_USER_IDS" ] || ALLOWED_USER_IDS="6664530859"

    # Merge with the existing notification bot: only falls back to it when
    # this bot's own token was never set (still the placeholder), so an
    # already-working custom token here is never silently swapped out.
    if [ "$TOKEN" = "YOUR_BOT_TOKEN_HERE" ] && [ -f "$NOTIFY_ENV" ]; then
        local TG_BOT_TOKEN=""
        . "$NOTIFY_ENV" 2>/dev/null
        [ -n "$TG_BOT_TOKEN" ] && TOKEN="$TG_BOT_TOKEN"
    fi

    BOT_API_URL="https://api.telegram.org/bot$TOKEN"
    # =====================

    # === Register Telegram Menu Commands for Whitelisted Users ===
    echo "Registering menu commands for authorized users..."

    local COMMANDS_JSON
    COMMANDS_JSON=$(build_commands_json)

    local OIFS="$IFS" ID
    IFS=','
    for ID in $ALLOWED_USER_IDS; do
        # Remove any trailing/leading spaces
        ID=$(printf '%s' "$ID" | tr -d ' ')
        if [ -n "$ID" ]; then
            _bot_post_json "$BOT_API_URL/setMyCommands" \
                "{\"commands\":${COMMANDS_JSON},\"scope\":{\"type\":\"chat\",\"chat_id\":${ID}}}"
        fi
    done
    IFS="$OIFS"
    # =============================================================

    echo "Router Bot Started..."

    local UPDATE OK UPDATE_ID USER_ID CHAT_ID COMMAND RESPONSE POST_ACTION CMD_NAME HANDLER
    while true; do
        # Fetch updates (max 1 at a time, 30s long-poll timeout; local wget
        # timeout is set higher than that so wget doesn't cut the connection
        # before Telegram's own long-poll returns).
        UPDATE=$("$WGET" -q -T 35 --no-check-certificate -O - \
            "$BOT_API_URL/getUpdates?offset=$BOT_OFFSET&limit=1&timeout=30" 2>/dev/null)

        OK=$(json_get "$UPDATE" "ok")
        if [ "$OK" = "true" ]; then

            UPDATE_ID=$(json_get "$UPDATE" "result/0/update_id")

            if [ -n "$UPDATE_ID" ]; then
                USER_ID=$(json_get "$UPDATE" "result/0/message/from/id")
                CHAT_ID=$(json_get "$UPDATE" "result/0/message/chat/id")
                COMMAND=$(json_get "$UPDATE" "result/0/message/text")

                # --- SECURITY CHECK ---
                # We wrap both the list and the user's ID in commas to ensure exact matches
                case ",$ALLOWED_USER_IDS," in
                    *",${USER_ID},"*)
                        RESPONSE=""
                        POST_ACTION=""

                        # --- COMMAND ROUTING (data-driven — see CMD_REGISTRY) ---
                        CMD_NAME=""
                        case "$COMMAND" in
                            /*) CMD_NAME=${COMMAND#/} ;;
                        esac

                        HANDLER=""
                        [ -n "$CMD_NAME" ] && HANDLER=$(lookup_handler "$CMD_NAME")

                        if [ -n "$HANDLER" ] && cmd_is_enabled "$CMD_NAME"; then
                            "$HANDLER"
                        else
                            RESPONSE="Unknown command."
                        fi

                        # Send the response back
                        _bot_send_reply "$CHAT_ID" "$RESPONSE"

                        # Execute delayed commands (set by the handler) after sending
                        [ "$POST_ACTION" = "reboot" ] && reboot
                        ;;
                    *)
                        # Reject unauthorized users
                        _bot_send_reply "$CHAT_ID" "Unauthorized user. Access denied."
                        ;;
                esac

                # Increment the offset to tell Telegram we processed this message
                BOT_OFFSET=$((UPDATE_ID + 1))
            fi
        fi
        # 2-second pause to prevent CPU pegging in case of network dropouts
        sleep 2
    done
}
# --- end interactive Telegram router bot -----------------------------------

# ── Dispatch ───────────────────────────────────────────────────────────────
if [ "$MSG" = "--bot" ]; then
    run_bot
    exit $?
fi

# Boot-time launcher — called once from a www2/sh/startup.sh marker (added/
# removed by hotspot.cgi's telegram_bot_toggle action, same as the
# Tailscale switch's boot marker). Starts the bot in the background only
# if the admin panel's switch was left on, and is a silent no-op if it's
# off, never configured, or already running (e.g. a stray pidfile that
# survived an unclean shutdown is verified live, not just present).
if [ "$MSG" = "--bot-autostart" ]; then
    _AS_BOT_ENV="/lmepisowifi/hotspot_data/telegram_bot.env"
    BOT_AUTOSTART="0"
    [ -f "$_AS_BOT_ENV" ] && . "$_AS_BOT_ENV" 2>/dev/null
    if [ "$BOT_AUTOSTART" = "1" ]; then
        if [ -f /tmp/telegram_bot.pid ] && kill -0 "$(cat /tmp/telegram_bot.pid)" 2>/dev/null; then
            exit 0
        fi
        "$0" --bot >/tmp/telegram_bot_start.log 2>&1 &
        echo $! > /tmp/telegram_bot.pid
    fi
    exit 0
fi

[ -n "$MSG" ] || exit 0
[ -f "$NOTIFY_ENV" ] || exit 0

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
