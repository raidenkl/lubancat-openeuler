# 外设验证手册

本文给出 LubanCat（RK3576 / RK3588）在 openEuler 上逐项验证外设的方法，以及**实测基线**。
每条固定四段：**验什么 → 命令 → 期望输出 → 失败含义**。

前置阅读：`docs/troubleshooting.md`（引导、显示、overlay 的排障）。

---

## 0. 两种用法

### 0.1 一键跑（推荐）

```sh
# 1) 构建机上把资产推过去（只做一次，重刷镜像后要重推）
#    npu-smoke.c / check_periph.sh / gpu-bench.c 来自仓库 build/，model/ 与 include/ 见第 2 节
scp -r /path/to/lubancat-test root@<板卡IP>:/opt/

# 2) 板端
cd /opt/lubancat-test
gcc -O2 -I include npu-smoke.c -o npu-smoke -L/usr/lib64 -lrknnrt -lpthread -ldl -lm
# gpu-bench.c 由 check_periph.sh 自己编，不用手工编；想单独跑见第 1 节
sudo bash check_periph.sh            # 全量，约 2 分钟
sudo bash check_periph.sh --quick    # 只做状态检查，不写盘
sudo bash check_periph.sh --stress   # NPU 跑 1000 次，看温升
```

脚本输出四态并给退出码（有 `FAIL` 则 `exit 1`）：

| 态 | 含义 |
|---|---|
| **PASS** | 功能可用 |
| **FAIL** | 功能不可用，必须处理 |
| **SKIP** | 前置条件不满足（缺模型、`dtoverlay` 未开、无工具），不算板子坏 |
| **WARN** | 环境相关或仅间接覆盖（无 ELD、ping 不通、只能开窗人工看） |

`/opt/lubancat-test/` 是**临时验证目录**，不在镜像里，重刷后需重新推送。

### 0.2 手工逐项

下面每节的命令都可直接粘贴。需要 root，或者把用户加进 `video` 组：

```sh
usermod -aG video lubancat     # /dev/mali0、/dev/rga、/dev/mpp_service 都是 0660 root:video
```

---

## 1. GPU（Mali-G52）

### 验什么

- 内核驱动是否识别到 GPU、用户态库版本
- EGL 能否初始化、GLES 能否**真的出像素**（回读校验），以及吞吐
- 桌面 GL 是不是 Mali（结论：不是，见「桌面为什么是 llvmpipe」）

### 命令

```sh
cat /sys/class/misc/mali0/device/gpuinfo                  # Mali-G52 3 cores r1p0
dmesg | grep 'Kernel DDK version'                         # g25p0-00eac0
strings /usr/lib64/libmali.so.1.9.0 | grep -m1 g13p0      # g13p0-01eac0

# 关键：必须走 GBM 平台 + 显式指到 DRM 节点，且只用 pbuffer
gcc -O2 -o /tmp/gpu-bench build/gpu-bench.c -lEGL -Wl,-l:libgbm.so.1 -lGLESv2
LD_LIBRARY_PATH=/usr/lib64/mali /tmp/gpu-bench /dev/dri/renderD128 300
```

### 期望

```
EGL 1.4  vendor=ARM
EGL_VERSION=1.4 Bifrost-"g13p0-01eac0"
SURFACE_TYPE=pbuffer
GL_VENDOR   = ARM
GL_RENDERER = Mali-G52
GL_VERSION  = OpenGL ES 3.2 v1.g13p0-01eac0...
READPIXEL   = 255,0,0,255
FRAMES=300  PER_FRAME=1.461 ms  FPS=684.4  PIXELFILL=1.4 Gpix/s
RESULT=PASS
```

判据：`vendor=ARM`、`GL_RENDERER = Mali-G52`、`OpenGL ES 3.2`、`READPIXEL` 为 `255,0,0,255`
（说明像素真是 GPU 算出来并回读得到的，不是空跑）、FPS > 200。

### 为什么 `eglinfo` / `es2_info` 全失败（已定论）

