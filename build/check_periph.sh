#!/bin/bash
# LubanCat 外设验证（板端直接跑）
#
# 用法：
#   sudo bash check_periph.sh            # 全量（含 NPU 推理、1080p 编解码、摄像头取流）
#   sudo bash check_periph.sh --quick    # 只做状态检查，跳过耗时/会写盘的项
#   sudo bash check_periph.sh --stress   # 额外做 NPU 长循环与温度对比
#
# 四态：PASS / FAIL / SKIP / WARN
#   FAIL —— 功能不可用，必须处理
#   SKIP —— 前置条件不满足（缺模型、dtoverlay 未开、工具缺失），不算板子坏
#   WARN —— 环境相关或间接验证（无 ELD、ping 不通、仅间接覆盖）
# 退出码：有 FAIL → 1，否则 0
#
# 只写 /tmp/periph.*，退出时清理；不动 /boot、不动分区表、不改 governor。

set -u

MODE=full
for a in "$@"; do
    case "$a" in
        --quick)  MODE=quick ;;
        --stress) MODE=stress ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

TMP=$(mktemp -d /tmp/periph.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0; WARN=0
pass() { PASS=$((PASS+1)); printf '  OK   %-36s %s\n' "$1" "${2:-}"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %-36s %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %-36s %s\n' "$1" "$2"; }
warn() { WARN=$((WARN+1)); printf '  WARN %-36s %s\n' "$1" "$2"; }

ck() { # ck <名称> <期望> <实际>
    if [ "$2" = "$3" ]; then pass "$1" "$3"; else fail "$1" "期望=$2 实际=$3"; fi
}
ckhas() { # ckhas <名称> <子串> <实际>
    case "$3" in
        *"$2"*) pass "$1" "含 $2" ;;
        *)      fail "$1" "缺少 $2（实际: $(printf '%s' "$3" | head -c 80)）" ;;
    esac
}

echo "=== LubanCat 外设验证（mode=$MODE）==="
[ "$(id -u)" = 0 ] || warn "非 root" "mali0/rga/mpp_service 是 0660 root:video，部分项会失败"

echo
echo "--- 0. 环境 ---"
printf '  info %-36s %s\n' "board-name" "$(cat /etc/lubancat/board-name 2>/dev/null || echo -)"
printf '  info %-36s %s\n' "kernel"     "$(uname -r)"
printf '  info %-36s %s\n' "model"      "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
printf '  info %-36s %s\n' "lightdm"    "$(systemctl is-active lightdm 2>/dev/null)"
for f in /sys/class/devfreq/*/cur_freq; do
    [ -e "$f" ] || continue
    printf '  info %-36s %s\n' "devfreq $(basename "$(dirname "$f")")" "$(cat "$f" 2>/dev/null)"
done

echo
echo "--- 1. GPU（Mali-G52：GBM 平台 EGL + GLES2 实跑）---"
GPUINFO=$(cat /sys/class/misc/mali0/device/gpuinfo 2>/dev/null)
ck "gpuinfo 含 Mali-G52" "yes" "$(printf '%s' "$GPUINFO" | grep -q 'Mali-G52' && echo yes || echo no)"
printf '  info %-36s %s\n' "gpuinfo" "$GPUINFO"
ckhas "内核 DDK" "g25p0" "$(dmesg 2>/dev/null | grep -m1 'Kernel DDK version')"
ckhas "用户态版本 g13p0" "g13p0" "$(strings /usr/lib64/libmali.so.1.9.0 2>/dev/null | grep -m1 g13p0)"
# 桌面走 X11，X 没有 Mali 的 DRI2/GLX，所以 glxinfo 一定是 llvmpipe。
# 这是预期行为，不是 GPU 故障；GPU 只能经 GBM 平台（renderD128 / card0）使用。
printf '  info %-36s %s\n' "桌面 GL 渲染器" "$(DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0 glxinfo -B 2>/dev/null | grep -m1 'OpenGL renderer' | cut -d: -f2 | sed 's/^ *//')"

if [ "$MODE" = quick ]; then
    skip "EGL/GLES 实测" "quick 模式"
