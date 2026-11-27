# 故障排查

## 引导进入 dracut emergency shell（根分区挂不上）

典型串口输出：

```
dracut-initqueue: Warning: dracut-initqueue timeout - starting timeout scripts
...
Expecting device /dev/disk/by-uuid/xxxxxxxx-....
...
Generating "/run/initramfs/rdsosreport.txt"
Entering emergency mode.
```

按下面顺序定位，**不要**急着重刷。

### 第 1 步：分区和文件系统是否还在

```sh
blkid /dev/mmcblk0p3            # 有没有 UUID / TYPE="ext4"
ls -l /dev/disk/by-uuid/        # by-uuid 链接有没有生成
```

- 没有 `by-uuid` 链接 → initrd 根本没看到这个分区的文件系统，跳到第 3 步
- 有链接但 `root=` 的 UUID 对不上 → 镜像的 cmdline 与 rootfs UUID 不一致

### 第 2 步：能不能手工挂

```sh
mkdir -p /mnt
mount -t ext4 /dev/mmcblk0p3 /mnt; echo rc=$?
```

如果报：

```
EXT4-fs (mmcblk0p3): bad geometry: block count NNN exceeds size of device (MMM blocks)
```

说明**文件系统比分区的实际尺寸大**（N > M）。这是本项目的已知故障模式，见下一节。

### 第 3 步：`bad geometry` 的修复

多半是历史版本在运行期改过分区表，而加载器下次启动按 `parameter.txt` 重算
GPT 收回了那几 MB，FS 就悬空了。修复就是把超级块尺寸收回到分区大小：

```sh
e2fsck -f /dev/mmcblk0p3
```

它会先警告再问：

```
The filesystem size (according to the superblock) is NNN blocks
The physical size of the device is MMM blocks
Either the superblock or the partition table is likely to be corrupt!
Abort? (y/n)
```

**第一条必须回答 `n`**（回答 `y` 等于放弃修复），之后所有 `Fix?` 都答 `y`。

修好后验证并重启：

```sh
mkdir -p /mnt && mount -t ext4 /dev/mmcblk0p3 /mnt && echo MOUNT_OK
umount /mnt && reboot
```

若 `e2fsck` 在尾部报 I/O error（超出的块不在分区内），只能重刷镜像。

## 为什么不能改分区表

本项目的分区表由加载器按 `scripts/configs/common/parameter*.txt` 生成，rootfs 是
`-@offset(rootfs:grow)`，**每次启动都会重算**。因此：

- 运行期用 `parted resizepart` / `fdisk` 改出来的尺寸，下次启动就会被收回；
- 如果这时已经 `resize2fs` 到那个偏大的尺寸，就会得到 `bad geometry`，根分区永久挂不上。

结论：**扩容只允许 `resize2fs`，不允许动分区表**。`lubancat-growfs.service`
（`scripts/overlay/lubancat-5/usr/libexec/lubancat/growfs-rootfs.sh`）就是按这个约束写的：
用 `/sys/class/block/<part>/size` 作为唯一尺寸来源，显式传给 `resize2fs`。

底座还自带 `/etc/rc.d/init.d/extend-root.sh`（`rc3/4/5.d/S99` 已启用，one-shot，
成功后自删）。它的 `resize2fs` 在 `if [ $PART_END -lt $ROOT_END ]` 分支里 ——
加载器会在盘尾留约 992 KiB（2 484 个扇区），条件成立，所以它**确实会扩 FS**，
而且会顺带 `fdisk` 重建一次分区表（这次重建会被加载器下次启动覆盖，属无害动作）。
alpha6 的首启扩容就是它做的。

既然它已经能扩，为什么还留 `lubancat-growfs.service`？因为它跑完就自删，
之后如果用户把系统 dd 到更大的卡上、或它某次因 `fdisk` 失败而没执行 `resize2fs`，
就没有第二道保险了。growfs 是常驻的、幂等的、且**只做 `resize2fs`**，两者目标尺寸
都取自同一个分区边界，不会互相打架（alpha7 的问题不是"两个扩容器"，而是其中一个
改了分区表并越界 992 KiB）。

## 构建机侧的坑

## u-boot 源码编（宿主）的几个坑

