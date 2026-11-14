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
# Kwrt 把默认 LAN 改成 10.0.0.1，改回现机的 192.168.1.1
sed -i 's/10.0.0/192.168.1/g' package/base-files/files/bin/config_generate || true

# 首次启动脚本和升级保留列表
mkdir -p files
cp -a "$ROOT/files/." files/

apply_home_config() {
  echo >> .config
  cat "$ROOT/extra.config" >> .config
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    pkg="${pkg%%#*}"
    pkg="$(printf '%s' "$pkg" | tr -d '[:space:]\r')"
    [ -z "$pkg" ] && continue
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
  done < "$ROOT/packages.txt"
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
grep -E '^CONFIG_(TARGET_x86|TARGET_x86_64|TARGET_BOARD|TARGET_SUBTARGET|TARGET_PROFILE|ARCH)=' .config || true
grep -qx 'CONFIG_TARGET_x86=y' .config
grep -qx 'CONFIG_TARGET_x86_64=y' .config
grep -qx 'CONFIG_TARGET_x86_64_DEVICE_generic=y' .config
grep -qx 'CONFIG_ARCH="x86_64"' .config
grep -qx 'CONFIG_PACKAGE_snmpd=y' .config
if grep -qE '^CONFIG_PACKAGE_(snmpd-ssl|libnetsnmp-ssl|luci-app-snmpd-ssl)=y' .config; then
  echo "ERROR: snmpd-ssl still enabled" >&2
  exit 1
fi

echo "==> enabled extra luci apps:"
grep -E '^CONFIG_PACKAGE_luci-app-.*=y' .config | sort
