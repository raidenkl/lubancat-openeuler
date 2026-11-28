%global debug_package %{nil}
%global __os_install_post %{nil}

# kver / kv / rel 由 tools/build-kernel-rpm.sh 用 --define 传入，与 kernel-lubancat 保持一致
%{!?kver:%global kver 6.1.99-rk3588}
%{!?kv:%global kv 6.1.99}
%{!?rel:%global rel 1.lbc5.rk3588}

Name:           kernel-lubancat-modules
Version:        %{kv}
Release:        %{rel}
Summary:        LubanCat kernel modules for %{kver}
License:        GPL-2.0-only
URL:            https://gitee.com/openeuler/yocto-meta-openeuler
BuildArch:      aarch64
AutoReqProv:    no

# depmod 在 %post 里跑（板上原生执行才准）；离线 chroot 里失败不算致命，
# 因为包内已带构建期生成的 modules.dep。
Requires(post): kmod

%description
LubanCat 内核模块树 /lib/modules/%{kver}。

单独成包的原因：体积大（约 127 MiB），只在改了内核配置/驱动时才需要更新；
只改 dts 时可以只装 kernel-lubancat。两个包用精确版本互相锁定，避免
"Image 新 / 模块旧"导致根挂不上。

%install
rm -rf %{buildroot}
SRC=%{_sourcedir}/modules/%{kver}

[ -d "$SRC" ] || { echo "ERROR: 缺模块树 $SRC（先跑 tools/build-image.sh --stage kernel）" >&2; exit 1; }

install -d %{buildroot}/lib/modules
cp -a "$SRC" %{buildroot}/lib/modules/

# build/source 是指向构建机内核源码树的软链，带上板毫无意义且会指向不存在的路径
rm -f %{buildroot}/lib/modules/%{kver}/build %{buildroot}/lib/modules/%{kver}/source

%pre
if [ -f /etc/lubancat/build-host ]; then
    echo "kernel-lubancat-modules: /etc/lubancat/build-host 存在（构建机或离线 chroot），跳过检查"
    exit 0
fi
# modules 装到 rootfs，不依赖 /boot 挂载；这里只提示空间，不阻断
avail=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$avail" ] || avail=0
if [ "$avail" -lt 300 ]; then
    echo "WARN: / 剩余 ${avail} MiB，模块树约 127 MiB，若装完后空间紧张请先清理旧内核" >&2
fi

%post
if [ -f /etc/lubancat/build-host ]; then
    echo "kernel-lubancat-modules: /etc/lubancat/build-host 存在，跳过 depmod"
    exit 0
fi
if command -v depmod >/dev/null 2>&1; then
    # 包内已带构建期的 modules.dep；这里只是按板上实际情况刷新。
    # 失败不阻断安装（模块文件本身是完整的），但要让人看见。
    depmod -a %{kver} || echo "WARN: depmod %{kver} 失败，模块依赖可能过期（可手工重跑）" >&2
else
    echo "WARN: 没有 depmod（kmod 未装），跳过" >&2
fi
echo "kernel-lubancat-modules: %{kver} 已安装（$(find /lib/modules/%{kver} -name '*.ko*' 2>/dev/null | wc -l) 个模块）"

%files
%defattr(-,root,root,-)
/lib/modules/%{kver}

%changelog
* Sat Nov 28 2026 LubanCat <dev@lubancat> - %{kv}-%{rel}
- initial kernel modules rpm for extboot layout
