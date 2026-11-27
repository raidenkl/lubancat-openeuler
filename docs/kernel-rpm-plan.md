# P3 实施计划：内核以 rpm 形式更新（`kerneldeb` 的 openEuler 等价物）

> 状态：**未执行，等决策**
> 目标：把厂商那套「拷 deb 到 `/boot/kerneldeb` → 首启 `apt install` → 重启换内核」
> 换成 openEuler 的做法，让"换内核"不再等于"重刷整包镜像"。
> 参照文档：`extboot的三个特殊机制.md` 第四节。

---

## 一、目标与非目标

**要做到的**

```sh
# 板上，有新内核包时
rpm -ivh kernel-lubancat-6.1.99-rk3588-x.y.z.aarch64.rpm
reboot
uname -r          # 变成新版本
```

- 一次装包同时更新：`Image-<ver>`、`System.map`、`config`、`/lib/modules/<ver>`、
  `dtb/*.dtb`、`dtb/overlay/*.dtbo`、`uEnv/*.txt`（含 `uname_r`）、`initrd`
- 旧内核保留，能回滚（改一行 `uname_r` 重启）
- 装包失败 / 空间不足 / `/boot` 没挂载时**明确报错**，不产生"装成功但起不来"

**不做的**

- 不做 dnf 仓库（`repodata`）。就 `rpm -ivh`，与现有 rkaiq 包一致。
- 不动 `boot.scr`。厂商的 deb 会覆盖 `boot.cmd`/`boot.scr`，风险太大
  （一个内核包把启动脚本改坏，串口都救不回来）。
- 不改 U-Boot（`CONFIG_ENV_IS_NOWHERE` 保持原样）。

---

## 二、包结构（建议双包）

| 包名 | 内容 | 大小（估） |
|---|---|---|
| `kernel-lubancat` | `/boot/Image-<kver>`、`System.map-<kver>`、`config-<kver>`、`/boot/dtb/*.dtb`、`/boot/dtb/overlay/*.dtbo`、`/boot/uEnv/*.txt` | ~45 MB 装完 |
| `kernel-lubancat-modules` | `/lib/modules/<kver>/` | 100–250 MB |

拆开的理由：
- 只改了 dts / 内核配置项（模块没变）时可以只装 image 包；
- modules 包体积大，单独存在便于在 SD 卡上按需拷贝；
- 依赖方向单一：`kernel-lubancat` **Requires** 同版本的 `kernel-lubancat-modules`（保证 Image 和 modules 版本一致，这是最容易出事的地方）。

> 也可以打成一个包（厂商 deb 就是 image 里带 modules）。是否拆开是**决策点 1**。

---

## 三、关键实现点（每个都是坑）

### 3.1 `/boot` 必须是独立挂载的分区，否则拒绝安装

`/boot` 在 rootfs 里是**空目录**，真机上挂的是 ext2 分区。如果 `/boot` 没挂上，
rpm 会把 43 MB 的 Image 写进 rootfs 的 `/boot` 目录——看着装成功了，重启还是老内核
（我们刚在 11-27 那次 emergency 里见过同一个坑的另一面）。

`%pre` 里加：

```sh
findmnt -no FSTYPE /boot >/dev/null 2>&1 || {
    echo "ERROR: /boot 未挂载（应为 LABEL=boot 的 ext2 分区），拒绝安装" >&2
    exit 1
}
```

### 3.2 构建期不能真的装进 rootfs

镜像构建时 rootfs 是干净的，`/boot` 是空目录。如果 `%post` 在构建期也跑，
要么写进 rootfs（镜像里多一份 43 MB 重复），要么因为"没挂载"直接失败。

照厂商的做法加一个构建机标记：

```sh
%post
if [ -f /boot/build-host ] || [ ! -f /etc/lubancat/board-name ]; then
    echo "build host / 非目标系统，跳过内核切换动作"
    exit 0
fi
...
```

`build_rootfs.sh` 在装完包后 `touch ${rootfs_dir}/boot/build-host`；
首启 `firstboot.sh` 里 `rm -f /boot/build-host`。

