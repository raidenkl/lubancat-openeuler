# openEuler extboot 实现 vs 厂商文档：逐项对照

> 对照对象
> - 文档：`extboot的三个特殊机制.md`、`rkboot与extboot启动流程详解-进阶篇.md`、
>   `rkboot与extboot学习笔记.md`、`U-Boot设备树加载与启动介质优先级.md`
> - 实现：`lubancat-openeuler` 仓库 `scripts/`、`tools/`、`overlay/`（截至 2026-11-27，
>   HEAD 之后的工作区状态）
> - 实机证据：`serial-log.txt`（Cat-4IO，2026-11-27 启动日志）
>
> 本文只记录**与文档不一致**的地方，以及需要决策的点；一致的部分在第二节简要列出。

---

## 一、结论摘要

**骨架是一致的**：ext2 boot 分区 + `bootable` 标志 + distro boot + `boot.scr` 优先 +
`/rk-kernel.dtb` 单一路径 + generic 先起 + ADC 判板 + 软链切换 + 重启一次 + `rootfs:grow`。

**三处"机制级"缺口**（文档描述、我们没有闭环）：

| # | 文档机制 | 我们的现状 |
|---|---|---|
| 1 | 内核以 deb 包更新（`/boot/kerneldeb/` + `apt install` + `apt-mark hold`） | **完全没有**。改内核只能重刷镜像或手工替换 `/boot/Image-<版本>`（P3，未做，见第四章计划） |
| 2 | `uname_r` 决定加载 `Image-<版本>`，支持多版本共存与回滚 | ✅ **已修（P1）**：`boot.cmd` 改为优先 `/Image-<uname_r>`，不再复制第二份 `/Image` |
| 3 | 通用屏自动适配（`i2c` 读背板 EEPROM → `fdt apply` 对应 dtbo） | ✅ **已移植（P2）**：`boot.cmd` 第 9 步，逻辑与厂商同构；构建期仍默认 `enable_gsdt_auto_load=0`（不改现有行为，置 1 即生效，未实机验证亮屏） |

> 2026-11-27 更新的部分在下文各小节末尾标了「✅ 已修」。

其余是**实现细节差异**，多数是我们主动改的（更适配 openEuler / 更保守），少数是遗留待办。

---

## 二、与文档一致的部分（已核实）

| 文档要点 | 我们的实现 | 证据 |
|---|---|---|
| 分区只有 uboot / boot / rootfs 三段，无 misc/recovery/backup/oem | 一致 | `Image/parameter.txt` 的 `mtdparts` |
| boot 分区带 `bootable` 标志 | 一致 | `parameter.txt`：`(boot:bootable)` |
| `rootfs:grow` 交给烧写工具铺到盘尾 | 一致 | `parameter.txt`：`-@0x00086000(rootfs:grow)` |
| boot 分区 = ext2，`mkfs.ext2 -d <目录>` 一步灌注（免 mount） | 一致 | `build_boot.sh:mk_boot()` → `truncate -s ${boot_size}M` + `mkfs.ext2 -F -L boot -d ${extboot_dir}` |
| 目录里有 `Image-<ver>`、`System.map-<ver>`、`config-<ver>`、`dtb/`、`dtb/overlay/`、`uEnv/`、`extlinux/`、`boot.cmd`、`boot.scr` | 一致 | 产物 `scripts/build/extboot/` 实测 |
| `boot.scr` 由 `boot.cmd` 用 `mkimage -T script` 生成 | 一致（我们用 `-A arm64`，文档写 `-A arm`，无实际影响） | `build_boot.sh:mk_extboot()` |
| U-Boot 先 `part list -bootable` 再扫 `boot.scr`，脚本优先于 extlinux | 一致 | 日志 `Found U-Boot script /boot.scr`，未见 extlinux 分支 |
| U-Boot 早期 dtb 从 bootable 分区根目录读 `rk-kernel.dtb`（`EARLY_DISTRO_DTB`） | 一致 | 日志 `DTB(Distro): rk-kernel.dtb` |
| U-Boot 早期 dtb 与内核 dtb 是同一个文件（extboot 下） | 一致 | `boot.cmd` 第 33 行 `load ... /rk-kernel.dtb` |
| 首次 `rk-kernel.dtb` 是**普通文件**（generic），由首启脚本换成软链 | 一致（`extboot_generic_first=1` 后） | 产物 `-rw-r--r-- rk-kernel.dtb` = `rk3588-lubancat-generic.dtb` 大小；`board-init.sh` 里 `ln -sf` |
| 软链必须用**相对路径** `dtb/xxx.dtb` | 一致 | `board-init.sh`：`ln -sf "dtb/$BOARD_DTB"` |
| `uEnv.txt` 也做成相对软链 `ln -sf $BOARD_uEnv /boot/uEnv/uEnv.txt` | 一致 | 同上 |
| 改完软链**必须重启**才生效 | 一致 | `board-init.sh` 末尾 `$REBOOT_CMD` |
| 板卡编号 = ADC ch2(高) + ch3(低)，10bit/12bit 两套阈值 | 一致 | `board-init.sh:get_index()` 两套 `ADC_INDEX`（229…/916…） |
| `board_info` 按 `compatible` 第三段分流 SoC | 一致 | `SOC_type=$(cut -d, -f 3 "$COMPAT_FILE")` |
| `devicetreedir /` 在 Rockchip U-Boot 下其实不生效 | **我们没走这条路**，用显式 `fdt /dtb/xxx.dtb`（见 3.6） | `configs/common/extlinux.conf` |
| `CONFIG_ENV_IS_NOWHERE`，`saveenv` 无效 | 一致（用厂商预编译 u-boot） | 未改动 u-boot 配置 |
| HWID（resource.img）选 dtb 只适用于 rkboot | 一致（extboot 无 resource 分区） | — |

