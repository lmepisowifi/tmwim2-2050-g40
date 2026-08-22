# Changelog

All notable changes to the lmepisowifi modded web interface.
This file is shown verbatim in Admin > System > Software Update.

## v1.0.2
- Coin-insert resilience: if the NodeMCU drops offline mid-insert, the portal now
  shows a "Reconnecting…" banner, preserves the inserted amount, and freezes the
  countdown instead of expiring the session. Done/Cancel stay clickable throughout.
- NodeMCU firmware (FW_VERSION 1.0.2): mirrors the live coin session to flash on
  every counted coin, pauses its countdown while the portal is unreachable, and
  replays a signed recovery POST on boot so coins survive a power outage.
- `coin_result.sh` accepts a MAC-signed recovery grant when the session file is
  gone, with idempotency to prevent double-crediting.
- New tunable `COIN_RECONNECT_GRACE` (default 300s) for the portal-side hold window.

## v1.0.0
- Dynamic `/admin` redirect on the captive portal to the www2 admin UI (no hardcoded IP).
- Auto-detected br0 upstream gateway (no hardcoded 192.168.18.1).
- GitHub-based OTA updates: manual check/apply, 6-hour scheduled check,
  optional automatic install, SHA-256 verification, and automatic rollback.
