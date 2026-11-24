# Changelog

本文件记录镜像与构建工程的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 SemVer（预发布阶段 `0.x`）。

镜像命名与 tag 逐字符对应：`<board>_openEuler-24.03-LTS_aarch64_<tag>.img.xz`。

## [Unreleased]（alpha9，未打 tag）

### Fixed
- **P0-1 系统目录属主污染**：libmali tar 改为 root 属主 + 无目录条目重打包；
  解包加 `--no-same-owner`；overlay 末尾对 `/ /etc /usr /usr/lib
  /usr/lib/firmware /usr/lib64 /etc/OpenCL /etc/ld.so.conf.d` 做属主兜底并断言
- **P0-2 桌面用户加入 video 组**（/dev/mali0、/dev/rga、/dev/mpp_service 可用）
- **P0-3 首启唯一性**：machine-id 截断、SSH 主机密钥删除（sshd-keygen@ 实例
  显式 enable）、新增 lubancat-firstboot.service 生成唯一主机名
- **P0-4 根分区自动扩容**：lubancat-growfs.service 只做在线 `resize2fs`，
  目标尺寸取自 `/sys/class/block/<part>/size`，**绝不改分区表**；不写 marker，
  每次启动比对块数，相等即退出（幂等）
- **P0-6 镜像卫生**：dnf 缓存 / /tmp 清理、补 /var/log/lastlog、ldconfig

### Fixed（alpha7 → alpha9 回归）
- **alpha7 装完无法启动（`bad geometry`）**：alpha7 的 `lubancat-resize.service`
  用 `parted resizepart 100%` 把分区定义到盘尾，比加载器留出的边界多 1984 扇区
  （992 KiB）；`resize2fs` 按这个尺寸扩完后，下次启动加载器按 `parameter.txt`
  重算 GPT 把分区收回，于是文件系统永远比分区大 248 块：

  ```
  EXT4-fs (mmcblk0p3): bad geometry: block count 30466040
      exceeds size of device (30465792 blocks)
  ```

  根分区挂不上，只能进 dracut emergency。已删除该服务并改为只 `resize2fs`；
  串口恢复步骤见 `docs/troubleshooting.md`。


### Changed
- rpmlist 增加 v4l-utils / i2c-tools / usbutils / gstreamer1-plugins-bad-free
- boards/lubancat-5.conf 默认口令参数化（LUBANCAT_DEFAULT_PASS / LUBANCAT_SALT）

### Removed
- 音频 workaround（asound.conf default→pulse）：已复原，音频修复另行处理
  （根因见下方 Known Issues）

### Planned
- LubanCat-4（RK3588S）板级支持：`gen_rk_update.sh` 参数化、`soc_name` 拆为 family/model
- LubanCat-3（RK3576）：新增 rk3576 内核与 u-boot 构建
- LubanCat-2 / 1（RK3568 / RK3566）：共用 rk356x 内核，补 Mali-G52 libmali
- LubanCat-0：实机标定 SARADC 板型映射
- **音频修复**：PL330 DMA 微码缓冲问题（见 v0.6.0-alpha6 Known Issues 最后一条），
  需在 DTS 的 dma-controller 节点加 `arm,pl330-mcbufsz-bytes = <4096>`
  （pl330.c 仅支持设备树传入，cmdline 参数无效），影响全系 SoC 的音频 DMA

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
- `/`、`/etc`、`/usr`、`/usr/lib` 曾被 libmali tar 的目录条目改成 uid 1000 + 775
  （提权风险）——**alpha7 已修复**，alpha6 及更早镜像不要用于生产
- **音频不可用（根因已定位）**：PL330 DMA 微码缓冲默认 256B，音频描述符（258B）
  被 `dma-pl330 fill_queue:2267 Bad Desc` 拒绝，I2S 中断恒为 0，任何播放器
  （含 UKUI 登录音 aplay）永久阻塞在 snd_pcm_write。修复需在 DTS 的
  `dma-controller@fea30000`（dmac1）节点加 `arm,pl330-mcbufsz-bytes = <4096>`；
  pl330.c 只从设备树读取该值（cmdline 参数无效），且上限为 PAGE_SIZE。
  该修复影响全系 SoC 的音频 DMA，待评估后统一合入
- 无 swap/zram；CPU governor 固定 performance，空载也满频

## 历史构建（工程内部编号，未打 tag）

| 内部版本 | 说明 |
|---|---|
| alpha1–alpha3 | 首次打通 vendor 布局；alpha3 桌面未装完（镜像早于 UKUI 安装完成） |
| alpha4 | 首个真正带完整 UKUI 与 299 个内核模块的镜像；修复内核模块缺失根因 |
| alpha5 | 固化 mali hook、光标主题、autologin、librknnrt、无线工具包 |
| alpha6 | 固化多媒体三件套与 3A RPM 预置（本版） |