---

## 三、不一致清单（按影响排序）

### 3.1 内核更新机制完全缺失（文档第四节的整节内容）

**文档**：`do_build_kerneldeb()` 用 `make bindeb-pkg` 产出 `linux-image-*.deb` /
`linux-headers-*.deb`，拷进 `/boot/kerneldeb/`；首启 `boot_init.sh` 执行
`apt install -fy --allow-downgrades /boot/kerneldeb/*`，再 `apt-mark hold` 钉版本，
最后 `rm -f /boot/kerneldeb/*`（一次性）。
deb 包内容直接落到 `/boot`（`Image-<ver>`、`dtb/`、`boot.cmd`、`boot.scr`、`uEnv/`），
**内核包同时负责更新启动脚本本身**。

**我们**：

```sh
# build_boot.sh:mk_extboot()
cp arch/arm64/boot/Image ${extboot_dir}/Image-${kernelrelease}
cp arch/arm64/boot/Image ${extboot_dir}/Image
cp System.map            ${extboot_dir}/System.map-${kernelrelease}
cp .config               ${extboot_dir}/config-${kernelrelease}
# 没有 kerneldeb/ 目录，没有任何 rpm/deb
```

- 产物里没有 `kerneldeb/`；`pkg/SPECS/` 只有 `camera-engine-rkaiq*`，**没有内核包**。
- `/boot` 里也没有 `boot.cmd`/`boot.scr` 的更新通路——换启动脚本只能重刷镜像。

**影响**：文档那套"装个包重启就换内核"的日常迭代路径在我们这里不存在；
调 dts 必须整包重编重刷（或手工 scp 文件＋自己记得改 uEnv）。

**建议**：openEuler 侧等价物是 rpm（`kernel-*.rpm`）。要么做一份"内核文件包"
（只需把 `Image-<ver>` + `dtb/` + `uEnv/` 打进 rpm，`%post` 里跑判板），
要么明确放弃这条路径并在 README 写明"内核只随镜像更新"。

---

### 3.2 `uname_r` 机制被 `/Image` 短路，多版本与回滚不可用

**文档**（4.4/4.5）：

```
uEnv.txt → uname_r=6.1.99-rt36-rk3576 → load /Image-6.1.99-rt36-rk3576
```
改 `uname_r` 就能切内核版本，`/boot` 可同时放多个 `Image-*`，回滚就是改一行文本。

**我们**（`scripts/configs/common/boot.cmd`）：

```
# 4) 内核：优先 /Image，回退 /Image-<uname_r>
if test -e ${devtype} ${devnum}:${distro_bootpart} /Image; then
  load ... ${kernel_addr_r} /Image
else
  load ... ${kernel_addr_r} /Image-${uname_r}
fi
```