**现象：编出来的 u-boot 起不来，串口停在 `Unknown command 'load'`。**
Rockchip 的 `rk3576_defconfig`（以及 `lubancat-*_defconfig`）**都没有**打开
`CONFIG_CMD_EXT4 / CMD_EXT2 / CMD_FAT / CMD_FS_GENERIC / CMD_PART / EFI_PARTITION`，
Kconfig 里也没有 `default y`。厂商的 `.config` 里这些全是 `=y`（菜单里手点的、
没回写 defconfig），所以他们的预编译 `uboot.img` 能用，照 defconfig 编就不行。

本项目用 `scripts/configs/u-boot/distro-boot.config` 叠加：

```bash
make ARCH=arm CROSS_COMPILE=$cc rk3576_defconfig scripts/configs/u-boot/distro-boot.config
make ARCH=arm CROSS_COMPILE=$cc olddefconfig        # 然后才 ./make.sh（不带板名）
```

**现象：`.config` 里明明有 `CONFIG_CMD_EXT4=y`，编出来却没有 `ext4load`。**
`.config` 里有不等于链接进去了。用二进制断言：

```bash
strings u-boot.bin | grep -E '^(ext4load|ext2load|fatload)$'
```

**现象：`make.sh` 之后 fragment 失效。**
`make.sh:252` 在自己带板名时会重跑 `make <board>_defconfig`。所以顺序必须是
「先 `make defconfig + fragment`，再 `./make.sh`（不带板名，`make.sh:263` 会用现有 `.config`）」，
最后 `./make.sh loader`。

**现象：容器里编 u-boot 报 `python2: command not found`。**
`make.sh` 固定 `PYTHON=python2`，而 openEuler 24.03 已移除 python2。用默认的
`--uboot-env host`（宿主原生 2.7.18）；容器路线需要先在容器里装 python2。

**现象：宿主跑 `build_u-boot.sh` 报 `Permission denied`（`build/log/*.log` 或 `build/.done`）。**
`scripts/build/` 是容器内 root 创建的。一次性修：

```bash
docker exec oe-lubancat-build bash -c \
  'chown -R 1000:1000 /work/src/SBC-sig/scripts/build/{log,u-boot} /work/src/SBC-sig/scripts/build'
```

`tools/build-image.sh` 在宿主模式会自动做这件事；`.done` 由容器维护
（脚本里 `LTB_SKIP_DONE_MARK=1` 让子脚本跳过记账）。

**现象：u-boot 编出来 `uboot.img` 是 8 MiB，塞不进 4 MiB 的 uboot 分区。**
那是 rk3588 的旧产物残留（`src/u-boot/uboot.img`）。rk3576 的 `make.sh` 产出正好
4,194,304 B；`gen_rk_update.sh` 用 `-le` 校验。确认 `parameter.txt` 的
`rk_uboot_sectors` 与产物体积一致即可。

## rpmbuild 在 x86_64 容器里编 aarch64 包

报 `No compatible architectures found for build`：需要
`buildarch_compat: x86_64: aarch64`。仓库的 `pkg/rpmrc-aarch64` 已加，用法：

```bash
rpmbuild -bb pkg/SPECS/<x>.spec --rcfile pkg/rpmrc-aarch64 --target aarch64 ...
```

正常路径走 `tools/build-rpms.sh`，它会带上 rcfile 并按 SoC 归档到
`scripts/bin/rpms/<soc>/`。

**注意**：`find ... -name 'camera-engine-rkaiq-*.rpm'` 会同时匹配 rk3576 与 rk3588 两个包
（前缀相同）。每个包要用独立的 `_rpmdir`，否则会把 rk3576 的包拷进 rk3588 目录。

## 断点标记为什么只存文件名

`build/.ltb_board` 的内容是 `<board>|<包清单文件名>`。**不能存绝对路径**：
宿主是 `/home/dev/.../rpmlist-xxx`、容器是 `/work/.../rpmlist-xxx`，两边一比就
判定「板卡或包清单变了」，于是清空 `.done` —— 表现为每次构建都重新编内核，
在宿主模式下还会让容器重跑 u-boot（然后因缺 python2 失败）。


