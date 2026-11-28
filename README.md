# Ryan-OpenWrt

家用 x86 软路由固件配置。跟踪 [kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) 的 `25.12` 分支，每月 1 号自动编译，插件按 `packages.txt` 和编译选项打进镜像。

## 固件约定

- 目标：`x86/64` generic
- 镜像：默认 `*-ext4-combined-efi.img.gz`（EFI + ext4）；也可在编译选项里改成 squashfs
- 分区：内核 16 MiB，根分区 1004 MiB（不要再改）
- LAN：`192.168.1.1`（可在编译选项里改）
- SSH：Dropbear 不绑定接口。LAN 没起来时绑定会让 SSH 起不来；公网由防火墙 `wan` input=REJECT 挡住
- Web：默认 uhttpd 作为 LuCI 后台。镜像同时编入 `nginx-ssl`，用于 Xbox 国内 CDN 的 302 跳转，并把 `http://192.168.1.1/` 反代到本机 `127.0.0.1:8080` 的 uhttpd；HTTPS 443 仍由 uhttpd 提供。不要把编译选项改成用 nginx 当后台（Kwrt 的 luci-nginx 会让根路径 403）
- 网口：默认 `eth0` 做 WAN，其余所有 eth 口做 LAN。多于 2 张网卡时不要把网口交给 Kwrt 分配（它会把 eth1 当 WAN）
- 拨号：默认 `keep`，升级保留现有 WAN 设置。PPPoE 账号密码不进固件，也不要写进 `build.conf`
- 主机名：`Ryan-OpenWrt`
- IPv6：默认开启，刷机不改现有的 `wan6` 等配置。不用 IPv6 就在路由器上关掉 `wan6`。选 `off` 会不装 IPv6 拨号/隧道组件，并在刷机后清除 `wan6`、LAN IPv6 和 DHCPv6；内核仍保留 IPv6，因为 firewall4 的防火墙表需要它
- 互联网：默认把 PassWall 和现机依赖编进固件（不含 SmartDNS）
- 多核：预装 `irqbalance` 和 `luci-app-irqbalance`，默认启用，给 iKOOLCORE R2（N95 四核）均衡网卡中断
- OpenVPN：镜像含 `luci-app-openvpn-server-client`、`openvpn-openssl`、`openvpn-easy-rsa`。不含演示账号、占位 DDNS（`myserver.f3322.net`）或示例推送路由 `192.168.9.0/24`。全新安装后在 LuCI 里自行配置、在本机生成证书并填写用户名密码，再启用服务。WAN 上的 1194（或你改过的端口）只在服务端启用时放行，停止或未启用时关闭。保留配置升级会保留 `/etc/config/openvpn`、`/etc/openvpn/`、`/etc/easy-rsa/`
- 后台密码不作为编译选项：仓库和 Release 是公开的，密码不能写进固件。升级会保留现有 `/etc/shadow`，在路由器上改即可

## 编译选项

默认值在 [`build.conf`](build.conf)。在 Actions 里 **Run workflow** 时，每一项旁边都有说明，页面上已预填同样的建议值，改了以页面为准。定时编译和 push 触发的编译直接用 `build.conf`。