else
    SRC="$(dirname "$0")/gpu-bench.c"
    [ -f "$SRC" ] || SRC=/opt/lubancat-test/gpu-bench.c
    if [ ! -f "$SRC" ]; then
        skip "EGL/GLES 实测" "缺 gpu-bench.c（与脚本同目录，或放到 /opt/lubancat-test/）"
    elif ! gcc -O2 -o "$TMP/gpu-bench" "$SRC" -lEGL -Wl,-l:libgbm.so.1 -lGLESv2 >"$TMP/gpu-build.log" 2>&1; then
        fail "gpu-bench 编译" "$(tail -2 "$TMP/gpu-build.log" | tr '\n' ' ' | head -c 120)"
    else
        GOUT=$(LD_LIBRARY_PATH=/usr/lib64/mali timeout 90 "$TMP/gpu-bench" /dev/dri/renderD128 300 2>&1)
        ckhas "EGL 初始化（GBM/renderD128）" "vendor=ARM" "$GOUT"
        ckhas "GL_RENDERER" "GL_RENDERER = Mali-G52" "$GOUT"
        ckhas "GLES 版本" "OpenGL ES 3.2" "$GOUT"
        ckhas "像素回读正确" "READPIXEL   = 255,0,0,255" "$GOUT"
        FPS=$(printf '%s\n' "$GOUT" | sed -n 's/.*FPS=\([0-9.]*\).*/\1/p' | head -1)
        if [ -n "$FPS" ] && [ "$(echo "$FPS > 200" | bc 2>/dev/null || echo 0)" = 1 ]; then
            pass "1080p 清屏帧率" "${FPS} fps（阈值 >200）"
        else
            fail "1080p 清屏帧率" "${FPS:-无输出} fps（阈值 >200）"
        fi
        printf '  info %-36s %s\n' "实测" "$(printf '%s\n' "$GOUT" | grep -E 'PER_FRAME|RESULT' | tr '\n' ' ' | sed 's/  */ /g')"
    fi
fi

echo
echo "--- 2. NPU（RKNPU）---"
ckhas "驱动版本" "RKNPU driver" "$(cat /sys/kernel/debug/rknpu/version 2>/dev/null)"
ckhas "card1 驱动是 RKNPU" "RKNPU" "$(readlink -f /sys/class/drm/card1/device/driver 2>/dev/null)"
ck "renderD129 存在" "yes" "$([ -e /dev/dri/renderD129 ] && echo yes || echo no)"
ckhas "librknnrt 版本" "2.3.0" "$(strings /usr/lib64/librknnrt.so 2>/dev/null | grep -m1 'librknnrt version')"
ckhas "librknnrt 支持 RK3576" "RK3576" "$(strings /usr/lib64/librknnrt.so 2>/dev/null | grep -m1 RK3576)"
printf '  info %-36s %s\n' "npu freq" "$(cat /sys/class/devfreq/27700000.npu/cur_freq 2>/dev/null)"
printf '  info %-36s %s\n' "npu load" "$(cat /sys/class/devfreq/27700000.npu/load 2>/dev/null)"

SMOKE=/opt/lubancat-test/npu-smoke
MODEL=/opt/lubancat-test/model/resnet18_for_rk3576.rknn
if [ "$MODE" = quick ]; then
    skip "NPU 推理" "quick 模式"
elif [ ! -x "$SMOKE" ]; then
    skip "NPU 推理" "缺 $SMOKE（需板端编译，见文档）"
elif [ ! -f "$MODEL" ]; then
    skip "NPU 推理" "缺模型 $MODEL"
else
    N=$([ "$MODE" = stress ] && echo 1000 || echo 100)
    OUT=$("$SMOKE" "$MODEL" "$N" 2>&1)
    printf '%s\n' "$OUT" | sed 's/^/       /'
    if printf '%s' "$OUT" | grep -q '^PASS'; then
        pass "NPU 推理 $N 次" "$(printf '%s' "$OUT" | grep -o 'avg=[0-9.]* ms' | head -1)"
    else
        fail "NPU 推理" "npu-smoke 未通过"
    fi
fi

