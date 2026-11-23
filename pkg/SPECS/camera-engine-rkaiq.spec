%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           camera-engine-rkaiq
Version:        6.9.0
Release:        1.lbc5
Summary:        Rockchip ISP 3A engine (rkaiq) for RK3588 / LubanCat 5
License:        GPL-2.0-or-later
URL:            https://github.com/rockchip-linux/camera_engine_rkaiq
BuildArch:      aarch64
AutoReqProv:    no
Requires:       glibc >= 2.17
Requires:       libstdc++
Requires(post): systemd
Requires(preun): systemd

%description
RKAIQ 3A server (AE/AWB/AF) plus librkaiq and the IQ tuning database for
Rockchip RK3588 (rkisp_v6 on LubanCat 5).

All 14 IQ json files shipped by the vendor SDK are bundled, so besides the
default IMX415 module these sensors work without repackaging:
gc08a8, gc2053, gc4653, gc8034, imx327, imx415, imx464, os04a10,
os04a10hk, ov02b10, ov13855, ov50c40, ov8858, s5kjn1.

%install
rm -rf %{buildroot}
install -Dm755 %{_sourcedir}/camera-engine-rkaiq/usr/bin/rkaiq_3A_server %{buildroot}/usr/bin/rkaiq_3A_server
install -Dm755 %{_sourcedir}/camera-engine-rkaiq/usr/lib/librkaiq.so       %{buildroot}/usr/lib64/librkaiq.so
install -Dm755 %{_sourcedir}/camera-engine-rkaiq/usr/lib/libIspFec.so      %{buildroot}/usr/lib64/libIspFec.so
install -Dm755 %{_sourcedir}/camera-engine-rkaiq/usr/lib/libsmartIr.so     %{buildroot}/usr/lib64/libsmartIr.so
install -Dm755 %{_sourcedir}/camera-engine-rkaiq/usr/lib/librkrawstream.so %{buildroot}/usr/lib64/librkrawstream.so
install -d %{buildroot}/etc/iqfiles
install -m644 %{_sourcedir}/camera-engine-rkaiq/etc/iqfiles/*.json %{buildroot}/etc/iqfiles/
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
/usr/lib64/librkaiq.so
/usr/lib64/libIspFec.so
/usr/lib64/libsmartIr.so
/usr/lib64/librkrawstream.so
/etc/iqfiles/*.json
/usr/lib/systemd/system/rkaiq_3A.service

%changelog
* Mon Nov 23 2026 LubanCat openEuler Port <dev@localhost> - 6.9.0-1.lbc5
- Initial package: rkaiq 3A server + librkaiq + all 14 vendor IQ json files