`eglinfo` 走的是 `eglGetDisplay(EGL_DEFAULT_DISPLAY)`，即 **X11/DRI2** 那条路，本镜像上必然失败：

```
GBM platform:      eglinfo: eglInitialize failed
Wayland platform:  eglinfo: eglInitialize failed
X11 platform:      eglinfo: eglInitialize failed
```

- **X11 平台**：X 自己没有 GPU。`Xorg.0.log` 里是
  `modeset(0): Refusing to try glamor on llvmpipe` → `AIGLX: Screen 0 is not DRI2 capable`
  → `GLX: Initialized DRISWRAST GL provider`，`glxinfo` 的 renderer 就是 `llvmpipe`。
  Mali 不是 Mesa 驱动，X 拿不到 DRI2，`EGL_DEFAULT_DISPLAY` 无从初始化。
- **GBM 平台（eglinfo 的写法）**：它建完 `gbm_device` 后要用 `EGL_WINDOW_BIT` 的 config
  挂一个 scanout surface；X 正持有 DRM master，window surface 直接 `EGL_BAD_MATCH`（0x3009）。
- **Wayland 平台**：没有 Wayland 合成器在跑。

把 EGL 显式绑到 **GBM 平台 + DRM 节点**、并且只用 **pbuffer**（不需要 master、不需要扫描输出），
一切正常 —— 上面的实测就是这条路。

**结论：GPU 本身没问题，之前是探测路径选错了。`eglinfo` 的 `eglInitialize failed`
不能用来判断「GPU 坏没坏」。**

### 顺带排除的两个怀疑

| 怀疑 | 结论 |
|---|---|
| 内核 DDK `g25p0` 比用户态 `g13p0` 新 | **不是问题**。DDK 高于 so 是允许方向（只不允许 so 比 DDK 新），实测初始化成功即证 |
| `libmali` 缺依赖 / 打不开设备 | **不是**。`ldd` 无缺失；`open("/dev/mali0")` 成功；kbase 正常分配内存 |

### 桌面为什么是 llvmpipe（预期行为）

ukui 跑在 X11 上，X 没有 Mali 的 DRI2/GLX 集成，所以桌面是软件渲染。
要让桌面用 GPU，得给 X 提供 Mali 的 GLX，或改走 Wayland 合成器 —— 属于另一件事。
需要 GPU 的应用用 `mali-env` + GBM（离屏渲染、合成器、`kmscube` 类）即可。

### 失败含义

| 现象 | 含义 |
|---|---|
| `vendor=Mesa Project` | 加载到系统 mesa 的 libEGL 了，检查 `LD_LIBRARY_PATH=/usr/lib64/mali` |
| 连 `vendor` 都没打印就失败 | hook 没找到真库：`ldd /usr/lib64/mali/libEGL.so.1` 看是否指向 `libmali.so.1` |
| `eglCreateWindowSurface` 返回 `0x3009` | 用了 window surface。X 持有 master 时建不出来，改 pbuffer |
| `GL_RENDERER` 里没有 `Mali` 但有 `MALI-HOOK` | 假阳性：那是 hook 的告警文案，只认 `GL_RENDERER` 行 |

---

## 2. NPU（RKNPU）

### 验什么

驱动、运行时库版本，以及**真实跑一次推理**（能算，而不只是 probe 成功）。

### 命令

```sh
cat /sys/kernel/debug/rknpu/version                        # RKNPU driver: v0.9.8
readlink -f /sys/class/drm/card1/device/driver             # /sys/bus/platform/drivers/RKNPU
ls /dev/dri/renderD129
strings /usr/lib64/librknnrt.so | grep -m1 'librknnrt version'
cat /sys/class/devfreq/27700000.npu/{cur_freq,load}
```

注意：**没有 `/dev/rknpu` 这个节点**，NPU 走 DRM accel 架构，设备是 `/dev/dri/card1` +
`/dev/dri/renderD129`，别照着旧文档找 `/dev/rknpu`。

