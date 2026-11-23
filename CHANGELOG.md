# Changelog

本文件记录镜像与构建工程的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 SemVer（预发布阶段 `0.x`）。

镜像命名与 tag 逐字符对应：`<board>_openEuler-24.03-LTS_aarch64_<tag>.img.xz`。

## [Unreleased]

### Planned
- LubanCat-4（RK3588S）板级支持：`gen_rk_update.sh` 参数化、`soc_name` 拆为 family/model
- LubanCat-3（RK3576）：新增 rk3576 内核与 u-boot 构建
- LubanCat-2 / 1（RK3568 / RK3566）：共用 rk356x 内核，补 Mali-G52 libmali
- LubanCat-0：实机标定 SARADC 板型映射

## [v0.6.0-alpha6] - 2026-11-23

首个公开发布。LubanCat-5（RK3588），vendor 布局，实机验证。

### 镜像
- `lubancat-5_openEuler-24.03-LTS_aarch64_v0.6.0-alpha6.img.xz`
- 大小 `2,071,434,436 B`（1.929 GiB）
- sha256 `7b235c5b61ef38caff2d0aac8fb4b46cfc6082f082214b64af29a11399793518`
- 根文件系统 UUID `6f1c2a10-4b3e-4d55-9c8a-2f5d0b7e1a01`

### Added
- 板级配置 `scripts/boards/lubancat-5.conf`（含 `POST_BOARD_OVERLAY`：调试账号、
  libmali 解包、光标主题、autologin、NPU 运行时、多媒体资产、`/opt/rpms` 预置）
- 厂商布局出包 `scripts/gen_rk_update.sh`（`update.img`，`afptool` + `rkImageMaker` 双向自校验）
- `scripts/mk_initrd.sh`：chroot 内生成 aarch64 initramfs
- 多媒体栈：librga 2.1.0、librockchip_mpp 1.5.0、MPP demos、源码编译的
  `libgstrockchipmpp.so` / `libgstrkximage.so`（对齐板卡 gstreamer 1.22.5）、
  `99-rockchip-permissions.rules`
- NPU 运行时 `librknnrt.so`（7.0 MB，实机 `rknn_run` 4.66 ms）
- `camera-engine-rkaiq` RPM（20 文件 / 14 个 IQ，含 IMX415 标定）
- 构建溯源 `manifests/`（source-lock、alpha1–6 摘要、校验和）

### Changed
- `build.sh` 增加 `--layout gpt|vendor` 分派，默认 `vendor`
- `build_boot.sh` 增加 `mk_extboot()`，`bootmode=extboot` 时组装 uEnv+dtb+ext2 boot.img
- `gen_image.sh` 在 extboot 布局下替换占位 root UUID
- 内核在仅 `dtb_name` 变化时复用构建树（不再 `make distclean`）

### Verified
- GPU：`GL_RENDERER=Mali-G610`，OpenGL ES 3.2 v1.g24p0，512×512 离屏渲染
  50000 帧 1346.7 ms（0.027 ms/帧），DVFS 300 MHz→1 GHz
- VPU：1080p H.264 编码 174.85 fps，解码 823.43 fps，`mppvideodec` 到 EOS
- NPU：resnet18 推理 4.66 ms
- 摄像头：IMX415 + rkaiq 3A，AE 收敛 Y 41→104.8，U/V 129.5/124.9
- 桌面：1920×1080，任务栏/光标/自动登录正常

### Known Issues
- 摄像头画面上下颠倒（sensor 安装方向），需取流端 rotate 或改 DTS
- HDMI 音频无 ELD 上报（当前显示器不含音频 sink）
- `/`、`/etc`、`/usr` 曾被 libmali tar 的目录条目改成 uid 1000 + 775（提权风险），
  **后续版本修复前不要用于生产**
- 无 swap/zram；CPU governor 固定 performance，空载也满频

## 历史构建（工程内部编号，未打 tag）

| 内部版本 | 说明 |
|---|---|
| alpha1–alpha3 | 首次打通 vendor 布局；alpha3 桌面未装完（镜像早于 UKUI 安装完成） |
| alpha4 | 首个真正带完整 UKUI 与 299 个内核模块的镜像；修复内核模块缺失根因 |
| alpha5 | 固化 mali hook、光标主题、autologin、librknnrt、无线工具包 |
| alpha6 | 固化多媒体三件套与 3A RPM 预置（本版） |
