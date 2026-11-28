#!/bin/bash
set -e
set +x

__usage="
Usage: build_rootfs [OPTIONS]
Build openEuler rootfs image.
Run in root user.
The target rootfs.img will be generated in the build folder of the directory where the build_rootfs.sh script is located.

Options: 
  --board, BOARD_CONFIG         Required! The config of target board in the boards folder, which defaults to firefly-rk3399.
  -r, --repo REPO_INFO          The URL/path of target repo file or list of repo's baseurls which should be a space separated list.
  -b, --branch KERNEL_BRANCH    The branch name of kernel source's repository, which defaults to openEuler-20.03-LTS.
  -s, --spec SPEC               The image's specification: headless, xfce, ukui, dde, gnome, devstation or the file path of rpmlist. The default is headless.
  -h, --help                    Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

default_param() {
    board=firefly-rk3399
    repo_file="https://raw.atomgit.com/src-openeuler/openEuler-repos/raw/openEuler-20.03-LTS/generic.repo"
    workdir=${cur_dir}/build
    tmp_dir=${workdir}/tmp
    branch=openEuler-20.03-LTS
    rootfs_arch=aarch64
    nonfree_bin_dir=${cur_dir}/bin
    rpmlist_dir=${cur_dir}/configs/common
    rootfs_dir=${workdir}/rootfs
    log_dir=${workdir}/log
    rootfs_mnt=${workdir}/rootfs_tmp
}

local_param(){
    if [ -f ${workdir}/.param ]; then
        board=$(cat ${workdir}/.param | grep board)
        board=${board:6}

        repo_file=$(cat ${workdir}/.param | grep repo_file)
        repo_file=${repo_file:10}

        branch=$(cat ${workdir}/.param | grep branch)
        branch=${branch:7}

        spec_param=$(cat ${workdir}/.param | grep spec_param)
        spec_param=${spec_param:11}

        kernel_url=$(cat ${workdir}/.param | grep kernel_url)
        kernel_url=${kernel_url:11}
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
        elif [ "x$1" == "x-r" -o "x$1" == "x--repo" ]; then
            repo_file=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-b" -o "x$1" == "x--branch" ]; then
            branch=`echo $2`
            shift
            shift
        elif [ "x$1" == "x-s" -o "x$1" == "x--spec" ]; then
            spec_param=`echo $2`
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
    echo `date` - ERROR, $* | tee -a ${log_dir}/${builddate}.log
}

LOG(){
    echo `date` - INFO, $* | tee -a ${log_dir}/${builddate}.log
}

LOSETUP_D_IMG(){
    set +e
    if [ -d ${rootfs_mnt} ]; then
        if grep -q "${rootfs_mnt} " /proc/mounts ; then
            umount ${rootfs_mnt}
        fi
    fi
    if [ -d ${rootfs_mnt} ]; then
        rm -rf ${rootfs_mnt}
    fi
    set -e
}

UMOUNT_ALL(){
    set +e
    if grep -q "${rootfs_dir}/dev " /proc/mounts ; then
        umount -l ${rootfs_dir}/dev
    fi
    if grep -q "${rootfs_dir}/proc " /proc/mounts ; then
        umount -l ${rootfs_dir}/proc
    fi
    if grep -q "${rootfs_dir}/sys " /proc/mounts ; then
        umount -l ${rootfs_dir}/sys
    fi
    set -e
}

root_need() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error:This script must be run as root!" 1>&2
        exit 1
    fi
}

# 统一的 chroot dnf 包装。
# --setopt='*.skip_if_unavailable=true'：把"某个上游 repo 的 metadata 坏了"降级成
# 跳过该 repo，而不是让整条 dnf 命令失败。openEuler 的 update 仓库出现过
# repomd.xml 校验和与 metalink 登记不符（持续复现），结果装 ukui 整组失败，
# 而下面的循环只打 ERROR 就继续 —— 产出了没有桌面的"假成功"镜像。
dnf_chroot() {
    chroot ${rootfs_dir}/ dnf ${tmp_repo_info} --disablerepo="*" \
        --setopt='*.skip_if_unavailable=true' "$@"
}