- `gen_rk_update.sh` 会 `mount` `rkpack/Image/boot.img`。如果之前用
  `mount -o loop,ro` 检查过同一个文件且没 `umount`，会残留一个只读 loop 设备，
  下一次 gen 挂载就变成 `source write-protected`，随后 `sed: Read-only file system` 失败。
  处理：`umount <挂载点> && losetup -d /dev/loopN` 后重跑。
- 内核模块与固定 UUID 只存在于 `rkpack/Image/rootfs.img`（gen 加工后的 staging 副本），
  工作区的 `rootfs.img` 永远没有模块、UUID 也是随机的；uEnv 占位 UUID 只替换
  staging 的 `boot.img`。校验时不要查错对象。

## 鼠标指针移到任务栏后消失

**现象**：指针进入底部任务栏后不可见，移开也不恢复，重启（或重登）才复原。

**判定**：X 侧光标状态是好的。用 XFixes 读 `XFixesGetCursorImage`，指针在任务栏上时
仍是 24x24、name=`default`、254 个不透明像素 —— 说明不是"被设成空白"，而是
"没有被画出来"。同时 `xwininfo` 显示面板窗口正常、`blkid` 之类无关。

**根因**：本平台 X 走 modesetting 驱动，glamor 初始化失败
（`modeset(0): Refusing to try glamor on llvmpipe`），`ShadowFB: enabled NO`，
X 直接渲染到扫描缓冲区；光标交给 rockchip-drm 的 VOP cursor plane 绘制，
而该 plane 在 DSI 面板上不稳定 —— 面板重绘一次就会丢，之后不再更新。

**修法**：强制软件光标，由 X 把它画进扫描缓冲区：

```sh
cat /etc/X11/xorg.conf.d/20-swcursor.conf
# Section "Device"
#     Identifier "Rockchip"
#     Driver     "modesetting"
#     Option     "SWcursor" "on"
# EndSection
```

生效验证（重启 lightdm 后）：

```sh
grep -i swcursor /var/log/Xorg.0.log
# (**) modeset(0): Option "SWcursor" "on"
```

副作用：光标由 CPU 合成，理论上多一点点延迟；在本平台可忽略。

## 屏幕键盘（onboard）

镜像预装 `onboard` + `onboard-data`，由
`/etc/xdg/autostart/onboard-autostart.desktop` 自启，默认值通过 dconf 系统库
`/etc/dconf/db/local.d/00-onboard` 下发：

| 键 | 值 | 含义 |
|---|---|---|
| `org.onboard.auto-show enabled` | `true` | 开机隐藏，触摸到文本输入框才弹出 |
| `org.onboard.auto-show hide-on-key-press` | `true` | 按物理键盘自动收起 |
| `org.onboard show-status-icon` | `true` | 托盘留图标 |
| `org.onboard layout` | `Compact` | 紧凑布局，适合 800x1280 竖屏 |
| `org.onboard.window docking-enabled` | `true` | 停靠在屏幕底部、自动让出工作区 |

手动打开：开始菜单搜 "Onboard"（中文名"屏幕键盘"），或终端 `onboard &`。

改成常显：`gsettings set org.onboard.auto-show enabled false` 后重新登录。

改完 dconf 系统库需要 `dconf update`（构建时 overlay 阶段已执行）。

## 板型识别错 / 主机名不变 / 没有 eth0

这三个症状通常是一条链：`board-init` 选错 dtb → 落到 `rk3576-lubancat-generic.dtb`
→ 该 dts **没有 `gmac0`/`gmac1` 节点**（`rk3576.dtsi` 默认 disabled，generic 里也没写）
→ 板上没有 eth0。同时缺 CSI、sys_led、watchdog、MIPI 屏。

### 先看现场

```sh
readlink /boot/rk-kernel.dtb      # 期望 dtb/rk3576-lubancat-3.dtb
readlink /boot/uEnv/uEnv.txt      # 期望 uEnvLubanCat3.txt
cat /etc/lubancat/board-name      # 期望 LubanCat-3
ls -l /boot/boot_init             # 存在 = 已识别过，之后不再重试
```

### 坑 1：IIO 设备名不是 `saradc`

