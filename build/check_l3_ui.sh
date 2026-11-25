#!/bin/bash
# Cat-3 桌面版镜像级验收（在构建容器内执行）
#   用法：bash check_l3_ui.sh [rootfs.img 路径]
# 断言分四段：A 板级/启动介质、B 桌面栈、C 图形与驱动、D 基础与首启
set -u
B=/work/src/SBC-sig/scripts/build
ROOTFS=${1:-$B/rkpack/Image/rootfs.img}
MNT=$B/l3uicheck
PASS=0; FAIL=0

ck() { # ck <名称> <期望> <实际>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  OK   %-46s %s\n' "$1" "$3"
    else FAIL=$((FAIL+1)); printf '  FAIL %-46s 期望=%s 实际=%s\n' "$1" "$2" "$3"; fi
}
ckhas() { # ckhas <名称> <子串> <实际>
    case "$3" in *"$2"*) PASS=$((PASS+1)); printf '  OK   %-46s 含 %s\n' "$1" "$2";;
        *) FAIL=$((FAIL+1)); printf '  FAIL %-46s 缺少 %s（实际: %s）\n' "$1" "$2" "${3:0:60}";; esac
}

echo "=== 挂载 rootfs ==="
umount "$MNT" 2>/dev/null
mkdir -p "$MNT"
mount -o loop,ro "$ROOTFS" "$MNT" || { echo "无法挂载 $ROOTFS"; exit 1; }
trap 'umount "$MNT" 2>/dev/null' EXIT

echo
echo "--- A. 板级与启动介质 ---"
PARAM=$B/rkpack/Image/parameter.txt
ckhas "parameter MACHINE_MODEL" "MACHINE_MODEL: RK3576" "$(cat "$PARAM" 2>/dev/null)"
UB=$B/rkpack/Image/uboot.img
SZU=$(stat -c %s "$UB" 2>/dev/null || echo 0)
ck "uboot.img ≤ 4 MiB" "yes" "$([ "$SZU" -le 4194304 ] && [ "$SZU" -gt 0 ] && echo yes || echo no)"
LD=$B/rkpack/Image/MiniLoaderAll.bin
[ -f "$LD" ] || LD=$B/u-boot/MiniLoaderAll.bin
ck "loader 头推导 SoC" "3576" "$(dd if="$LD" bs=1 skip=21 count=4 2>/dev/null | rev)"
BM=$B/rkpack/Image/boot.img
mkdir -p $B/l3boot; umount $B/l3boot 2>/dev/null
if mount -o loop,ro "$BM" $B/l3boot 2>/dev/null; then
    ck "boot.img 有 rk-kernel.dtb" "yes" "$([ -e $B/l3boot/rk-kernel.dtb ] && echo yes || echo no)"
    ck "boot.img 有 boot.scr" "yes" "$([ -f $B/l3boot/boot.scr ] && echo yes || echo no)"
    ck "boot.img uEnv 文件数" "7" "$(ls $B/l3boot/uEnv/*.txt 2>/dev/null | wc -l)"
    ck "boot.img 板级 dtb 数(3)" "3" "$(ls $B/l3boot/dtb/rk3576-lubancat-3.dtb $B/l3boot/dtb/rk3576-lubancat-3-v2.dtb $B/l3boot/dtb/rk3576-lubancat-3io.dtb 2>/dev/null | wc -l)"
    ck "boot.img 有 generic dtb" "yes" "$([ -f $B/l3boot/dtb/rk3576-lubancat-generic.dtb ] && echo yes || echo no)"
    umount $B/l3boot
else
    ck "boot.img 可挂载" "yes" "no"
fi

echo
echo "--- B. 桌面栈 ---"
for p in ukui lightdm onboard onboard-data; do
    ck "已安装 $p" "yes" "$(chroot "$MNT" rpm -q "$p" >/dev/null 2>&1 && echo yes || echo no)"
