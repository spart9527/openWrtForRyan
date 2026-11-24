#!/bin/bash
# 把 Kwrt 25.12 源码、本仓库的包清单和 files 叠到 openwrt/ 里，供随后 make。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git_clone_path() {
  trap 'rm -rf "$tmpdir"' RETURN
  local branch="$1" rurl="$2" mv="${3:-}"
  if [ "$mv" != "mv" ]; then
    shift 2
  else
    shift 3
  fi
  local rootdir="$PWD"
  local tmpdir
  tmpdir="$(mktemp -d)"
  if [ ${#branch} -lt 10 ]; then
    git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$rurl" "$tmpdir"
    cd "$tmpdir"
  else
    git clone --filter=blob:none --sparse "$rurl" "$tmpdir"
    cd "$tmpdir"
    git checkout "$branch"
  fi
  git sparse-checkout init --cone
  git sparse-checkout set "$@"
  if [ "$mv" != "mv" ]; then
    cp -rn ./* "$rootdir/" || true
  else
    mv -n "$@"/* "$rootdir/$@/" || true
  fi
  cd "$rootdir"
}
export -f git_clone_path

echo "==> clone Kwrt 25.12"
if [ ! -d kwrt/.git ]; then
  git clone --depth 1 -b 25.12 https://github.com/kiddin9/Kwrt.git kwrt
fi

echo "==> clone OpenWrt openwrt-25.12"
if [ ! -d openwrt/.git ]; then
  git clone --depth 1 -b openwrt-25.12 https://github.com/openwrt/openwrt.git openwrt
fi

echo "==> copy Kwrt device files"
cp -rf kwrt/devices/common/. openwrt/
cp -rf kwrt/devices/x86_64/. openwrt/
cp -rf kwrt/devices openwrt/

cd openwrt
chmod +x devices/common/diy.sh devices/x86_64/diy.sh

echo "==> run Kwrt common diy.sh"
export REPO_TOKEN="${REPO_TOKEN:-}"
export TARGET="${TARGET:-x86_64}"
/bin/bash devices/common/diy.sh

# kiddin9 的 net-snmp-ssl 是 5.9.1 且无 GCC 14 补丁。feeds -f 会盖掉官方
# snmpd-ssl / libnetsnmp-ssl。源码包里任意一个 *-ssl 被选中都会整包编译失败。
echo "==> drop kiddin9 net-snmp-ssl, restore official net-snmp"
rm -rf feeds/kiddin9/net-snmp-ssl feeds/kiddin9/luci-app-snmpd-ssl
rm -rf package/feeds/kiddin9/net-snmp-ssl package/feeds/kiddin9/luci-app-snmpd-ssl
./scripts/feeds install net-snmp

echo "==> merge .config"
cp -f devices/common/.config .config
echo >> .config
cat devices/x86_64/.config >> .config

echo "==> run Kwrt x86_64 diy.sh"
/bin/bash devices/x86_64/diy.sh

# Kwrt 用 LEDE 的 x86 Makefile 覆盖 OpenWrt 25.12：TESTING 内核 7.3 不存在，
# 扫描目标失败后 kconfig 会丢掉 x86，defconfig 掉到默认 ARM。
echo "==> pin x86 Makefile to OpenWrt 25.12 kernel"
sed -i '/^KERNEL_TESTING_PATCHVER/d' target/linux/x86/Makefile
sed -i 's/^KERNEL_PATCHVER:=.*/KERNEL_PATCHVER:=6.12/' target/linux/x86/Makefile
if ! grep -qE '(^| )ext4( |$)' target/linux/x86/Makefile; then
  sed -i '/^FEATURES:=/s/:=/:=ext4 targz /' target/linux/x86/Makefile
fi
if [ ! -f target/linux/generic/kernel-6.12 ]; then
  echo "ERROR: target/linux/generic/kernel-6.12 missing" >&2
  exit 1
fi
rm -rf tmp

echo "==> apply home overlay"
# 首次启动脚本和升级保留列表
mkdir -p files
cp -a "$ROOT/files/." files/

# 编译选项（LAN IP、Web 服务器、网口、拨号方式、额外包），见 build.conf
/bin/bash "$ROOT/scripts/build-options.sh" "$ROOT"

apply_home_config() {
  echo >> .config
  cat "$ROOT/extra.config" >> .config
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    pkg="${pkg%%#*}"
    pkg="$(printf '%s' "$pkg" | tr -d '[:space:]\r')"
    [ -z "$pkg" ] && continue
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
  done < "$ROOT/packages.txt"
  cat build-options.config >> .config
}

apply_home_config

cp -Rf ./diy/* ./ 2>/dev/null || true

echo "==> apply Kwrt patches"
mkdir -p "devices/x86_64/patches"
cp -rn devices/common/patches devices/x86_64/ 2>/dev/null || true
if [ -n "$(ls -A devices/x86_64/patches/*.bin.patch 2>/dev/null || true)" ]; then
  git apply devices/x86_64/patches/*.bin.patch || true
fi
find "devices/x86_64/patches" -maxdepth 1 -type f -name '*.revert.patch' -print0 2>/dev/null \
  | sort -z \
  | xargs -0 -r -n 1 -I % sh -c "patch -d './' -R --no-backup-if-mismatch -p1 -F 1 -i '%' || true"
find "devices/x86_64/patches" -maxdepth 1 -type f -name '*.patch' ! -name '*.revert.patch' ! -name '*.bin.patch' -print0 2>/dev/null \
  | sort -z \
  | xargs -0 -r -n 1 -I % sh -c "patch -d './' --no-backup-if-mismatch -p1 -F 1 -i '%' || true"

# IPV6=off 不再改 config/Config-build.in 去关 CONFIG_IPV6：
# OpenWrt 25.12 的 CONFIG_IPV6 是 def_bool y，且 CONFIG_KERNEL_IPV6 跟着它走。
# kiddin9 的 firewall4 依赖 +ip6tables（ip6tables-* 是 @IPV6），关掉后 make defconfig
# 会去掉 firewall4，连带 luci / luci-light（depends on firewall||firewall4）、
# luci-mod-admin-full 和 luci-mod-network/status/system 一起掉。就算把依赖改掉，
# 没有内核 IPv6 时 nf_tables 的 inet 表（NF_TABLES_INET depends on IPV6）也不可用，
# fw4 的 "table inet fw4" 起不来，路由器就没有防火墙和 NAT。
# 所以 IPV6=off 时保留内核 IPv6，只去掉 IPv6 拨号/隧道组件，开机由 99-ryan-home 清掉
# wan6 / LAN IPv6 / DHCPv6。
if grep -qx $'\t\tdef_bool n' <(grep -A1 $'^\tconfig IPV6$' config/Config-build.in 2>/dev/null); then
  echo "ERROR: config/Config-build.in has IPV6 def_bool n; firewall4/LuCI would be dropped" >&2
  exit 1
fi

# 去掉 OpenVPN 软件包带的演示密码文件，避免它进入公开 Release。
# files/ 叠加层不能删除打包文件；这里从包源删，并在 prepare_rootfs 里再删一次、做断言。
# 不要在仓库里写入演示口令或拿口令做比对。
echo "==> strip OpenVPN demo password file from package source"
for d in \
	feeds/kiddin9/luci-app-openvpn-server-client \
	feeds/kiddin9/luci-app-openvpn-server \
	package/feeds/kiddin9/luci-app-openvpn-server-client \
	package/feeds/kiddin9/luci-app-openvpn-server
do
	[ -d "$d" ] || continue
	rm -f "$d/root/etc/openvpn/server/psw-file"
done
# 用命令替换而不是 find | grep -q：set -o pipefail 下 grep -q 提前退出会让 find 收到 SIGPIPE，
# 管道整体返回非零，反而跳过这个检查。
if [ -n "$(find feeds/kiddin9/luci-app-openvpn-server-client \
	feeds/kiddin9/luci-app-openvpn-server \
	-name psw-file 2>/dev/null || true)" ]
then
	echo "ERROR: OpenVPN demo psw-file still present in package source" >&2
	find feeds/kiddin9/luci-app-openvpn-server-client feeds/kiddin9/luci-app-openvpn-server -name psw-file >&2
	exit 1
fi

if [ -f include/rootfs.mk ] && ! grep -q 'ryan-strip-openvpn-demo' include/rootfs.mk; then
	echo "==> hook prepare_rootfs to drop demo OpenVPN files and reject placeholder config"
	# $(call mklibs,$(1)) 在 include/rootfs.mk 的 prepare_rootfs 里只出现一次
	awk '
		/\$\(call mklibs,\$\(1\)\)/ && !done {
			print
			print "\t# ryan-strip-openvpn-demo"
			print "\t@rm -f $(1)/etc/openvpn/server/psw-file"
			print "\t@if grep -qF myserver.f3322.net $(1)/etc/config/openvpn $(1)/etc/uci-defaults/openvpn 2>/dev/null; then echo \"ERROR: demo OpenVPN DDNS still present in image\" >&2; exit 1; fi"
			print "\t@if grep -qE \"192\\\\.168\\\\.9\\\\.(0|1)\" $(1)/etc/config/openvpn $(1)/etc/uci-defaults/openvpn 2>/dev/null; then echo \"ERROR: demo OpenVPN 192.168.9.0/24 route still present in image\" >&2; exit 1; fi"
			done=1
			next
		}
		{ print }
	' include/rootfs.mk > include/rootfs.mk.ryan && mv include/rootfs.mk.ryan include/rootfs.mk
	grep -q 'ryan-strip-openvpn-demo' include/rootfs.mk || {
		echo "ERROR: failed to hook include/rootfs.mk" >&2
		exit 1
	}
fi

# ---- 作者署名与外链（SIGNATURE / REMOVE_AUTHOR_LINKS，见 build-options.sh）----
# 2026.11.16-16 实测：LuCI“固件版本”仍带 " by Kiddin'"（来自 /usr/lib/os-release 的 OPENWRT_RELEASE），
# 概览“系统”卡片底部仍有 固件下载与定制 / 赞助 / 源码与反馈 / TG交流 一行
# （kiddin9 feed 的 luci-mod-status 10_system.js）。这里改源码，并在 rootfs 再检查一遍。
author_opts="$(. files/etc/ryan-build.conf; printf '%s|%s' "$SIGNATURE" "$REMOVE_AUTHOR_LINKS")"
author_sig="${author_opts%%|*}"
author_links="${author_opts##*|}"
echo "==> verify signature in base-files (SIGNATURE='${author_sig}')"
for f in package/base-files/files/usr/lib/os-release package/base-files/files/etc/banner; do
	[ -f "$f" ] || continue
	if grep -qF "by Kiddin'" "$f"; then
		echo "ERROR: $f still contains \"by Kiddin'\"" >&2
		grep -nF "by Kiddin'" "$f" >&2
		exit 1
	fi
done
if [ -e package/base-files/files/usr/lib/os-release ] && [ ! -L package/base-files/files/etc/os-release ]; then
	echo "ERROR: package/base-files/files/etc/os-release is no longer a symlink" >&2
	exit 1
fi
if [ "$author_links" = yes ]; then
	echo "==> strip Kwrt author links row from LuCI status overview"
	sys_js="$(find feeds -path '*/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js' -type f 2>/dev/null | sort -u || true)"
	if [ -z "$sys_js" ]; then
		echo "ERROR: luci-mod-status 10_system.js not found in feeds" >&2
		exit 1
	fi
	# package/feeds/* 是指向 feeds/* 的链接，同一个文件可能出现两次，脚本对已处理的文件会跳过
	# shellcheck disable=SC2086
	python3 "$ROOT/scripts/strip-status-links.py" $sys_js
fi
# rootfs 检查：最终镜像里还有 "by Kiddin'" 或（REMOVE_AUTHOR_LINKS=yes 时）作者外链就编译失败
cp -f "$ROOT/scripts/rootfs-author-check.sh" scripts/ryan-rootfs-author-check.sh
chmod +x scripts/ryan-rootfs-author-check.sh
if [ -f include/rootfs.mk ] && ! grep -q 'ryan-rootfs-author-check' include/rootfs.mk; then
	echo "==> hook prepare_rootfs to check author signature/links in final rootfs"
	awk '
		/\$\(call mklibs,\$\(1\)\)/ && !done {
			print
			print "\t@bash $(TOPDIR)/scripts/ryan-rootfs-author-check.sh $(1)"
			done=1
			next
		}
		{ print }
	' include/rootfs.mk > include/rootfs.mk.ryan && mv include/rootfs.mk.ryan include/rootfs.mk
	grep -q 'ryan-rootfs-author-check' include/rootfs.mk || {
		echo "ERROR: failed to hook include/rootfs.mk for author check" >&2
		exit 1
	}
fi

# 固定目标优化为 -O2 -pipe。Kwrt x86_64/diy.sh 曾把 include/target.mk 里的
# -Os 改成 -O2；2026-11-19 起那行被删掉，默认回到 -Os。
# TARGET_OPTIMIZATION 只在 TARGET_OPTIONS 开启时才可被用户设置（固件里这个选项是关的），
# DEFAULT_TARGET_OPTIMIZATION 没有 prompt，make defconfig 会按 target 元数据重写这两项。
# 因此不能只改 .config。这里只改 DUMP 段生成默认值的那一行
# （CPU_CFLAGS = -Os -pipe），与旧 Kwrt 做法同类但范围更窄，loongarch 的
# “CPU_CFLAGS := -O2 -pipe” 不会被碰到。随后的 defconfig 会据此写出 -O2。
echo "==> pin include/target.mk CPU_CFLAGS default to -O2 -pipe"
if [ ! -f include/target.mk ]; then
  echo "ERROR: include/target.mk missing" >&2
  exit 1
fi
if ! grep -qE '^[[:space:]]*CPU_CFLAGS = -O2 -pipe[[:space:]]*$' include/target.mk; then
  if grep -qE '^[[:space:]]*CPU_CFLAGS = -Os -pipe[[:space:]]*$' include/target.mk; then
    sed -i 's/^\([[:space:]]*CPU_CFLAGS = \)-Os -pipe[[:space:]]*$/\1-O2 -pipe/' include/target.mk
  else
    echo "ERROR: include/target.mk has no CPU_CFLAGS = -Os -pipe default to pin" >&2
    grep -n 'CPU_CFLAGS' include/target.mk >&2 || true
    exit 1
  fi
fi
if ! grep -qE '^[[:space:]]*CPU_CFLAGS = -O2 -pipe[[:space:]]*$' include/target.mk; then
  echo "ERROR: failed to pin include/target.mk CPU_CFLAGS to -O2 -pipe" >&2
  exit 1
fi

echo "==> make defconfig"
make defconfig

echo "==> re-apply home overlay after defconfig"
apply_home_config
make defconfig

echo "==> verify target x86_64"
grep -E '^CONFIG_(TARGET_x86|TARGET_x86_64|TARGET_BOARD|TARGET_SUBTARGET|TARGET_PROFILE|ARCH|PACKAGE_snmpd)' .config || true
require_config() {
  local key="$1"
  if ! grep -qx "$key" .config; then
    echo "ERROR: missing $key in .config" >&2
    grep -E "$(printf '%s' "$key" | sed 's/=.*//')" .config >&2 || true
    exit 1
  fi
}
require_config 'CONFIG_TARGET_x86=y'
require_config 'CONFIG_TARGET_x86_64=y'
require_config 'CONFIG_ARCH="x86_64"'
require_config 'CONFIG_TARGET_BOARD="x86"'
require_config 'CONFIG_TARGET_SUBTARGET="64"'
require_config 'CONFIG_TARGET_PROFILE="DEVICE_generic"'
require_config 'CONFIG_TARGET_KERNEL_PARTSIZE=16'
echo "==> target optimization:"
grep -E '^CONFIG_(DEFAULT_)?TARGET_OPTIMIZATION=' .config || true
# TARGET_OPTIMIZATION 实际进入 rules.mk 的 TARGET_CFLAGS。
# DEFAULT_TARGET_OPTIMIZATION 无 prompt，不能当作用户可选项写入；它应与上面 pin 后的默认一致。
require_config 'CONFIG_TARGET_OPTIMIZATION="-O2 -pipe"'
require_config 'CONFIG_DEFAULT_TARGET_OPTIMIZATION="-O2 -pipe"'
# 加速：不应再编译整个软件源
for k in ALL_NONSHARED ALL_KMODS ALL IB; do
  if grep -qx "CONFIG_${k}=y" .config; then
    echo "ERROR: CONFIG_${k}=y still enabled (slow build)" >&2
    exit 1
  fi
done
echo "==> packages: $(grep -c '^CONFIG_PACKAGE_.*=y' .config) built-in, $(grep -c '^CONFIG_PACKAGE_.*=m' .config) modules"
require_config 'CONFIG_TARGET_ROOTFS_PARTSIZE=1004'
require_config 'CONFIG_PACKAGE_snmpd-nossl=y'
if grep -E '^CONFIG_PACKAGE_[^=]*snmp[^=]*-ssl=[ym]' .config; then
  echo "ERROR: a snmp *-ssl package is still enabled" >&2
  grep -E '^CONFIG_PACKAGE_[^=]*snmp[^=]*-ssl=' .config >&2 || true
  exit 1
fi
if [ -d feeds/kiddin9/net-snmp-ssl ] || [ -d package/feeds/kiddin9/net-snmp-ssl ]; then
  echo "ERROR: kiddin9 net-snmp-ssl still present" >&2
  exit 1
fi

# 按编译选项核对 Web 服务器、文件系统、IPv6、互联网组件
. files/etc/ryan-build.conf
if [ "$FILESYSTEM" = ext4 ]; then
  require_config 'CONFIG_TARGET_ROOTFS_EXT4FS=y'
  if grep -qx 'CONFIG_TARGET_ROOTFS_SQUASHFS=y' .config; then
    echo "ERROR: FILESYSTEM=ext4 but squashfs is still enabled" >&2
    exit 1
  fi
else
  require_config 'CONFIG_TARGET_ROOTFS_SQUASHFS=y'
  if grep -qx 'CONFIG_TARGET_ROOTFS_EXT4FS=y' .config; then
    echo "ERROR: FILESYSTEM=squashfs but ext4 is still enabled" >&2
    exit 1
  fi
fi
# 两种选项都必须保留 CONFIG_IPV6=y：firewall4 需要内核 IPv6（见上面的说明）
require_config 'CONFIG_IPV6=y'
require_config 'CONFIG_PACKAGE_firewall4=y'
if [ "$IPV6" = off ]; then
  for p in odhcp6c ipv6helper 6in4 6rd 6to4 ds-lite; do
    if grep -qE "^CONFIG_PACKAGE_${p}=[ym]" .config; then
      echo "ERROR: IPV6=off but $p is still enabled" >&2
      grep -E "^CONFIG_PACKAGE_${p}=" .config >&2 || true
      exit 1
    fi
  done
fi
if [ "$REMOVE_AUTHOR_LINKS" = yes ]; then
  if grep -qE '^CONFIG_VERSION_HOME_URL="https?://' .config; then
    echo "ERROR: REMOVE_AUTHOR_LINKS=yes but HOME_URL still set" >&2
    grep '^CONFIG_VERSION_HOME_URL' .config >&2 || true
    exit 1
  fi
fi
if [ "$WEB_SERVER" = uhttpd ]; then
  require_config 'CONFIG_PACKAGE_luci=y'
  require_config 'CONFIG_PACKAGE_uhttpd=y'
  if grep -qE '^CONFIG_PACKAGE_luci-nginx=[ym]' .config; then
    echo "ERROR: WEB_SERVER=uhttpd but luci-nginx is still enabled" >&2
    exit 1
  fi
  if grep -qE '^CONFIG_PACKAGE_nginx[^=]*=y' .config; then
    echo "WARN: nginx pulled in by another package; 99-ryan-home disables it at boot" >&2
  fi
else
  require_config 'CONFIG_PACKAGE_luci-nginx=y'
fi
for p in $(grep -E '^CONFIG_PACKAGE_' build-options.config | sed 's/^CONFIG_PACKAGE_\(.*\)=y$/\1/'); do
  require_config "CONFIG_PACKAGE_${p}=y"
done

# 必须编进去的包：少一个就不出固件，免得刷完没有后台或少了在用的功能
must_have="luci-base luci-app-firewall luci-mod-network luci-mod-status luci-mod-system luci-app-openvpn-server-client luci-app-upnp irqbalance luci-app-irqbalance"
if [ "$WEB_SERVER" = uhttpd ]; then
  must_have="$must_have luci luci-light luci-mod-admin-full uhttpd"
else
  must_have="$must_have luci-nginx"
fi
case "$INTERNET" in
  none) ;;
  *) must_have="$must_have luci-app-${INTERNET}" ;;
