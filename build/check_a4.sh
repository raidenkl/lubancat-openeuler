set -e
B=/work/src/SBC-sig/scripts/build
IMG=$B/rkpack/Image/rootfs.img
MNT=$B/a4check
umount $MNT 2>/dev/null || true
mkdir -p $MNT
mount -o loop,ro $IMG $MNT
echo "== /lib =="; ls -ld $MNT/lib
echo "== 模块 =="; ls -ld $MNT/usr/lib/modules/6.1.99-rk3588
echo "ko 数量: $(find $MNT/usr/lib/modules/6.1.99-rk3588 -name '*.ko' | wc -l)"
echo "modules.dep 行数: $(wc -l < $MNT/usr/lib/modules/6.1.99-rk3588/modules.dep)"
echo "== 关键模块 =="
for m in rtw88_8822ce option btusb rtw88_core; do
  printf "%-14s " $m; find $MNT/usr/lib/modules/6.1.99-rk3588 -name "$m.ko" | head -1
done
echo "== 无线工具 =="
ls -l $MNT/usr/sbin/iw $MNT/usr/lib/firmware/regulatory.db 2>&1
ls $MNT/usr/lib64/NetworkManager/*/libnm-device-plugin-wifi.so 2>&1
echo "== 桌面/板级 =="
ls -l $MNT/etc/systemd/system/default.target 2>&1
ls $MNT/usr/libexec/lubancat/board-init.sh 2>&1
ls $MNT/usr/share/xsessions/ 2>&1 | head -3
echo "== 模块版本 =="
strings $MNT/usr/lib/modules/6.1.99-rk3588/kernel/drivers/net/wireless/realtek/rtw88/rtw88_8822ce.ko | grep -m1 vermagic=
sync
umount $MNT
echo CHECK_DONE
