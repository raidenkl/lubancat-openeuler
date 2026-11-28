echo [boot.cmd] LubanCat extboot boot script
setenv initrd_size 0

# 1) 读 uEnv.txt（固定路径；板型差异由 board-init 在用户态改这个文件来切换）
if test -e ${devtype} ${devnum}:${distro_bootpart} /uEnv/uEnv.txt; then
  load ${devtype} ${devnum}:${distro_bootpart} ${env_addr_r} /uEnv/uEnv.txt
  # 记下真实文件长度：dtfile 会把 env 的 size 当 uEnv.txt 的文本长度，见第 7 步
  setenv uenv_size ${filesize}
  env import -t ${env_addr_r} 0x8000
else
  echo [boot.cmd] no /uEnv/uEnv.txt, fallback to extlinux
  exit 1
fi

# 2) 组装 bootargs：cmdline 已含 root=UUID=（构建期写入），这里只补 boot_part
setenv bootargs ${cmdline} boot_part=${distro_bootpart}

# 3) initrd（可选，三级回退）
#    1) uEnv 里的 initrd=  —— 新镜像写的是 initrd-<uname_r>（版本化：回滚时"旧 Image + 新 initrd"
#       会因为模块路径对不上而挂不住根，版本化才能一起回退）
#    2) /initrd-<uname_r>  —— uEnv 还写着旧值 initrd.img、但盘上已经是版本化文件名
#    3) /initrd.img        —— 老镜像 / 兜底
#    先显式置 0：下面 booti 用 ${initrd_size} != 0 判断要不要带 initrd，
#    变量未定义时 hush 会把它展开成空串，`test  != 0` 直接报语法错。
setenv initrd_size 0
if test -n "${initrd}"; then
  if load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /${initrd}; then
    setenv initrd_size ${filesize}
    echo [boot.cmd] load /${initrd}
  fi
fi
if test "${initrd_size}" = "0" && test -n "${uname_r}"; then
  if load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /initrd-${uname_r}; then
    setenv initrd_size ${filesize}
    echo [boot.cmd] load /initrd-${uname_r}
  fi
fi
if test "${initrd_size}" = "0"; then
  if load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /initrd.img; then
    setenv initrd_size ${filesize}
    echo [boot.cmd] load /initrd.img (fallback)
  fi
fi

# 4) 内核：优先 /Image-<uname_r>（版本化，支持多版本共存与回滚），回退 /Image
#    顺序与厂商 boot.cmd 一致：uname_r 决定加载哪个 Image-<版本>，改 uEnv 就能切内核。
#    旧版本镜像只有 /Image（没有版本化文件），走回退分支仍能启动，所以是加法不是替换。
#    注意：构建期只产出 /Image-<版本> 一份，不再额外拷一份 /Image 占掉 ~43 MB boot 空间。
if test -n "${uname_r}" && test -e ${devtype} ${devnum}:${distro_bootpart} /Image-${uname_r}; then
  echo [boot.cmd] load /Image-${uname_r}
  load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /Image-${uname_r}
else
  echo [boot.cmd] load /Image (fallback, uname_r=${uname_r})
  load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /Image
fi

# 5) 板级 dtb（固定路径，实际指向由 board-init 决定）
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} /rk-kernel.dtb

# 6) 写 bootargs 进 DT
#    先 fdt resize 扩出空间：cmdline 较长时 fdt set 会报 FDT_ERR_NOSPACE 而静默失败
fdt addr ${fdt_addr_r}
fdt resize 0x10000
fdt set /chosen bootargs ${bootargs}

# 7) 记下 dtbo 所在分区（dtoverlay/dtoverlay.c 与 gsdt 段都要用）
#    dtoverlay/dtoverlay.c 用 env_get("devtype") + env_get("dev_bootpart") 定位 dtbo 所在分区。
#    distro boot 只设 devtype/devnum，不会设 dev_bootpart；缺这行会输出 "mmc <NULL>"、
#    读 dtbo 失败（err -9），随后 fdt_overlay_apply 作用在垃圾数据上触发 SError 复位。
setenv dev_bootpart ${devnum}:${distro_bootpart}

# 8) 应用 uEnv 里的 dtoverlay（dtfile 解析 #overlay_start..#overlay_end）
if test "${enable_uboot_overlays}" = "1"; then
  echo [boot.cmd] applying overlays from /uEnv/uEnv.txt

  # dtfile（cmd/dtfile.c:38-47）把 env 的 size 当成 uEnv.txt 的**文本长度**：
  # 先 malloc(size+1) 再 memcpy(size) 字节去解析。uEnv 模板里的 size=0x1000000（16MiB）
  # 一旦拿不到整块连续堆，malloc 就失败；而 dtfile 失败也 return 0（看着像成功），
  # overlay 会全部静默跳过，串口只留一句 "can't malloc 16777217 bytes"。
  # 构建期已把 uEnv 的 size 改成 0x8000；这里再用刚记下的真实文件长度覆盖（双保险）。
  setenv size 0x8000
  if test -n "${uenv_size}"; then
    setenv size ${uenv_size}
  fi

  dtfile ${fdt_addr_r} ${fdt_over_addr} /uEnv/uEnv.txt ${env_addr_r}
  echo [boot.cmd] overlays applied, size=${size}
fi

# 9) 通用屏自动适配（移植自厂商 boot.cmd，与文档 5.3 节同构）
#    读显示模组背板 EEPROM（i2c_devs 里的每个总线，地址 eeprom_addr），读到就按序
#    叠 gsdt_plugin0 / gsdt_plugin1（dsi0 / dsi1 的 generic overlay），实现"插上就亮"。
#    - 生效条件：uEnv 里 enable_gsdt_auto_load=1（构建期默认写 0，见 build_boot.sh）
#    - 用 && 串联所有前置条件：i2c 命令缺失、总线不存在、EEPROM 无应答时整段跳过
if test "${enable_gsdt_auto_load}" = "1" && test -n "${i2c_devs}"; then
  i2c bus
  if test $? -eq 0; then
    echo [boot.cmd] screen eeprom scan: ${i2c_devs} addr=${eeprom_addr}
    setenv i2c_idx 0
    for dev in ${i2c_devs}; do
      i2c dev ${dev}
      i2c md "${eeprom_addr}" 0 1
      if test $? -eq 0; then
        setenv plugin_file
        if test "${i2c_idx}" = "0"; then
          setenv plugin_file "${gsdt_plugin0}"
        elif test "${i2c_idx}" = "1"; then
          setenv plugin_file "${gsdt_plugin1}"
        fi
        if test -n "${plugin_file}"; then
          echo [boot.cmd] apply screen plugin: ${plugin_file}
          load ${devtype} ${devnum}:${distro_bootpart} ${fdt_over_addr} ${plugin_file}
          if test $? -eq 0; then
            fdt apply ${fdt_over_addr}
          fi
        fi
      fi
      if test "${i2c_idx}" = "0"; then
        setenv i2c_idx 1
      fi
    done
  fi
fi

# 10) 启动
if test ${initrd_size} != 0; then
  booti ${kernel_addr_r} ${ramdisk_addr_r}:${initrd_size} ${fdt_addr_r}
else
  booti ${kernel_addr_r} - ${fdt_addr_r}
fi
