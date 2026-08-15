#!/bin/sh
# ipacl.cgi — Remote/local access control for router management services
# (telnet, ftp, tftp, web, https, ssh, snmp), backed by ACC_TBL.
#
# GET  ?action=list          → current level + port for each service (JSON)
# POST ?action=set  body: service=<name>&level=<0-3>
#       → applies iptables rules (ipacl.sh), sets + commits the mib value

SESSION_TIMEOUT=600

# ── Auth ──────────────────────────────────────────────────────────────────────
BROWSER_SESSION=$(echo "$HTTP_COOKIE" \
    | busybox sed -n 's/.*session=\([^;]*\).*/\1/p' \
    | busybox tr -d '\r\n')
BROWSER_SESSION=$(printf '%s' "$BROWSER_SESSION" \
    | busybox tr -cd 'a-fA-F0-9')
SESSION_FILE="/tmp/sessions/$BROWSER_SESSION"

if [ -z "$BROWSER_SESSION" ] || [ ! -f "$SESSION_FILE" ]; then
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

LAST=$(cat "$SESSION_FILE" 2>/dev/null | busybox tr -d '\r\n')
NOW=$(date +%s)
[ -z "$LAST" ] && LAST=$NOW
if [ $((NOW - LAST)) -gt $SESSION_TIMEOUT ]; then
    rm -f "$SESSION_FILE"
    printf "Status: 302 Found\r\nLocation: /login.html\r\n\r\n"
    exit 0
fi

_STMP=$(mktemp /tmp/sessions/.tmp.XXXXXX)
echo "$NOW" > "$_STMP"
busybox mv "$_STMP" "$SESSION_FILE"

# ── Shared logic (functions only — see ipacl.sh for the actual rules) ────────
. /lmepisowifi/www2/sh/ipacl.sh --lib

json_esc() { printf '%s' "$1" | busybox sed 's/\\/\\\\/g; s/"/\\"/g'; }

svc_label() {
    case "$1" in
        telnet) echo "Telnet"    ;;
        ftp)    echo "FTP"       ;;
        tftp)   echo "TFTP"      ;;
        web)    echo "Web (HTTP)"  ;;
        https)  echo "Web (HTTPS)" ;;
        ssh)    echo "SSH"       ;;
        snmp)   echo "SNMP"      ;;
        *)      echo "$1"        ;;
    esac
}

SUPPORTED_SERVICES="telnet ftp tftp web https ssh snmp"

