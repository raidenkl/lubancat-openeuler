# 构建说明

## 依赖

- 构建宿主：x86_64，Ubuntu 22.04+（本项目在 20.04 上验证）
- **宿主侧的 u-boot 编译依赖**（`--uboot-env host`，默认路径）：`python2`、`make`、
  `gcc`、`bc`、`bison`、`flex`、`dtc`、`cpio`。Ubuntu 22.04 上
  `apt-get install -y python2 make gcc bc bison flex device-tree-compiler cpio`
  即可；缺哪一项脚本会在 preflight 里直接点名。
- 宿主**不需要** root：u-boot 编译不 mount、不 chroot。反过来，任何需要
  mount/chroot 的阶段（rootfs、initrd、打包）一律在容器里跑。
- 容器：`openeuler/openeuler:24.03-lts-sp3`（`dnf` 装包与 rpmbuild 都在容器内完成）
- 磁盘：≥ 120 GB 空闲（`scripts/build/` 单次构建可占 30–40 GB）
- 网络：首次需拉源码仓与 openEuler 源；离线构建见下文

## 首次准备

```bash
./scripts/fetch-sources.sh            # 按 manifests/source-lock.yaml 拉 5 个仓
./scripts/fetch-sources.sh --check    # 仅校验本地 SHA 是否与 lock 一致
```

`fetch-sources.sh` 会把仓库放到 `src/` 下，并按 `clone_depth` 使用浅克隆。
若上游服务器不允许按 SHA fetch，脚本会自动降级为「先拉分支再 checkout」。

## 推荐入口：`tools/build-image.sh`

选了 SoC 家族 → 板卡 → 桌面，一条命令出镜像。板卡清单来自
`scripts/boards/matrix.tsv`，新增板卡只需在那里加一行。

```bash
tools/build-image.sh                      # 交互菜单：SoC → 板卡 → 桌面(ukui/none) → 确认
tools/build-image.sh --list               # 看矩阵（含每块板的状态）
tools/build-image.sh --soc rk356x --list  # 只看某个 SoC 家族

# 非交互（CI / 批量）
tools/build-image.sh --board lubancat-5 --desktop ukui -y
tools/build-image.sh --board lubancat-5 --desktop none -y      # 无桌面
tools/build-image.sh --board lubancat-5 --dry-run -V           # 只打印将执行的命令

# 分步
tools/build-image.sh --board lubancat-3 --stage uboot -y       # 只编 u-boot（宿主编）
tools/build-image.sh --board lubancat-3 --stage kernel -y      # 只编内核 + boot.img
tools/build-image.sh --board lubancat-5 --stage boot -y
tools/build-image.sh --board lubancat-5 --stage image -y       # 改 overlay 后只重打包
```

**宿主 / 容器分工**（v0.7 起）：

| 阶段 | 在哪跑 | 原因 |
| --- | --- | --- |
| u-boot 源码编 | **宿主**（`--uboot-env host`，默认） | Rockchip 的 `make.sh` 固定 `PYTHON=python2`，容器（openEuler 24.03）没有 python2；宿主原生 2.7 |
| 内核 + boot.img | 容器 | 需要 initrd（chroot 进 aarch64 rootfs） |
| rootfs / 打包 | 容器 | 需要 root、mount、loop |

`--uboot-env container` 保留给「已在容器里装好 python2」或只想用预编译 u-boot 的场合。
预编译路线（`build_uboot_from_src=0`）完全不受影响。

**u-boot 源码编的两个硬约束**（否则编出来的 u-boot 开不了机）：

1. `rk3576_defconfig` 等 Rockchip defconfig **都没有** `CONFIG_CMD_EXT4/CMD_FS_GENERIC/
   CMD_PART/EFI_PARTITION`，Kconfig 里也没有默认值。本项目用
   `scripts/configs/u-boot/distro-boot.config` 这份 fragment 在 defconfig 之后叠加
   （`make <defconfig> <frag>` + `olddefconfig`），缺了就是 `Unknown command 'load'`，
   读不到 `boot.scr`。
