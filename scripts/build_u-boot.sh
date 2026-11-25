#!/bin/bash
set -e
set -x

__usage="
Usage: build_u-boot [OPTIONS]
Build openEuler SBCs u-boot image.
The target files idbloader.img and u-boot.itb will be generated in the build/u-boot folder of the directory where the build_u-boot.sh script is located.

Options: 
  --board, BOARD_CONFIG     Required! The config of target board in the boards folder, which defaults to firefly-rk3399.
  --cores N                 The number of cpu cores to be used during making.
  -h, --help                Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    board=firefly-rk3399
    workdir=${cur_dir}/build
    u_boot_url="https://gitlab.arm.com/systemready/firmware-build/u-boot.git"
    rk3399_bl31_url="https://github.com/rockchip-linux/rkbin/raw/master/bin/rk33/rk3399_bl31_v1.36.elf"
    log_dir=${workdir}/log
    nonfree_bin_dir=${cur_dir}/bin
    make_cores=$(nproc)
}

local_param(){
    if [ -f ${workdir}/.param ]; then
        board=$(cat ${workdir}/.param | grep board)
        board=${board:6}
    fi
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi

    while [ "x$#" != "x0" ];
    do
        if [ "x$1" == "x-h" -o "x$1" == "x--help" ]; then
            return 1
        elif [ "x$1" == "x" ]; then
            shift
        elif [ "x$1" == "x--board" ]; then
            board=`echo $2`
            shift
            shift
        elif [ "x$1" == "x--cores" ]; then
            make_cores=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
    done
}

buildid=$(date +%Y%m%d%H%M%S)
builddate=${buildid:0:8}

ERROR(){
    echo `date` - ERROR, $* | tee -a ${log_dir}/${builddate}.log 2>/dev/null || echo `date` - ERROR, $*
}

LOG(){
    # 宿主执行时 ${log_dir} 可能是容器内 root 创建的（不可写），日志失败不应中断构建
    echo `date` - INFO, $* | tee -a ${log_dir}/${builddate}.log 2>/dev/null || echo `date` - INFO, $*
}

build_u-boot() {
    pushd ${workdir}
    if [ -d ${workdir}/u-boot ];then
        pushd ${workdir}/u-boot
        remote_url_exist=`git remote -v | grep "origin"`
        remote_url=`git ls-remote --get-url origin`
        popd
        if [[ ${remote_url_exist} = "" || ${remote_url} != ${u_boot_url} ]]; then
            rm -rf ${workdir}/u-boot
            git clone --depth=1 -b ${u_boot_ver} ${u_boot_url}
            if [[ $? -eq 0 ]]; then
                LOG "clone u-boot done."
            else
                ERROR "clone u-boot failed."
                exit 1
            fi
        fi
    else
        git clone --depth=1 -b ${u_boot_ver} ${u_boot_url}
        LOG "clone u-boot done."
    fi
    popd
    pushd ${workdir}/u-boot
    if [[ -f ${workdir}/u-boot/u-boot.itb && -f ${workdir}/u-boot/idbloader.img ]];then
        LOG "u-boot is the latest"
    else
        if [ -f bl31.elf ];then rm bl31.elf; fi
        wget -O bl31.elf ${rk3399_bl31_url}
        if [ ! -f bl31.elf ]; then
            ERROR "arm-trusted-firmware(bl31.elf) can not be found!"
            exit 2
        fi

        make ARCH=arm ${ubootconfig}
        make ARCH=arm -j${make_cores}
        make ARCH=arm u-boot.itb -j${make_cores}
        LOG "make u-boot done."
    fi
    if [ ! -f u-boot.itb ]; then
        ERROR "make u-boot failed!"
        exit 2
    fi
    popd

}