# 装一组包；失败时用 --refresh 重拉一次仓库元数据再试。
#
# 为什么需要：openEuler 的 update 仓库反复出现"元数据与本体不一致"，实测三类：
#   1) NetworkManager-1.44.2-10：repodata 声明 1935669 字节，服务器实际给 1935657
#      → dnf 报 "Inconsistent server data ... repository metadata states file length"
#   2) repomd.xml 校验和与 metalink 登记不符 → 整个 repo 的 metadata 都下不来
#   3) 镜像偶发 Curl 28（30s 连接超时）/ 92（HTTP2 stream INTERNAL_ERROR）
# 这三类里 (1)(2) 只要重拉一次 metadata 就能自愈（上游修复后 repodata 会更新），
# 但同一次 dnf 处理里 dnf 会一直用那份坏缓存，不会自己重试——所以由这里补一次。
# (3) 由 dnf 自身的多镜像重试兜住，这里只是顺手再给一次机会。
dnf_install_set() {
    local desc=$1
    shift
    if dnf_chroot install -y "$@" --nogpgcheck; then
        LOG "$desc installed."
        return 0
    fi
    LOG "install $desc failed; retry once with --refresh (重新拉取仓库元数据)"
    if dnf_chroot --refresh --setopt=retries=10 --setopt=timeout=120 \
            install -y "$@" --nogpgcheck; then
        LOG "$desc installed (after --refresh)."
        return 0
    fi
    return 1
}

# 关掉 ukui-powermanagement-service（root 身份、系统总线 D-Bus 激活）。
#
# 为什么：它会在桌面会话起来约 20~30 秒后执行
#     echo 0 | tee /sys/class/backlight/*/brightness
# 把背光写成 0。MIPI 屏表现就是"桌面全黑"——DSI 连接器 connected、VOP 在输出、
# X 也在渲染（xrandr 里 DSI-1 primary 1024x600），只是背光关着，于是完全看不见。
# 现场排查时极易误判成 DSI/面板/dtb 问题（本次就走过这个弯路）。
#
# 该行为不受任何 dconf 键控制（backlight-battery-reduce=false、idle-dim-battery=false、
# brightness-bat=100.0 全部试过，仍归零）；也与会话里的 ukui-powermanagement、屏保、
# auto-brightness 插件无关（逐个杀掉/关掉后仍归零）。实测只有禁用它才停止写入：
# 去掉可执行位 + 摘掉 D-Bus 激活文件后，重启 lightdm 观察 100 秒，亮度稳定不再被改写。
#
# 代价（明示）：桌面亮度滑条失效（它经 D-Bus 调这个服务）、失去电池/休眠 UI，
# 以及开机时该服务顺带做的 governor=performance / power_dpm 设置。
# 这几块板没有电池，取舍可接受；将来要恢复亮度滑条，删掉下面两行即可。
#
# 作用域：ukui 专有。不要直接调用，统一由 DESKTOP_QUIRKS() 分派。
DISABLE_UKUI_POWER_MGMT() {
    local svc=${rootfs_dir}/usr/bin/ukui-powermanagement-service
    local act=${rootfs_dir}/usr/share/dbus-1/system-services/org.ukui.powermanagement.service

    # 兜底：正常入口是 DESKTOP_QUIRKS()，这里再判一次，保证被直接调用时也不会误伤
    if [ ! -e "${svc}" ] && [ ! -e "${act}" ]; then
        return 0
    fi

    if [ -f "${act}" ]; then
        mv "${act}" "${act}.disabled"
        LOG "ukui-powermanagement: 已摘除 D-Bus 激活（org.ukui.powermanagement.service -> .disabled）"
    fi

    if [ -f "${svc}" ]; then
        chmod -x "${svc}"
        LOG "ukui-powermanagement: 已去掉可执行位（不再把 /sys/class/backlight/*/brightness 写 0）"
    fi
}

