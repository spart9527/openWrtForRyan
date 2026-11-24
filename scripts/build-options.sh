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
in_SIGNATURE="${IN_SIGNATURE:-}"
in_REMOVE_AUTHOR_LINKS="${IN_REMOVE_AUTHOR_LINKS:-}"
in_FILESYSTEM="${IN_FILESYSTEM:-}"; in_IPV6="${IN_IPV6:-}"
in_INTERNET="${IN_INTERNET:-}"
# shellcheck disable=SC1091
. "$ROOT/build.conf"
# SIGNATURE 允许留空，不能用“非空才覆盖”，否则手动触发时没法清掉默认签名
if [ -n "${GITHUB_EVENT_NAME:-}" ] && [ "${GITHUB_EVENT_NAME}" = workflow_dispatch ]; then
  SIGNATURE="${in_SIGNATURE}"
fi
for k in LAN_IP HOSTNAME WEB_SERVER WAN_PORT LAN_PORTS WAN_PROTO EXTRA_PACKAGES \
         REMOVE_AUTHOR_LINKS FILESYSTEM IPV6 INTERNET; do
  v="in_$k"
  [ -n "${!v}" ] && printf -v "$k" '%s' "${!v}"
done
# 非手动触发时，若 Actions 没传 SIGNATURE，就用 build.conf
if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ]; then
  [ -n "${in_SIGNATURE+x}" ] && [ -n "$in_SIGNATURE" ] && SIGNATURE="$in_SIGNATURE"
fi
SIGNATURE="${SIGNATURE:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---- 校验：选错了就不出固件 ----
[[ "$LAN_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || fail "LAN_IP 不是 IPv4: $LAN_IP"
for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || fail "LAN_IP 段超出 255: $LAN_IP"; done
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || fail "HOSTNAME 不合法: $HOSTNAME"
case "$WEB_SERVER" in uhttpd|nginx) ;; *) fail "WEB_SERVER 只能是 uhttpd 或 nginx: $WEB_SERVER" ;; esac
case "$WAN_PROTO" in keep|pppoe|dhcp) ;; *) fail "WAN_PROTO 只能是 keep/pppoe/dhcp: $WAN_PROTO" ;; esac
case "$FILESYSTEM" in ext4|squashfs) ;; *) fail "FILESYSTEM 只能是 ext4 或 squashfs: $FILESYSTEM" ;; esac
case "$IPV6" in off|on) ;; *) fail "IPV6 只能是 off 或 on: $IPV6" ;; esac
case "$REMOVE_AUTHOR_LINKS" in yes|no) ;; *) fail "REMOVE_AUTHOR_LINKS 只能是 yes 或 no: $REMOVE_AUTHOR_LINKS" ;; esac
case "$INTERNET" in passwall|passwall2|openclash|homeproxy|ssr-plus|none) ;; *)
  fail "INTERNET 只能是 passwall/passwall2/openclash/homeproxy/ssr-plus/none: $INTERNET"
esac
if [ -n "$SIGNATURE" ]; then
  [ "${#SIGNATURE}" -le 40 ] || fail "SIGNATURE 太长（最多 40 字符）"
  printf '%s' "$SIGNATURE" | grep -qE '[$`\\;|&<>"/'\'']' && fail "SIGNATURE 含有非法字符: $SIGNATURE"
  # 不能用 grep -q $'\n'：换行会被 grep 当成空模式，任何非空签名都会误报
  case "$SIGNATURE" in *$'\n'*|*$'\r'*) fail "SIGNATURE 不能换行" ;; esac
fi
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

# 互联网组件：选客户端后把对应包编进固件。不再编入 SmartDNS 及其 LuCI 页面。
# passwall 额外带上现机在用的依赖，刷完即可用。
internet_packages() {
  case "$INTERNET" in
    none) return 0 ;;
    passwall)
      printf '%s' "luci-app-passwall chinadns-ng haproxy sing-box shadowsocks-rust-sslocal shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir simple-obfs-client v2ray-plugin geoview dns2socks ipt2socks microsocks tcping"
      ;;
    passwall2) printf '%s' "luci-app-passwall2" ;;
    openclash) printf '%s' "luci-app-openclash" ;;
    homeproxy) printf '%s' "luci-app-homeproxy" ;;
    ssr-plus) printf '%s' "luci-app-ssr-plus" ;;
  esac
}

# ---- 写入固件，供开机脚本 99-ryan-home 读取 ----
# 不要把密码写进这个文件：Release 是公开的。
mkdir -p files/etc
cat > files/etc/ryan-build.conf <<CONF
LAN_IP='$LAN_IP'
HOSTNAME='$HOSTNAME'
WEB_SERVER='$WEB_SERVER'
WAN_PORT='$WAN_PORT'
LAN_PORTS='$LAN_PORTS'
WAN_PROTO='$WAN_PROTO'
FILESYSTEM='$FILESYSTEM'
IPV6='$IPV6'
INTERNET='$INTERNET'
SIGNATURE='$SIGNATURE'
REMOVE_AUTHOR_LINKS='$REMOVE_AUTHOR_LINKS'
CONF