`/Image` 永远存在（`mk_extboot` 每次都拷一份），所以**永远走第一分支**，
`uname_r` 只是摆设。想换内核得覆盖 `/Image` 本身。

**附带浪费**：`/Image` 与 `/Image-6.1.99-rk3588` 各 43,758,080 B，合计 87 MB，
boot 分区共 256 MB（Cat-3 是 512 MB），**三分之一的容量用来存同一份内核**。

**✅ 已修（P1）**：

- `build_boot.sh:mk_extboot()` 删掉 `cp Image ${extboot_dir}/Image`，只产 `Image-<kernelrelease>`；
- `boot.cmd` 第 4 步改为「`uname_r` 非空且 `/Image-<uname_r>` 存在 → 加载它，否则回退 `/Image`」
  （回退分支留给旧 boot 分区，属加法不是替换）；
- `mk_extboot` 里顺手把 `extlinux.conf` 的 `kernel /Image` 改写成
  `kernel /Image-<kernelrelease>`——否则 extlinux 兜底路径会因为 `/Image` 不存在而断掉。

效果：`uname_r` 恢复为真正的开关，改一行 uEnv 就能切内核/回滚；boot 分区省下 43 MB。

---

### 3.3 initrd 文件名固定为 `initrd.img`，不是 `initrd-<版本>`

- 文档：`initrd=initrd-6.1`，与 `uname_r` 一样是版本化的，可多版本共存。
- 我们：`mk_extboot` 里强行 `sed -i "/^uname_r=/a initrd=initrd.img"`，
  `boot_dir/initrd.img` 直接拷成 `/initrd.img`。

**影响**：换内核时 initrd 必须一起替换，无法保留旧的组合；回滚要靠人工。

---

### 3.4 `/boot` 的挂载与 fstab 不由首启脚本负责

**文档**（2.2）：`boot_init.sh` 自己从 `/proc/cmdline` 读 `root=` 与 `boot_part=`，
推出 boot 分区节点 → `mount` → **追加 fstab 条目**；并且先 `until [ -e /dev/disk/by-partlabel/boot ]` 等设备出现。

**我们**：

```sh
# build_rootfs.sh:333-334
echo "LABEL=rootfs  / ext4    defaults,noatime 0 0" >  ${rootfs_dir}/etc/fstab
echo "LABEL=boot  /boot ext2    defaults,noatime 0 2" >> ${rootfs_dir}/etc/fstab
```

fstab **构建期就写好**（用 LABEL），首启脚本不 mount、不改 fstab；
`lubancat-board-init.service` 用 `RequiresMountsFor=/boot` 声明依赖。

**差异带来的两个实际后果**：

1. 我们依赖 boot 分区**有 `boot` 卷标**（`mkfs.ext2 -L boot` 保证），文档方案靠分区号推算，
   不依赖卷标。卷标一旦丢（比如被重新 mkfs）→ `/boot` 挂不上 → 见 3.4.1。
2. 文档方案只在**首次** mount，之后靠 fstab；我们每次开机都要 mount。
   若 `/boot` 挂不上，`local-fs.target` 失败（fstab 条目没有 `nofail`）→
   `OnFailure=emergency.target` → 掉进 `sulogin` 维护 shell，
   **这正是 2026-11-27 那次"重新上电后进不了系统"的现象**（详见 `docs/troubleshooting.md`）。

**建议**：`/boot` 条目加 `nofail,x-systemd.device-timeout=10s`；
`lubancat-board-init` 已经有"`/boot` 不可用就跳过、下次再试"的判断，不会误写。

---

### 3.5 首启标记文件名不同：`.board_init` vs `boot_init`

- 文档 / 厂商：`/boot/boot_init`
- 我们：`FLAG=$BOOT/.board_init`（**带点**），见 `board-init.sh`

**影响**：按文档给的命令（`ls /boot/boot_init`、`rm /boot/boot_init` 重置判板）在
旧镜像上全部无效——排查时容易得出"判板没跑"的错误结论。

**✅ 已修（P2）**：标记改为 `/boot/boot_init`，unit 的 `ConditionPathExists=!/boot/boot_init` 同步。
为兼容已刷过老镜像的板子，脚本启动时会先把 `/boot/.board_init` `mv` 成新名字再判断，
所以不会被当成首启、白重启一次。`docs/troubleshooting.md` 里相关命令已全部改名。

