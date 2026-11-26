#!/usr/bin/env bash
# Print release notes (markdown) to stdout.
# Usage: HASH=<build hash> SKUS="6111 ..." [INPUTS=inputs.json] scripts/gen-release-notes.sh <out-dir>
# Needs build-info.env (and optionally inputs.json) from scripts/prepare.sh, and the openwrt/ tree
# for the known-issues check. The "Build-Hash:" line must stay last; the CI check job parses it.
set -euo pipefail

OUT="${1:?usage: $0 <out-dir>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HASH:?HASH is not set}"
: "${SKUS:?SKUS is not set}"

# shellcheck disable=SC1091
source "$ROOT/build-info.env"

declare -A UART=(
  [6111]="3.3 V" [6411]="3.3 V" [6611]="3.3 V"
  [6711]="1.8 V" [6811]="1.8 V" [6911]="1.8 V"
)

upstream_date="$(git -C "$ROOT/openwrt" log -1 --format=%cs "$UPSTREAM_SHA" 2>/dev/null || echo unknown)"

cat <<EOF
Unofficial OpenWrt snapshot builds for the Jio Router AX6000 (JIDU6J11). Not affiliated with Jio or the OpenWrt project.

> **Check your SKU before flashing.** Images are SKU-specific (wifi calibration and UART voltage differ). Flashing the wrong one can break wifi.

| SKU | UART | Sysupgrade image | Size |
|-----|------|------------------|------|
EOF

for sku in $SKUS; do
  # Image names use the jidu<sku> form, e.g.
  # openwrt-qualcommbe-ipq95xx-jiorouter_ax6000-jidu6111-squashfs-sysupgrade.bin
  f="$(find "$OUT" -maxdepth 1 -name "*-jidu${sku}-*sysupgrade*" | head -n1)"
  if [ -n "$f" ]; then
    size="$(du -h "$f" | cut -f1)"
    echo "| $sku | ${UART[$sku]:-?} | \`$(basename "$f")\` | $size |"
  else
    echo "| $sku | ${UART[$sku]:-?} | _missing_ | - |"
  fi
done

cat <<EOF

**Base:** openwrt/openwrt \`${UPSTREAM_SHA:0:12}\` ($upstream_date)
EOF

if [ -n "$PR_NUMBER" ]; then
  echo "**Device support PR:** #$PR_NUMBER at \`${PR_SHA:0:12}\`"
fi

if [ -n "${IWINFO_PRS:-}" ]; then
  echo "**iwinfo PRs applied:** $(for n in $IWINFO_PRS; do printf '#%s ' "$n"; done)"
fi

# ---- Inputs (INF-3): rendered from inputs.json written by prepare.sh -------------------------
INPUTS="${INPUTS:-$ROOT/inputs.json}"
if [ -f "$INPUTS" ]; then
  echo ""
  echo "### Inputs"
  echo ""
  echo "Everything this build was made from. \`inputs.json\` (release asset) is the machine-readable record;"
  echo "to rebuild, pass its SHAs to \`scripts/prepare.sh\` as \`OPENWRT_SHA\` and \`PR_SHA\`, and the release's"
  echo "\`feeds.buildinfo\` as \`FEEDS_CONF\`."
  echo ""
  # shellcheck disable=SC2016  # Python source, not shell
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
pin = lambda k: " (pinned)" if d.get(k) else ""
print("| Input | Revision / sha256 |")
print("|---|---|")
print("| OpenWrt `%s` | `%s`%s |" % (d.get("openwrt_branch"), d.get("openwrt_sha"), pin("openwrt_pinned")))
if d.get("pr_number"):
    print("| openwrt#%s head | `%s`%s |" % (d["pr_number"], d.get("pr_sha"), pin("pr_pinned")))
for i in d.get("iwinfo_prs", []):
    print("| iwinfo#%s patch | `%s` |" % (i["pr"], i["patch_sha256"]))
print("| feeds | see `feeds.buildinfo`%s |" % (" (custom FEEDS_CONF)" if d.get("feeds_conf") else ""))
w = d.get("ipq_wifi_package") or {}
if w.get("source_version"):
    print("| ipq-wifi package source | `%s` |" % w["source_version"])
for b in d.get("board_data", []):
    print("| `%s` | `%s` |" % (b["file"], b["sha256"]))
for c in d.get("config", []):
    print("| `%s` | `%s` |" % (c["file"], c["sha256"]))
if d.get("build_repo_sha"):
    print("| build repo commit | `%s` |" % d["build_repo_sha"])
' "$INPUTS"
fi

# ---- Known issues (UX-2) -------------------------------------------------------------------
# FEAT-14: openwrt 07d8afca2a (openwrt#26847) disables q6_region in ipq9574.dtsi; the JIDU dtsi
# must re-enable it or the integrated 2.4 GHz radio never starts.
known=""
ow="$ROOT/openwrt"
dtsi="$ow/target/linux/qualcommbe/dts/ipq9554-jiorouter-ax6000-jidu6j11.dtsi"
if [ -d "$ow/.git" ] && feat14="$(git -C "$ow" rev-parse --verify -q '07d8afca2a^{commit}')" \
   && git -C "$ow" merge-base --is-ancestor "$feat14" "$UPSTREAM_SHA"; then
  if [ -f "$dtsi" ] && grep -A1 -E '^&q6_region[[:space:]]*\{' "$dtsi" | grep -q 'status = "okay"'; then
    known="$known
- **FEAT-14 (2.4 GHz radio, q6_region):** this base contains openwrt \`07d8afca2a\` (openwrt#26847), which disables the WCSS reserved memory. The JIDU dtsi in this build enables \`&q6_region\`, so the 2.4 GHz radio should start. Report it if \`phy0\` is missing."
  else
    known="$known
- **FEAT-14 (2.4 GHz radio, q6_region): BROKEN in this build.** This base contains openwrt \`07d8afca2a\` (openwrt#26847) but the JIDU dtsi does not enable \`&q6_region\`, so the integrated 2.4 GHz radio fails (\`unable to acquire memory-region\`, \`ath11k: failed to get rproc\`). Use a build of openwrt#26498 at \`727ed7916a1d\` or later, which enables it."
  fi
fi
echo ""
echo "### Known issues"
if [ -n "$known" ]; then
  echo "$known"
else
  echo ""
  echo "- None recorded for this build."
fi

cat <<EOF

Verify downloads with \`sha256sums\`.

Build-Hash: $HASH
EOF