# ════════════════════════════════════════════════════════════════════════════════
# GET
# ════════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "GET" ]; then

    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    if [ "$ACTION" = "list" ]; then
        JSON="["
        FIRST=1
        for SVC in $SUPPORTED_SERVICES; do
            LVL=$(mib_field "ACC_TBL.0.${SVC}")
            case "$LVL" in 0|1|2|3) ;; *) LVL=0 ;; esac

            PP=$(svc_proto_port "$SVC")
            PROTO=${PP%% *}
            PORT=${PP#* }

            [ "$FIRST" = "1" ] && FIRST=0 || JSON="${JSON},"
            JSON="${JSON}{\"service\":\"$(json_esc "$SVC")\""
            JSON="${JSON},\"label\":\"$(json_esc "$(svc_label "$SVC")")\""
            JSON="${JSON},\"level\":${LVL}"
            JSON="${JSON},\"proto\":\"$(json_esc "$PROTO")\""
            JSON="${JSON},\"port\":${PORT}"
            # ssh is the only service backed by an on-demand daemon (dropbear)
            # rather than one that's always running — surface its live state.
            if [ "$SVC" = "ssh" ]; then
                if dropbear_running; then DBR=true; else DBR=false; fi
                JSON="${JSON},\"daemonRunning\":${DBR}"
            fi
            JSON="${JSON}}"
        done
        JSON="${JSON}]"

        printf "Status: 200 OK\r\n"
        printf "Content-Type: application/json\r\n\r\n"
        printf '{"services":%s}' "$JSON"
        exit 0
    fi

    printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
    printf "Unknown action"
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════
# POST
# ════════════════════════════════════════════════════════════════════════════════
if [ "$REQUEST_METHOD" = "POST" ]; then

    __CL="${CONTENT_LENGTH:-0}"
    case "$__CL" in *[!0-9]*|"") __CL=0 ;; esac
    [ "$__CL" -gt 65536 ] && __CL=65536
    POST_DATA=$(busybox dd bs=1 count="$__CL" 2>/dev/null)

    ACTION=$(echo "$QUERY_STRING" \
        | busybox sed -n 's/.*action=\([^&]*\).*/\1/p' \
        | busybox tr -d '\r\n')

    if [ "$ACTION" = "set" ]; then
        FORM_SVC=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*service=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_LVL=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*level=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        # Whitelist: only the supported single-port services
        VALID_SVC=0
        for _S in $SUPPORTED_SERVICES; do
            [ "$_S" = "$FORM_SVC" ] && VALID_SVC=1
        done
        if [ "$VALID_SVC" != "1" ]; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Invalid service"
            exit 0
        fi

        case "$FORM_LVL" in
            0|1|2|3) ;;
            *)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid level"
                exit 0
                ;;
        esac

        # Apply the iptables rules first, then persist the mib value —
        # if apply_acc_rule fails (unknown port mapping) the mib is left
        # untouched so `mib get` never claims a level that isn't enforced.
        if ! apply_acc_rule "$FORM_SVC" "$FORM_LVL"; then
            printf "Status: 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\n"
            printf "Failed to apply rules"
            exit 0
        fi

        mib set "ACC_TBL.0.${FORM_SVC}" "$FORM_LVL"
        mib commit

        if [ "$FORM_SVC" = "ssh" ]; then
            if dropbear_running; then DBR=true; else DBR=false; fi
            printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n"
            printf '{"ok":true,"service":"%s","level":%s,"daemonRunning":%s}' \
                "$(json_esc "$FORM_SVC")" "$FORM_LVL" "$DBR"
        else
            printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n"
            printf '{"ok":true,"service":"%s","level":%s}' \
                "$(json_esc "$FORM_SVC")" "$FORM_LVL"
        fi

        # the response above before any daemon restart takes effect.
        {
            [ "$FORM_SVC" = "ftp"    ] && [ "$FORM_LVL" = "0" ] && busybox pkill -f ftpd
            [ "$FORM_SVC" = "telnet" ] && [ "$FORM_LVL" = "0" ] && busybox pkill -f telnetd
            /etc/scripts/loadinetdconf.sh
        } >/dev/null 2>&1 &
        exit 0
    fi

    # ── set_port: SSH-only. The stock firmware has no concept of a
    # configurable dropbear port at all — telnet/ftp/web/etc are handled
    # by daemons that are always running with a fixed, vendor-hardcoded
    # port, so rewriting ACC_TBL.0.<svc>_port for them would change what
    # the iptables rule targets without changing what the daemon actually
    # listens on. SSH is different because www2 itself launches dropbear,
    # so it's the one service where the port can be genuinely rebound.
    if [ "$ACTION" = "set_port" ]; then
        FORM_SVC=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*service=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')
        FORM_PORT=$(echo "$POST_DATA" \
            | busybox sed -n 's/.*port=\([^&]*\).*/\1/p' \
            | busybox tr -d '\r\n')

        if [ "$FORM_SVC" != "ssh" ]; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Only the SSH port can be changed here"
            exit 0
        fi

        case "$FORM_PORT" in
            ''|*[!0-9]*)
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Invalid port"
                exit 0
                ;;
        esac
        if [ "$FORM_PORT" -lt 1 ] || [ "$FORM_PORT" -gt 65535 ]; then
            printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
            printf "Port must be between 1 and 65535"
            exit 0
        fi

        # Reject collisions with the other management services' current
        # ports (their fixed daemons already own those ports).
        for _S in telnet ftp tftp web https snmp; do
            _SPP=$(svc_proto_port "$_S")
            _SPORT=${_SPP#* }
            if [ "$FORM_PORT" = "$_SPORT" ]; then
                printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
                printf "Port %s is already used by %s" "$FORM_PORT" "$_S"
                exit 0
            fi
        done

        mib set "ACC_TBL.0.ssh_port" "$FORM_PORT"
        mib commit

        # Re-apply at the current level: this rewrites the iptables rule
        # to the new port and — since apply_acc_rule's ssh branch always
        # restarts dropbear when level != 0 — rebinds the live daemon too.
        LVL=$(mib_field "ACC_TBL.0.ssh")
        case "$LVL" in 0|1|2|3) ;; *) LVL=0 ;; esac
        if ! apply_acc_rule "ssh" "$LVL"; then
            printf "Status: 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\n"
            printf "Failed to apply new port"
            exit 0
        fi

        if dropbear_running; then DBR=true; else DBR=false; fi
        printf "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n"
        printf '{"ok":true,"service":"ssh","port":%s,"level":%s,"daemonRunning":%s}' \
            "$FORM_PORT" "$LVL" "$DBR"
        exit 0
    fi
fi

# Fallback
printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n"
printf "Bad request"
