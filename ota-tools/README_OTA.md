# OTA updates for lmepisowifi — Opus 4.8

File-sync OTA (not a firmware flash). A release is a `.tar.gz` of the
`/lmepisowifi` app tree; the device downloads it from GitHub Releases, verifies
its SHA-256, atomically swaps the app directories on the UBIFS volume, restarts
the portal + admin `httpd` + hotspot watchdog, health-checks, and auto-rolls-back
on failure. Runtime data (users, vouchers, income, portal images/audio, dashboard
layout) is preserved across updates.

## Components on the device
| Path | Purpose |
|---|---|
| `/lmepisowifi/ota.sh` | the updater (check / apply / rollback / cron) |
| `/lmepisowifi/ota.env` | **local** config — pinned repo, `OTA_AUTO`, CA bundle path. Never overwritten. |
| `/lmepisowifi/VERSION` | currently-installed version |
| `/lmepisowifi/www2/cgi-bin/ota.cgi` | auth-gated web API |
| `/lmepisowifi/www2/ota.html` | Admin UI → System → Software Update |
| `/lmepisowifi/cacert.pem` | *(optional)* CA bundle for TLS cert verification |

## One-time GitHub setup (repo is currently empty)

Repo: `https://github.com/lmepisowifi/lmepisowifi`

Recommended repo layout:
```
.
├─ manifest.txt          # version pointer (committed to main; the device polls this)
├─ payload/              # == the /lmepisowifi tree that ships to devices
│  ├─ lmehspt.sh
│  ├─ ota.sh
│  ├─ ota.env            # excluded from the release tar automatically
│  ├─ hotspot/…
│  └─ www2/…
└─ ota-tools/
   └─ make_release.sh
```

Bootstrap:
```sh
git clone https://github.com/lmepisowifi/lmepisowifi
cd lmepisowifi
mkdir payload
# copy the device tree into payload/ (everything that lives under /lmepisowifi)
cp -a /path/to/lmepisowifi/* payload/
cp -a payload/ota-tools .        # keep the tools at repo root too (optional)
git add . && git commit -m "initial import" && git push
```

## Cutting a release
```sh
./ota-tools/make_release.sh 1.0.1 "Dynamic /admin redirect + auto br0 gateway"
# -> builds dist/lmepisowifi-1.0.1.tar.gz, writes manifest.txt
git add manifest.txt payload/VERSION && git commit -m "release v1.0.1" && git push
gh release create v1.0.1 dist/lmepisowifi-1.0.1.tar.gz --title v1.0.1 --notes "…"
```
The device sees the new `manifest.txt` on the next check.

## How the device checks / applies
- **Manual:** Admin UI → **System → Software Update** → *Check for updates* → *Update now*.
- **Scheduled:** `startup.sh` launches a check every 6 hours (`ota.sh cron`).
  With **Automatic updates** off (default) it only notifies via
  `hotspot/notify.sh`; toggle it on in the UI (or set `OTA_AUTO=1` in
  `/lmepisowifi/ota.env`) to auto-install on that 6-hour cycle.
- **CLI:** `sh /lmepisowifi/ota.sh check | apply | rollback | changelog`.

## Changelog
Commit a `CHANGELOG.md` to the repo root (`OTA_CHANGELOG_URL` points at its raw
URL). The admin UI fetches and displays it on the Software Update page. A
starter `CHANGELOG.md` is included in `ota-tools/`.

## TLS / certificate verification
`wget` on the device is GNU Wget 1.25 (full HTTPS). For real certificate
verification, drop a CA bundle at `/lmepisowifi/cacert.pem` (Mozilla roots, e.g.
from https://curl.se/ca/cacert.pem) — `ota.sh` uses it automatically. If the file
is absent it falls back to `--no-check-certificate`; the payload SHA-256 in the
manifest is **always** enforced, so tampered downloads are rejected regardless.

## Safety properties
- SHA-256 gate on every download; URL pinned to this repo's Releases.
- Atomic `mv` swaps on the UBIFS volume; previous trees kept as `*.ota_old`.
- Automatic rollback if the admin UI/portal don't come back healthy.
- Config & user data are never in the payload, so they survive every update.
- Downloads land in `/tmp` (RAM) — no flash wear from partial downloads.