---

### 3.6 extlinux 用显式 `fdt`，且写死板型

**文档**（2.8）：`devicetreedir /` 在 Rockchip U-Boot 下拼成 `-.dtb`，加载失败、label 被跳过，
实际永远走 `boot.scr`。

**我们**（`configs/common/extlinux.conf`，构建期 `sed` 替换 `DEVICETREE`）：

```
label openEuler
        kernel /Image
        initrd /initrd.img
        fdt /dtb/rk3588s-lubancat-4io.dtb      ← 显式路径，且是"构建时选的那块板"
        append  earlyprintk console=ttyS2,1500000 rw root=UUID=...
```

**影响**：
- 好处：万一 `boot.scr` 丢失/损坏，extlinux 这条兜底路径**能真的启动**（文档方案是死的）。
- 坏处：它写死板型 dtb，与"一份镜像通吃同族"冲突——把 4io 的镜像插到 Cat-5 上、
  且 `boot.scr` 又恰好损坏时，extlinux 会拿 4io 的 dtb 起 Cat-5，回到之前的"卡在 CPU 初始化"。
- 另外 `append` 里的 `console=ttyS2,1500000` 与 extboot `uEnv` 的 `console=ttyFIQ0`
  **不一致**（`build_boot.sh` 的 `rockchip_bootargs` 用的是 ttyS2）。

**✅ 已修（P1）**：

- `mk_boot()` 生成 extlinux 时，`extboot_generic_first=1` 的板子把 `fdt` 指向
  `dtb/${extboot_generic_dtb}`，兜底路径不再写死构建时选的板型；
- `rockchip_bootargs` 的 `console=ttyS2,1500000` 改为 `console=ttyFIQ0 console=tty1
  consoleblank=0 loglevel=7`，与 uEnv 的 `cmdline` 一致（`ttyS2` 被 fiq-debugger 占着）。

---

### 3.7 分区尺寸与文档不同

| 分区 | 文档（厂商 extboot） | 我们（rk3588 / Cat-4/5） | 我们（rk3576 / Cat-3） |
|---|---|---|---|
| uboot | 8 MiB | **4 MiB**（`0x2000@0x4000`） | 4 MiB |
| boot | 128 MiB | **256 MiB**（`boot_size=256`） | **512 MiB**（`boot_size=512`） |
| rootfs | grow | grow ✓ | grow ✓ |

不冲突，只是布局不同（所以 `boot` 起始偏移是 `0x6000` 而不是文档的 `0x8000`）。
boot 偏大主要是被 3.2 的双份 Image 撑起来的，双份去掉后可以回落到 128–192 MiB。

---

### 3.8 `root=` 是构建期 UUID，不是运行期 `part number`

**文档**（5.1）：

```
part number ${devtype} ${devnum} "rootfs" rootfs_part
setenv bootargs ${bootargs} root=/dev/mmcblk${devnum}p${rootfs_part} boot_part=${distro_bootpart} ${cmdline}
```

**我们**（`boot.cmd` 第 16 行）：

```
setenv bootargs ${cmdline} boot_part=${distro_bootpart}
```

`root=UUID=...` 是在 `mk_extboot` 里写进每个 `uEnv*.txt` 的 `cmdline`（占位值
`614e0000-…-54a9`），再由 `gen_rk_update.sh` 把 `rootfs.img` 的 UUID 改写成同一个值。

**评价**：UUID 比 `mmcblkXpN` 更抗设备号漂移（SD/eMMC 换号不影响），这一点比文档方案好；
但代价是 **rootfs 一旦重新 mkfs 而没走 `gen_rk_update` 改 UUID，就必然挂不上根**，
而 `part number` 方案没有这个耦合。目前 `gen_rk_update.sh` 里已有该步骤并有注释说明，
属于"已知且受控"的差异。

---

### 3.9 通用屏自动适配（gsdt）没有实现

**文档**（5.3）：`boot.cmd` 里 `i2c bus` / `i2c md ${eeprom_addr}` 读背板 EEPROM，
命中就 `fdt apply` 对应 dtbo；`enable_gsdt_auto_load=1` 时启用。

