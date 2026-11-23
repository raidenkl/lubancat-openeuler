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

## 构建

```bash
sudo ./scripts/build.sh \
  -b lubancat-5 \
  -s "$PWD/scripts/configs/common/rpmlist-lubancat-desktop"
```

关键点：

- `-s` 必须传**文件完整路径**。`build_rootfs.sh` 的白名单只认
  `headless/xfce/ukui/dde/gnome/devstation`，`lubancat-desktop` 不在其中。
- 默认 `--layout vendor`（走 `gen_rk_update.sh`，产出可 `upgrade_tool` 烧写的 `update.img`）。
  需要通用 GPT 布局时加 `--layout gpt`。
- 构建产物：`scripts/build/<YYYY-MM-DD>/<name>.img.xz` 与其 `.sha256sum`。

## 只重打镜像（复用已有 rootfs）

```bash
cd scripts
sudo bash gen_rk_update.sh -n <镜像名> -b lubancat-5
```

注意：`rootfs.img` 若被残留 loop 挂载占用，第二次挂载会变成只读并导致打包失败。
打包前先 `mount | grep rootfs` 清理。

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
| `scripts/build/` | 构建中间产物，**不入库** |
| `scripts/bin/` | 工具与厂商二进制，入库 |
| `pkg/SOURCES/` | RPM 打包源（vendor 解包，入库） |
| `manifests/` | 构建溯源，入库 |
