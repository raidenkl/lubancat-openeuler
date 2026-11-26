#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# init-env.sh —— 编译环境初始化（幂等，可重复执行）
#
# 做四件事：
#   1) 体检宿主：OS/架构/内存/磁盘、构建依赖、docker 与 aarch64 binfmt
#   2) 准备基础镜像：docker pull openEuler 24.03 SP3 (linux/arm64) 并验证 uname -m
#   3) 准备构建容器：创建/复用 oe-lubancat-build（本仓库同路径挂到容器）
#   4) 拉源码：调用 scripts/fetch-sources.sh，按 manifests/source-lock.yaml 锁版
#
# 用法：
#   ./scripts/init-env.sh                  # 体检 + 拉镜像 + 建容器 + 拉源码（推荐）
#   ./scripts/init-env.sh --check          # 只体检，不改任何东西
#   ./scripts/init-env.sh --skip-fetch     # 不拉源码（已拉过）
#   ./scripts/init-env.sh --skip-docker    # 不碰容器（离线/已有环境）
#   ./scripts/init-env.sh --recreate       # 删掉同名容器重建（挂载点变了时用）
#   ./scripts/init-env.sh --install-deps   # 缺失的 apt 包直接装（会调 sudo）
#   ./scripts/init-env.sh --fix-perms      # 只修 scripts/build 的属主（宿主编 u-boot 报不可写时用）
#
# 设计取舍：
#   * 默认不 sudo、不改 /etc/docker/daemon.json —— 只报告缺什么，装不装由用户决定
#   * 容器用「常驻 + docker exec」而不是 docker run --rm：build-image.sh 会分阶段复用
#   * 源码不进 git（见 .gitignore 的 /src/），由 fetch-sources.sh 重建

set -u

PROG=$(basename "$0")
SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO=$(cd "$(dirname "$SELF")/.." && pwd)

CONTAINER=${LTB_CONTAINER:-oe-lubancat-build}
IMAGE=${LTB_IMAGE:-openeuler/openeuler:24.03-lts-sp3}
MIN_DISK_G=120
CTR_LEGACY_DST=/work/src/SBC-sig

MODE=all
DO_FETCH=1
DO_DOCKER=1
INSTALL_DEPS=0
RECREATE=0
FIX_PERMS_ONLY=0

OK=0; WARN=0; BAD=0
ok()   { OK=$((OK+1));   printf '  \033[32mOK\033[0m   %-42s %s\n' "$1" "${2:-}"; }
warn() { WARN=$((WARN+1)); printf '  \033[33mWARN\033[0m %-42s %s\n' "$1" "${2:-}"; }
bad()  { BAD=$((BAD+1));  printf '  \033[31mFAIL\033[0m %-42s %s\n' "$1" "${2:-}"; }
info() { printf '  ---- %-42s %s\n' "$1" "${2:-}"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

usage() { sed -n '5,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check)         MODE=check ;;
        --skip-fetch)    DO_FETCH=0 ;;
        --skip-docker)   DO_DOCKER=0 ;;
        --install-deps)  INSTALL_DEPS=1 ;;
        --recreate)      RECREATE=1 ;;
        --fix-perms)     FIX_PERMS_ONLY=1 ;;
        -h|--help)       usage ;;
        *) echo "未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- 0. 基本信息
section "0. 环境概况"
info "仓库"     "$REPO"
info "容器"     "$CONTAINER（镜像 $IMAGE）"
[ "$(id -u)" -eq 0 ] && bad "不要用 root 运行" "镜像会写进仓库目录，属主会变成 root" \
                     || ok "运行身份" "$(id -un) (uid=$(id -u))"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    info "宿主系统" "${PRETTY_NAME:-unknown}"
fi
info "架构/内核" "$(uname -m) / $(uname -r)"
info "CPU / 内存" "$(nproc) vCPU / $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo) GiB"

