#!/usr/bin/env bash
# Clone OpenWrt, merge the device-support PR, apply patches, set up feeds and .config.
# Run from anywhere; works relative to the repo root.
# Env: OPENWRT_REPO, OPENWRT_BRANCH, PR_NUMBER, TARGET, SUBTARGET, EXPECTED_DEVICES
# Optional pins (unset = float, today's behaviour):
#   OPENWRT_SHA          (full SHA) check out this OpenWrt commit after cloning OPENWRT_BRANCH
#   PR_SHA               (full SHA) merge exactly this commit of PR_NUMBER (fetched directly if the PR moved on)
#   IWINFO_PATCH_SHA256  space-separated "<pr>=<sha256>"; fail if a downloaded iwinfo patch differs
#   FEEDS_CONF           feeds.conf to use instead of feeds.conf.default + feeds.conf.default.d,
#                        e.g. a release's feeds.buildinfo (every feed pinned with ^<commit>)
# Writes build-info.env and inputs.json (the record of every input) to the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-main}"
PR_NUMBER="${PR_NUMBER:-}"
IWINFO_PRS="${IWINFO_PRS:-}"
OPENWRT_SHA="${OPENWRT_SHA:-}"
PIN_PR_SHA="${PR_SHA:-}"
IWINFO_PATCH_SHA256="${IWINFO_PATCH_SHA256:-}"
FEEDS_CONF="${FEEDS_CONF:-}"
abs_file() { # absolute path of an existing file, since the script later cd's into openwrt/
  [ -f "$2" ] || { echo "::error::$1 file not found: $2" >&2; exit 1; }
  echo "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
}
if [ -n "$FEEDS_CONF" ]; then FEEDS_CONF="$(abs_file FEEDS_CONF "$FEEDS_CONF")"; fi
TARGET="${TARGET:-qualcommbe}"
SUBTARGET="${SUBTARGET:-ipq95xx}"

git config --global user.name "ci"
git config --global user.email "ci@localhost"
shopt -s nullglob

echo "::group::Clone OpenWrt"
rm -rf openwrt
git clone --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" openwrt
cd openwrt
if [ -n "$OPENWRT_SHA" ]; then
  echo "Pinning OpenWrt to $OPENWRT_SHA"
  git cat-file -e "$OPENWRT_SHA^{commit}" 2>/dev/null || git fetch origin "$OPENWRT_SHA"
  git -c advice.detachedHead=false checkout --detach "$OPENWRT_SHA"
fi
UPSTREAM_SHA="$(git rev-parse HEAD)"
PR_SHA=""
if [ -n "$PR_NUMBER" ]; then
  git fetch origin "pull/$PR_NUMBER/head"
  PR_SHA="$(git rev-parse FETCH_HEAD)"
  MERGE_REF=FETCH_HEAD
  if [ -n "$PIN_PR_SHA" ] && [ "$PR_SHA" != "$(git rev-parse --verify -q "$PIN_PR_SHA^{commit}" || echo none)" ]; then
    echo "::warning::PR #$PR_NUMBER head is $PR_SHA, pinned $PIN_PR_SHA; fetching the pinned commit"
    git fetch origin "$PIN_PR_SHA" || { echo "::error::pinned PR commit $PIN_PR_SHA not fetchable"; exit 1; }
    PR_SHA="$(git rev-parse --verify "$PIN_PR_SHA^{commit}")"
    MERGE_REF="$PR_SHA"
  fi
  git merge --no-edit "$MERGE_REF"
elif [ -n "$PIN_PR_SHA" ]; then
  echo "::error::PR_SHA is set but PR_NUMBER is empty"
  exit 1
fi
cat > "$ROOT/build-info.env" <<EOF
UPSTREAM_SHA=$UPSTREAM_SHA
PR_NUMBER=$PR_NUMBER
PR_SHA=$PR_SHA
IWINFO_PRS="$IWINFO_PRS"
EOF
echo "::endgroup::"

