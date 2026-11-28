%global debug_package %{nil}
%global __os_install_post %{nil}

# kver / kv / rel 由 tools/build-kernel-rpm.sh 用 --define 传入：
#   kver = kernelrelease（6.1.99-rk3588，带 SoC 后缀，用于文件名）
#   kv   = 版本段（6.1.99）—— RPM 的 Version 不允许出现 '-'
#   rel  = release（1.lbc5.rk3588）—— 尾部带 SoC，避免 rk3576/rk3588 包互相顶替
%{!?kver:%global kver 6.1.99-rk3588}
%{!?kv:%global kv 6.1.99}
%{!?rel:%global rel 1.lbc5.rk3588}

Name:           kernel-lubancat
Version:        %{kv}
Release:        %{rel}
Summary:        LubanCat kernel image, dtb and dtbo (extboot layout)
License:        GPL-2.0-only
URL:            https://gitee.com/openeuler/yocto-meta-openeuler
BuildArch:      aarch64
AutoReqProv:    no

# Image 与 modules 版本错配是这类机制最容易出的事故：装一半、或 Image 新而
# /lib/modules 旧，表现是"能进 initramfs 但根挂不上"。用 Requires 锁死版本。
Requires:       kernel-lubancat-modules = %{version}-%{release}

# %pre 用 findmnt（util-linux）、df（coreutils）
Requires(pre):  util-linux coreutils

%description
LubanCat 内核的启动载荷，按 extboot 布局落盘：

  /boot/Image-<kver>         内核
  /boot/System.map-<kver>    符号表
  /boot/config-<kver>        内核配置
  /boot/initrd-<kver>        initramfs（与内核版本配对）
  /boot/dtb/*.dtb            全族设备树
  /boot/dtb/overlay/*.dtbo   设备树插件

装包后 `%post` 会把**板上现有** uEnv 的 `uname_r` / `initrd` 改指向新版本，
reboot 即生效；旧版本文件保留，起不来时改回 uname_r 就能回滚。

**刻意不包含 `/boot/uEnv/*.txt`**：uEnv 里除了 uname_r/initrd，还有 `cmdline="... root=UUID=..."`
这种只能由**镜像打包**决定的变量（`gen_rk_update.sh` 在打包时才把占位 UUID 换成真实值）。
内核包若携带 uEnv，装机就会把板上的正确 root=UUID 覆盖成构建期占位值 ——
实际发生过一次：装完重启卡在 `Waiting for /dev/disk/by-uuid/614e0000-...`。
所以 uEnv 归镜像管，内核包只改其中的两行。
代价：新增的 `dtoverlay=` 启用行不会随内核包下发（dtbo 文件本身会更新），
需要手工加一行或等镜像更新。

刻意不包含：boot.cmd / boot.scr（一个内核包改坏启动脚本，串口都救不回来）、
rk-kernel.dtb（它由 board-init 用软链管理，覆盖会破坏"一份镜像通吃同族"）。

%install
rm -rf %{buildroot}
S=%{_sourcedir}/extboot

[ -s "$S/Image-%{kver}" ]        || { echo "ERROR: 缺 $S/Image-%{kver}（先跑 tools/build-image.sh --stage kernel）" >&2; exit 1; }
[ -s "$S/initrd-%{kver}" ]       || { echo "ERROR: 缺 $S/initrd-%{kver}（先跑 --stage boot）" >&2; exit 1; }
[ -s "$S/System.map-%{kver}" ]   || { echo "ERROR: 缺 $S/System.map-%{kver}" >&2; exit 1; }

install -Dm644 "$S/Image-%{kver}"      %{buildroot}/boot/Image-%{kver}
install -Dm644 "$S/System.map-%{kver}" %{buildroot}/boot/System.map-%{kver}
install -Dm644 "$S/initrd-%{kver}"     %{buildroot}/boot/initrd-%{kver}
[ -s "$S/config-%{kver}" ] || { echo "ERROR: 缺 $S/config-%{kver}" >&2; exit 1; }
install -Dm644 "$S/config-%{kver}"     %{buildroot}/boot/config-%{kver}

mkdir -p %{buildroot}/boot/dtb/overlay
cp -a "$S"/dtb/*.dtb          %{buildroot}/boot/dtb/
cp -a "$S"/dtb/overlay/*.dtbo %{buildroot}/boot/dtb/overlay/

# 不装 uEnv：见 %description 里的说明（会把 root=UUID 覆盖成构建期占位值）。
# %post 改成"就地修改板上现有文件"，只动 uname_r / initrd 两行。

# 兜底断言：万一以后有人把 uEnv 加回载荷，这里直接失败
if ls "$S"/uEnv/*.txt >/dev/null 2>&1; then
    echo "WARN: $S/uEnv 下有 txt（不会被装进包；uEnv 归镜像管）" >&2
fi

%pre
# 构建机 / 离线 chroot：由 build_rootfs.sh 写的标记，跳过挂载与空间检查
if [ -f /etc/lubancat/build-host ]; then
    echo "kernel-lubancat: /etc/lubancat/build-host 存在（构建机或离线 chroot），跳过检查"
    exit 0
fi

# /boot 必须是独立挂载的分区。否则 Image 会写进 rootfs 的 /boot 目录：
# rpm 报成功、reboot 还是旧内核，是最难查的一类"装了没生效"。
if ! findmnt -no FSTYPE /boot >/dev/null 2>&1; then
    echo "ERROR: /boot 未挂载（应为 LABEL=boot 的独立分区）。" >&2
    echo "       现在装会把 Image 写进 rootfs 的 /boot 目录，重启仍是旧内核。" >&2
    echo "       先确认 fstab 并 mount /boot，再重试。" >&2
    exit 1
fi

avail=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$avail" ] || avail=0
# 单版本实测约 68.5 MiB（Image 41.7 + initrd 19.7 + System.map 6.6 + config 0.2），
# dtb/dtbo 全族共用会被覆盖、不重复占空间。阈值 100 MiB 留出余量。
if [ "$avail" -lt 100 ]; then
    echo "ERROR: /boot 剩余 ${avail} MiB，至少需要 100 MiB。" >&2
    echo "       可先删一个旧版本：" >&2
    echo "       ls -1t /boot/Image-* | tail -n +3 | sed 's|.*/Image-||'" >&2
    exit 1
