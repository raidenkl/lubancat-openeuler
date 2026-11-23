#!/bin/bash
# 把多媒体三件套固化进现有 rootfs.img（等价 POST_BOARD_OVERLAY），并打 alpha6
set -e
S=/work/src/SBC-sig/scripts
MNT=$S/build/rootfs_a6
IMG=$S/build/rootfs.img
MULTI=$S/bin/multimedia

umount $MNT 2>/dev/null || true
mkdir -p $MNT
mount -o loop $IMG $MNT
echo "mounted"

# RGA（2.2.0）
install -Dm755 $MULTI/rga/librga.so.2.1.0 $MNT/usr/lib64/librga.so.2.1.0
ln -sf librga.so.2.1.0 $MNT/usr/lib64/librga.so.2
echo "RGA: $(ls -l $MNT/usr/lib64/librga.so.2 | awk '{print $NF}')"

# MPP：实体 .so.0，SONAME .so.1
install -Dm755 $MULTI/mpp/librockchip_mpp.so.0 $MNT/usr/lib64/librockchip_mpp.so.0
ln -sf librockchip_mpp.so.0 $MNT/usr/lib64/librockchip_mpp.so.1
ln -sf librockchip_mpp.so.1 $MNT/usr/lib64/librockchip_mpp.so
install -Dm755 $MULTI/mpp/librockchip_vpu.so.0 $MNT/usr/lib64/librockchip_vpu.so.0
ln -sf librockchip_vpu.so.0 $MNT/usr/lib64/librockchip_vpu.so.1
ln -sf librockchip_vpu.so.1 $MNT/usr/lib64/librockchip_vpu.so
echo "MPP: $(ls $MNT/usr/lib64/librockchip_mpp.so* | wc -l) links"

# gst 插件
install -d $MNT/usr/lib64/gstreamer-1.0
for f in $MULTI/gst/*.so; do
    install -m755 "$f" "$MNT/usr/lib64/gstreamer-1.0/$(basename "$f")"
done
echo "gst: $(ls $MNT/usr/lib64/gstreamer-1.0/libgst*rockchip* $MNT/usr/lib64/gstreamer-1.0/libgstrkx* 2>/dev/null | wc -l) plugins"

# demos
install -d $MNT/usr/bin
for f in $MULTI/demos/*; do install -m755 "$f" "$MNT/usr/bin/"; done
echo "demos: $(ls $MNT/usr/bin/mpi_* $MNT/usr/bin/mpp_info_test $MNT/usr/bin/vpu_api_test 2>/dev/null | wc -l) tools"

# udev 规则
install -Dm644 $MULTI/rules/99-rockchip-permissions.rules $MNT/etc/udev/rules.d/99-rockchip-permissions.rules
echo "udev rule installed"

# 摄像头 RPM 预置
install -d $MNT/opt/rpms
install -m644 $S/bin/rpms/camera-engine-rkaiq-*.rpm $MNT/opt/rpms/
echo "rpm seeded: $(ls $MNT/opt/rpms/)"

# 刷新 ld.so.cache（容器有 qemu binfmt，失败不阻塞）
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    chroot $MNT /usr/sbin/ldconfig 2>/dev/null && echo "ldconfig done" || echo "WARN: chroot ldconfig skipped"
fi

sync
umount $MNT
echo "rootfs patched"

cd $S
bash gen_rk_update.sh -n openEuler-24.03-LTS-SP3-LubanCat-5-aarch64-alpha6 -b lubancat-5 > /tmp/gen-a6.log 2>&1
echo "GEN_RC=$?"
tail -18 /tmp/gen-a6.log
