#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# tools/build-image.sh —— LubanCat openEuler 镜像统一构建入口
#
#   第一层选 SoC 家族 → 第二层选该家族的板卡 → 第三层选桌面（ukui / none），
#   然后一条龙出镜像。所有板卡信息来自 scripts/boards/matrix.tsv，
#   新增一块板卡只需在那里加一行 + 一份 boards/<board>.conf。
#
# 用法：
#   tools/build-image.sh                       # 交互菜单
#   tools/build-image.sh --list                # 列出矩阵
#   tools/build-image.sh --board lubancat-5 --desktop ukui -y
#   tools/build-image.sh --soc rk356x --list
#   tools/build-image.sh --board lubancat-5 --stage image -y
#   tools/build-image.sh --board lubancat-5 --dry-run -V
#
# 说明：本脚本只做「选择 + 校验 + 编排」，不修改 scripts/build.sh 的参数语义。
#       dtb_name / soc_name / boot_size / local_uboot_dir / ubootconfig 等
#       一律以 boards/<board>.conf 为准，这里只读不写。
set -u

PROG=$(basename "$0")
SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO=$(cd "$(dirname "$SELF")/.." && pwd)
SBC=$REPO/scripts
# 运行环境：容器内（/work）还是宿主。宿主模式下 u-boot/内核可走本地编译，
# 其余需要 root 的阶段（rootfs/initrd/打包）通过 docker exec 回容器执行。
ORIG_ARGS=("$@")
IN_CONTAINER=0
[ -f /.dockerenv ] && IN_CONTAINER=1
CONTAINER=${LTB_CONTAINER:-oe-lubancat-build}
CTR_WORKDIR=${LTB_CTR_WORKDIR:-/work/src/SBC-sig}
MATRIX=$SBC/boards/matrix.tsv
BUILD_DIR=$SBC/build
DISTRO_TAG=openEuler-24.03-LTS-SP3
# rootfs 的 dnf 源（build.sh 的 -r）。默认值随 DISTRO_TAG 走；
# build.sh 自带的默认是 openEuler-20.03，不覆盖会装到 oe1 的包。
DEFAULT_REPO_FILE="https://raw.atomgit.com/src-openeuler/openEuler-repos/raw/${DISTRO_TAG}/generic.repo"

# ---------- 输出 ----------
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
info() { printf '%s\n' "$*"; }
warn() { printf '%s: WARN: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat <<'EOF'
用法: build-image.sh [选项]

选择（都不给则进交互菜单）:
  --soc <rk356x|rk3576|rk3588>   先按 SoC 家族过滤（rk3566/rk3568→rk356x，rk3588s→rk3588）
  --board <name>                 直接指定板卡，隐含非交互
  --desktop <ukui|none>          桌面（默认 ukui）；none 出无桌面镜像
  --pkglist <file>               直接指定包清单文件（覆盖 --desktop）

构建:
  --stage <all|uboot|kernel|boot|rootfs|image>
                                 跑到哪一步（默认 all）；kernel=只编内核+boot.img
  --uboot-env <host|container>   u-boot 源码编在哪跑（默认 host；容器没有 python2）
  --layout <vendor|gpt>          镜像布局（默认 vendor）
  -n, --name <name>              镜像名（默认自动生成）
  --kernel-branch <branch>       内核分支（默认取 matrix 的 kern_branch）
  --kernel-url <url|path>        内核源码位置（默认自动探测 src/kernel-bsp-6.1）
  --repo-file <url>              rootfs 的 dnf 源（默认 openEuler-24.03-LTS-SP3/generic.repo）
  --jobs <N>                     并行度（默认 nproc）
  --clean <stage|all>            构建前清理（stage=rootfs.img；all=内核/rkpack/param）

其它:
  --list                         列出板卡矩阵后退出
  --format <table|tsv>           --list 的输出格式（默认 table）
  --dry-run                      只打印将执行的命令，不落盘
  -y, --yes                      跳过确认
  --force                        允许构建 status 非 verified/buildable 的板卡
  --noninteractive               禁止交互菜单（CI 里自动生效）
  -V, --verbose                  打印 conf 取值与资产探测结果
  -h, --help                     显示本帮助

示例:
  build-image.sh --list
  build-image.sh --board lubancat-5 --desktop none -y
  build-image.sh --board lubancat-5 --stage image -y
EOF
}