`drivers/iio/adc/rockchip_saradc.c` 里是 `indio_dev->name = dev_name(&pdev->dev)`，
dts 节点叫 `adc@2ae00000`，所以 `/sys/bus/iio/devices/iio:device0/name` 的值是
**`2ae00000.adc`**。按 `*saradc*` 去筛设备会永远筛不到 → BID 为空 → 走 generic。

厂商脚本是**直接读 `iio:device0`**、不看名字的：

```sh
ADC_RAW=$(cat /sys/bus/iio/devices/iio:device0/in_voltage2_raw)
```

`scripts/overlay/common/usr/libexec/lubancat/board-init.sh` 已按厂商做法实现，
不要改回按名字匹配。

### 坑 2：`boot_init` 会把失败固化

识别失败也会 `touch /boot/boot_init`，而 unit 的条件是
`ConditionPathExists=!/boot/boot_init` → 之后每次启动都跳过，不再重试。

要重试：

```sh
rm -f /boot/boot_init
systemctl restart lubancat-board-init     # 会改软链并自动重启
```

> 标记文件名与厂商 `boot_init.sh` 一致（早期镜像用的是 `/boot/.board_init`）。
> 脚本启动时若发现老标记，会自动 `mv` 成新名字，所以刷过老镜像的板子不会被当成首启再重启一次。

### 坑 3：首启日志会被 reboot 清掉

journal 是 volatile，board-init 末尾 `reboot` 一执行，`BOARD_ID` 那几行就没了。
所以 unit 里加了 `StandardOutput=journal+console`：**开机时盯着串口**就能看到

```
ADC_voltage_scale:0.439453125
ADC_CH:2 ADC_RAW:...
ADC_CH:3 ADC_RAW:...
SOC_type:rk3576
BOARD_ID:0000
BOARD_NAME:LubanCat-3
BOARD_DTB:rk3576-lubancat-3.dtb
BOARD_uEnv:uEnvLubanCat3.txt
```

表里没有的 BID 会打 `Device ID Error !!!` 并落到 generic。

### 映射表在哪儿

`board-init.sh` 的 `board_info()`，全 SoC 一张表。改之前先对照厂商
`SDK/debian12/overlay/etc/init.d/boot_init.sh`；离线验证不需要板子：

```sh
bash build/board-init-selftest.sh scripts/overlay/common/usr/libexec/lubancat/board-init.sh
```

注意厂商表的 rk3588 段可能落后于内核树（树里另有 `5iob`/`5iobi`/`5iof`/`5io-aibox1`
四个 dtb，厂商只映射到 `5io`/`5ioi`），迁移 rk3588 板卡时逐条核对。

## 桌面起不来：X 报 `Cannot run in framebuffer mode`

### 症状

`lightdm.service` failed，`journalctl -u lightdm` 只有反复 restart，看不到具体原因。
真正的错误在 `/var/log/lightdm/x-0.log`（以及 `x-0.log.old`）：

```
(EE) Fatal server error:
(EE) Cannot run in framebuffer mode. Please specify busIDs        for all framebuffer devices
```

### 根因：NPU 的 DRM 设备抢了「主 GPU」

`drivers/rknpu/rknpu_drv.c:862` 无条件 `drm_dev_alloc()`（NPU 要用 GEM 做 dma-buf），
而 rknpu 比显示子系统 probe 得早，于是两张卡的角色是反的：

```
/dev/dri/card1 -> 27700000.npu        驱动 RKNPU
/dev/dri/card0 -> display-subsystem   驱动 rockchip-drm
```

X 的平台探测把**第一个** DRM 设备当主设备，选中 NPU 后那设备没有 CRTC，直接 Fatal：

```
(II) xfree86: Adding drm device (/dev/dri/card1)
(II) xfree86: Adding drm device (/dev/dri/card0)
(II) no primary bus or device found
        falling back to /sys/devices/platform/27700000.npu/drm/card1
(EE) Cannot run in framebuffer mode. Please specify busIDs for all framebuffer devices
```

注意：`Option "kmsdev" "/dev/dri/card0"` 单独加**不够**（screen 会用 card0，但
主设备仍是 NPU，`xf86BusConfig` 阶段照样 Fatal）。必须用 `OutputClass` 改主设备。

### 修法

`/etc/X11/xorg.conf.d/10-rockchip-primary.conf`（与厂商 SDK 的
`debian12/overlay/etc/X11/xorg.conf.d/20-modesetting.conf` 同源）：

