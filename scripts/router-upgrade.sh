#!/bin/sh
# 可拷到现机使用。新固件里请用 firmware-upgrade（内容相同）。
set -e

REPO="${REPO:-spart9527/openWrtForRyan}"
PROXY="${GITHUB_PROXY:-https://ghfast.top/}"
KEEP_CONFIG="${KEEP_CONFIG:-1}"
LIST="${PRIVATE_PACKAGES:-/root/private-packages.txt}"

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

if [ ! -f "$LIST" ]; then
	echo "警告: 没有 $LIST ，重启后不会自动安装私有插件"
fi

echo "备份配置到 /root/backup-latest.tar.gz"
sysupgrade -b /root/backup-latest.tar.gz

DL="${PROXY}${URL}"
TMP="/tmp/firmware.img.gz"
echo "下载 $DL"
wget -O "$TMP" "$DL"
gzip -t "$TMP"

echo "开始刷机，设备会重启。私有插件在开机联网后自动安装。"
if [ "$KEEP_CONFIG" = "1" ]; then
	sysupgrade -v "$TMP"
else
	sysupgrade -n -v "$TMP"
fi