# ---------- 参数 ----------
SOC=""
BOARD=""
DESKTOP=ukui
PKGLIST=""
NAME=""
STAGE=all
UBOOT_ENV=host
LAYOUT=vendor
CLEAN=none
DO_LIST=0
LIST_FMT=table
DRY_RUN=0
ASSUME_YES=0
JOBS=$(nproc 2>/dev/null || echo 4)
FORCE=0
NONINTERACTIVE=0
VERBOSE=0
KERNEL_BRANCH=""
KERNEL_URL=""
REPO_FILE=""

need_arg() { [ "$#" -ge 2 ] || die "选项 $1 需要一个参数"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --soc)            need_arg "$@"; SOC=$2; shift 2 ;;
        --soc=*)          SOC=${1#*=}; shift ;;
        --board)          need_arg "$@"; BOARD=$2; shift 2 ;;
        --board=*)        BOARD=${1#*=}; shift ;;
        --desktop)        need_arg "$@"; DESKTOP=$2; shift 2 ;;
        --desktop=*)      DESKTOP=${1#*=}; shift ;;
        --pkglist)        need_arg "$@"; PKGLIST=$2; shift 2 ;;
        --pkglist=*)      PKGLIST=${1#*=}; shift ;;
        -n|--name)        need_arg "$@"; NAME=$2; shift 2 ;;
        --name=*)         NAME=${1#*=}; shift ;;
        --stage)          need_arg "$@"; STAGE=$2; shift 2 ;;
        --uboot-env)      need_arg "$@"; UBOOT_ENV=$2; shift 2 ;;
        --uboot-env=*)    UBOOT_ENV=${1#*=}; shift ;;
        --stage=*)        STAGE=${1#*=}; shift ;;
        --layout)         need_arg "$@"; LAYOUT=$2; shift 2 ;;
        --layout=*)       LAYOUT=${1#*=}; shift ;;
        --clean)          need_arg "$@"; CLEAN=$2; shift 2 ;;
        --clean=*)        CLEAN=${1#*=}; shift ;;
        --jobs)           need_arg "$@"; JOBS=$2; shift 2 ;;
        --jobs=*)         JOBS=${1#*=}; shift ;;
        --kernel-branch)  need_arg "$@"; KERNEL_BRANCH=$2; shift 2 ;;
        --kernel-url)     need_arg "$@"; KERNEL_URL=$2; shift 2 ;;
        --repo-file)      need_arg "$@"; REPO_FILE=$2; shift 2 ;;
        --list)           DO_LIST=1; shift ;;
        --format)         need_arg "$@"; LIST_FMT=$2; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        --force)          FORCE=1; shift ;;
        --noninteractive) NONINTERACTIVE=1; shift ;;
        -V|--verbose)     VERBOSE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "未知参数: $1（--help 查看用法）" ;;
    esac
done

[ -f "$MATRIX" ] || die "缺少板卡矩阵: $MATRIX"

# 去掉可能的 UTF-8 BOM，后续只读这份副本
MATRIX_DATA=$(mktemp)
trap 'rm -f "$MATRIX_DATA"' EXIT
sed '1s/^\xEF\xBB\xBF//' "$MATRIX" > "$MATRIX_DATA"

# ---------- 工具函数 ----------
normalize_soc() {
    case "$1" in
        rk3566|rk3568|rk356x) printf 'rk356x' ;;
        rk3576)               printf 'rk3576' ;;
        rk3588|rk3588s)       printf 'rk3588' ;;
        *)                    return 1 ;;
    esac
}

board_display() { printf '%s' "$1" | sed 's/^lubancat-/LubanCat-/'; }

# matrix_row <board> → family<TAB>board<TAB>kdef<TAB>branch<TAB>status<TAB>note
matrix_row() {
    awk -F'\t' -v b="$1" '!/^#/ && NF && $2==b {print; found=1; exit} END{exit !found}' "$MATRIX_DATA"
}

matrix_has_board() { matrix_row "$1" >/dev/null 2>&1; }

family_boards() {
    awk -F'\t' -v f="$1" '!/^#/ && NF && $1==f {print $2}' "$MATRIX_DATA"
}

