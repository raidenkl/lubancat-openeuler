# 发布流程

## 版本号

预发布阶段 `0.x.y`，tag 形如 `v0.6.0-alpha6`。

- `v<MAJOR>.<MINOR>.<PATCH>-<stage><n>`
- `stage`：`alpha` → `beta` → `rc`
- 稳定版去掉后缀：`v0.6.0`
- 不要用裸 `alpha6`：字符串排序会把 `alpha10` 排在 `alpha6` 前面，且 `git describe` 失去语义

## 镜像分发方式

> **镜像不进仓库，也不上传到 GitHub Release。**

经评估，2 GiB 级别的镜像不适合放在代码仓库的 Release 里：占用配额、无法增量、
与代码 tag 的生命周期不一致。当前策略：

| 内容 | 存放位置 |
|---|---|
| 源码、板级配置、厂商二进制 | 本仓库（git） |
| 构建产物 `.img.xz`（约 1.9 GiB） | 构建机 `scripts/build/<日期>/`，经内部渠道分发 |
| 校验信息 | 本仓库 `manifests/`（sha256、构建摘要），随 tag 固定 |

因此仓库里**只有可复现的构建输入**，镜像通过「tag + manifests + 内部渠道」三者对齐。
任何人拿到 tag 后都能用 `scripts/fetch-sources.sh` + `scripts/build.sh` 复现出同一个镜像。

## 发布步骤

1. **更新 CHANGELOG**：在 `[Unreleased]` 下方新增版本段，写清「镜像信息（大小 / sha256 /
   rootfs UUID）、验证结果、已知问题、升级说明」
2. **同步 manifests**：把本次构建的 `source-lock.yaml`、`<版本>-summary.txt` 与 `.sha256sum`
   提交进 `manifests/`
3. **提交**：`git commit -m "docs(changelog): v0.6.0-alpha6"`
4. **打 tag**：
   ```bash
   git tag -a v0.6.0-alpha6 -m "v0.6.0-alpha6: LubanCat-5 (RK3588) first public alpha"
   git push origin main
   git push origin v0.6.0-alpha6      # 只推该 tag，不要 --tags
   ```
5. **分发镜像**：通过内部渠道发出 `.img.xz` 与 `SHA256SUMS`，并注明对应的 tag，
   便于接收方反查源码版本
6. **可选：建 GitHub Release**，只写发布说明（变更摘要、已知问题、烧写步骤），
   **不挂任何镜像资产**；如需固定镜像校验值，把 sha256 写进 Release 描述正文

## 镜像命名与 tag 的对应

镜像文件名与 tag 逐字符对应，便于「镜像名 → tag → commit」反查：

```
lubancat-5_openEuler-24.03-LTS_aarch64_v0.6.0-alpha6.img.xz
```

## 分批推送

首次推送分两批，给自己留核对窗口：

```bash
git push -u origin main
git push origin v0.6.0-alpha6
```

不要用 `git push --all` / `--tags`。

## 多板发布

同一 tag 下多块板各自一个镜像文件，用前缀区分：

```
lubancat-5_..._v0.7.0.img.xz
lubancat-4_..._v0.7.0.img.xz
```

`SHA256SUMS` 汇总全部镜像，与源码 tag 一起归档；Release 说明里注明每块板的
验证项与已知差异（同样不挂镜像资产）。

## 可复现性校验

拿到 tag 后在一台干净机器上：

```bash
git clone --branch v0.6.0-alpha6 git@github.com:raidenkl/lubancat-openeuler.git
cd lubancat-openeuler
./scripts/fetch-sources.sh
sudo ./scripts/build.sh -b lubancat-5 -s "$PWD/scripts/configs/common/rpmlist-lubancat-desktop"
sha256sum scripts/build/*/*.img.xz      # 与 manifests/ 记录比对
```

时间戳类差异可能导致 `.img` 不完全一致，此时比对 `manifests/<版本>-summary.txt`
里的关键字段（rootfs UUID、模块数量、包清单）作为等效判据。
