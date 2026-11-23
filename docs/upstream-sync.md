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
| `scripts/build.sh` | 修改 | C2 | 增加 `--layout gpt\|vendor`，默认 vendor |
| `scripts/build_boot.sh` | 修改 | C2 | 新增 `mk_extboot()`；内核复用（`dtb_name` 变化不重编） |
| `scripts/build_rootfs.sh` | 修改 | C2 | 调用 `POST_BOARD_OVERLAY` 钩子 |
| `scripts/gen_image.sh` | 修改 | C2 | extboot 布局下替换占位 root UUID |
| `scripts/configs/common/rpmlist` | 修改 | C2 | 补 iw / wireless-regdb / NetworkManager-wifi |
| `scripts/configs/common/extlinux.conf` | 修改 | C2 | 调整启动参数 |
| `scripts/bin/tools/rockchip/rk3588-pack/afptool` | 仅 chmod +x | C2 | 打包工具需可执行 |
| `scripts/bin/tools/rockchip/rk3588-pack/rkImageMaker` | 仅 chmod +x | C2 | 同上 |
| `scripts/gen_rk_update.sh` | 新增 | C3 | vendor 布局出 `update.img` |
| `scripts/mk_initrd.sh` | 新增 | C3 | chroot 内生成 aarch64 initramfs |
| `scripts/boards/lubancat-5.conf` | 新增 | C3 | LubanCat-5 板级配置 |
| `scripts/overlay/lubancat-5/**` | 新增 | C3 | 板型识别服务与脚本 |
| `scripts/configs/common/{boot.cmd,lubancat_linux_rk3588_defconfig,rpmlist-lubancat-desktop}` | 新增 | C3 | 板卡启动脚本 / 内核配置 / 包清单 |
| `scripts/bin/{libmali,multimedia,npu,u-boot/lubancat-5}` | 新增 | C4 | 厂商二进制 |
| `pkg/`、`manifests/`、`docs/`、`build/*.sh` | 新增 | C5/C6 | 打包源、构建溯源与工程文档 |

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
