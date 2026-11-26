# LubanCat openEuler

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

| 板卡 | SoC | 状态 | 镜像布局 |
|---|---|---|---|
| LubanCat-5 | RK3588 | **已支持**（v0.6.0-alpha6 实机验证） | vendor / gpt |
| LubanCat-4 | RK3588S | 计划中 | vendor |
| LubanCat-3 | RK3576 | 计划中 | vendor |
| LubanCat-2 | RK3568 | 计划中 | vendor |
| LubanCat-1 | RK3566 | 计划中 | vendor |
| LubanCat-0 | RK3566 | 计划中（需实机标定 SARADC 板型） | vendor |

## 快速开始

```bash
git clone git@github.com:raidenkl/lubancat-openeuler.git
cd lubancat-openeuler

# 1) 拉取内核 / u-boot / rkbin / SBC-sig 源码（按 manifests/source-lock.yaml 的 SHA）
./scripts/fetch-sources.sh

# 2) 构建（以 LubanCat-5 为例）
sudo ./scripts/build.sh -b lubancat-5 -s "$PWD/scripts/configs/common/rpmlist-lubancat-desktop"

# 3) 产物在 scripts/build/<日期>/ 下，.img.xz 可直接用 upgrade_tool / RKDevTool 烧写
```

详细说明见 [docs/building.md](docs/building.md)；发布流程见 [docs/release.md](docs/release.md)。

## 仓库结构

```
scripts/            上游构建脚本 + 本项目适配（build.sh / gen_rk_update.sh / mk_initrd.sh）
scripts/bin/        工具、固件、厂商二进制（libmali / npu / multimedia / u-boot）
scripts/boards/     板级配置（每块板一个 .conf，含 POST_BOARD_OVERLAY）
scripts/configs/    包清单、内核 defconfig、boot.cmd、extlinux
scripts/overlay/    rootfs 覆盖层（板型识别、服务单元）
pkg/                RPM 打包源（SPECS + SOURCES，目前为 camera-engine-rkaiq）
manifests/          构建溯源：source-lock、各版本摘要、校验和
docs/               本项目的工程文档（与上游 documents/ 区分）
build/              本地构建辅助脚本（产物不入库）
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
- 桌面走 mesa/llvmpipe 软件渲染；需要 GPU 的应用用 `mali-env` 启动。
- 摄像头 3A（rkaiq）已装进镜像本体（`rkaiq_3A_server` + `/etc/iqfiles/`），
  `rkaiq_3A.service` 默认启用；没接摄像头时该服务会退出并在 5 次后进 failed，属预期。

## License

本项目整体遵循 MulanPSL-2.0（见 [LICENSE](LICENSE)）。
`scripts/`、`documents/` 等源自 openEuler SBC-sig @521f1ae，同为 MulanPSL-2.0；
对其的修改见 [NOTICE](NOTICE) 与 git 历史。仓库内捆绑的第三方二进制遵循各自原始许可，
见 [docs/third-party.md](docs/third-party.md)。
