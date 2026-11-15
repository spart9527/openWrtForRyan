#!/bin/sh
# 可拷到现机使用。新固件里请用 firmware-upgrade（内容相同）。
# 一键升级：备份 → 下载最新公开固件 → 保留配置刷入。
# 重启后 private-packages 服务会自动安装 /root/private-packages.txt。
# 用法：
#   firmware-upgrade --check
#   firmware-upgrade

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

SUMS_URL="$(echo "$JSON" | jsonfilter -e '@.assets[*].browser_download_url' | grep -E '/sha256sums$' | head -n1)"
OPTS_URL="$(echo "$JSON" | jsonfilter -e '@.assets[*].browser_download_url' | grep -E '/ryan-build\.conf$' | head -n1)"

echo "最新版本: $TAG"
echo "镜像: $URL"

# 核对这个固件的编译选项，和现机不一致就停下，避免再刷出 LAN 断网/后台 403
OPTS="/tmp/ryan-build.conf.new"
if [ -n "$OPTS_URL" ] && wget -qO "$OPTS" "${PROXY}${OPTS_URL}"; then
	echo "---- 新固件编译选项 ----"
	cat "$OPTS"
	echo "------------------------"
	( . "$OPTS"
	  bad=0
	  cur_ip="$(uci -q get network.lan.ipaddr)"
	  [ "$LAN_IP" = "$cur_ip" ] || { echo "注意: 新固件 LAN_IP=$LAN_IP，现机是 $cur_ip"; bad=1; }
	  [ "$WAN_PORT" != auto ] || { echo "注意: WAN_PORT=auto，网口交给 Kwrt 分配（>2 网卡时 eth1 当 WAN）"; bad=1; }
	  if [ "$WAN_PORT" != auto ] && [ ! -e "/sys/class/net/$WAN_PORT" ]; then
	    echo "注意: 本机没有 $WAN_PORT"; bad=1
	  fi
	  exit $bad ) || {
		if [ "${FORCE:-0}" != "1" ]; then
			echo "编译选项和现机不一致，确认没问题再用 FORCE=1 firmware-upgrade"
			exit 1
		fi
	}
else
	echo "警告: Release 里没有 ryan-build.conf（旧版本固件），无法核对编译选项"
	[ "${FORCE:-0}" = "1" ] || { echo "用 FORCE=1 firmware-upgrade 强制继续"; exit 1; }
fi

if [ "${1:-}" = "--check" ]; then
	exit 0
fi

if [ ! -f "$LIST" ]; then
	echo "警告: 没有 $LIST ，重启后不会自动安装私有插件（PassWall 等会消失）"
	if [ "${FORCE:-0}" != "1" ]; then
		echo "先补好清单，或用 FORCE=1 firmware-upgrade 强制继续"
		exit 1
	fi
fi

if ! sysupgrade -l | grep -qx "$LIST"; then
	echo "警告: $LIST 不在 sysupgrade 保留列表里，检查 /etc/sysupgrade.conf"
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

echo "开始刷机，设备会重启。私有插件在开机联网后自动安装。"
if [ "$KEEP_CONFIG" = "1" ]; then
	sysupgrade -v "$TMP"
else
	sysupgrade -n -v "$TMP"
fi
