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
if [ "$IPV6" = off ]; then
  if grep -qx 'CONFIG_IPV6=y' .config; then
    echo "ERROR: IPV6=off but CONFIG_IPV6=y is still enabled" >&2
    grep -E '^CONFIG_IPV6' .config >&2 || true
    exit 1
  fi
else
  require_config 'CONFIG_IPV6=y'
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

echo "==> enabled extra luci apps:"
grep -E '^CONFIG_PACKAGE_luci-app-.*=y' .config | sort
