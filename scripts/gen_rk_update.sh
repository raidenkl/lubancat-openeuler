#!/bin/bash
# 厂商原生布局（Rockchip rk-boot：parameter + package-file + afptool/rkImageMaker）
# 与 gen_image.sh 的 SBC-sig 通用 GPT 布局并存、互不替代：
#   - gen_image.sh       -> GPT + idbloader@64 + u-boot.itb@16384，dd 整盘
#   - gen_rk_update.sh   -> parameter 分区表 + update.img，upgrade_tool/RKDevTool 刷写
#
# 输入（由 build_rootfs.sh / build_boot.sh 产出）：
#   build/rootfs.img                       ext4 根文件系统
#   build/boot.img                         ext2 extboot 分区（boot.scr/uEnv/dtb/overlay）
#   build/u-boot/uboot.img                 或 bin/u-boot/<board>/u-boot.itb（FIT: atf/optee/uboot）
#   build/u-boot/MiniLoaderAll.bin         或 bin/u-boot/<board>/MiniLoaderAll.bin
#                                         或 <rkbin>/rk3588_spl_loader_*.bin，缺失时用 boot_merger 生成
set -e

__usage="
Usage: gen_rk_update.sh [OPTIONS]
Pack openEuler boot.img/rootfs.img into a Rockchip vendor-layout update.img.

Options:
  -n, --name NAME      Image name, default: openEuler-LubanCat-5-aarch64-vendor
  -b, --board BOARD    Board config in boards/, default: lubancat-5
  -h, --help           Show this help.
"

help()
{
    echo "$__usage"
    exit ${1:-0}
}

default_param()
{
    workdir=${cur_dir}/build
    rkpack_dir=${workdir}/rkpack
    outputdir=${workdir}/$(date +'%Y-%m-%d')
    name=openEuler-LubanCat-5-aarch64-vendor
    board=lubancat-5
    nonfree_bin_dir=${cur_dir}/bin
    # 上游已跟踪的 Rockchip 打包工具（afptool / rkImageMaker）
    # afptool / rkImageMaker 与 SoC 无关，各板共用；只保留覆盖位
    rk_tool_dir=${rk_tool_dir:-${cur_dir}/bin/tools/rockchip/rk3588-pack}
    # rkbin：SBC-sig 与 rkbin 同级（src/SBC-sig、src/rkbin）
    rkbin_dir=${rkbin_dir:-${cur_dir}/../../rkbin}
    # uboot 分区：0x2000 扇区 = 4 MiB，足够放 983K 的 u-boot.itb
    rk_uboot_sectors=${rk_uboot_sectors:-0x2000}
    rk_uboot_offset=${rk_uboot_offset:-0x4000}   # 与 idbloader@64 + itb@16384 布局一致
    # 与 gen_image.sh 保持同一默认值；实际以 boot 分区 uEnv 里的 root=UUID 为准
    rootfs_uuid=${rootfs_uuid:-6f1c2a10-4b3e-4d55-9c8a-2f5d0b7e1a01}
    log_dir=${workdir}/log
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--name)  name=$2; shift 2 ;;
            -b|--board) board=$2; shift 2 ;;
            -h|--help)  help 0 ;;
            *)          echo "unknown option: $1"; help 1 ;;
        esac
    done
}

LOG()
{
    echo "$(date) - INFO, $*" | tee -a ${log_dir}/$(date +'%Y%m%d').log
}
ERROR()
{
    echo "$(date) - ERROR, $*" | tee -a ${log_dir}/$(date +'%Y%m%d').log
}

cur_dir=$(cd "$(dirname "$0")"; pwd)
default_param

parseargs "$@"

# board.conf 可覆盖 boot_size / soc_name 等参数。
# 必须在 parseargs 之后加载：否则 -b 指定的板卡不会生效（会用 default_param 的默认板卡）。
[ -f ${cur_dir}/boards/${board}.conf ] || { echo "no such board: ${board}"; exit 1; }
source ${cur_dir}/boards/${board}.conf
[ -n "${soc_name:-}" ] || { echo "conf 未设置 soc_name: ${board}"; exit 1; }