# Kwrt 默认 LAN 是 10.0.0.1，改成选定的地址（fresh flash 时的兜底）
sed -i "s/10\.0\.0\.1/$LAN_IP/g; s/192\.168\.1\.1/$LAN_IP/g" package/base-files/files/bin/config_generate || true

# ---- 版本签名、作者外链（登录横幅 / os-release / LuCI 主页链接）----
# 注意：package/base-files/files/etc/os-release 是指向 ../usr/lib/os-release 的符号链接。
# 以前直接 sed -i 它，GNU sed 会把链接换成普通文件：真正进固件的 /usr/lib/os-release
# 没改到（LuCI“固件版本”读的就是它的 OPENWRT_RELEASE，所以还显示 by Kiddin'），
# 而 /etc/os-release 变成了没替换占位符的模板。现在一律 --follow-symlinks，并改实际文件。
osr=package/base-files/files/etc/os-release
if [ -e package/base-files/files/usr/lib/os-release ] && [ ! -L "$osr" ]; then
  ln -sfn ../usr/lib/os-release "$osr"
fi
apply_text() {
  local f="$1"
  [ -f "$f" ] || return 0
  if [ -n "$SIGNATURE" ]; then
    if grep -q "by Kiddin'" "$f"; then
      sed --follow-symlinks -i "s/by Kiddin'/by $SIGNATURE/g" "$f"
    elif grep -q '%C"' "$f" && ! grep -q "by $SIGNATURE" "$f"; then
      sed --follow-symlinks -i "s#%C\"#%C by $SIGNATURE\"#" "$f"
    fi
  else
    sed --follow-symlinks -i "s/ by Kiddin'//g" "$f"
  fi
  if [ "$REMOVE_AUTHOR_LINKS" = yes ]; then
    sed --follow-symlinks -i -e 's#https://openwrt.ai/##g' -e 's#https://openwrt.ai##g' "$f"
  fi
}
apply_text package/base-files/files/usr/lib/os-release
apply_text package/base-files/files/etc/banner
apply_text files/etc/banner
# Kwrt 的横幅在 diy/ 里（"%D %C by Kiddin'"），prepare.sh 稍后会执行 cp -Rf ./diy/* ./
# 把它盖到 package/base-files 上，所以源头也要改，否则前面的修改会被覆盖。
apply_text diy/package/base-files/files/etc/banner
apply_text devices/common/diy/package/base-files/files/etc/banner

# ---- Web 服务器、文件系统、IPv6、互联网组件、外链 ----
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
  if [ "$FILESYSTEM" = ext4 ]; then
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=y"
    echo "# CONFIG_TARGET_ROOTFS_SQUASHFS is not set"
  else
    echo "# CONFIG_TARGET_ROOTFS_EXT4FS is not set"
    echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
  fi
  # CONFIG_IPV6 两种选项都保持 y：firewall4 的 inet 表需要内核 IPv6，
  # 关掉会连带去掉 firewall4 和 LuCI（见 prepare.sh）。IPV6=off 只去掉 IPv6 组件。
  echo "CONFIG_IPV6=y"
  if [ "$IPV6" = off ]; then
    echo "# CONFIG_PACKAGE_ds-lite is not set"
    echo "# CONFIG_PACKAGE_odhcp6c is not set"
    echo "# CONFIG_PACKAGE_ipv6helper is not set"
    echo "# CONFIG_PACKAGE_6in4 is not set"
    echo "# CONFIG_PACKAGE_6rd is not set"
    echo "# CONFIG_PACKAGE_6to4 is not set"
  fi
  if [ "$REMOVE_AUTHOR_LINKS" = yes ]; then
    echo 'CONFIG_VERSION_HOME_URL=""'
  else
    echo 'CONFIG_VERSION_HOME_URL="https://openwrt.ai/"'
  fi
  if [ -n "$SIGNATURE" ]; then
    echo "CONFIG_VERSION_MANUFACTURER=\"$SIGNATURE\""
  else
    echo 'CONFIG_VERSION_MANUFACTURER=""'
  fi
  for p in $EXTRA_PACKAGES $(internet_packages); do
    echo "CONFIG_PACKAGE_${p}=y"
  done
} > build-options.config

echo "==> build options:"
cat files/etc/ryan-build.conf
echo "EXTRA_PACKAGES='$EXTRA_PACKAGES'"
echo "INTERNET_PACKAGES='$(internet_packages)'"