```ini
Section "OutputClass"
    Identifier  "RockchipDRM"
    MatchDriver "rockchip"
    Option      "PrimaryGPU"     "yes"
EndSection
```

`MatchDriver` 匹配的是内核 DRM 驱动名 `rockchip_drm_driver.name = "rockchip"`，
NPU 那份是 `rknpu`，所以只会匹配到显示子系统。

### 两分钟定位

```sh
readlink -f /sys/class/drm/card*/device/driver   # 哪张是 rockchip-drm
grep -n "falling back to" /var/log/Xorg.*.log    # 出现 npu 就是这个问题
ls /etc/X11/xorg.conf.d/                         # 有没有 OutputClass + PrimaryGPU
```

改完不用重启：`systemctl restart lightdm`，起来后应能看到
`(II) modeset(0): Output HDMI-1 connected` 与 `Setting screen physical size`。

### 两个容易误判的点

1. 开机时 HDMI 未连接，内核会打 `[drm] Cannot find any crtc or sizes`。这**不是**致命项，
   插上屏后热插拔会重新 modeset。真正致命的是主设备选错。
2. 在串口上手工跑 `Xorg :1` 会看到
   `logind integration requires -keeptty and -keeptty was not provided`，
   那是手工调试产物；lightdm 拉起的 X 不受影响，别顺着这条去改 `-keeptty`。

## 设备树插件（dtoverlay）不生效

### 症状

uEnv.txt 里已取消注释 `dtoverlay=...`、`enable_uboot_overlays=1`，但串口上没有
任何 `loading overlay:`，只有：

```
[boot.cmd] applying overlays from /uEnv/uEnv.txt
DTOVERLAY[debug]: himport_r: can't malloc 16777217 bytes
```

开机后 `/proc/device-tree/` 里也找不到 overlay 应该加进来的节点。

### 根因：`size` 不是缓冲区大小，而是 uEnv.txt 的文本长度

`cmd/dtfile.c:38-47`：

```c
buf  = env_get("size");                  // uEnv.txt 里的 size=0x1000000
size = simple_strtoul(buf, NULL, 16);    // → 16 MiB
if ((data = malloc(size + 1)) == NULL) { // 16777217 = 0x1000000 + 1
    dtoverlay_debug("himport_r: can't malloc %lu bytes\n", size + 1);
    return 0;                            // ← 失败也返回"成功"
}
memcpy(data, ptr, size);                 // 从 env_addr_r 拷 size 字节再解析
```

- uEnv 模板本来只有 6 KB，`size=0x1000000` 是厂商模板里的遗留值
- 16 MiB 的**整块连续堆**在 32 MiB 池里不一定拿得到；拿不到就 `return 0`
- boot.cmd 无从判断，直接 `booti`，所以既不报错也不生效

顺带一个容易误判的点：`argv[3]`（`/uEnv/uEnv.txt`）在 dtfile 里**只被打印、从未用于
读文件**（`dtfile.c:36` 只取 `argv[4]`）。所以"改的 uEnv.txt 和读的不是同一份"只是
错觉——文件是同一份，但**长度取自 env 的 `size`**，不是文件真实大小。

那句 `himport_r: can't malloc` 是从 `lib/hashtable.c:792` 抄来的文案，不是 himport_r
打的（它用 `debug()`，不带 `DTOVERLAY[` 前缀），别顺着 himport_r 去查 env import。

### 修法

已修在 `scripts/configs/common/boot.cmd`：`load` 完 uEnv.txt 立刻记录真实长度，
`dtfile` 之前覆盖 `size`：

```sh
  load ... ${env_addr_r} /uEnv/uEnv.txt
  setenv uenv_size ${filesize}       # fs/fs.c:505 是 env_set_hex，无前缀 hex
  env import -t ${env_addr_r} 0x8000
  ...
  setenv size 0x8000                 # 兜底，与 env import 上限一致
  if test -n "${uenv_size}"; then setenv size ${uenv_size}; fi
  dtfile ${fdt_addr_r} ${fdt_over_addr} /uEnv/uEnv.txt ${env_addr_r}
```