mkdir -p ${log_dir} ${outputdir} ${rkpack_dir}/Image
boot_size=${boot_size:-256}

# ---------- SoC 派生（loader / parameter / 打包共用）----------
# soc_name 是 uEnv 目录名，可能是家族名（rk356x），而 loader 文件名是 rk3566_spl_loader_*.bin
loader_prefix=${loader_prefix:-${soc_name}}
[ "${loader_prefix}" = rk356x ] && loader_prefix=rk3566
rk_loader_ini=${rk_loader_ini:-${loader_prefix^^}MINIALL.ini}
param_machine=${param_machine:-${loader_prefix^^}}
xz_threads=${xz_threads:-8}
LOG "soc: soc_name=${soc_name} loader_prefix=${loader_prefix} loader_ini=${rk_loader_ini}"

# ---------- 0. 前置检查 ----------
for f in ${workdir}/boot.img ${workdir}/rootfs.img; do
    [ -s "$f" ] || { ERROR "missing $f (run build_boot.sh / build_rootfs.sh first)"; exit 2; }
done
for t in afptool rkImageMaker; do
    [ -x "${rk_tool_dir}/$t" ] || chmod +x "${rk_tool_dir}/$t" 2>/dev/null || true
    [ -x "${rk_tool_dir}/$t" ] || { ERROR "missing tool ${rk_tool_dir}/$t"; exit 2; }
done

# ---------- 1. loader（bootloader 项）----------
loader=""
for c in ${workdir}/u-boot/MiniLoaderAll.bin \
         ${nonfree_bin_dir}/u-boot/${board}/MiniLoaderAll.bin; do
    [ -s "$c" ] && { loader=$c; break; }
done
if [ -z "${loader}" ]; then
    for c in ${workdir}/u-boot/${loader_prefix}_spl_loader_*.bin \
             ${nonfree_bin_dir}/u-boot/${board}/${loader_prefix}_spl_loader_*.bin; do
        [ -s "$c" ] && { loader=$c; break; }
    done
fi
if [ -z "${loader}" ] && [ -x "${rkbin_dir}/tools/boot_merger" ]; then
    LOG "loader not found, generate with boot_merger..."
    ( cd "${rkbin_dir}" && ./tools/boot_merger pack "RKBOOT/${rk_loader_ini}" ) >/dev/null 2>&1 || true
    for c in ${rkbin_dir}/${loader_prefix}_spl_loader_*.bin; do [ -s "$c" ] && { loader=$c; break; }; done
fi
[ -n "${loader}" ] || { ERROR "no loader (MiniLoaderAll.bin / ${loader_prefix}_spl_loader_*.bin)"; exit 2; }

# rkImageMaker 的 -RKxxxx：优先 conf 显式；其次从 loader 头读（offset 21 起 4 字节，小端）；
# 最后退回 loader_prefix。Cat-4 虽为 RK3588S，loader 头仍是 3588，从头部推导天然正确。
if [ -z "${rkimage_chip:-}" ]; then
    rkimage_chip=$(dd if="${loader}" bs=1 skip=21 count=4 2>/dev/null | rev)
    case "${rkimage_chip}" in
        [0-9][0-9][0-9][0-9]) : ;;
        *) rkimage_chip=$(printf '%s' "${loader_prefix#rk}" | tr '[:lower:]' '[:upper:]') ;;
    esac
fi
LOG "rkimage_chip=${rkimage_chip} (loader=$(basename "${loader}"))"