AVAIL_G=$(df -BG --output=avail "$REPO" 2>/dev/null | tail -1 | tr -dc '0-9')
AVAIL_G=${AVAIL_G:-0}
if [ "$AVAIL_G" -ge "$MIN_DISK_G" ]; then
    ok "可用磁盘" "${AVAIL_G} GiB（≥ ${MIN_DISK_G} GiB）"
else
    warn "可用磁盘" "${AVAIL_G} GiB < ${MIN_DISK_G} GiB；单次全量构建约 30–40 GiB"
fi

# ---------------------------------------------------------------- 1. 宿主依赖
section "1. 宿主依赖"

# 硬依赖：缺了连源码都拉不下来
HARD_PROGS="git curl awk sed tar gzip sha256sum realpath"
# 宿主侧 u-boot 源码编（--uboot-env host，默认路径）
UBOOT_PROGS="python2 make gcc bc bison flex dtc cpio"
# 打包/镜像阶段在容器里用，宿主缺了通常不影响；列出来只为排障
OPT_PROGS="rsync xz pigz parted sfdisk kpartx mtools mkimage losetup"

missing_hard=""; missing_uboot=""; missing_opt=""
for t in $HARD_PROGS;  do command -v "$t" >/dev/null 2>&1 || missing_hard="$missing_hard $t"; done
for t in $UBOOT_PROGS; do command -v "$t" >/dev/null 2>&1 || missing_uboot="$missing_uboot $t"; done
for t in $OPT_PROGS;   do command -v "$t" >/dev/null 2>&1 || missing_opt="$missing_opt $t"; done

# 程序名 -> apt 包名（只映射不一致的）
apt_pkg() {
    case "$1" in
        sha256sum|realpath) echo coreutils ;;
        losetup|sfdisk)     echo util-linux ;;
        dtc)      echo device-tree-compiler ;;
        mkimage)  echo u-boot-tools ;;
        mkfs.vfat) echo dosfstools ;;
        *)        echo "$1" ;;
    esac
}

if [ -z "$missing_hard" ]; then
    ok "硬依赖" "齐全（$HARD_PROGS）"
else
    bad "硬依赖缺失" "$missing_hard"
fi

if [ -z "$missing_uboot" ]; then
    ok "宿主 u-boot 编译依赖" "齐全（$UBOOT_PROGS）"
else
    # python2 缺失不算致命：--uboot-env container 或预编译 u-boot 都能绕开
    warn "宿主 u-boot 编译依赖缺失" "$missing_uboot"
    info "影响" "只有 --uboot-env host（默认）编 u-boot 时需要；可用预编译 u-boot 绕过"
fi

if [ -n "$missing_opt" ]; then
    info "可选工具缺失" "$missing_opt（打包阶段在容器内完成，一般不影响）"
fi

# 汇总需要 apt 装的包（去重）
need_pkgs=""
for t in $missing_hard $missing_uboot; do
    need_pkgs="$need_pkgs $(apt_pkg "$t")"
done
need_pkgs=$(printf '%s\n' $need_pkgs | sort -u | tr '\n' ' ')

if [ -n "${need_pkgs// /}" ]; then
    info "建议安装命令" "sudo apt-get install -y $need_pkgs"
    if [ "$INSTALL_DEPS" = 1 ]; then
        section "1b. 安装缺失依赖（--install-deps）"
        if [ "$(id -u)" -eq 0 ]; then
            # shellcheck disable=SC2086
            apt-get update && apt-get install -y $need_pkgs || { bad "apt 安装失败" "请手动安装"; }
        else
            # shellcheck disable=SC2086
            sudo apt-get update && sudo apt-get install -y $need_pkgs || { bad "apt 安装失败" "请手动安装"; }
        fi
        # 重新检查
        still=""
        for t in $missing_hard $missing_uboot; do command -v "$t" >/dev/null 2>&1 || still="$still $t"; done
        if [ -z "$still" ]; then ok "补装后复查" "全部就位"; missing_hard=""; missing_uboot=""
        else warn "补装后仍缺" "$still"; fi
    fi