现场也可以先不动镜像验证：把 `/boot/uEnv/uEnv.txt` 的 `size=0x1000000` 改成
`size=0x2000`（`dtfile` 读的是 `env import` 之后的值）。若改完仍失败，注意别让
`memcpy(size)` 读到文件末尾之后的 DRAM 垃圾——把文件补齐到与 `size` 等长最稳。

### 为什么别的板子"没这个问题"

同一份 `dtfile.c`、同一个 `size`、两边 `CONFIG_SYS_MALLOC_LEN` 都是 32 MiB
（`rk3576_common.h:25` / `rk3588_common.h:23`）。差别只在"分配那一刻堆里还剩多少
连续空间"——Cat-5 上曾侥幸拿到 16 MiB，所以看起来正常。这是运气，不是设计正确；
Image/initrd/分区尺寸一变就可能复现。所以修在共用的 boot.cmd 里。

### 验收

```sh
# 串口应出现
loading overlay: /dtb/overlay/rk3576-lubancat-3-cam1-imx415-1920x1080-60fps-overlay.dtbo
# 板端
dmesg | grep -iE "imx415|rkcif|rkisp"      # sensor probe / notifier completed
tr -d '\0' < /proc/device-tree/csi2-dphy1/status; echo   # okay
ls /dev/video*
```

## rkaiq 装了但 /etc/iqfiles 是空的

旧镜像是"只把 rpm 预置到 `/opt/rpms`、没装"，表现为 `ls /etc/iqfiles` 为空、
`rpm -q camera-engine-rkaiq-rk3576` 查不到，ISP 出图偏色/发暗。两种补救：

```sh
# 1) 现场装（旧镜像）
dnf install -y --nogpgcheck /opt/rpms/camera-engine-rkaiq-*.rpm

# 2) 重新出镜像（已修）：conf 里改成构建期 rpm -ivh，装完不留 rpm
```

装好后确认：`rpm -q camera-engine-rkaiq-rk3576`、`ls /etc/iqfiles | wc -l`（rk3576 是 12）。
`rkaiq_3A.service` 默认启用。没接摄像头时它会因 media 拓扑缺失退出，5 次后进 failed ——
`systemctl --failed` 里看到它是预期噪音；接上摄像头（并打开 uEnv 的 dtoverlay）后自动恢复正常。
确实不用 3A 时：`systemctl disable --now rkaiq_3A.service`。

## 宿主 u-boot 阶段失败：`cp: -r not specified; omitting directory`

现象（`tools/build-image.sh` 走到 u-boot 阶段就退出）：

```
cp .../scripts/bin/u-boot/lubancat-5/MiniLoaderAll.bin .../u-boot.itb .../scripts/build/u-boot
cp: -r not specified; omitting directory '.../scripts/bin/u-boot/lubancat-5/pcie-named'
build-image.sh: 宿主 u-boot 构建失败
```

原因：`scripts/bin/u-boot/<board>/` 下放了**子目录**（历史遗留的变体备份，如 `pcie-named/`），
而 `scripts/build_u-boot.sh` 的预编译分支是 `cp ${local_uboot_dir}/* ...`，裸 `cp` 遇到目录返回非 0，
脚本又是 `set -e`，于是一个无关目录就能把整个构建打断。

修复（两层，都已落地）：

```bash
# 1) 脚本改成 cp -a（对子目录/附加文件免疫）
grep -n "cp -a \${local_uboot_dir}" scripts/build_u-boot.sh

# 2) 清掉多余目录（子目录通常是 root 建的，要用容器删）
ls scripts/bin/u-boot/*/ | grep -v '://' | head
docker exec oe-lubancat-build rm -rf /work/src/SBC-sig/scripts/bin/u-boot/lubancat-5/pcie-named
```

自查：`find scripts/bin/u-boot -mindepth 2 -type d` 应该没有任何输出。

## boot 阶段报 `initrd.img missing and rootfs.img absent`

现象（从零构建时必现，尤其是刚跑过 `--purge` 之后）：

```
INFO, start make bootimg...
ERROR initrd.img missing and rootfs.img absent; run build_rootfs.sh first
      (host dracut would build an unusable x86 initramfs)
```

两层原因：

1. initrd 必须 chroot 进 **aarch64 rootfs** 生成——构建容器是 x86_64，宿主 dracut 会
   打出 x86 的 initramfs，板子上 `/init` 直接 `ENOEXEC(-8)`；