**我们**：
- `configs/common/boot.cmd` **完全没有 i2c/gsdt 段**（只有 `dtfile` 那条 overlay 路径）。
- `mk_extboot` 还主动把每个 uEnv 的 `enable_gsdt_auto_load` 改成 `0`：

```sh
sed -i "s|^enable_gsdt_auto_load=.*|enable_gsdt_auto_load=0|" "$f"
# 注释：无屏场景默认关闭 gsdt 自动探测，避免 i2c 探测噪声
```

**影响**：板型 uEnv 里 `eeprom_addr=0x51`、`i2c_devs=2 5`、`gsdt_plugin0/1` 这些变量
**填了也没用**——U-Boot 脚本里没有人读它们。想靠"插不同的屏自动点亮"目前做不到，
只能手工把 `#dtoverlay=...` 放开。

**✅ 已移植（P2，默认关闭）**：`configs/common/boot.cmd` 第 9 步按厂商 `boot.cmd` 同构实现：

```
if test "${enable_gsdt_auto_load}" = "1" && test -n "${i2c_devs}"; then
  i2c bus → i2c dev ${dev} → i2c md "${eeprom_addr}" 0 1
  命中就 load ${gsdt_plugin0|gsdt_plugin1} → fdt apply
```

前置条件（命令缺失 / 总线不存在 / EEPROM 无应答）全部用 `if test $? -eq 0` 兜住，整段跳过。

**仍默认关闭**：`mk_extboot` 继续把 `enable_gsdt_auto_load` 写成 `0`，理由是
"插上就亮"这条路径没有实机验证过亮屏，无屏板子上还会多一轮 i2c 扫描噪声。
要启用：改 `/boot/uEnv/<板>.txt` 里那一行为 `1` 后重启（`docs/building.md` 已写步骤）。
等有屏可测时，再决定要不要把默认值改回厂商的 `1`。

---

### 3.10 没有开机 logo

- 文档（2.2）：首启 `cp -f /boot/logo_kernel.bmp /boot/logo.bmp`，U-Boot 阶段显示开机图。
- 我们：`extboot/` 目录里**没有** `logo.bmp` / `logo_kernel.bmp`，`board-init.sh` 也没有这一步。

**影响**：U-Boot 阶段黑屏到内核接管（HDMI 上表现为"很久才有画面"）。
要加的话需要往 boot 分区放 `logo.bmp`（U-Boot 侧还需 `CONFIG_VIDEO_BMP_LOGO` 等配置）。

---

### 3.11 `board-init` 少做了文档里的几个动作

`board-init.sh` 头部注释里已明确"剪掉仅 Debian 才成立的段"，逐项确认：

| 文档动作 | 我们 | 说明 |
|---|---|---|
| `service lightdm stop` | 未做 | 我们换 dtb 后直接 reboot，不需要停显示管理器 |
| `apt install /boot/kerneldeb/*` | 未做 | 无内核包（3.1） |
| `apt-mark hold` | 未做 | 同上 |
| `rm -f /boot/kerneldeb/*` | 未做 | 同上 |
| `cp logo_kernel.bmp logo.bmp` | 未做 | 3.10 |
| `wait /dev/disk/by-partlabel/boot` + `mount /boot` | 未做 | 3.4（靠 fstab + `RequiresMountsFor`） |
| 判断 `userdata` 分区区分 rkboot 布局 | 未做 | 我们只出 extboot，`userdata` 分支无用 |
| 写 `/etc/lubancat/board-name` | **我们有，文档没有** | 额外产物，便于用户态查板型 |

另一处结构性差异：厂商是 **SysV `init.d` 脚本**（`etc/init.d/boot_init.sh`），
我们是 **systemd oneshot**（`lubancat-board-init.service`，`After=local-fs.target`、
`Before=getty.target`、`ConditionPathExists=!/boot/.board_init`）。功能等价。

---

### 3.12 扩容：自写脚本，且刻意不改分区表

**文档**（3.2）：`resize-disk.sh`（`/var/lib/misc/firstrun` 一次触发）
→ `resize-helper` 分发 → `disk-helper` 的 `resize_part`，
三个标记文件 `firstrun` / `.resized` / `.fixed`。

