#!/bin/bash
# 生成目标架构(aarch64)的 initramfs
#
# 背景：构建容器是 x86_64。直接在该容器里执行 `dracut --no-kernel` 会把容器的
#       x86-64 用户态(systemd/udev/bash)打进 initramfs，板卡上内核执行 /init
#       时报 ENOEXEC(-8)，最终 "No working init found" panic。
# 做法：以已构建的 aarch64 rootfs.img 为根，chroot 进去生成，并用 DRACUT_ARCH
#       覆盖 uname -m（chroot 内 uname 仍返回宿主 x86_64）。
#
# 用法：mk_initrd.sh [--rootfs <rootfs.img>] [--output <initrd.img>] [--kernelrelease <ver>]
set -e

cur_dir=$(cd "$(dirname "$0")"; pwd)
workdir=${cur_dir}/build

rootfs_img=""
output=""
kernelrelease=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)        rootfs_img=$2; shift 2 ;;
        --output)        output=$2; shift 2 ;;
        --kernelrelease) kernelrelease=$2; shift 2 ;;
        -h|--help)       sed -n '2,15p' "$0"; exit 0 ;;
        *)               echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "${rootfs_img}" ] || rootfs_img=${workdir}/rootfs.img
[ -f "${rootfs_img}" ] || { echo "ERROR: rootfs.img not found: ${rootfs_img}" >&2; exit 1; }
[ -n "${output}" ] || output=${workdir}/boot/initrd.img
mkdir -p "$(dirname "${output}")"

# kernelrelease 优先从 kernel tree 推导，保证与 Image 完全一致
if [ -z "${kernelrelease}" ]; then
    kernelrelease=$(make -s -C "${workdir}/kernel" kernelrelease 2>/dev/null)
fi
[ -n "${kernelrelease}" ] || { echo "ERROR: cannot determine kernelrelease" >&2; exit 1; }

mnt=${workdir}/initrd-root
mkdir -p "${mnt}"

cleanup() {
    for p in "${mnt}/dev" "${mnt}/sys" "${mnt}/proc" "${mnt}/run" "${mnt}/usr/lib/modules" "${mnt}"; do
        umount -l "$p" 2>/dev/null || true
    done
}
trap cleanup EXIT

cleanup
mount "${rootfs_img}" "${mnt}"

# dracut 需要 /proc /sys /dev
mount -t proc       proc  "${mnt}/proc" 2>/dev/null || mount -t proc proc "${mnt}/proc"
mount --bind /sys         "${mnt}/sys"
mount --bind /dev         "${mnt}/dev"
mkdir -p "${mnt}/run"
mount --bind /run         "${mnt}/run" 2>/dev/null || true

# 已编译的模块树（--no-kernel 不强依赖，但接上可避免 dracut 报 kver 缺失）
if [ -d "${workdir}/kernel/kernel-modules/lib/modules" ]; then
    mkdir -p "${mnt}/usr/lib/modules"
    mount --bind "${workdir}/kernel/kernel-modules/lib/modules" "${mnt}/usr/lib/modules"
fi

[ -x "${mnt}/usr/bin/dracut" ] || { echo "ERROR: dracut not found in rootfs" >&2; exit 1; }

echo "generating aarch64 initramfs for ${kernelrelease} from ${rootfs_img}"
# --no-kernel：本内核 ext4/mmc 均内置，initramfs 无需内核模块
# DRACUT_ARCH：chroot 内 uname -m 仍是 x86_64，必须显式覆盖
chroot "${mnt}" env DRACUT_ARCH=aarch64 \
    dracut --force --no-hostonly --no-kernel --no-early-microcode /tmp/initrd.img "${kernelrelease}"

[ -s "${mnt}/tmp/initrd.img" ] || { echo "ERROR: dracut produced no output" >&2; exit 1; }
cp -f "${mnt}/tmp/initrd.img" "${output}"
rm -f "${mnt}/tmp/initrd.img"

# 自校验：initramfs 内 /init 指向 systemd，必须是 AArch64，避免再产出 x86 initramfs。
# 注意：dracut 059 产出的是「early cpio（未压缩） + 主 cpio（压缩）」串接结构，
#       直接用 zcat|cpio 解只能拿到前半段，必须按条目用 lsinitrd 提取。
if command -v lsinitrd >/dev/null 2>&1; then
    lsinitrd -f /usr/lib/systemd/systemd "${output}" > /tmp/.initrd-check.bin 2>/dev/null || true
    machine=$(readelf -h /tmp/.initrd-check.bin 2>/dev/null | awk -F: '/Machine/{gsub(/^ +/,"",$2); print $2}')
    rm -f /tmp/.initrd-check.bin
    case "${machine}" in
        *AArch64*) echo "initrd arch OK: ${machine}" ;;
        *)         echo "ERROR: initrd systemd arch is '${machine}', expected AArch64" >&2; exit 1 ;;
    esac
else
    echo "WARN: lsinitrd not found, skip initrd arch verification"
fi

chmod 644 "${output}"

echo "initrd ready: ${output} ($(du -h "${output}" | cut -f1), kver ${kernelrelease})"
