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
ls -l /boot/.board_init           # 存在 = 已识别过，之后不再重试
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

### 坑 2：`.board_init` 会把失败固化

识别失败也会 `touch /boot/.board_init`，而 unit 的条件是
`ConditionPathExists=!/boot/.board_init` → 之后每次启动都跳过，不再重试。

要重试：

```sh
rm -f /boot/.board_init
systemctl restart lubancat-board-init     # 会改软链并自动重启
```

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