2. 而 `build.sh` 原来的阶段顺序是 `u-boot → build_boot.sh(编内核+打 boot.img) → build_rootfs.sh`，
   **boot 阶段永远跑在 rootfs 之前**，于是在干净树上必然命中这个保护。

之前没暴露，是因为 `.done` 里留着 `bootimg` 标记把整步跳过了；`--purge` 清掉断点后就现形。

修复（已落地）：把 boot 阶段拆成两段，中间插 rootfs：

```
--stage kernel（编内核，产出 boot_dir + kernel-modules）
→ rootfs.img（装模块）
→ --stage bootimg（chroot 生成 initrd + 打 boot.img）
```

自查：

```sh
cat scripts/build/.done            # 期望依次看到 kernel / rootfs / bootimg / image
ls -l scripts/build/rootfs.img scripts/build/boot.img
```

## 换一块同族板卡后，串口卡在内核早期（CPU/外设初始化）

典型现象：U-Boot 能跑完并加载内核，但内核只到 `smp: Bringing up secondary CPUs` 前后就停，
串口里能看到**板名却是另一块板**：

```
Model: Embedfire LubanCat-5          <- U-Boot 载入 rk-kernel.dtb 之后
Machine model: Embedfire LubanCat-5  <- 内核
```

原因：镜像里的 `rk-kernel.dtb` 是**构建时那块板**的 dtb。换板后设备树描述的是别的硬件，
内核早期就挂；而 `board-init`（负责按 SARADC 换 dtb）是 systemd 用户态服务，起不来就跑不到。

修复：把 conf 里的 `extboot_generic_first` 置 1（`extboot_generic_dtb` / `extboot_generic_uenv`
也要有），让镜像先用家族 generic dtb 启动，首启由 board-init 判定实板后覆盖并重启一次。
rk3588 家族（lubancat-5 / 4 / 4io）已经默认打开。

自查镜像里初始用的是哪个 dtb：

```bash
# 构建机上
ls -l scripts/build/extboot/rk-kernel.dtb
cmp -s scripts/build/extboot/rk-kernel.dtb \
       scripts/build/extboot/dtb/rk3588-lubancat-generic.dtb && echo "generic ✓" || echo "不是 generic"
grep -c "dtoverlay=" scripts/build/extboot/uEnv/uEnv.txt   # generic uEnv 里应全是注释
```

## 预检报「缺预编译 u-boot」但其实同族有

```
build-image.sh: WARN: 缺预编译 u-boot: bin/u-boot/lubancat-4/u-boot.itb
```

同 SoC 家族的板卡共用一份 u-boot（Cat-4/4IO 复用 `bin/u-boot/lubancat-5/`），
conf 里用 `local_uboot_dir` 指定。预检现在按 `local_uboot_dir` 找，不再按板名硬拼目录
（早期版本会误报）。

## 开机卡在 `A start job is running for Wait for udev Device Initialization`（约 90 秒）

现象：系统能起来，但每次开机都要等 ~90 秒才继续；期间串口只有

```
rk-pcie fe190000.pcie: PCIe Linking... LTSSM is 0x3        (刷屏，171 次被抑制)
rk-pcie fe190000.pcie: PCIe Link Fail, LTSSM is 0x3
[*     ] A start job is running for Wait for udev Device Initialization (10s / 3min)
```

根因链（实测 Cat-4IO，M.2 槽空着）：

1. `rkaiq_3A.service` 的 unit 里有 `Wants=systemd-udev-settle.service`；
2. `systemd-udev-settle.service` 自带 **`Before=sysinit.target`** —— 它一跑就变成
   「整机启动的同步点」；
3. 4-IO 的 `&pcie2x1l2`（M.2 槽）启用了但槽位空着，链路协商不上，udev 事件队列
   ~90 秒才清空 → settle 一直不返回；
4. `sysinit.target` 等 settle，于是 **D-Bus socket 也没起来**；`lubancat-firstboot`
   里的 `hostnamectl set-hostname`（走 D-Bus）跟着阻塞，所以 firstboot、polkit、
   D-Bus 全在同一时刻（~102s）才完成 —— 看起来像"某个服务起不来"，其实是同一棵树。