family_count() {
    awk -F'\t' -v f="$1" '!/^#/ && NF && $1==f {c++} END{print c+0}' "$MATRIX_DATA"
}

# 读板卡 conf 里的变量（子 shell，不污染当前环境，不执行 conf 的顶层语句）
# cur_dir / nonfree_bin_dir / workdir / board 是 conf 内部引用的变量，这里 export 供其使用
conf_get() {
    local b=$1 k=$2
    ( set +u
      export cur_dir="$SBC"
      export board="$b"
      export nonfree_bin_dir="$SBC/bin"
      export workdir="$BUILD_DIR"
      # shellcheck disable=SC1090
      source "$SBC/boards/$b.conf" >/dev/null 2>&1 || exit 1
      printf '%s' "${!k-}" )
}

# 询问；超时或 EOF 直接退出（绝不回退默认值，避免 CI 里随机产出镜像）
ask() {
    local prompt=$1 def=${2-} timeout=${LTB_INPUT_TIMEOUT:-120}
    printf '%s' "$prompt"
    if ! IFS= read -r -t "$timeout" REPLY; then
        printf '\n' >&2
        die "输入超时或 EOF（非交互环境请用 --board 指定板卡）"
    fi
    [ -n "$REPLY" ] || REPLY=$def
}

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# ---------- 列表 ----------
print_list() {
    local soc_filter=${1:-}
    if [ "$LIST_FMT" = tsv ]; then
        printf '#family\tboard\tsoc_name\tdtb_name\tboot_size\tkern_defconfig\tstatus\n'
        while IFS=$'\t' read -r family board kdef _ status _; do
            case "$family" in ''|'#'*) continue ;; esac
            [ -z "$soc_filter" ] || [ "$family" = "$soc_filter" ] || continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$family" "$board" "$(conf_get "$board" soc_name)" \
                "$(conf_get "$board" dtb_name)" "$(conf_get "$board" boot_size)" \
                "$kdef" "$status"
        done < "$MATRIX_DATA"
        return 0
    fi

    printf '%-8s %-12s %-10s %-28s %-6s %s\n' FAMILY BOARD SOC_NAME DTB_NAME BOOT STATUS
    printf '%-8s %-12s %-10s %-28s %-6s %s\n' -------- ------------ ---------- ---------------------------- ------ ------
    while IFS=$'\t' read -r family board kdef _ status _; do
        case "$family" in ''|'#'*) continue ;; esac
        [ -z "$soc_filter" ] || [ "$family" = "$soc_filter" ] || continue
        local soc dtb boot
        soc=$(conf_get "$board" soc_name)
        dtb=$(conf_get "$board" dtb_name)
        boot=$(conf_get "$board" boot_size)
        printf '%-8s %-12s %-10s %-28s %-6s %s\n' \
            "$family" "$board" "${soc:--}" "${dtb:--}" "${boot:--}" "$status"
    done < "$MATRIX_DATA"
    info ""
    info "桌面可选: ukui（默认） | none（headless，无 UKUI/lightdm）"
    info "用法示例: $PROG --board lubancat-5 --desktop ukui -y"
}

# ---------- 交互菜单 ----------
pick_soc() {
    local fams=(rk3588 rk3576 rk356x)
    local i n reply
    info ""
    info "[1/3] 选择 SoC 家族:"
    for i in "${!fams[@]}"; do
        n=$(family_count "${fams[$i]}")
        printf '  %d) %-8s (%s 块板)\n' "$((i + 1))" "${fams[$i]}" "$n"
    done
    while :; do
        ask "选择 [1-${#fams[@]}]，默认 1，q 退出: " 1
        reply=$REPLY
        case "$reply" in
            q|Q) die "已取消" ;;
        esac
        if printf '%s' "$reply" | grep -qE '^[0-9]+$' && [ "$reply" -ge 1 ] && [ "$reply" -le "${#fams[@]}" ]; then
            SOC=${fams[$((reply - 1))]}
            return 0
        fi
        warn "无效输入: $reply"
    done
}

