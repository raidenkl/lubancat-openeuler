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

> 一键版：`./scripts/init-env.sh`（体检 + 建容器 + 拉源码，幂等）。
> 下面两节是要它做的事，手工排障时看这里。

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
tools/build-image.sh --board lubancat-3 --stage kernel -y      # 只编内核（rootfs 要装它的模块）
tools/build-image.sh --board lubancat-3 --stage rootfs -y      # 只做 rootfs.img
tools/build-image.sh --board lubancat-3 --stage boot -y        # 只打 boot.img（需 kernel+rootfs 就绪）
tools/build-image.sh --board lubancat-5 --stage image -y       # 改 overlay 后只重打包

# 换 SoC / 换板卡之前先清中间产物（否则会复用上一个 SoC 的内核与打包中间件）
tools/build-image.sh --purge         # 清内核/rkpack/rootfs/中间镜像/断点/日志，保留工具链与历史输出
tools/build-image.sh --purge-all     # 同上，并删掉 scripts/build/<日期>/ 的历史输出（不可恢复）
```

**阶段顺序**（`--stage all` 时自动按此排列）：

```
u-boot → 编内核 → rootfs.img → boot.img → 打包镜像
```

不是"编内核就直接打 boot.img"，因为 initrd 必须 chroot 进 **aarch64 rootfs** 生成
（构建容器是 x86_64，宿主 dracut 会打出 x86 的 initramfs，板子上 `/init` 报 ENOEXEC），
而 rootfs 又要装内核模块。`.done` 里对应 `kernel` / `rootfs` / `bootimg` 三个标记。

**一份镜像通 SoC 家族**（`extboot_generic_first=1`，rk3588 家族已开）：

boot 分区里放的是**整个 SoC 家族**的 dtb 与 uEnv（`build_boot.sh` 里 `cp dts/rockchip/*.dtb`），
但上电时只能有一个 `rk-kernel.dtb`。两种选法：

| | 初始 `rk-kernel.dtb` | 换板后果 |
|---|---|---|
| `extboot_generic_first=0`（默认老行为） | 本板 dtb | 换到别的板会拿错设备树，卡在 CPU/外设初始化 |
| `extboot_generic_first=1`（rk3588 家族已开） | `extboot_generic_dtb`（`*-generic.dtb`） | generic 先起来 → board-init 读 SARADC 判定实板 → `ln -sf` 覆盖 `rk-kernel.dtb` 与 `uEnv.txt` → **重启一次** → 进正常系统 |

为什么必须 generic-first：`board-init` 是 **systemd 用户态服务**。初始 dtb 若描述的是另一块板，
内核早期就卡住，用户态永远起不来，也就永远轮不到它去换 dtb —— 死锁。
`extboot_generic_dtb` / `extboot_generic_uenv` 是在 `boards/<board>.conf` 里声明的家族兜底。

代价：每块板**首启多一次重启**（串口能看到 `board-init: name=... dtb=... uenv=...` 后再重启）。
收益：rk3588 家族（Cat-5 / 4 / 4IO 及各 IO 变体）只需维护一份镜像。

**boot 分区里放什么**（extboot 布局，与厂商一致）：

```
/boot/Image-<kernelrelease>     内核（版本化，boot.cmd 用 uEnv 的 uname_r 拼出来）
/boot/System.map-<ver>          调试符号
/boot/config-<ver>              内核配置
/boot/initrd.img                initramfs
/boot/boot.cmd  /boot/boot.scr  U-Boot 启动脚本
/boot/rk-kernel.dtb             当前板卡 dtb（首启后是软链 dtb/<板>.dtb；构建期是普通文件=generic）
/boot/dtb/*.dtb                 全系板卡 dtb
/boot/dtb/overlay/*.dtbo        设备树插件
/boot/uEnv/*.txt                各板卡变量文件（uEnv.txt 首启后软链到实板那份）
/boot/extlinux/extlinux.conf    boot.scr 失效时的兜底配置
```

**换内核**：只放 `Image-<版本>` 一份，`boot.cmd` 按 `uEnv/<板>.txt` 里的 `uname_r`
去加载对应文件。所以

- 想换内核版本：把新 Image 拷成 `/boot/Image-<新版本>`，改 `uname_r`，重启；
- 想回滚：把 `uname_r` 改回旧版本号（旧 Image 没删就能直接回）；
- **不要再往 `/boot/Image` 拷**：那是旧布局的兜底名，只在 `uname_r` 缺失/文件不存在时才会用到。

**板上换内核（rpm）**：`--stage all` 走完会自动产出两个包

```
scripts/bin/rpms/<soc>/kernel-lubancat-<ver>-<rel>.aarch64.rpm           Image/System.map/config/initrd/dtb/dtbo
scripts/bin/rpms/<soc>/kernel-lubancat-modules-<ver>-<rel>.aarch64.rpm   /lib/modules/<kver>
```

**包里刻意不含 `/boot/uEnv/*.txt`**：uEnv 里的 `cmdline="... root=UUID=..."` 是镜像打包时
（`gen_rk_update.sh`）才替换成真实值的，内核包携带它就会把板上正确的 UUID 覆盖成构建期占位值。
实测过一次：装完重启卡在 `A start job is running for /dev/disk/by-uuid/614e0000-...`。
所以 uEnv 归镜像管，`%post` 只就地改里面的 `uname_r` 与 `initrd=` 两行。

代价：**新增的 `dtoverlay=` 启用行不会随内核包下发**（dtbo 文件本身会更新）。
要让新 dtbo 生效，手工在当前 uEnv 里加一行，或等镜像更新：

```sh
T=$(readlink -f /boot/uEnv/uEnv.txt)
echo 'dtoverlay=rk3588s-lubancat-4io-xxx-overlay' >> "$T"
```

单独打：`tools/build-kernel-rpm.sh --soc rk3588`（`--list` 只看会打什么）。
宿主一般没装 `rpm-build`，脚本检测不到 `rpmbuild` 时会自动 `docker exec` 进构建容器执行，
并在结束时把产物属主改回调用者。
**注意它必须排在 bootimg 之后** —— `initrd-<kver>` 是 chroot 进 rootfs 生成的，
打包脚本的前置检查会拦住缺 initrd 的情况。

板上升级（两个包一起装，`Requires` 会校验版本一致）：

```sh
rpm -ivh kernel-lubancat-modules-*.rpm kernel-lubancat-[0-9]*.rpm
reboot && uname -r
```

回滚：编辑当前在用的 `/boot/uEnv/` 实体文件（`uEnv.txt` 是软链，用 `readlink -f` 取），
把 `uname_r` 与 `initrd=` 改回旧版本后重启。`%post` 会保留"当前 + 最近 1 个"共 2 个版本。

装机校验（离线、不用板子）：

```sh
build/check_kernel_rpm.sh --soc rk3588
```

它会验载荷清单、依赖、`/boot` 未挂载时必须拒绝安装，以及把 `boot.img` 挂成 `/boot` 后
在 rootfs 的 overlay 副本上真装一次（检查 `uname_r` 改写、`uEnv.txt` 仍是软链、旧版清理）。

镜像**不预装**这两个包：`/boot` 仍由构建直接灌注，rpm 只作后续升级通道，
避免同一份内核在镜像里存两遍。

**通用屏自动识别**（`enable_gsdt_auto_load`）：`boot.cmd` 已移植厂商那套
「读背板 EEPROM → 叠 `gsdt_plugin0/1`」的逻辑，但构建期默认写 `0`。
要启用就在板子上改 `/boot/uEnv/<板>.txt`：

```sh
sed -i 's/^enable_gsdt_auto_load=.*/enable_gsdt_auto_load=1/' /boot/uEnv/uEnvLubanCat4IO.txt
sync; reboot
```

> 默认关的原因：无屏板子上会多一轮 i2c 扫描噪声，而且"插上就亮"这条路径
> 还没有实机验证过亮屏效果。改回 0 就恢复原行为。

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
  `scripts/bin/rpms/rk3588/`（ISP v30，14 个 iqfiles）。
- conf 在构建期用 `chroot ${rootfs_dir} rpm -ivh --nodeps /opt/rpms/*.rpm` **直接装进 rootfs**，
  装完删掉 rpm 本体并建 `multi-user.target.wants/rkaiq_3A.service` 链接（默认自启）；
  `/opt/rpms` 只在安装失败时留作现场补救
- 不要退回"只把 rpm 放进 /opt/rpms"：那样镜像里 `/etc/iqfiles/` 是空的，ISP 拿不到标定
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
   librknnrt、rkaiq（构建期装进 rootfs）、ttyS2 屏蔽）
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