# ---------- 2. uboot.img（FIT：atf + optee + uboot）----------
uboot_img=${workdir}/u-boot/uboot.img
if [ ! -s "${uboot_img}" ]; then
    src=""
    for c in ${nonfree_bin_dir}/u-boot/${board}/u-boot.itb ${workdir}/u-boot/u-boot.itb; do
        [ -s "$c" ] && { src=$c; break; }
    done
    [ -n "${src}" ] || { ERROR "no u-boot.itb to build uboot.img"; exit 2; }
    cp -f "${src}" "${uboot_img}"
    LOG "uboot.img <= $(basename ${src})"
fi

# ---------- 3. parameter.txt：uboot / boot / rootfs ----------
uboot_off=${rk_uboot_offset}
uboot_num=$((rk_uboot_sectors))
boot_off=$((uboot_off + uboot_num))
boot_num=$((boot_size * 1024 * 1024 / 512))
rootfs_off=$((boot_off + boot_num))

cat > ${rkpack_dir}/Image/parameter.txt <<EOF
FIRMWARE_VER: 8.1
MACHINE_MODEL: ${param_machine}
MACHINE_ID: 007
MANUFACTURER: ${param_machine}
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: 0xffffffff
CHECK_MASK: 0x80
PWR_HLD: 0,0,A,0,1
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:$(printf '0x%08x' ${uboot_num})@$(printf '0x%08x' ${uboot_off})(uboot),$(printf '0x%08x' ${boot_num})@$(printf '0x%08x' ${boot_off})(boot:bootable),-@$(printf '0x%08x' ${rootfs_off})(rootfs:grow)
EOF

# ---------- 4. 组装 Image/ 与 package-file ----------
cp -f "${loader}"      ${rkpack_dir}/Image/MiniLoaderAll.bin
cp -f "${uboot_img}"   ${rkpack_dir}/Image/uboot.img
cp -f ${workdir}/boot.img   ${rkpack_dir}/Image/boot.img

# rootfs 镜像的 ext4 UUID 必须与 uEnv/extlinux 里的 root=UUID 一致。
# build_rootfs.sh 产出的 rootfs.img 每次重建 UUID 都不同；build_boot.sh 产出的 boot 分区里
# 还是构建期占位 UUID（gen_image.sh 会在目标分区上替换并 mkfs -U，vendor 打包没有这一步）。
# 因此这里做两件事：① 把 boot 分区内的占位 UUID 替换成固定值；② 改写 rootfs.img 的 UUID。
cp -f ${workdir}/rootfs.img ${rkpack_dir}/Image/rootfs.img

# ---------- 4.1 内核模块入 rootfs（对齐 gen_image.sh 的 same 段）----------
# 背景：build_boot.sh 只把 modules_install 产物放到 ${workdir}/kernel/kernel-modules，
# gen_image.sh（GPT 布局）会把它拷进 rootfs；vendor 后端若不做同样的事，
# 镜像启动后 /lib/modules 为空 → rtw88(RTL8822CE)、option(EC20)、btusb 等模块化驱动全部缺失。
# 注意 usrmerge：/lib 是指向 usr/lib 的符号链接，写 ${rootmnt}/lib 会自动落到 usr/lib。
rootmnt=${workdir}/rk_root_tmp
umount ${rootmnt} 2>/dev/null || true
mkdir -p ${rootmnt}
mount -t ext4 ${rkpack_dir}/Image/rootfs.img ${rootmnt} || { ERROR "mount rootfs.img failed"; exit 2; }
trap 'umount ${rootmnt} 2>/dev/null || true' EXIT
if [ -d ${workdir}/kernel/kernel-modules/lib/modules ]; then
    kver=$(ls ${workdir}/kernel/kernel-modules/lib/modules | head -1)
    rm -rf ${rootmnt}/lib/modules
    cp -rfp ${workdir}/kernel/kernel-modules/lib/modules ${rootmnt}/lib
    # depmod 与内核架构无关，直接对挂载点生成 modules.dep（rootfs 内的 depmod 是 aarch64，构建机跑不了）
    if command -v depmod >/dev/null 2>&1; then
        depmod -b ${rootmnt} "${kver}" >/dev/null 2>&1 || LOG "WARN: depmod -b ${kver} failed"
    else
        LOG "WARN: depmod not found on build host, skip modules.dep"
    fi
    ko_n=$(find ${rootmnt}/lib/modules/${kver} -name '*.ko' 2>/dev/null | wc -l)
    LOG "install kernel modules ${kver} into rootfs: ${ko_n} ko"
