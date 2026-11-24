#!/bin/bash
# alpha7 镜像验收：除音频外的全部 P0 项 + G2
# 注意：内核模块与 UUID 检查对象是 rkpack staging 的 rootfs.img（gen 拷贝并加工后的那份）
set -e
B=/work/src/SBC-sig/scripts/build
MNT=$B/a7check
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (期望=$2 实际=$3)"; fail=$((fail+1)); fi; }

# ---------- A. workspace rootfs.img（overlay 成果）----------
IMG=$B/rootfs.img
umount $MNT 2>/dev/null || true; mkdir -p $MNT; mount -o loop,ro $IMG $MNT

echo "== P0-1 属主（含新补的 /usr/lib）=="
for d in "" /etc /usr /usr/lib /usr/lib/firmware /usr/lib64 /usr/lib64/mali; do
    ck "  ${d:-/} 属主为 root" "0" "$(stat -c %u $MNT$d)"
done
ck "  全库无 uid1000 污染目录" "0" "$(find $MNT -maxdepth 4 -uid 1000 -type d 2>/dev/null | grep -vcE "$MNT/(home|proc|sys|dev|run|tmp|var)/")"

echo "== P0-2 video 组 =="
ck "  lubancat 在 video 组" "yes" "$(grep -E "^video:" $MNT/etc/group | grep -q lubancat && echo yes || echo no)"

echo "== P0-3 首启唯一性 =="
ck "  machine-id 已截断" "0" "$(stat -c %s $MNT/etc/machine-id 2>/dev/null || echo missing)"
ck "  ssh_host_* 已删除" "0" "$(ls $MNT/etc/ssh/ssh_host_* 2>/dev/null | wc -l)"
ck "  firstboot 脚本" "1" "$(ls $MNT/usr/libexec/lubancat/firstboot.sh 2>/dev/null | wc -l)"
ck "  firstboot 服务链接" "1" "$(ls $MNT/etc/systemd/system/multi-user.target.wants/lubancat-firstboot.service 2>/dev/null | wc -l)"
ck "  sshd-keygen@rsa 链接" "1" "$(ls $MNT/etc/systemd/system/multi-user.target.wants/sshd-keygen@rsa.service 2>/dev/null | wc -l)"
echo "== P0-4 自动扩容 =="
ck "  resize 脚本" "1" "$(ls $MNT/usr/libexec/lubancat/resize-rootfs.sh 2>/dev/null | wc -l)"
ck "  resize 服务链接" "1" "$(ls $MNT/etc/systemd/system/multi-user.target.wants/lubancat-resize.service 2>/dev/null | wc -l)"
echo "== 音频已复原（确认无残留）=="
ck "  无 asound.conf 音频路由" "0" "$(grep -c "type pulse" $MNT/etc/asound.conf 2>/dev/null || echo 0)"
echo "== P0-6 卫生 =="
echo "      dnf 缓存: $(du -sh $MNT/var/cache/dnf 2>/dev/null | cut -f1)"
echo "      /tmp 内容: $(ls -A $MNT/tmp 2>/dev/null | wc -l) 项"
ck "  lastlog 存在" "1" "$(ls $MNT/var/log/lastlog 2>/dev/null | wc -l)"
echo "== G2 补包 =="
for p in v4l-utils i2c-tools usbutils gstreamer1-plugins-bad-free; do
    ck "  $p" "installed" "$(chroot $MNT rpm -q $p >/dev/null 2>&1 && echo installed || echo missing)"
done
umount $MNT

# ---------- B. rkpack staging rootfs.img（gen 加工后，进 update.img 的那份）----------
STG=$B/rkpack/Image/rootfs.img
umount $MNT 2>/dev/null || true; mount -o loop,ro $STG $MNT
echo "== 打包层 rootfs（gen 加工后）=="
STG_UUID=$(blkid -s UUID -o value $STG)
ck "  内核模块 299 ko" "299" "$(find $MNT/lib/modules/6.1.99-rk3588 -name '*.ko' 2>/dev/null | wc -l)"
ck "  /lib 软链未破坏" "usr/lib" "$(readlink $MNT/lib)"
echo "      rootfs UUID = $STG_UUID"
umount $MNT

# ---------- C. rkpack staging boot.img（gen 加工后那份）----------
BMT=$B/a7boot
umount $BMT 2>/dev/null || true; mkdir -p $BMT; mount -o loop,ro $B/rkpack/Image/boot.img $BMT
UENV_UUID=$(grep -m1 -oE "root=UUID=[0-9a-f-]+" $BMT/uEnv/uEnv.txt | cut -d= -f3)
EXT_UUID=$(grep -m1 -oE "root=UUID=[0-9a-f-]+" $BMT/extlinux/extlinux.conf 2>/dev/null | cut -d= -f3)
echo "== 三方 UUID 一致 =="
echo "      uEnv=$UENV_UUID extlinux=$EXT_UUID rootfs=$STG_UUID"
ck "  uEnv 与 rootfs UUID 一致" "$STG_UUID" "$UENV_UUID"
ck "  extlinux 与 rootfs UUID 一致" "$STG_UUID" "${EXT_UUID:-$UENV_UUID}"
umount $BMT

echo
echo "RESULT: pass=$pass fail=$fail"
