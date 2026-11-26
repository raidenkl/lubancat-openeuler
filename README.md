# LubanCat openEuler

**简体中文** | [English](README.en.md)

为 LubanCat（RK3588 / RK3588S / RK3576 / RK3568 / RK3566）系列单板构建
openEuler 24.03 LTS SP3 镜像的构建工程。基于 openEuler SBC-sig 的构建脚本，
采用 Rockchip 厂商 `parameter-extboot` + `update.img` 烧写链路（vendor 布局）。

> 上游血缘：[openEuler SBC-sig](https://atomgit.com/openeuler/SBC-sig) @ `521f1ae`（MulanPSL-2.0）。
> 本项目为独立下游工程，非 openEuler 官方发行版。

> [!WARNING]
> **默认凭据**：本仓库产出的镜像默认用户 `lubancat`、默认口令 `lubancat`，
> `sudo` 免密、桌面自动登录。这是**开发/评测镜像**的便利设定，
> **不可直接用于生产或公网环境**。首次登录后请立即修改口令、移除
> `/etc/sudoers.d/` 下的 NOPASSWD 规则、关闭 autologin。详见
> [docs/security-notes.md](docs/security-notes.md)。

## 板卡支持状态

**以 [scripts/boards/matrix.tsv](scripts/boards/matrix.tsv) 为准**，下表只是摘要：

| 板卡 | SoC | 状态 | 实机验证到哪一步 |
|---|---|---|---|
| LubanCat-5 | RK3588 | ✅ 已支持 | alpha10：ukui 桌面可进；headless 未单独验证 |
| LubanCat-3 | RK3576 | ✅ 已支持 | alpha6（Cat-3 V2）：板型自动识别、千兆网口、主机名、X 桌面、GPU `Mali-G52`（1080p 清屏 ≈1.5 ms/帧、≈680 fps）、3.5mm 耳机有声、NPU 3.3 ms/次、VPU 1080p 编 109 fps / 解 567 fps、摄像头 `imx415` 取帧、rkaiq 3A 已装并自启 |
| LubanCat-4 | RK3588S | ⏳ 待补齐 | 缺 `boards/lubancat-4.conf` 与 u-boot 产物（`soc_name` 要写 `rk3588`） |
| LubanCat-2 | RK3568 | ⏳ 待补齐 | 缺 conf 与 u-boot；`soc_name` 要写 `rk356x` |
| LubanCat-1 | RK3566 | ⏳ 待补齐 | 缺 conf 与 u-boot；`ubootconfig` 用 `rk3566.config` fragment |
| LubanCat-0 | RK3566 | ⏳ 待补齐 | 除 conf/u-boot 外，还需实机标定 SARADC 板型映射 |

“已支持”= 在该板上出过镜像并实机跑通，不是仅编译通过。
`⏳ 待补齐` 的板子在 `tools/build-image.sh` 里会被直接拦下并提示缺什么。

## 快速开始

```bash
git clone git@github.com:raidenkl/lubancat-openeuler.git
cd lubancat-openeuler

# 1) 初始化编译环境（体检 + 拉镜像 + 建容器 + 拉源码；幂等，可重跑）
./scripts/init-env.sh

# 2) 出镜像（--dry-run -V 可先只看将执行的命令）
tools/build-image.sh --board lubancat-3 --desktop ukui -y

# 3) 产物在 scripts/build/<日期>/ 下，.img.xz 用 RKDevTool / upgrade_tool 烧写
```

只看有哪些板子：`tools/build-image.sh --list`。

详细构建参数见 [docs/building.md](docs/building.md)，发布流程见 [docs/release.md](docs/release.md)。

## 编译环境准备

### 宿主要求

| 项 | 要求 | 说明 |
|---|---|---|
| 架构 | **x86_64** | 目标镜像是 aarch64，靠 qemu-user binfmt 在容器里跑 |
| 系统 | Ubuntu 22.04 LTS（实测 22.04.3） | 其他发行版只要提供同等的 docker 与 binfmt 也可 |
| CPU / 内存 | ≥ 8 核 / ≥ 16 GiB（实测 64 核 / 62 GiB） | 内核与 rootfs 阶段在容器里跑，核多明显快 |
| 磁盘 | **≥ 120 GiB 空闲** | `scripts/build/` 单次全量构建占 30–40 GiB |
| 网络 | 首次需联网 | 容器镜像约 200 MB，五个源码仓 5–10 GiB |
| docker | 20.10+（实测 27.1.1），当前用户在 `docker` 组 | rootfs/initrd/打包阶段都在容器里做 |
| binfmt | 已注册 `qemu-aarch64` | `ls /proc/sys/fs/binfmt_misc/qemu-aarch64` |

宿主**不需要 root 跑构建**：u-boot 在宿主原生编（不 mount 不 chroot），
需要 mount/chroot 的阶段一律回容器。

### 一键初始化

```bash
./scripts/init-env.sh                # 体检 → 拉基础镜像 → 建构建容器 → 拉源码
./scripts/init-env.sh --check        # 只体检，不改任何东西（CI/排障用）
./scripts/init-env.sh --skip-fetch   # 源码已拉过，只保证容器就绪
./scripts/init-env.sh --recreate     # 仓库换了路径，删掉旧容器重建
./scripts/init-env.sh --install-deps # 缺的 apt 包直接装（会调 sudo，显式 opt-in）
./scripts/init-env.sh --fix-perms    # 宿主编 u-boot 报「scripts/build 不可写」时修属主
```

脚本默认**不 sudo、不改 `/etc/docker/daemon.json`**，只报告缺什么并给出命令；
`--check` 模式下没有任何写操作。

<details>
<summary><b>手工分步（等价于 init-env.sh，点开）</b></summary>

**1. 装宿主依赖**

```bash
# 硬依赖：拉源码、算校验用
sudo apt-get install -y git curl coreutils tar gzip

# 宿主 u-boot 源码编需要（build-image.sh 默认 --uboot-env host）
sudo apt-get install -y python2 make gcc bc bison flex device-tree-compiler cpio
```

> `python2` 是 Rockchip `u-boot/make.sh` 的硬依赖（脚本里写死 `PYTHON=python2`），
> openEuler 24.03 容器里没有 py2，所以这一步在宿主做。
> 装不了 python2 时用预编译 u-boot（`build_uboot_from_src=0`）或 `--uboot-env container` 绕过。

**2. docker 与 aarch64 binfmt**

```bash
sudo usermod -aG docker "$USER"        # 之后要重新登录
sudo apt-get install -y qemu-user-static binfmt-support
ls /proc/sys/fs/binfmt_misc/qemu-aarch64   # 应显示 enabled
```

binfmt 没注册时，容器里连 `uname` 都跑不起来，表现为 `exec format error`。
另一种注册方式：

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

**3. 建构建容器**

```bash
docker run -d --name oe-lubancat-build --platform linux/arm64 --privileged \
  -v "$PWD:$PWD" -w "$PWD" \
  openeuler/openeuler:24.03-lts-sp3 sleep infinity

docker exec oe-lubancat-build uname -m     # 期望 aarch64
```

两个细节：

- **仓库挂到容器里的同路径**（`-v "$PWD:$PWD"`）。`tools/build-image.sh` 会从容器挂载表
  反查“本仓库在容器里是哪个目录”，所以克隆到任意路径都能用；只有老工作区
  （父目录挂到 `/work`、仓库在 `/work/src/SBC-sig`）才走兼容回退。
- 容器是**常驻**的（`sleep infinity`），不是 `--rm`。构建分 u-boot / kernel / boot /
  rootfs / image 几个阶段，后续阶段都要 `docker exec` 复用同一个容器。

**4. 拉源码**

```bash
./scripts/fetch-sources.sh            # 按 manifests/source-lock.yaml 的 SHA 拉 5 个仓到 src/
./scripts/fetch-sources.sh --check    # 只校验本地 SHA 是否与锁文件一致
```

锁文件固定了内核 `6.1.99`、u-boot `2017.09`、rkbin、openEuler SBC-sig 与上游内核
五个仓的提交，构建可复现。`src/` 不进 git（见 `.gitignore`）。

</details>

### 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `exec format error` / 容器里 `uname -m` 报错 | 宿主没注册 binfmt | 见上方第 2 步 |
| `permission denied ... Docker daemon` | 用户不在 `docker` 组 | `sudo usermod -aG docker $USER` 后重新登录 |
| `docker pull` 卡住 | Docker Hub 直连慢 | 配镜像加速，或 `docker load` 离线包 |
| `scripts/build 不可写`（宿主编 u-boot） | 目录被容器内 root 写过 | `./scripts/init-env.sh --fix-perms` |
| 构建末尾 `No space left on device` | 磁盘不足 | 清 `scripts/build/` 或换 ≥120 GiB 的盘 |
| 「检测到 build/ 下有残留挂载」 | 上次构建异常退出 | `mount \| grep scripts/build` 后 `umount`，再 `losetup -d` |

## 仓库结构

```
scripts/            上游构建脚本 + 本项目适配（build.sh / gen_rk_update.sh / mk_initrd.sh）
scripts/init-env.sh 编译环境初始化（体检 / 容器 / 源码）
scripts/bin/        工具、固件、厂商二进制（libmali / npu / multimedia / u-boot）
scripts/boards/     板级配置（每块板一个 .conf，含 POST_BOARD_OVERLAY）+ matrix.tsv
scripts/configs/    包清单、内核 defconfig、boot.cmd、extlinux
scripts/overlay/    rootfs 覆盖层（板型识别、音频/相机服务单元、X11 配置）
tools/              构建入口（build-image.sh 一键出镜像、build-rpms.sh 打 rkaiq 包）
pkg/                RPM 打包源（SPECS + SOURCES，目前为 camera-engine-rkaiq）
manifests/          构建溯源：source-lock、各版本摘要、校验和
docs/               本项目的工程文档（与上游 documents/ 区分）
build/              本地构建辅助脚本与板端测试程序（产物不入库）
src/                上游源码仓（fetch-sources.sh 生成，不进 git）
```

## 与上游的关系

- 仓库第 1 个 commit 是 **openEuler SBC-sig @521f1ae 的原始树**，未含本项目任何改动，
  因此 `git diff` 可零噪声对照上游。
- 我们的适配从第 2 个 commit 起，逐条记录在 [docs/upstream-sync.md](docs/upstream-sync.md)。
- 本工程**不向上游提 PR**，仅作为独立下游维护。

## 已知限制

- 一张 SD/eMMC 卡**不能跨 SoC 通用**：loader 与 dtb 绑定 SoC，只能同族通用
  （RK3588+RK3588S、RK3566+RK3568）。
- 本工程自行生成 `parameter.txt`（boot 分区 256 MiB），**严禁与原厂 parameter 交叉烧写**。
- **桌面走 mesa/llvmpipe 软件渲染**：X11 没有 Mali 的 DRI2/GLX 集成，属预期。
  GPU 本身可用（`Mali-G52` / OpenGL ES 3.2，1080p 清屏 ≈680 fps），但要经 GBM 平台
  使用，例如 `mali-env <程序>`；桌面级 GPU 加速要另做 Wayland 或给 X 提供 Mali GLX，
  不在当前范围。
- 摄像头 3A（rkaiq）已装进镜像本体（`rkaiq_3A_server` + `/etc/iqfiles/`），
  `rkaiq_3A.service` 默认启用；没接摄像头时该服务会退出并在 5 次后进 failed，属预期。
- 摄像头默认不启用：`/boot/uEnv/uEnv.txt` 里的 dtoverlay 是注释态，要手工打开。
- 只在 x86_64 宿主 + docker 下验证过；原生 aarch64 宿主理论上可用，未验证。

## License

本项目整体遵循 MulanPSL-2.0（见 [LICENSE](LICENSE)）。
`scripts/`、`documents/` 等源自 openEuler SBC-sig @521f1ae，同为 MulanPSL-2.0；
对其的修改见 [NOTICE](NOTICE) 与 git 历史。仓库内捆绑的第三方二进制遵循各自原始许可，
见 [docs/third-party.md](docs/third-party.md)。
