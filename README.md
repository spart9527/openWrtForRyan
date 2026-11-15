# Ryan-OpenWrt

家用 x86 软路由固件配置。跟踪 [kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) 的 `25.12` 分支，每周自动编译，插件按 `packages.txt` 打进镜像。

## 固件约定

- 目标：`x86/64` generic
- 镜像：`*-ext4-combined-efi.img.gz`（EFI + ext4）
- 分区：内核 16 MiB，根分区 1004 MiB（不要再改）
- LAN：`192.168.1.1`（可在编译选项里改）
- SSH：Dropbear 不绑定接口。LAN 没起来时绑定会让 SSH 起不来；公网由防火墙 `wan` input=REJECT 挡住
- Web：默认 uhttpd。Kwrt 默认的 luci-nginx 会让根路径 403
- 网口：默认 `eth0` 做 WAN，其余所有 eth 口做 LAN。多于 2 张网卡时不要把网口交给 Kwrt 分配（它会把 eth1 当 WAN）
- 拨号：默认 `keep`，升级保留现有 WAN 设置。PPPoE 账号密码不进固件，也不要写进 `build.conf`
- 主机名：`Ryan-OpenWrt`

## 编译选项

默认值在 [`build.conf`](build.conf)。手动跑 Actions 时页面上已预填同样的建议值，改了以页面为准。定时编译和 push 触发的编译直接用 `build.conf`。

| 项 | 默认 | 含义 |
|---|---|---|
| `LAN_IP` | `192.168.1.1` | 后台地址 |
| `HOSTNAME` | `Ryan-OpenWrt` | 只在 `build.conf` 里，Actions 页面没有这一项 |
| `WEB_SERVER` | `uhttpd` | `uhttpd` 或 `nginx` |
| `WAN_PORT` | `eth0` | `eth0`–`eth3`，或 `auto`（不建议） |
| `LAN_PORTS` | `auto` | 除 WAN 以外的所有 eth 口；也可写成 `eth1 eth2` |
| `WAN_PROTO` | `keep` | `keep` / `pppoe` / `dhcp`。`pppoe` 只改协议，账号沿用现机 |
| `EXTRA_PACKAGES` | 空 | 追加到 `packages.txt` 之后。私有包不要写在这里 |

不合法的值会让编译直接失败。选定的值写进固件 `/etc/ryan-build.conf`，并附在 Release 里的同名文件上。开机脚本 `99-ryan-home` 按这个文件写配置，保留配置升级后也会再跑一遍。

## 改插件

公开镜像里的包写在 [`packages.txt`](packages.txt)。推到 `main` 或在 Actions 里 **Run workflow**。

不想出现在 GitHub / Release 里的包，写到路由上的 `/root/private-packages.txt`（一行一个包名）。新固件开机后按清单逐个检查、缺的才装；某个包下架不影响其它包。WAN 每次拨号成功都会再试，直到装齐。一般不用手跑 `install-private-packages`。

不要把 `luci-proto-wireguard`、`wireguard-tools` 放进私有清单：这台机器不用 WireGuard，自编内核也拿不到 `kmod-wireguard`。

`/root/` 已加入升级保留列表。内核和 x86 网卡驱动跟 Kwrt 走，不必手写 `kmod-*`。

## GitHub 上编译

1. 仓库地址：https://github.com/spart9527/openWrtForRyan
2. 打开仓库 **Settings → Actions → General**：允许 workflow，允许 **Read and write** 权限（用来发 Release）。
3. **Actions → Build x86_64 firmware → Run workflow**。页面上有 6 个选项，已预填建议值。
4. 第一次全量大约 2～5 小时。成功后 Releases 里会有镜像和 `ryan-build.conf`。

定时：每周一 00:00（北京时间）自动编一次。

## 固件更新顺序

只刷 **Actions 成功** 后 Releases 里的 `*-ext4-combined-efi.img.gz`。正在跑或已取消的编译不要用。

第一次升级前把私有包名放到 `/root/private-packages.txt`（已做过可跳过）。刷之前确认：

```sh
sysupgrade -l | grep private-packages
```

**之后每次一键（新固件里）：**

```sh
firmware-upgrade --check
firmware-upgrade
```

会先核对新固件的编译选项和现机（LAN IP、WAN 口是否存在）。不一致就停下，确认没问题再用 `FORCE=1 firmware-upgrade`。接着保存 `network` / `dhcp` / `firewall` / `dropbear` 快照，备份到 `/root/backup-latest.tar.gz`，校验 sha256，用 `sysupgrade -T` 预检，再保留配置刷入。设备重启后，开机联网会自动安装私有清单。OpenVPN 已在镜像里。

旧固件里的 `firmware-upgrade` 还没有这些检查。第一次请在 LuCI 里上传 Release 的镜像并勾选保留配置，或先把仓库里的 `scripts/router-upgrade.sh` 拷到路由的 `/usr/sbin/firmware-upgrade` 再跑 `--check`。有人在家、能接显示器或笔记本时再刷。

手动补装（自动失败时）：

```sh
logread -e private-packages
install-private-packages
```

不要在现机上对 `kmod-*` 做 `opkg upgrade`。内核只通过刷整包固件更新。

网络起不来时：无配置再刷一次，只手工恢复 `network` / `firewall` / `dhcp` / `dropbear`，然后 `install-private-packages`，需要的话从备份取出 OpenVPN 证书。

## 刷机后验证

- `cat /etc/ryan-build.conf` 与 Release 说明一致
- `ip -br link`：插线的口是 UP；`bridge link` 里 `br-lan` 含除 eth0 以外的口
- `ifstatus wan | grep -E '"up"|"proto"'`：up 为 true，proto 为现有拨号方式
- SSH 在现机端口上监听
- 浏览器打开 `http://192.168.1.1/` 直接是 LuCI 登录页
- `logread -e private-packages` 最后是 `all installed`
- `uci get dhcp.@dnsmasq[0].port` 为 `0`（私有包装齐之后）
- `nslookup baidu.com 127.0.0.1` 正常
- `opkg update` 不再报 core 源 404

## 本地试配置（可选）

需要 Linux 或 WSL2，磁盘 50G+：

```sh
./scripts/prepare.sh
cd openwrt
make -j$(nproc)
ls bin/targets/x86/64/*ext4-combined-efi.img.gz
```
