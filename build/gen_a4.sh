set -x
MNT=/work/src/SBC-sig/scripts/build/rootmnt
rm -rf ${MNT}/var/cache/dnf/* 2>/dev/null || true
sync
umount ${MNT}/run ${MNT}/dev ${MNT}/sys ${MNT}/proc 2>/dev/null || true
umount ${MNT} 2>/dev/null || true
echo "剩余 rootmnt 挂载: $(mount | grep -c "${MNT}")"
cd /work/src/SBC-sig/scripts
bash gen_rk_update.sh -n openEuler-24.03-LTS-SP3-LubanCat-5-aarch64-alpha4 -b lubancat-5 > /tmp/gen-a4.log 2>&1
echo "GEN_RC=$?"
tail -30 /tmp/gen-a4.log
