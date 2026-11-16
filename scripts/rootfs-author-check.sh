#!/bin/bash
# 在 include/rootfs.mk 的 prepare_rootfs 末尾执行（prepare.sh 挂的钩子），检查最终 rootfs：
#   - 固件里不能再有 "by Kiddin'"（SIGNATURE 留空时去掉；填了就换成自己的签名）
#   - /usr/lib/os-release 不能留着没替换的 %X 占位符，/etc/os-release 应是指向它的链接
#   - REMOVE_AUTHOR_LINKS=yes 时，LuCI 里不能再有 Kwrt 作者外链（概览“系统”卡片底部那一行）
# 不符合就退出 1，编译失败、不出固件。
# 用法：rootfs-author-check.sh <rootfs 目录>
set -u
R="${1:?rootfs dir}"
fail=0
err() { echo "ERROR: rootfs-author-check: $*" >&2; fail=1; }

SIGNATURE=""
REMOVE_AUTHOR_LINKS=yes
if [ -f "$R/etc/ryan-build.conf" ]; then
  # shellcheck disable=SC1091
  . "$R/etc/ryan-build.conf"
else
  err "missing /etc/ryan-build.conf in rootfs"
fi

for f in usr/lib/os-release etc/openwrt_release etc/banner etc/banner.failsafe; do
  [ -f "$R/$f" ] || continue
  if grep -qF "by Kiddin'" "$R/$f"; then
    err "/$f still contains \"by Kiddin'\": $(grep -F "by Kiddin'" "$R/$f" | head -1)"
  fi
  if [ -n "$SIGNATURE" ] && [ "$f" = usr/lib/os-release ] && ! grep -qF "by $SIGNATURE" "$R/$f"; then
    err "/$f missing signature \"by $SIGNATURE\""
  fi
done

if [ -f "$R/usr/lib/os-release" ] && grep -qE '="[^"]*%[A-Za-z]' "$R/usr/lib/os-release"; then
  err "/usr/lib/os-release has unexpanded placeholders: $(grep -E '="[^"]*%[A-Za-z]' "$R/usr/lib/os-release" | head -1)"
fi
if [ -e "$R/etc/os-release" ] && [ ! -L "$R/etc/os-release" ]; then
  err "/etc/os-release is a regular file (should link to ../usr/lib/os-release)"
fi

if [ "$REMOVE_AUTHOR_LINKS" = yes ]; then
  hits="$(grep -rlF \
      -e '固件下载与定制' -e 'TG交流' -e 't.me/opkwrt' -e 'openwrt.ai/fadian' \
      -e "'links')!=='0'" -e "'links') !== '0'" \
      "$R/www" "$R/usr/share/ucode" "$R/usr/lib/lua" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    err "REMOVE_AUTHOR_LINKS=yes but Kwrt author links remain in:"
    printf '  %s\n' $hits >&2
  fi
fi

[ "$fail" -eq 0 ] || exit 1
echo "rootfs-author-check: OK (SIGNATURE='${SIGNATURE}', REMOVE_AUTHOR_LINKS=${REMOVE_AUTHOR_LINKS})"