2. **不能给 `make.sh` 传板名**——它会重跑 `make <board>_defconfig` 把 fragment 冲掉。
   正确姿势是先 `make defconfig + fragment`，再 `./make.sh`（不带板名，用现有 `.config`），
   最后 `./make.sh loader` 生成 loader。

u-boot 用 EVB 的 u-boot 设备树（`rk3576_defconfig`）是**正确**的：extboot 方式下
内核 DTB 由 `boot.scr` 自己加载，u-boot 的 DT 只服务它自己的驱动，而
`arch/arm/dts/rk3576-u-boot.dtsi` 已在 SoC 级配好 `&sdhci`（8bit/HS400）。

要点：

- **桌面只有 `ukui` / `none` 两档**。`none` 走 `rpmlist-headless`，镜像里不含
  UKUI/lightdm；**不要**用 `-s headless`，那个词在 `build_rootfs.sh:178` 是空操作，
  出来的镜像仍然带桌面。
- 镜像名默认 `openEuler-24.03-LTS-SP3-<Board>-aarch64-<ukui|headless>-<version>-<日期>`，
  可用 `-n` 覆盖。
- 切换板卡时脚本会自动清 `build/.done`、`build/boot.img`，避免把上一块板的
  boot 打进新镜像。
- 非交互环境下不给 `--board` 会直接 `exit 2`（不会挂起等输入）。

## 直接调用底层脚本（排障时用）

```bash
sudo ./scripts/build.sh \
  --board lubancat-5 \
  -c lubancat_linux_rk3588_defconfig \
  -b lubancat-5 \
  -s "$PWD/scripts/configs/common/rpmlist-lubancat-desktop" \
  --layout vendor
```

关键点：

- `--board` 才选板卡；**`-b` 是内核分支，不是板卡**（早期文档写成 `-b lubancat-5`
  会把分支设成 `lubancat-5` 而板卡仍是默认值）。
- `-s` 必须传**文件完整路径**。`build_rootfs.sh` 的白名单只认
  `headless/xfce/ukui/dde/gnome/devstation`，`lubancat-desktop` 不在其中。
- 默认 `--layout vendor`（走 `gen_rk_update.sh`，产出可 `upgrade_tool` 烧写的 `update.img`）。
  需要通用 GPT 布局时加 `--layout gpt`。
- 构建产物：`scripts/build/<YYYY-MM-DD>/<name>.img.xz` 与其 `.sha256sum`。

## 只重打镜像（复用已有 rootfs）

```bash
# 推荐
tools/build-image.sh --board lubancat-5 --stage image -y

# 等价底层命令
cd scripts && sudo bash gen_rk_update.sh -n <镜像名> -b lubancat-5
```

注意：`rootfs.img` 若被残留 loop 挂载占用，第二次挂载会变成只读并导致打包失败
（`source write-protected`）。打包前先 `mount | grep rootfs` 清理。

## 构建预置 rpm（rkaiq 3A）

`scripts/bin/rpms/<soc>/*.rpm` 是**构建产物**（不入 git），由 `pkg/SPECS` + `pkg/SOURCES`
在容器里 rpmbuild 出来。新克隆第一次出镜像前跑一次：

```bash
tools/build-rpms.sh --list                 # 看会构建哪些包、落到哪个 SoC 目录
tools/build-rpms.sh                        # 全部构建
tools/build-rpms.sh camera-engine-rkaiq-rk3576   # 只构建一个
```

- 输出：`scripts/bin/rpms/rk3576/`（ISP v39，12 个 iqfiles）与
  `scripts/bin/rpms/rk3588/`（ISP v30，14 个 iqfiles），供 conf 预置到镜像 `/opt/rpms`
- 交叉打包靠 `pkg/rpmrc-aarch64` 里的 `buildarch_compat: x86_64: aarch64`
  （没有这行，x86_64 容器会报 `No compatible architectures found for build`）

## 新增一块板卡

1. `scripts/boards/matrix.tsv` 加一行（6 列：family / board / kern_defconfig /
   kern_branch / status / note），`status` 先写 `blocked:<缺什么>`
2. `cp scripts/boards/lubancat-5.conf scripts/boards/<board>.conf`，改这几个变量：
   `dtb_name`、`soc_name`、`local_uboot_dir`、`boot_size`、
   `extboot_generic_dtb` / `extboot_generic_uenv`