fi

# ---------------------------------------------------------------- 2. docker / binfmt
section "2. docker 与 aarch64 binfmt"

DOCKER_OK=0
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        DOCKER_OK=1
        ok "docker 可用" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    else
        if [ "$(id -u)" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qx docker; then
            bad "docker 无权限" "当前用户不在 docker 组：sudo usermod -aG docker $(id -un)（重新登录生效）"
        else
            bad "docker 不可用" "docker info 失败，检查 dockerd 是否在跑"
        fi
    fi
else
    bad "未安装 docker" "见 https://docs.docker.com/engine/install/"
fi

BINFMT_OK=0
if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && \
   grep -qx enabled /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
    BINFMT_OK=1
    ok "aarch64 binfmt" "$(grep -m1 interpreter /proc/sys/fs/binfmt_misc/qemu-aarch64 | sed 's/interpreter //')"
else
    bad "aarch64 binfmt 未注册" "x86_64 宿主必须能直接跑 arm64 二进制"
    info "修复（二选一）" "sudo apt-get install -y qemu-user-static binfmt-support"
    info "" "docker run --privileged --rm tonistiigi/binfmt --install arm64"
fi

# ---------------------------------------------------------------- 3. 基础镜像
if [ "$DO_DOCKER" = 1 ] && [ "$MODE" = all ]; then
    section "3. 基础镜像 $IMAGE"
    if [ "$DOCKER_OK" = 1 ]; then
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            ok "镜像已存在" "跳过拉取"
        else
            info "拉取中" "linux/arm64（约 200 MB，无镜像加速时较慢）"
            if docker pull --platform linux/arm64 "$IMAGE" >/dev/null 2>&1; then
                ok "拉取完成" "$IMAGE"
            else
                bad "拉取失败" "检查网络；必要时配镜像加速或离线 docker load"
            fi
        fi
        arch=$(docker image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null)
        [ "$arch" = "arm64" ] && ok "镜像架构" "arm64" || bad "镜像架构不是 arm64" "${arch:-unknown}"
    else
        warn "跳过镜像拉取" "docker 不可用"
    fi
fi

# ---------------------------------------------------------------- 4. 构建容器
if [ "$DO_DOCKER" = 1 ] && [ "$MODE" = all ] && [ "$DOCKER_OK" = 1 ] && [ "$BINFMT_OK" = 1 ]; then
    section "4. 构建容器 $CONTAINER"
    existing=0
    docker container inspect "$CONTAINER" >/dev/null 2>&1 && existing=1

    if [ "$existing" = 1 ] && [ "$RECREATE" = 1 ]; then
        info "重建" "删除同名容器"
        docker rm -f "$CONTAINER" >/dev/null 2>&1
        existing=0
    fi

    # 容器里本仓库的落点：优先「同路径挂载」（克隆到任意目录都成立），
    # 老工作区那种「父目录挂到 /work、仓库在 /work/src/SBC-sig」也认
    ctr_repo() {
        docker inspect "$CONTAINER" \
            --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null \
          | awk -F'|' -v s="$REPO" '$1==s {print $2; exit}'
    }

    if [ "$existing" = 1 ]; then
        cdst=$(ctr_repo)
        if [ -n "$cdst" ]; then
            ok "容器已存在，仓库挂载点" "$cdst"
        elif docker inspect "$CONTAINER" --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null | grep -q "$CTR_LEGACY_DST"; then
            ok "容器已存在（老布局）" "仓库在 $CTR_LEGACY_DST"
            info "说明" "build-image.sh 会按挂载表自动识别，不用改"
        else
            bad "容器没挂载本仓库" "期望挂载 $REPO"
            info "处理" "$PROG --recreate（会删掉旧容器）"
        fi
        st=$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null)
        if [ "$st" != "true" ]; then
            docker start "$CONTAINER" >/dev/null 2>&1 && ok "容器已启动" "$CONTAINER" \
                                                        || bad "容器启动失败" "$CONTAINER"
        fi
    else
        info "创建" "-v $REPO:$REPO -w $REPO --privileged --platform linux/arm64"
        if docker run -d --name "$CONTAINER" --platform linux/arm64 --privileged \
                -v "$REPO:$REPO" -w "$REPO" "$IMAGE" sleep infinity >/dev/null 2>&1; then
            ok "容器已创建并常驻" "$CONTAINER"
        else
            bad "容器创建失败" "看 docker logs / docker run 手工重试"
        fi
    fi

    # 容器内跑一次 arm64 二进制，确认 binfmt 真的生效
    m=$(docker exec "$CONTAINER" uname -m 2>/dev/null)
    [ "$m" = "aarch64" ] && ok "容器内架构" "aarch64" || bad "容器内 uname -m" "${m:-无输出}"