esac
missing=""
for p in $must_have; do
  grep -qx "CONFIG_PACKAGE_${p}=y" .config || missing="$missing $p"
done
if [ -n "$missing" ]; then
  echo "ERROR: must-have packages missing from .config:$missing" >&2
  for p in $missing; do
    grep -E "^(# )?CONFIG_PACKAGE_${p}[= ]" .config >&2 || echo "  (CONFIG_PACKAGE_${p} not in .config)" >&2
  done
  exit 1
fi
# packages.txt 里的顶层包也必须编进去。下面几个在 Kwrt 25.12 x86 上本来就编不了
# （源里没有，或依赖 PWM_SUPPORT），之前的成功编译里也没有，只警告。
not_on_x86=" luci-app-turboacc luci-app-fan "
missing=""
while IFS= read -r pkg || [ -n "$pkg" ]; do
  pkg="${pkg%%#*}"
  pkg="$(printf '%s' "$pkg" | tr -d '[:space:]\r')"
  [ -z "$pkg" ] && continue
  grep -qx "CONFIG_PACKAGE_${pkg}=y" .config && continue
  case "$not_on_x86" in
    *" $pkg "*) echo "WARN: packages.txt entry $pkg is not available on x86, skipped" >&2 ;;
    *) missing="$missing $pkg" ;;
  esac
done < "$ROOT/packages.txt"
if [ -n "$missing" ]; then
  echo "ERROR: packages.txt entries not built in:$missing" >&2
  exit 1
fi
echo "==> must-have packages OK:$must_have"

echo "==> enabled extra luci apps:"
grep -E '^CONFIG_PACKAGE_luci-app-.*=y' .config | sort