修复：

- `pkg/SOURCES/rkaiq_3A.service` 去掉 `Wants/After=systemd-udev-settle.service`，
  改成 `After=dev-media0.device systemd-udev-trigger.service`（rkaiq 只等 media 节点）；
- `firstboot.sh` 的 `hostnamectl` 加 `timeout 10` 兜底（D-Bus 不就绪时退回写
  `/etc/hostname`，不再无限阻塞）。

现场快速验证（不用重编镜像，1 分钟）：

```sh
sudo ln -sf /dev/null /etc/systemd/system/systemd-udev-settle.service   # mask
sudo reboot
systemd-analyze            # 看 total 是否从 ~110s 掉到 ~10s
systemd-analyze blame | head
```

> `systemd-udev-settle` 本身已被 systemd 标记为「不应使用」：任何服务都不该等它。
> 需要等某个设备就用 `After=<dev-xxx.device>` 精确排序。

顺带：这条链还会让 `sshd-keygen@rsa.service` 失败（firstboot 里多余的 `ssh-keygen -A`
与它并发写同一个密钥文件），已在 firstboot 里去掉，交给 `sshd-keygen@` 实例。

## 构建"成功"但镜像里没有桌面（日志里有 `can not install ukui`）

现象：`tools/build-image.sh --desktop ukui` 跑完、镜像也打出来了，但烧到板子上只有
text console，没有 X/桌面。板子上查：

```
systemctl is-enabled lightdm     -> not-found      （unit 根本不存在）
rpm -qa | grep -ci ukui          -> 0
rpm -qa | wc -l                  -> 607            （ukui 镜像应该在 700+）
```

构建日志里有一行：

```
ERROR, can not install ukui.
```

两个独立问题叠在一起：

1. **dnf 装不上**：openEuler `update` 仓库的 `repomd.xml` 与 metalink 登记的校验和
   不一致（表现为 `Downloading successful, but checksum doesn't match` +
   `Cannot download repomd.xml: All mirrors were tried`），而 dnf 会把"一个 repo 的
   metadata 坏了"当成整条命令失败，于是 `install ukui` 整组没装上。
2. **脚本不报错**：`INSTALL_PACKAGES()` 的循环里失败只 `LOG ERROR`，不退出，于是
   残缺的 rootfs 继续被 initrd、boot.img、打包流程消费，产出一个"看起来成功"的镜像。

修法（已落地）：

- `dnf_chroot()` 包装所有 chroot dnf 调用，统一加
  `--setopt='*.skip_if_unavailable=true'`：坏 repo 降级为跳过，不影响其它 repo；
- 装包失败先自动用 `--refresh` 重拉一次仓库元数据再重试（`dnf_install_set()`），
  仍失败才 `exit 1`（`build.sh` 是 `set -e`）—— 缺包就停，不产出假成功镜像。

为什么需要那次 `--refresh`：同一个 `update` 仓库一天里给出过三种不同的错法，
其中两种都只能靠"重拉元数据"自愈，而 dnf 在同一次处理里不会自己重试：

| 现象 | 根因 |
|---|---|
| `Inconsistent server data, reported Content-Length: 1935657, metadata states 1935669` | 服务器上的 rpm 被重打包（短了 12 字节），repodata 没跟上 |
| `Cannot download repomd.xml: All mirrors were tried`（校验和不符） | repomd.xml 与 metalink 登记不一致 |
| `Curl error (28) 30s 超时` / `(92) HTTP/2 framing INTERNAL_ERROR` | 镜像抖动，dnf 自己的多镜像重试能兜住 |

装包日志里出现 `install <包名> failed; retry once with --refresh` 就是这次兜底生效了。

现状（2026-11-27）：`update` 仓库仍不一致，但已不影响构建 —— ukui 的 506 个包
全部来自 OS / everything / EPOL，解析与安装都正常。

自查方法：

```bash
# 构建机上，确认镜像里真的装了桌面
M=/tmp/chk; mkdir -p $M
mount -o loop,ro scripts/build/rkpack/Image/rootfs.img $M
chroot $M rpm -qa | grep -c ukui          # 应为几十个，不是 0
chroot $M rpm -q lightdm
umount $M
```
