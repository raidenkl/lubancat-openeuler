#!/bin/bash
# 把 A1/A2/A3/A4/A5/C1 应用到现有 rootfs.img（等价于 POST_BOARD_OVERLAY 的效果），
# 然后打 alpha5。用于在不想重跑 build_rootfs 的情况下快速出镜像。
set -e
S=/work/src/SBC-sig/scripts
MNT=$S/build/rootfs_apply
IMG=$S/build/rootfs.img

umount $MNT 2>/dev/null || true
mkdir -p $MNT
mount -o loop $IMG $MNT
echo "mounted $IMG"

# A1: mali 包（内含 libmali-hook.so.1.9.0）
tar xzf $S/bin/libmali/mali-g610-g24p0.tar.gz -C $MNT
echo "A1 done: $(ls $MNT/usr/lib64/mali/libmali-hook* 2>/dev/null | wc -l) hook files"

# A2: 去掉全局 LD_LIBRARY_PATH，改为按需 mali-env
rm -f $MNT/etc/profile.d/mali.sh
mkdir -p $MNT/usr/local/bin
cat > $MNT/usr/local/bin/mali-env <<'EOS'
#!/bin/sh
# 按需启用 Mali GPU（EGL/GLES，GBM/Wayland 平台）。X11 桌面仍走 mesa/llvmpipe。
# 用法：mali-env <命令>   例如 mali-env eglinfo
export LD_LIBRARY_PATH=/usr/lib64/mali${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
exec "$@"
EOS
chmod 755 $MNT/usr/local/bin/mali-env
echo "A2 done"

# A3: 补齐空的光标主题
if [ -d "$MNT/usr/share/icons/Adwaita/cursors" ]; then
    for ct in breeze breeze-dark ukui ukui-classical; do
        cdir="$MNT/usr/share/icons/$ct/cursors"
        if [ -d "$MNT/usr/share/icons/$ct" ] && [ -z "$(ls -A "$cdir" 2>/dev/null)" ]; then
            rm -rf "$cdir"
            cp -a "$MNT/usr/share/icons/Adwaita/cursors" "$cdir"
        fi
    done
    echo "A3 done: $(for t in breeze ukui; do printf '%s=%s ' $t $(ls $MNT/usr/share/icons/$t/cursors 2>/dev/null | wc -l); done)"
fi

# A4: 光标主题配置
mkdir -p $MNT/etc/xdg $MNT/etc/skel/.config
printf '[Mouse]\ncursorTheme=Adwaita\ncursorSize=24\n' > $MNT/etc/xdg/kcminputrc
printf '[$Version]\nupdate_info_kcminputrc=1\n\n[Mouse]\ncursorTheme=Adwaita\ncursorSize=24\n' > $MNT/etc/skel/.config/kcminputrc
grep -q XCURSOR_THEME $MNT/etc/environment 2>/dev/null || printf 'XCURSOR_THEME=Adwaita\nXCURSOR_SIZE=24\n' >> $MNT/etc/environment
echo "A4 done"

# A5: lightdm 自动登录
mkdir -p $MNT/etc/lightdm/lightdm.conf.d
cat > $MNT/etc/lightdm/lightdm.conf.d/50-autologin.conf <<'EOS'
[Seat:*]
autologin-user=lubancat
autologin-user-timeout=0
autologin-session=ukui
EOS
echo "A5 done"

# C1: NPU 运行时
install -Dm755 $S/bin/npu/librknnrt.so $MNT/usr/lib64/librknnrt.so
echo "C1 done: $(stat -c %s $MNT/usr/lib64/librknnrt.so) bytes"

sync
umount $MNT
echo "rootfs patched"

cd $S
bash gen_rk_update.sh -n openEuler-24.03-LTS-SP3-LubanCat-5-aarch64-alpha5 -b lubancat-5 > /tmp/gen-a5.log 2>&1
echo "GEN_RC=$?"
tail -20 /tmp/gen-a5.log
