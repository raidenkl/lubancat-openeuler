#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# growfs-rootfs.sh —— 把根文件系统扩到分区实际大小。
#
# 铁律：只 resize2fs，绝不改分区表。
#   分区表由加载器按 parameter.txt 的 `-@offset(rootfs:grow)` 生成，且每次
#   启动都会重算。任何运行期的分区表修改（parted resizepart / fdisk）都会
#   在下一次启动被收回，而 resize2fs 已经按偏大的尺寸扩完 FS，结果就是：
#     EXT4-fs (mmcblk0p3): bad geometry: block count 30466040
#         exceeds size of device (30465792 blocks)
#   根分区永久挂不上（alpha7 实机 brick 的成因）。
#
# 为什么不用底座自带的 /etc/rc.d/init.d/extend-root.sh：
#   它的 resize2fs 在 `if [ $PART_END -lt $ROOT_END ]` 分支里，分区已到盘尾时
#   直接 "Already the largest!" 自删，不扩文件系统；而我们的 rootfs 由加载器
#   grow 到盘尾，正好命中这个分支。
#
# 幂等：不写 marker，每次启动比对 FS 块数与分区块数，相等即退出（约 10ms）。
set -u

SRC=$(findmnt -no SOURCE / 2>/dev/null)
case "$SRC" in
    /dev/mmcblk*p[0-9]*|/dev/sd[a-z][0-9]*|/dev/nvme[0-9]*n[0-9]*p[0-9]*) ;;
    *) echo "growfs-rootfs: unsupported root source '${SRC}', skip"; exit 0 ;;
esac

BASE=$(basename "$SRC")
SECT=$(cat "/sys/class/block/${BASE}/size" 2>/dev/null) || exit 0
BLK=$(( SECT / 8 ))                       # 512B 扇区 -> 4K 块
[ "$BLK" -gt 0 ] || exit 0

CUR=$(dumpe2fs -h "$SRC" 2>/dev/null | awk '/^Block count:/{print $3}')
[ -n "${CUR:-}" ] || { echo "growfs-rootfs: cannot read block count of ${SRC}"; exit 0; }

if [ "$CUR" -eq "$BLK" ]; then
    exit 0                                 # 已满，静默通过
fi
if [ "$CUR" -gt "$BLK" ]; then
    # FS 比分区大：beta 期历史 bug 造成，必须离线 e2fsck 修，运行时绝不碰
    echo "growfs-rootfs: ERROR fs(${CUR}) > partition(${BLK}), refusing to resize" >&2
    exit 0
fi

echo "growfs-rootfs: ${SRC} ${CUR} -> ${BLK} blocks"
resize2fs "$SRC" "$BLK" || { echo "growfs-rootfs: resize2fs failed, will retry next boot" >&2; exit 0; }
df -h /
exit 0
