#!/bin/bash
# 从 pkg/SPECS + pkg/SOURCES 构建本项目需要的 aarch64 rpm，产物落到 scripts/bin/rpms/<soc>/。
#
# 为什么需要这一步：rpm 是构建产物（不入 git），但 conf 在 overlay 阶段会把
#   scripts/bin/rpms/<soc>/*.rpm 预置进 /opt/rpms。新克隆必须能重建它们，
#   否则摄像头 3A 那一节会静默跳过（conf 里带 ls 存在性判断）。
#
# 用法：
#   tools/build-rpms.sh              # 构建全部 spec
#   tools/build-rpms.sh --list       # 只列出将要构建什么
#   tools/build-rpms.sh camera-engine-rkaiq-rk3576   # 只构建指定包
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SBC=$REPO/scripts
CONTAINER=${LTB_CONTAINER:-oe-lubancat-build}
# 容器内把工作区挂成 /work；本脚本要求在构建工作区里跑（否则路径对不上）
WS=${LTB_WORKSPACE:-/home/dev/ljh/lubancat-openeuler/src/SBC-sig}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# spec 名 → SoC 目录（命名约定：带 -rkXXXX 后缀的进对应目录，其余是 rk3588）
spec_soc() {
    case "$1" in
        *-rk3576) echo rk3576 ;;
        *-rk356x) echo rk356x ;;
        *)        echo rk3588 ;;
    esac
}

mapfile -t SPECS < <(ls "$REPO"/pkg/SPECS/*.spec 2>/dev/null | sort)
[ "${#SPECS[@]}" -gt 0 ] || die "pkg/SPECS 下没有 spec"

if [ "${1:-}" = "--list" ]; then
    for s in "${SPECS[@]}"; do
        printf '%-45s -> scripts/bin/rpms/%s/\n' "$(basename "$s")" "$(spec_soc "$(basename "$s" .spec)")"
    done
    exit 0
fi

want=()
for s in "${SPECS[@]}"; do
    name=$(basename "$s" .spec)
    if [ "$#" -gt 0 ] && [ "${1:-}" != "$name" ]; then
        continue
    fi
    want+=("$s")
done
[ "${#want[@]}" -gt 0 ] || die "没有匹配的 spec"

command -v docker >/dev/null 2>&1 || die "需要 docker（rpmbuild 在容器 $CONTAINER 内执行）"
[ "$REPO" = "$WS" ] || die "请在构建工作区运行：$WS/tools/build-rpms.sh（当前 $REPO）"

for s in "${want[@]}"; do
    base=$(basename "$s" .spec)
    soc=$(spec_soc "$base")
    printf '\n=== %s -> bin/rpms/%s/ ===\n' "$base" "$soc"
    docker exec -w /work/src/SBC-sig "$CONTAINER" bash -c "
        set -e
        rpmbuild -bb pkg/SPECS/${base}.spec \
            --rcfile /work/src/SBC-sig/pkg/rpmrc-aarch64 \
            --define '_sourcedir /work/src/SBC-sig/pkg/SOURCES' \
            --define '_rpmdir /work/src/SBC-sig/pkg/rpmbuild/RPMS' \
            --define '_builddir /work/src/SBC-sig/pkg/rpmbuild/BUILD' \
            --target aarch64 2>&1 | tail -2
    "
    rpm=$(docker exec "$CONTAINER" bash -c "find /work/src/SBC-sig/pkg/rpmbuild/RPMS -name '${base}-*.rpm' | sort | tail -1")
    [ -n "$rpm" ] || die "$base 构建后没找到产物"
    mkdir -p "$SBC/bin/rpms/$soc"
    docker cp "$CONTAINER:$rpm" "$SBC/bin/rpms/$soc/"
    echo "installed: scripts/bin/rpms/$soc/$(basename "$rpm")"
done

echo
echo "=== 结果 ==="
find "$SBC/bin/rpms" -name '*.rpm' -printf '%10s  %P\n' | sort -k2
