# LubanCat openEuler

[简体中文](README.md) | **English**

Build openEuler 24.03 LTS SP3 images for the LubanCat family
(RK3588 / RK3588S / RK3576 / RK3568 / RK3566). It is based on the openEuler
SBC-sig build framework and uses Rockchip's vendor flow — `parameter-extboot`
plus `update.img` (the "vendor" layout).

> Upstream lineage: [openEuler SBC-sig](https://atomgit.com/openeuler/SBC-sig) @ `521f1ae` (MulanPSL-2.0).
> This is an independent downstream project, not an official openEuler release.

> [!WARNING]
> **Default credentials**: images built here ship with user `lubancat`, password
> `lubancat`, passwordless `sudo`, and desktop autologin. That is a convenience
> setting for **development / evaluation images** — **do not use them in
> production or on any public network**. After the first login, change the
> password, remove the NOPASSWD rules under `/etc/sudoers.d/`, and turn off
> autologin. See [docs/security-notes.md](docs/security-notes.md).

## Board support

**[scripts/boards/matrix.tsv](scripts/boards/matrix.tsv) is the source of truth**;
the table below is only a summary:

| Board | SoC | Status | How far it has been verified on hardware |
|---|---|---|---|
| LubanCat-5 | RK3588 | ✅ Supported | alpha10: UKUI desktop boots; headless not verified separately |
| LubanCat-3 | RK3576 | ✅ Supported | alpha6 (Cat-3 V2): automatic board detection, gigabit Ethernet, hostname, X desktop, GPU `Mali-G52` (1080p clear ≈1.5 ms/frame, ≈680 fps), 3.5 mm headphone audio, NPU 3.3 ms/inference, VPU 1080p encode 109 fps / decode 567 fps, `imx415` camera capture, rkaiq 3A installed and auto-started |
| LubanCat-4 | RK3588S | ✅ Supported | 2026-11-28, on hardware: image boots and the UKUI desktop comes up. Shares u-boot/defconfig with Cat-5 (same family), only the dtb differs; peripherals (audio/camera/NPU) not verified one by one |
| LubanCat-4IO | RK3588S | ✅ Supported | 2026-11-28, on hardware: as above. dtb `rk3588s-lubancat-4io`; generic first boot resolves `LubanCat-4IO` via SARADC and switches the dtb (serial log shows `Model: Embedfire LubanCat-4IO`) |
| LubanCat-2 | RK3568 | ⏳ Pending | Missing conf and u-boot; `soc_name` must be `rk356x` |
| LubanCat-1 | RK3566 | ⏳ Pending | Missing conf and u-boot; `ubootconfig` uses the `rk3566.config` fragment |
| LubanCat-0 | RK3566 | ⏳ Pending | Besides conf/u-boot, the SARADC board-ID mapping needs calibration on real hardware |

"Supported" means an image was built *and* booted on that board — not merely
"it compiles". Picking a `⏳ Pending` board in `tools/build-image.sh` is refused
with a message listing what is missing.

## Quick start

```bash
git clone git@github.com:raidenkl/lubancat-openeuler.git
cd lubancat-openeuler

# 1) Prepare the build environment (checks host, pulls image, creates container, fetches sources; idempotent)
./scripts/init-env.sh

# 2) Build (--dry-run -V prints the commands without running them)
tools/build-image.sh --board lubancat-3 --desktop ukui -y

# 3) Output lands in scripts/build/<date>/; flash the .img.xz with RKDevTool or upgrade_tool
```

To list boards: `tools/build-image.sh --list`.

Build parameters: [docs/building.md](docs/building.md). Release process: [docs/release.md](docs/release.md).

## Build environment

### Host requirements

| Item | Requirement | Notes |
|---|---|---|
| Architecture | **x86_64** | Target images are aarch64; the container runs arm64 code through qemu-user binfmt |
| OS | Ubuntu 22.04 LTS (verified on 22.04.3) | Any distro providing equivalent docker and binfmt works |
| CPU / RAM | ≥ 8 cores / ≥ 16 GiB (verified on 64 cores / 62 GiB) | Kernel and rootfs stages run inside the container; more cores help a lot |
| Disk | **≥ 120 GiB free** | One full build uses 30–40 GiB under `scripts/build/` |
| Network | Required for the first run | ~200 MB container image, 5–10 GiB of source repositories |
| docker | 20.10+ (verified on 27.1.1); user in the `docker` group | rootfs/initrd/packaging stages all run in the container |
| binfmt | `qemu-aarch64` registered | `ls /proc/sys/fs/binfmt_misc/qemu-aarch64` |

The host does **not** need root to build: u-boot is compiled natively on the host
(no mount, no chroot), and every stage that needs mount/chroot runs in the container.

### One-shot setup

```bash
./scripts/init-env.sh                # host checks -> pull base image -> create container -> fetch sources
./scripts/init-env.sh --check        # checks only, changes nothing (CI / troubleshooting)
./scripts/init-env.sh --skip-fetch   # sources already present, just make sure the container is ready
./scripts/init-env.sh --recreate     # repo moved? drop and recreate the container
./scripts/init-env.sh --install-deps # install missing apt packages (calls sudo; explicit opt-in)
./scripts/init-env.sh --fix-perms    # fix ownership when host-side u-boot build says "scripts/build is not writable"
```

By default the script **never calls sudo and never edits `/etc/docker/daemon.json`** —
it reports what is missing and prints the command to fix it. `--check` performs no writes at all.

<details>
<summary><b>Manual steps (what the script does, click to expand)</b></summary>

**1. Install host dependencies**

```bash
# Hard requirements: needed to fetch sources and verify checksums
sudo apt-get install -y git curl coreutils tar gzip

# Needed for the host-side u-boot build (build-image.sh defaults to --uboot-env host)
sudo apt-get install -y python2 make gcc bc bison flex device-tree-compiler cpio
```

> `python2` is a hard requirement of Rockchip's `u-boot/make.sh` (it hardcodes
> `PYTHON=python2`) and is not available in the openEuler 24.03 container, so it
> belongs on the host. If you cannot install python2, use a prebuilt u-boot
> (`build_uboot_from_src=0`) or `--uboot-env container` instead.

