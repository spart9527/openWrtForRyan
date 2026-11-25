#!/bin/bash
# 让 x86 combined 镜像带上 sysupgrade metadata，供 LuCI 网页升级校验。
# 在 openwrt/ 源码树里调用（prepare.sh 已经 cd 到这里）。
set -euo pipefail

# x86 的 Device/Default 会把 SUPPORTED_DEVICES 清空。Build/append-metadata 只有在
# 该列表非空时才往镜像末尾写入 fwtool JSON，否则 LuCI / sysupgrade 会看到
# “Image metadata not present”。官方这样做是因为 x86 通用镜像要跑在各种 DMI
# board_name 上，写上 generic 等设备名反而会让校验失败。正确做法是：仍然写入
# metadata（supported_devices 可为空），并在 x86 的 fwtool 校验里允许空列表。
# 不要开启 REQUIRE_IMAGE_METADATA，以免旧的无 metadata 镜像无法再刷入。

if [ ! -f include/image-commands.mk ]; then
  echo "ERROR: include/image-commands.mk missing" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
p = Path("include/image-commands.mk")
text = p.read_text()
old = "$(if $(SUPPORTED_DEVICES),-echo $(call metadata_json) | fwtool -I - $@)"
new = "-echo $(call metadata_json) | fwtool -I - $@"
if old in text:
    if text.count(old) != 1:
        raise SystemExit("ERROR: expected exactly one append-metadata fwtool line, found %d" % text.count(old))
    p.write_text(text.replace(old, new, 1))
elif text.count("-echo $(call metadata_json) | fwtool -I - $@") >= 1:
    raise SystemExit(0)
else:
    raise SystemExit("ERROR: append-metadata fwtool line not found in include/image-commands.mk")
PY

if grep -q '$(if $(SUPPORTED_DEVICES),-echo $(call metadata_json) | fwtool -I - $@)' include/image-commands.mk; then
  echo "ERROR: failed to make append-metadata always write fwtool JSON" >&2
  grep -n 'append-metadata\|metadata_json' include/image-commands.mk | head >&2 || true
  exit 1
fi
if ! grep -q -- '-echo $(call metadata_json) | fwtool -I - $@' include/image-commands.mk; then
  echo "ERROR: append-metadata no longer writes fwtool JSON" >&2
  exit 1
fi

img_mk="target/linux/x86/image/Makefile"
if [ ! -f "$img_mk" ]; then
  echo "ERROR: $img_mk missing" >&2
  exit 1
fi
if ! grep -qE '^[[:space:]]*IMAGE/combined-efi\.img\.gz := .*[[:space:]]append-metadata[[:space:]]*$' "$img_mk"; then
  echo "ERROR: combined-efi.img.gz recipe is missing append-metadata" >&2
  grep -n 'combined-efi.img.gz' "$img_mk" >&2 || true
  exit 1
fi

fwtool_sh="package/base-files/files/lib/upgrade/fwtool.sh"
if [ ! -f "$fwtool_sh" ]; then
  echo "ERROR: $fwtool_sh missing" >&2
  exit 1
fi
if ! grep -q 'PERMIT_EMPTY_SUPPORTED_DEVICES' "$fwtool_sh"; then
  python3 - <<'PY'
from pathlib import Path
p = Path("package/base-files/files/lib/upgrade/fwtool.sh")
text = p.read_text()
old = """\tv "Device $device not supported by this image"
\tlocal devices="Supported devices:"
\tfor k in $dev_keys; do
\t\tjson_get_var dev "$k"
\t\tdevices="$devices $dev"
\tdone
\tv "$devices"

\treturn 1
}
"""
new = """\tlocal devices="Supported devices:"
\tlocal has_devices=0
\tfor k in $dev_keys; do
\t\tjson_get_var dev "$k"
\t\tdevices="$devices $dev"
\t\thas_devices=1
\tdone

\tif [ "$has_devices" = 0 ]; then
\t\t# x86/armsr 等通用镜像不绑定具体 board_name
\t\t[ "$PERMIT_EMPTY_SUPPORTED_DEVICES" = 1 ] && return 0

\t\tv "This image does not support any devices"
\telse
\t\tv "Device $device not supported by this image"
\t\tv "$devices"
\tfi

\treturn 1
}
"""
if old not in text:
    raise SystemExit("ERROR: fwtool_check_image failure tail not found")
if text.count(old) != 1:
    raise SystemExit("ERROR: fwtool_check_image failure tail is not unique")
p.write_text(text.replace(old, new, 1))
PY
fi
if ! grep -q 'PERMIT_EMPTY_SUPPORTED_DEVICES' "$fwtool_sh"; then
  echo "ERROR: failed to patch $fwtool_sh for empty supported_devices" >&2
  exit 1
fi

plat_sh="target/linux/x86/base-files/lib/upgrade/platform.sh"
if [ ! -f "$plat_sh" ]; then
  echo "ERROR: $plat_sh missing" >&2
  exit 1
fi
if ! grep -q '^PERMIT_EMPTY_SUPPORTED_DEVICES=1$' "$plat_sh"; then
  if grep -q '^RAMFS_COPY_BIN=' "$plat_sh"; then
    sed -i '/^RAMFS_COPY_BIN=/a PERMIT_EMPTY_SUPPORTED_DEVICES=1' "$plat_sh"
  else
    sed -i '1i PERMIT_EMPTY_SUPPORTED_DEVICES=1' "$plat_sh"
  fi
fi
if ! grep -q '^PERMIT_EMPTY_SUPPORTED_DEVICES=1$' "$plat_sh"; then
  echo "ERROR: failed to set PERMIT_EMPTY_SUPPORTED_DEVICES in $plat_sh" >&2
  exit 1
fi
# 不要打开 REQUIRE_IMAGE_METADATA：旧的无 metadata 镜像还应能刷入。
