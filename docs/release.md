# 发布流程

## 版本号

预发布阶段 `0.x.y`，tag 形如 `v0.6.0-alpha6`。

- `v<MAJOR>.<MINOR>.<PATCH>-<stage><n>`
- `stage`：`alpha` → `beta` → `rc`
- 稳定版去掉后缀：`v0.6.0`
- 不要用裸 `alpha6`：字符串排序会把 `alpha10` 排在 `alpha6` 前面，且 `git describe` 失去语义

镜像文件名与 tag 逐字符对应，便于「镜像名 → tag → commit」反查：

```
lubancat-5_openEuler-24.03-LTS_aarch64_v0.6.0-alpha6.img.xz
```

## 发布步骤

1. **冻结**：`git switch -c release/v0.6`（仅在需要并行维护旧版时才开）
2. **更新 CHANGELOG**：在 `[Unreleased]` 下方新增版本段，补「镜像信息 / 已知问题 / 升级说明」
3. **提交**：`git commit -m "docs(changelog): v0.6.0-alpha6"`
4. **打 tag**：
   ```bash
   git tag -a v0.6.0-alpha6 -m "v0.6.0-alpha6: LubanCat-5 (RK3588) first public alpha"
   git push origin main
   git push origin v0.6.0-alpha6      # 只推该 tag，不要 --tags
   ```
5. **建 Release**：tag 选 `v0.6.0-alpha6`，勾选 *Set as a pre-release*
6. **上传资产**：
   ```bash
   sha256sum lubancat-5_*_v0.6.0-alpha6.img.xz > SHA256SUMS
   ```
   上传 `.img.xz` 与 `SHA256SUMS`。单文件上限 **2 GiB**（2,147,483,648 B），
   上传前用 `stat -c%s` 实测；超限则 `split -b 1900M` 拆卷并在 Release 说明里给合并命令。
7. **校验**：在另一台干净机器 `git clone` → `fetch-sources.sh` → 构建，确认可复现

## 分批推送

首次推送分三批，给自己留核对窗口：

```bash
git push -u origin main          # 1) 代码
git push origin vendor-2026.11   # 2) 厂商二进制 tag（若采用 Release 承载）
git push origin v0.6.0-alpha6    # 3) 版本 tag
```

不要用 `git push --all`。

## 多板发布

同一 tag 下多块板各自一个 asset，用文件名前缀区分：

```
lubancat-5_..._v0.7.0.img.xz
lubancat-4_..._v0.7.0.img.xz
```

`SHA256SUMS` 汇总全部镜像。Release 说明里注明每块板的验证项与已知差异。
