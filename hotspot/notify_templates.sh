#!/bin/sh
# ============================================================
# notify_templates.sh — customizable Telegram/Discord message
# formats for hotspot events.
#
# Source this file, then render a message with:
#   MSG=$(tpl_render "$TPL_NEW_SALE" totaltime "$total" mac "$mac" ...)
#
# Template syntax:
#   *placeholder*   replaced with the matching value passed to tpl_render
#   %0A             line break (same convention as the MikroTik RouterOS
#                   edition, so templates can be copy-pasted between them)
#
# User overrides live in:
#   /lmepisowifi/hotspot_data/notify_templates.env
# Edit them via the www2 admin UI (Income & Notifications page) or by
# hand. Any TPL_* left unset/empty there falls back to the built-in
# default below, so clearing a field never sends a blank message.
# ============================================================

BB="busybox"

# ── Built-in defaults ─────────────────────────────────────────────────────
DEFAULT_TPL_NEW_SALE='%0A-------New Sale-------%0AMAC: *mac*%0ATime Added: *addedtime*%0ATotal Time: *totaltime*%0ARemaining Time: *remainingtime*%0ACoin: ₱*insertcoinamt*%0A%0AOther Information: %0AActive Users: *activeusrcount*%0ADaily: ₱*dailyamt* | Monthly: ₱*monthlyamt* | Yearly: ₱*yearlyamt*%0ADate: *date*%0A%0ASystem Information:%0ACPU Usage: *cpuusage* %0ARAM Usage: *ramusage* %0A'
DEFAULT_TPL_COINS_INSERTED='Coins Inserted%0AAmount: ₱*insertcoinamt*%0ADevice: *mac*'
DEFAULT_TPL_ANTI_TROLL='-------Insert Coin Suspended-------%0ADevice: *mac*%0AReached *strikemax* Strikes%0ASuspended For: *cooldownmins* minute(s)'
DEFAULT_TPL_VOUCHER_ANTI_TROLL='-------Voucher Conversion Suspended-------%0ADevice: *mac*%0AReached *strikemax* Strikes%0ASuspended For: *cooldownmins* minute(s)'
DEFAULT_TPL_SESSION_EXPIRED='-------Ran Out of Time-------%0ADevice: *mac*'
DEFAULT_TPL_SESSION_PAUSED='-------Time Paused *reason*-------%0ADevice: *mac*'
DEFAULT_TPL_SESSION_RESUMED='-------Resumed Time-------%0ADevice: *mac*%0ATime Remaining: *remainingtime*%0AActive Users: *activeusrcount*'
DEFAULT_TPL_VOUCHER_REDEEMED='-------Redeemed Voucher-------%0ADevice: *mac*%0AVoucher: *voucher*%0ATime Added: *addedtime*%0ATotal Time: *totaltime*%0ARemaining Time: *remainingtime*%0A'
DEFAULT_TPL_DAILY_REPORT='-------Daily Income-------%0ADate: *label*%0ATotal: ₱*amount*'
DEFAULT_TPL_MONTHLY_REPORT='-------Monthly Income------- Report%0AMonth: *label*%0ATotal: ₱*amount*'
DEFAULT_TPL_YEARLY_REPORT='-------Yearly Income-------%0AYear: *label*%0ATotal: ₱*amount*'
DEFAULT_TPL_TEST_ALERT='this is a test message.'

# ── Load user overrides ──────────────────────────────────────────────────
_TPL_ENV="/lmepisowifi/hotspot_data/notify_templates.env"
[ -f "$_TPL_ENV" ] && . "$_TPL_ENV" 2>/dev/null

