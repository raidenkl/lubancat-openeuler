set -e
S=/work/src/SBC-sig/scripts
MNT=$S/build/rootfs_a6fix
IMG=$S/build/rootfs.img
# 清理所有可能占用 rootfs.img 的残留挂载
for m in a6check a5check a4check a4du rootmnt rootfs_apply rootfs_a6 rk_root_tmp; do
    umount $S/build/$m 2>/dev/null || true
done
mkdir -p $MNT
mount -o loop $IMG $MNT
install -m644 $S/bin/rpms/camera-engine-rkaiq-*.rpm $MNT/opt/rpms/
echo "rpm in image: $(ls -l $MNT/opt/rpms/ | tail -1)"
sync
umount $MNT
cd $S
bash gen_rk_update.sh -n openEuler-24.03-LTS-SP3-LubanCat-5-aarch64-alpha6 -b lubancat-5 > /tmp/gen-a6c.log 2>&1 || true
echo "RC=$?"
tail -14 /tmp/gen-a6c.log
