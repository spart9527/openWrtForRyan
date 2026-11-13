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

不想出现在 GitHub / Release 里的包，写到路由上的 `/root/private-packages.txt`（一行一个包名），刷机后执行：

```sh
install-private-packages
```

`/root/` 已加入升级保留列表。内核和 x86 网卡驱动跟 Kwrt 走，不必手写 `kmod-*`。

## GitHub 上编译

1. 仓库地址：https://github.com/spart9527/openWrtForRyan
2. 打开仓库 **Settings → Actions → General**：允许 workflow，允许 **Read and write** 权限（用来发 Release）。
3. **Actions → Build x86_64 firmware → Run workflow**。
4. 第一次全量大约 2～5 小时。成功后 Releases 里会有镜像。

定时：每周一 00:00（北京时间）自动编一次。

## 固件更新顺序

只刷 **Actions 成功** 后 Releases 里的 `*-ext4-combined-efi.img.gz`。正在跑或已取消的编译不要用。

1. **确认清单还在路由上**  
   第一次升级前把私有包名放到 `/root/private-packages.txt`。之后 `/root/` 会随配置保留。

2. **备份**（拷到电脑）

   ```sh
   sysupgrade -b /tmp/backup.tar.gz
   ```

3. **刷入并保留配置**  
   LuCI：**系统 → 备份/升级**，上传镜像，勾选保留配置。  
   或：

   ```sh
   REPO=spart9527/openWrtForRyan sh router-upgrade.sh --check
   REPO=spart9527/openWrtForRyan sh router-upgrade.sh
   ```

   重启后 SSH 端口、LAN、防火墙、OpenVPN 服务和证书都还在（OpenVPN 已编进公开镜像）。

4. **再装未编进镜像的插件**

   ```sh
   install-private-packages
   ```

5. **检查**  
   私有插件能打开；OpenVPN 客户端能连；防火墙规则没有明显重复。

不要在现机上对 `kmod-*` 做 `opkg upgrade`。内核只通过刷整包固件更新。

网络起不来时：无配置再刷一次，只手工恢复 `network` / `firewall` / `dhcp` / `dropbear`，然后执行第 4 步，需要的话从备份里取出 OpenVPN 证书。

## 本地试配置（可选）

需要 Linux 或 WSL2，磁盘 50G+：

```sh
./scripts/prepare.sh
cd openwrt
make -j$(nproc)
ls bin/targets/x86/64/*ext4-combined-efi.img.gz
```