echo "::group::Apply patches/openwrt"
for p in "$ROOT"/patches/openwrt/*.patch; do
  echo "Applying $p"
  git am --3way "$p"
done
echo "::endgroup::"

echo "::group::Copy custom BDFs"
# BDF files live in bdf/ in this repo; the ipq-wifi package expects them in src/
if [ -d "$ROOT/bdf" ]; then
  mkdir -p package/firmware/ipq-wifi/src
  cp -v "$ROOT"/bdf/* package/firmware/ipq-wifi/src/
fi
echo "::endgroup::"

echo "::group::Copy raw files into the tree"
# tree/ mirrors the OpenWrt root: tree/target/linux/... is copied to target/linux/...
# Use it for plain kernel patch files, which are applied by the kernel build with patch(1).
if [ -d "$ROOT/tree" ]; then
  cp -av "$ROOT/tree/." .
fi
echo "::endgroup::"

echo "::group::Copy ath11k patches"
# patches/ath11k/*.patch go into the mac80211 package's ath11k patch dir
mkdir -p package/kernel/mac80211/patches/ath11k
for p in "$ROOT"/patches/ath11k/*.patch; do
  cp -v "$p" package/kernel/mac80211/patches/ath11k/
done
echo "::endgroup::"

echo "::group::Apply open iwinfo PRs"
# Downloaded as patches and dropped into the iwinfo package's patches/ dir
for n in $IWINFO_PRS; do
  mkdir -p package/network/utils/iwinfo/patches
  echo "Fetching iwinfo PR #$n"
  curl -fsSL --retry 3 "https://github.com/openwrt/iwinfo/pull/$n.patch" \
    -o "package/network/utils/iwinfo/patches/900-iwinfo-pr-$n.patch"
  got="$(sha256sum "package/network/utils/iwinfo/patches/900-iwinfo-pr-$n.patch" | cut -d' ' -f1)"
  echo "iwinfo PR #$n patch sha256 $got"
  for pin in $IWINFO_PATCH_SHA256; do
    if [ "${pin%%=*}" = "$n" ] && [ "${pin#*=}" != "$got" ]; then
      echo "::error::iwinfo PR #$n patch sha256 $got, pinned ${pin#*=}"
      exit 1
    fi
  done
done
echo "::endgroup::"

# Persistent dirs restored/saved by actions/cache
mkdir -p "$ROOT/cache/dl" "$ROOT/cache/ccache"
ln -sfn "$ROOT/cache/dl" dl
ln -sfn "$ROOT/cache/ccache" .ccache
echo "max_size = 3.0G" > "$ROOT/cache/ccache/ccache.conf"

echo "::group::Feeds"
if [ -n "$FEEDS_CONF" ]; then
  echo "Using $FEEDS_CONF as feeds.conf"
  cp "$FEEDS_CONF" feeds.conf
else
  cp feeds.conf.default feeds.conf
  for f in "$ROOT"/feeds.conf.default.d/*; do
    [ -f "$f" ] || continue
    echo "" >> feeds.conf
    cat "$f" >> feeds.conf
  done
fi
./scripts/feeds update -a

# Patches for packages in the main packages feed (feeds/packages is a git clone)
for p in "$ROOT"/patches/packages/*.patch; do
  echo "Applying $p to feeds/packages"
  git -C feeds/packages am --3way "$p"
done

./scripts/feeds install -a
echo "::endgroup::"

if [ -d "$ROOT/files" ]; then
  cp -r "$ROOT/files" files
fi

echo "::group::Config"
if [ ! -f "$ROOT/config/base.diffconfig" ]; then
  echo "::error::config/base.diffconfig not found - commit it to the repo (see README)"
  exit 1
fi
: > .config
cat "$ROOT/config/base.diffconfig" >> .config

# extra-packages.txt: one package per line, "#" comments allowed.
# A leading "-" removes a package (e.g. "-ppp").
if [ -f "$ROOT/config/extra-packages.txt" ]; then
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      p = $1
      if (substr(p, 1, 1) == "-") print "# CONFIG_PACKAGE_" substr(p, 2) " is not set"
      else                        print "CONFIG_PACKAGE_" p "=y"
    }
  ' "$ROOT/config/extra-packages.txt" >> .config
fi

cat >> .config <<'EOF'
CONFIG_CCACHE=y
CONFIG_VERSION_DIST="OpenWrt (unofficial)"
EOF

make defconfig

if [ -n "${EXPECTED_DEVICES:-}" ]; then
  n=$(grep -cE "^CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_.*=y" .config || true)
  if [ "$n" -ne "$EXPECTED_DEVICES" ]; then
    echo "::error::Expected $EXPECTED_DEVICES device profiles enabled, found $n"
    exit 1
  fi
fi
echo "::endgroup::"

echo "::group::Record inputs"
# inputs.json: everything needed to rebuild this tree. Read-only; changes nothing in the build.
{
  printf 'openwrt_repo\t%s\n' "$OPENWRT_REPO"
  printf 'openwrt_branch\t%s\n' "$OPENWRT_BRANCH"
  printf 'openwrt_sha\t%s\n' "$UPSTREAM_SHA"
  printf 'openwrt_pinned\t%s\n' "${OPENWRT_SHA:+yes}"
  printf 'pr_number\t%s\n' "$PR_NUMBER"
  printf 'pr_sha\t%s\n' "$PR_SHA"
  printf 'pr_pinned\t%s\n' "${PIN_PR_SHA:+yes}"
  printf 'tree_sha\t%s\n' "$(git rev-parse HEAD)"
  printf 'build_repo_sha\t%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  for n in $IWINFO_PRS; do
    printf 'iwinfo\t%s\t%s\n' "$n" \
      "$(sha256sum "package/network/utils/iwinfo/patches/900-iwinfo-pr-$n.patch" | cut -d' ' -f1)"
  done
  printf 'feeds_conf\t%s\n' "${FEEDS_CONF:+custom}"
  for f in "$ROOT"/bdf/*; do
    if [ -f "$f" ]; then printf 'bdf\t%s\t%s\n' "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"; fi
  done
  # ipq-wifi package source pin (board data not carried in bdf/, e.g. the QCN9074 file)
  printf 'ipq_wifi\t%s\t%s\n' \
    "$(sed -n 's/^PKG_SOURCE_VERSION:=//p' package/firmware/ipq-wifi/Makefile 2>/dev/null | head -n1)" \
    "$(sed -n 's/^PKG_MIRROR_HASH:=//p' package/firmware/ipq-wifi/Makefile 2>/dev/null | head -n1)"
  for f in "$ROOT"/patches/*/*.patch; do
    printf 'patch\t%s\t%s\n' "${f#"$ROOT"/}" "$(sha256sum "$f" | cut -d' ' -f1)"
  done
  if [ -d "$ROOT/tree" ]; then
    (cd "$ROOT" && find tree -type f | LC_ALL=C sort) | while read -r f; do
      printf 'patch\t%s\t%s\n' "$f" "$(sha256sum "$ROOT/$f" | cut -d' ' -f1)"
    done
  fi
  for f in config/base.diffconfig config/extra-packages.txt; do
    if [ -f "$ROOT/$f" ]; then printf 'config\t%s\t%s\n' "$f" "$(sha256sum "$ROOT/$f" | cut -d' ' -f1)"; fi
  done
} | python3 -I -c '
import json, sys
d = {"schema": 1, "iwinfo_prs": [], "board_data": [], "patches": [], "config": []}
for line in sys.stdin.read().splitlines():
    f = line.split("\t")
    k = f[0]
    if k == "iwinfo":   d["iwinfo_prs"].append({"pr": f[1], "patch_sha256": f[2]})
    elif k == "bdf":    d["board_data"].append({"file": "bdf/" + f[1], "sha256": f[2]})
    elif k == "ipq_wifi": d["ipq_wifi_package"] = {"source_version": f[1] or None, "mirror_hash": f[2] or None}
    elif k == "patch":  d["patches"].append({"file": f[1], "sha256": f[2]})
    elif k == "config": d["config"].append({"file": f[1], "sha256": f[2]})
    elif k.endswith("_pinned"): d[k] = f[1] == "yes"
    else:               d[k] = f[1] if len(f) > 1 and f[1] else None
json.dump(d, sys.stdout, indent=1, sort_keys=True)
print()
' > "$ROOT/inputs.json"
cat "$ROOT/inputs.json"
echo "::endgroup::"
