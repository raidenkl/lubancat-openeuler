echo [boot.cmd] LubanCat extboot boot script
setenv initrd_size 0

# 1) 读 uEnv.txt（固定路径；板型差异由 board-init 在用户态改这个文件来切换）
if test -e ${devtype} ${devnum}:${distro_bootpart} /uEnv/uEnv.txt; then
  load ${devtype} ${devnum}:${distro_bootpart} ${env_addr_r} /uEnv/uEnv.txt
  env import -t ${env_addr_r} 0x8000
else
  echo [boot.cmd] no /uEnv/uEnv.txt, fallback to extlinux
  exit 1
fi

# 2) 组装 bootargs：cmdline 已含 root=UUID=（构建期写入），这里只补 boot_part
setenv bootargs ${cmdline} boot_part=${distro_bootpart}

# 3) initrd（可选）
if test -n "${initrd}"; then
  if load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /${initrd}; then
    setenv initrd_size ${filesize}
  fi
fi

# 4) 内核：优先 /Image，回退 /Image-<uname_r>
if test -e ${devtype} ${devnum}:${distro_bootpart} /Image; then
  load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /Image
else
  load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /Image-${uname_r}
fi

# 5) 板级 dtb（固定路径，实际指向由 board-init 决定）
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} /rk-kernel.dtb

# 6) 写 bootargs 进 DT
#    先 fdt resize 扩出空间：cmdline 较长时 fdt set 会报 FDT_ERR_NOSPACE 而静默失败
fdt addr ${fdt_addr_r}
fdt resize 0x10000
fdt set /chosen bootargs ${bootargs}

# 7) 应用 uEnv 里的 dtoverlay（dtfile 解析 #overlay_start..#overlay_end）
if test "${enable_uboot_overlays}" = "1"; then
  echo [boot.cmd] applying overlays from /uEnv/uEnv.txt
  # dtoverlay/dtoverlay.c 用 env_get("devtype") + env_get("dev_bootpart") 定位 dtbo 所在分区。
  # distro boot 只设 devtype/devnum，不会设 dev_bootpart；缺这行会输出 "mmc <NULL>"、
  # 读 dtbo 失败（err -9），随后 fdt_overlay_apply 作用在垃圾数据上触发 SError 复位。
  setenv dev_bootpart ${devnum}:${distro_bootpart}
  dtfile ${fdt_addr_r} ${fdt_over_addr} /uEnv/uEnv.txt ${env_addr_r}
fi

# 8) 启动
if test ${initrd_size} != 0; then
  booti ${kernel_addr_r} ${ramdisk_addr_r}:${initrd_size} ${fdt_addr_r}
else
  booti ${kernel_addr_r} - ${fdt_addr_r}
fi
