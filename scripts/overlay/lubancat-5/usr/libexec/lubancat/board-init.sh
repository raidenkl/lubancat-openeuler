#!/bin/bash
# LubanCat 板型识别：首启读 SARADC 硬件 ID，选择 dtb 与 uEnv，然后重启一次生效。
# 移植自 BSP debian12/overlay/etc/init.d/boot_init.sh，差异：
#   1) IIO 设备按 name 匹配，不硬编码 iio:device0
#   2) uEnv 用复制而非软链（同目录复制，避免 U-Boot 相对软链解析歧义）
#   3) 任何异常都回落 generic 并直接退出，绝不阻塞开机

BOOT=/boot
FLAG=$BOOT/.board_init
GENERIC_DTB=${GENERIC_DTB:-rk3588-lubancat-generic.dtb}
GENERIC_UENV=${GENERIC_UENV:-uEnvLubanCat.txt}
LOG_TAG=lubancat-board-init

log() { echo "$LOG_TAG: $*"; }

[ -e "$FLAG" ] && { log "already configured, skip"; exit 0; }

# /boot 没挂上（fstab 异常）时直接放弃，交给人工
if [ ! -d "$BOOT/dtb" ] || [ ! -d "$BOOT/uEnv" ]; then
    log "WARN /boot not ready (dtb/uEnv missing), skip"
    exit 0
fi

# SOC：compatible 是 NUL 分隔的多项，取 rkXXXX
SOC=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | tr ',' '\n' | grep -m1 -E '^rk[0-9]{4}$')
[ -n "$SOC" ] || SOC=unknown

# 按 name 找 saradc 的 iio 设备
IIO=""
for d in /sys/bus/iio/devices/iio:device*; do
    [ -r "$d/name" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in
        *saradc*) IIO="$d"; break;;
    esac
done

# 与 BSP 完全一致的 8 档量化
adc_index() {
    local ch=$1 raw scale is10 i
    raw=$(cat "$IIO/in_voltage${ch}_raw" 2>/dev/null) || return 1
    scale=$(cat "$IIO/in_voltage_scale" 2>/dev/null) || scale=0
    is10=$(awk -v s="$scale" 'BEGIN{print (s>1)?1:0}')
    if [ "$is10" = "1" ]; then
        set -- 229 344 460 595 732 858 975 1024
    else
        set -- 916 1376 1840 2380 2928 3432 3900 4096
    fi
    i=0
    for t in "$@"; do
        [ "$raw" -lt "$t" ] && { echo "$i"; return 0; }
        i=$((i+1))
    done
    return 1
}

BID=""
if [ -n "$IIO" ]; then
    H=$(adc_index 2) || H=""
    L=$(adc_index 3) || L=""
    [ -n "$H" ] && [ -n "$L" ] && BID="0${H}0${L}"
fi
BID=${LUBANCAT_BOARD_ID_OVERRIDE:-$BID}
log "soc=$SOC board_id=${BID:-unknown} iio=${IIO:-none}"

DTB=""; UENV=""
case "$SOC:$BID" in
    rk3588:0101) DTB=rk3588s-lubancat-4.dtb;    UENV=uEnvLubanCat4.txt ;;
    rk3588:0102) DTB=rk3588s-lubancat-4-v1.dtb; UENV=uEnvLubanCat4-V1.txt ;;
    rk3588:0201) DTB=rk3588s-lubancat-4io.dtb;  UENV=uEnvLubanCat4IO.txt ;;
    rk3588:0301) DTB=rk3588s-lubancat-4io.dtb;  UENV=uEnvLubanCat4IO.txt ;;
    rk3588:0401) DTB=rk3588-lubancat-5.dtb;     UENV=uEnvLubanCat5.txt ;;
    rk3588:0402) DTB=rk3588-lubancat-5-v2.dtb;  UENV=uEnvLubanCat5-V2.txt ;;
    rk3588:0501) DTB=rk3588-lubancat-5iof.dtb;  UENV=uEnvLubanCat5IOF.txt ;;
    rk3588:0601) DTB=rk3588-lubancat-5iob.dtb;  UENV=uEnvLubanCat5IOB.txt ;;
    rk3588:0701) DTB=rk3588-lubancat-5iobi.dtb; UENV=uEnvLubanCat5IOB.txt ;;
    *)           DTB=$GENERIC_DTB;              UENV=$GENERIC_UENV ;;
esac

# 二次兜底：文件不存在就用 generic
[ -f "$BOOT/dtb/$DTB" ] || { log "WARN dtb $DTB missing, use generic"; DTB=$GENERIC_DTB; }
[ -f "$BOOT/uEnv/$UENV" ] || { log "WARN uEnv $UENV missing, use generic"; UENV=$GENERIC_UENV; }

CHANGED=0
CUR=$(readlink "$BOOT/rk-kernel.dtb" 2>/dev/null)
if [ "$CUR" != "dtb/$DTB" ]; then
    rm -f "$BOOT/rk-kernel.dtb"
    ln -sfn "dtb/$DTB" "$BOOT/rk-kernel.dtb"
    CHANGED=1
fi
if ! cmp -s "$BOOT/uEnv/$UENV" "$BOOT/uEnv/uEnv.txt"; then
    cp -f "$BOOT/uEnv/$UENV" "$BOOT/uEnv/uEnv.txt"
    CHANGED=1
fi

sync
touch "$FLAG"
sync
log "selected dtb=dtb/$DTB uenv=$UENV changed=$CHANGED"

if [ "$CHANGED" = "1" ]; then
    log "reboot to apply"
    systemctl reboot
fi
exit 0