pick_board() {
    local boards=() b i reply
    while IFS= read -r b; do
        [ -n "$b" ] && boards+=("$b")
    done < <(family_boards "$SOC")
    [ "${#boards[@]}" -gt 0 ] || die "family $SOC 下没有板卡（检查 $MATRIX）"

    info ""
    info "[2/3] 选择板卡（SoC 家族: $SOC）:"
    for i in "${!boards[@]}"; do
        b=${boards[$i]}
        local row status dtb boot soc
        row=$(matrix_row "$b")
        status=$(printf '%s' "$row" | cut -f5)
        dtb=$(conf_get "$b" dtb_name)
        boot=$(conf_get "$b" boot_size)
        soc=$(conf_get "$b" soc_name)
        printf '  %d) %-12s soc=%-8s dtb=%-28s boot=%-4s [%s]\n' \
            "$((i + 1))" "$(board_display "$b")" "${soc:--}" "${dtb:--}" "${boot:--}" "$status"
    done
    while :; do
        ask "选择 [1-${#boards[@]}]，默认 1，b 返回上一层: " 1
        reply=$REPLY
        case "$reply" in
            b|B) pick_soc; return 0 ;;
            q|Q) die "已取消" ;;
        esac
        if printf '%s' "$reply" | grep -qE '^[0-9]+$' && [ "$reply" -ge 1 ] && [ "$reply" -le "${#boards[@]}" ]; then
            BOARD=${boards[$((reply - 1))]}
            return 0
        fi
        warn "无效输入: $reply"
    done
}

pick_desktop() {
    local reply
    info ""
    info "[3/3] 选择桌面:"
    info "  1) ukui     （桌面，含 UKUI/lightdm/onboard）[默认]"
    info "  2) none     （headless，无桌面）"
    while :; do
        ask "选择 [1-2]，默认 1，b 返回上一层: " 1
        reply=$REPLY
        case "$reply" in
            1|"") DESKTOP=ukui; return 0 ;;
            2)    DESKTOP=none; return 0 ;;
            b|B)  pick_soc; pick_board; pick_desktop; return 0 ;;
            q|Q)  die "已取消" ;;
            *)    warn "无效输入: $reply" ;;
        esac
    done
}

# ---------- 主流程 ----------
if [ -n "$SOC" ]; then
    SOC=$(normalize_soc "$SOC") || die "未知 SoC: ${SOC}（可用: rk356x rk3576 rk3588）"
fi

if [ "$DO_LIST" = 1 ]; then
    print_list "$SOC"
    exit 0
fi

case "$STAGE" in
    all|uboot|kernel|boot|rootfs|image) ;;
    *) die "未知 --stage: $STAGE（可用: all uboot kernel boot rootfs image）" ;;
esac
case "$UBOOT_ENV" in
    host|container) ;;
    *) die "未知 --uboot-env: $UBOOT_ENV（可用: host container）" ;;
esac
case "$LAYOUT" in
    vendor|gpt) ;;
    *) die "未知 --layout: $LAYOUT（可用: vendor gpt）" ;;
esac
case "$CLEAN" in
    none|stage|all) ;;
    *) die "未知 --clean: $CLEAN（可用: stage all）" ;;
esac
case "$LIST_FMT" in
    table|tsv) ;;
    *) die "未知 --format: $LIST_FMT（可用: table tsv）" ;;
esac

# 双模判定：参数优先，其次看是否交互终端
if [ -z "$BOARD" ]; then
    if [ "$NONINTERACTIVE" = 1 ] || [ -n "${CI:-}" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
        print_list "$SOC" >&2
        die "未指定 --board，且当前不是交互终端（CI 环境请显式传 --board）"
    fi
    pick_soc
    pick_board
    pick_desktop
fi

# 板卡合法性
if ! matrix_has_board "$BOARD"; then
    {
        printf '%s: 未知板卡: %s\n' "$PROG" "$BOARD"
        printf '可用板卡:\n'
        awk -F'\t' '!/^#/ && NF {printf "  %-8s %s\n", $1, $2}' "$MATRIX_DATA"
    } >&2
    exit 2
fi

ROW=$(matrix_row "$BOARD")
M_FAMILY=$(printf '%s' "$ROW" | cut -f1)
M_KDEF=$(printf '%s' "$ROW" | cut -f3)
M_BRANCH=$(printf '%s' "$ROW" | cut -f4)
M_STATUS=$(printf '%s' "$ROW" | cut -f5)

if [ -n "$SOC" ] && [ "$SOC" != "$M_FAMILY" ]; then
    die "板卡 $BOARD 属于 $M_FAMILY，与 --soc $SOC 冲突"
fi

if [ "$M_STATUS" != verified ] && [ "$M_STATUS" != buildable ] && [ "$FORCE" = 0 ]; then
    die "板卡 $BOARD 状态为 $M_STATUS（缺: ${M_STATUS#blocked:}）。补齐后用 --force 强制构建"
fi

# 桌面 → 包清单（必须走文件路径分支：headless 关键词在 build_rootfs.sh 里是空操作）
if [ -n "$PKGLIST" ]; then
    SPEC=$PKGLIST
    DESK_TAG=$(basename "$SPEC" | sed 's/^rpmlist-//')
else
    case "$DESKTOP" in
        ukui)
            SPEC=$SBC/configs/common/rpmlist-lubancat-desktop
            DESK_TAG=ukui
            ;;
        none)
            SPEC=$SBC/configs/common/rpmlist-headless
            DESK_TAG=headless
            ;;
        *)
            die "未知 --desktop: $DESKTOP（可用: ukui none）"
            ;;
    esac
