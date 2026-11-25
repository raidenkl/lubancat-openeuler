# Changelog

本文件记录镜像与构建工程的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 SemVer（预发布阶段 `0.x`）。

镜像命名与 tag 逐字符对应：`<board>_openEuler-24.03-LTS_aarch64_<tag>.img.xz`。

## [Unreleased]（Cat-3 外设验证：手册 + 一键脚本）

### Added
- `docs/peripheral-verification.md`：GPU / NPU / VPU / RGA / 摄像头 / 音频 / 网络 / USB /
  存储 / 温度的验证方法，每条固定「验什么 → 命令 → 期望 → 失败含义」，末尾附实测基线
- `build/check_periph.sh`：板端一键跑，四态 PASS/FAIL/SKIP/WARN + 退出码，
  支持 `--quick`（只查状态）与 `--stress`（NPU 1000 次看温升）
- `build/npu-smoke.c`：最小 NPU 推理自测，只用 `rknn_api.h` + `librknnrt.so`。
  SDK 的 `rknn_benchmark` 依赖 OpenCV，本镜像没有，所以自写
- `.gitignore` 放行 `build/*.c`

### Verified（LubanCat-3 V2 / 6.1.99-rk3576）
- NPU：resnet18 224×224 **3.341 ms / 299.3 fps**（100 次 0 失败），SDK 2.3.0 / driver 0.9.8
- VPU：1080p H.264 编码 **109.08 fps**、解码 **567.26 fps**，gst `mppvideodec` 到 EOS
- 摄像头：imx415(cam1) 1080p NV12 取 10 帧 = 29 MB，DT 节点在 i2c4、拓扑在 `media0`
- 音频：3 张卡，ES8323 (`hw:0`) DMA 正常；HDMI 无 ELD（未接音频 sink，属 WARN）
- 网络 1000 Mb/s、USB 4 设备、eMMC 三分区、最高温 55 °C
- `check_periph.sh`：PASS=32 FAIL=0 SKIP=2 WARN=1

### Known
- **GPU：EGL 起不来**。`mali-env eglinfo`/`es2_info` 在 X11、GBM、Wayland 三平台都
  `eglInitialize failed`，root 与 lubancat 一致；`ldd libmali` 无缺失依赖、
  kbase 侧可通信。按「内核 DDK 可高于 mali-so」判断不是 g25p0/g13p0 版本问题，
  待查方向（X 持 DRM master / 无 DRI2、GBM 句柄、hook 行为）记在文档第 1 节，本轮记 SKIP
- RGA：无测试工具与头文件，用户态只能开窗看 `rkximagesink`，脚本标 SKIP
- 摄像头默认不启用：uEnv 模板里 dtoverlay 仍是注释态，要手工打开
- 音频只验 DMA 通路，有无声音需人耳；PCIe/mSATA、WiFi/蓝牙未覆盖

## [Unreleased]（LubanCat-3 桌面版 alpha4：修 u-boot overlay 不生效）

### Fixed
- **设备树插件（dtoverlay）静默不生效**：串口只有
  `DTOVERLAY[debug]: himport_r: can't malloc 16777217 bytes`。根因在
  `cmd/dtfile.c:38-47`——它把 uEnv.txt 里的 `size=0x1000000` 当成 uEnv.txt 的**文本长度**，
  先 `malloc(size+1)`（16 MiB+1）再 `memcpy(size)` 解析；malloc 失败后 **`return 0`**
  （看着像成功），overlay 全部跳过。uEnv.txt 真实只有 6 KB。
- 这也解释了"uEnv.txt 似乎读的不是同一份"：`argv[3]`（`/uEnv/uEnv.txt`）在 dtfile 里
  只被打印、从未用于读文件，长度取自 env 的 `size` 而非文件真实大小

### Changed
- `scripts/configs/common/boot.cmd`：`load` 完 uEnv.txt 立刻
  `setenv uenv_size ${filesize}`，`dtfile` 前 `setenv size ${uenv_size}`
  （兜底 `0x8000`，与 `env import` 上限一致），并打印 `overlays applied, size=`
- `scripts/build_boot.sh`：dtbo 拷贝补计数断言，0 个直接报错（原来只有 `|| true`）

### Added
- `build/check_l3_ui.sh` boot.img 段 4 项断言：dtbo 数 > 0、boot.cmd 含
  `setenv uenv_size`、含 `setenv size`、boot.scr 里 grep 得到 `uenv_size`