**我们**（`overlay/lubancat-5/usr/libexec/lubancat/growfs-rootfs.sh` + `lubancat-growfs.service`）：

- **只 `resize2fs`，绝不改分区表**；分区由加载器按 `parameter.txt` 的 `rootfs:grow` 铺满。
- 幂等方式不是标记文件，而是每次开机比对 `dumpe2fs` 的 `Block count` 与
  `/sys/class/block/<dev>/size`，相等即退出（约 10 ms）。
- 额外保护：`fs > partition` 时报错并拒绝 resize（历史上 alpha7 就是被运行期改分区表搞 brick 的）。

**评价**：这条差异是**我们更好**——文档方案会在运行期动分区表，掉电/重刷时容易
出现 `bad geometry` 起不来。这条建议保持，并写进文档作为与厂商的明确偏离。

---

### 3.13 `boot.cmd` 里两个文档没提的 workaround

我们的 `boot.cmd` 比文档多两段，都是踩过坑补的（值得写进文档，否则以后有人"优化"掉就复发）：

1. **`setenv dev_bootpart ${devnum}:${distro_bootpart}`**
   `dtoverlay/dtoverlay.c` 用 `env_get("devtype")` + `env_get("dev_bootpart")` 定位 dtbo；
   distro boot 只设 `devtype`/`devnum`，缺这行会输出 `mmc <NULL>`、读 dtbo 失败（err -9），
   随后 `fdt_overlay_apply` 作用在垃圾数据上 → **SError 复位**。
2. **`setenv size ${uenv_size}`**
   `cmd/dtfile.c` 把 env 的 `size` 当成 uEnv.txt 的**文本长度**去 `malloc`；
   uEnv 模板里写的是 `size=0x1000000`（16 MiB），拿不到整块连续堆时 malloc 失败，
   而 `dtfile` 失败也 `return 0`（看着像成功），overlay 全部静默跳过，
   串口只留一句 `can't malloc 16777217 bytes`。

3. **gsdt 段的 `setenv dev_bootpart`**
   第 9 步要用 `load` 取 dtbo，同样依赖 `dev_bootpart`。所以这一行已从 overlay 段里
   **提到第 7 步（两段之前）**，避免只在 `enable_uboot_overlays=1` 时才设。

> 顺带：uEnv 模板里的 `size=0x1000000`（16 MiB）是陷阱值 —— **✅ 已修（P2）**，
> `mk_extboot` 的 uEnv 循环里加了 `sed -i "s|^size=.*|size=0x8000|"`，
> 与 boot.cmd 用真实文件长度覆盖形成双保险。

---

### 3.14 首启（generic）阶段没有显示 overlay

`extboot_generic_first=1` 时，初始 `uEnv/uEnv.txt` = `uEnvLubanCat.txt`（generic），内容是：

```
enable_uboot_overlays=0
#overlay_start
#dtoverlay=
#overlay_end
```

而板型 uEnv（如 `uEnvLubanCat4IO.txt`）是 `enable_uboot_overlays=1` + 两行实际 dtoverlay。

**影响**：首次启动那一次（generic dtb + 无 overlay）**HDMI/DP 输出可能不亮**，
board-init 判板重启后才正常。这不是 bug（厂商方案同样如此），
但用户第一次上电容易误判成"显示坏了"，建议写进 README/首启说明。

---

### 3.15 bootargs 末尾有 U-Boot 追加的字段

实机 `Kernel command line`：

```
earlyprintk console=ttyFIQ0 console=tty1 consoleblank=0 loglevel=7 rootwait rw
rootfstype=ext4 root=UUID=6f1c2a10-… rd.shell boot_part=2
#d-11/20/2026 androidboot.fwver=ddr-v1.19-…,spl-v1.13,bl31-v1.51,bl32-v1.20,uboot-a564b1d
```

`#d-…`、`androidboot.fwver=` 是 Rockchip U-Boot 自己追加的（文档 4.5 提过
`board_fdt_chosen_bootargs()` 会把 dtb 的 bootargs 合并进来、同名以 dtb 为先）。
内核随后报 `Unknown kernel command line parameters "earlyprintk #d-11/20/2026 boot_part=2"`。

**无害**，但排查内核参数时容易被这一段带偏，值得在排错文档里写一句。

---