SDK 自带的 `rknn_benchmark` **依赖 OpenCV**（`CMakeLists.txt` 里
`target_link_libraries(... ${OpenCV_LIBS})`），本镜像没装 OpenCV，所以改用
`build/npu-smoke.c`（只用 `rknn_api.h` + `librknnrt.so`）：

```sh
cd /opt/lubancat-test
gcc -O2 -I include npu-smoke.c -o npu-smoke -L/usr/lib64 -lrknnrt -lpthread -ldl -lm
./npu-smoke model/resnet18_for_rk3576.rknn 100
```

### 期望

```
sdk     : api=2.3.0 (...) driver=0.9.8
io      : n_input=1 n_output=1
input   : n_dims=4 dims=[1,224,224,3]
run     : loop=100 fail=0 avg=3.341 ms  299.3 fps
PASS
```

### 失败含义

| 现象 | 含义 |
|---|---|
| `rknn_init` 失败 | 模型与 SoC 不匹配（用了 `*_for_rk3588.rknn`）或运行时库版本不符 |
| `RKNN_QUERY_SDK_VERSION` 失败 | `librknnrt.so` 与驱动 ABI 不符 |
| `avg` 明显 > 30 ms | 降频或模型跑在 CPU 上（看 `devfreq/27700000.npu/cur_freq`） |
| 编译报 `rknn_api.h` 找不到 | 没把 SDK 的 `include/` 一起拷过去 |

模型来源：`SDK/external/rknn-toolkit2/rknn-toolkit-lite2/examples/resnet18/resnet18_for_rk3576.rknn`。

---

## 3. VPU（MPP 编解码）

### 验什么

MPP 用户态库、硬件编解码实例、GStreamer 插件接线。

### 命令

```sh
cat /sys/kernel/debug/mpp_service 2>/dev/null || dmesg | grep -i 'mpp_service mpp-srv'   # probe success
mpp_info_test                                              # mpp version 43a191ed ...
gst-inspect-1.0 rockchipmpp                                # 4 个 element
mpi_enc_test -w 1920 -h 1080 -t 7 -n 60 -o /tmp/out.h264 -v f     # -t 7 = H.264
mpi_dec_test -t 7 -i /tmp/out.h264 -n 60 -v f
gst-launch-1.0 -q filesrc location=/tmp/out.h264 ! h264parse ! mppvideodec ! fakesink
```

`/sys/kernel/debug/mpp_service/` 这个目录**不存在**（该 debugfs 未提供），
看驱动状态用 `dmesg | grep mpp`。

### 期望

编码/解码都打印 `fps`，输出文件非空；gst 管线跑到 EOS（退出码 0）。

### 失败含义

| 现象 | 含义 |
|---|---|
| `mpi_enc_test` 报 `invalid input height` | 少了 `-w/-h`，参数没给全 |
| 编码成功但 fps 很低 | 检查 `devfreq/dmc` 与温度（降频） |
| gst 找不到 `mppvideodec` | `libgstrockchipmpp.so` 没装或依赖缺失（`ldd` 它） |
| ffmpeg 想用硬解 | **不行**，本镜像的 ffmpeg 6.1.1 没有 rkmpp；用 `mpi_*` 或 gst |

---

## 4. RGA（2D 加速）

### 验什么

驱动 probe；用户态目前**没有可自动化验证的工具**。

### 命令

```sh
ls -l /dev/rga                                              # crw-rw---- root video
dmesg | grep -i rga2 | grep 'probe successfully'            # 两条（双核）
ls -l /usr/lib64/librga.so.2.1.0
```

手工（会占用桌面开窗，只看是否流畅）：

```sh
gst-launch-1.0 videotestsrc num-buffers=300 ! \
  video/x-raw,format=NV12,width=1920,height=1080 ! rkximagesink
```

### 失败含义

- 只有一条 `probe successfully`：双核里有一个没起来
- `rkximagesink` 找不到：`libgstrkximage.so` 的 element 名是 `rkximagesink`，**不是 `rkximage`**
- 无头文件、无 demo：镜像里没有 `librga` 的 devel 与测试程序，要写用例得自带头文件

