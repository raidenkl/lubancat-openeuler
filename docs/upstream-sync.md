# 与上游的关系

## 基线

本仓库第 1 个 commit（`chore: import openEuler SBC-sig @521f1ae as baseline`）
的树与下列上游 commit **完全一致**，不含本项目任何改动：

```
repo   : https://atomgit.com/openeuler/SBC-sig.git
commit : 521f1ae01de979bf4c18d577be2c18cd1f2e9824
license: MulanPSL-2.0
```

因此可以直接对照上游：

```bash
git remote add upstream https://atomgit.com/openeuler/SBC-sig.git
git fetch upstream master --depth=1
git diff --stat upstream/master -- scripts documents
```

因为是「同路径、同文件名」的叠加，diff 的每一条都对应真实内容差异，
不存在路径重写噪声。

## 已知本地偏离

| 路径 | 偏离 | 引入 commit | 原因 |
|---|---|---|---|
| `scripts/build.sh` | 修改 | C2 | 增加 `--layout gpt\|vendor`，默认 vendor；本次：阶段顺序改为 内核 → rootfs → boot.img（initrd 要 chroot 进 rootfs），vendor 布局补写 image 标记；本次：bootimg 之后新增 `kernelrpm` 阶段（打内核双包） |
| `pkg/SPECS/kernel-lubancat.spec` | 新增 | 本次 | 内核启动载荷（Image/map/config/initrd/dtb/dtbo/uEnv）；`%pre` 强制 `/boot` 已挂载 + 空间 >=100 MiB；`%post` 改 `uname_r`/`initrd`（绕开软链）、保留 2 版 |
| `pkg/SPECS/kernel-lubancat-modules.spec` | 新增 | 本次 | `/lib/modules/<kver>`；`%post` 跑 depmod（失败只告警） |
| `tools/build-kernel-rpm.sh` | 新增 | 本次 | 从 `scripts/build/{extboot,kernel}` 取产物打双包；必须带 `--rcfile pkg/rpmrc-aarch64`，否则 x86_64 上 rpmbuild 报 No compatible architectures |
| `build/check_kernel_rpm.sh` | 新增 | 本次 | 离线验收：载荷/依赖、`/boot` 未挂载必须拒绝、overlay+loop 真装一次（软链保持、版本清理） |
| `scripts/build_boot.sh` | 修改 | C2/C11 | 新增 `mk_extboot()`；C11 起才真正从重编判据去掉 `dtb_name`（此前换板仍会全量重编）；本次：新增 --stage kernel|bootimg，供 build.sh 分两次调用；本次：mk_extboot 支持 extboot_generic_first，初始 rk-kernel.dtb/uEnv 用家族 generic；本次：只产 Image-<ver>（不复制 /Image）、extlinux 兜底改版本化内核名 + generic dtb、uEnv 的 size 改 0x8000、rockchip_bootargs 改 ttyFIQ0；本次：initrd 版本化为 `initrd-<kver>`，uEnv 的 `initrd=` 同步 |
| `scripts/configs/common/boot.cmd` | 修改 | 本次 | 内核改为优先 `/Image-<uname_r>`；移植厂商 gsdt 通用屏自动识别（默认关闭）；`dev_bootpart` 提到 overlay 段之前；本次：initrd 三级回退（uEnv 值 -> initrd-<uname_r> -> initrd.img） |
| `scripts/build_rootfs.sh` | 修改 | C2 | 调用 `POST_BOARD_OVERLAY` 钩子；本次：新增 `DESKTOP_QUIRKS` 分派 + `DISABLE_UKUI_POWER_MGMT`（**ukui 专有**）。判定按 rootfs 里是否装了 ukui 的电源管理器，xfce/dde/gnome/headless 不触碰；动作为摘掉 D-Bus 激活文件 + 去掉可执行位，阻止它把 `/sys/class/backlight/*/brightness` 写 0（MIPI 屏因此全黑）；板级开关 `keep_ukui_power_mgmt=1` 可保留原行为；本次：写 `/etc/lubancat/build-host` 标记 |
| `scripts/build_u-boot.sh` | 修改 | 本次 | 复制厂商 u-boot 产物改 `cp -a`：裸 `cp *` 遇到子目录返回非 0，脚本是 `set -e`，会直接中断构建（实测被 `bin/u-boot/lubancat-5/pcie-named/` 触发） |
| `scripts/gen_image.sh` | 修改 | C2 | extboot 布局下替换占位 root UUID |
| `scripts/configs/common/rpmlist` | 修改 | C2 | 补 iw / wireless-regdb / NetworkManager-wifi |
| `scripts/configs/common/extlinux.conf` | 修改 | C2 | 调整启动参数 |
| `scripts/bin/tools/rockchip/rk3588-pack/afptool` | 仅 chmod +x | C2 | 打包工具需可执行 |
| `scripts/bin/tools/rockchip/rk3588-pack/rkImageMaker` | 仅 chmod +x | C2 | 同上 |
| `scripts/gen_rk_update.sh` | 新增/修改 | C3/C11 | vendor 布局出 `update.img`；C11 起 SoC 参数化（loader 前缀 / MINIALL.ini / rkImageMaker 标签） |
| `scripts/mk_initrd.sh` | 新增 | C3 | chroot 内生成 aarch64 initramfs |
| `scripts/boards/lubancat-5.conf` | 新增 | C3 | LubanCat-5 板级配置 |
| `scripts/overlay/lubancat-5/**` | 新增 | C3 | 板型识别服务与脚本；本次 firstboot.sh 首启删除 `/etc/lubancat/build-host` |
| `scripts/configs/common/{boot.cmd,lubancat_linux_rk3588_defconfig,rpmlist-lubancat-desktop}` | 新增 | C3 | 板卡启动脚本 / 内核配置 / 包清单 |
| `scripts/bin/{libmali,multimedia,npu,u-boot/lubancat-5}` | 新增 | C4 | 厂商二进制 |
| `pkg/`、`manifests/`、`docs/`、`build/*.sh` | 新增 | C5/C6 | 打包源、构建溯源与工程文档 |
| `tools/build-image.sh` | 新增 | C11 | 统一构建入口：选 SoC → 选板卡 → 选桌面(ukui/none)，包装 `scripts/build.sh`；本次：预检按 conf 的 local_uboot_dir 找 u-boot（原来按板名硬拼，同族复用会误报） |
| `scripts/boards/matrix.tsv` | 新增 | C11 | 板卡矩阵，新增板卡只改这里一行 |
| `scripts/configs/common/rpmlist-headless` | 新增 | C11 | 无桌面包清单（`rpmlist` 去掉 4 行桌面项） |
| `tests/test-build-image.sh` | 新增 | C11 | 矩阵与入口脚本的静态校验（CI 可跑） |

## 同步上游（按需）

本项目不追求全量跟随上游，只在需要某个上游修复时手工移植：

```bash
git fetch upstream master --depth=1
git show upstream/master:scripts/build_boot.sh > /tmp/up.sh
diff -u scripts/build_boot.sh /tmp/up.sh     # 逐块比对，不要整文件覆盖
```

整文件覆盖会丢掉本项目的适配（extboot 组装、内核复用等）。

## 为什么不 fork 提 PR

上游只接受与板卡无关的通用改动，而本项目的核心内容（板级 conf 含调试账号与
免密配置、81 MB 厂商二进制、私有内核 defconfig）都不适合进上游。
因此本项目作为独立下游维护，通过本文件记录与上游的对应关系。
