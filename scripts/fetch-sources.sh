#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# fetch-sources.sh —— 按 manifests/source-lock.yaml 拉取构建所需的源码仓。
#
# 用法：
#   ./scripts/fetch-sources.sh           # 拉取（幂等，已在目标 SHA 则跳过）
#   ./scripts/fetch-sources.sh --check   # 只校验，不拉取
#   ./scripts/fetch-sources.sh --unshallow  # 强制完整历史（需要 git blame 时）
#
# 设计要点：
#   * 不依赖 yq，直接用 awk 解析 source-lock.yaml 的 repos 段
#   * 按 commit 拉取失败时依次降级：按 SHA fetch -> 按分支 shallow -> unshallow
#   * 源码仓不进 git（见 .gitignore 的 /src/），本脚本负责重建

set -e

cur_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${cur_dir}/.." && pwd)
lock="${repo_root}/manifests/source-lock.yaml"
src_dir="${repo_root}/src"

CHECK_ONLY=0
UNSHALLOW=0
for arg in "$@"; do
    case "$arg" in
        --check)      CHECK_ONLY=1 ;;
        --unshallow)  UNSHALLOW=1 ;;
        -h|--help)    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

[ -f "$lock" ] || { echo "ERROR: $lock 不存在" >&2; exit 1; }
mkdir -p "$src_dir"

# 解析 lock：输出 "name<TAB>url<TAB>commit" 每行一条
parse_lock() {
    awk '
        /^repos:/            { in_repos = 1; next }
        in_repos && /^[^ -]/ { in_repos = 0 }
        !in_repos            { next }
        /^[[:space:]]*-[[:space:]]*name:/ {
            if (name != "") printf "%s\t%s\t%s\n", name, url, commit
            name = $0; sub(/.*name:[[:space:]]*/, "", name); gsub(/"/, "", name)
            url = ""; commit = ""; next
        }
        /^[[:space:]]*url:/    { url    = $0; sub(/.*url:[[:space:]]*/, "", url);    gsub(/"/, "", url) }
        /^[[:space:]]*commit:/ { commit = $0; sub(/.*commit:[[:space:]]*/, "", commit); gsub(/"/, "", commit) }
        END { if (name != "") printf "%s\t%s\t%s\n", name, url, commit }
    ' "$lock"
}

# 取全局 clone_depth（缺省 1）
depth=$(awk '/^clone_depth:/ { print $2; exit }' "$lock")
[ -n "$depth" ] || depth=1
[ "$UNSHALLOW" = "1" ] && depth=0

fail=0
parse_lock | while IFS=$'\t' read -r name url commit; do
    [ -n "$name" ] || continue
    dest="${src_dir}/${name}"

    if [ -d "${dest}/.git" ]; then
        have=$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo none)
        if [ "$have" = "$commit" ]; then
            echo "OK      ${name} @ ${commit:0:10}"
            continue
        fi
    else
        have=none
    fi

    if [ "$CHECK_ONLY" = "1" ]; then
        echo "MISMATCH ${name}: want ${commit:0:10}, have ${have:0:10}"
        fail=1
        continue
    fi

    echo "FETCH   ${name} -> ${commit:0:10}"
    if [ ! -d "${dest}/.git" ]; then
        rm -rf "$dest"
        git init -q "$dest"
        git -C "$dest" remote add origin "$url"
    fi

    # 阶梯 1：按 SHA 浅取（服务器允许 allowReachableSHA1InWant 时最快）
    ok=0
    if [ "$depth" != "0" ]; then
        git -C "$dest" fetch -q --depth "$depth" origin "$commit" 2>/dev/null && ok=1
        # 阶梯 2：按默认分支浅取后 checkout
        if [ "$ok" = "0" ]; then
            git -C "$dest" fetch -q --depth "$depth" origin 2>/dev/null || true
            git -C "$dest" fetch -q --depth "$depth" origin HEAD 2>/dev/null || true
        fi
    else
        git -C "$dest" fetch -q origin 2>/dev/null || true
    fi

    if ! git -C "$dest" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        echo "        浅取未命中，退化为完整 fetch" >&2
        git -C "$dest" fetch -q --unshallow origin 2>/dev/null || git -C "$dest" fetch -q origin 2>/dev/null || true
    fi

    if git -C "$dest" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        git -C "$dest" checkout -q --detach "$commit"
        echo "        done @ $(git -C "$dest" rev-parse --short HEAD)"
    else
        echo "ERROR   ${name}: 无法获取 ${commit}" >&2
        echo "        请检查网络，或手动：git clone ${url} ${dest} && git -C ${dest} checkout ${commit}" >&2
        fail=1
    fi
done

if [ "$CHECK_ONLY" = "0" ]; then
    echo
    echo "源码就绪：${src_dir}"
    echo "下一步：sudo ./scripts/build.sh -b lubancat-5 -s \"\$PWD/scripts/configs/common/rpmlist-lubancat-desktop\""
fi

exit "$fail"
