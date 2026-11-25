#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# LubanCat-3（RK3576）首启板型识别：
#   读 SARADC 的 ch2/ch3 → 8 档量化 → BID（如 0000）→ 选 dtb 与 uEnv → 需要时重启一次。
#
# 映射表来源：厂商 debian12/overlay/etc/init.d/boot_init.sh 的 board_info()，
# 经 yocto-meta-lubancat 的 board-table 机械转换（rk3576 三行）：
#   BID 0000 → LubanCat-3    → rk3576-lubancat-3.dtb    / uEnvLubanCat3.txt
#   BID 0001 → LubanCat-3IO  → rk3576-lubancat-3io.dtb  / uEnvLubanCat3IO.txt
#   BID 0100 → LubanCat-3 v2 → rk3576-lubancat-3-v2.dtb / uEnvLubanCat3-V2.txt
#
# 调试用环境变量：
#   LUBANCAT_BOARD_ID_OVERRIDE=0000   强制指定 BID（不改阈值表）
#   LUBANCAT_BOARD_INIT_DRYRUN=1      只打印将选的 dtb/uEnv，不落盘、不重启

BOOT=${BOOT:-/boot}
FLAG=$BOOT/.board_init
GENERIC_DTB=${GENERIC_DTB:-rk3576-lubancat-generic.dtb}
GENERIC_UENV=${GENERIC_UENV:-uEnvLubanCat.txt}
LOG_TAG=lubancat-board-init
DRYRUN=${LUBANCAT_BOARD_INIT_DRYRUN:-0}

log() { echo "$LOG_TAG: $*"; }

[ -e "$FLAG" ] && { log "already configured, skip"; exit 0; }

if [ ! -d "$BOOT/dtb" ] || [ ! -d "$BOOT/uEnv" ]; then
    log "WARN /boot not ready (dtb/uEnv missing), skip"
    exit 0
fi

SOC=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | tr ',' '\n' | grep -m1 -E '^rk[0-9]{4}$')
[ -n "$SOC" ] || SOC=unknown

IIO=""
for d in /sys/bus/iio/devices/iio:device*; do
    [ -r "$d/name" ] || continue
    case "$(cat "$d/name" 2>/dev/null)" in
        *saradc*) IIO="$d"; break;;
    esac
done

# ---- 回填点 A：阈值表（12bit / 10bit），与下面的映射表物理分离 ----
thresh_12() { echo 916 1376 1840 2380 2928 3432 3900 4096; }
thresh_10() { echo 229 344 460 595 732 858 975 1024; }

adc_index() {
    local ch=$1 raw scale is10 i t
    raw=$(cat "$IIO/in_voltage${ch}_raw" 2>/dev/null) || return 1
    scale=$(cat "$IIO/in_voltage_scale" 2>/dev/null) || scale=0
    is10=$(awk -v s="$scale" 'BEGIN{print (s>1)?1:0}')
    if [ "$is10" = "1" ]; then
        # shellcheck disable=SC2046
        set -- $(thresh_10)
    else
        # shellcheck disable=SC2046
        set -- $(thresh_12)
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

# ---- 回填点 B：BID → dtb/uEnv 映射（rk3576 只有这三行）----
DTB=""; UENV=""
case "$SOC:$BID" in
    rk3576:0000) DTB=rk3576-lubancat-3.dtb;    UENV=uEnvLubanCat3.txt ;;
    rk3576:0001) DTB=rk3576-lubancat-3io.dtb;  UENV=uEnvLubanCat3IO.txt ;;
    rk3576:0100) DTB=rk3576-lubancat-3-v2.dtb; UENV=uEnvLubanCat3-V2.txt ;;
    *)           DTB=$GENERIC_DTB;             UENV=$GENERIC_UENV ;;
esac

# 二次兜底：文件不存在就用 generic；generic 也没有就保持现状（不 touch 标记，下次再试）
if [ ! -f "$BOOT/dtb/$DTB" ]; then
    log "WARN dtb $DTB missing, use generic"
    DTB=$GENERIC_DTB
fi
if [ ! -f "$BOOT/dtb/$DTB" ]; then
    log "ERROR generic dtb also missing ($DTB), keep current boot config"
    exit 0
fi
if [ ! -f "$BOOT/uEnv/$UENV" ]; then
    log "WARN uEnv $UENV missing, use generic"
    UENV=$GENERIC_UENV
fi
[ -f "$BOOT/uEnv/$UENV" ] || { log "ERROR generic uEnv missing ($UENV), keep current"; exit 0; }

if [ "$DRYRUN" = "1" ]; then
    log "DRYRUN would select dtb=$DTB uenv=$UENV"
    exit 0
fi

CHANGED=0
CUR=$(readlink "$BOOT/rk-kernel.dtb" 2>/dev/null)
if [ "$CUR" != "dtb/$DTB" ]; then
    # 原子替换：先建临时链接再 mv，避免 rm 与 ln 之间被 u-boot 读到空值
    ln -sfn "dtb/$DTB" "$BOOT/rk-kernel.dtb.new" && mv -Tf "$BOOT/rk-kernel.dtb.new" "$BOOT/rk-kernel.dtb"
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