else
    LOG "WARN: ${workdir}/kernel/kernel-modules missing, image will boot without modules"
fi
sync
umount ${rootmnt}
trap - EXIT

bootmnt=${workdir}/rk_boot_tmp
umount ${bootmnt} 2>/dev/null || true
mkdir -p ${bootmnt}
mount -t ext2 ${rkpack_dir}/Image/boot.img ${bootmnt} || { ERROR "mount boot.img failed"; exit 2; }
trap 'umount ${bootmnt} 2>/dev/null || true' EXIT
if [ -d ${bootmnt}/uEnv ]; then
    find ${bootmnt}/uEnv -name '*.txt' -exec \
        sed -i "s|614e0000-0000-4b53-8000-1d28000054a9|${rootfs_uuid}|g" {} +
fi
[ -f ${bootmnt}/extlinux/extlinux.conf ] && \
    sed -i "s|614e0000-0000-4b53-8000-1d28000054a9|${rootfs_uuid}|g" ${bootmnt}/extlinux/extlinux.conf
sync
umount ${bootmnt}
trap - EXIT

# tune2fs 要求文件系统处于「刚检查过」状态，否则拒绝改 UUID
e2fsck -fy ${rkpack_dir}/Image/rootfs.img >/dev/null 2>&1 || true
tune2fs -U ${rootfs_uuid} ${rkpack_dir}/Image/rootfs.img >/dev/null 2>&1 || {
    ERROR "tune2fs -U ${rootfs_uuid} failed"; exit 2; }
got_uuid=$(tune2fs -l ${rkpack_dir}/Image/rootfs.img 2>/dev/null | awk '/Filesystem UUID/{print $3}')
[ "${got_uuid}" = "${rootfs_uuid}" ] || { ERROR "rootfs UUID mismatch: ${got_uuid} != ${rootfs_uuid}"; exit 2; }
LOG "rootfs UUID fixed to ${rootfs_uuid} (uEnv/extlinux/rootfs 三方一致)"

cat > ${rkpack_dir}/package-file <<'EOF'
package-file	package-file
bootloader	Image/MiniLoaderAll.bin
parameter	Image/parameter.txt
uboot		Image/uboot.img
boot		Image/boot.img
rootfs		Image/rootfs.img
EOF
cp -f ${rkpack_dir}/package-file ${rkpack_dir}/Image/package-file

# 尺寸校验：uboot/boot 不能超过 parameter 给定分区
itb_sz=$(stat -c %s ${rkpack_dir}/Image/uboot.img)
itb_cap=$((uboot_num * 512))
[ ${itb_sz} -le ${itb_cap} ] || { ERROR "uboot.img ${itb_sz} > partition ${itb_cap}"; exit 2; }
boot_sz=$(stat -c %s ${rkpack_dir}/Image/boot.img)
boot_cap=$((boot_num * 512))
[ ${boot_sz} -le ${boot_cap} ] || { ERROR "boot.img ${boot_sz} > partition ${boot_cap}"; exit 2; }

# ---------- 5. afptool 打包 + rkImageMaker 加壳 ----------
LOG "pack update.img (afptool)..."
cd ${rkpack_dir}
${rk_tool_dir}/afptool -pack . Image/update.img >/dev/null 2>&1 || {
    ERROR "afptool pack failed"; exit 2; }

