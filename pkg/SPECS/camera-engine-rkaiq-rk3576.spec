%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           camera-engine-rkaiq-rk3576
Version:        6.9.0
Release:        1.lbc5.rk3576
Summary:        Rockchip ISP 3A engine (rkaiq) for RK3576 / LubanCat 3
License:        GPL-2.0-or-later
URL:            https://github.com/rockchip-linux/camera_engine_rkaiq
BuildArch:      aarch64
AutoReqProv:    no
Requires:       glibc >= 2.17
Requires:       libstdc++
Requires:       libdrm
Requires(post): systemd
Requires(preun): systemd
Conflicts:      camera-engine-rkaiq

%description
RKAIQ 3A server (AE/AWB/AF) plus librkaiq and the IQ tuning database for
Rockchip RK3576 (rkisp_v39 on LubanCat 3).

This is the rk3576 build; it conflicts with the rk3588 package because both
install /usr/bin/rkaiq_3A_server and /etc/iqfiles.

The 12 IQ json files shipped by the vendor SDK are bundled:
gc05a2, gc08a8, gc2053, gc4653, imx415, imx464, os04a10, ov16880,
ov8858, ox03c10, s5k4h5yb, sc4336.

%install
rm -rf %{buildroot}
install -Dm755 %{_sourcedir}/camera-engine-rkaiq-rk3576/usr/bin/rkaiq_3A_server   %{buildroot}/usr/bin/rkaiq_3A_server
install -Dm755 %{_sourcedir}/camera-engine-rkaiq-rk3576/usr/bin/rkaiq_tool_server %{buildroot}/usr/bin/rkaiq_tool_server
install -Dm755 %{_sourcedir}/camera-engine-rkaiq-rk3576/usr/lib/librkaiq.so       %{buildroot}/usr/lib64/librkaiq.so
install -Dm755 %{_sourcedir}/camera-engine-rkaiq-rk3576/usr/lib/libIspFec.so      %{buildroot}/usr/lib64/libIspFec.so
install -Dm755 %{_sourcedir}/camera-engine-rkaiq-rk3576/usr/lib/libsmartIr.so     %{buildroot}/usr/lib64/libsmartIr.so
install -Dm755 %{_sourcedir}/camera-engine-rkaiq-rk3576/usr/lib/librkrawstream.so %{buildroot}/usr/lib64/librkrawstream.so
install -d %{buildroot}/etc/iqfiles
install -m644 %{_sourcedir}/camera-engine-rkaiq-rk3576/etc/iqfiles/*.json %{buildroot}/etc/iqfiles/
install -Dm644 %{_sourcedir}/rkaiq_3A.service %{buildroot}/usr/lib/systemd/system/rkaiq_3A.service

%post
/usr/sbin/ldconfig || :
/usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :
/usr/bin/systemctl enable --now rkaiq_3A.service >/dev/null 2>&1 || :

%preun
if [ "$1" -eq 0 ]; then
    /usr/bin/systemctl disable --now rkaiq_3A.service >/dev/null 2>&1 || :
fi

%postun
/usr/sbin/ldconfig || :
/usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :

%files
%defattr(-,root,root,-)
/usr/bin/rkaiq_3A_server
/usr/bin/rkaiq_tool_server
/usr/lib64/librkaiq.so
/usr/lib64/libIspFec.so
/usr/lib64/libsmartIr.so
/usr/lib64/librkrawstream.so
/etc/iqfiles/*.json
/usr/lib/systemd/system/rkaiq_3A.service

%changelog
* Tue Nov 24 2026 LubanCat openEuler Port <dev@localhost> - 6.9.0-1.lbc5.rk3576
- Initial rk3576 package: rkaiq 3A server (rkisp_v39) + librkaiq + 12 vendor IQ json
