#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# check_kernel_rpm.sh —— 内核 rpm 的离线验收（在构建容器内跑，不需要板子）
#
# 验的是"装上去会怎样"，而不是"包能打出来"：
#   1) 载荷清单：该有的都在，不该有的（boot.cmd/boot.scr/rk-kernel.dtb/uEnv.txt）一个都没有
#   2) 依赖：kernel-lubancat 精确 Requires 同版本 modules
#   3) 负向：/boot 没挂载时 %pre 必须拒绝安装（最常见的"装了没生效"）
#   4) 正向：把 boot.img loop 挂成 /boot，在 rootfs 的 overlay 副本上真装一次，
#      校验 Image/initrd 落地、uname_r 改写、uEnv.txt 仍是软链、旧版本按策略清理
#
# 用法：build/check_kernel_rpm.sh [--rpm-dir DIR] [--rootfs IMG] [--bootimg IMG]
# 默认：--rpm-dir scripts/bin/rpms/<soc>（用 --soc 选，默认 rk3588）
#
set -u

PROG=$(basename "$0")
REPO=$(cd "$(dirname "$0")/.." && pwd)
workdir=${workdir:-$REPO/scripts/build}

soc=rk3588
rpm_dir=""
rootfs_img=""
boot_img=""

while [ $# -gt 0 ]; do
    case "$1" in
        --soc)      soc=$2; shift 2 ;;
        --rpm-dir)  rpm_dir=$2; shift 2 ;;
        --rootfs)   rootfs_img=$2; shift 2 ;;
        --bootimg)  boot_img=$2; shift 2 ;;
        -h|--help)  sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "$PROG: 未知参数 $1" >&2; exit 2 ;;
    esac
done

rpm_dir=${rpm_dir:-$REPO/scripts/bin/rpms/$soc}
rootfs_img=${rootfs_img:-$workdir/rkpack/Image/rootfs.img}
[ -f "$rootfs_img" ] || rootfs_img=$workdir/rootfs.img
boot_img=${boot_img:-$workdir/boot.img}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s  【%s】\n' "$1" "${2:-}"; }
info() { printf '        %s\n' "$1"; }

IMG_RPM=$(ls -1 "$rpm_dir"/kernel-lubancat-[0-9]*.rpm 2>/dev/null | head -1)
MOD_RPM=$(ls -1 "$rpm_dir"/kernel-lubancat-modules-*.rpm 2>/dev/null | head -1)
[ -n "$IMG_RPM" ] || { echo "ERROR: 找不到 kernel-lubancat-*.rpm（$rpm_dir）" >&2; exit 2; }
[ -n "$MOD_RPM" ] || { echo "ERROR: 找不到 kernel-lubancat-modules-*.rpm（$rpm_dir）" >&2; exit 2; }

kver=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$IMG_RPM" 2>/dev/null)
# VERSION=6.1.99 RELEASE=1.lbc5.rk3588 -> 真实 kernelrelease 是 6.1.99-rk3588
kver=$(echo "$kver" | sed -E 's/^([0-9.]+)-[0-9.]+\.lbc[0-9]+\.(.+)$/\1-\2/')

echo "== 内核 rpm 离线验收 =="
echo "  image   : $IMG_RPM"
echo "  modules : $MOD_RPM"
echo "  kver    : $kver"
echo "  rootfs  : $rootfs_img"
echo "  bootimg : $boot_img"
echo

# ---------------- 1. 载荷清单 ----------------
echo "[1] 载荷清单"
list_img=$(rpm -qp --qf '[%{FILENAMES}\n]' "$IMG_RPM" 2>/dev/null)
list_mod=$(rpm -qp --qf '[%{FILENAMES}\n]' "$MOD_RPM" 2>/dev/null)

for f in "/boot/Image-$kver" "/boot/System.map-$kver" "/boot/config-$kver" "/boot/initrd-$kver"; do
    echo "$list_img" | grep -qx "$f" && ok "含 $f" || bad "缺 $f"