---

## 5. 摄像头与 ISP

### 前置：DT 里得有 sensor

sensor 是通过 **uEnv 的 dtoverlay** 挂进来的，模板里默认是注释态：

```sh
grep -nE "^enable_uboot_overlays|^dtoverlay" /boot/uEnv/uEnv.txt
```

要开 cam1 的 imx415，把对应行取消注释后重启（注意 `size=` 那条别动，理由见
`docs/troubleshooting.md` 的 overlay 一节）：

```
enable_uboot_overlays=1
dtoverlay=/dtb/overlay/rk3576-lubancat-3-cam1-imx415-1920x1080-60fps-overlay.dtbo
```

### 命令

```sh
ls /proc/device-tree/i2c@2ac70000 | grep imx415             # 节点在 = overlay 生效
dmesg | grep -i imx415                                      # Detected imx415 id 0000e0
media-ctl -d /dev/media0 -p | grep imx415                   # 拓扑在 media0（rkcif）
media-ctl -d /dev/media1 -e rkisp_mainpath                  # 取流节点，通常 /dev/video11
v4l2-ctl -d /dev/video11 --set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
         --stream-mmap=3 --stream-count=10 --stream-to=/tmp/cam.nv12
ls -l /tmp/cam.nv12                                          # ≈29 MB
```

### 失败含义

| 现象 | 含义 |
|---|---|
| `/proc/device-tree` 里没有 imx415 | dtoverlay 没开，先回第 5 节前置 |
| `detect imx415` 失败 / i2c 无应答 | sensor 没接好或供电/时钟不对 |
| 取流超时 | ISP 被占用（先 `systemctl stop lightdm`）或链路没配好 |
| `media-ctl -p` 里 imx415 在 media0 | 正常，它挂在 rkcif 侧；rkisp 是 media1 |

3A：`/usr/bin/rkaiq_3A_server` 与 `/etc/iqfiles/` 下 12 个 sensor 的 json 已随镜像装好
（`camera-engine-rkaiq-rk3576`），本手册只验「能取到帧」，不做画质与标定。

---

## 6. 音频 / 3.5mm 耳机

### 命令

```sh
aplay -l                                                     # 3 张卡
amixer -c 0 sget OUT1                                        # 耳机输出混音器，必须 on
timeout 15 speaker-test -D hw:0,0 -t sine -f 440 -l 1 -p 1   # 用退出码判 DMA
grep -E 'gpio-13[68]' /sys/kernel/debug/gpio                 # hp-det / hp-con
awk '$1=="04:"{print $2}' /sys/kernel/debug/regmap/3-0011/registers   # ES8388 R4
cat /proc/asound/card1/eld#*                                 # HDMI ELD
```

### 期望与判据

- `aplay -l` 至少 3 张卡：`rockchipes8388`(card0，唯一带 capture)、`rockchip-hdmi`、`rockchip-dp0`
- `amixer -c 0 sget OUT1` 必须 **on**（见下面「3.5mm 无声的根因」）
- `speaker-test` **退出码 0** = DMA 通路正常
- **退出码 124 = TIMEOUT**，DMA 卡住的信号 —— Cat-5 上出现过：PL330 的音频描述符
  258 B 超过默认 `mcbufsz` 256 B，`aplay` 永久阻塞（见 `manifests/alpha7-summary.txt`）
- **播放中** `hp-con`（GPIO4_B2）应为 **out hi**，ES8388 `R4` 的 bit7/bit6（左右 DAC 掉电位）
  必须为 0（正常值 `3c`，掉电时是 `c0`）。这两条是「通路真的通电了」的硬证据，
  不依赖人耳；`R2` 正常为 `00`，掉电时是 `ff`
- 无 ELD 只是「显示器不带音频 sink」，属 WARN，不是故障

### 3.5mm 无声的根因（2026-11-25 定位并修复）

**症状**：插耳机完全没声音，但一切看起来都正常 —— `aplay` 不报错、PCM `state: RUNNING`、
`hw_ptr` 正常推进、`dmesg` 干净。

