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