done
n_dtb=$(echo "$list_img"  | grep -c '^/boot/dtb/[^/]*\.dtb$')
n_dtbo=$(echo "$list_img" | grep -c '^/boot/dtb/overlay/.*\.dtbo$')
n_uenv=$(echo "$list_img" | grep -c '^/boot/uEnv/.*\.txt$')
[ "$n_dtb"  -ge 5 ] && ok "dtb 数量 $n_dtb" || bad "dtb 数量过少" "$n_dtb"
[ "$n_dtbo" -ge 100 ] && ok "dtbo 数量 $n_dtbo" || bad "dtbo 数量过少" "$n_dtbo"
# 方案 A：uEnv 不进载荷（它带构建期占位 root=UUID，装机覆盖会卡启动）
[ "$n_uenv" -eq 0 ] && ok "不含任何 uEnv（uEnv 归镜像管）" || bad "载荷里混进了 uEnv" "$n_uenv 个"

# 不该出现的：会破坏启动链 / 破坏板型软链
for f in "/boot/boot.cmd" "/boot/boot.scr" "/boot/rk-kernel.dtb" "/boot/uEnv/uEnv.txt"; do
    echo "$list_img" | grep -qx "$f" && bad "不该包含 $f" || ok "不含 $f"
done

echo "$list_mod" | grep -qx "/lib/modules/$kver" && ok "含 /lib/modules/$kver" || bad "缺 /lib/modules/$kver"
n_ko=$(rpm2cpio "$MOD_RPM" | cpio -t 2>/dev/null | grep -c '\.ko')
[ "$n_ko" -ge 50 ] && ok "模块文件 $n_ko 个" || bad "模块文件过少" "$n_ko"

# ---------------- 2. 依赖 ----------------
echo "[2] 依赖"
req=$(rpm -qp --requires "$IMG_RPM" 2>/dev/null)
echo "$req" | grep -q "kernel-lubancat-modules = " && ok "Requires 同版本 modules" || bad "缺 Requires: kernel-lubancat-modules"
echo "$req" | grep -q "kernel-lubancat-modules = ${kver%-*}-" && ok "Requires 版本段匹配" || info "（版本串：$(echo "$req" | grep kernel-lubancat-modules)）"

# ---------------- 3/4. 真实安装 ----------------
echo "[3] /boot 未挂载时必须拒绝安装"
if [ ! -f "$rootfs_img" ]; then
    info "跳过 3/4：找不到 rootfs.img（$rootfs_img）"