**根因**：`/var/lib/alsa/asound.state` 里 `OUT1 Switch` / `OUT2 Switch` 是 `false`，
开机 alsa 状态恢复照搬这个值。而 ES8388 的模拟输出链路是

```
Playback 流 -> Left DAC -> Left Mixer -> Left Out 1 -> OUT1 -> LOUT1 -> Headphone
```

`OUT1` 这个输出混音器一关，**DAPM 就找不到从流到 Headphone 引脚的完整通路，
于是整条链一个部件都不上电**。表现：

```
dapm_pop_time = 0                        # 上电序列一次都没跑
Left DAC / Left Mixer / LOUT1 / Headphone: Off
hp-con = out lo
ES8388 R2 = ff, R4 = c0                  # 数字部分全关、左右 DAC 掉电
```

`aplay` 之所以看着正常，是因为 SAI 侧 DMA 照跑，只是数据进了没上电的 codec。

**修复**：`scripts/overlay/common/usr/libexec/lubancat/audio-init.sh` +
`lubancat-audio-mixer.service`，开机把 `OUT1` 和 `Headphone` 两个**功能使能**开关置 on
（音量不动，属于用户偏好）。单元排在 `alsa-restore` / `alsa-state` **和 `lightdm` 之后**：

- 排在 alsa 之后：否则 `asound.state` 会把 `OUT1` 又写回 off
- 排在 lightdm 之后：multicodecs 卡的耳机插拔由 jack 上报，开机早期那次上报可能在
  codec 就绪前就判成「未插入」并把 `Headphone` 引脚关掉；等它报完再断言才留得住

**验证**（本机实测）：重启后 `OUT1=on`、`Headphone=on`；插着耳机放音时
`hp-con = out hi`、`Left DAC/Mixer/LOUT1/Headphone = On`、`R2=00`、`R4=3c`，人耳确认有声。

### 排查这类"看着正常却没声"的顺序

1. `amixer -c 0 contents` 逐项看：输出通路上有没有开关是 off（尤其 `OUT1`）
2. `cat /sys/kernel/debug/asoc/<card>/dapm_pop_time` 恒为 0 → DAPM 上电序列没跑过
3. 看 codec 的 widget 状态（`/sys/kernel/debug/asoc/*/ES8323.3-0011/dapm/`）与寄存器
   （`/sys/kernel/debug/regmap/3-0011/registers`，`i2cdump` 会被驱动占用而报 busy）
4. `grep gpio . /sys/kernel/debug/gpio` 看 `hp-det`（耳机检测）与 `hp-con`（通路使能）
5. 耳机在不在：`python3` 读 `EVIOCGSW`（`/dev/input/event3`），或直接看 `hp-det`

### 其它两点

- Cat-3 **只有 3.5mm 接口、没有扬声器**，所以只开 `OUT1`，`Speaker`/`OUT2` 保持 off
- HDMI/DP 声卡在没接带音频的显示器时打不开是正常的（`hdmi-audio-codec: Only one
  simultaneous stream supported!`），不影响模拟输出

---

## 7. 网络 / USB / 存储

```sh
ip -br link ; ip -4 -br addr show end0
ethtool end0 | grep Speed                   # 期望 1000Mb/s
ping -c2 -W2 223.5.5.5                      # 环境相关，失败只 WARN
lsusb
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT          # 期望 mmcblk0p1(4M) / p2(/boot 512M) / p3(/) 
findmnt -n -o SOURCE,SIZE,USE% /
```

注意 `lsblk` 默认输出带树形缩进（`├─`），写脚本计数时**不能加 `^` 锚点**。

---

## 8. 温度与调频

```sh
for z in /sys/class/thermal/thermal_zone*; do
  printf '%-24s %s\n' "$(cat $z/type)" "$(( $(cat $z/temp) / 1000 ))C"
done
for d in /sys/class/devfreq/*; do
  printf '%-22s cur=%-10s gov=%s\n' "$(basename $d)" "$(cat $d/cur_freq)" "$(cat $d/governor)"
done
```

