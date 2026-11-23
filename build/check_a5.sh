#!/bin/bash
# 校验 alpha5 镜像内 A1-A5 / B1 / C1 是否生效
set -e
B=/work/src/SBC-sig/scripts/build
MNT=$B/a5check
umount $MNT 2>/dev/null || true
mkdir -p $MNT
mount -o loop,ro $B/rkpack/Image/rootfs.img $MNT

echo "== A1 mali hook =="
ls -l $MNT/usr/lib64/mali/libmali-hook* 2>&1 | head -4

echo "== A2 全局 LD_LIBRARY_PATH 已移除 =="
[ -f "$MNT/etc/profile.d/mali.sh" ] && echo "FAIL: mali.sh 仍存在" || echo "OK: 无 profile.d/mali.sh"
ls -l $MNT/usr/local/bin/mali-env 2>&1 | head -2

echo "== A3 光标主题 =="
for t in breeze breeze-dark ukui ukui-classical; do
    printf "%-14s %s\n" "$t" "$(ls $MNT/usr/share/icons/$t/cursors 2>/dev/null | wc -l)"
done

echo "== A4 光标配置 =="
cat $MNT/etc/xdg/kcminputrc 2>&1
echo "--- /etc/environment ---"
cat $MNT/etc/environment 2>&1

echo "== A5 自动登录 =="
cat $MNT/etc/lightdm/lightdm.conf.d/50-autologin.conf 2>&1

echo "== B1 无线工具 =="
chroot $MNT rpm -q iw wireless-regdb NetworkManager-wifi 2>&1 | head -4

echo "== C1 NPU 运行时 =="
ls -l $MNT/usr/lib64/librknnrt.so 2>&1

echo "== D1 是否（应不存在，未选）=="
ls -d $MNT/etc/iqfiles 2>&1
ls -l $MNT/usr/bin/rkaiq_3A_server 2>&1 | head -2

echo "== 模块与 UUID =="
echo "ko: $(find $MNT/usr/lib/modules/6.1.99-rk3588 -name '*.ko' 2>/dev/null | wc -l)"
grep -c . $MNT/usr/lib/modules/6.1.99-rk3588/modules.dep 2>/dev/null

sync
umount $MNT
echo CHECK_DONE
