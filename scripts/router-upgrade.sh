#!/bin/sh
# 在路由上运行：从 GitHub Releases 拉最新 ext4-efi 镜像并 sysupgrade。
# 用法：
#   REPO=spart9527/openWrtForRyan ./router-upgrade.sh
#   REPO=spart9527/openWrtForRyan ./router-upgrade.sh --check

set -e

REPO="${REPO:-spart9527/openWrtForRyan}"
PROXY="${GITHUB_PROXY:-https://ghfast.top/}"
KEEP_CONFIG="${KEEP_CONFIG:-1}"

if [ -z "$REPO" ]; then
  echo "请设置 REPO=owner/repo ，例如 REPO=ryan/openWrt"
  exit 1
fi

API="https://api.github.com/repos/${REPO}/releases/latest"
echo "检查 $API"
JSON="$(wget -qO- "$API")" || {
  echo "无法访问 GitHub API，可设置 HTTPS 代理后再试"
  exit 1
}

TAG="$(echo "$JSON" | jsonfilter -e '@.tag_name')"
URL="$(echo "$JSON" | jsonfilter -e '@.assets[*].browser_download_url' | grep -E 'ext4-combined-efi\.img\.gz$' | head -n1)"

if [ -z "$URL" ]; then
  echo "最新 Release $TAG 里没有 ext4-combined-efi.img.gz"
  exit 1
fi

echo "最新版本: $TAG"
echo "镜像: $URL"

if [ "${1:-}" = "--check" ]; then
  exit 0
fi

DL="${PROXY}${URL}"
TMP="/tmp/firmware.img.gz"
echo "下载 $DL"
wget -O "$TMP" "$DL"

echo "校验 gzip"
gzip -t "$TMP"

if [ "$KEEP_CONFIG" = "1" ]; then
  sysupgrade -v "$TMP"
else
  sysupgrade -n -v "$TMP"
fi