6 个 zone：soc / bigcore / little-core / ddr / npu / gpu；4 个 devfreq：npu / gpu / vop / dmc。
压测前后对比这两组值，就能看出是否降频。

判据：空闲 < 60 °C，满载 < 85 °C。跑 `--stress`（NPU 1000 次）可观察温升。

---

## 9. 实测基线（2026-11-25，LubanCat-3 V2）

环境：`openEuler 24.03 LTS SP3`，内核 `6.1.99-rk3576`，`board-name = LubanCat-3 v2`，
`lightdm active`，空闲温度 55 °C。

| 外设 | 结果 | 关键数字 |
|---|---|---|
| GPU Mali-G52 | **PASS** | `GL_RENDERER = Mali-G52` / `OpenGL ES 3.2`；1080p 清屏 300 帧 **1.461 ms/帧，684 fps，1.4 Gpix/s**，像素回读正确（走 GBM + pbuffer，桌面仍是 llvmpipe） |
| NPU | PASS | `librknnrt 2.3.0` / driver `0.9.8`；resnet18 224×224 **3.341 ms，299.3 fps**（100 次 0 失败） |
| VPU 编码 | PASS | 1080p H.264 60 帧 **109.08 fps**，输出 735 KB |
| VPU 解码 | PASS | 同一码流 **567.26 fps** |
| GStreamer | PASS | `rockchipmpp` 4 element；`mppvideodec` 跑到 EOS |
| RGA | 驱动 PASS / 用户态 SKIP | 双核 `probe successfully`、驱动 v1.3.7；无测试工具 |
| 摄像头 | PASS（需接模组） | imx415 在 cam1（i2c4），`media0` 拓扑可见，1080p NV12 取 10 帧 = 29 MB；拔掉模组时脚本判 SKIP 而非 FAIL |
| 音频 3.5mm | **PASS** | 3 张卡；`OUT1=on`、播放中 `hp-con=hi`、`R2=00`/`R4=3c`；人耳确认有声 |
| 网络 | PASS | `end0` 1000Mb/s，有 IPv4，外网可达 |
| USB | PASS | 4 个设备（2 root hub + 7-port hub + 鼠标） |
| 存储 | PASS | `mmcblk0p1/p2/p3`；`/` 28.1 G 用 23% |
| 温度 | PASS | 最高 55 °C（little-core） |

复跑命令：`sudo bash /opt/lubancat-test/check_periph.sh` → `PASS=38 FAIL=0 SKIP=2 WARN=1`
（摄像头模组拔掉时为 `PASS=36 SKIP=4`）。

与 Cat-5（RK3588）可比的一项：resnet18 推理 Cat-5 是 4.66 ms，Cat-3 是 3.34 ms
（模型同为 resnet18，输入同为 224×224）。

---

## 10. 已知问题

| 项 | 状态 | 说明 |
|---|---|---|
| 桌面不走 Mali | 预期 | X11 无 Mali DRI2/GLX，桌面是 llvmpipe；GPU 经 GBM 可用（第 1 节） |
| RGA 无自动化验证 | 缺口 | 无测试工具与头文件，只能开窗看 `rkximagesink` |
| 摄像头默认不启用 | 设计如此 | uEnv 模板里 dtoverlay 是注释态，要手工开 |
| 耳机插拔检测不稳定 | 待查 | jack 开机首次上报可能误判「未插入」并把 Headphone 引脚关掉，已用「lightdm 之后再断言」绕过；根因在 `rockchip_multicodecs` 的 jack 初始化时序 |
| PCIe / mSATA、WiFi/蓝牙 | 未覆盖 | Cat-3 无对应硬件或未接模组 |
| 画质与 3A 标定 | 未做 | 只验「能取到帧」 |

## 11. 不做什么

- 不在验证脚本里改 `governor`、不动 `/boot`、不动分区表
- 不把测试资产固化进镜像（`/opt/lubancat-test` 是临时目录，重刷需重推）