LOG "wrap loader (rkImageMaker)..."
${rk_tool_dir}/rkImageMaker -RK${rkimage_chip} Image/MiniLoaderAll.bin Image/update.img \
    ${outputdir}/${name}.img -os_type:androidos >/dev/null 2>&1 || {
    ERROR "rkImageMaker failed"; exit 2; }

[ -s ${outputdir}/${name}.img ] || { ERROR "no output image"; exit 2; }

# ---------- 6. 自校验：解包比对 ----------
# afptool -unpack 会把内容还原到 <dir>/Image/ 下（保留 package-file 里的相对路径）
LOG "verify by unpacking..."
rm -rf ${workdir}/rkverify && mkdir -p ${workdir}/rkverify
${rk_tool_dir}/afptool -unpack Image/update.img ${workdir}/rkverify >/dev/null 2>&1 || true
for f in MiniLoaderAll.bin parameter.txt uboot.img boot.img rootfs.img; do
    u=${workdir}/rkverify/Image/$f
    if [ -s "$u" ]; then
        a=$(stat -c %s "$u"); b=$(stat -c %s ${rkpack_dir}/Image/$f)
        [ "$a" = "$b" ] || { ERROR "unpack size mismatch: $f ($a != $b)"; exit 2; }
    else
        ERROR "unpack missing Image/$f"; exit 2
    fi
done
# 最终一致性：从打包后的镜像里读回，确认 uEnv cmdline 与 rootfs 实际 UUID 相同
u_boot=$(debugfs -R "cat /uEnv/uEnv.txt" ${workdir}/rkverify/Image/boot.img 2>/dev/null \
         | grep -m1 '^cmdline' | grep -o 'root=UUID=[0-9a-f-]*' | cut -d= -f3)
u_root=$(tune2fs -l ${workdir}/rkverify/Image/rootfs.img 2>/dev/null | awk '/Filesystem UUID/{print $3}')
[ "${u_boot}" = "${u_root}" ] || { ERROR "UUID mismatch in packed image: uEnv=${u_boot} rootfs=${u_root}"; exit 2; }
LOG "packed-image UUID check OK: ${u_root}"

# 最终镜像必须能被 rkImageMaker 还原出 loader(boot.bin) 与 firmware.img
rm -rf ${workdir}/rkverify2 && mkdir -p ${workdir}/rkverify2
${rk_tool_dir}/rkImageMaker -unpack ${outputdir}/${name}.img ${workdir}/rkverify2 >/dev/null 2>&1 || true
[ -s ${workdir}/rkverify2/boot.bin ] && [ -s ${workdir}/rkverify2/firmware.img ] || {
    ERROR "rkImageMaker unpack verify failed (loader/firmware missing)"; exit 2; }
rm -rf ${workdir}/rkverify ${workdir}/rkverify2

# ---------- 7. 压缩与输出 ----------
LOG "xz compress..."
( cd ${outputdir} && xz -T ${xz_threads} -f ${name}.img )
( cd ${outputdir} && sha256sum ${name}.img.xz > ${name}.img.xz.sha256sum )

cat <<EOF

========================================================================
vendor layout (Rockchip rk-boot / parameter)
  parameter : uboot $(printf '0x%x' ${uboot_num})@$(printf '0x%x' ${uboot_off})  boot $(printf '0x%x' ${boot_num})@$(printf '0x%x' ${boot_off})  rootfs grow@$(printf '0x%x' ${rootfs_off})
  bootloader: $(basename ${loader})  ($(du -h ${loader} | cut -f1))
  uboot.img : ${itb_sz} bytes (FIT: atf/optee/uboot)
  boot.img  : ${boot_sz} bytes (ext2, extboot)
  rootfs.img: $(stat -c %s ${workdir}/rootfs.img) bytes
  output    : ${outputdir}/${name}.img.xz
  sha256    : $(cut -d' ' -f1 ${outputdir}/${name}.img.xz.sha256sum)
flash with upgrade_tool / RKDevTool (MaskRom), NOT dd.
========================================================================
EOF