fi

# 传给 conf：POST_BOARD_OVERLAY 里桌面 5 段（图形栈/光标/autologin/swcursor/onboard）
# 整段包在 if [ "$lbc_desktop" != none ] 里。驱动类（libmali/NPU/多媒体）不受此开关影响。
export LTB_DESKTOP=$DESKTOP

# 内核分支/源码
[ -n "$KERNEL_BRANCH" ] || KERNEL_BRANCH=$M_BRANCH
if [ -z "$KERNEL_URL" ]; then
    for cand in "$REPO/src/kernel-bsp-6.1" "$REPO/../kernel-bsp-6.1"; do
        [ -d "$cand" ] && { KERNEL_URL=$cand; break; }
    done
fi

[ -n "$REPO_FILE" ] || REPO_FILE=$DEFAULT_REPO_FILE

# 镜像名
if [ -z "$NAME" ]; then
    VER=$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo dev)
    VER=${VER//\//-}
    NAME="$DISTRO_TAG-$(board_display "$BOARD")-aarch64-$DESK_TAG-$VER-$(date +%Y%m%d)"
fi

DTB=$(conf_get "$BOARD" dtb_name)
SOC_NAME=$(conf_get "$BOARD" soc_name)
BOOT_SIZE=$(conf_get "$BOARD" boot_size)
UBOOT_CFG=$(conf_get "$BOARD" ubootconfig)
LOCAL_UBOOT=$(conf_get "$BOARD" local_uboot_dir)

# ---------- 预检 ----------
preflight() {
    local err=0

    [ -f "$SPEC" ] || { warn "包清单不存在: $SPEC"; err=1; }

    if [ -z "$DTB" ]; then warn "conf 里 dtb_name 为空"; err=1; fi
    if [ -z "$SOC_NAME" ]; then warn "conf 里 soc_name 为空"; err=1; fi

    if [ -n "$KERNEL_URL" ] && [ -d "$KERNEL_URL" ]; then
        local uenv="$KERNEL_URL/arch/arm64/boot/dts/rockchip/uEnv/$SOC_NAME"
        [ -d "$uenv" ] || {
            warn "uEnv/$SOC_NAME 不存在（Cat-0/1/2 写 rk356x，Cat-4 写 rk3588）"
            err=1
        }
        [ -f "$KERNEL_URL/arch/arm64/boot/dts/rockchip/$DTB.dts" ] || {
            warn "内核树无 $DTB.dts"
            err=1
        }
        [ -f "$KERNEL_URL/arch/arm64/configs/$M_KDEF" ] || {
            warn "内核树无 $M_KDEF"
            err=1
        }
    elif [ "$DRY_RUN" = 0 ]; then
        warn "未找到内核源码树（--kernel-url 可指定），构建会由 build.sh 自行 clone"
    fi

    if [ "$STAGE" = all ] || [ "$STAGE" = uboot ]; then
        if [ -z "$UBOOT_CFG" ]; then
            [ -s "$SBC/bin/u-boot/$BOARD/u-boot.itb" ] || {
                warn "缺预编译 u-boot: bin/u-boot/$BOARD/u-boot.itb（见 docs/building.md 新增板卡节）"
                err=1
            }
        fi
    fi

    if mount | grep -qE "$BUILD_DIR/(rootfs_tmp|rk_root_tmp|rk_boot_tmp|rkpack)"; then
        warn "检测到 build/ 下有残留挂载，先 umount（否则 gen 会报 source write-protected）"
        err=1
    fi
    if losetup -a 2>/dev/null | grep -qF "$BUILD_DIR/rootfs.img"; then
        warn "rootfs.img 仍被 loop 设备占用，先 losetup -d"
        err=1
    fi

    if [ "$err" = 1 ] && [ "$DRY_RUN" = 0 ]; then
        die "预检未通过，已终止"
    fi
}

if [ "$VERBOSE" = 1 ]; then
    info "-------------------- 构建参数 --------------------"
    info "板卡        : $BOARD ($(board_display "$BOARD"))"
    info "SoC 家族    : $M_FAMILY   conf soc_name: ${SOC_NAME:--}"
    info "dtb         : ${DTB:--}"
    info "boot_size   : ${BOOT_SIZE:--} MiB"
    info "内核 defcfg : $M_KDEF"
    info "内核分支    : $KERNEL_BRANCH"
    info "内核源码    : ${KERNEL_URL:--（由 build.sh 自行 clone）}"
    info "dnf 源      : $REPO_FILE"
    info "u-boot 配置 : ${UBOOT_CFG:-（空=用预编译 $LOCAL_UBOOT）}"
    info "桌面        : $DESKTOP → $SPEC"
    info "布局        : $LAYOUT"
    info "阶段        : $STAGE"
    info "镜像名      : $NAME"
    info "并行度      : $JOBS"
    info "清理        : $CLEAN"
    info "输出目录    : $BUILD_DIR/$(date +%Y-%m-%d)"
    info "--------------------------------------------------"
fi

preflight

# ---------- 断点：.done 不带板卡维度，切换板卡/清单必须清 ----------
if [ "$DRY_RUN" = 0 ] && [ "$STAGE" = all ]; then
    mkdir -p "$BUILD_DIR"
    marker=$BUILD_DIR/.ltb_board
    prev=$(cat "$marker" 2>/dev/null || true)
    cur="$BOARD|$(basename "$SPEC")"   # 只存文件名：宿主与容器的绝对路径不同，存全路径会误判"变了"
    if [ "$prev" != "$cur" ]; then
        info "板卡或包清单变化，清理上次的断点标记"
        rm -f "$BUILD_DIR/.done" "$BUILD_DIR/.param_last" "$BUILD_DIR/boot.img"
    fi
    printf '%s\n' "$cur" > "$marker"

    case "$CLEAN" in
        stage) rm -f "$BUILD_DIR/rootfs.img" ;;
        all)   rm -rf "$BUILD_DIR/kernel" "$BUILD_DIR/rkpack" "$BUILD_DIR/rootfs.img" \
                      "$BUILD_DIR/boot.img" "$BUILD_DIR/.done" "$BUILD_DIR/.param" ;;
        none)  : ;;
    esac