use_prebuild_u-boot() {
    if [ -d ${workdir}/u-boot ]; then
        rm -rf ${workdir}/u-boot
    fi

    mkdir ${workdir}/u-boot
    if [[ "x${platform}" == "xrockchip" ]]; then
        cp ${local_uboot_dir}/* ${workdir}/u-boot
    elif [[ "x${platform}" == "xphytium" ]]; then
        cp ${local_uboot_dir}/fip-all-sd-boot.bin ${workdir}/u-boot
        mkenvimage -s 0x1000 -o ${workdir}/u-boot/env.bin ${local_uboot_dir}/env.txt
        dd if=${workdir}/u-boot/env.bin of=${workdir}/u-boot/fip-all-sd-boot.bin bs=1k seek=1472 conv=notrunc
    elif [[ "x${platform}" == "xallwinner" ]]; then
        cp ${local_uboot_dir}/* ${workdir}/u-boot
    elif [[ "x${platform}" == "xamlogic" ]]; then
        cp ${local_uboot_dir}/* ${workdir}/u-boot
    else
        echo "target u-boot can not found!"
        exit 2
    fi
}


use_local_u_boot() {
    # 用 Rockchip 的 src/u-boot（2017.09 + make.sh）在本地源码树原地构建。
    # 与上面的 build_u-boot()（arm.com 上游 v2020.10 + rk3399 bl31）是两套体系，
    # 后者对本项目所有 LubanCat 板都不适用。
    #
    # 关键点：
    #   - make.sh 必须原地跑（它硬编码 RKBIN_TOOLS=../rkbin/tools）
    #   - fragment 必须在 make.sh 之前叠加：给 make.sh 传板名会重跑
    #     `make <board>_defconfig`，把 fragment 冲掉
    #   - make.sh 固定 PYTHON=python2；宿主原生有，容器没有 → 默认在宿主跑
    local ub="${uboot_src_dir:-${cur_dir}/../../u-boot}"
    local defconfig="${uboot_defconfig:-}"
    local frag="${cur_dir}/configs/u-boot/distro-boot.config"

    [ -n "${defconfig}" ] || { ERROR "build_uboot_from_src=1 但 conf 未设 uboot_defconfig"; exit 2; }
    [ -f "${ub}/make.sh" ] || { ERROR "找不到 ${ub}/make.sh（uboot_src_dir=${ub}）"; exit 2; }
    [ -f "${frag}" ]       || { ERROR "缺少 Kconfig fragment: ${frag}"; exit 2; }
    # 宿主执行时 ${workdir} 可能是容器内 root 创建的；不可写就无法落产物
    if [ ! -w "${workdir}" ]; then
        ERROR "${workdir} 不可写（属主多为 root）。在宿主跑 u-boot 前先修一次："
        ERROR "  docker exec oe-lubancat-build bash -c 'mkdir -p /work/src/SBC-sig/scripts/build/log /work/src/SBC-sig/scripts/build/u-boot && chown -R 1000:1000 /work/src/SBC-sig/scripts/build/log /work/src/SBC-sig/scripts/build/u-boot'"
        exit 2
    fi
    [ -n "${CROSS_COMPILE:-}" ] || { ERROR "CROSS_COMPILE 未设置（需要 ${workdir}/openeuler_gcc_arm64le/bin 交叉工具链）"; exit 2; }
    command -v python2 >/dev/null 2>&1 || { ERROR "u-boot make.sh 需要 python2（宿主安装 python2 或改用 --uboot-env container）"; exit 2; }

    # u-boot 2017.09 的厂商代码在 GCC 12 下会触发大量老式告警（实测 cmd/dtfile.c
    # 的 -Werror=address 直接编不过），逐条豁免不现实，统一关掉 -Werror。
    export KCFLAGS="${KCFLAGS:-} -Wno-error"

    LOG "build u-boot from source: defconfig=${defconfig} fragment=$(basename ${frag})"

    pushd "${ub}" >/dev/null

    make ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" "${defconfig}" >/dev/null || {
        ERROR "make ${defconfig} 失败"; popd >/dev/null; exit 2; }

    # 叠加 fragment：merge_config.sh 是 kconfig 自带脚本，逐项合并并保留依赖
    if ! scripts/kconfig/merge_config.sh -m .config "${frag}" >/dev/null 2>&1; then
        LOG "merge_config.sh 不可用，直接追加 fragment"
        cat "${frag}" >> .config
    fi
    make ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig >/dev/null || {
        ERROR "make olddefconfig 失败"; popd >/dev/null; exit 2; }

    # 断言 .config（早失败，别等到刷机才发现）
    local missing="" sym
    # 注意：这一版 u-boot 没有 CONFIG_FS_EXT4 符号，ext4 代码由 fs/Makefile 的
    # obj-$(CONFIG_CMD_EXT4) 直接编入，所以只断言 CMD_* 与分区符号。
    for sym in CONFIG_CMD_PART CONFIG_CMD_EXT4 CONFIG_CMD_FS_GENERIC \
               CONFIG_EFI_PARTITION CONFIG_DOS_PARTITION; do
        grep -q "^${sym}=y" .config || missing="${missing} ${sym}"
    done
    [ -n "${missing}" ] && { ERROR "u-boot .config 缺符号:${missing}"; popd >/dev/null; exit 2; }
    grep -q "^CONFIG_BOOTCOMMAND=.*distro_bootcmd\|^CONFIG_BOOTCOMMAND=.*bootcmd" .config \
        || LOG "WARN .config 里没看到 distro_bootcmd，bootcmd 可能由 BOOTENV 提供（继续）"

    # 不传板名 → make.sh 用现有 .config（:263）
    LOG "make u-boot（make.sh 不带板名）"
    ./make.sh CROSS_COMPILE="${CROSS_COMPILE}" >>"${log_dir}/uboot-make.log" 2>&1 || {
        tail -25 "${log_dir}/uboot-make.log"
        ERROR "make.sh 失败，详见 ${log_dir}/uboot-make.log"; popd >/dev/null; exit 2; }

    LOG "pack loader（boot_merger）"
    ./make.sh CROSS_COMPILE="${CROSS_COMPILE}" loader >>"${log_dir}/uboot-make.log" 2>&1 || {
        tail -25 "${log_dir}/uboot-make.log"
        ERROR "make.sh loader 失败，详见 ${log_dir}/uboot-make.log"; popd >/dev/null; exit 2; }

    [ -s "${ub}/uboot.img" ] || { ERROR "make.sh 未产出 uboot.img"; popd >/dev/null; exit 2; }

    # 二进制级断言：.config 里 =y 不等于链接进去了
    if [ -f "${ub}/u-boot.bin" ] && command -v strings >/dev/null 2>&1; then
        strings "${ub}/u-boot.bin" | grep -qw ext4load \
            || { ERROR "u-boot.bin 里没有 ext4load，FS 命令没被链进去"; popd >/dev/null; exit 2; }
    fi

    popd >/dev/null

    # 产物落到 build/u-boot/（gen_rk_update.sh 直接消费这两个名字）
    rm -rf "${workdir}/u-boot"
    mkdir -p "${workdir}/u-boot"
    install -m644 "${ub}/uboot.img" "${workdir}/u-boot/uboot.img"

    local ld
    ld=$(ls -1 "${ub}"/*_spl_loader_*.bin 2>/dev/null | sort | tail -1)
    [ -n "${ld}" ] || { ERROR "make.sh loader 未产出 *_spl_loader_*.bin"; exit 2; }
    install -m644 "${ld}" "${workdir}/u-boot/MiniLoaderAll.bin"

    LOG "u-boot source build done: uboot.img=$(stat -c %s "${workdir}/u-boot/uboot.img")B MiniLoaderAll.bin=$(stat -c %s "${workdir}/u-boot/MiniLoaderAll.bin")B"

    # 可选：回写 bin/u-boot/<board>/（先把厂商原件备份成 .vendor）
    if [ "${uboot_install_to_bin:-0}" = "1" ]; then
        local dst="${nonfree_bin_dir}/u-boot/${board}"
        mkdir -p "${dst}"
        [ -f "${dst}/u-boot.itb" ] && [ ! -f "${dst}/u-boot.itb.vendor" ] && cp -a "${dst}/u-boot.itb" "${dst}/u-boot.itb.vendor"
        [ -f "${dst}/MiniLoaderAll.bin" ] && [ ! -f "${dst}/MiniLoaderAll.bin.vendor" ] && cp -a "${dst}/MiniLoaderAll.bin" "${dst}/MiniLoaderAll.bin.vendor"
        install -m644 "${workdir}/u-boot/uboot.img"            "${dst}/u-boot.itb"
        install -m644 "${workdir}/u-boot/MiniLoaderAll.bin"    "${dst}/MiniLoaderAll.bin"
        LOG "installed to ${dst}（原件已备份为 *.vendor）"
    fi
}

set -e
u_boot_ver="v2020.10"
cur_dir=$(cd $(dirname $0);pwd)
default_param
local_param
parseargs "$@" || help $?

source ${cur_dir}/boards/${board}.conf

host_arch=$(arch)

if [[ "${host_arch}" == "x86_64" && "${arch}" == "arm64" ]];then
    LOG "You are running this script on a ${host_arch} mechine, use cross compile...."
    export CROSS_COMPILE="${workdir}/openeuler_gcc_arm64le/bin/aarch64-openeuler-linux-gnu-"
else
    LOG "You are running this script on a ${host_arch} mechine, progress...."
fi

if [ ! -d ${workdir} ]; then
    mkdir ${workdir}
fi

if [ ! -d ${log_dir} ];then mkdir -p ${log_dir}; fi
if [ ! -f ${workdir}/.done ];then
    touch ${workdir}/.done 2>/dev/null || LOG "WARN 无法创建 ${workdir}/.done（宿主模式下由容器维护）"
fi
if [ "${LTB_SKIP_DONE_MARK:-0}" = "1" ]; then
    LOG "LTB_SKIP_DONE_MARK=1：跳过 .done 清理（由调用方通过容器维护）"
else
    sed -i 's/u-boot//g' ${workdir}/.done
fi
LOG "build u-boot..."

if [[ "x${ubootconfig}" == "x" && "x${local_uboot_dir}" == "x" ]]; then # RaspberryPi & Radxa-Orion-O6
    LOG "Skip build u-boot."
else
    if [ "${build_uboot_from_src:-0}" = "1" ]; then
        use_local_u_boot
    elif [ "x$ubootconfig" == "x" ]; then
        use_prebuild_u-boot
    else
        build_u-boot
    fi
    LOG "The bootloader files are generated in the ${workdir}/u-boot."
fi

if [ "${LTB_SKIP_DONE_MARK:-0}" = "1" ]; then
    LOG "LTB_SKIP_DONE_MARK=1：跳过 .done 写入（由调用方通过容器维护）"
else
    echo "u-boot" >> ${workdir}/.done
fi
