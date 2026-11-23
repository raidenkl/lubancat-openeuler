# 安全说明

> [!WARNING]
> 本工程产出的镜像是**开发/评测镜像**，默认配置不适合生产环境。

## 出厂默认值

| 项 | 值 | 位置 |
|---|---|---|
| 桌面用户 | `lubancat` | `scripts/boards/lubancat-5.conf` |
| 用户口令 | `lubancat`（SHA-512，salt `Sbc2026`） | 同上，`openssl passwd -6` |
| root 口令 | `openeuler` | `scripts/chroot.sh` |
| sudo | `lubancat ALL=(ALL) NOPASSWD:ALL` | `scripts/boards/lubancat-5.conf` |
| 桌面登录 | lightdm 自动登录，免密 | `50-autologin.conf` |
| sshd | `PermitRootLogin yes`，允许密码登录 | 沿用 openEuler 默认 |

镜像公开分发意味着 `/etc/shadow` 中的哈希对任何人可见，本身可离线爆破。
第一性风险不是「仓库泄露」，而是**用户刷机后不修改默认口令**。

## 首次部署必做

1. 修改 `lubancat` 与 `root` 口令
2. 删除或收紧 `/etc/sudoers.d/lubancat` 的 NOPASSWD
3. 关闭自动登录：删除 `/etc/lightdm/lightdm.conf.d/50-autologin.conf`
4. 收紧 SSH：`PermitRootLogin prohibit-password`、`PasswordAuthentication no`
5. 不要在不可信网络中长期开机

## 可选：构建时注入口令

若不想使用仓库内的默认值，可在构建环境中覆盖（不改变默认行为）：

```bash
export LUBANCAT_DEFAULT_PASS='<your-password>'
export LUBANCAT_SALT="$(openssl rand -hex 8)"
```

`scripts/boards/lubancat-5.conf` 已按此方式参数化，未设置时回落到默认值。

> 注意：`Sbc2026` 这个 salt 只用于默认口令。**禁止**把它复用为任何其它用途的
> salt 或密钥材料。

## 已知未修复项（截至 v0.6.0-alpha6）

- `scripts/bin/libmali/*.tar.gz` 内含 `./`、`./etc/`、`./usr/` 目录条目，
  解包时会把 `/`、`/etc`、`/usr`、`/usr/lib64` 的属主改成 uid 1000、权限 775。
  板上 uid 1000 为桌面用户 → **等价免密提权**。
  修复方式：重打 tar（`--owner=0 --group=0`）+ 解包加 `--no-same-owner`
  + overlay 末尾 `chown root:root` 兜底 + `rpm -V filesystem` 自检。
- 镜像内 `machine-id` 与 SSH 主机私钥为固定值，多台设备相同；
  正式发布前需改为首启动生成。
- 无 swap/zram；CPU governor 固定 `performance`。