## 四、优先建议（等你拍板）

| 优先级 | 事项 | 状态 | 说明 |
|---|---|---|---|
| P0 | `/boot` fstab 加 `nofail,x-systemd.device-timeout=10s`；`boot_fs` 考虑换 ext4 | **按决定不做** | 掉电后仍可能掉进维护 shell，靠现场 `fsck -y /dev/mmcblk0p2` 恢复 |
| P1 | 去掉重复的 `/Image`，`boot.cmd` 改 `load /Image-<uname_r>` | ✅ 已完成 | 恢复多版本/回滚；boot 分区省 43 MB |
| P1 | extlinux `fdt` 改 generic；`rockchip_bootargs` 的 `ttyS2` 改 `ttyFIQ0` | ✅ 已完成 | 兜底路径不再写死板型；串口参数统一 |
| P2 | 首启标记改名 `boot_init`（带老标记迁移） | ✅ 已完成 | 与厂商文档命令兼容 |
| P2 | uEnv 的 `size=0x1000000` 改 `0x8000` | ✅ 已完成 | 去掉 dtfile malloc 隐患 |
| P2 | gsdt 自动识别屏：移植 | ✅ 已移植（默认关） | 能力就位，等有屏时验证亮屏再改默认值 |
| P3 | 内核以 rpm 形式更新 | 待决策 | 见第四章计划 |
| P3 | 开机 logo（`logo.bmp`） | 待决策 | 缩短"黑屏等待"的观感问题 |

### 本轮改动清单（2026-11-27，P1 + P2）

| 文件 | 改动 |
|---|---|
| `scripts/configs/common/boot.cmd` | 内核优先 `/Image-<uname_r>`；`dev_bootpart` 提前；移植 gsdt 段 |
| `scripts/build_boot.sh` | 只产 `Image-<ver>`；extlinux 内核名/兜底 fdt；uEnv 的 `size`；`rockchip_bootargs` 控制台 |
| `scripts/overlay/common/usr/libexec/lubancat/board-init.sh` | 标记改 `boot_init` + 老标记迁移 |
| `scripts/overlay/common/etc/systemd/system/lubancat-board-init.service` | `ConditionPathExists` 同步 |
| `build/check_l3_ui.sh` | 新增 6 条断言（无裸 `/Image`、版本化内核、extlinux 两处、`size`、gsdt 默认值） |
| `docs/{building,troubleshooting,upstream-sync}.md` | boot 分区内容清单、换内核/gsdt 步骤、标记改名、偏离登记 |

---

## 五、证据索引

| 结论 | 位置 |
|---|---|
| extboot 组装（Image / dtb / uEnv / boot.cmd / boot.scr / initrd） | `scripts/build_boot.sh:mk_extboot()` |
| boot.img = `truncate ${boot_size}M` + `mkfs.ext2 -L boot -d` | `scripts/build_boot.sh:mk_boot()` |
| 内核加载顺序（`/Image` 优先） | `scripts/configs/common/boot.cmd` 第 26-30 行 |
| overlay 应用与两个 workaround | `scripts/configs/common/boot.cmd` 第 41-61 行 |
| extlinux 模板（`fdt /dtb/<板>.dtb`） | `scripts/configs/common/extlinux.conf`，`mk_boot()` 里 sed 替换 |
| 首启判板 / 软链 / 标记 / reboot | `scripts/overlay/common/usr/libexec/lubancat/board-init.sh` 第 340-380 行 |
| fstab 构建期写入 | `scripts/build_rootfs.sh` 第 333-334 行 |
| parameter.txt 生成（uboot/boot/rootfs:grow） | `scripts/gen_rk_update.sh` 第 150-165 行 |
| rootfs UUID 与 uEnv `root=` 对齐 | `scripts/gen_rk_update.sh` 第 4 步注释段 |
| 扩容（只 resize2fs） | `scripts/overlay/lubancat-5/usr/libexec/lubancat/growfs-rootfs.sh` |
| 板级尺寸 | `scripts/boards/lubancat-{3,4,4io,5}.conf` 的 `boot_size` |
| 实机启动路径 | `serial-log.txt`：`DTB(Distro): rk-kernel.dtb` / `Found U-Boot script /boot.scr` / `[boot.cmd] overlays applied` |