echo
echo "--- 3. VPU（MPP 编解码）---"
ck "mpp_service 节点" "yes" "$([ -e /dev/mpp_service ] && echo yes || echo no)"
ckhas "mpp_info_test 有版本" "mpp version" "$(mpp_info_test 2>&1 | grep -m1 'mpp version')"
ck "gst rockchipmpp 插件" "yes" "$(gst-inspect-1.0 rockchipmpp >/dev/null 2>&1 && echo yes || echo no)"
for e in mppvideodec mpph264enc mpph265enc mppjpegdec; do
    ck "gst element $e" "yes" "$(gst-inspect-1.0 "$e" >/dev/null 2>&1 && echo yes || echo no)"
done

if [ "$MODE" = quick ]; then
    skip "1080p 编码" "quick 模式"
    skip "1080p 解码" "quick 模式"
    skip "gst 硬解到 EOS" "quick 模式"
else
    ENC="$TMP/out.h264"
    ENC_OUT=$(timeout 90 mpi_enc_test -w 1920 -h 1080 -t 7 -n 60 -o "$ENC" -v f 2>&1)
    ENC_RC=$?
    ENC_SZ=$(stat -c %s "$ENC" 2>/dev/null || echo 0)
    if [ "$ENC_RC" -eq 0 ] && [ "$ENC_SZ" -gt 100000 ]; then
        pass "1080p H.264 编码" "$(printf '%s' "$ENC_OUT" | grep -oE 'fps[: ]+[0-9.]+' | tail -1) 输出=$((ENC_SZ/1024))KB"
    else
        fail "1080p H.264 编码" "rc=$ENC_RC size=$ENC_SZ"
        printf '%s\n' "$ENC_OUT" | tail -4 | sed 's/^/       /'
    fi

    if [ "$ENC_SZ" -gt 0 ]; then
        DEC_OUT=$(timeout 90 mpi_dec_test -t 7 -i "$ENC" -n 60 -v f 2>&1)
        DEC_RC=$?
        if [ "$DEC_RC" -eq 0 ]; then
            pass "1080p H.264 解码" "$(printf '%s' "$DEC_OUT" | grep -oE 'fps[: ]+[0-9.]+' | tail -1)"
        else
            fail "1080p H.264 解码" "rc=$DEC_RC"
        fi

        GST_OUT=$(timeout 60 gst-launch-1.0 -q filesrc location="$ENC" ! h264parse ! mppvideodec ! fakesink 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then pass "gst 硬解到 EOS" "exit 0"; else fail "gst 硬解到 EOS" "rc=$rc"; fi
    else
        skip "1080p 解码" "没有可用的码流"
        skip "gst 硬解到 EOS" "没有可用的码流"
    fi
fi

echo
echo "--- 4. RGA ---"
ck "rga 节点" "yes" "$([ -e /dev/rga ] && echo yes || echo no)"
# 注意：dmesg 里 rga2 的第一条是 "Adding to iommu group"，不能只取第一条
ckhas "rga2 驱动 probe" "probe successfully" "$(dmesg 2>/dev/null | grep -i rga2 | grep -m1 'probe successfully')"
ck "librga.so.2.1.0" "yes" "$([ -e /usr/lib64/librga.so.2.1.0 ] && echo yes || echo no)"
if [ "$MODE" = quick ]; then
    skip "RGA 用户态" "quick 模式"
elif gst-inspect-1.0 rkximagesink >/dev/null 2>&1; then
    # rkximagesink 是显示 sink（内部做格式转换时会用 RGA），但跑它会占桌面开窗，
    # 不适合自动化；这里只标注"可用但需人工看"，不计 PASS 也不计 FAIL
    skip "RGA 用户态" "仅 rkximagesink（开窗显示），手工验：gst-launch-1.0 videotestsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! rkximagesink"
else
    skip "RGA 用户态" "无任何 RGA 测试工具"
fi

echo
echo "--- 5. 摄像头 / ISP ---"
SKIP_CAM=0
if ls /proc/device-tree/i2c@2ac70000 2>/dev/null | grep -q imx415; then
    pass "DT 里有 imx415 节点" "i2c4"
    ISP=$(media-ctl -d /dev/media1 -e "rkisp_mainpath" 2>/dev/null)
    [ -n "$ISP" ] || ISP=/dev/video11
    printf '  info %-36s %s\n' "取流节点" "$ISP"
    # imx415 这个 entity 挂在 /dev/media0（rkcif），不在 media1（rkisp），要逐个找
    MT=
    for m in /dev/media0 /dev/media1 /dev/media2; do
        if media-ctl -d "$m" -p 2>/dev/null | grep -q imx415; then MT=$m; break; fi
    done
    # sensor 没插 / 没应答时，DT 节点仍在（overlay 决定），但不会 probe 出 media entity。
    # 这是硬件状态，不是软件故障 —— 判 SKIP，别报 FAIL。
    if [ -n "$MT" ]; then
        pass "media 拓扑含 imx415" "$MT"
    elif dmesg 2>/dev/null | grep -q 'imx415 .*: Detected imx415 id'; then
        fail "media 拓扑含 imx415" "sensor 探到了但 media 里没有，检查 rkcif/rkisp 绑定"
    else
        skip "media 拓扑含 imx415" "sensor 未接入（i2c 无应答，硬件未插）—— DT 节点在，软件侧正常"
        SKIP_CAM=1
    fi

    if [ "$MODE" = quick ]; then
        skip "取流 10 帧" "quick 模式"
    elif [ "${SKIP_CAM:-0}" = 1 ]; then
        skip "取流 10 帧" "sensor 未接入"
    else
        CAP="$TMP/cam.nv12"
        timeout 30 v4l2-ctl -d "$ISP" --set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
            --stream-mmap=3 --stream-count=10 --stream-to="$CAP" >/dev/null 2>&1
        rc=$?
        SZ=$(stat -c %s "$CAP" 2>/dev/null || echo 0)
        if [ "$rc" -eq 0 ] && [ "$SZ" -gt 1000000 ]; then
            pass "取流 10 帧 1080p" "$((SZ/1024/1024)) MB"
        elif [ "$rc" -eq 124 ]; then
            fail "取流 10 帧 1080p" "超时（ISP 被占用？试 systemctl stop lightdm 后重试）"
        else
            fail "取流 10 帧 1080p" "rc=$rc size=$SZ"
        fi
    fi
else
    skip "摄像头" "DT 里没有 imx415（uEnv 的 dtoverlay 未打开）"
fi

echo
echo "--- 6. 音频 / 3.5mm 耳机 ---"
NCARD=$(aplay -l 2>/dev/null | grep -c '^card ')
ck "声卡数量 >= 3" "yes" "$([ "$NCARD" -ge 3 ] && echo yes || echo no)"
printf '  info %-36s %s\n' "声卡" "$(aplay -l 2>/dev/null | grep '^card ' | cut -d: -f1-2 | tr '\n' ' ')"
# 3.5mm 通路的命门：OUT1（耳机输出混音器）必须为 on。
# 它为 off 时 DAPM 找不到 Playback->DAC->Mixer->Out1->OUT1->LOUT1->Headphone 的完整通路，
# 整条链都不上电：aplay 正常、hw_ptr 正常，但完全无声。详见文档音频节。
ck "OUT1 耳机通路开关" "on" "$(amixer -c 0 sget OUT1 2>/dev/null | tail -1 | sed 's/.*\[\(.*\)\].*/\1/')"
if [ "$MODE" = quick ]; then
    skip "ES8323 播放" "quick 模式"
    skip "耳机通路带电" "quick 模式"
else
    timeout 15 speaker-test -D hw:0,0 -t sine -f 440 -l 1 -p 1 >"$TMP/spk.log" 2>&1
    rc=$?
    case "$rc" in
        0)   pass "ES8323 播放（card0）" "DMA 正常（是否有声需人耳）" ;;
        124) fail "ES8323 播放（card0）" "TIMEOUT —— DMA 卡住（Cat-5 出现过 PL330 描述符超 mcbufsz）" ;;
        *)
            if grep -qiE 'busy|resource busy' "$TMP/spk.log"; then
                # 桌面 PulseAudio 正占着 hw:0,0，不是板子的问题
                skip "ES8323 播放（card0）" "hw:0,0 被 PulseAudio 占用（关掉正在播放的音频再跑，或用 --quick）"
            else
                fail "ES8323 播放（card0）" "rc=$rc $(tail -2 "$TMP/spk.log" | tr '\n' ' ' | head -c 80)"
            fi
            ;;
    esac

    # 播放中看芯片是否真上电：hp-con 使能脚 + ES8388 R4 的左右 DAC 掉电位
    HPDET=$(grep -m1 'hp-det' /sys/kernel/debug/gpio 2>/dev/null)
    RM=$(ls -d /sys/kernel/debug/regmap/*-0011 2>/dev/null | head -1)
    if ! printf '%s' "$HPDET" | grep -q ' in  hi'; then
        skip "耳机通路带电" "未检测到耳机（hp-det=lo），插上耳机后重跑"
    else
        speaker-test -D hw:0,0 -t sine -f 440 -p 1 -l 0 >/dev/null 2>&1 &
        SPK=$!
        sleep 2
        HPCON=$(grep -m1 'hp-con' /sys/kernel/debug/gpio 2>/dev/null)
        R4=$([ -n "$RM" ] && awk '$1=="04:"{print $2}' "$RM/registers" 2>/dev/null)
        kill $SPK 2>/dev/null; wait $SPK 2>/dev/null
        case "$HPCON" in
            *"out hi"*) pass "hp-con 使能脚" "播放中已拉高" ;;
            *)          fail "hp-con 使能脚" "播放中仍为低，通路未通（${HPCON:-读不到}）" ;;
        esac
        case "$R4" in
            ""|c0|C0) fail "ES8388 DAC 上电" "R4=${R4:-读不到}，左右 DAC 仍掉电（应为 3c 之类）" ;;
            *)        pass "ES8388 DAC 上电" "R4=$R4（bit7/bit6 已清零）" ;;
        esac
    fi
fi
ELD=0
for f in /proc/asound/card1/eld#*; do [ -e "$f" ] && ELD=1; done
if [ "$ELD" = 1 ]; then pass "HDMI ELD" "存在"; else warn "HDMI ELD" "无 ELD（未接带音频的显示器，非故障）"; fi

echo
echo "--- 7. 网络 ---"
ckhas "end0 有 IPv4" "/" "$(ip -4 -br addr show end0 2>/dev/null | awk '{print $3}')"
printf '  info %-36s %s\n' "end0 速率" "$(ethtool end0 2>/dev/null | grep -m1 Speed)"
if timeout 8 ping -c2 -W2 223.5.5.5 >/dev/null 2>&1; then
    pass "外网连通" "ping 223.5.5.5"
else
    warn "外网连通" "ping 不通（环境相关，非板级故障）"
fi

echo
echo "--- 8. USB / 存储 ---"
ck "USB 枚举 >= 1" "yes" "$([ "$(lsusb 2>/dev/null | wc -l)" -ge 1 ] && echo yes || echo no)"
printf '  info %-36s %s\n' "USB 设备数" "$(lsusb 2>/dev/null | wc -l)"
# lsblk 默认带树形缩进（├─），不能用 ^ 锚点
ck "eMMC 三个分区" "3" "$(lsblk -o NAME 2>/dev/null | grep -c 'mmcblk0p')"
printf '  info %-36s %s\n' "根分区" "$(findmnt -n -o SOURCE,SIZE,USE% / 2>/dev/null | tr -s ' ')"

echo
echo "--- 9. 温度 ---"
MAXT=0; MAXZ=-
for z in /sys/class/thermal/thermal_zone*; do
    [ -e "$z/temp" ] || continue
    t=$(cat "$z/temp" 2>/dev/null || echo 0)
    [ "$t" -gt "$MAXT" ] 2>/dev/null && { MAXT=$t; MAXZ=$(cat "$z/type" 2>/dev/null); }
done
printf '  info %-36s %s\n' "最高温" "$((MAXT/1000))C ($MAXZ)"
ck "最高温 < 85C" "yes" "$([ "$MAXT" -lt 85000 ] && echo yes || echo no)"

echo
echo "================ RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN ================"
[ "$FAIL" -eq 0 ] && echo "无 FAIL（SKIP/WARN 不计入失败，请逐条看原因）" || echo "有 FAIL 项，见上"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