| 项 | 默认 | 含义 |
|---|---|---|
| `LAN_IP` | `192.168.1.1` | 后台地址。刷机后写入，并覆盖你在后台改过的 LAN IP |
| `HOSTNAME` | `Ryan-OpenWrt` | 主机名。刷机后写入，并覆盖你在后台改过的主机名 |
| `WEB_SERVER` | `uhttpd` | LuCI 后台。请保持 `uhttpd`（推荐）。Xbox 跳转另编 `nginx-ssl`，不必改成 `nginx`；选 `nginx` 会用 luci-nginx 当后台，根路径可能 403 |
| `WAN_PORT` | `eth0` | `eth0`–`eth3`，或 `auto`（不建议） |
| `LAN_PORTS` | `auto` | 除 WAN 以外的所有 eth 口；也可写成 `eth1 eth2` |
| `WAN_PROTO` | `keep` | `keep` / `pppoe` / `dhcp`。`pppoe` 只改协议，账号沿用现机 |
| `FILESYSTEM` | `ext4` | `ext4`（与现机一致）或 `squashfs`（出厂文件可从 `/rom` 恢复）。换格式会整盘重写分区，不能当普通升级 |
| `IPV6` | `on` | `on` 保留默认 IPv6 能力，刷机不改现有 IPv6 配置。`off` 不装 IPv6 组件（odhcp6c、ipv6helper、6in4、6rd、6to4、ds-lite），刷机后清掉 `wan6`、LAN IPv6 和 DHCPv6，路由器不再获取或下发 IPv6；内核仍保留 IPv6，因为 firewall4 依赖它 |
| `INTERNET` | `passwall` | 科学上网客户端，直接编进固件。`passwall` 含现机依赖（不含 SmartDNS）；也可选 `passwall2` / `openclash` / `homeproxy` / `ssr-plus` / `none`。不含 WireGuard。节点配置留在路由器上，不进公开镜像 |
| `SIGNATURE` | 空 | 自定义版本签名，替换 “by Kiddin'”。留空则去掉作者签名 |
| `REMOVE_AUTHOR_LINKS` | `yes` | 去掉 LuCI 和横幅里指向 openwrt.ai 的主页链接。软件源 `dl.openwrt.ai` 会保留 |
| `EXTRA_PACKAGES` | 空 | 追加到 `packages.txt` 之后 |

不合法的值会让编译直接失败。选定的值写进固件 `/etc/ryan-build.conf`，并附在 Release 里的同名文件上。开机脚本 `99-ryan-home` 按这个文件写配置，保留配置升级后也会再跑一遍。后台密码不会出现在这个文件里。

## 改插件

公开镜像里的基础包写在 [`packages.txt`](packages.txt)（含 `irqbalance` 和 `luci-app-irqbalance`）。科学上网相关包由 `INTERNET` 选项编进固件（默认 PassWall，不含 SmartDNS）。推到 `main` 或在 Actions 里 **Run workflow**。

这台机器不用 WireGuard，也不要把 `luci-proto-wireguard`、`wireguard-tools` 加进固件：自编内核匹配不到现成的 `kmod-wireguard`。

`/root/` 已加入升级保留列表，用来存备份、证书等。Xbox 国内 CDN：镜像含 `nginx-ssl`、`/etc/nginx/nginx.conf`、`/etc/nginx/conf.d/xbox-cn.conf`（对 Xbox CDN 主机 302 到 assets1/dlassets.xboxlive.cn）和 `/etc/nginx/conf.d/luci-proxy.conf`（其他 HTTP 请求反代到 `127.0.0.1:8080` 的 uhttpd）。nginx 独占 80，不监听 443；uhttpd 的 HTTP 只监听 `127.0.0.1:8080`，HTTPS 仍走 443。`nginx.global.uci_enable` 为 false，避免旧 UCI 里的 `_lan` / `_sc_pw` 抢端口。升级会保留这些 nginx 配置以及 `/etc/config` 里的 uhttpd 监听设置。主 dnsmasq（口 53，含 Xbox 网卡「直连」例外）把下载域名指到本机 LAN IP（默认 192.168.1.1，随 `LAN_IP` 编译选项），并把 `assets-srvs-net.trafficmanager.net` 的 SRV 转到 `assets1.xboxlive.com:80`。PassWall 会把其余 53 端口查询（含本机）转到 11400 的临时 dnsmasq，`ryan-xbox-cdn` 会把同样的 `address=`、SRV 和 `filter-AAAA` 写入这份配置并重新拉起进程（只 HUP 不够）；开机执行，之后每分钟检查一次，PassWall 重写配置后不必再手工补。不要把 .com CNAME 到 .cn（会 403）。本版不再预装 SmartDNS，也不再保留 `/etc/smartdns/`（旧的自定义规则和去广告列表升级后会清掉）。不预装 `luci-app-adbyby-plus`，也不打开 PassWall 去广告。内核和 x86 网卡驱动跟 Kwrt 走，不必手写 `kmod-*`。

## GitHub 上编译

