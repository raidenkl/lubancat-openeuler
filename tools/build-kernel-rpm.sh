#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# build-kernel-rpm.sh —— 把已编好的内核产物打成两个 rpm，供板上 `rpm -ivh` 换内核。
#
#   kernel-lubancat           Image / System.map / config / initrd / dtb / dtbo（**不含 uEnv**）
#   kernel-lubancat-modules   /lib/modules/<kver>
#
# 前置：`--stage kernel`（要有 Image/System.map/config/模块树）与 `--stage boot`
#       （要有 initrd-<kver>，它是 chroot 进 rootfs 生成的，所以本脚本必须排在 bootimg 之后）。
#
# 产物：scripts/bin/rpms/<soc>/kernel-lubancat-<ver>-<rel>.<arch>.rpm
#
# 用法：
#   tools/build-kernel-rpm.sh --soc rk3588
#   tools/build-kernel-rpm.sh --soc rk3588 --out /tmp/rpms
#   tools/build-kernel-rpm.sh --soc rk3588 --list     # 只打印将要打包的文件，不打包
#
set -e

PROG=$(basename "$0")
REPO=$(cd "$(dirname "$0")/.." && pwd)

soc=""
out_dir=""
list_only=0

usage() {
    cat <<'EOF'
build-kernel-rpm.sh —— 把已编好的内核产物打成两个 rpm（image + modules）

用法:
  tools/build-kernel-rpm.sh --soc <rk3588|rk3576> [--out DIR] [--list]

  --soc NAME   目标 SoC 家族，决定 Release 后缀与默认输出目录 scripts/bin/rpms/<soc>/
  --out DIR    覆盖输出目录
  --list       只打印将打包的文件与体积，不执行 rpmbuild

前置:
  --stage kernel  产出 Image/System.map/config/模块树
  --stage boot    产出 initrd-<kver>（chroot 进 rootfs 生成，所以本脚本必须排在 bootimg 之后）
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --soc)      soc=$2; shift 2 ;;
        --soc=*)    soc=${1#*=}; shift ;;
        --out)      out_dir=$2; shift 2 ;;
        --out=*)    out_dir=${1#*=}; shift ;;
        --list)     list_only=1; shift ;;
        -h|--help)  usage ;;
        *) echo "$PROG: 未知参数 $1" >&2; usage ;;
    esac
done

[ -n "$soc" ] || { echo "$PROG: 必须指定 --soc（rk3588 / rk3576）" >&2; exit 2; }

# ---------- 0. rpmbuild 在不在；不在就自动进构建容器 ----------
# 宿主一般没装 rpm-build（它只在 openeuler 构建容器里）。这个脚本被
# scripts/build.sh 在容器内直接调用，也要支持用户在宿主直接敲，所以缺 rpmbuild 时
# 反过来用 docker exec 进容器跑（与 tools/build-rpms.sh 的做法一致，只是那边是外面包一层）。
if ! command -v rpmbuild >/dev/null 2>&1; then
    if [ "${LTB_IN_CONTAINER:-0}" = "1" ]; then
        echo "ERROR: 容器内也没有 rpmbuild（openeuler 镜像里应自带 rpm-build）" >&2
        exit 2
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: 宿主没有 rpmbuild，也没有 docker。" >&2
        echo "       装 rpm-build，或先跑 scripts/init-env.sh 建出构建容器。" >&2
        exit 2
    fi
    ctr=${LTB_CONTAINER:-oe-lubancat-build}
    docker inspect "$ctr" >/dev/null 2>&1 || {
        echo "ERROR: 容器 $ctr 不存在。先跑 scripts/init-env.sh。" >&2; exit 2; }

    # 反查本仓库在容器里挂到哪（同路径挂载 / 老布局都能命中），拿不到就退回旧默认
    cdst=$(docker inspect "$ctr" \
             --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null \
           | awk -F'|' -v s="$REPO" '$1==s {print $2; exit}')
    [ -n "$cdst" ] || cdst=/work/src/SBC-sig

    # --out 若给的是仓库内路径，映射成容器内路径
    if [ -n "$out_dir" ]; then
        case "$out_dir" in
            "$REPO"|"$REPO"/*) out_dir="$cdst${out_dir#$REPO}" ;;
        esac
    fi

    echo "→ 宿主没有 rpmbuild，转入容器执行: $ctr:$cdst"

    set -- --soc "$soc"
    [ -n "$out_dir" ] && set -- "$@" --out "$out_dir"
    [ "$list_only" = 1 ] && set -- "$@" --list

    docker exec -w "$cdst" -e LTB_IN_CONTAINER=1 "$ctr" \
        bash "$cdst/tools/build-kernel-rpm.sh" "$@"
    rc=$?

    # 容器里是 root：把产物属主改回调用者，免得工作区里冒出一堆 root 文件
    if [ "$rc" = 0 ] && [ -d "$REPO/scripts/bin/rpms/$soc" ]; then
        docker exec "$ctr" chown -R "$(id -u):$(id -g)" "$cdst/scripts/bin/rpms/$soc" 2>/dev/null || true
    fi
    exit $rc
fi


workdir=${workdir:-$REPO/scripts/build}
kernel_dir=$workdir/kernel
extboot_dir=$workdir/extboot
out_dir=${out_dir:-$REPO/scripts/bin/rpms/$soc}

echo "== 内核 rpm 打包 =="
echo "  soc      : $soc"
echo "  workdir  : $workdir"
echo "  out      : $out_dir"

# ---------- 1. 确定 kernelrelease ----------
kver=""
if [ -f "$kernel_dir/Makefile" ]; then
    kver=$(make -s -C "$kernel_dir" kernelrelease 2>/dev/null || true)
fi
if [ -z "$kver" ]; then
    # 内核树没了（被清理过）就退而用 extboot 里的版本化文件名反推
    kver=$(ls -1 "$extboot_dir"/Image-* 2>/dev/null | sed 's|.*/Image-||' | head -1)