**2. docker and aarch64 binfmt**

```bash
sudo usermod -aG docker "$USER"        # log in again afterwards
sudo apt-get install -y qemu-user-static binfmt-support
ls /proc/sys/fs/binfmt_misc/qemu-aarch64   # should say enabled
```

Without binfmt, even `uname` fails inside the container with `exec format error`.
An alternative registration method:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

**3. Create the build container**

```bash
docker run -d --name oe-lubancat-build --platform linux/arm64 --privileged \
  -v "$PWD:$PWD" -w "$PWD" \
  openeuler/openeuler:24.03-lts-sp3 sleep infinity

docker exec oe-lubancat-build uname -m     # expect aarch64
```

Two details:

- **The repo is mounted at the same path inside the container** (`-v "$PWD:$PWD"`).
  `tools/build-image.sh` looks up "where is this repo inside the container?" from
  the container's mount table, so any clone location works. Only the legacy
  workspace layout (parent directory mounted at `/work`, repo at
  `/work/src/SBC-sig`) falls back to the old default.
- The container is **long-lived** (`sleep infinity`), not `--rm`. A build runs in
  stages — u-boot / kernel / boot / rootfs / image — and later stages reuse the
  same container via `docker exec`.

**4. Fetch sources**

```bash
./scripts/fetch-sources.sh            # fetch the 5 repos at the SHAs pinned in manifests/source-lock.yaml
./scripts/fetch-sources.sh --check    # only verify that local SHAs match the lock file
```

The lock file pins commits for kernel `6.1.99`, u-boot `2017.09`, rkbin,
openEuler SBC-sig and the upstream kernel, which makes builds reproducible.
`src/` is not tracked by git (see `.gitignore`).

</details>

### Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `exec format error`, or `uname -m` fails in the container | Host has no binfmt registration | See step 2 above |
| `permission denied ... Docker daemon` | User not in the `docker` group | `sudo usermod -aG docker $USER`, then log in again |
| `docker pull` hangs | Slow direct access to Docker Hub | Configure a registry mirror, or `docker load` an offline image |
| `scripts/build is not writable` (host-side u-boot) | Directory was written by root inside the container | `./scripts/init-env.sh --fix-perms` |
| `No space left on device` near the end of a build | Not enough disk | Clean `scripts/build/` or move to a ≥120 GiB disk |
| "leftover mounts under build/" | A previous build exited abnormally | `mount \| grep scripts/build`, then `umount` and `losetup -d` |
| `afptool`/`parameter` errors after switching SoC or board, or a wrong dtb in boot.img | Kernel and packaging intermediates from the previous SoC were reused | `tools/build-image.sh --purge`, then rebuild |

## Repository layout

```
scripts/            upstream build scripts + this project's changes (build.sh / gen_rk_update.sh / mk_initrd.sh)
scripts/init-env.sh build-environment setup (host checks / container / sources)
scripts/bin/        tools, firmware, vendor binaries (libmali / npu / multimedia / u-boot)
scripts/boards/     per-board configs (one .conf each, incl. POST_BOARD_OVERLAY) + matrix.tsv
scripts/configs/    package lists, kernel defconfigs, boot.cmd, extlinux
scripts/overlay/    rootfs overlay (board detection, audio/camera units, X11 config)
tools/              entry points (build-image.sh builds an image; build-rpms.sh builds the rkaiq RPM)
pkg/                RPM packaging sources (SPECS + SOURCES; currently camera-engine-rkaiq)
manifests/          build provenance: source-lock, per-release summaries, checksums
docs/               project documentation (kept apart from upstream documents/)
build/              local helper scripts and on-board test programs (outputs not tracked)
src/                upstream source repos (created by fetch-sources.sh, not tracked)
```

## Relationship to upstream

- The first commit is **openEuler SBC-sig @521f1ae verbatim**, with none of this
  project's changes, so `git diff` against it is noise-free.
- Our changes start from the second commit and are recorded one by one in
  [docs/upstream-sync.md](docs/upstream-sync.md).
- We do **not** send PRs upstream; this is maintained as an independent downstream.

## Known limitations

- A single SD/eMMC card **cannot be shared across SoC families**: the loader and
  dtb are bound to the SoC and only work within one family
  (RK3588+RK3588S, RK3566+RK3568).
- `parameter.txt` is generated by this project (boot partition = 256 MiB).
  **Never mix it with a vendor `parameter` file when flashing.**
- **The desktop renders with mesa/llvmpipe (software)**: X11 has no Mali
  DRI2/GLX integration, which is expected. The GPU itself works (`Mali-G52` /
  OpenGL ES 3.2, 1080p clear ≈680 fps) but must be used through the GBM platform,
  e.g. `mali-env <program>`. Desktop-level GPU acceleration would need Wayland or
  a Mali GLX provider for X — out of scope here.
- Camera 3A (rkaiq) is baked into the image (`rkaiq_3A_server` + `/etc/iqfiles/`)
  and `rkaiq_3A.service` is enabled by default. With no camera attached the
  service exits and reaches `failed` after 5 restarts — that is expected.
- Cameras are disabled by default: the `dtoverlay` lines in
  `/boot/uEnv/uEnv.txt` are commented out and must be enabled by hand.
- Verified on x86_64 hosts with docker only. Native aarch64 hosts should work in
  principle but have not been tested.

## License

This project is licensed under MulanPSL-2.0 (see [LICENSE](LICENSE)).
`scripts/`, `documents/` and other parts derived from openEuler SBC-sig @521f1ae
are likewise MulanPSL-2.0; our modifications are recorded in [NOTICE](NOTICE) and
in the git history. Bundled third-party binaries keep their original licenses —
see [docs/third-party.md](docs/third-party.md).
