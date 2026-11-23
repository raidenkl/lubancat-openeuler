# 第三方组件与许可

本仓库捆绑了若干第三方二进制。**再分发前请自行核对原始许可**，下表是当前认知，
不构成法律意见。

| 组件 | 路径 | 来源 | 许可状态 | 备注 |
|---|---|---|---|---|
| libmali (Mali-G610 g24p0) | `scripts/bin/libmali/mali-g610-g24p0.tar.gz` | Rockchip / LubanCat SDK（`debian12/packages/arm64/libmali/`） | ARM 专有 blob，随 SoC 厂商 SDK 分发 | 通常允许随搭载该 SoC 的产品分发；**禁止反向工程**。公开再分发前请确认条款 |
| librkaiq（ISP 3A） | `pkg/SOURCES/camera-engine-rkaiq/`、`scripts/bin/rpms/*.rpm`（不入库） | Rockchip camera_engine_rkaiq v6.9.0 | Rockchip 专有 | 含 `librkaiq.a` 静态库 |
| librknnrt（NPU 运行时） | `scripts/bin/npu/librknnrt.so` | Rockchip rknpu2 | Rockchip 专有 | 版本 2.3.0 / driver 0.9.8 |
| librockchip_mpp / librga | `scripts/bin/multimedia/` | Rockchip MPP 1.5.0 / RGA 2.1.0 | 开源（Apache-2.0 / BSD 类）为主，需核对具体版本 | gst 插件为本项目源码编译（gstreamer 1.22.5） |
| linux-firmware | `scripts/bin/linux-firmware/` | 上游 linux-firmware | 混合：GPL/BSD/专有固件许可 | 各文件许可见其目录内 `LICENCE.*` |
| u-boot 预编译产物 | `scripts/bin/u-boot/` | LubanCat / 上游 u-boot (GPL-2.0) 编译 | GPL-2.0（二进制分发需提供对应源码） | 对应源码 SHA 见 `manifests/source-lock.yaml` |
| afptool / rkImageMaker | `scripts/bin/tools/rockchip/` | Rockchip 打包工具 | Rockchip 专有 | 仅用于生成 update.img |
| openEuler 构建脚本 | `scripts/`、`documents/` | openEuler SBC-sig @521f1ae | MulanPSL-2.0 | 见 `LICENSE` |

## 合规要点

1. `LICENSE` 保持 MulanPSL-2.0 原文，不整体替换。
2. 本项目新增文件带 SPDX 头；上游已有文件不加（避免污染上游 diff）。
3. 分发 u-boot / 内核二进制时，应同时提供或指向对应源码（GPL-2.0 要求），
   `manifests/source-lock.yaml` 中的 commit 即为对应版本。
4. Rockchip 专有 blob 的再分发边界由厂商 SDK 许可决定；若不确定，
   把对应文件移到 Release 私有附件，或改为文档说明获取方式。