fi

# ---------------------------------------------------------------- 5. 目录与属主
section "5. 构建目录"
if [ "$MODE" = all ]; then
    mkdir -p "$REPO/scripts/build/log" "$REPO/scripts/build/u-boot"
    ok "scripts/build/{log,u-boot}" "已就绪"
else
    [ -d "$REPO/scripts/build" ] && ok "scripts/build 存在" "" || info "scripts/build 尚未创建" "首次构建时生成"
fi

# 容器内 root 写过的目录，宿主编 u-boot 时会不可写（build_u-boot.sh 会直接报错）
if [ "$DO_DOCKER" = 1 ] && [ "$DOCKER_OK" = 1 ] && [ "$(id -u)" -ne 0 ]; then
    for d in log u-boot; do
        if [ -e "$REPO/scripts/build/$d" ] && [ ! -w "$REPO/scripts/build/$d" ]; then
            cbase=$(ctr_repo 2>/dev/null); cbase=${cbase:-$CTR_LEGACY_DST}
            docker exec "$CONTAINER" chown -R "$(id -u):$(id -g)" "$cbase/scripts/build/$d" 2>/dev/null \
                && ok "修正属主 scripts/build/$d" "$(id -un)" \
                || warn "属主修正失败" "scripts/build/$d（宿主编 u-boot 会报不可写）"
        fi
    done
fi

# ---------------------------------------------------------------- 6. 源码
if [ "$DO_FETCH" = 1 ] && [ "$MODE" = all ]; then
    section "6. 源码（manifests/source-lock.yaml）"
    if [ -x "$REPO/scripts/fetch-sources.sh" ]; then
        if bash "$REPO/scripts/fetch-sources.sh"; then
            ok "源码就绪" "$REPO/src"
        else
            bad "源码拉取失败" "可重跑本脚本；或 ./scripts/fetch-sources.sh 单独排查"
        fi
    else
        bad "缺少 scripts/fetch-sources.sh" "仓库不完整"
    fi
fi

# ---------------------------------------------------------------- 汇总
section "汇总"
printf '  OK=%d  WARN=%d  FAIL=%d\n' "$OK" "$WARN" "$BAD"

if [ "$MODE" = check ] || [ "$FIX_PERMS_ONLY" = 1 ]; then
    [ "$BAD" -eq 0 ] && echo "体检通过（未做任何修改）" || echo "体检未通过，见上方 FAIL"
    exit $([ "$BAD" -eq 0 ] && echo 0 || echo 1)
fi

if [ "$BAD" -gt 0 ]; then
    echo "初始化未完成：先处理上面的 FAIL 项再重跑本脚本"
    exit 1
fi

cat <<EOF

环境就绪。下一步：

  tools/build-image.sh --list                      # 看板卡矩阵与状态
  tools/build-image.sh --board lubancat-3 --desktop ukui -y
  tools/build-image.sh --board lubancat-3 --desktop ukui --dry-run -V   # 只打印将执行的命令

产物在 scripts/build/<日期>/ 下，.img.xz 用 RKDevTool / upgrade_tool 烧写。
EOF
exit 0
