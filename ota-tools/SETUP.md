# Bootstrapping OTA from an empty GitHub repo

The device's `ota.sh` does NOT pull loose files. It reads a **manifest** and
downloads a **release tarball asset**, and it hard-pins that tarball to
`github.com/<OTA_REPO>/releases/download/...`. So going live means (1) putting
the source in the repo, (2) publishing the first release, (3) a one-time manual
bootstrap of the device and the coin slot. Do it once, then every future update
is `git tag vX.Y.Z && git push --tags`.

---

## Step 1 — Put the app in the repo

Make the repo root mirror `/lmepisowifi`. At minimum it must contain the OTA
components plus the firmware source:

```
lmepisowifi/                 (repo root)
├── hotspot/                 ← component (includes hotspot/firmware/coin_nodemcu.bin)
├── www2/                    ← component
├── lmehspt.sh               ← component
├── ota.sh                   ← component
├── defaults.env             ← component
├── hotspot/nodemcucodeholder    (NodeMCU sketch source)
├── release.sh
├── ota.env.example
├── CHANGELOG.md
└── .github/workflows/release.yml
```

Do NOT commit runtime state: `globals.env`, `ota.env`, `VERSION`,
`hotspot_data/`, `*.ota_old`. Add them to `.gitignore`.

```sh
cd /path/to/lmepisowifi
git init && git branch -M main
printf 'globals.env\nota.env\nVERSION\nhotspot_data/\n*.ota_old\ndist/\nbuild/\n' > .gitignore
git remote add origin git@github.com:YOUR_GH_USERNAME/lmepisowifi.git
git add . && git commit -m "initial import" && git push -u origin main
```

## Step 2 — One-time NodeMCU bootstrap (USB)

**Chicken-and-egg:** the coin slot can only self-flash once it's ALREADY running
firmware that has the new `/version` + `/update` endpoints. So flash it once
over USB with the updated `nodemcucodeholder` (as `coin_nodemcu.ino`):

- Arduino IDE → Tools → **Flash Size: "4MB (FS:1MB OTA:~1019KB)"** (reserves the
  OTA slot), or arduino-cli FQBN `...:eesz=4M2M`.
- Upload over USB. `FW_VERSION` is `1.0.0`.

After this, every later firmware change ships over OTA automatically.

## Step 3 — Publish the first release

Locally (needs `gh` authenticated + `arduino-cli`), or just push a tag to let
the Actions workflow do it:

```sh
./release.sh 1.0.0 "Initial release"
#   or:
git tag v1.0.0 && git push origin v1.0.0     # triggers .github/workflows/release.yml
```

This produces `manifest.txt` at the repo root and a Release `v1.0.0` with
`lmepisowifi-1.0.0.tar.gz` attached, containing `hotspot/firmware/coin_nodemcu.bin`.

## Step 4 — Deploy the base image + config to the ONT (once)

The very first install is manual — OTA can only *update* an already-running
install. Copy the tree to the device and seed its config:

```sh
scp -r hotspot www2 lmehspt.sh ota.sh defaults.env  root@<ont>:/lmepisowifi/
ssh root@<ont>
  cp /lmepisowifi/defaults.env /lmepisowifi/globals.env   # seed user settings
  # edit globals.env: NODEMCU_IP, NODEMCU_PORT, COIN_PSK, portal IP, etc.
  cp /lmepisowifi/ota.env.example /lmepisowifi/ota.env     # from the repo
  # edit ota.env: set OTA_REPO + OTA_MANIFEST_URL to your repo
  echo "1.0.0" > /lmepisowifi/VERSION                      # match the release
  chmod +x /lmepisowifi/ota.sh /lmepisowifi/lmehspt.sh
```

> Tip: to test the OTA path end-to-end immediately, seed `VERSION` with `0.0.0`
> instead — then `ota.sh check` will report an update and you can exercise a
> full apply right away.

## Step 5 — Verify

```sh
ssh root@<ont>
  sh /lmepisowifi/ota.sh check      # -> {"current":"1.0.0","latest":"1.0.0","update_available":false,...}
  sh /lmepisowifi/ota.sh nodemcu    # force a coin-slot version check/push
  cat /tmp/ota.log
```

`ota.sh nodemcu` should log `already on 1.0.0 — no flash needed` (the gate
working). If the coin slot is offline it logs and skips — never fatal.

---

## The steady-state loop after bootstrap

1. Edit code. If you changed `hotspot/nodemcucodeholder`, bump `FW_VERSION`.
2. `git commit`, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. Actions builds the bin, packs the tarball, writes+commits `manifest.txt`,
   publishes the release.
4. The ONT's cron (`ota.sh cron`, every ~6h) notifies or auto-applies. On apply
   it swaps the portal files, then `sync_nodemcu` flashes the coin slot **only
   if `FW_VERSION` changed**.

That's it — a portal-only release (no `FW_VERSION` bump) never touches the coin
slot; a firmware change rides along automatically.
