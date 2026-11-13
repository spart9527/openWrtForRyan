# Ryan-OpenWrt

家用 x86 软路由固件配置。跟踪 [kiddin9/Kwrt](https://github.com/kiddin9/Kwrt) 的 `25.12` 分支，每周自动编译，插件按 `packages.txt` 打进镜像。

## 固件约定

- 目标：`x86/64` generic
- 镜像：`*-ext4-combined-efi.img.gz`（EFI + ext4）
- LAN：`192.168.1.1`
- SSH：仅监听 LAN
- 主机名：`Ryan-OpenWrt`

## 改插件

编辑 [`packages.txt`](packages.txt)，只写顶层包（`luci-app-*` 等）。推到 `main` 或在 Actions 里 **Run workflow**。

内核和 Kwrt 的 x86 网卡驱动跟上游走，不必手写 `kmod-r8168` 这类包。

## GitHub 上编译

1. 仓库地址：https://github.com/spart9527/openWrtForRyan
2. 打开仓库 **Settings → Actions → General**：允许 workflow，允许 **Read and write** 权限（用来发 Release）。
3. **Actions → Build x86_64 firmware → Run workflow**。
4. 第一次全量大约 2～5 小时。成功后 Releases 里会有镜像。

定时：每周一 00:00（北京时间）自动编一次。

## 刷机

备份：

```sh
sysupgrade -b /tmp/backup.tar.gz
```

LuCI：**系统 → 备份/升级**，上传 `*-ext4-combined-efi.img.gz`，勾选保留配置。

或把 [`scripts/router-upgrade.sh`](scripts/router-upgrade.sh) 拷到路由上：

```sh
REPO=spart9527/openWrtForRyan sh router-upgrade.sh --check
REPO=spart9527/openWrtForRyan sh router-upgrade.sh
```

跨内核升级前先备份。网络异常就无配置刷入，再只恢复 `network` / `firewall` / `dhcp` / `dropbear`。

不要对现机执行 `opkg upgrade` 去升 `kmod-*`。

## 本地试配置（可选）

需要 Linux 或 WSL2，磁盘 50G+：

```sh
./scripts/prepare.sh
cd openwrt
make -j$(nproc)
ls bin/targets/x86/64/*ext4-combined-efi.img.gz
```