- `manifests/lubancat-3-ukui-alpha4-20261125.txt`
- `docs/troubleshooting.md`：新增「设备树插件（dtoverlay）不生效」一节

## [Unreleased]（LubanCat-3 桌面版 alpha3：修 X 主 GPU 选择）

### Fixed
- **桌面起不来，X 在 probe 阶段就 Abort**：`/var/log/lightdm/x-0.log` 里是
  `Cannot run in framebuffer mode. Please specify busIDs for all framebuffer devices`。
  根因是 RKNPU 也注册了一个 DRM 设备（`drivers/rknpu/rknpu_drv.c:862` 的 `drm_dev_alloc`，
  NPU 要用 GEM 做 dma-buf），且比显示子系统 probe 得早：`card1` 归 NPU、`card0` 才是
  rockchip-drm。X 的平台探测把第一个 DRM 设备当主设备，选中 NPU 后没有 CRTC，直接 Fatal
- `plymouth-quit.service` 的 failed 是 lightdm 的 `OnFailure=` 连带，随之一并消失
- 只加 `Option "kmsdev" "/dev/dri/card0"` 不够（主设备仍是 NPU，照样 Fatal），
  必须用 `OutputClass` 改主设备

### Added
- `scripts/overlay/common/etc/X11/xorg.conf.d/10-rockchip-primary.conf`：
  `OutputClass` + `MatchDriver "rockchip"` + `PrimaryGPU yes`，把显示子系统钉成主 GPU
  （与厂商 `debian12/overlay/etc/X11/xorg.conf.d/20-modesetting.conf` 同源）
- `check_l3_ui.sh` B 段加 3 项断言（文件存在 / MatchDriver / PrimaryGPU）
- `manifests/lubancat-3-ukui-alpha3-20261125.txt`
- `docs/troubleshooting.md`：新增「桌面起不来：X 报 Cannot run in framebuffer mode」

### Changed
- `lubancat-3.conf` / `lubancat-5.conf` 桌面段各补一条 install

## [Unreleased]（LubanCat-3 桌面版 alpha2：修首启板型识别）

### Fixed
- **首启板型识别永远失败**：`board-init.sh` 按 IIO 设备 `name` 含 `saradc` 筛选，而驱动是
  `indio_dev->name = dev_name(&pdev->dev)`，dts 节点为 `adc@2ae00000`，实际值
  `2ae00000.adc` → 一个都筛不到 → BID 为空 → 落到 `rk3576-lubancat-generic.dtb`。
  generic dts 没有 `gmac0`/`gmac1` 节点，实机表现是「能启动、能出画面，但没有 eth0」
- **识别失败被固化**：失败分支同样 `touch /boot/.board_init`，配合 unit 的
  `ConditionPathExists=!/boot/.board_init`，之后每次启动都跳过、永不重试
- **主机名不生效**：`firstboot.sh` 硬编码 `BOARD=LubanCat-5`；且 `ConditionFirstBoot=yes`
  在首启被 board-init 的 `reboot` 打断后永久失效，主机名再也不会被设置

### Changed
- `board-init.sh` 移到 `scripts/overlay/common/`，**全系共用一份**，识别逻辑照搬厂商
  `SDK/debian12/overlay/etc/init.d/boot_init.sh`：全 SoC 映射表、10 位/12 位阈值表与
  `bc` 判定、ch2+ch3（rk3128 用 ch0+ch2）、选型后 `ln -sf` + `touch` + `reboot`；
  仅剪掉 apt-kerneldeb、userdata/oem、fstab 追加、partlabel 等待、logo、`service lightdm stop`
- 映射表结构改为「外层按 SoC family 分支、内层只匹配 BID」，顺带修掉 rk3588s 匹配不到
  `rk3588:xxxx` 的隐患（旧表键是 `"$SOC:$BID"`）
- `lubancat-board-init.service` 加 `StandardOutput=journal+console`：本镜像 journal 是
  volatile，首启 `reboot` 前不把输出送到串口就什么都不剩
- `firstboot.sh` 的板型名改读 `/etc/lubancat/board-name`（board-init 写入，空格转 `-`，
  兼容厂商表里的 `LubanCat-3 v2`）
- `lubancat-firstboot.service` 去掉 `ConditionFirstBoot=yes`，改以 marker 做幂等，
  并 `After=lubancat-board-init.service`
- `lubancat-3.conf` 两处 install 指向 `overlay/common`；头注释里「不做板型识别/只出
  headless」的过时说明改掉