# Empty/unset override -> built-in default (":-" covers both cases)
TPL_NEW_SALE="${TPL_NEW_SALE:-$DEFAULT_TPL_NEW_SALE}"
TPL_COINS_INSERTED="${TPL_COINS_INSERTED:-$DEFAULT_TPL_COINS_INSERTED}"
TPL_ANTI_TROLL="${TPL_ANTI_TROLL:-$DEFAULT_TPL_ANTI_TROLL}"
TPL_VOUCHER_ANTI_TROLL="${TPL_VOUCHER_ANTI_TROLL:-$DEFAULT_TPL_VOUCHER_ANTI_TROLL}"
TPL_SESSION_EXPIRED="${TPL_SESSION_EXPIRED:-$DEFAULT_TPL_SESSION_EXPIRED}"
TPL_SESSION_PAUSED="${TPL_SESSION_PAUSED:-$DEFAULT_TPL_SESSION_PAUSED}"
TPL_SESSION_RESUMED="${TPL_SESSION_RESUMED:-$DEFAULT_TPL_SESSION_RESUMED}"
TPL_VOUCHER_REDEEMED="${TPL_VOUCHER_REDEEMED:-$DEFAULT_TPL_VOUCHER_REDEEMED}"
TPL_DAILY_REPORT="${TPL_DAILY_REPORT:-$DEFAULT_TPL_DAILY_REPORT}"
TPL_MONTHLY_REPORT="${TPL_MONTHLY_REPORT:-$DEFAULT_TPL_MONTHLY_REPORT}"
TPL_YEARLY_REPORT="${TPL_YEARLY_REPORT:-$DEFAULT_TPL_YEARLY_REPORT}"
TPL_TEST_ALERT="${TPL_TEST_ALERT:-$DEFAULT_TPL_TEST_ALERT}"

# ── Live system stats (used by the universal *ramusage* / *cpuusage* tokens) ──
# RAM: matches busybox top's own "used" calc (total - free - buffers - cached),
# i.e. excludes reclaimable buffer/cache, so it lines up with the device's
# own `top` output rather than counting cache as "used". Reported in MB
# (rounded to the nearest whole MB) rather than a bare/ambiguous number.
get_ram_usage_mb() {
    $BB awk '
        /^MemTotal:/  { total = $2 }
        /^MemFree:/   { free = $2 }
        /^Buffers:/   { buff = $2 }
        /^Cached:/    { cached = $2 }
        END {
            if (total <= 0) { print 0; exit }
            used = total - free - buff - cached
            if (used < 0) used = 0
            printf "%d", (used + 512) / 1024
        }
    ' /proc/meminfo
}

# CPU: total (non-idle) usage over a short sampling window, computed from
# /proc/stat jiffy deltas — the same source `top` itself reads from. Two
# snapshots ~0.3s apart are needed for an instantaneous reading (a single
# snapshot only gives cumulative totals since boot, which isn't useful).
get_cpu_usage_pct() {
    local line1 line2 t1 i1 t2 i2 dt di
    line1=$($BB awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%d %d", t, $5}' /proc/stat)
    sleep 0.3 2>/dev/null || sleep 1
    line2=$($BB awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%d %d", t, $5}' /proc/stat)

    set -- $line1; t1=$1; i1=$2
    set -- $line2; t2=$1; i2=$2

    dt=$(( t2 - t1 ))
    di=$(( i2 - i1 ))
    if [ "$dt" -le 0 ]; then printf '0'; return; fi
    printf '%d' $(( (dt - di) * 100 / dt ))
}

# ── Renderer ──────────────────────────────────────────────────────────────
# tpl_render <template> [<name1> <value1> ...]
# Replaces every *name* token with its value (plain substring search, no
# regex, so values are never mis-interpreted), then converts literal %0A
# sequences to real newlines. Tokens with no matching value are left as-is.
#
# *ramusage* (actual RAM used, e.g. "128 MB") and *cpuusage* (percentage,
# e.g. "8%" — the "%" is already included, don't add your own or it can
# break the Discord/Telegram send) are available in EVERY template
# automatically. They're computed lazily, only when the template actually
# references them, since the CPU sample needs a short ~0.3s window.
tpl_render() {
    local _t="$1"; shift
    case "$_t" in *'*ramusage*'*) set -- "$@" ramusage "$(get_ram_usage_mb) MB" ;; esac
    case "$_t" in *'*cpuusage*'*) set -- "$@" cpuusage "$(get_cpu_usage_pct)%" ;; esac
    while [ "$#" -ge 2 ]; do
        _t=$($BB awk -v t="$_t" -v ph="*$1*" -v val="$2" '
            BEGIN {
                n = length(ph); s = t; out = ""
                while ((i = index(s, ph)) > 0) {
                    out = out substr(s, 1, i - 1) val
                    s = substr(s, i + n)
                }
                printf "%s", out s
            }')
        shift 2
    done
    $BB awk -v t="$_t" 'BEGIN { gsub(/%0A/, "\n", t); printf "%s", t }'
}