else
    # upper/work 必须放在支持 xattr 的普通文件系统上。容器根是 overlayfs，
    # 在它上面再叠 overlay 会失败（overlay-on-overlay 不支持），所以放到 $workdir/tmp，
    # 它经 bind 落在宿主的 ext4 上。
    mkdir -p "$workdir/tmp"
    M=${KRPM_CHECK_DIR:-$workdir/tmp/krpm-check-$$}
    cleanup() {
        [ -n "${M:-}" ] || return 0
        for m in "$M/merged/boot" "$M/merged/dev" "$M/merged/proc" "$M/merged/sys" "$M/merged" "$M/root"; do
            mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null
        done
        rm -rf "$M"
    }
    trap cleanup EXIT
    mkdir -p "$M"/{root,upper,work,merged}

    mount -o loop,ro "$rootfs_img" "$M/root" 2>/dev/null || { bad "rootfs.img 挂载失败"; cleanup; M=""; }
    if [ -n "${M:-}" ]; then
    mount -t overlay overlay -o "lowerdir=$M/root,upperdir=$M/upper,workdir=$M/work" "$M/merged" 2>/dev/null \
        || { bad "overlay 挂载失败（容器需要 privileged）"; cleanup; M=""; }
    fi

    if [ -n "${M:-}" ]; then
    for d in proc sys dev; do mount --bind /$d "$M/merged/$d" 2>/dev/null; done
    mkdir -p "$M/merged/tmp/krpm"
    cp -f "$IMG_RPM" "$MOD_RPM" "$M/merged/tmp/krpm/"

    # 3) 负向：不挂 boot，%pre 应拒绝
    # 不用 --test：它不跑 %pre，测不出拒绝。overlay 层是一次性的，真装也无副作用。
    out=$(chroot "$M/merged" rpm -ivh --nodeps --replacepkgs "/tmp/krpm/$(basename "$IMG_RPM")" 2>&1)
    rc=$?
    if [ $rc -ne 0 ] && echo "$out" | grep -q "未挂载"; then
        ok "%pre 拒绝（rc=$rc，提示 /boot 未挂载）"
    else
        bad "%pre 未按预期拒绝" "rc=$rc; $(echo "$out" | tail -1)"
    fi

    # 4) 正向：把 boot.img 挂成 /boot，并造两个旧版本 + 把 uEnv.txt 换成软链（模拟真机）
    echo "[4] 挂 boot.img 后真实安装"
    if [ -f "$boot_img" ]; then
        # 必须挂副本：直接 rw 挂真实 boot.img 会往里写测试文件（假版本、uEnv.txt 软链），
        # 污染构建产物。踩过一次，这里改成 cp 后挂。
        cp -f "$boot_img" "$M/boot.img.copy"
        mount -o loop "$M/boot.img.copy" "$M/merged/boot" 2>/dev/null || bad "boot.img 副本挂载失败"
        if mountpoint -q "$M/merged/boot"; then
            B="$M/merged/boot"
            for v in 6.1.99-oldA 6.1.99-oldB; do
                for p in Image System.map config initrd; do
                    echo fake > "$B/$p-$v"
                done
                touch -d "2 days ago" "$B/Image-$v"
            done
            touch -d "1 day ago" "$B/Image-6.1.99-oldA"
            if [ -f "$B/uEnv/uEnvLubanCat4IO.txt" ]; then
                ln -sfn uEnvLubanCat4IO.txt "$B/uEnv/uEnv.txt"
            fi

            # 记录安装前的 root=UUID：这就是 11-28 那次"装完起不来"的直接原因，
            # 必须断言内核包不会改动它（uEnv 不进载荷）
            uuid_before=$(grep -h '^cmdline=' "$B/uEnv/uEnvLubanCat4IO.txt" 2>/dev/null \
                          | sed -nE 's/.*root=UUID=([0-9a-fA-F-]+).*/\1/p' | head -1)

            out=$(chroot "$M/merged" rpm -ivh --nodeps --replacepkgs \
                    "/tmp/krpm/$(basename "$MOD_RPM")" "/tmp/krpm/$(basename "$IMG_RPM")" 2>&1)
            rc=$?
            echo "$out" | sed 's/^/        | /' | tail -8
            [ $rc -eq 0 ] && ok "安装成功（rc=0）" || bad "安装失败" "rc=$rc"

            [ -s "$B/Image-$kver" ]  && ok "Image-$kver 已落地" || bad "Image-$kver 未落地"
            [ -s "$B/initrd-$kver" ] && ok "initrd-$kver 已落地" || bad "initrd-$kver 未落地"

            if [ -L "$B/uEnv/uEnv.txt" ]; then
                ok "uEnv.txt 仍是软链"
                tgt=$(readlink -f "$B/uEnv/uEnv.txt")
                u=$(sed -n 's/^uname_r=//p' "$tgt" | head -1)
                [ "$u" = "$kver" ] && ok "软链目标的 uname_r = $kver" || bad "uname_r 未更新" "$u"
                i=$(sed -n 's/^initrd=//p' "$tgt" | head -1)
                [ "$i" = "initrd-$kver" ] && ok "initrd= 已改版本化" || bad "initrd= 未更新" "$i"
            else
                bad "uEnv.txt 不是软链了（sed 碰到了软链本身）"
            fi

            uuid_after=$(grep -h '^cmdline=' "$B/uEnv/uEnvLubanCat4IO.txt" 2>/dev/null \
                         | sed -nE 's/.*root=UUID=([0-9a-fA-F-]+).*/\1/p' | head -1)
            if [ -n "$uuid_before" ] && [ "$uuid_before" = "$uuid_after" ]; then
                ok "root=UUID 未被改动（$uuid_after）"
            else
                bad "root=UUID 被改动" "before=$uuid_before after=$uuid_after"
            fi

            n_ver=$(ls -1 "$B"/Image-* 2>/dev/null | wc -l)
            [ "$n_ver" -le 2 ] && ok "旧版本已清理（保留 $n_ver 版）" || bad "旧版本未清理" "$n_ver 版"

            [ -d "$M/merged/lib/modules/$kver" ] && ok "模块树已落地" || bad "模块树未落地"
        fi
    else
        info "跳过 4：找不到 boot.img（$boot_img）"
    fi
    fi
fi

echo
echo "================ RESULT: PASS=$PASS FAIL=$FAIL ================"
[ "$FAIL" -eq 0 ]