1. 仓库地址：https://github.com/spart9527/openWrtForRyan
2. 打开仓库 **Settings → Actions → General**：允许 workflow，允许 **Read and write** 权限（用来发 Release）。
3. **Actions → Build x86_64 firmware → Run workflow**。页面上每一项都有说明，并已预填建议值。
4. 只编进固件的包（已关闭 Kwrt 默认的 `ALL_NONSHARED` / `ALL_KMODS` / ImageBuilder），并缓存工具链、ccache 和 Go 编译缓存（dl/ 按体积可选）。成功后 Releases 里会有镜像和 `ryan-build.conf`。

目标软件包固定按 `-O2 -pipe` 编译（偏向运行速度，也与现有 ccache 一致）。`scripts/prepare.sh` 会改 `include/target.mk` 里生成默认优化参数的那一行，再跑 `defconfig` 并检查生效值；只往 `.config` 里写会被覆盖。不再依赖 Kwrt 的 `diy.sh`。不要改成 `-Os`：优化参数变了之后 ccache 会大面积失效，编译可能从约 2 小时拉长到 5 小时以上。

定时：每月 1 号 08:00（北京时间）自动编一次。只改 `README.md` 不会触发编译。

## 固件更新顺序

只刷 **Actions 成功** 后 Releases 里与本次 `FILESYSTEM` 对应的 `*-combined-efi.img.gz`。正在跑或已取消的编译不要用。

**之后每次一键（新固件里）：**

```sh
firmware-upgrade --check
firmware-upgrade
```

会先核对新固件的编译选项和现机（LAN IP、WAN 口是否存在、文件系统是否一致）。不一致就停下，确认没问题再用 `FORCE=1 firmware-upgrade`。若新固件关闭了 IPv6，会提示刷机后将清除 `wan6` 等配置。接着保存 `network` / `dhcp` / `firewall` / `dropbear` 快照，备份到 `/root/backup-latest.tar.gz`，校验 sha256，用 `sysupgrade -T` 预检，再保留配置刷入。PassWall、irqbalance 和 OpenVPN 默认已在镜像里。

旧固件里的 `firmware-upgrade` 还没有这些检查。第一次请在 LuCI 里上传 Release 的镜像并勾选保留配置，或先把仓库里的 `scripts/router-upgrade.sh` 拷到路由的 `/usr/sbin/firmware-upgrade` 再跑 `--check`。有人在家、能接显示器或笔记本时再刷。

镜像会附带 sysupgrade metadata，LuCI 网页升级不应再出现 “Image metadata not present”。x86 通用包不把特定 DMI `board_name` 写进 `supported_devices`，以免校验误拒；现机侧允许空的设备列表。从还没有这一改动的版本（例如 `2026.11.25-28-x86_64`）刷入第一份带 metadata 的镜像时，现机校验还不认识空列表，LuCI 可能提示校验失败，需勾选“强制刷写”并保留配置；命令行则用 `FORCE=1 firmware-upgrade` 或 `sysupgrade -F -v`。刷入之后，再升级就不需要强制。

不要在现机上对 `kmod-*` 做 `opkg upgrade`。内核只通过刷整包固件更新。

网络起不来时：无配置再刷一次，只手工恢复 `network` / `firewall` / `dhcp` / `dropbear`，需要的话从备份取出 OpenVPN 证书。

## 刷机后自动调优

`files/etc/uci-defaults/zz-ryan-tune` 每次刷机后跑一遍（排在 Kwrt 自带脚本之后），可重复执行：

- 关闭 `zram`、`ram_release`、`parentcontrol` 自启（8GB 内存不需要压缩交换和定时清缓存；家长控制没在用，要用时在 LuCI 里勾选开启）
- 若还没有 irqbalance 配置，则默认启用（镜像里已是启用；已有配置不覆盖，可在 LuCI 里关闭）
- 本版未编入 SmartDNS 时，清掉升级留下的 `/etc/config/smartdns*` 和 `/etc/smartdns/`（不去动 PassWall 自带的 SmartDNS 辅助脚本）
- 写入 Xbox CDN 的主 dnsmasq 主机名和 SRV（见 `98-ryan-xbox-cdn`），并启用 `ryan-xbox-cdn`（开机 + 每分钟 cron）把同样规则补进 PassWall 的 11400 临时配置；选 uhttpd 时启用 nginx 与 uhttpd，把 uhttpd 的 HTTP 改到 `127.0.0.1:8080`，并关闭 nginx UCI 托管，避免和 LuCI 抢 80/443
- 防火墙只开软件流量卸载：`flow_offloading=1`、`flow_offloading_hw=0`（igc / i226 网卡不支持硬件卸载）
- 删除已卸载插件残留的防火墙 include：`dockerd`、`adbyby`、`shadowsocksr`、`passwall2`、`passwall2_server`、`unblockmusic`