### 3.3 `uname_r` 必须跟着改，而且只改"当前在用的"

`boot.cmd` 现在按 `uEnv/<板>.txt` 的 `uname_r` 加载 `Image-<ver>`。
装包后要把它改成新版本，否则重启还是旧内核（典型的"装了没生效"）。

```sh
%post
KVER=%{kver}
for f in /boot/uEnv/*.txt; do
    sed -i "s|^uname_r=.*|uname_r=${KVER}|" "$f"
done
```

**注意**：`/boot/uEnv/uEnv.txt` 是软链（指向板型那份），`sed -i` 会替换软链本身
（变成普通文件），导致板型 uEnv 以后再也不会被 `board-init` 切换。
所以：

```sh
TARGET=$(readlink -f /boot/uEnv/uEnv.txt)      # 解析到实板那份
sed -i "s|^uname_r=.*|uname_r=${KVER}|" "$TARGET"
# 其余板型文件也改，便于同一张卡换板；但绝不能碰 uEnv.txt 这个软链
find /boot/uEnv -name 'uEnv*.txt' -type f -exec sed -i "s|^uname_r=.*|uname_r=${KVER}|" {} +
```

### 3.4 initrd 必须重建，而且**要版本化**

现状：`initrd.img` 单个固定名字，`mk_initrd.sh` 是构建期 chroot 进 rootfs 生成的。
板上换内核后，initrd 里带的模块版本还是旧的 → 若 initrd 依赖的模块（storage/keyboard 等）
路径对不上，会挂不上根。

两种做法：

| 方案 | 做法 | 代价 |
|---|---|---|
| A. 板上重建 | `%post` 里 `dracut -f --kver <ver> /boot/initrd-<ver>` | 装包多花 30–60 s；板上要有 dracut（有） |
| B. 包里带现成的 | 构建期打好 initrd 一起打进 rpm | 包再大 ~15 MB；构建期必须已经能 chroot 生成（已有 `mk_initrd.sh`） |

建议 **B**（构建期生成，稳定可复现），失败才退化成 A。

同时要把 initrd 版本化，否则回滚时"旧 Image + 新 initrd"照样跑不起来：

```
/boot/initrd-<kver>
```

`boot.cmd` 第 3 步改成：

```
if test -n "${initrd}"; then                       # 老镜像仍可用 initrd.img
  load ... /${initrd}
fi
if test -n "${uname_r}" && test -e ... /initrd-${uname_r}; then
  load ... /initrd-${uname_r}                      # 版本化优先
fi
```

`mk_extboot` 也要改成产 `initrd-<kernelrelease>`（并保留一份 `initrd.img` 给旧流程/兜底）。

> 这条会改 `boot.cmd` 与 `mk_extboot`，是本次 P3 里唯一"碰到启动路径"的改动，
> 也是**决策点 2**（要不要现在就版本化 initrd）。

### 3.5 modules 与 depmod

```sh
%post modules
depmod -a %{kver}
```

`depmod` 在板上跑（aarch64 原生），不能像 `gen_rk_update.sh` 那样在 x86 构建机
用 `depmod -b` 代替——那是给"离线灌进 rootfs"用的，装包场景板上跑更准。

### 3.6 boot 分区空间与保留策略

Cat-4/5 的 boot 分区 256 MB，算一下：

```
Image-<ver>      43 MB × N
initrd-<ver>     14 MB × N
dtb + dtbo       ~5 MB
System.map       7 MB × N
uEnv + 脚本      <1 MB
```

N=2 约 128 MB，N=3 约 192 MB，N=4 就满了。
`%pre` 里做**空间预检**（留 20 MB 余量），`%post` 里做**清理**（保留最近 2 个版本，
且绝不删当前 `uname_r` 指向的那个）：

```sh
keep=2
# 按 mtime 排序，跳过当前 uname_r 对应版本
```

> 或者把 rk3588 的 `boot_size` 从 256 提到 512（Cat-3 已经是 512）。
> 这是**决策点 3**——扩分区意味着已出的镜像必须重刷才能升级。

### 3.7 失败可见性