fi

# ---------- 宿主模式：本地编 u-boot，其余阶段回容器 ----------
host_uboot_deps() {
    local miss=0 t
    for t in python2 make gcc dtc bison flex bc cpio; do
        command -v "$t" >/dev/null 2>&1 || { warn "宿主缺 $t（u-boot 源码编需要）"; miss=1; }
    done
    [ -x "$BUILD_DIR/openeuler_gcc_arm64le/bin/aarch64-openeuler-linux-gnu-gcc" ] || {
        warn "缺交叉工具链 $BUILD_DIR/openeuler_gcc_arm64le/bin/（先在建一次容器构建）"; miss=1; }
    [ -x "$REPO/../rkbin/tools/boot_merger" ] || {
        warn "缺 $REPO/../rkbin/tools/boot_merger（boot_merger 打包 loader 用）"; miss=1; }
    return $miss
}

host_uboot_prepare() {
    # scripts/build 及其 log/u-boot 子目录由容器创建，属主多为 root；
    # 宿主需要能删建 build/u-boot 并写 .done，靠容器一次性改归属。
    local b="$BUILD_DIR"
    if [ ! -w "$b" ] || [ ! -w "$b/u-boot" ] || [ ! -w "$b/log" ]; then
        info "修复 build/ 属主（容器内 root → 1000）"
        docker exec "$CONTAINER" bash -c \
            "mkdir -p $CTR_WORKDIR/scripts/build/{log,u-boot} && chown -R 1000:1000 $CTR_WORKDIR/scripts/build/{log,u-boot} $CTR_WORKDIR/scripts/build" \
            || die "无法通过容器修复 build/ 属主"
    fi
}