不要对 `miniupnpd-nftables` / `luci-app-upnp` 做 `opkg install --force-reinstall`：`luci-app-upnp` 不在任何在线源里，卸掉就装不回来，只能从固件镜像里提取或重刷。

## 刷机后验证

- `cat /etc/ryan-build.conf` 与 Release 说明一致（应看到 `IPV6='on'`、`INTERNET='passwall'`、`FILESYSTEM='ext4'`）
- `opkg status luci-app-passwall`、`opkg status irqbalance` 和 `opkg status luci-app-irqbalance` 显示已安装
- 登录横幅和系统信息里没有 “by Kiddin'”，LuCI 里没有指向 openwrt.ai 的主页链接
- `ip -br link`：插线的口是 UP；`bridge link` 里 `br-lan` 含除 eth0 以外的口
- `ifstatus wan | grep -E '"up"|"proto"'`：up 为 true，proto 为现有拨号方式
- SSH 在现机端口上监听
- 浏览器打开 `http://192.168.1.1/` 直接是 LuCI 登录页
- `uci get dhcp.@dnsmasq[0].port` 为 `0`（PassWall 接管 53 之后）
- `uci get irqbalance.irqbalance.enabled` 为 `1`；`/etc/init.d/irqbalance enabled && echo on` 输出 `on`
- `uci get dhcp.@dnsmasq[0].address` 含 `/assets1.xboxlive.com/<LAN_IP>`；`uci get dhcp.ryan_xbox_srvs.target` 为 `assets1.xboxlive.com`
- `opkg status nginx-ssl` 显示已安装；`test -f /etc/nginx/nginx.conf && test -f /etc/nginx/conf.d/xbox-cn.conf && test -f /etc/nginx/conf.d/luci-proxy.conf && echo ok` 输出 `ok`
- `uci get uhttpd.main.listen_http` 为 `127.0.0.1:8080`；`uci get uhttpd.main.listen_https` 仍含 443；`uci get nginx.global.uci_enable` 为 `false`
- `/etc/init.d/nginx enabled && echo on` 与 `/etc/init.d/uhttpd enabled && echo on` 都输出 `on`
- `curl -sI -H 'Host: assets1.xboxlive.com' http://192.168.1.1/testpath/file.bin` 为 302，且 Location 指向 `http://assets1.xboxlive.cn/testpath/file.bin`；`dlassets.xboxlive.com` 同理，跳到 `http://dlassets.xboxlive.cn/...`
- `curl -sI http://192.168.1.1/` 仍是 LuCI（例如 403 且带 `x-luci-login-required`），不是 nginx 默认页；`curl -skI https://192.168.1.1/` 同样能打开 LuCI
- `nslookup assets1.xboxlive.com 127.0.0.1` 应直接返回 LAN IP（走 PassWall 11400 时也一样，且不应再出现官方 AAAA/IP）；`/etc/init.d/ryan-xbox-cdn enabled && echo on` 输出 `on`
- `nslookup baidu.com 127.0.0.1` 正常
- `opkg update` 不再报 core 源 404
- `/etc/init.d/zram enabled || echo off` 输出 `off`；`uci get firewall.@defaults[0].flow_offloading_hw` 为 `0`
- LuCI 的 UPnP 页面打开不报错
- 全新安装：`uci get openvpn.myvpn.enabled` 为 `0`；`uci get firewall.openvpn.enabled` 为 `0`；`uci -q get openvpn.myvpn.ddns` 应为空；`/etc/openvpn/server/psw-file` 不存在。保留配置升级：OpenVPN 配置和证书仍是你原来的；若服务端是启用的，则 `uci get firewall.openvpn.enabled` 为 `1`

## 本地试配置（可选）

需要 Linux 或 WSL2，磁盘 50G+：

```sh
./scripts/prepare.sh
cd openwrt
make -j$(nproc)
ls bin/targets/x86/64/*-combined-efi.img.gz
```