DESKTOP_QUIRKS() {
    # 板级逃生开关：boards/<board>.conf 里写 keep_ukui_power_mgmt=1 即保留原行为
    if [ "${keep_ukui_power_mgmt:-0}" = "1" ]; then
        LOG "desktop quirks: keep_ukui_power_mgmt=1，保留 ukui 电源服务"
        return 0
    fi

    # 判定依据是"rootfs 里是否真的装了 ukui 的电源管理器"，而不是镜像名或板名：
    #   - build-image.sh 传下来的是清单路径（-s .../rpmlist-lubancat-desktop），
    #     桌面名在 spec_param 里已经丢失，按名字判断在本层不可行；
    #   - xfce/dde/gnome 用的是各自的后端（xfce4-power-manager 等），不会命中；
    #   - headless 更不会命中。
    # 这样 ukui 的修补天然只作用于 ukui 镜像，将来加桌面互不影响。
    if [ -e "${rootfs_dir}/usr/bin/ukui-powermanagement-service" ] \
       || [ -e "${rootfs_dir}/usr/share/dbus-1/system-services/org.ukui.powermanagement.service" ]; then
        DISABLE_UKUI_POWER_MGMT
    else
        LOG "desktop quirks: 未安装 ukui 电源管理，跳过 ukui 专有修补"
    fi
}

INSTALL_PACKAGES(){
    tmp_repo_info=$2
    dnf_chroot makecache --nogpgcheck || LOG "makecache: 有仓库不可用，已跳过（继续装包）"
    if [ "x${board}" == "xraspberrypi" ] && [ -z "${kernel_url}"  ]; then
        dnf_chroot install -y raspberrypi-kernel --nogpgcheck
        if [ $? == 0 ]; then
            LOG raspberrypi-kernel installed.
        else
            ERROR can not install raspberrypi-kernel.
        fi
        if [ "x$spec_param" == "xgnome" ] || [ "x$spec_param" == "xdevstation" ]; then
            dnf_chroot install -y raspberrypi-kernel-tools --nogpgcheck
            if [ $? == 0 ]; then
                LOG raspberrypi-kernel-tools installed.
            else
                ERROR can not install raspberrypi-kernel-tools.
            fi
        fi
    fi
    for item in $(cat $1)
    do
        # 失败先自动 --refresh 重试一次（见 dnf_install_set 的注释）；
        # 仍失败就停：宁可构建失败，也不要产出"看起来成功、实际缺整组包"的镜像
        # （曾因 update 仓库 metadata 校验失败，ukui 整组没装上，镜像照常打包）
        dnf_install_set "$item" "$item" || {
            ERROR can not install $item.
            exit 1
        }
    done
    if [ "x${bootmode}" == "xgrub" ]; then
        dnf_chroot install -y grub2-efi-aa64 grub2-efi-aa64-modules efibootmgr --nogpgcheck
    fi
}