done
ck "default.target → graphical" "graphical.target" "$(readlink "$MNT/etc/systemd/system/default.target" 2>/dev/null | xargs -r basename)"
ck "lightdm 已挂到 graphical.target" "yes" "$([ -L "$MNT/etc/systemd/system/graphical.target.wants/lightdm.service" ] && echo yes || echo no)"
ck "20-swcursor.conf" "yes" "$([ -f "$MNT/etc/X11/xorg.conf.d/20-swcursor.conf" ] && echo yes || echo no)"
ck "onboard autostart" "yes" "$([ -f "$MNT/etc/xdg/autostart/onboard-autostart.desktop" ] && echo yes || echo no)"
ck "dconf 已编译(local)" "yes" "$([ -f "$MNT/etc/dconf/db/local" ] && echo yes || echo no)"
ck "kcminputrc" "yes" "$([ -f "$MNT/etc/xdg/kcminputrc" ] && echo yes || echo no)"
ckhas "XCURSOR_THEME" "XCURSOR_THEME=Adwaita" "$(cat "$MNT/etc/environment" 2>/dev/null)"
ckhas "autologin 用户" "autologin-user=lubancat" "$(cat "$MNT/etc/lightdm/lightdm.conf.d/50-autologin.conf" 2>/dev/null)"
GP=$MNT/etc/X11/xorg.conf.d/10-rockchip-primary.conf
ck "主 GPU 钉住显示子系统" "yes" "$([ -f "$GP" ] && echo yes || echo no)"
ckhas "MatchDriver rockchip" 'MatchDriver "rockchip"' "$(cat "$GP" 2>/dev/null)"
ckhas "PrimaryGPU yes" "PrimaryGPU" "$(cat "$GP" 2>/dev/null)"
ck "breeze 光标非空" "yes" "$([ -n "$(ls -A "$MNT/usr/share/icons/breeze/cursors" 2>/dev/null)" ] && echo yes || echo no)"

echo
echo "--- C. 图形与驱动 ---"
MALI=$(stat -c %s "$MNT/usr/lib64/libmali.so.1.9.0" 2>/dev/null || echo 0)
ck "libmali.so.1.9.0 约 43MB" "yes" "$([ "$MALI" -gt 40000000 ] && echo yes || echo no)"
ckhas "mali 版本标识 g13p0" "g13p0" "$(strings -a "$MNT/usr/lib64/libmali.so.1.9.0" 2>/dev/null | grep -m1 g13p0)"
ck "mali 桩数量(6)" "6" "$(ls "$MNT/usr/lib64/mali"/libEGL.so.1 "$MNT/usr/lib64/mali"/libGLESv1_CM.so.1 "$MNT/usr/lib64/mali"/libGLESv2.so.2 "$MNT/usr/lib64/mali"/libMaliOpenCL.so.1 "$MNT/usr/lib64/mali"/libgbm.so.1 "$MNT/usr/lib64/mali"/libwayland-egl.so.1 2>/dev/null | wc -l)"
ck "无 mali_csffw.bin(G52 不需要)" "0" "$(ls "$MNT/usr/lib/firmware/mali_csffw.bin" 2>/dev/null | wc -l)"
ck "无 /etc/profile.d/mali.sh" "0" "$(ls "$MNT/etc/profile.d/mali.sh" 2>/dev/null | wc -l)"
ck "ld.so.conf.d 无 mali" "0" "$(grep -rl mali "$MNT/etc/ld.so.conf.d/" 2>/dev/null | wc -l)"
ck "mali-env 可执行" "yes" "$([ -x "$MNT/usr/local/bin/mali-env" ] && echo yes || echo no)"
ckhas "librknnrt 支持 RK3576" "RK3576" "$(strings -a "$MNT/usr/lib64/librknnrt.so" 2>/dev/null | grep -m1 RK3576)"
ck "librga.so.2.1.0" "yes" "$([ -f "$MNT/usr/lib64/librga.so.2.1.0" ] && echo yes || echo no)"
ck "librockchip_mpp.so.0" "yes" "$([ -f "$MNT/usr/lib64/librockchip_mpp.so.0" ] && echo yes || echo no)"
ck "gst rockchip 插件数" "2" "$(ls "$MNT/usr/lib64/gstreamer-1.0/" 2>/dev/null | grep -cE '^libgst(rockchipmpp|rkximage)\.so$')"
ck "udev rockchip 规则" "yes" "$([ -f "$MNT/etc/udev/rules.d/99-rockchip-permissions.rules" ] && echo yes || echo no)"
ck "/opt/rpms 里 rkaiq 恰好 1 个" "1" "$(ls "$MNT/opt/rpms/"camera-engine-rkaiq-*.rpm 2>/dev/null | wc -l)"
ckhas "预置的是 rk3576 版" "rk3576" "$(ls "$MNT/opt/rpms/" 2>/dev/null | head -1)"

