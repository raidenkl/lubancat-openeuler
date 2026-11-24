# 构建说明

## 依赖

- 构建宿主：x86_64，Ubuntu 22.04+（本项目在 20.04 上验证）
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
tools/build-image.sh --board lubancat-5 --stage boot -y
tools/build-image.sh --board lubancat-5 --stage image -y       # 改 overlay 后只重打包
```

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

## 新增一块板卡

1. `scripts/boards/matrix.tsv` 加一行（6 列：family / board / kern_defconfig /
   kern_branch / status / note），`status` 先写 `blocked:<缺什么>`
2. `cp scripts/boards/lubancat-5.conf scripts/boards/<board>.conf`，改这几个变量：
   `dtb_name`、`soc_name`、`local_uboot_dir`、`boot_size`、
   `extboot_generic_dtb` / `extboot_generic_uenv`
3. `scripts/bin/u-boot/<board>/` 放 `u-boot.itb` + `MiniLoaderAll.bin`
   （源码编或从厂商 BSP 取，见 `matrix.tsv` 注释与下节）
4. `scripts/overlay/<board>/` 按板改 `board-init.sh` 的板型映射
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