build_rootfs() {
    if [ ! -d ${tmp_dir} ]; then
        mkdir -p ${tmp_dir}
    else
        rm -rf ${tmp_dir}/*
    fi

    if [ "x$spec_param" == "xheadless" ] || [ "x$spec_param" == "x" ]; then
        :
    elif [ "x$spec_param" == "xxfce" ] || [ "x$spec_param" == "xukui" ] || [ "x$spec_param" == "xdde" ] || [ "x$spec_param" == "xgnome" ] || [ "x$spec_param" == "xdevstation" ]; then
        CONFIG_RPM_LIST=${rpmlist_dir}/rpmlist-${spec_param}
    elif [ -f ${spec_param} ]; then
        cp ${spec_param} ${tmp_dir}/
        spec_file_name=${spec_param##*/}
        CONFIG_RPM_LIST=${tmp_dir}/${spec_file_name}
    else
        echo `date` - ERROR, please check your params in option -s or --spec.
        exit 2
    fi
    echo $(pwd)

    if [ "x$repo_file" == "x" ] ; then
        echo `date` - ERROR, \"-r REPO_INFO or --repo REPO_INFO\" missing.
        help 2
    elif [ "x${repo_file:0:4}" == "xhttp" ]; then
        if [ "x${repo_file:0-5}" == "x.repo" ]; then
            wget ${repo_file} -P ${tmp_dir}/
            repo_file_name=${repo_file##*/}
            repo_file=${tmp_dir}/${repo_file_name}
        else
            repo_file_name=tmp.repo
            repo_file_tmp=${tmp_dir}/${repo_file_name}
            index=1
            for baseurl in ${repo_file// / }
            do
                echo [repo${index}] >> ${repo_file_tmp}
                echo name=repo${index} to build ${board} image >> ${repo_file_tmp}
                echo baseurl=${baseurl} >> ${repo_file_tmp}
                echo enabled=1 >> ${repo_file_tmp}
                echo gpgcheck=0 >> ${repo_file_tmp}
                echo >> ${repo_file_tmp}
                index=$(($index+1))
            done
            repo_file=${repo_file_tmp}
        fi
    else
        if [ ! -f $repo_file ]; then
            echo `date` - ERROR, repo file $repo_file can not be found.
            exit 2
        else
            cp $repo_file ${tmp_dir}/
            repo_file_name=${repo_file##*/}
            repo_file=${tmp_dir}/${repo_file_name}
        fi
    fi

    repo_info_names=`cat ${repo_file} | grep "^\["`
    repo_baseurls=`cat ${repo_file} | grep "^baseurl="`
    index=1
    for repo_name in ${repo_info_names}
    do
        repo_name_list[$index]=${repo_name:1:-1}
        index=$((index+1))
    done
    index=1
    for baseurl in ${repo_baseurls}
    do
        repo_info="${repo_info} --repofrompath ${repo_name_list[$index]}-tmp,${baseurl:8}"
        index=$((index+1))
    done
    
    os_release_name="openEuler-release"
    dnf ${repo_info} --disablerepo="*" --downloaddir=${tmp_dir}/ download ${os_release_name} --forcearch ${rootfs_arch}
    if [ $? != 0 ]; then
        ERROR "Fail to download ${os_release_name}!"
        exit 2
    fi
    os_release_name=`ls -r ${tmp_dir}/${os_release_name}*.rpm 2>/dev/null| head -n 1`
    if [ -z "${os_release_name}" ]; then
        ERROR "${os_release_name} can not be found!"
        exit 2
    else
        LOG "Success to download ${os_release_name}."
    fi

    LOG "make rootfs for ${repo_file} begin..."
    trap 'UMOUNT_ALL' EXIT
    if [ -d ${rootfs_dir} ]; then
        UMOUNT_ALL
        rm -rf ${rootfs_dir}
    fi
    mkdir ${rootfs_dir}

    mkdir -p ${rootfs_dir}/var/lib/rpm
    rpm --root  ${rootfs_dir}/ --initdb
    rpm -ivh --nodeps --root ${rootfs_dir}/ ${os_release_name} --ignorearch

    mkdir -p ${rootfs_dir}/etc/rpm
    chmod a+rX ${rootfs_dir}/etc/rpm
    echo "%_install_langs en_US" > ${rootfs_dir}/etc/rpm/macros.image-language-conf
    echo ${repo_info}
    dnf ${repo_info} --disablerepo="*" --installroot=${rootfs_dir}/ install -y dnf yum --nogpgcheck --forcearch ${rootfs_arch}
    
    cp -L /etc/resolv.conf ${rootfs_dir}/etc/resolv.conf
    
    mount --bind /dev ${rootfs_dir}/dev
    mount -t proc /proc ${rootfs_dir}/proc
    mount -t sysfs /sys ${rootfs_dir}/sys
    set +e
    INSTALL_PACKAGES ${CONFIG_RPM_LIST} "${repo_info}"
    cat ${rootfs_dir}/etc/systemd/timesyncd.conf | grep "^NTP=*"
    if [ $? -ne 0 ]; then
        sed -i -e '/^#NTP=/cNTP=0.cn.pool.ntp.org' ${rootfs_dir}/etc/systemd/timesyncd.conf
        sed -i -e 's/#FallbackNTP=/FallbackNTP=1.asia.pool.ntp.org 2.asia.pool.ntp.org /g' ${rootfs_dir}/etc/systemd/timesyncd.conf
    fi
    set -e

    rm -rf ${rootfs_dir}/*.core
    
    cp ${cur_dir}/configs/common/resolv.conf ${rootfs_dir}/etc/resolv.conf

    if [ ! -d ${rootfs_dir}/etc/sysconfig/network-scripts ]; then mkdir "${rootfs_dir}/etc/sysconfig/network-scripts"; fi
    cp ${cur_dir}/configs/common/ifcfg-eth0 ${rootfs_dir}/etc/sysconfig/network-scripts/ifcfg-eth0

    LOG "Configure network done."

    if [ ! -d ${rootfs_dir}/etc/rc.d/init.d ]; then mkdir -p ${rootfs_dir}/etc/rc.d/init.d; fi

    if [ "x${board}" == "xraspberrypi" ]; then
        mkdir -p ${rootfs_dir}/lib/udev/rules.d
        if [ ! -d ${rootfs_dir}/usr/share/licenses/raspi ]; then mkdir -p ${rootfs_dir}/usr/share/licenses/raspi; fi
        cp ${cur_dir}/configs/raspberrypi/hosts ${rootfs_dir}/etc/hosts
        cp ${cur_dir}/configs/raspberrypi/*.rules ${rootfs_dir}/lib/udev/rules.d/
        cp ${cur_dir}/configs/raspberrypi/LICENCE.* ${rootfs_dir}/usr/share/licenses/raspi/
        cp ${cur_dir}/configs/common/extend-root.sh ${rootfs_dir}/etc/rc.d/init.d/extend-root.sh
        cp ${cur_dir}/configs/raspberrypi/chroot.sh ${rootfs_dir}/chroot.sh
    else
        cp ${cur_dir}/configs/common/extend-root.sh ${rootfs_dir}/etc/rc.d/init.d/extend-root.sh
        cp ${cur_dir}/configs/common/chroot.sh ${rootfs_dir}/chroot.sh
    fi

    chmod +x ${rootfs_dir}/etc/rc.d/init.d/extend-root.sh
    echo net.ipv4.conf.wlan0.rp_filter=0 >> ${rootfs_dir}/etc/sysctl.conf

    chmod +x ${rootfs_dir}/chroot.sh
    chroot ${rootfs_dir} /bin/bash -c "echo 'Y' | /chroot.sh ${spec_param}"

    LOG "Set NTP and auto expand rootfs done."

    echo "LABEL=rootfs  / ext4    defaults,noatime 0 0" > ${rootfs_dir}/etc/fstab
    echo "LABEL=boot  /boot ext2    defaults,noatime 0 2" >> ${rootfs_dir}/etc/fstab
    LOG "Set fstab done."

    # 标记"这是构建机灌出来的 rootfs"。内核 rpm 的 %pre/%post 见到它就跳过挂载检查与
    # uname_r 改写 —— 否则镜像构建时装内核包（或离线 chroot 验证）要么写进 rootfs 的
    # /boot 目录（假成功），要么因"没挂载"直接失败。首启时 firstboot.sh 负责删掉。
    #
    # 位置用 /etc/lubancat/ 而不是厂商的 /boot/build-host：真机上 /boot 是独立分区，
    # 挂载后会**盖住** rootfs 里 /boot 下的同名文件 —— 标记既看不见也删不掉。
    # /etc 在 rootfs 上，任何时刻都可见。
    mkdir -p ${rootfs_dir}/etc/lubancat
    touch ${rootfs_dir}/etc/lubancat/build-host
    LOG "mark /etc/lubancat/build-host (kernel rpm 跳过安装动作的构建机标记)"

    # 桌面相关的构建期修补（目前只有 ukui 的电源服务一项），按"装了什么组件"分派，
    # 不按镜像名、不按板名 —— 见 DESKTOP_QUIRKS() 的注释。
    # 放在 POST_BOARD_OVERLAY 之前：板级 hook 可能再装/改包，这里先做一次兜底，
    # 且此时 rootfs 仍完整可用（/dev /proc /sys 还没 umount）。
    DESKTOP_QUIRKS

    POST_BOARD_OVERLAY

    UMOUNT_ALL
    rm ${rootfs_dir}/chroot.sh
    LOG "make rootfs for ${repo_file} end."

}

mk_rootfsimg() {
    trap 'LOSETUP_D_IMG' EXIT
    rootfs_size=`du -sh --block-size=1MiB ${rootfs_dir} | cut -f 1 | xargs`
    if [ -d ${workdir}/kernel/kernel-modules/lib/modules ]; then
        mod_size=`du -sh --block-size=1MiB ${workdir}/kernel/kernel-modules/lib/modules | cut -f 1 | xargs`
    else
        mod_size=0
    fi
    size=$(($rootfs_size+$mod_size+1100))
    rootfs_img=${workdir}/rootfs.img
    dd if=/dev/zero of=${rootfs_img} bs=1MiB count=$size status=progress && sync
    mkfs.ext4 -L rootfs ${workdir}/rootfs.img

    if [ -d ${rootfs_mnt} ];then rm -rf ${rootfs_mnt}; fi
    mkdir ${rootfs_mnt}
    mount ${workdir}/rootfs.img ${rootfs_mnt}

    rsync -avHAXq ${rootfs_dir}/* ${rootfs_mnt}
    sync
    sleep 10

    LOSETUP_D_IMG

    if [ -f ${workdir}/rootfs.img ]; then
        LOG "make rootfs image done."
    else
        ERROR "make rootfs image failed!"
        exit 2
    fi

    LOG "clean rootfs directory."
    rm -rf ${rootfs_dir}
}
set -e
root_need
cur_dir=$(cd $(dirname $0);pwd)
default_param
local_param
parseargs "$@" || help $?

if [ "x${board}" == "xraspberrypi" ]; then
    rpmlist_dir=${cur_dir}/configs/raspberrypi
fi
CONFIG_RPM_LIST=${rpmlist_dir}/rpmlist

POST_BOARD_OVERLAY() {
    echo "Initial POST_BOARD_OVERLAY function" # It will be overwritten by board.conf.
}

if [[ "x$arch" == "arm64" ]]; then
    rootfs_arch="aarch64"
fi

if [ ! -d ${workdir} ]; then
    mkdir ${workdir}
fi

source ${cur_dir}/boards/${board}.conf

if [ ! -d ${log_dir} ];then mkdir -p ${log_dir}; fi
if [ ! -f ${workdir}/.done ];then
    touch ${workdir}/.done
fi
sed -i 's/rootfs//g' ${workdir}/.done
LOG "build rootfs..."
if [ -d ${rootfs_dir} ]; then
    if [[ -f ${workdir}/rootfs.img && $(cat ${workdir}/.done | grep rootfs) == "rootfs" ]];then
        if [ -f ${workdir}/.param_last ];then
            last_branch=$(cat ${workdir}/.param_last | grep branch)
            last_branch=${last_branch:7}

            last_board=$(cat ${workdir}/.param_last | grep board)
            last_board=${last_board:6}

            last_repo_file=$(cat ${workdir}/.param_last | grep repo_file)
            last_repo_file=${last_repo_file:10}

            last_spec_param=$(cat ${workdir}/.param_last | grep spec_param)
            last_spec_param=${last_spec_param:11}

            if [[ ${last_branch} != ${branch} || ${last_board} != ${board} || ${last_repo_file} != ${repo_file} || ${last_spec_param} != ${spec_param} ]]; then
                build_rootfs
                mk_rootfsimg
            fi
        fi
    else
        build_rootfs
        mk_rootfsimg
    fi
else
    build_rootfs
    mk_rootfsimg
fi
LOG "The rootfs.img is generated in the ${workdir}."
echo "rootfs" >> ${workdir}/.done