echo
echo "--- D. 基础与首启 ---"
ck "machine-id 为空" "0" "$(stat -c %s "$MNT/etc/machine-id" 2>/dev/null || echo 0)"
ck "无 SSH 主机密钥" "0" "$(ls "$MNT"/etc/ssh/ssh_host_* 2>/dev/null | wc -l)"
ck "firstboot 已 enable" "yes" "$([ -L "$MNT/etc/systemd/system/multi-user.target.wants/lubancat-firstboot.service" ] && echo yes || echo no)"
ck "growfs 已 enable" "yes" "$([ -L "$MNT/etc/systemd/system/multi-user.target.wants/lubancat-growfs.service" ] && echo yes || echo no)"
ck "board-init 已 enable" "yes" "$([ -L "$MNT/etc/systemd/system/multi-user.target.wants/lubancat-board-init.service" ] && echo yes || echo no)"
ck "/ 属主 root" "0:0" "$(stat -c %u:%g "$MNT")"
ck "/etc 属主 root" "0:0" "$(stat -c %u:%g "$MNT/etc")"
ck "/usr 属主 root" "0:0" "$(stat -c %u:%g "$MNT/usr")"
ck "顶层无 uid1000 目录" "0" "$(find "$MNT" -maxdepth 2 -uid 1000 -type d 2>/dev/null | grep -vE "/(home|proc|sys|dev|run|tmp|var)" | wc -l)"
ck "lubancat 在 video 组" "lubancat" "$(grep '^video:' "$MNT/etc/group" 2>/dev/null | cut -d: -f4)"
KO=$(find "$MNT/lib/modules" -name '*.ko' 2>/dev/null | wc -l)
ck "内核模块 > 200" "yes" "$([ "$KO" -gt 200 ] && echo yes || echo no)"
ck "modules.dep 存在" "yes" "$([ -s "$MNT/lib/modules/6.1.99-rk3576/modules.dep" ] && echo yes || echo no)"

echo
echo "--- E. 板型识别（厂商映射表 + 离线跑真实脚本）---"
BI=$MNT/usr/libexec/lubancat/board-init.sh
ck "board-init 存在" "yes" "$([ -f "$BI" ] && echo yes || echo no)"
ck "board-init 与 overlay/common 一致" "yes" "$(cmp -s "$BI" /work/src/SBC-sig/scripts/overlay/common/usr/libexec/lubancat/board-init.sh && echo yes || echo no)"
ck "无 name 过滤(旧写法)" "0" "$(grep -c "\*saradc\*" "$BI" 2>/dev/null || true)"
ckhas "默认直读 iio:device0" "iio:device0" "$(grep -m1 "^IIO_BASE=" "$BI" 2>/dev/null)"
ckhas "12 位阈值表(厂商原值)" "916 1376 1840 2380 2928 3432 3900 4096" "$(grep -m1 "916 " "$BI" 2>/dev/null)"
ckhas "10 位阈值表(厂商原值)" "229 344 460 595 732 858 975 1024" "$(grep -m1 "229 " "$BI" 2>/dev/null)"
ckhas "unit 同时输出到串口" "StandardOutput=journal+console" "$(cat "$MNT/etc/systemd/system/lubancat-board-init.service" 2>/dev/null)"
ck "firstboot 无 ConditionFirstBoot" "0" "$(grep -c "^ConditionFirstBoot=" "$MNT/etc/systemd/system/lubancat-firstboot.service" 2>/dev/null || true)"
ckhas "firstboot 排在 board-init 之后" "lubancat-board-init.service" "$(grep "^After=" "$MNT/etc/systemd/system/lubancat-firstboot.service" 2>/dev/null)"
ck "firstboot 无 LubanCat-5 硬编码" "0" "$(grep -c "BOARD=LubanCat-5" "$MNT/usr/libexec/lubancat/firstboot.sh" 2>/dev/null || true)"
SEL=/work/src/SBC-sig/build/board-init-selftest.sh
if [ -f "$SEL" ]; then
    SELFTOUT=$(bash "$SEL" "$BI" 2>&1)
    ck "映射表用例 PASS 数" "8" "$(printf "%s\n" "$SELFTOUT" | grep -c "^PASS")"
    ck "映射表用例 FAIL 数" "0" "$(printf "%s\n" "$SELFTOUT" | grep -c "^FAIL")"
else
    ck "board-init-selftest.sh 存在" "yes" "no"
fi

echo
echo "================ RESULT: PASS=$PASS FAIL=$FAIL ================"
[ "$FAIL" -eq 0 ] && echo "全部通过" || echo "有失败项，见上"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
