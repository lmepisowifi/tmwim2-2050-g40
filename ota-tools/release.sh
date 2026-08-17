#!/usr/bin/env bash
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

# release.sh — cut an OTA release for lmepisowifi from this repo.
#
# What it does:
#   1. (optional) builds the NodeMCU firmware and drops it at
#      hotspot/firmware/coin_nodemcu.bin
#   2. tars the OTA components into dist/lmepisowifi-<VER>.tar.gz
#   3. computes the bundle sha256 and the firmware md5
#   4. writes manifest.txt at the repo root
#   5. commits manifest.txt (+ the bin) to the default branch and pushes
#   6. creates a GitHub Release <vVER> with the tarball as an asset
#
# The device's ota.sh then reads manifest.txt over raw.githubusercontent and
# downloads the tarball from the Release. Requires: git, tar, sha256sum,
# md5sum, and the GitHub CLI `gh` (authenticated). arduino-cli is optional.
#
# Usage:  ./release.sh 1.0.0  "Initial release"
set -euo pipefail

VER="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Release $VER}"

# ---- repo identity ---------------------------------------------------------
# OWNER/REPO — taken from the git remote so the manifest URL is correct.
ORIGIN=$(git config --get remote.origin.url)
REPO=$(printf '%s' "$ORIGIN" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ -n "$REPO" ] || { echo "cannot determine OWNER/REPO from git remote"; exit 1; }
echo ">> repo=$REPO branch=$BRANCH version=$VER"

# ---- 1. build the NodeMCU firmware (skip if arduino-cli absent) ------------
if command -v arduino-cli >/dev/null 2>&1; then
    echo ">> building coin_nodemcu.bin"
    mkdir -p build coin_nodemcu hotspot/firmware
    cp hotspot/nodemcucodeholder coin_nodemcu/coin_nodemcu.ino
    FQBN="esp8266:esp8266:nodemcuv2:eesz=4M2M,xtal=80"   # reserves the OTA slot
    arduino-cli compile --fqbn "$FQBN" --output-dir build coin_nodemcu
    cp build/coin_nodemcu.ino.bin hotspot/firmware/coin_nodemcu.bin
else
    echo ">> arduino-cli not found — reusing existing hotspot/firmware/coin_nodemcu.bin"
    [ -f hotspot/firmware/coin_nodemcu.bin ] || \
        { echo "no firmware bin present and cannot build one"; exit 1; }
fi

# FW_VERSION is the source of truth for the coin-slot gate.
FW=$(sed -n 's/.*#define[[:space:]]\+FW_VERSION[[:space:]]\+"\([^"]*\)".*/\1/p' \
        hotspot/nodemcucodeholder)
[ -n "$FW" ] || { echo "could not read FW_VERSION from sketch"; exit 1; }

# ---- 2. build the component tarball ---------------------------------------
# Only the swap components go in the bundle; runtime state never does.
COMPONENTS="hotspot www2 lmehspt.sh ota.sh defaults.env"
mkdir -p dist
TARBALL="dist/lmepisowifi-$VER.tar.gz"
echo ">> packing $TARBALL"
tar -czf "$TARBALL" $COMPONENTS

# ---- 3. checksums ----------------------------------------------------------
SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
MD5=$(md5sum hotspot/firmware/coin_nodemcu.bin | awk '{print $1}')
URL="https://github.com/$REPO/releases/download/v$VER/lmepisowifi-$VER.tar.gz"

# ---- 4. write the manifest -------------------------------------------------
cat > manifest.txt <<EOF
version=$VER
url=$URL
sha256=$SHA
notes=$NOTES
nodemcu_version=$FW
nodemcu_md5=$MD5
EOF
echo ">> manifest.txt:"; sed 's/^/     /' manifest.txt

# ---- 5. commit manifest + firmware, push -----------------------------------
git add manifest.txt hotspot/firmware/coin_nodemcu.bin
git commit -m "release $VER (nodemcu fw $FW)" || echo ">> nothing to commit"
git push origin "$BRANCH"

# ---- 6. create the GitHub Release with the tarball asset -------------------
echo ">> creating GitHub release v$VER"
gh release create "v$VER" "$TARBALL" --title "v$VER" --notes "$NOTES"

echo ">> done. Point OTA_MANIFEST_URL at:"
echo "   https://raw.githubusercontent.com/$REPO/$BRANCH/manifest.txt"