host_uboot_mark() {
    # .done 由容器维护（root），宿主只读给它看
    local op=$1
    case "$op" in
        clear) docker exec -w "$CTR_WORKDIR" "$CONTAINER" bash -c "sed -i 's/u-boot//g' scripts/build/.done 2>/dev/null || true" ;;
        add)   docker exec -w "$CTR_WORKDIR" "$CONTAINER" bash -c "grep -q '^u-boot$' scripts/build/.done 2>/dev/null || echo u-boot >> scripts/build/.done" ;;
    esac
}

# 断点标记必须在宿主阶段就处理：否则宿主写完 .done 进容器后，
# 容器的「板卡/包清单变化」清理会把 .done 删掉，导致 build.sh 重编 u-boot
# （而容器没有 python2，直接失败）。
host_board_marker_reset() {
    local marker="$BUILD_DIR/.ltb_board" cur prev
    cur="$BOARD|$(basename "$SPEC")"   # 只存文件名：宿主与容器的绝对路径不同，存全路径会误判"变了"
    prev=$(cat "$marker" 2>/dev/null || true)
    [ "$prev" = "$cur" ] && return 0
    info "板卡或包清单变化，清理上次断点（宿主阶段）"
    docker exec -w "$CTR_WORKDIR" "$CONTAINER" bash -c \
        "rm -f scripts/build/.done scripts/build/.param_last scripts/build/boot.img; printf '%s\n' '$cur' > scripts/build/.ltb_board" \
        || die "无法通过容器清理断点"
}

stage_uboot_host() {
    host_uboot_deps || die "宿主依赖不足，或改用 --uboot-env container"
    host_board_marker_reset
    host_uboot_prepare
    host_uboot_mark clear
    LTB_SKIP_DONE_MARK=1 bash "$SBC/build_u-boot.sh" --board "$BOARD" \
        || die "宿主 u-boot 构建失败（详见 $BUILD_DIR/log/）"
    host_uboot_mark add
    info "u-boot 阶段完成（宿主源码编）"
}

reexec_in_container() {
    local args=() a skip=0
    for a in "${ORIG_ARGS[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$a" in
            --uboot-env)   skip=1; continue ;;
            --uboot-env=*) continue ;;
        esac
        args+=("$a")
    done
    info "→ 其余阶段转入容器执行: $CONTAINER:$CTR_WORKDIR"
    exec docker exec -w "$CTR_WORKDIR" "$CONTAINER" tools/build-image.sh "${args[@]}" --uboot-env container
}

# ---------- --stage uboot 且宿主模式：不必走完整确认流程 ----------
if [ "$IN_CONTAINER" = 0 ] && [ "$STAGE" = uboot ] && [ "$UBOOT_ENV" = host ] && [ "$DRY_RUN" = 0 ]; then
    stage_uboot_host
    info ""
    info "完成: u-boot（宿主源码编，产物在 $BUILD_DIR/u-boot/）"
    exit 0
fi

# ---------- 确认 ----------
if [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    info ""
    info "即将构建: $(board_display "$BOARD")  桌面=$DESKTOP  布局=$LAYOUT  阶段=$STAGE"
    info "镜像名  : $NAME"
    ask "回车开始 [Y/n]: " Y
    case "$REPLY" in
        y|Y|yes|YES|"") ;;
        *) die "已取消" ;;
    esac
fi