fi
[ -n "$kver" ] || { echo "ERROR: 取不到 kernelrelease（$kernel_dir 与 $extboot_dir/Image-* 都没有）" >&2; exit 2; }

# RPM 的 Version 不允许出现 '-'：6.1.99-rk3588 -> Version 6.1.99 / Release 1.lbc5.rk3588
case "$kver" in
    *-*) kv=${kver%%-*};  suffix=${kver#*-} ;;
    *)   kv=$kver;        suffix=$soc ;;
esac
rel="1.lbc5.$suffix"

echo "  kver     : $kver"
echo "  Version  : $kv   Release: $rel"

# ---------- 2. 检查产物是否齐全 ----------
missing=0
for f in "Image-$kver" "System.map-$kver" "config-$kver" "initrd-$kver"; do
    if [ ! -s "$extboot_dir/$f" ]; then
        echo "  缺: $extboot_dir/$f" >&2
        missing=1
    fi
done
[ -d "$kernel_dir/kernel-modules/lib/modules/$kver" ] || {
    echo "  缺: $kernel_dir/kernel-modules/lib/modules/$kver" >&2; missing=1; }
[ "$(ls "$extboot_dir"/dtb/*.dtb 2>/dev/null | wc -l)" -gt 0 ] || { echo "  缺: $extboot_dir/dtb/*.dtb" >&2; missing=1; }
[ "$(ls "$extboot_dir"/dtb/overlay/*.dtbo 2>/dev/null | wc -l)" -gt 0 ] || { echo "  缺: $extboot_dir/dtb/overlay/*.dtbo" >&2; missing=1; }

if [ "$missing" != 0 ]; then
    echo "ERROR: 产物不全。initrd 由 bootimg 阶段生成，先跑到那一步：" >&2
    echo "       tools/build-image.sh --board <board> --desktop <spec> -y" >&2
    exit 2
fi

if [ "$list_only" = 1 ]; then
    echo "== 将打包（未实际执行）=="
    echo "  [image]"
    ls -lh "$extboot_dir/Image-$kver" "$extboot_dir/System.map-$kver" "$extboot_dir/config-$kver" "$extboot_dir/initrd-$kver" | awk '{printf "    %8s  %s\n", $5, $9}'
    echo "    $extboot_dir/dtb/*.dtb              ($(ls "$extboot_dir"/dtb/*.dtb | wc -l) 个)"
    echo "    $extboot_dir/dtb/overlay/*.dtbo     ($(ls "$extboot_dir"/dtb/overlay/*.dtbo | wc -l) 个)"
    echo "  [modules] $kernel_dir/kernel-modules/lib/modules/$kver ($(du -sh "$kernel_dir/kernel-modules/lib/modules/$kver" | cut -f1))"
    exit 0
