#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# resize-rootfs.sh —— 首启动把根分区扩到整盘并在线扩文件系统。
# 解决：镜像按最小尺寸打包，刷到更大 eMMC/SD 卡后剩余空间不可用。
# 由 lubancat-resize.service 触发（ConditionPathExists 幂等）。
set -e

MARK=/var/lib/lubancat/.rootfs-resized
mkdir -p /var/lib/lubancat

SRC=$(findmnt -no SOURCE /)                    # 如 /dev/mmcblk0p3
BASE=$(basename "$SRC")
case "$SRC" in
    /dev/mmcblk*p[0-9]*|/dev/sd[a-z][0-9]*|/dev/nvme[0-9]*n[0-9]*p[0-9]*)
        DISK="/dev/$(lsblk -no pkname "$SRC" | head -1)"
        PART=$(cat "/sys/class/block/${BASE}/partition")
        ;;
    *)
        echo "resize-rootfs: unsupported source ${SRC}, skip"
        exit 0
        ;;
esac
if [ -z "$DISK" ] || [ -z "$PART" ]; then
    echo "resize-rootfs: cannot resolve disk/partition for ${SRC}, skip"
    exit 0
fi

# 分区是否已到盘尾（GPT）
CUR_END=$(parted -ms "$DISK" unit B print 2>/dev/null \
          | awk -F: -v p="$PART" '$1==p {e=$3; sub(/B$/,"",e); print e}')
DISK_SIZE=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
if [ -n "$CUR_END" ] && [ "$DISK_SIZE" != "0" ] \
   && [ "$CUR_END" -ge $((DISK_SIZE - 1048576)) ]; then
    echo "resize-rootfs: partition already at end of disk, only resizing fs"
else
    echo "resize-rootfs: growing ${DISK} partition ${PART} to 100%"
    # 根分区所在的表是 vendor 布局生成的 GPT，rootfs 恒为最后一个分区
    parted -s "$DISK" resizepart "$PART" 100% 2>/dev/null || true
    partprobe "$DISK" 2>/dev/null || true
fi

echo "resize-rootfs: resize2fs ${SRC}"
resize2fs "$SRC" || echo "resize-rootfs: resize2fs failed, will retry next boot (stamp not written)"

touch "$MARK"
echo "resize-rootfs: done"
df -h /
exit 0
