#!/bin/bash
# 校验 alpha6 镜像：多媒体固化 + 摄像头 RPM 预置 + 之前 alpha5 的固化项
set -e
B=/work/src/SBC-sig/scripts/build
MNT=$B/a6check
umount $MNT 2>/dev/null || true
mkdir -p $MNT
mount -o loop,ro $B/rkpack/Image/rootfs.img $MNT

echo "== RGA =="
ls -l $MNT/usr/lib64/librga.so.2* 2>&1 | head -3

echo "== MPP / VPU =="
ls -l $MNT/usr/lib64/librockchip_mpp.so* $MNT/usr/lib64/librockchip_vpu.so* 2>&1 | head -6

echo "== gst 插件 =="
ls -l $MNT/usr/lib64/gstreamer-1.0/libgstrockchipmpp.so $MNT/usr/lib64/gstreamer-1.0/libgstrkximage.so 2>&1

echo "== MPP 工具 =="
ls $MNT/usr/bin/ | grep -E "^(mpi_|mpp_info|vpu_api)" | tr '\n' ' '; echo

echo "== udev 规则 =="
ls -l $MNT/etc/udev/rules.d/99-rockchip-permissions.rules 2>&1

echo "== 预置 RPM =="
ls -lh $MNT/opt/rpms/ 2>&1

echo "== alpha5 固化项复核 =="
ls -l $MNT/usr/lib64/mali/libmali-hook.so.1.9.0 2>&1 | head -2
[ -f "$MNT/etc/profile.d/mali.sh" ] && echo "FAIL: mali.sh 仍存在" || echo "OK: 无 profile.d/mali.sh"
echo "breeze cursors: $(ls $MNT/usr/share/icons/breeze/cursors 2>/dev/null | wc -l)"
ls -l $MNT/usr/lib64/librknnrt.so 2>&1 | head -2
ls -l $MNT/etc/lightdm/lightdm.conf.d/50-autologin.conf 2>&1 | head -2

echo "== 模块 =="
echo "ko: $(find $MNT/usr/lib/modules/6.1.99-rk3588 -name '*.ko' 2>/dev/null | wc -l)"

sync
umount $MNT
echo CHECK_DONE
