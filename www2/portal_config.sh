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

# Portal branding config endpoint — no auth required
# Reads /lmepisowifi/hotspot_data/portal.env and returns JSON for the
# captive portal index.html to apply dynamic title/brand/logo/banner.
BB="busybox"
HDATA="/lmepisowifi/hotspot_data"
PCFG="$HDATA/portal.env"
PORTAL_TITLE="lmepisowifi"
PORTAL_BRAND="beta"
PORTAL_LOGO="/img/favicon.ico"
PORTAL_BANNER=""
[ -f "$PCFG" ] && . "$PCFG" 2>/dev/null

esc_j() { printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g'; }

printf "Content-Type: application/json\r\nCache-Control: no-cache, no-store\r\n\r\n"
printf '{"title":"%s","brand":"%s","logo":"%s","banner":"%s"}\n' \
    "$(esc_j "$PORTAL_TITLE")" \
    "$(esc_j "$PORTAL_BRAND")" \
    "$(esc_j "$PORTAL_LOGO")" \
    "$(esc_j "$PORTAL_BANNER")"