fi

# ---------- 3. 准备 rpmbuild 工作区 ----------
topdir=$(mktemp -d "${TMPDIR:-/tmp}/kernelrpm.XXXXXX")
trap 'rm -rf "$topdir"' EXIT
mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

stage_src=$topdir/SOURCES
mkdir -p "$stage_src/extboot/dtb/overlay" "$stage_src/modules"

echo "== 收集载荷 =="
for f in "Image-$kver" "System.map-$kver" "config-$kver" "initrd-$kver"; do
    cp -f "$extboot_dir/$f" "$stage_src/extboot/$f"
done
cp -a "$extboot_dir"/dtb/*.dtb           "$stage_src/extboot/dtb/"
cp -a "$extboot_dir"/dtb/overlay/*.dtbo  "$stage_src/extboot/dtb/overlay/"
# uEnv 一律不进包（方案 A）：它带着构建期占位 root=UUID，
# 装机覆盖会把板上正确值改成占位值，实测导致卡在 Waiting for /dev/disk/by-uuid/614e0000-...
cp -a "$kernel_dir/kernel-modules/lib/modules/$kver" "$stage_src/modules/"

# 兜底：载荷里一旦出现构建期占位 UUID 就拒绝打包（防止以后又有人把 uEnv 塞回来）
if grep -rlq '614e0000-0000-4b53-8000-1d28000054a9' "$stage_src" 2>/dev/null; then
    echo "ERROR: 载荷里出现构建期占位 root UUID（614e0000-...）" >&2
    echo "       这类文件（通常是 uEnv）不能进内核包：装机后会把板上正确的 root=UUID 覆盖掉。" >&2
    exit 2
fi

echo "  extboot 载荷: $(du -sh "$stage_src/extboot" | cut -f1)"
echo "  modules 载荷: $(du -sh "$stage_src/modules/$kver" | cut -f1)"

# ---------- 4. 打包 ----------
mkdir -p "$out_dir"
rpmbuild_args=(
    --rcfile "$REPO/pkg/rpmrc-aarch64"
    --define "_topdir $topdir"
    --define "kver $kver"
    --define "kv $kv"
    --define "rel $rel"
    --target aarch64
    --quiet
)
# --rcfile 是必须的：默认 rpmrc 里 x86_64 不兼容 aarch64，rpmbuild 会直接报
# "No compatible architectures found for build"。pkg/rpmrc-aarch64 末尾补了
# buildarch_compat: x86_64: aarch64（现有 build-rpms.sh 也是这么做的）。

echo "== rpmbuild =="
rpmbuild -bb "${rpmbuild_args[@]}" "$REPO/pkg/SPECS/kernel-lubancat-modules.spec"
rpmbuild -bb "${rpmbuild_args[@]}" "$REPO/pkg/SPECS/kernel-lubancat.spec"

built=$(ls -1 "$topdir"/RPMS/aarch64/*.rpm 2>/dev/null | wc -l)
[ "$built" -gt 0 ] || { echo "ERROR: rpmbuild 没有产出" >&2; exit 2; }

cp -f "$topdir"/RPMS/aarch64/*.rpm "$out_dir"/

echo
echo "== 产物 =="
ls -lh "$out_dir"/*.rpm | awk '{printf "  %8s  %s\n", $5, $9}'
echo
# 用相对仓库的路径打印：脚本在容器里跑时 $out_dir 是 /work/... ，直接打出来会误导
relout=${out_dir#"$REPO"/}
[ "$relout" = "$out_dir" ] && relout=$out_dir
echo "  板上用法（两个包一起装，顺序无所谓，Requires 会校验版本）："
echo "    rpm -ivh $relout/kernel-lubancat-modules-*.rpm \\"
echo "             $relout/kernel-lubancat-[0-9]*.rpm"
echo "    reboot && uname -r      # 应变成 $kver"
echo
echo "  回滚：编辑 /boot/uEnv/ 下当前在用的那份（uEnv.txt 是软链，用 readlink -f 取实体），"
echo "        把 uname_r 改回旧版本后重启。旧版本文件按 %post 策略保留 1 个。"
