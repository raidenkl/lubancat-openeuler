B=/work/src/SBC-sig/scripts/build
MNT=$B/a4du
umount $MNT 2>/dev/null || true
mkdir -p $MNT
mount -o loop,ro $B/rkpack/Image/rootfs.img $MNT
echo "== 顶层大目录 =="
du -sh --exclude=proc --exclude=sys --exclude=dev $MNT/* 2>/dev/null | sort -h | tail -12
echo "== var 细分 =="
du -sh $MNT/var/* 2>/dev/null | sort -h | tail -8
echo "== usr 细分 =="
du -sh $MNT/usr/* 2>/dev/null | sort -h | tail -8
sync
umount $MNT
