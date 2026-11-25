#!/bin/sh
# 打开 ES8388 的耳机输出通路。
#
# 背景：镜像里 /var/lib/alsa/asound.state 记录的 OUT1/OUT2 开关是 false，
# 而 ES8388 的模拟输出是 DAC -> Left Mixer -> Left Out 1 -> OUT1 -> LOUT1 -> Headphone，
# OUT1 这个混音器开关一关，DAPM 就找不到从 Playback 流到 Headphone 引脚的完整通路，
# 于是整条链（DAC / Mixer / LOUT1 / Headphone，含 hp-con 使能脚）都不上电：
#   dmesg 无异常、aplay 正常 RUNNING、hw_ptr 正常推进，但 3.5mm 完全无声。
# 表现为 `dapm_pop_time` 恒为 0、ES8388 R2=0xFF / R4=0xC0。
#
# 这里只改"功能使能"类的开关，不碰音量（音量属于用户偏好，由 asound.state 保存）。
# 找不到 ES8388 声卡时静默退出，便于同一份 overlay 供全系共用。

set -u

CARD=""
for c in /proc/asound/card[0-9]*; do
    [ -r "$c/id" ] || continue
    case "$(cat "$c/id" 2>/dev/null)" in
        *es8388*|rockchipes8388*|rockchip-es8388*)
            CARD=$(basename "$c" | sed 's/^card//')
            break
            ;;
    esac
done

[ -n "$CARD" ] || exit 0
command -v amixer >/dev/null 2>&1 || exit 0

# OUT1 = 耳机输出（LOUT1/ROUT1）；Headphone = 耳机引脚开关
amixer -c "$CARD" sset OUT1 on          >/dev/null 2>&1
amixer -c "$CARD" sset Headphone on     >/dev/null 2>&1

# 音量只在"被静音或归零"时兜底到 30/33（约 91%），避免覆盖用户调过的值
VOL=$(amixer -c "$CARD" sget "Output 1" 2>/dev/null | awk '/Front Left/ {print $4}' | tr -dc '0-9')
if [ -z "${VOL:-}" ] || [ "$VOL" -eq 0 ]; then
    amixer -c "$CARD" sset "Output 1" 30 >/dev/null 2>&1
fi

exit 0
