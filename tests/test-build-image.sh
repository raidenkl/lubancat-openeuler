#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# tests/test-build-image.sh —— 校验构建矩阵与入口脚本的静态一致性。
#
# 可在没有内核/u-boot 源码树的 CI 环境运行：缺源码时相关断言自动降级为 skip。
# 用法：bash tests/test-build-image.sh [-q]
set -u

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SBC="$REPO/scripts"
MATRIX="$SBC/boards/matrix.tsv"
TOOL="$REPO/tools/build-image.sh"

# 内核源码树可能有两种布局：仓库内 src/，或工作区里与 SBC-sig 平级
KSRC=""
for cand in "$REPO/src/kernel-bsp-6.1" "$REPO/../kernel-bsp-6.1"; do
    [ -d "$cand" ] && { KSRC="$cand"; break; }
done

pass=0
fail=0
skipped=0

ok()   { pass=$((pass + 1)); [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { skipped=$((skipped + 1)); [ "$QUIET" = 1 ] || printf '  skip  %s\n' "$1"; }
hdr()  { [ "$QUIET" = 1 ] || printf '\n== %s ==\n' "$1"; }

hdr "matrix.tsv 结构"

if [ ! -f "$MATRIX" ]; then
    bad "缺少 $MATRIX"
    printf '\n结果: %d 通过, %d 失败, %d 跳过\n' "$pass" "$fail" "$skipped"
    exit 1
fi
ok "matrix.tsv 存在"

# 去掉可能的 UTF-8 BOM（Windows 编辑器保存后常见），其余断言只看清理后的副本
CLEAN=$(mktemp)
trap 'rm -f "$CLEAN"' EXIT
sed '1s/^\xEF\xBB\xBF//' "$MATRIX" > "$CLEAN"

# 列数必须为 6（注释行与空行除外）
bad_lines=$(awk -F'\t' '!/^#/ && NF && NF != 6 { printf "%d(%d列) ", NR, NF }' "$CLEAN")
if [ -z "$bad_lines" ]; then
    ok "每行 6 列"
else
    bad "列数不对的行: $bad_lines"
fi

# family 取值
bad_family=$(awk -F'\t' '!/^#/ && NF && $1 !~ /^(rk356x|rk3576|rk3588)$/ { printf "%d:%s ", NR, $1 }' "$CLEAN")
if [ -z "$bad_family" ]; then
    ok "family 取值合法"
else
    bad "非法 family: $bad_family"
fi

# status 取值
bad_status=$(awk -F'\t' '!/^#/ && NF && $5 !~ /^(verified|buildable|blocked(:[a-z,]+)?)$/ { printf "%d:%s ", NR, $5 }' "$CLEAN")
if [ -z "$bad_status" ]; then
    ok "status 取值合法"
else
    bad "非法 status: $bad_status"
fi

# board 唯一
dup=$(awk -F'\t' '!/^#/ && NF { c[$2]++ } END { for (b in c) if (c[b] > 1) printf "%s(x%d) ", b, c[b] }' "$CLEAN")
if [ -z "$dup" ]; then
    ok "board 不重复"
else
    bad "重复 board: $dup"
fi

# 家族分组数量（3 个家族、6 块板）
fam_n=$(awk -F'\t' '!/^#/ && NF { print $1 }' "$CLEAN" | sort -u | wc -l | tr -d ' ')
brd_n=$(awk -F'\t' '!/^#/ && NF { print $2 }' "$CLEAN" | sort -u | wc -l | tr -d ' ')
if [ "$fam_n" -eq 3 ] && [ "$brd_n" -eq 6 ]; then
    ok "3 个 family / 6 块板"
else
    bad "期望 3 family / 6 board，实际 $fam_n / $brd_n"
fi

hdr "板卡配置可达性"

while IFS=$'\t' read -r family board kdef _ status _; do
    case "$family" in ''|'#'*) continue ;; esac
    [ -n "${board:-}" ] || continue

    conf="$SBC/boards/$board.conf"
    if [ -f "$conf" ]; then
        ok "$board: boards/$board.conf 存在"
    else
        case "${status:-}" in
            blocked:*conf*) skip "$board: conf 未创建（status=${status}）" ;;
            *)              bad  "$board: 缺 boards/$board.conf 但 status=${status}" ;;
        esac
    fi

    if [ -n "$KSRC" ] && [ -d "$KSRC" ]; then
        if [ -f "$KSRC/arch/arm64/configs/$kdef" ]; then
            ok "$board: 内核 $kdef 存在"
        else
            bad "$board: 内核树无 $kdef"
        fi
    else
        skip "$board: 内核树未检出，跳过 $kdef"
    fi
done < "$CLEAN"

hdr "入口脚本"

if [ -f "$TOOL" ]; then
    if bash -n "$TOOL" 2>/dev/null; then
        ok "tools/build-image.sh 语法通过"
    else
        bad "tools/build-image.sh 语法错误"
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck -S warning "$TOOL" >/dev/null 2>&1; then
            ok "shellcheck -S warning 通过"
        else
            bad "shellcheck 有警告（-S warning）"
        fi
    else
        skip "未安装 shellcheck"
    fi

    list_out=$("$TOOL" --list 2>/dev/null)
    if [ -z "$list_out" ]; then
        bad "--list 无输出"
    else
        miss=""
        for b in lubancat-0 lubancat-1 lubancat-2 lubancat-3 lubancat-4 lubancat-5; do
            printf '%s' "$list_out" | grep -q "$b" || miss="$miss $b"
        done
        if [ -z "$miss" ]; then
            ok "--list 覆盖全部 6 块板"
        else
            bad "--list 缺少:$miss"
        fi
    fi
else
    skip "tools/build-image.sh 尚未实现"
fi

printf '\n结果: %d 通过, %d 失败, %d 跳过\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