3. `scripts/bin/u-boot/<board>/` 放 `u-boot.itb` + `MiniLoaderAll.bin`
   （源码编或从厂商 BSP 取，见 `matrix.tsv` 注释与下节）
4. **板型识别不用复制**：`scripts/overlay/common/usr/libexec/lubancat/board-init.sh`
   全系共用一份，映射表移植自厂商 `debian12/overlay/etc/init.d/boot_init.sh`。
   新板在表里已有条目就只改 conf 的两行 install 指向 `${ov}/common/...`；
   表里没有才回去补，补之前先对照厂商原文件。离线验证（不需要板子）：
   `bash build/board-init-selftest.sh scripts/overlay/common/usr/libexec/lubancat/board-init.sh`
5. 逐段核对 `POST_BOARD_OVERLAY` 里与 SoC 绑定的部分（libmali G610/G52、
   librknnrt、rkaiq、`/opt/rpms`、ttyS2 屏蔽）
6. `tools/build-image.sh --list` 确认出现，`--dry-run -V` 确认参数
7. `--stage uboot → boot → rootfs → image` 分段跑，烧写验收后把 `status` 改成 `verified`

`matrix.tsv` 里**不重复** `dtb_name` / `soc_name` / `boot_size` 等取值 ——
它们只以 `boards/<board>.conf` 为准，避免两处漂移。

**易错点**：`uEnv/` 只有 `rk356x`、`rk3576`、`rk3588` 三个 SoC 目录，所以
Cat-0/1/2 的 `soc_name` 必须写 `rk356x`，Cat-4（RK3588S）必须写 `rk3588`；
写错不会报错，`build_boot.sh:282` 的 `cp ... || true` 会静默漏拷 uEnv，首启黑屏。

### u-boot 配置怎么选

`u-boot/configs/` 下有两套，**只用 Rockchip 官方那套**：

| SoC | 配置 | 说明 |
|---|---|---|
| RK3566 | `rk3566.config` | **fragment**，2 行：`CONFIG_BASE_DEFCONFIG="rk3568_defconfig"` + `CONFIG_LOADER_INI="RK3566MINIALL.ini"` |
| RK3568 | `rk3568_defconfig` | 完整 defconfig |
| RK3576 | `rk3576_defconfig` | 完整 defconfig |
| RK3588 / RK3588S | `rk3588_defconfig` | 完整 defconfig |

`lubancat-*_defconfig` 六个是野火早期加的，没被任何 conf 引用，不要用。

`rk3566.config` 是 fragment，必须「先 `make rk3568_defconfig`，再用
`scripts/sync-fragment.sh` 叠加」；当前 `build_u-boot.sh:110` 是裸 `make ${ubootconfig}`，
**源码编 RK3566 前要先补这段 fragment 处理**，否则配置会落回 rk3568 而缺 3566 项。
走预编译 `bin/u-boot/<board>/` 则不受影响（`ubootconfig` 留空即可）。

## 烧写

```bash
xz -dk <name>.img.xz
upgrade_tool uf <name>.img          # 或 RKDevTool（MaskRom 模式）
```

**vendor 布局不能用 `dd`**，也不能与原厂 parameter 交叉烧写（分区表不同）。

## 离线构建

`src/` 与镜像产物都不入库。需要在无外网环境构建时，提前在一台有网机器上执行
`fetch-sources.sh` 并把 `src/` 打包带过去；`pkg/SOURCES/` 与 `scripts/bin/` 已在仓库内，
不需要额外下载。

## 目录约定

| 路径 | 说明 |
|---|---|
| `tools/build-image.sh` | 统一构建入口（菜单 + 参数） |
| `scripts/boards/matrix.tsv` | 板卡矩阵（SoC → 板卡 → 内核配置 → 状态） |
| `scripts/build/` | 构建中间产物，**不入库** |
| `scripts/bin/` | 工具与厂商二进制，入库 |
| `pkg/SOURCES/` | RPM 打包源（vendor 解包，入库） |
| `manifests/` | 构建溯源，入库 |
