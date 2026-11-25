#!/bin/bash
# board-init 映射表离线自测：不需要真板子，用假 sysfs 跑厂商表
# 用法：bash selftest.sh /path/to/board-init.sh
BI=${1:?need board-init.sh path}
T=$(mktemp -d)
pass=0; fail=0

run_case() {
    local soc=$1 ch2=$2 ch3=$3 scale=$4 exp_dtb=$5 exp_uenv=$6 exp_name=$7 label=$8
    rm -rf "$T/b" "$T/iio" "$T/compat" "$T/n"
    mkdir -p "$T/b/dtb" "$T/b/uEnv" "$T/iio"
    local d
    for d in rk3576-lubancat-3 rk3576-lubancat-3io rk3576-lubancat-3-v2 rk3576-lubancat-generic \
             rk3588-lubancat-5 rk3588-lubancat-5-v2 rk3588s-lubancat-4 rk3588-lubancat-generic; do
        : > "$T/b/dtb/$d.dtb"
    done
    local u
    for u in uEnvLubanCat3.txt uEnvLubanCat3IO.txt uEnvLubanCat3-V2.txt uEnvLubanCat.txt \
             uEnvLubanCat5.txt uEnvLubanCat5-V2.txt; do
        : > "$T/b/uEnv/$u"
    done
    echo "$scale" > "$T/iio/in_voltage_scale"
    echo "$ch2"   > "$T/iio/in_voltage2_raw"
    echo "$ch3"   > "$T/iio/in_voltage3_raw"
    printf "embedfire,%s-lubancat-3\0rockchip,%s\0" "$soc" "$soc" > "$T/compat"

    BOOT="$T/b" IIO_BASE="$T/iio" COMPAT_FILE="$T/compat" \
    BOARD_NAME_FILE="$T/n/board-name" REBOOT_CMD=/bin/true \
        bash "$BI" > "$T/log" 2>&1

    local got_dtb got_uenv got_name
    got_dtb=$(readlink "$T/b/rk-kernel.dtb" 2>/dev/null)
    got_uenv=$(readlink "$T/b/uEnv/uEnv.txt" 2>/dev/null)
    got_name=$(cat "$T/n/board-name" 2>/dev/null)

    if [ "$got_dtb" = "dtb/$exp_dtb" ] && [ "$got_uenv" = "$exp_uenv" ] && [ "$got_name" = "$exp_name" ]; then
        printf 'PASS  %-26s -> %s | %s | %s\n' "$label" "$got_dtb" "$got_uenv" "$got_name"
        pass=$((pass+1))
    else
        printf 'FAIL  %-26s 期望 dtb/%s | %s | %s\n' "$label" "$exp_dtb" "$exp_uenv" "$exp_name"
        printf '      实得 %s | %s | %s\n' "$got_dtb" "$got_uenv" "$got_name"
        sed -n '1,15p' "$T/log"
        fail=$((fail+1))
    fi
}

S12=0.439453125   # 1.8V/12bit -> 用 12 位阈值表
S10=1.7578125     # 1.8V/10bit -> 用 10 位阈值表

echo "== 厂商表验证（12 位阈值表，rk3576）=="
run_case rk3576 100  100   $S12 rk3576-lubancat-3.dtb      uEnvLubanCat3.txt    "LubanCat-3"      "0000 -> Cat-3"
run_case rk3576 100  1000  $S12 rk3576-lubancat-3io.dtb    uEnvLubanCat3IO.txt  "LubanCat-3IO"    "0001 -> Cat-3IO"
run_case rk3576 1000 100   $S12 rk3576-lubancat-3-v2.dtb   uEnvLubanCat3-V2.txt "LubanCat-3 v2"   "0100 -> Cat-3 v2"
run_case rk3576 4096 4096  $S12 rk3576-lubancat-generic.dtb uEnvLubanCat.txt   "LubanCat-RK3576" "表外(ffff) -> generic"

echo "== 10 位阈值表（scale > 1）=="
run_case rk3576 100  300   $S10 rk3576-lubancat-3io.dtb    uEnvLubanCat3IO.txt  "LubanCat-3IO"    "10bit 0001 -> 3IO"

echo "== rk3588s 走 rk3588 分支（旧表 case \"\$SOC:\$BID\" 会漏）=="
run_case rk3588s 2500 1500 $S12 rk3588-lubancat-5-v2.dtb   uEnvLubanCat5-V2.txt "LubanCat-5 v2"   "rk3588s 0402 -> 5-v2"

echo "== 标记已存在则跳过 =="
rm -rf "$T/b" "$T/iio" "$T/compat" "$T/n"
mkdir -p "$T/b/dtb" "$T/b/uEnv" "$T/iio"
: > "$T/b/dtb/rk3576-lubancat-3.dtb"; : > "$T/b/uEnv/uEnvLubanCat3.txt"
echo $S12 > "$T/iio/in_voltage_scale"; echo 100 > "$T/iio/in_voltage2_raw"; echo 100 > "$T/iio/in_voltage3_raw"
printf "embedfire,rk3576-lubancat-3\0rockchip,rk3576\0" > "$T/compat"
touch "$T/b/.board_init"
BOOT="$T/b" IIO_BASE="$T/iio" COMPAT_FILE="$T/compat" BOARD_NAME_FILE="$T/n/board-name" REBOOT_CMD=/bin/true \
    bash "$BI" > "$T/log" 2>&1
if [ ! -e "$T/n/board-name" ] && [ ! -e "$T/b/rk-kernel.dtb" ]; then
    echo "PASS  marker 存在 -> 不改动"; pass=$((pass+1))
else
    echo "FAIL  marker 存在却仍改动了"; sed -n '1,10p' "$T/log"; fail=$((fail+1))
fi

echo "== dtb 缺失则拒绝切换 =="
rm -rf "$T/b" "$T/n"; mkdir -p "$T/b/dtb" "$T/b/uEnv"
echo $S12 > "$T/iio/in_voltage_scale"; echo 100 > "$T/iio/in_voltage2_raw"; echo 1000 > "$T/iio/in_voltage3_raw"
BOOT="$T/b" IIO_BASE="$T/iio" COMPAT_FILE="$T/compat" BOARD_NAME_FILE="$T/n/board-name" REBOOT_CMD=/bin/true \
    bash "$BI" > "$T/log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$T/b/.board_init" ]; then
    echo "PASS  dtb 缺失 -> rc=$rc 且不写标记"; pass=$((pass+1))
else
    echo "FAIL  dtb 缺失但 rc=$rc / 标记状态 $([ -e "$T/b/.board_init" ] && echo 有 || echo 无)"; fail=$((fail+1))
fi

echo
echo "RESULT: pass=$pass fail=$fail"
rm -rf "$T"
[ "$fail" -eq 0 ]