### Added
- `build/board-init-selftest.sh`：8 个用例用假 sysfs 跑真脚本（0000→Cat-3 / 0001→3IO /
  0100→3-v2 / 表外→generic / 10 位阈值 / rk3588s 0402→5-v2 / 标记存在则跳过 /
  dtb 缺失则拒绝切换），不需要板子
- `build/check_l3_ui.sh` 新增 E 段 12 项（含上述 8 个用例）
- `manifests/lubancat-3-ukui-alpha2-20261125.txt`
- `docs/troubleshooting.md`：新增「板型识别错 / 主机名不变 / 没有 eth0」一节

## [Unreleased]（LubanCat-3 桌面版 alpha1）

### Added
- **LubanCat-3（RK3576）桌面版**：ukui + lightdm(autologin) + onboard + 软件光标，
  镜像 1.76 GiB，镜像级验收 47 项全过（`build/check_l3_ui.sh`）
- **GPU**：libmali Mali-G52 g13p0（43.4 MB）+ 6 装订桩 + hook；不带 `mali_csffw.bin`
  （G52 不需要）；仍走 `mali-env` 按需启用，不污染全局 ld 路径
- **NPU / 硬解**：librknnrt 2.3.0（支持 RK3576）、librga 2.1.0、librockchip_mpp、
  gst rockchip 插件、udev 权限规则
- **摄像头 3A（rk3576 版）**：`pkg/SPECS/camera-engine-rkaiq-rk3576.spec`（ISP v39，
  12 个 iqfiles），预置到 `/opt/rpms`；`bin/rpms/{rk3576,rk3588}/` 分目录避免通配串包
- **SARADC 板型识别**：`overlay/lubancat-3/board-init.sh`，BID 0000→Cat-3、
  0001→3IO、0100→3-V2（映射来源厂商 board-table），阈值表与映射表分离便于回填
- **u-boot 宿主源码编**：`tools/build-image.sh --stage uboot`（默认 `--uboot-env host`），
  `rk3576_defconfig` + `scripts/configs/u-boot/distro-boot.config` fragment；
  产物 `uboot.img` 4 MiB、loader 头推导 3576、二进制内含 `ext4load`
- **`tools/build-rpms.sh`**：从 `pkg/SPECS` + `pkg/SOURCES` 构建 aarch64 rpm，
  `pkg/rpmrc-aarch64` 增加 `buildarch_compat: x86_64: aarch64`
- **`--stage kernel`**：只编内核 + boot.img 的快速通道；`LTB_DESKTOP` 打通
  `--desktop none`（桌面 5 段整体跳过，驱动段仍装）

### Changed
- `scripts/build_u-boot.sh`：新增 `use_local_u_boot()`（Rockchip `make.sh` 体系，
  与原先 arm.com v2020.10 路线并存）；修 `:158` 的 `CROSS_COMPILE` 缺 `/bin/`
- `tools/build-image.sh`：宿主模式先编 u-boot，其余阶段 `docker exec` 进容器；
  断点标记 `<board>|<包清单文件名>`（不存绝对路径，否则宿主/容器互判为"变了"）
- `scripts/boards/lubancat-5.conf`：rkaiq 通配改到 `bin/rpms/rk3588/`

### Fixed
- u-boot `-Werror`（GCC 12 下 `cmd/dtfile.c` 的 `-Werror=address`）→ 统一 `-Wno-error`
- `make.sh` 传板名会重跑 defconfig 冲掉 fragment → 固定「先 make defconfig+frag，
  再 `./make.sh` 不带板名」
- 宿主跑 u-boot 时 `scripts/build/`（容器 root 创建）不可写 → wrapper 自动 chown

## [Unreleased]（alpha10，未打 tag）

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


### Added
- **屏幕键盘 onboard**（含 onboard-data）：自启但默认隐藏，触摸文本输入时弹出、
  按物理键盘收起、托盘留图标；默认值经 dconf 系统库
  `/etc/dconf/db/local.d/00-onboard` 下发，布局 `Compact` 适配 800x1280 竖屏

### Fixed（alpha10）
- **鼠标指针移到任务栏后消失**：X 走 modesetting 且 glamor 初始化失败
  （`Refusing to try glamor on llvmpipe`）、无 ShadowFB，光标依赖 rockchip-drm
  的 VOP cursor plane，DSI 面板重绘一次后丢失且不再更新。改为软件光标
  （`/etc/X11/xorg.conf.d/20-swcursor.conf`，`Option "SWcursor" "on"`），
  由 X 画进扫描缓冲区。判定依据与验证方法见 `docs/troubleshooting.md`


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