`%post` 里任何一步失败都要 `exit 1`（rpm 会回滚 %post 的失败？不会回滚文件，
但至少事务报错、命令行能看到）。另外装完打一行"自检结果"：

```
新内核: Image-6.1.99-rk3588 / uname_r=6.1.99-rk3588 / modules=xxx
旧内核保留: Image-6.1.99-rk3588-old
重启生效；出问题在 U-Boot 里把 uname_r 改回旧版本
```

---

## 四、交付物清单

| 文件 | 说明 | 新增/修改 |
|---|---|---|
| `pkg/SPECS/kernel-lubancat.spec` | image + dtb + uEnv + initrd 的包 | 新增 |
| `pkg/SPECS/kernel-lubancat-modules.spec` | `/lib/modules/<kver>` | 新增 |
| `tools/build-kernel-rpm.sh` | 从 `scripts/build/kernel` 取产物打包，产出到 `scripts/bin/rpms/<soc>/` | 新增 |
| `scripts/build.sh` | 新增 `--stage kernelrpm`（编完内核后打，可选） | 修改 |
| `scripts/configs/common/boot.cmd` | initrd 版本化 + 回退 | 修改 |
| `scripts/build_boot.sh` | 产 `initrd-<kver>`；`mk_extboot` 同步 | 修改 |
| `scripts/build_rootfs.sh` | 装完包 `touch /boot/build-host` | 修改 |
| `scripts/overlay/.../firstboot.sh` | `rm -f /boot/build-host` | 修改 |
| `build/check_kernel_rpm.sh` | 在容器里 `rpm2cpio` 校验包内容、大小、依赖 | 新增 |
| `docs/building.md` / `docs/troubleshooting.md` | 升级/回滚步骤、空间不足、装完没生效 | 修改 |

---

## 五、验收步骤（每步都可离线做，除了最后一步）

1. `tools/build-kernel-rpm.sh --soc rk3588` → 产出两个 rpm
2. `rpm2cpio kernel-lubancat-*.rpm | cpio -t` → 文件清单与预期一致
3. 在**已运行镜像的 rootfs 副本**上 `chroot … rpm -ivh --nodeps`（模拟板上，
   但把 `/boot` 先用 `mount -o loop boot.img` 挂成一个独立分区）→
   校验 `/boot/Image-<新ver>` 存在、`uname_r` 已改、软链 `uEnv.txt` **仍是软链**
4. 故意不挂 `/boot` 再装一次 → 应报"拒绝安装"
5. 板上实装（需要你操作，我不自行刷机）：`rpm -ivh …` → `reboot` → `uname -r` → 回滚一次

---

## 六、风险与回滚

| 风险 | 缓解 |
|---|---|
| 新内核起不来 | 旧 `Image-<ver>` 不删；U-Boot 里改 `uname_r`，或 `extlinux` 兜底 |
| 装完没生效（`/boot` 未挂载） | `%pre` 强制 `findmnt /boot` |
| Image 与 modules 版本错配 | 两个包用 `Requires: kernel-lubancat-modules = %{version}-%{release}` 锁死 |
| boot 分区写满 | `%pre` 空间预检 + `%post` 保留 2 版 |
| initrd 与内核错配 | initrd 版本化（3.4） |

---

## 七、工作量与决策点

**工作量**：约 2 个新脚本 + 2 个 spec + 3 处小改 + 文档，估计 4–6 小时（含打包调试），
不涉及内核代码。

**需要你拍板的四件事**

1. **单包还是双包**（image+modules 合一 / 拆开）—— 建议拆开。
2. **initrd 要不要现在就版本化** —— 建议要，否则回滚只能"旧 Image + 新 initrd"。
3. **rk3588 的 boot 分区要不要从 256 MB 扩到 512 MB** —— 扩了能存 3–4 个内核，
   但已出的镜像必须重刷才能享受（分区表在烧写时定型）。
4. **镜像是否预装内核 rpm** —— 建议不预装：`/boot` 继续由构建灌注，rpm 只作升级通道，
   避免"同一份内核在镜像里存两遍"（那正是我们刚在 P1 里省掉的 43 MB）。