if [ "$IN_CONTAINER" = 0 ]; then
    case "$STAGE" in
        all)
            if [ "$UBOOT_ENV" = host ]; then
                if [ "$DRY_RUN" = 1 ]; then
                    info "[dry-run] 宿主: bash scripts/build_u-boot.sh --board $BOARD（源码编）"
                    info "[dry-run] 容器: tools/build-image.sh <其余阶段> --uboot-env container"
                    exit 0
                fi
                stage_uboot_host
            fi
            reexec_in_container
            ;;
        uboot)
            if [ "$UBOOT_ENV" = host ]; then
                if [ "$DRY_RUN" = 1 ]; then
                    info "[dry-run] 宿主: bash scripts/build_u-boot.sh --board $BOARD（源码编）"
                    exit 0
                fi
                stage_uboot_host
                info ""
                info "完成: u-boot（宿主源码编，产物在 $BUILD_DIR/u-boot/）"
                exit 0
            fi
            reexec_in_container
            ;;
        *)
            [ "$DRY_RUN" = 1 ] || reexec_in_container
            ;;
    esac
fi

# ---------- 执行 ----------
BUILD_SH_ARGS=(--board "$BOARD" -n "$NAME" -s "$SPEC" --layout "$LAYOUT" --cores "$JOBS")
[ -n "$REPO_FILE" ] && BUILD_SH_ARGS+=(-r "$REPO_FILE")
[ -n "$M_KDEF" ] && BUILD_SH_ARGS+=(-c "$M_KDEF")
[ -n "$KERNEL_BRANCH" ] && BUILD_SH_ARGS+=(-b "$KERNEL_BRANCH")
[ -n "$KERNEL_URL" ] && BUILD_SH_ARGS+=(-k "$KERNEL_URL")

stage_all() {
    run bash "$SBC/build.sh" "${BUILD_SH_ARGS[@]}" || die "build.sh 执行失败（详见上面的日志）"
}

stage_image() {
    [ "$DRY_RUN" = 1 ] || {
        [ -f "$BUILD_DIR/boot.img" ] || die "缺少 $BUILD_DIR/boot.img（先跑 --stage boot）"
        [ -f "$BUILD_DIR/rootfs.img" ] || die "缺少 $BUILD_DIR/rootfs.img（先跑 --stage rootfs）"
        [ -f "$BUILD_DIR/.param" ] || die "缺少 $BUILD_DIR/.param（先跑 --stage all 或 boot）"
        grep -q "^board=$BOARD\$" "$BUILD_DIR/.param" || \
            die "$BUILD_DIR/.param 不是为 $BOARD 生成的（先跑 --stage all）"
    }
    run bash "$SBC/gen_rk_update.sh" -n "$NAME" -b "$BOARD" || die "gen_rk_update.sh 执行失败"
}

stage_sub() {
    local script=$1 name=$2
    [ "$DRY_RUN" = 1 ] || {
        [ -f "$BUILD_DIR/.param" ] || die "缺少 $BUILD_DIR/.param（先跑 --stage all）"
        grep -q "^board=$BOARD\$" "$BUILD_DIR/.param" || \
            die "$BUILD_DIR/.param 不是为 $BOARD 生成的（先跑 --stage all）"
    }
    run bash "$SBC/$script" || die "$name 阶段失败（$script）"
    [ "$DRY_RUN" = 1 ] || info "$name 阶段完成"
}

# 单实例锁（避免两个构建同时踩 build/）
if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$BUILD_DIR"
    exec 200>"$BUILD_DIR/.ltb.lock"
    flock -n 200 || die "已有构建在运行（$BUILD_DIR/.ltb.lock 被占用）"
    # 容器内才要求 root（rootfs/initrd/loop）；宿主模式由 docker exec 进容器执行这些阶段
    [ "$IN_CONTAINER" = 0 ] || [ "$(id -u)" = 0 ] || die "容器内需要 root（chroot / mount / loop）"
fi

case "$STAGE" in
    all)    stage_all ;;
    image)  stage_image ;;
    uboot)  stage_sub build_u-boot.sh u-boot ;;
    boot)   stage_sub build_boot.sh boot ;;
    rootfs) stage_sub build_rootfs.sh rootfs ;;
    kernel) stage_sub build_boot.sh kernel ;;
esac

info ""
info "完成: $NAME"
if [ "$DRY_RUN" = 1 ]; then
    info "（dry-run，未执行任何构建）"
else
    info "产物目录: $BUILD_DIR/$(date +%Y-%m-%d)"
    ls -1 "$BUILD_DIR/$(date +%Y-%m-%d)" 2>/dev/null | sed 's/^/  /' || true
fi