fi

%post
if [ -f /etc/lubancat/build-host ]; then
    echo "kernel-lubancat: /etc/lubancat/build-host 存在，跳过 uname_r 改写与清理"
    exit 0
fi

KVER=%{kver}

# 1) 把当前在用的 uEnv 指到新版本。
#    必须绕开软链：sed -i 会把 /boot/uEnv/uEnv.txt 这个软链替换成普通文件，
#    之后 board-init 换板型时再也改不动它。所以先 readlink -f 取实体。
TARGET=$(readlink -f /boot/uEnv/uEnv.txt 2>/dev/null)
if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
    sed -i "s|^uname_r=.*|uname_r=${KVER}|" "$TARGET"
    sed -i "/^initrd=/d" "$TARGET"
    sed -i "/^uname_r=/a initrd=initrd-${KVER}" "$TARGET"
fi

# 其余板型文件也一起改，方便同一张卡换板；find -type f 天然跳过软链
for f in $(find /boot/uEnv -maxdepth 1 -name 'uEnv*.txt' -type f 2>/dev/null); do
    sed -i "s|^uname_r=.*|uname_r=${KVER}|" "$f"
    sed -i "/^initrd=/d" "$f"
    sed -i "/^uname_r=/a initrd=initrd-${KVER}" "$f"
done

# 2) 清理旧版本：保留"当前 + 最近 1 个"共 2 版（约 143 MiB / 256 MiB）。
#    绝不删当前 uname_r 指向的那版。
n=0
for img in $(ls -1t /boot/Image-* 2>/dev/null); do
    v=${img##*/Image-}
    [ "$v" = "$KVER" ] && continue
    n=$((n+1))
    [ "$n" -ge 2 ] || continue
    rm -f "/boot/Image-$v" "/boot/System.map-$v" "/boot/config-$v" "/boot/initrd-$v"
    echo "kernel-lubancat: 已清理旧版本 $v"
done

# 3) 自检：装完立刻把结果打在命令行上，避免"装完了但不确定"
echo "kernel-lubancat: 已安装 Image-${KVER}"
echo "  uname_r      = $(sed -n 's/^uname_r=//p' /boot/uEnv/uEnv.txt 2>/dev/null | head -1)"
echo "  initrd       = $(sed -n 's/^initrd=//p' /boot/uEnv/uEnv.txt 2>/dev/null | head -1)"
echo "  dtb / dtbo   = $(ls /boot/dtb/*.dtb 2>/dev/null | wc -l) / $(ls /boot/dtb/overlay/*.dtbo 2>/dev/null | wc -l)"
echo "  保留的版本   = $(ls -1 /boot/Image-* 2>/dev/null | sed 's|.*/Image-||' | tr '\n' ' ')"
echo "  reboot 生效；起不来就在 U-Boot 里把 uname_r 改回旧版本（或 extlinux 兜底）"

%files
%defattr(-,root,root,-)
/boot/Image-%{kver}
/boot/System.map-%{kver}
/boot/config-%{kver}
/boot/initrd-%{kver}
/boot/dtb/*.dtb
/boot/dtb/overlay/*.dtbo

%changelog
* Sat Nov 28 2026 LubanCat <dev@lubancat> - %{kv}-%{rel}
- initial kernel rpm for extboot layout
