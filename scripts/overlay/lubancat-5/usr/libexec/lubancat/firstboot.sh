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

# 1) machine-id（正常由 systemd 首启动生成，这里兜底）
if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup 2>/dev/null || true
fi
MID=$(cat /etc/machine-id 2>/dev/null)
if [ -z "$MID" ]; then
    MID=$(head -c 16 /dev/urandom | md5sum | cut -c1-32)
    printf "%s\n" "$MID" > /etc/machine-id
fi

# 2) 唯一主机名：LubanCat-<board>-<machine-id 前 6 位>
BOARD=LubanCat-5
HN="${BOARD}-$(printf "%s" "$MID" | cut -c1-6)"
if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$HN" 2>/dev/null || {
        echo "$HN" > /etc/hostname
        hostname "$HN" 2>/dev/null || true
    }
else
    echo "$HN" > /etc/hostname
fi

# 3) /etc/hosts 的 127.0.1.1 条目同步
sed -i "/127\.0\.1\.1/d" /etc/hosts 2>/dev/null || true
printf "127.0.1.1\t%s\n" "$HN" >> /etc/hosts

# 4) SSH 主机密钥兜底（sshd-keygen@ 实例已在 Wants 链上，此处保险）
ssh-keygen -A >/dev/null 2>&1 || true

echo "$HN" > "$MARK"
echo "firstboot: hostname=$HN machine-id=${MID:0:12}..."
exit 0
