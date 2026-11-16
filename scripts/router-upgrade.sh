#!/bin/sh
# 可拷到现机使用。新固件里请用 firmware-upgrade（内容相同）。
# 一键升级：备份 → 下载最新公开固件 → 保留配置刷入。
# 用法：
#   firmware-upgrade --check
#   firmware-upgrade

set -e

REPO="${REPO:-spart9527/openWrtForRyan}"
PROXY="${GITHUB_PROXY:-https://ghfast.top/}"
KEEP_CONFIG="${KEEP_CONFIG:-1}"

API="https://api.github.com/repos/${REPO}/releases/latest"
echo "检查 $API"
JSON="$(wget -qO- "$API")" || {
	echo "无法访问 GitHub API，可设置 HTTPS 代理后再试"
	exit 1
}

TAG="$(echo "$JSON" | jsonfilter -e '@.tag_name')"
SUMS_URL="$(echo "$JSON" | jsonfilter -e '@.assets[*].browser_download_url' | grep -E '/sha256sums$' | head -n1)"
OPTS_URL="$(echo "$JSON" | jsonfilter -e '@.assets[*].browser_download_url' | grep -E '/ryan-build\.conf$' | head -n1)"

# 先读编译选项，再按 FILESYSTEM 选镜像（ext4 或 squashfs）
OPTS="/tmp/ryan-build.conf.new"
FILESYSTEM=ext4
INTERNET=
if [ -n "$OPTS_URL" ] && wget -qO "$OPTS" "${PROXY}${OPTS_URL}"; then
	echo "---- 新固件编译选项 ----"
	cat "$OPTS"
	echo "------------------------"
	# shellcheck disable=SC1090
	. "$OPTS"
	bad=0
	cur_ip="$(uci -q get network.lan.ipaddr)"
	[ "$LAN_IP" = "$cur_ip" ] || { echo "注意: 新固件 LAN_IP=$LAN_IP，现机是 $cur_ip"; bad=1; }
	[ "$WAN_PORT" != auto ] || { echo "注意: WAN_PORT=auto，网口交给 Kwrt 分配（>2 网卡时 eth1 当 WAN）"; bad=1; }
	if [ "$WAN_PORT" != auto ] && [ ! -e "/sys/class/net/$WAN_PORT" ]; then
		echo "注意: 本机没有 $WAN_PORT"; bad=1
	fi
	cur_fs=ext4
	if grep -q ' / overlay ' /proc/mounts 2>/dev/null || [ -d /rom/ ]; then
		cur_fs=squashfs
	fi
	[ -z "${FILESYSTEM:-}" ] && FILESYSTEM=ext4
	[ "$FILESYSTEM" = "$cur_fs" ] || {
		echo "注意: 新固件文件系统是 $FILESYSTEM，现机是 $cur_fs，换格式会整盘重写分区"
		bad=1
	}
	if [ "${IPV6:-on}" = off ] && uci -q get network.wan6 >/dev/null; then
		echo "注意: 新固件关闭了 IPv6，刷机后会清除 wan6、LAN IPv6 和 DHCPv6 配置"
	fi
	if [ "$bad" != 0 ] && [ "${FORCE:-0}" != "1" ]; then
		echo "编译选项和现机不一致，确认没问题再用 FORCE=1 firmware-upgrade"
		exit 1
	fi
else
	echo "警告: Release 里没有 ryan-build.conf（旧版本固件），无法核对编译选项"
	[ "${FORCE:-0}" = "1" ] || { echo "用 FORCE=1 firmware-upgrade 强制继续"; exit 1; }
fi

if [ "$FILESYSTEM" = squashfs ]; then
	imgpat='squashfs-combined-efi.img.gz'
else
	imgpat='ext4-combined-efi.img.gz'
fi
URL="$(echo "$JSON" | jsonfilter -e '@.assets[*].browser_download_url' | grep -E "${imgpat}$" | head -n1)"
if [ -z "$URL" ]; then
	echo "最新 Release $TAG 里没有 $imgpat"
	exit 1
fi

echo "最新版本: $TAG"
echo "镜像: $URL"

if [ "${1:-}" = "--check" ]; then
	exit 0
fi

SNAP="/root/pre-upgrade-$(date +%Y%m%d-%H%M%S).uci"
echo "保存网络相关配置快照到 $SNAP"
for c in network dhcp firewall dropbear; do
	echo "### $c"
	uci export "$c"
done >"$SNAP" 2>/dev/null

echo "备份配置到 /root/backup-latest.tar.gz"
sysupgrade -b /root/backup-latest.tar.gz

DL="${PROXY}${URL}"
TMP="/tmp/firmware.img.gz"
echo "下载 $DL"
wget -O "$TMP" "$DL"
gzip -t "$TMP"

# 校验下载完整性（代理下载偶尔会截断或出错）
if [ -n "$SUMS_URL" ] && wget -qO /tmp/sha256sums "${PROXY}${SUMS_URL}"; then
	want="$(grep "$(basename "$URL")" /tmp/sha256sums | awk '{print $1}')"
	got="$(sha256sum "$TMP" | awk '{print $1}')"
	if [ -n "$want" ] && [ "$want" != "$got" ]; then
		echo "sha256 不一致，下载的镜像损坏，停止"
		exit 1
	fi
	[ -n "$want" ] && echo "sha256 校验通过"
fi

# 让 sysupgrade 先检查镜像格式，不通过就不刷
sysupgrade -T "$TMP"

echo "开始刷机，设备会重启。"
if [ "$KEEP_CONFIG" = "1" ]; then
	sysupgrade -v "$TMP"
else
	sysupgrade -n -v "$TMP"
fi
