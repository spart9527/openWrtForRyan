#!/bin/bash
# 读取编译选项（build.conf 默认值 + Actions 手动触发时填写的值），
# 校验后写进固件的 /etc/ryan-build.conf，并按选项调整 .config。
# 用法：在 openwrt/ 目录里执行 build-options.sh <仓库根目录>
set -euo pipefail
ROOT="$1"

# 先记下 Actions 传进来的值，再读默认值，最后用非空的输入覆盖
in_LAN_IP="${IN_LAN_IP:-}";       in_HOSTNAME="${IN_HOSTNAME:-}"
in_WEB_SERVER="${IN_WEB_SERVER:-}"; in_WAN_PORT="${IN_WAN_PORT:-}"
in_LAN_PORTS="${IN_LAN_PORTS:-}";   in_WAN_PROTO="${IN_WAN_PROTO:-}"
in_EXTRA_PACKAGES="${IN_EXTRA_PACKAGES:-}"
# shellcheck disable=SC1091
. "$ROOT/build.conf"
for k in LAN_IP HOSTNAME WEB_SERVER WAN_PORT LAN_PORTS WAN_PROTO EXTRA_PACKAGES; do
  v="in_$k"
  [ -n "${!v}" ] && printf -v "$k" '%s' "${!v}"
done

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---- 校验：选错了就不出固件 ----
[[ "$LAN_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || fail "LAN_IP 不是 IPv4: $LAN_IP"
for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || fail "LAN_IP 段超出 255: $LAN_IP"; done
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || fail "HOSTNAME 不合法: $HOSTNAME"
case "$WEB_SERVER" in uhttpd|nginx) ;; *) fail "WEB_SERVER 只能是 uhttpd 或 nginx: $WEB_SERVER" ;; esac
case "$WAN_PROTO" in keep|pppoe|dhcp) ;; *) fail "WAN_PROTO 只能是 keep/pppoe/dhcp: $WAN_PROTO" ;; esac
if [ "$WAN_PORT" != auto ]; then
  [[ "$WAN_PORT" =~ ^eth[0-9]+$ ]] || fail "WAN_PORT 应为 ethN 或 auto: $WAN_PORT"
  if [ "$LAN_PORTS" != auto ]; then
    [ -n "$LAN_PORTS" ] || fail "LAN_PORTS 不能为空"
    for p in $LAN_PORTS; do
      [[ "$p" =~ ^eth[0-9]+$ ]] || fail "LAN_PORTS 里有非法口名: $p"
      [ "$p" != "$WAN_PORT" ] || fail "$p 同时出现在 WAN 和 LAN"
    done
  fi
fi
for p in $EXTRA_PACKAGES; do
  [[ "$p" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "EXTRA_PACKAGES 里有非法包名: $p"
done

# ---- 写入固件，供开机脚本 99-ryan-home 读取 ----
mkdir -p files/etc
cat > files/etc/ryan-build.conf <<CONF
LAN_IP='$LAN_IP'
HOSTNAME='$HOSTNAME'
WEB_SERVER='$WEB_SERVER'
WAN_PORT='$WAN_PORT'
LAN_PORTS='$LAN_PORTS'
WAN_PROTO='$WAN_PROTO'
CONF

# Kwrt 默认 LAN 是 10.0.0.1，改成选定的地址（fresh flash 时的兜底）
sed -i "s/10\.0\.0\.1/$LAN_IP/g; s/192\.168\.1\.1/$LAN_IP/g" package/base-files/files/bin/config_generate || true

# ---- Web 服务器：Kwrt common .config 写死了 luci-nginx=y，这里显式覆盖 ----
{
  echo
  echo "# --- build-options.sh ---"
  if [ "$WEB_SERVER" = uhttpd ]; then
    echo "CONFIG_PACKAGE_luci=y"
    echo "CONFIG_PACKAGE_uhttpd=y"
    echo "CONFIG_PACKAGE_uhttpd-mod-ubus=y"
    echo "# CONFIG_PACKAGE_luci-nginx is not set"
  else
    echo "CONFIG_PACKAGE_luci-nginx=y"
    echo "# CONFIG_PACKAGE_luci is not set"
  fi
  for p in $EXTRA_PACKAGES; do echo "CONFIG_PACKAGE_${p}=y"; done
} > build-options.config

echo "==> build options:"
cat files/etc/ryan-build.conf
echo "EXTRA_PACKAGES='$EXTRA_PACKAGES'"
