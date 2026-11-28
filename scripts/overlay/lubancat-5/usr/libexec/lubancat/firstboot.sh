#!/bin/bash
# SPDX-FileCopyrightText: 2026 raidenkl
# SPDX-License-Identifier: MulanPSL-2.0
#
# firstboot.sh —— 首启动唯一化：machine-id / 主机名 / SSH 主机密钥。
# 由 lubancat-firstboot.service 触发，ConditionFirstBoot=yes 保证只跑一次。
#
# 背景：镜像里的 machine-id 与 SSH 主机私钥是固定值，多台设备刷同一镜像
# 会共享同一 machine-id（日志/DHCP 冲突）与同一 SSH 主机密钥（中间人风险）。
set -e

MARK=/var/lib/lubancat/firstboot.done
mkdir -p /var/lib/lubancat

# 0) 删掉构建机标记：镜像里的 /etc/lubancat/build-host 用来让内核 rpm 在构建机/离线
#    chroot 里跳过安装动作（不改 uname_r、不 depmod）。留着会让板上
#    `rpm -ivh kernel-lubancat` 静默什么都不做。
#
#    为什么不是厂商的 /boot/build-host：真机上 /boot 是独立分区，挂载后会盖住 rootfs
#    里 /boot 下的同名文件，标记既看不见也删不掉。
rm -f /etc/lubancat/build-host

# 1) machine-id（正常由 systemd 首启动生成，这里兜底）
if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup 2>/dev/null || true
fi
MID=$(cat /etc/machine-id 2>/dev/null)
if [ -z "$MID" ]; then
    MID=$(head -c 16 /dev/urandom | md5sum | cut -c1-32)
    printf "%s\n" "$MID" > /etc/machine-id
fi

# 2) 唯一主机名：<板型>-<machine-id 前 6 位>
# 板型名由 lubancat-board-init.sh 从厂商映射表写入；表里有带空格的（"LubanCat-3 v2"），
# 空格换成 - 才能当主机名。文件缺失时退回不带板型的通用前缀。
BOARD=$(cat /etc/lubancat/board-name 2>/dev/null | tr " " "-" | tr -d "\n")
[ -n "$BOARD" ] || BOARD=LubanCat
HN="${BOARD}-$(printf "%s" "$MID" | cut -c1-6)"
# hostnamectl 走 D-Bus；若 D-Bus/polkit 还没就绪会一直阻塞（曾因 udev-settle 卡住
# sysinit.target 而等了 92s）。加超时兜底，超时就退回直接写 /etc/hostname。
if command -v hostnamectl >/dev/null 2>&1; then
    timeout 10 hostnamectl set-hostname "$HN" 2>/dev/null || {
        echo "$HN" > /etc/hostname
        hostname "$HN" 2>/dev/null || true
    }
else
    echo "$HN" > /etc/hostname
fi

# 3) /etc/hosts 的 127.0.1.1 条目同步
sed -i "/127\.0\.1\.1/d" /etc/hosts 2>/dev/null || true
printf "127.0.1.1\t%s\n" "$HN" >> /etc/hosts

# 4) SSH 主机密钥：交给 sshd-keygen@ 实例（sshd.service 会 Wants=sshd-keygen.target）。
# 这里不要再跑 ssh-keygen -A —— 与 sshd-keygen@rsa 并发写同一个密钥文件，
# 实测会让 sshd-keygen@rsa.service 失败（Failed to start OpenSSH rsa Server Key Generation）。

echo "$HN" > "$MARK"
echo "firstboot: hostname=$HN machine-id=${MID:0:12}..."
exit 0
