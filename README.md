# Ryan-OpenWrt

家用 x86 软路由固件配置。跟踪 [kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) 的 `25.12` 分支，每周自动编译，插件按 `packages.txt` 打进镜像。

## 固件约定

- 目标：`x86/64` generic
- 镜像：`*-ext4-combined-efi.img.gz`（EFI + ext4）
- LAN：`192.168.1.1`
- SSH：仅监听 LAN
- 主机名：`Ryan-OpenWrt`

## 改插件

公开镜像里的包写在 [`packages.txt`](packages.txt)。推到 `main` 或在 Actions 里 **Run workflow**。

不想出现在 GitHub / Release 里的包，写到路由上的 `/root/private-packages.txt`（一行一个包名）。新固件开机联网后会自动安装，一般不用手跑 `install-private-packages`。

`/root/` 已加入升级保留列表。内核和 x86 网卡驱动跟 Kwrt 走，不必手写 `kmod-*`。

## GitHub 上编译

1. 仓库地址：https://github.com/spart9527/openWrtForRyan
2. 打开仓库 **Settings → Actions → General**：允许 workflow，允许 **Read and write** 权限（用来发 Release）。
3. **Actions → Build x86_64 firmware → Run workflow**。
4. 第一次全量大约 2～5 小时。成功后 Releases 里会有镜像。

定时：每周一 00:00（北京时间）自动编一次。

## 固件更新顺序

只刷 **Actions 成功** 后 Releases 里的 `*-ext4-combined-efi.img.gz`。正在跑或已取消的编译不要用。

第一次升级前把私有包名放到 `/root/private-packages.txt`（已做过可跳过）。

**之后每次一键（新固件里）：**

```sh
firmware-upgrade --check
firmware-upgrade
```

会备份到 `/root/backup-latest.tar.gz`，下载并保留配置刷入，设备重启。开机联网后自动安装私有清单，OpenVPN 已在镜像里。

第一版还没有 `firmware-upgrade` 时，用 LuCI 上传镜像并勾选保留配置，或把仓库里的 `scripts/router-upgrade.sh` 拷到路由再执行。重启后同样会自动装私有包。

手动补装（自动失败时）：

```sh
logread -e private-packages
install-private-packages
```

不要在现机上对 `kmod-*` 做 `opkg upgrade`。内核只通过刷整包固件更新。

网络起不来时：无配置再刷一次，只手工恢复 `network` / `firewall` / `dhcp` / `dropbear`，然后 `install-private-packages`，需要的话从备份取出 OpenVPN 证书。

## 本地试配置（可选）

需要 Linux 或 WSL2，磁盘 50G+：

```sh
./scripts/prepare.sh
cd openwrt
make -j$(nproc)
ls bin/targets/x86/64/*ext4-combined-efi.img.gz
```
